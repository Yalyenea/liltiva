import SwiftUI

/// Artwork and lyrics share the available space; transport stays at the bottom.
struct NowPlayingView: View {
    let onOpenDestination: (Destination) -> Void

    @EnvironmentObject private var player: PlayerService
    @EnvironmentObject private var settings: SettingsManager
    @EnvironmentObject private var artworkStore: NowPlayingArtworkStore
    @EnvironmentObject private var nowPlayingIdle: NowPlayingIdleController
    @State private var highlightedOption: PlaybackOption?

    private enum PlaybackOption: Hashable {
        case mode(NowPlayingMode)
        case transparency
    }

    var body: some View {
        GeometryReader { geo in
            ZStack {
                backdrop
                    // Continue the same gradient beneath the persistent transport.
                    .padding(.bottom, -Theme.Layout.playerBarHeight)
                VStack(spacing: 0) {
                    headerBar
                    playbackContent
                }
            }
            .frame(width: geo.size.width, height: geo.size.height)
            .background(alignment: .top) {
                NowPlayingSwipeGesture(direction: .both, onSwipe: close)
                    .frame(height: 120)
            }
        }
        // The window toolbar is hidden while this page is up, but SwiftUI keeps
        // reserving its safe area, which pushed the whole immersive layout —
        // close button included — a toolbar's height down from the window top.
        .ignoresSafeArea()
        .preferredColorScheme(.dark)
        .onExitCommand {
            close()
        }
        .onDisappear { nowPlayingIdle.isShowingOptions = false }
    }

    private var hasLyricsColumn: Bool {
        if let lyrics = player.lyrics, !lyrics.isEmpty { return true }
        return player.lyrics == nil // still loading — keep layout stable
    }

    private func close() {
        player.showNowPlaying = false
    }

    private func headerGlyph(_ name: String) -> some View {
        Image(systemName: name)
            .font(.system(size: 13, weight: .medium))
            .foregroundStyle(.white.opacity(0.85))
            .frame(width: 28, height: 28)
            .contentShape(Rectangle())
    }

    /// Give song metadata its own row below the window controls, so the
    /// lyrics layout has breathing room without moving the header buttons.
    private var playbackContent: some View {
        VStack(spacing: 0) {
            if settings.nowPlayingMode == .lyrics {
                trackMetaView
                    .trackSwipeContent()
                    .padding(.horizontal, 32)
                    .padding(.vertical, 12)
            }
            GeometryReader { content in
                playbackLayout(size: content.size)
                    .trackSwipeContent()
            }
            .clipped()
        }
        // The header extends into the titlebar outside the safe area. Keep the
        // swipe's content shape below it so it cannot cut off button hit tests.
        .trackSwipeNavigation()
    }

    private var headerBar: some View {
        HStack(spacing: 4) {
            Spacer()
          HStack(spacing: 4) {
            Button {
                nowPlayingIdle.isShowingOptions.toggle()
            } label: {
                headerGlyph("rectangle.on.rectangle")
            }
            .buttonStyle(.plain)
            .noFocusRing()
            .fixedSize()
            .popover(isPresented: $nowPlayingIdle.isShowingOptions, arrowEdge: .bottom) {
                playbackOptions
                    .popupSurface()
            }
            .help("播放页设置")
            .accessibilityLabel("播放页设置")
            Button(action: close) {
                headerGlyph("chevron.down")
            }
            .buttonStyle(.pressable)
            .help("收起播放页")
            .accessibilityLabel("收起播放页")
          }
          .hiddenDuringCleanPlayback(nowPlayingIdle.isClean)
        }
        .padding(.trailing, 16)
        .frame(height: Theme.Layout.titlebarHeight)
    }

    private var playbackOptions: some View {
        VStack(alignment: .leading, spacing: 2) {
            ForEach(NowPlayingMode.allCases) { mode in
                PopupRow(isSelected: settings.nowPlayingMode == mode,
                         isHighlighted: highlightedOption == .mode(mode),
                         onHover: { if $0 { highlightedOption = .mode(mode) } },
                         action: { selectOption(.mode(mode)) }) {
                    Text(mode.displayName)
                }
            }
            Divider().padding(.vertical, 4)
            Toggle("透明模式", isOn: $settings.transparentPlayback)
                .toggleStyle(.switch)
                .controlSize(.small)
                .font(.system(size: 13))
                .padding(.horizontal, 10)
                .padding(.vertical, 6)
                .background(PopupRowBackground(isHighlighted: highlightedOption == .transparency))
                .onHover { if $0 { highlightedOption = .transparency } }
            if settings.transparentPlayback {
                transparencyOptions
                    .padding(.horizontal, 10)
                    .padding(.vertical, 6)
            }
        }
        .padding(8)
        .frame(width: 246)
        .popupKeyboardNavigation(items: NowPlayingMode.allCases.map(PlaybackOption.mode) + [.transparency],
                                 selection: .mode(settings.nowPlayingMode), highlighted: $highlightedOption,
                                 onSelect: selectOption,
                                 onDismiss: { nowPlayingIdle.isShowingOptions = false })
    }

    private func selectOption(_ option: PlaybackOption) {
        switch option {
        case .mode(let mode):
            settings.nowPlayingMode = mode
            nowPlayingIdle.isShowingOptions = false
        case .transparency:
            settings.transparentPlayback.toggle()
        }
    }

    private var transparencyOptions: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack {
                Text("背景透明度")
                Spacer()
                Text(settings.playbackTransparency, format: .percent.precision(.fractionLength(0)))
                    .monospacedDigit()
                    .foregroundStyle(.secondary)
            }
            Slider(value: $settings.playbackTransparency,
                   in: SettingsManager.playbackTransparencyRange, step: 0.05)
                .accessibilityLabel("背景透明度")
                .accessibilityValue(Text(settings.playbackTransparency,
                                         format: .percent.precision(.fractionLength(0))))
            HStack {
                Text("不透明")
                Spacer()
                Text("完全透明")
            }
            .font(.caption2)
            .foregroundStyle(.secondary)
        }
        .font(.system(size: 12))
        .controlSize(.small)
    }

    // MARK: - Backdrop

    private var artworkImage: PlatformImage? {
        artworkStore.artwork
    }

    private var colors: ArtworkColors {
        artworkStore.colors
    }

    private var backdrop: some View {
        ZStack {
            LinearGradient(
                colors: [colors.primary, colors.secondary],
                startPoint: .topLeading, endPoint: .bottomTrailing
            )
            RadialGradient(
                colors: [.white.opacity(0.12), .clear],
                center: .topLeading, startRadius: 0, endRadius: 700
            )
            LinearGradient(
                colors: [.clear, .black.opacity(0.35)],
                startPoint: .top, endPoint: .bottom
            )
        }
        .opacity(playbackArtworkOpacity)
        .background {
            if settings.transparentPlayback { TransparentPlaybackBackground() }
        }
        // Preserve the original glass at the default position; further
        // transparency fades the entire background without fading the content.
        .opacity(playbackBackgroundOpacity)
        .ignoresSafeArea()
        .animation(AppAnimation.smooth, value: settings.transparentPlayback)
        .animation(.easeInOut(duration: 0.8), value: colors)
    }

    private var playbackBackgroundOpacity: Double {
        guard settings.transparentPlayback else { return 1 }
        return min(1, (1 - settings.playbackTransparency)
                   / (1 - SettingsManager.defaultPlaybackTransparency))
    }

    private var playbackArtworkOpacity: Double {
        guard settings.transparentPlayback else { return 1 }
        // The original appearance used full-strength system glass with a
        // 28% artwork tint. Interpolate toward opaque below that preset.
        let fraction = min(settings.playbackTransparency / SettingsManager.defaultPlaybackTransparency, 1)
        return 1 - fraction * (1 - 0.28)
    }


    // MARK: - Layouts

    @ViewBuilder
    private func playbackLayout(size: CGSize) -> some View {
        if settings.nowPlayingMode == .lyrics {
            lyricsColumn(centered: true)
                .frame(maxWidth: 900)
                .frame(maxWidth: .infinity, maxHeight: .infinity)
        } else if (size.width < 820 || size.height > size.width), hasLyricsColumn {
            // On tall, narrow windows artwork sits above the lyrics instead
            // of spending half the width on an almost empty album column.
            let artworkSize = max(72, min(220, size.width * 0.42, size.height * 0.25))
            VStack(spacing: 12) {
                albumPresentation(size: artworkSize)
                trackMetaView.padding(.horizontal, 24)
                lyricsColumn(centered: true)
            }
            .padding(.top, 4)
            .frame(maxWidth: .infinity, maxHeight: .infinity)
        } else {
            regularLayout(size: size)
        }
    }

    private func regularLayout(size: CGSize) -> some View {
        let artworkSize = max(90, min(340, size.width * 0.32, (size.height - 110) / 1.26))
        let maxBandWidth: CGFloat = hasLyricsColumn ? 1040 : 560
        return HStack(spacing: hasLyricsColumn ? 30 : 0) {
            leftColumn(artworkSize: artworkSize)
                .frame(maxWidth: .infinity)
            if hasLyricsColumn {
                lyricsColumn(centered: false)
                    .frame(maxWidth: .infinity)
            }
        }
        .frame(maxWidth: maxBandWidth)
        .frame(maxWidth: .infinity)
        .padding(.horizontal, size.width < 760 ? 24 : 40)
        .padding(.vertical, 12)
    }

    // MARK: - Views

    private func artworkView(size: CGFloat) -> some View {
        Group {
            if let album = player.currentTrack?.album, album.id > 0, !album.name.isEmpty {
                Button {
                    onOpenDestination(.album(album.id))
                } label: {
                    artworkSurface(size: size)
                }
                .buttonStyle(.plain)
                .noFocusRing()
                .help("打开专辑：\(album.name)")
                .accessibilityLabel("打开专辑：\(album.name)")
            } else {
                artworkSurface(size: size)
            }
        }
    }

    private func artworkSurface(size: CGFloat) -> some View {
        ZStack {
            Rectangle()
                .fill(.white.opacity(0.06))
                .overlay(
                    Image(systemName: "music.note")
                        .font(.system(size: 48, weight: .light))
                        .foregroundStyle(.white.opacity(0.3))
                )
            if let artworkImage {
                Image(platformImage: artworkImage)
                    .resizable()
                    .aspectRatio(contentMode: .fill)
                    .transition(.opacity)
            }
        }
        .frame(width: size, height: size)
        .clipShape(RoundedRectangle(cornerRadius: 8, style: .continuous))
        .shadow(color: .black.opacity(0.2), radius: 12, y: 6)
        .animation(.easeIn(duration: 0.25), value: artworkImage != nil)
        .scaleEffect(player.isPlaying ? 1 : 0.95)
        .animation(AppAnimation.bouncy, value: player.isPlaying)
    }

    private var trackMetaView: some View {
        VStack(spacing: 8) {
            trackTitle
            trackArtists
        }
        .frame(maxWidth: 400)
    }

    private var trackTitle: some View {
        HStack(spacing: 8) {
            if player.currentTrack?.fee == 1 {
                // Equal badge space keeps the title centred, including
                // when a long title needs truncation in a narrow window.
                VIPBadge().hidden().accessibilityHidden(true)
            }
            Text(player.currentTrack?.name ?? "")
                .font(.system(size: 21, weight: .bold))
                .foregroundStyle(.white)
                .lineLimit(1)
            if player.currentTrack?.fee == 1 {
                VIPBadge()
                    .hiddenDuringCleanPlayback(nowPlayingIdle.isClean)
            }
        }
    }

    @ViewBuilder
    private var trackArtists: some View {
        if let track = player.currentTrack {
            NowPlayingTrackDestinationLinks(
                track: track,
                font: .system(size: 13.5),
                color: .white.opacity(0.65),
                onOpenDestination: onOpenDestination
            )
        }
    }

    private func albumPresentation(size: CGFloat) -> some View {
        Group {
            if settings.nowPlayingMode == .vinyl {
                VinylTurntableView(
                    artworkImage: artworkImage,
                    isPlaying: player.isPlaying,
                    duration: player.duration,
                    trackId: player.currentTrack?.id,
                    size: size,
                    onTap: {
                        player.togglePlayPause()
                    }
                )
                .help(player.isPlaying ? "暂停" : "播放")
            } else {
                artworkView(size: size)
            }
        }
    }

    private func leftColumn(artworkSize: CGFloat) -> some View {
        VStack(spacing: 20) {
            Spacer(minLength: 0)
            albumPresentation(size: artworkSize)
            trackMetaView
            Spacer()
        }
    }

    private func lyricsColumn(centered: Bool) -> some View {
        NowPlayingLyricsColumn(centered: centered)
    }
}

/// Keep line changes inside the lyrics tree: the backdrop and hosted record
/// have no dependency on the playback cursor.
private struct NowPlayingLyricsColumn: View {
    let centered: Bool
    @EnvironmentObject private var player: PlayerService
    @EnvironmentObject private var settings: SettingsManager
    @ObservedObject private var lyricsCursor = PlayerService.shared.lyricsCursor
    @ObservedObject private var windowVisibility = MainWindowVisibility.shared
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @State private var activeIndex: Int?
    @State private var isUserScrolling = false

    /// Jump straight to the line the song is on. Used when the view appears,
    /// where waiting for the next line change would leave the lyrics parked at
    /// the top. Scrolling is deferred a turn: the list has not laid out yet
    /// while `onAppear` runs, and `scrollTo` on an unlaid list does nothing.
    private func adoptCursor(proxy: ScrollViewProxy) {
        let index = lyricsCursor.activeIndex
        activeIndex = index
        guard let index else { return }
        DispatchQueue.main.async {
            proxy.scrollTo(index, anchor: .center)
        }
    }

    var body: some View {
        GeometryReader { proxy in
            lyricContent(verticalInset: max(32, proxy.size.height * 0.35), centered: centered)
        }
    }

    @ViewBuilder
    private func lyricContent(verticalInset: CGFloat, centered: Bool) -> some View {
        if let lyrics = player.lyrics, !lyrics.isEmpty {
            ScrollViewReader { proxy in
                ScrollView(showsIndicators: false) {
                    // A song is a bounded list. Lay out its lines once instead
                    // of estimating and materializing rows during every scroll.
                    VStack(alignment: centered ? .center : .leading, spacing: 26) {
                        Color.clear.frame(height: verticalInset)
                        ForEach(lyrics.lines) { line in
                            bigLyricLine(line, isActive: line.id == activeIndex, centered: centered)
                                .id(line.id)
                        }
                        Color.clear.frame(height: verticalInset)
                    }
                    .padding(.horizontal, 24)
                }
                .mask(
                    LinearGradient(
                        stops: [
                            .init(color: .clear, location: 0),
                            .init(color: .black, location: 0.12),
                            .init(color: .black, location: 0.85),
                            .init(color: .clear, location: 1),
                        ],
                        startPoint: .top, endPoint: .bottom
                    )
                )
                .onChange(of: lyricsCursor.activeIndex) { index in
                    guard index != activeIndex else { return }
                    activeIndex = index
                    guard !isUserScrolling, let index else { return }
                    // A long spring keeps laying out the scroll view after the
                    // line is visually settled. Finish the motion promptly and
                    // skip unseen frames when another window covers the player.
                    withAnimation(windowVisibility.isVisible && !reduceMotion
                                  ? .easeOut(duration: 0.28) : nil) {
                        proxy.scrollTo(index, anchor: .center)
                    }
                }
                .onAppear {
                    // The cursor only fires on a line change, which can be many
                    // seconds away — on re-entering the page, adopt where the
                    // song already is instead of waiting for the next line.
                    adoptCursor(proxy: proxy)
                }
                .onChange(of: player.currentTrack?.id) { _ in
                    activeIndex = nil
                }
                .lyricsScrollTracking(isUserScrolling: $isUserScrolling)
            }
        } else if player.lyrics?.isInstrumental == true {
            VStack(spacing: 10) {
                Image(systemName: "music.quarternote.3")
                    .font(.system(size: 36, weight: .light))
                    .foregroundStyle(.white.opacity(0.4))
                Text("纯音乐，请欣赏")
                    .font(.system(size: 15))
                    .foregroundStyle(.white.opacity(0.6))
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
        } else if player.lyrics != nil {
            Text("暂无歌词")
                .foregroundStyle(.white.opacity(0.6))
                .frame(maxWidth: .infinity, maxHeight: .infinity)
        } else {
            ProgressView()
                .controlSize(.small)
                .tint(.white)
                .frame(maxWidth: .infinity, maxHeight: .infinity)
        }
    }

    private func bigLyricLine(_ line: LyricLine, isActive: Bool, centered: Bool) -> some View {
        Button {
            player.seek(to: line.time)
        } label: {
            VStack(alignment: centered ? .center : .leading, spacing: 5) {
                if settings.lyricsAnnotation == .romaji, let romaji = line.romaji {
                    Text(romaji)
                        .font(.system(size: 15, weight: .medium))
                        .foregroundStyle(.white.opacity(isActive ? 0.7 : 0.35))
                }
                LyricMainText(
                    line: line, isActive: isActive,
                    size: 26, weight: .bold,
                    verbatim: settings.verbatimLyrics,
                    alignment: centered ? .center : .left
                )
                if settings.showLyricsTranslation, let translation = line.translation {
                    Text(translation)
                        .font(.system(size: 16, weight: .medium))
                        .foregroundStyle(.white.opacity(isActive ? 0.7 : 0.35))
                }
            }
            .multilineTextAlignment(centered ? .center : .leading)
            .frame(maxWidth: .infinity, alignment: centered ? .center : .leading)
            .contentShape(Rectangle())
            // Reserve the highlighted line's geometry. Animating font size and
            // weight rebuilt glyph outlines and reflowed the list every frame.
            .scaleEffect(isActive ? 1.02 : 20.0 / 26.0, anchor: centered ? .center : .leading)
        }
        .buttonStyle(.plain)
        .animation(windowVisibility.isVisible && !reduceMotion
                   ? .easeOut(duration: 0.18) : nil, value: isActive)
    }
}

/// Resolve the glass against a dark appearance even when the app uses a light theme.
private struct TransparentPlaybackBackground: NSViewRepresentable {
    func makeNSView(context: Context) -> NSVisualEffectView {
        let view = NSVisualEffectView()
        view.material = .underWindowBackground
        view.blendingMode = .behindWindow
        view.state = .active
        view.appearance = NSAppearance(named: .darkAqua)
        return view
    }

    func updateNSView(_ view: NSVisualEffectView, context: Context) {}
}


/// The main lyric line. Renders karaoke-style per-character highlighting from
/// verbatim (`yrc`) timings, driven live by the player, when the line is active
/// and verbatim data exists; otherwise a plain line.
///
/// Whether the line carries furigana is `LyricText`'s decision; the wipe is
/// handed down as per-character opacity so it reads the same either way.
struct LyricMainText: View {
    let line: LyricLine
    let isActive: Bool
    let size: CGFloat
    let weight: Font.Weight
    let verbatim: Bool
    var alignment: NSTextAlignment = .left
    var inactiveOpacity: Double = 0.45

    @EnvironmentObject private var player: PlayerService
    @ObservedObject private var windowVisibility = MainWindowVisibility.shared

    var body: some View {
        if isActive, verbatim, let words = line.words, !words.isEmpty {
            // The wipe runs on a display link inside the host: a per-frame
            // SwiftUI value here re-measured the page's whole layout while a
            // verbatim line was up (see KaraokeLyricLine).
            KaraokeLyricLine(
                line: line,
                words: words,
                size: size,
                weight: weight,
                alignment: alignment,
                playing: player.isPlaying && windowVisibility.isVisible
            )
        } else {
            LyricText(
                line: line, size: size, weight: weight,
                color: .white.opacity(isActive ? 1 : inactiveOpacity),
                alignment: alignment
            )
        }
    }

    /// One opacity per character of `line.text`: sung characters are bright,
    /// the current one fades in, unsung stay dim.
    static func alphas(for line: LyricLine, words: [LyricWord], at time: TimeInterval) -> [Double] {
        let unsung = 0.28
        var out: [Double] = []
        for word in words {
            let chars = Array(word.text)
            let per = chars.isEmpty ? word.duration : word.duration / Double(chars.count)
            for index in chars.indices {
                let charStart = word.start + per * Double(index)
                let frac = per > 0 ? min(max((time - charStart) / per, 0), 1)
                                   : (time >= charStart ? 1 : 0)
                out.append(unsung + (1 - unsung) * frac)
            }
        }
        // `line.text` is the words joined and *then* trimmed, so drop the
        // opacities for whitespace the line no longer starts with.
        let joined = words.map(\.text).joined()
        guard joined.count != line.text.count else { return out }
        let leading = joined.count - joined.drop(while: \.isWhitespace).count
        return Array(out.dropFirst(leading).prefix(line.text.count))
    }
}



// MARK: - Mini lyrics (compact now-playing)

/// Three synced lyric lines (previous / current / next) filling the gap
/// between the track meta and the transport controls on compact layouts.
/// Tapping opens the full lyrics page.
struct MiniLyricsView: View {
    let onOpen: () -> Void

    @EnvironmentObject private var player: PlayerService
    @ObservedObject private var lyricsCursor = PlayerService.shared.lyricsCursor

    private var lines: (previous: LyricLine?, current: LyricLine?, next: LyricLine?) {
        guard let lyrics = player.lyrics, !lyrics.isEmpty else { return (nil, nil, nil) }
        guard let index = lyricsCursor.activeIndex else {
            return (nil, nil, lyrics.lines.first)
        }
        let all = lyrics.lines
        return (
            index > 0 ? all[index - 1] : nil,
            all[index],
            index + 1 < all.count ? all[index + 1] : nil
        )
    }

    var body: some View {
        let (previous, current, next) = lines
        Group {
            if current != nil || next != nil {
                VStack(spacing: 12) {
                    line(previous, emphasized: false)
                    line(current, emphasized: true)
                    line(next, emphasized: false)
                }
                .frame(maxWidth: .infinity, maxHeight: .infinity)
                .contentShape(Rectangle())
                .onTapGesture(perform: onOpen)
                .animation(.spring(response: 0.4, dampingFraction: 0.85), value: current?.id)
            } else {
                Color.clear
            }
        }
    }

    @ViewBuilder
    private func line(_ line: LyricLine?, emphasized: Bool) -> some View {
        Text(line?.text.isEmpty == false ? line!.text : " ")
            .font(.system(size: emphasized ? 17 : 14, weight: emphasized ? .bold : .medium))
            .foregroundStyle(.white.opacity(emphasized ? 1 : 0.45))
            .lineLimit(1)
            .multilineTextAlignment(.center)
            .padding(.horizontal, 28)
            .id(line?.id)
            .transition(.opacity.combined(with: .move(edge: .bottom)))
    }
}
