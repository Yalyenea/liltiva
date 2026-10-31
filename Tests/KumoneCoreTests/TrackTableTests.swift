import AppKit
import SwiftUI
import Testing
@testable import KumoneCore

@Suite("Native song-list geometry")
@MainActor
struct TrackTableTests {
    @Test func clickingSearchDoesNotRequireSelectingTheHeaderRow() throws {
        let coordinator = TrackTable.Coordinator()
        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 900, height: 700),
                              styleMask: [.titled], backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        defer { window.close() }
        window.contentView = coordinator.scrollView
        let header = ShortcutSearchField(text: .constant(""), placeholder: "Search", isPlaylistSearch: true)
            .frame(height: 30)
        coordinator.update(TrackTable(trackIDs: [1], header: AnyView(header), footer: AnyView(Color.clear),
                                      headerHeight: 40, footerHeight: 20) { _ in AnyView(Text("Song")) },
                           environment: EnvironmentValues())
        coordinator.scrollView.layoutSubtreeIfNeeded()
        coordinator.table.layoutSubtreeIfNeeded()
        let field = try #require(coordinator.scrollView.descendant(of: ShortcutSearchField.Field.self))
        let location = field.convert(NSPoint(x: field.bounds.midX, y: field.bounds.midY), to: nil)
        let click = try #require(NSEvent.mouseEvent(with: .leftMouseDown, location: location, modifierFlags: [],
            timestamp: 0, windowNumber: window.windowNumber, context: nil, eventNumber: 0, clickCount: 1, pressure: 1))

        #expect(!coordinator.tableView(coordinator.table, shouldSelectRow: 0))
        #expect(coordinator.table.selectedRow == -1)
        #expect(coordinator.table.validateProposedFirstResponder(field, for: click))
    }

    @Test func filteringRetainsTheSearchEditorAndAllowsContinuousChineseInput() throws {
        let coordinator = TrackTable.Coordinator()
        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 900, height: 700),
                              styleMask: [.titled], backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        defer { window.close() }
        window.contentView = coordinator.scrollView
        var query = ""
        let header = AnyView(ShortcutSearchField(text: Binding(get: { query }, set: { query = $0 }),
                                                placeholder: "Search", isPlaylistSearch: true).frame(height: 30))
        func content(_ ids: [Int]) -> TrackTable {
            TrackTable(trackIDs: ids, header: header, footer: AnyView(Color.clear),
                       headerHeight: 40, footerHeight: 20) { _ in AnyView(Text("Song")) }
        }
        coordinator.update(content(Array(0..<200)), environment: EnvironmentValues())
        coordinator.table.layoutSubtreeIfNeeded()
        let field = try #require(coordinator.scrollView.descendant(of: ShortcutSearchField.Field.self))
        field.focusAndSelect()
        let editor = try #require(window.firstResponder as? NSTextView)
        editor.insertText("夜", replacementRange: NSRange(location: NSNotFound, length: 0))
        #expect(query == "夜")
        coordinator.update(content([1, 4]), environment: EnvironmentValues())
        #expect(window.firstResponder === editor)
        #expect(field.window === window)
        editor.insertText("曲", replacementRange: NSRange(location: NSNotFound, length: 0))
        #expect(query == "夜曲")
        coordinator.update(content(Array(0..<200)), environment: EnvironmentValues())
        window.makeFirstResponder(coordinator.table)
        coordinator.table.scrollRowToVisible(199)
        coordinator.table.layoutSubtreeIfNeeded()
        #expect(coordinator.focusSearch())
        #expect((window.firstResponder as? NSTextView)?.delegate === field)
    }

    @Test func keyboardSelectionSkipsChromeAndFollowsTrackIdentityAfterFiltering() {
        let coordinator = TrackTable.Coordinator()
        var content = fixture(count: 3)
        coordinator.update(content, environment: EnvironmentValues())
        #expect(!coordinator.tableView(coordinator.table, shouldSelectRow: 0))
        #expect(!coordinator.tableView(coordinator.table, shouldSelectRow: 4))
        #expect(coordinator.moveSelection(forward: true))
        #expect(coordinator.table.selectedRow == 1)
        #expect(coordinator.moveSelection(forward: true))
        #expect(coordinator.table.selectedRow == 2)
        content = TrackTable(trackIDs: [1, 2], header: content.header, footer: content.footer,
                             headerHeight: 246, footerHeight: 100, row: content.row)
        coordinator.update(content, environment: EnvironmentValues())
        #expect(coordinator.table.selectedRow == 1)
        coordinator.update(fixture(count: 0), environment: EnvironmentValues())
        #expect(coordinator.table.selectedRow == -1)
        #expect(!coordinator.moveSelection(forward: true))
        #expect(!coordinator.activateSelection())
    }

    @Test func returnUsesHostedRowActionAndHonorsDisabledRows() {
        let coordinator = TrackTable.Coordinator()
        coordinator.scrollView.frame = NSRect(x: 0, y: 0, width: 900, height: 700)
        var activated: [Int] = []
        let content = TrackTable(trackIDs: [1, 2], header: AnyView(Color.clear), footer: AnyView(Color.clear),
                                 headerHeight: 20, footerHeight: 20) { index in
            AnyView(Text("Song").background(TrackActivationTarget { activated.append(index) }).disabled(index == 1))
        }
        coordinator.update(content, environment: EnvironmentValues())
        #expect(coordinator.moveSelection(forward: true))
        #expect(coordinator.activateSelection())
        #expect(activated == [0])
        #expect(coordinator.moveSelection(forward: true))
        #expect(!coordinator.activateSelection())
        #expect(activated == [0])
    }

    @Test(arguments: [true, false])
    func offscreenHeaderRetainsItsHeightAcrossContentUpdates(explicitHeight: Bool) {
        let coordinator = TrackTable.Coordinator()
        coordinator.scrollView.frame = NSRect(x: 0, y: 0, width: 900, height: 700)
        var content = fixture(count: 1_200)
        if !explicitHeight { content.headerHeight = nil }
        coordinator.update(content, environment: EnvironmentValues())
        let table = coordinator.table
        // AppKit may defer geometry for distant rows. Realize the destination
        // before recording it, as it would be during an actual scroll.
        table.scrollRowToVisible(1_200)
        table.layoutSubtreeIfNeeded()
        let lastSong = table.rect(ofRow: 1_200)
        #expect(lastSong.height == 53)
        #expect(table.rect(ofRow: 0).height == 246)

        coordinator.scrollView.contentView.scroll(to: NSPoint(x: 0, y: lastSong.minY - 500))
        let offset = coordinator.scrollView.contentView.bounds.origin
        coordinator.update(content, environment: EnvironmentValues())
        table.layoutSubtreeIfNeeded()
        #expect(table.rect(ofRow: 1_200) == lastSong)
        #expect(coordinator.scrollView.contentView.bounds.origin == offset)
    }

    @Test func filteringKeepsHeaderAndFooterHeightsIncludingEmptyResults() {
        let coordinator = TrackTable.Coordinator()
        for count in [1_200, 2, 0, 90] {
            coordinator.update(fixture(count: count), environment: EnvironmentValues())
            let footer = coordinator.table.rect(ofRow: count + 1)
            #expect(coordinator.table.numberOfRows == count + 2)
            #expect(coordinator.table.rect(ofRow: 0).height == 246)
            if count > 0 {
                #expect(coordinator.table.rect(ofRow: count).height == 53)
            }
            if count == 0 { #expect(footer.minY == 246) }
            #expect(footer.height == 100)
        }
    }

    @Test func contentSizedChromeUpdatesWithoutChangingSongHeights() {
        let coordinator = TrackTable.Coordinator()
        coordinator.scrollView.frame = NSRect(x: 0, y: 0, width: 900, height: 700)
        var content = TrackTable(trackIDs: Array(0..<30),
                                 header: AnyView(Color.clear.frame(height: 220)),
                                 footer: AnyView(Color.clear.frame(height: 80))) { _ in
            AnyView(Text("Song"))
        }
        coordinator.update(content, environment: EnvironmentValues())
        #expect(coordinator.table.rect(ofRow: 0).height == 220)
        #expect(coordinator.table.rect(ofRow: 31).height == 80)
        content = TrackTable(trackIDs: content.trackIDs,
                             header: AnyView(Color.clear.frame(height: 60)),
                             footer: AnyView(Color.clear.frame(height: 320))) { _ in
            AnyView(Text("Song"))
        }
        coordinator.update(content, environment: EnvironmentValues())
        #expect(coordinator.table.rect(ofRow: 0).height == 60)
        #expect(coordinator.table.rect(ofRow: 31).height == 320)
        #expect(coordinator.table.rect(ofRow: 1).height == 53)
    }

    @Test func wrappedHeaderAdaptsToWindowWidth() {
        let coordinator = TrackTable.Coordinator()
        coordinator.scrollView.frame = NSRect(x: 0, y: 0, width: 900, height: 700)
        let header = Text(String(repeating: "An artist and a long album description. ", count: 12))
            .font(.system(size: 14)).padding(24)
        let content = TrackTable(trackIDs: [1], header: AnyView(header),
                                 footer: AnyView(Color.clear.frame(height: 80))) { _ in
            AnyView(Text("Song"))
        }
        coordinator.update(content, environment: EnvironmentValues())
        coordinator.scrollView.layoutSubtreeIfNeeded()
        let wideHeight = coordinator.table.rect(ofRow: 0).height
        coordinator.scrollView.frame.size.width = 300
        coordinator.scrollView.needsLayout = true
        coordinator.scrollView.layoutSubtreeIfNeeded()
        #expect(coordinator.table.rect(ofRow: 0).height > wideHeight)
        #expect(coordinator.table.rect(ofRow: 1).height == 53)
    }

    @Test func albumHeaderReflowsWithoutOverlappingTheFirstSong() {
        let coordinator = TrackTable.Coordinator()
        let header = AdaptiveStack(horizontalMinimum: 620, spacing: 20) {
            Color.clear.frame(width: 160, height: 160)
            Text(String(repeating: "Album title and description. ", count: 8))
                .font(.system(size: 14))
                .frame(maxWidth: .infinity, alignment: .leading)
        }
        .padding(24)
        let content = TrackTable(trackIDs: [1], header: AnyView(header),
                                 footer: AnyView(Color.clear.frame(height: 8))) { _ in
            AnyView(Text("Song"))
        }
        var heights: [CGFloat] = []
        for width: CGFloat in [900, 420, 900] {
            coordinator.scrollView.frame = NSRect(x: 0, y: 0, width: width, height: 700)
            coordinator.update(content, environment: EnvironmentValues())
            coordinator.scrollView.layoutSubtreeIfNeeded()
            let header = coordinator.table.rect(ofRow: 0)
            let song = coordinator.table.rect(ofRow: 1)
            #expect(song.minY == header.maxY)
            #expect(song.height == 53)
            heights.append(header.height)
        }
        #expect(heights[1] > heights[0])
        #expect(heights[2] == heights[0])
    }

    @Test func reusingACellUpdatesContentWithoutRecreatingItsViewGraph() {
        let cell = TrackTable.Cell()
        cell.frame = NSRect(x: 0, y: 0, width: 900, height: 53)
        let lifetime = RowLifetime()
        for songID in [1, 400, 1_200, 2] {
            cell.update(AnyView(RowProbe(songID: songID, lifetime: lifetime)),
                        environment: EnvironmentValues())
            cell.layoutSubtreeIfNeeded()
            cell.host.layout()
            #expect(lifetime.songID == songID)
            #expect(lifetime.creations == 1)
        }
    }

    @Test(arguments: [true, false])
    func hidingReleasesHostsWithoutLosingListState(windowHidden: Bool) throws {
        let visibility = MainWindowVisibility()
        let coordinator = TrackTable.Coordinator(visibility: visibility)
        coordinator.scrollView.frame = NSRect(x: 0, y: 0, width: 900, height: 700)
        let content = fixture(count: 1_200)
        let table = coordinator.table
        weak var releasedHost: NSHostingView<AnyView>?
        // AppKit autoreleases views during layout; drain the event's temporary
        // ownership before checking whether the reuse pool still retains a host.
        let (cell, offset, row) = try autoreleasepool {
            coordinator.update(content, environment: EnvironmentValues())
            table.selectRowIndexes(IndexSet(integer: 1_100), byExtendingSelection: false)
            table.scrollRowToVisible(1_100)
            table.layoutSubtreeIfNeeded()
            let cell = try #require(table.view(atColumn: 0, row: 1_100, makeIfNecessary: true) as? TrackTable.Cell)
            releasedHost = cell.host
            let offset = coordinator.scrollView.contentView.bounds.origin
            let row = table.rect(ofRow: 1_100)
            if windowHidden {
                visibility.update(isVisible: false, isOnScreen: false)
            } else {
                visibility.setBrowsingVisible(false)
            }
            return (cell, offset, row)
        }
        let wasReleased = releasedHost == nil
        #expect(wasReleased)
        #expect(cell.subviews.isEmpty)
        // Background model changes and native layout must not recreate hosts.
        coordinator.update(content, environment: EnvironmentValues())
        cell.layout()
        #expect(cell.subviews.isEmpty)
        #expect(!coordinator.moveSelection(forward: true))
        #expect(!coordinator.activateSelection())
        #expect(!coordinator.focusSearch())
        #expect(table.selectedRow == 1_100)
        #expect(coordinator.scrollView.contentView.bounds.origin == offset)
        #expect(table.rect(ofRow: 1_100) == row)

        visibility.update(isVisible: true, isOnScreen: true)
        if !windowHidden { #expect(cell.subviews.isEmpty) }
        visibility.setBrowsingVisible(true)
        coordinator.update(content, environment: EnvironmentValues())
        table.layoutSubtreeIfNeeded()
        #expect(!cell.subviews.isEmpty)
        #expect(table.selectedRow == 1_100)
        #expect(coordinator.scrollView.contentView.bounds.origin == offset)
        #expect(table.rect(ofRow: 1_100) == row)
    }

    @Test func responsiveScrollingKeepsOverdrawNearTheViewport() {
        let coordinator = TrackTable.Coordinator(visibility: MainWindowVisibility())
        coordinator.scrollView.frame = NSRect(x: 0, y: 0, width: 900, height: 700)
        coordinator.update(fixture(count: 1_200), environment: EnvironmentValues())
        let table = coordinator.table
        for index in [1, 600, 1_200] {
            table.scrollRowToVisible(index)
            table.layoutSubtreeIfNeeded()
            table.prepareContent(in: table.bounds)
            #expect(table.preparedContentRect.contains(table.visibleRect))
            #expect(table.preparedContentRect.height <= table.visibleRect.height * 2)
            #expect(table.numberOfRows == 1_202)
        }
    }

    private final class RowLifetime {
        var creations = 0
        var songID = 0
    }

    private struct RowProbe: NSViewRepresentable {
        let songID: Int
        let lifetime: RowLifetime

        func makeNSView(context: Context) -> NSView {
            lifetime.creations += 1
            return NSView()
        }

        func updateNSView(_ view: NSView, context: Context) {
            lifetime.songID = songID
        }
    }

    private func fixture(count: Int) -> TrackTable {
        TrackTable(trackIDs: Array(0..<count), header: AnyView(Text("Playlist").frame(height: 246)),
                      footer: AnyView(Color.clear), headerHeight: 246, footerHeight: 100) { index in
            AnyView(Text("Song \(index)"))
        }
    }
}
