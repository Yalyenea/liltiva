import AppKit
import SwiftUI
import Testing
@testable import KumoneCore

@Suite("Navigation destination tests")
struct NavigationDestinationTests {
    @Test func doesNotAppendTheCurrentDestination() {
        var destinations: [Destination] = [.artist(42)]

        destinations.appendIfNotCurrent(.artist(42))

        #expect(destinations == [.artist(42)])
    }

    @Test func appendsADifferentDestination() {
        var destinations: [Destination] = [.album(7)]

        destinations.appendIfNotCurrent(.artist(42))

        #expect(destinations == [.album(7), .artist(42)])
    }

    @Test func menuPagesCanBePinnedAndUnpinnedInOrder() {
        var pages: [RootPage] = []
        RootPage.collections.togglePin(in: &pages)
        RootPage.explore.togglePin(in: &pages)
        #expect(pages == [.collections, .explore])
        #expect(pages.map(\.rawValue).compactMap(RootPage.init(rawValue:)) == pages)

        RootPage.collections.togglePin(in: &pages)
        #expect(pages == [.explore])
        RootPage.collections.togglePin(in: &pages)
        #expect(pages == [.explore, .collections])
    }

    @Test func primaryTabsCannotBeDuplicatedByPinning() {
        var pages: [RootPage] = []
        for page in RootPage.primaryPages {
            page.togglePin(in: &pages)
        }
        #expect(pages.isEmpty)
        #expect(RootPage.menuPages.contains(.collections))
        #expect(!RootPage.menuPages.contains(.created))
    }

    @Test func savedPlaylistPinsMigrateToOneCollectionEntryInOrder() {
        #expect(RootPage.restoredPinnedPages(["profile", "saved", "cloud", "collections"]) == [.profile, .collections, .cloud])
        #expect(RootPage.restoredPinnedPages(["collections", "saved", "messages"]) == [.collections, .messages])
        #expect(RootPage.restoredPinnedPages(["saved"]) == [.collections])
        #expect(RootPage.restoredPinnedPages(["home", "unknown", "cloud", "cloud"]) == [.cloud])
        #expect(RootPage(rawValue: "saved") == nil)
        #expect(RootPage.menuPages.filter { $0 == .collections }.count == 1)
    }

    @Test func navigationContentFitsItsReservedSpace() {
        for width in [420.0, 650, 790, 1024, 1200] {
            for tabsWidth in [206.0, 2000] {
                for searchExpanded in [false, true] {
                    let layout = NavigationBarLayout(windowWidth: width, tabsWidth: tabsWidth,
                                                     searchExpanded: searchExpanded)
                    #expect(layout.tabsWidth > 0)
                    #expect(layout.searchWidth > 24)
                    let searchReservation = searchExpanded ? layout.searchWidth : 24
                    #expect(layout.tabsWidth + searchReservation + 18 <= layout.width + 0.001)
                }
            }
        }

        // Extra pinned tabs fit at the usual window width while search is closed.
        let pinnedTabs = NavigationBarLayout(windowWidth: 790, tabsWidth: 350)
        #expect(pinnedTabs.tabsWidth == 350)
        let compactTabs = NavigationBarLayout(windowWidth: 650, tabsWidth: 350)
        let searching = NavigationBarLayout(windowWidth: 650, tabsWidth: 350, searchExpanded: true)
        #expect(searching.tabsWidth < compactTabs.tabsWidth)
    }

    @Test func historyRestoresRootTabsAndTheirDestinationStacks() {
        var history = NavigationHistory()
        history.visit(.init(page: .home, path: [.profile(42), .people(42, followers: false)]))
        history.visit(.init(page: .likedSongs))
        history.goBack()
        #expect(history.current == .init(page: .home, path: [.profile(42), .people(42, followers: false)]))
        #expect(history.canGoBack)
        #expect(history.canGoForward)
        history.goForward()
        #expect(history.current == .init(page: .likedSongs))
        #expect(!history.canGoForward)
    }

    @Test func aNewVisitAfterGoingBackDiscardsForwardHistory() {
        var history = NavigationHistory()
        history.visit(.init(path: [.album(1)]))
        history.visit(.init(path: [.album(1), .artist(2)]))
        history.goBack()
        history.visit(.init(path: [.playlist(3)]))
        #expect(!history.canGoForward)
        history.goForward()
        #expect(history.current.path == [.playlist(3)])
        history.goBack()
        #expect(history.current.path == [.album(1)])
    }

    @Test func historyBoundariesAndRepeatedVisitsDoNotCreateEntries() {
        var history = NavigationHistory()
        history.visit(.init())
        history.goBack()
        history.goForward()
        #expect(!history.canGoBack)
        #expect(!history.canGoForward)
        history.visit(.init(path: [.messages]))
        history.goBack()
        history.visit(.init())
        #expect(!history.canGoBack)
        #expect(history.canGoForward)
    }

    @Test @MainActor func titlebarAttachmentResizesWithoutCreatingToolbarItems() {
        _ = NSApplication.shared
        let window = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 1200, height: 600),
            styleMask: [.titled, .closable, .resizable],
            backing: .buffered, defer: false
        )
        window.isReleasedWhenClosed = false
        window.toolbarStyle = .unifiedCompact
        window.toolbar = NSToolbar(identifier: "navigation-layout-test")
        defer { window.close() }
        let titlebar = MainWindowTitlebar()

        for width in [1200.0, 1024, 790, 650, 420, 790, 1200] {
            window.setContentSize(NSSize(width: width, height: 600))
            titlebar.update(content: AnyView(Color.clear), in: window)
            window.layoutIfNeeded()
            #expect(abs(titlebar.view.frame.width - (width - MainWindowTitlebar.leadingInset))
                <= 0.5 / window.backingScaleFactor)
            #expect(window.titlebarAccessoryViewControllers.count == 1)
            #expect(window.toolbar?.items.isEmpty == true)
        }

        titlebar.setFadedOut(true)
        // Immersive controls need the accessory's container removed from
        // hit testing, not just an invisible hosting view.
        #expect(window.titlebarAccessoryViewControllers.isEmpty)
        titlebar.setFadedOut(false)
        #expect(window.titlebarAccessoryViewControllers.count == 1)
        #expect(window.titlebarAccessoryViewControllers.first === titlebar)
    }
}
