import SwiftUI

enum TrackRowStyle {
    /// Artwork + album column (playlists, search, daily).
    case full
    /// Track number, no artwork (album pages).
    case albumTrack
    /// Compact with artwork, no album column (artist hot songs, panels).
    case compact

    var desktopRowHeight: CGFloat { self == .albumTrack ? 46 : 52 }
}

enum RecommendationContext {
    case daily
    case radar
}

// MARK: - Row

struct TrackRow: View {
    let track: Track
    let index: Int
    let numberColumnWidth: CGFloat
    var style: TrackRowStyle = .full
    var playability: TrackPlayability = .playable
    /// Extra trailing text (e.g. play count for recents).
    var trailingText: String?
    /// Set when the row lives inside a user's own playlist (enables 删除).
    var removableFromPlaylistID: Int?
    var onRemoved: (() -> Void)?
    var onRecommendationReduced: ((Track) -> Void)?
    let onPlay: () -> Void

    @EnvironmentObject private var player: PlayerService
    @EnvironmentObject private var account: AccountStore
    @Environment(\.openDestination) private var openDestination
    // Native cells retain this view graph when rebound to another song. Scope
    // transient state and asynchronous completions to the song they belong to.
    @State private var hoveredTrackID: Int?
    @State private var addToPlaylistTrack: Track?
    @State private var reducingRecommendationIDs: Set<Int> = []
    /// Only this track's download state, so another row's transfer cannot
    /// re-evaluate this body four times a second.
    @ObservedObject private var downloadState: TrackDownloadState

    init(track: Track, index: Int, totalCount: Int, style: TrackRowStyle = .full, playability: TrackPlayability = .playable,
         trailingText: String? = nil, removableFromPlaylistID: Int? = nil, onRemoved: (() -> Void)? = nil,
         onRecommendationReduced: ((Track) -> Void)? = nil, onPlay: @escaping () -> Void) {
        self.track = track
        self.index = index
        // Size the entire column for the longest ordinal, so four-digit
        // entries neither wrap nor shift the artwork relative to earlier rows.
        self.numberColumnWidth = max(28, CGFloat(String(totalCount).count) * 8 + 4)
        self.style = style
        self.playability = playability
        self.trailingText = trailingText
        self.removableFromPlaylistID = removableFromPlaylistID
        self.onRemoved = onRemoved
        self.onRecommendationReduced = onRecommendationReduced
        self.onPlay = onPlay
        _downloadState = ObservedObject(wrappedValue: DownloadManager.shared.trackState(for: track.id))
    }

    private var isCurrent: Bool { player.currentTrack?.id == track.id }
    private var isHovering: Bool { hoveredTrackID == track.id }
    private var isReducingRecommendation: Bool { reducingRecommendationIDs.contains(track.id) }
    private var isOffline: Bool { downloadState.isOffline }
    private var isPlayable: Bool { playability == .playable || isOffline }
    private var needsNetwork: Bool { downloadState.needsNetwork }
    private var showsArtwork: Bool { style != .albumTrack }
    var body: some View {
        GeometryReader { geometry in
            HStack(spacing: geometry.size.width < 440 ? 8 : 12) {
                leadingIndicator

                if showsArtwork {
                    artwork
                }

                VStack(alignment: .leading, spacing: 2) {
                    HStack(spacing: 6) {
                        Text(track.name)
                            .font(.system(size: 13, weight: .medium))
                            .foregroundStyle(isCurrent ? Theme.accent : .primary)
                            .lineLimit(1)
                        if let subtitle = track.subtitle, geometry.size.width >= 440 {
                            Text("(\(subtitle))")
                                .font(.system(size: 12))
                                .foregroundStyle(.tertiary)
                                .lineLimit(1)
                        }
                        if track.fee == 1 {
                            VIPBadge()
                        }
                    }
                    artistLinks
                }
                .frame(maxWidth: .infinity, alignment: .leading)

                // Keep the song and its actions readable before showing secondary columns.
                if style == .full, geometry.size.width >= 620 {
                    if track.album.id > 0, !track.album.name.isEmpty {
                        Button {
                            openDestination(.album(track.album.id))
                        } label: {
                            Text(track.album.name)
                                .font(.system(size: 12))
                                .foregroundStyle(.secondary)
                                .lineLimit(1)
                        }
                        .buttonStyle(.plain)
                        .accessibilityLabel("打开专辑：\(track.album.name)")
                        .frame(maxWidth: 220, alignment: .leading)
                    } else {
                        Text(track.album.name)
                            .font(.system(size: 12))
                            .foregroundStyle(.secondary)
                            .lineLimit(1)
                            .frame(maxWidth: 220, alignment: .leading)
                    }
                }

                if let reason = playability.reason, !isOffline, geometry.size.width >= 520 {
                    Text(reason)
                        .font(.system(size: 10, weight: .medium))
                        .foregroundStyle(.tertiary)
                        .padding(.horizontal, 5)
                        .padding(.vertical, 2)
                        .background(.quaternary.opacity(0.5), in: RoundedRectangle(cornerRadius: 4))
                }

                if let trailingText, geometry.size.width >= 440 {
                    Text(trailingText)
                        .font(.system(size: 11).monospacedDigit())
                        .foregroundStyle(.tertiary)
                }

                likeAndDuration
                    .padding(.leading, 0)
            }
            .padding(.horizontal, 10)
            .padding(.vertical, 5)
        }
        // Keep the row and its virtual scroll extent in agreement (#3).
        .frame(height: rowHeight)
        .opacity(isPlayable && !needsNetwork ? 1 : 0.45)
        .background(
            RoundedRectangle(cornerRadius: Theme.Radius.standard, style: .continuous)
                .fill(isHovering ? Color.primary.opacity(0.06) : .clear)
        )
        .contentShape(Rectangle())
        .background(TrackActivationTarget(activate: playSelectedTrack))
        .onHover { hovering in
            // Scrolling moves many rows beneath the pointer. Avoid starting a
            // new implicit animation for every row crossed during a scroll.
            hoveredTrackID = hovering ? track.id : nil
        }
        .onTapGesture(count: 2) {
            playSelectedTrack()
        }
        .contextMenu { contextMenuItems }
        .sheet(item: $addToPlaylistTrack) { selectedTrack in
            AddToPlaylistSheet(track: selectedTrack)
        }
        .onChange(of: track.id) { _ in
            hoveredTrackID = nil
            addToPlaylistTrack = nil
        }
    }

    private func playSelectedTrack() {
        if needsNetwork { ToastCenter.shared.show(String(localized: "此歌曲需要联网播放")) } else if isPlayable { onPlay() }
    }

    @ViewBuilder
    private var artwork: some View {
        if track.album.id > 0, !track.album.name.isEmpty {
            Button {
                openDestination(.album(track.album.id))
            } label: {
                artworkImage
            }
            .buttonStyle(.plain)
            .accessibilityLabel("打开专辑：\(track.album.name)")
        } else {
            artworkImage
        }
    }

    @ViewBuilder
    private var artworkImage: some View {

            CachedAsyncImage(url: track.album.picUrl?.resizedImageURL(96), animated: false)
                .frame(width: 42, height: 42)
                .clipShape(RoundedRectangle(cornerRadius: Theme.Radius.small, style: .continuous))

    }

    private var artistLinks: some View {
        ArtistLinks(artists: track.artists) { id in
            openDestination(.artist(id))
        }
    }

    private var rowHeight: CGFloat {
        if style == .albumTrack {
            return style.desktopRowHeight
        }
        return style.desktopRowHeight
    }

    @ViewBuilder
    private var leadingIndicator: some View {
        ZStack {
            if isCurrent {
                PlayingIndicator(animating: player.isPlaying && !player.showNowPlaying)
            } else if isHovering, isPlayable {
                Button(action: onPlay) {
                    Image(systemName: "play.fill")
                        .font(.system(size: 11, weight: .semibold))
                        .foregroundStyle(.primary)
                }
                .buttonStyle(.pressable)
            } else {
                Text(String(index))
                    .font(.system(size: 12).monospacedDigit())
                    .lineLimit(1)
                    .fixedSize(horizontal: true, vertical: false)
                    .foregroundStyle(.tertiary)
            }
        }
        .frame(width: numberColumnWidth)
    }

    private var likeAndDuration: some View {
        HStack(spacing: 8) {
            // A saved track already keeps the button visible through its own state.
            TrackDownloadButton(track: track, isVisible: isHovering)
                // Keep download confirmation and in-flight button state bound
                // to their original song without replacing the whole row.
                .id(track.id)
            let liked = account.isLiked(track.id)
            Button {
                Task { await account.toggleLike(trackID: track.id) }
            } label: {
                Image(systemName: liked ? "heart.fill" : "heart")
                    .font(.system(size: 12))
                    .foregroundStyle(liked ? AnyShapeStyle(Theme.accent) : AnyShapeStyle(.secondary))
            }
            .buttonStyle(.pressable)
            .opacity(liked || isHovering ? 1 : 0)

            Text(Formatters.duration(track.duration))
                .font(.system(size: 11.5).monospacedDigit())
                .foregroundStyle(.tertiary)
                .frame(width: 36, alignment: .trailing)
        }
    }

    @ViewBuilder
    private var contextMenuItems: some View {
        Button("播放") { onPlay() }
        TrackDownloadActions(track: track)
        Button("下一首播放") {
            player.addToPlayNext(track)
        }
        Divider()
        let liked = account.isLiked(track.id)
        Button(liked ? String(localized: "从「我喜欢」中移除") : String(localized: "添加到「我喜欢」")) {
            Task { await account.toggleLike(trackID: track.id) }
        }
        Button("收藏到歌单…") {
            addToPlaylistTrack = track
        }
        if let pid = removableFromPlaylistID {
            Button("从歌单中删除", role: .destructive) {
                Task {
                    do {
                        try await NeteaseAPI.playlistTracks(op: "del", playlistID: pid, trackIDs: [track.id])
                        onRemoved?()
                        ToastCenter.shared.show(String(localized: "已从歌单中删除"))
                    } catch {
                        ToastCenter.shared.show(error.localizedDescription)
                    }
                }
            }
        }
        if !account.isLiked(track.id), let onRecommendationReduced {
            Button(String(localized: "减少推荐"), role: .destructive) {
                guard !isReducingRecommendation else { return }
                let trackID = track.id
                reducingRecommendationIDs.insert(trackID)
                Task {
                    defer { reducingRecommendationIDs.remove(trackID) }
                    do {
                        let replacement = try await NeteaseAPI.dislikeRecommendedSong(id: track.id)
                        onRecommendationReduced(replacement)
                        ToastCenter.shared.show(String(localized: "已减少推荐"))
                    } catch {
                        ToastCenter.shared.show(error.localizedDescription)
                    }
                }
            }
            .disabled(isReducingRecommendation)
        }
        Divider()
        if track.album.id > 0 {
            Button("查看专辑") {
                openDestination(.album(track.album.id))
            }
        }
        ForEach(track.artists.filter { $0.id > 0 && !$0.name.isEmpty }.prefix(3)) { artist in
            Button("查看歌手：\(artist.name)") {
                openDestination(.artist(artist.id))
            }
        }
        Divider()
        Button("复制链接") {
            Platform.copyToPasteboard(string: "https://music.163.com/#/song?id=\(track.id)")
            ToastCenter.shared.show(String(localized: "链接已复制"))
        }
    }
}

// MARK: - Playing indicator

/// The four bars beside the row that's playing.
///
/// Deliberately not a SwiftUI animation. Driving these from `TimelineView` —
/// as this did for a long time — makes SwiftUI re-evaluate and re-lay-out the
/// enclosing tree on every tick, and with the now-playing page presented as an
/// overlay that tree is the entire window. Profiling put the cost at roughly
/// 30% of a core, for four 14pt bars.
///
/// Scaling plain `CALayer`s instead is a compositing change: no `draw`, no
/// layout invalidation, nothing above it in the tree ever learns a frame
/// happened.
struct PlayingIndicator: View {
    var animating: Bool
    @ObservedObject private var windowVisibility = MainWindowVisibility.shared

    var body: some View {
        SpectrumBars(animating: animating && windowVisibility.isVisible)
            .frame(width: SpectrumBarsView.width, height: SpectrumBarsView.maxHeight)
    }
}

private struct SpectrumBars: NSViewRepresentable {
    var animating: Bool
    func makeNSView(context: Context) -> SpectrumBarsView { SpectrumBarsView() }
    func updateNSView(_ view: SpectrumBarsView, context: Context) {
        view.animating = animating
    }
    static func dismantleNSView(_ view: SpectrumBarsView, coordinator: ()) {
        view.animating = false
    }
}

final class SpectrumBarsView: PlatformView {
    static let minHeight: CGFloat = 3
    static let maxHeight: CGFloat = 14
    static let barWidth: CGFloat = 2.5
    static let spacing: CGFloat = 2
    static let width =
        CGFloat(AudioSpectrum.bandCount) * barWidth
        + CGFloat(AudioSpectrum.bandCount - 1) * spacing

    private var bars: [CALayer] = []
    private var timer: Timer?

    var animating = false {
        didSet {
            guard animating != oldValue else { return }
            animating ? start() : stop()
        }
    }

    init() {
        super.init(frame: CGRect(x: 0, y: 0, width: Self.width, height: Self.maxHeight))
        wantsLayer = true
        buildBars()
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError("init(coder:) is not used") }

    deinit { timer?.invalidate() }

    override func viewDidMoveToWindow() {
        super.viewDidMoveToWindow()
        // Native table reuse can detach a cell before SwiftUI updates its state.
        // A detached indicator has no visible frames to deliver.
        if window == nil { stop() }
        else if animating { start() }
    }

    private var hostLayer: CALayer? { layer }

    private func buildBars() {
        guard let host = hostLayer else { return }
        let color = PlatformColor(Theme.accent).cgColor
        for _ in 0..<AudioSpectrum.bandCount {
            let bar = CALayer()
            bar.backgroundColor = color
            bar.cornerRadius = 1
            // Centered anchor so a scale grows the bar symmetrically.
            bar.anchorPoint = CGPoint(x: 0.5, y: 0.5)
            bar.bounds = CGRect(x: 0, y: 0, width: Self.barWidth, height: Self.maxHeight)
            host.addSublayer(bar)
            bars.append(bar)
        }
        apply(scaleForAll: Self.minHeight / Self.maxHeight)
    }

    override func layout() {
        super.layout()
        positionBars()
    }

    private func positionBars() {
        for (i, bar) in bars.enumerated() {
            bar.position = CGPoint(
                x: CGFloat(i) * (Self.barWidth + Self.spacing) + Self.barWidth / 2,
                y: bounds.midY)
        }
    }

    private func start() {
        guard window != nil, timer == nil else { return }
        // Common mode so the bars keep moving while a list is being scrolled.
        let timer = Timer(timeInterval: 1.0 / 30, repeats: true) { [weak self] _ in
            MainActor.assumeIsolated { self?.tick() }
        }
        RunLoop.main.add(timer, forMode: .common)
        self.timer = timer
    }

    private func stop() {
        timer?.invalidate()
        timer = nil
        apply(scaleForAll: Self.minHeight / Self.maxHeight)
    }

    @MainActor
    private func tick() {
        let spectrum = AudioSpectrum.shared
        guard spectrum.tapState == .tapped, spectrum.isLive else {
            apply(scaleForAll: Self.minHeight / Self.maxHeight)
            return
        }

        let span = Self.maxHeight - Self.minHeight

        CATransaction.begin()
        CATransaction.setDisableActions(true)
        for (i, bar) in bars.enumerated() {
            let level = CGFloat(spectrum.level(at: i))
            let height = Self.minHeight + span * level
            bar.transform = CATransform3DMakeScale(1, height / Self.maxHeight, 1)
        }
        CATransaction.commit()
    }

    private func apply(scaleForAll scale: CGFloat) {
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        for bar in bars {
            bar.transform = CATransform3DMakeScale(1, scale, 1)
        }
        CATransaction.commit()
    }
}

// MARK: - Track list

struct TrackListView: View {
    enum Layout {
        case stack
        /// One reusable native table cell, retaining the complete playback queue.
        case singleRow(Int)
    }

    private let rowSpacing: CGFloat = 1

    let tracks: [Track]
    var style: TrackRowStyle = .full
    var privileges: [Int: TrackPrivilege] = [:]
    var source: PlaySource = .none
    /// The place this list belongs to, for the Dock menu's recents.
    var context: PlayContext?
    var removableFromPlaylistID: Int?
    var onRemoved: ((Track) -> Void)?
    var recommendationContext: RecommendationContext?
    var onRecommendationReduced: ((Track, Track) -> Void)?
    var selection: Binding<Set<Int>>?
    var layout: Layout = .stack

    // Playback state belongs to TrackRow; the list only starts playback.
    private let player = PlayerService.shared
    @EnvironmentObject private var account: AccountStore

    @ViewBuilder
    var body: some View {
        switch layout {
        case .stack:
            LazyVStack(spacing: rowSpacing) { rows(in: tracks.indices) }
        case .singleRow(let index):
            // The native table already provides one reusable cell. A keyed
            // ForEach here would discard the entire row graph on every reuse.
            row(at: index)
        }
    }

    private func rows(in range: Range<Int>) -> some View {
        ForEach(range.map { (index: $0, track: tracks[$0]) }, id: \.track.id) { index, _ in
            row(at: index)
        }
    }

    private func row(at index: Int) -> some View {
        let track = tracks[index]
        let recommendationHandler = onRecommendationReduced
        let row = TrackRow(
            track: track,
            index: style == .albumTrack ? (track.trackNo > 0 ? track.trackNo : index + 1) : index + 1,
            totalCount: tracks.count,
            style: style,
            playability: playability(of: track),
            removableFromPlaylistID: removableFromPlaylistID,
            onRemoved: { onRemoved?(track) },
            onRecommendationReduced: recommendationContext == nil || recommendationHandler == nil
                ? nil
                : { replacement in recommendationHandler?(track, replacement) }
        ) {
            player.play(tracks: playableTracks, source: source, startAt: track,
                        context: context)
        }
        return VStack(spacing: 0) {
            if let selection {
                let selected = selection.wrappedValue.contains(track.id)
                Button {
                    if selected { selection.wrappedValue.remove(track.id) }
                    else { selection.wrappedValue.insert(track.id) }
                } label: {
                    HStack(spacing: 0) {
                        Image(systemName: selected ? "checkmark.circle.fill" : "circle")
                            .font(.system(size: 20))
                            .foregroundStyle(selected ? Theme.accent : Color.secondary)
                            .frame(width: 32)
                        row.disabled(true).allowsHitTesting(false).accessibilityHidden(true)
                    }
                    .contentShape(Rectangle())
                    .background(Theme.accent.opacity(selected ? 0.07 : 0), in: RoundedRectangle(cornerRadius: Theme.Radius.standard))
                }
                .buttonStyle(.plain)
                .accessibilityLabel(Text("\(track.name), \(track.artistNames)"))
                .accessibilityValue(selected ? Text("已选择") : Text("未选择"))
                .accessibilityIdentifier("select-download-\(track.id)")
            } else { row }
        }
    }

    private var playableTracks: [Track] {
        tracks.filter { playability(of: $0) == .playable }
    }

    private func playability(of track: Track) -> TrackPlayability {
        // Read, not observed: each row watches its own download state, so a
        // transfer elsewhere must not rebuild the whole list.
        if DownloadManager.shared.offlineTracksByID[track.id] != nil { return .playable }
        return track.playability(
            privilege: privileges[track.id],
            isLoggedIn: account.isLoggedIn,
            vipType: account.vipType
        )
    }
}

// MARK: - Add to playlist

struct AddToPlaylistSheet: View {
    let track: Track

    @EnvironmentObject private var account: AccountStore
    @Environment(\.dismiss) private var dismiss
    @State private var newName = ""
    @State private var creating = false

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            Text("收藏到歌单")
                .font(.headline)
                .padding(16)
            Divider().opacity(0.4)
            if account.createdPlaylists.isEmpty {
                EmptyStateView(icon: "music.note.list", title: "还没有创建歌单")
                    .frame(height: 200)
            } else {
                ScrollView {
                    LazyVStack(spacing: 1) {
                        ForEach(account.createdPlaylists) { playlist in
                            Button {
                                add(to: playlist)
                            } label: {
                                HStack(spacing: 10) {
                                    CachedAsyncImage(url: playlist.coverURL?.resizedImageURL(80), animated: false)
                                        .frame(width: 36, height: 36)
                                        .clipShape(RoundedRectangle(cornerRadius: 6, style: .continuous))
                                    VStack(alignment: .leading, spacing: 2) {
                                        Text(playlist.name)
                                            .font(.system(size: 13, weight: .medium))
                                            .foregroundStyle(.primary)
                                            .lineLimit(1)
                                        Text("\(playlist.trackCount) 首")
                                            .font(.system(size: 11))
                                            .foregroundStyle(.secondary)
                                    }
                                    Spacer()
                                }
                                .padding(.horizontal, 10)
                                .padding(.vertical, 6)
                                .contentShape(Rectangle())
                            }
                            .buttonStyle(.interactiveRow)
                        }
                    }
                    .padding(8)
                }
                .frame(height: 280)
            }
            Divider().opacity(0.4)
            HStack {
                TextField("新建歌单", text: $newName)
                    .textFieldStyle(.roundedBorder)
                Button("创建并收藏") {
                    createAndAdd()
                }
                .disabled(newName.trimmingCharacters(in: .whitespaces).isEmpty || creating)
            }
            .padding(12)
        }
        .frame(width: 340)
        .noFocusRing()
    }

    private func add(to playlist: PlaylistSummary) {
        Task {
            do {
                try await NeteaseAPI.playlistTracks(op: "add", playlistID: playlist.id, trackIDs: [track.id])
                ToastCenter.shared.show(String(localized: "已收藏到「\(playlist.name)」"))
                await account.refreshLibrary()
                dismiss()
            } catch {
                ToastCenter.shared.show(error.localizedDescription)
            }
        }
    }

    private func createAndAdd() {
        let name = newName.trimmingCharacters(in: .whitespaces)
        guard !name.isEmpty else { return }
        creating = true
        Task {
            defer { creating = false }
            do {
                if let id = try await NeteaseAPI.createPlaylist(name: name, isPrivate: false) {
                    try await NeteaseAPI.playlistTracks(op: "add", playlistID: id, trackIDs: [track.id])
                    ToastCenter.shared.show(String(localized: "已收藏到「\(name)」"))
                    await account.refreshLibrary()
                    dismiss()
                }
            } catch {
                ToastCenter.shared.show(error.localizedDescription)
            }
        }
    }
}
