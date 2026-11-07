import SwiftUI

struct PlayerBar: View {
    @Binding var showsVolume: Bool
    @EnvironmentObject private var player: PlayerService
    @EnvironmentObject private var settings: SettingsManager
    @EnvironmentObject private var account: AccountStore
    @ObservedObject private var shortcuts = ShortcutManager.shared
    @Environment(\.openLogin) private var openLogin
    @State private var showsSoundEffects = false

    var body: some View {
        GeometryReader { proxy in
            let compact = proxy.size.width < 640
            let diameter: CGFloat = compact ? 26 : 32
            let gap: CGFloat = compact ? 6 : 10
            let transportWidth = diameter * 4 + 36 + gap * 4
            let sideWidth = min(280, max(0, (proxy.size.width - transportWidth) / 2 - 20))

            // Reserve equal side regions around the transport. Even the
            // narrow layout keeps every action visible and Play centred.
            ZStack {
                HStack(spacing: 0) {
                    songInfoSection(compact: compact, diameter: diameter)
                        .trackSwipeContent(scale: 0.4)
                        .frame(width: sideWidth, alignment: .leading)
                        .clipped()
                    Spacer(minLength: 0)
                    optionsSection(compact: compact, diameter: diameter,
                                   showsQualityTitle: proxy.size.width >= 1000)
                        .frame(width: sideWidth, alignment: .trailing)
                }
                .padding(.horizontal, 12)
                transportControls(diameter: diameter, gap: gap)
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
        }
        .frame(height: Theme.Layout.playerBarHeight)
        .trackSwipeNavigation()
        .background {
            if !player.showNowPlaying {
                Platform.windowBackgroundColor
            }
        }
        .background {
            if player.hasCurrentTrack {
                NowPlayingSwipeGesture(direction: .both) {
                    withAnimation(AppAnimation.smooth) { player.showNowPlaying.toggle() }
                }
            }
        }
        .overlay(alignment: .top) { ScrubberLane().offset(y: -7) }
    }

    private func songInfoSection(compact: Bool, diameter: CGFloat) -> some View {
        HStack(spacing: compact ? 5 : 8) {
            artworkButton(size: compact ? 32 : 40)
            VStack(alignment: .leading, spacing: 2) {
                MarqueeText(text: player.currentTrack?.name ?? String(localized: "未在播放"))
                    .frame(height: 17)
                    .help(player.currentTrack?.name ?? String(localized: "未在播放"))
                Text(player.currentTrack?.artistNames ?? "Liltiva")
                    .font(.system(size: 11))
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
                    .help(player.currentTrack?.artistNames ?? "Liltiva")
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            if let track = player.currentTrack {
                LikeButton(trackID: track.id, size: compact ? 14 : 16, diameter: diameter)
            }
        }
    }

    private func artworkButton(size: CGFloat) -> some View {
        Button {
            guard player.hasCurrentTrack else { return }
            withAnimation(AppAnimation.smooth) { player.showNowPlaying.toggle() }
        } label: {
            CachedAsyncImage(url: player.currentTrack?.album.picUrl?.resizedImageURL(128))
                .frame(width: size, height: size)
                .clipShape(Circle())
                .overlay { Circle().strokeBorder(.primary.opacity(0.1), lineWidth: 0.5) }
        }
        .buttonStyle(.pressable)
        .noFocusRing()
        .help("正在播放")
        .accessibilityLabel(player.showNowPlaying ? "收起播放页" : "打开播放页")
    }

    private func transportControls(diameter: CGFloat, gap: CGFloat) -> some View {
        HStack(spacing: gap) {
            PlaybackModeButton(mode: player.playbackMode, isFMMode: player.isFMMode,
                               diameter: diameter) { player.cyclePlaybackMode() }

            PlayerIconButton(icon: player.isFMMode ? "trash" : "backward.end.fill",
                             size: 17, diameter: diameter) {
                if player.isFMMode { player.fmTrash() } else { player.previous() }
            }
            .help(player.isFMMode ? "不喜欢，换一首" : "上一首")
            .accessibilityLabel(player.isFMMode ? "不喜欢，换一首" : "上一首")

            playPauseButton

            PlayerIconButton(icon: "forward.end.fill", size: 17, diameter: diameter) {
                player.next()
            }
            .help("下一首")
            .accessibilityLabel("下一首")

            PlayerIconButton(icon: "list.bullet", size: 16, diameter: diameter,
                             isActive: player.activePanel == .queue, disabled: player.isFMMode) {
                player.activePanel = player.activePanel == .queue ? nil : .queue
            }
            .controlHint(String(localized: "播放队列"))
            .accessibilityLabel("播放队列")
        }
        .disabled(!player.hasCurrentTrack)
    }

    private var playPauseButton: some View {
        Button { player.togglePlayPause() } label: {
            ZStack {
                Circle().fill(Theme.accent).frame(width: 36, height: 36)
                if player.isBuffering && player.isPlaying {
                    ProgressView().controlSize(.small).tint(.white).scaleEffect(0.8)
                } else {
                    Image(systemName: player.isPlaying ? "pause.fill" : "play.fill")
                        .font(.system(size: 16, weight: .semibold))
                        .foregroundStyle(.white)
                        .offset(x: player.isPlaying ? 0 : 1)
                        .contentTransition(.opacity)
                }
            }
        }
        .buttonStyle(.pressable)
        .accessibilityLabel(player.isPlaying ? "暂停" : "播放")
    }

    private func optionsSection(compact: Bool, diameter: CGFloat, showsQualityTitle: Bool) -> some View {
        HStack(spacing: compact ? 1 : 6) {
            PlayerIconButton(icon: "text.bubble", size: 14, diameter: diameter,
                             isActive: player.activePanel == .comments, disabled: !player.hasCurrentTrack) {
                shortcuts.executeAction(.toggleComments)
            }
            .controlHint(commentsHint)
            .accessibilityLabel("评论")
            .accessibilityIdentifier("track-comments-button")
            qualityMenu(showsTitle: showsQualityTitle, diameter: diameter)
            soundEffectButton(diameter: diameter)
            PlayerIconButton(icon: "inset.filled.bottomthird.square", size: 16,
                             diameter: diameter, isActive: settings.showDesktopLyrics) {
                settings.showDesktopLyrics.toggle()
            }
            .controlHint(String(localized: "桌面歌词"))
            .accessibilityLabel("桌面歌词")
            RoutePickerButton(diameter: diameter, glyphSize: 16,
                              tint: .primary, background: .clear)
            VolumeControl(diameter: diameter, showsVolume: $showsVolume)
        }
    }

    private var commentsHint: String {
        let title = String(localized: "评论")
        let shortcut = shortcuts.shortcut(for: .toggleComments)
        return shortcut.key.isEmpty ? title : "\(title) (\(shortcut.displayString))"
    }

    private func qualityMenu(showsTitle: Bool, diameter: CGFloat) -> some View {
        let currentQuality = player.servedQuality.flatMap(AudioQuality.init) ?? account.playbackQuality
        return Menu {
            Picker("播放音质", selection: Binding(
                get: { account.playbackQuality },
                set: { player.setAudioQuality($0) }
            )) {
                ForEach(account.availableAudioQualities) { quality in
                    Text(quality.displayName).tag(quality)
                }
            }
            .pickerStyle(.inline)
            Divider()
            Text(account.membershipTier.displayName)
            if account.membershipRefreshFailed {
                Button("重试会员信息") { Task { await account.refreshMembership() } }
            }
            if let level = player.servedQuality, let quality = AudioQuality(rawValue: level) {
                Divider()
                Text("当前音质：\(quality.displayName)")
            }
        } label: {
            Group {
                if showsTitle {
                    QualityTag(text: currentQuality.displayName)
                } else {
                    Image(systemName: "waveform")
                        .font(.system(size: 14, weight: .medium))
                        .frame(width: diameter)
                }
            }
            .frame(height: diameter)
            .contentShape(Rectangle())
        }
        .menuStyle(.borderlessButton)
        .menuIndicator(.hidden)
        .fixedSize()
        .controlHint(currentQuality.displayName)
        .accessibilityLabel("播放音质")
        .accessibilityValue(currentQuality.displayName)
    }

    private func soundEffectButton(diameter: CGFloat) -> some View {
        Button { showsSoundEffects.toggle() } label: {
            Label("音效", systemImage: "slider.horizontal.3")
                .labelStyle(.iconOnly)
                .font(.system(size: 14, weight: .medium))
                .foregroundStyle(settings.soundEffectMode == .off ? Color.primary : Theme.accent)
                .frame(width: diameter, height: diameter)
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .fixedSize()
        .controlHint(player.selectedSoundEffectName)
        .accessibilityLabel("音效")
        .accessibilityIdentifier("sound-effect-menu")
        .accessibilityValue(player.selectedSoundEffectName)
        .popover(isPresented: $showsSoundEffects, arrowEdge: .top) {
            ScrollView {
                SoundEffectPanel(onLogin: {
                    showsSoundEffects = false
                    openLogin()
                }).padding(20)
            }
            .frame(width: 390, height: 530)
        }
    }
}

/// Keep mode changes and their short feedback anchored to the same button.
private struct PlaybackModeButton: View {
    let mode: PlaybackMode
    let isFMMode: Bool
    let diameter: CGFloat
    let action: () -> Void
    @State private var isHovering = false
    @State private var isShowingMode = false
    @State private var feedbackTask: Task<Void, Never>?

    var body: some View {
        Button(action: action) {
            Group {
                if isFMMode || mode == .shuffled {
                    Image(systemName: isFMMode ? "wave.3.right" : (mode == .shuffled ? "shuffle" : "wand.and.stars"))
                        .font(.system(size: 16, weight: .medium))
                } else {
                    arrows.stroke(style: StrokeStyle(lineWidth: 1.5, lineCap: .round, lineJoin: .round))
                }
            }
            .frame(width: 18, height: 18)
            .foregroundStyle(.primary)
            .frame(width: diameter, height: diameter)
            .background(.primary.opacity(isHovering ? 0.08 : 0),
                        in: RoundedRectangle(cornerRadius: 7))
            .contentShape(Rectangle())
        }
        .buttonStyle(.pressable)
        .noFocusRing()
        .disabled(isFMMode)
        .opacity(isFMMode ? 0.35 : 1)
        .onHover { isHovering = $0 }
        .animation(AppAnimation.quick, value: isHovering)
        .accessibilityLabel(isFMMode ? String(localized: "私人漫游中") : mode.displayName)
        .controlHint(mode.displayName, isPresented: isShowingMode)
        .onChange(of: mode) { _ in
            feedbackTask?.cancel()
            isShowingMode = true
            feedbackTask = Task { @MainActor in
                try? await Task.sleep(for: .milliseconds(1500))
                guard !Task.isCancelled else { return }
                isShowingMode = false
            }
        }
        .onDisappear {
            feedbackTask?.cancel()
            isShowingMode = false
        }
    }

    private var arrows: Path {
        Path { path in
            switch mode {
            case .ordered:
                for row in [CGFloat(5), CGFloat(13)] {
                    path.move(to: CGPoint(x: 2, y: row))
                    path.addLine(to: CGPoint(x: 16, y: row))
                    path.move(to: CGPoint(x: 13, y: row - 3))
                    path.addLine(to: CGPoint(x: 16, y: row))
                    path.addLine(to: CGPoint(x: 13, y: row + 3))
                }
            case .repeatOne:
                path.move(to: CGPoint(x: 2, y: 7))
                path.addQuadCurve(to: CGPoint(x: 5, y: 4), control: CGPoint(x: 2, y: 4))
                path.addLine(to: CGPoint(x: 16, y: 4))
                path.move(to: CGPoint(x: 13, y: 1))
                path.addLine(to: CGPoint(x: 16, y: 4))
                path.addLine(to: CGPoint(x: 13, y: 7))
                path.move(to: CGPoint(x: 16, y: 11))
                path.addQuadCurve(to: CGPoint(x: 13, y: 14), control: CGPoint(x: 16, y: 14))
                path.addLine(to: CGPoint(x: 2, y: 14))
                path.move(to: CGPoint(x: 5, y: 11))
                path.addLine(to: CGPoint(x: 2, y: 14))
                path.addLine(to: CGPoint(x: 5, y: 17))
                path.move(to: CGPoint(x: 8, y: 8))
                path.addLine(to: CGPoint(x: 9.5, y: 6.5))
                path.addLine(to: CGPoint(x: 9.5, y: 11.5))
                path.move(to: CGPoint(x: 8, y: 11.5))
                path.addLine(to: CGPoint(x: 11, y: 11.5))
            case .shuffled:
                break // These modes use their system symbols above.
            }
        }
    }
}

// MARK: - Icon button

struct PlayerIconButton: View {
    let icon: String
    var size: CGFloat = 14
    var diameter: CGFloat = 32
    var isActive = false
    var disabled = false
    let action: () -> Void

    @State private var isHovering = false
    @Environment(\.colorScheme) private var colorScheme

    var body: some View {
        Button(action: action) {
            Image(systemName: icon)
                .font(.system(size: size, weight: .medium))
                .foregroundStyle(isActive ? AnyShapeStyle(Theme.accent) : AnyShapeStyle(.primary))
                .frame(width: diameter, height: diameter)
                .background(
                    RoundedRectangle(cornerRadius: 7, style: .continuous)
                        .fill(backgroundColor)
                )
                .contentShape(Rectangle())
        }
        .buttonStyle(.pressable)
        .noFocusRing()
        .disabled(disabled)
        .opacity(disabled ? 0.35 : 1)
        .onHover { isHovering = $0 }
        .animation(AppAnimation.quick, value: isHovering)
    }

    private var backgroundColor: Color {
        let base: Color = colorScheme == .dark ? .white : .black
        if isHovering, !disabled { return base.opacity(0.08) }
        return .clear
    }
}

// MARK: - Like button

struct LikeButton: View {
    let trackID: Int
    var size: CGFloat = 13
    var diameter: CGFloat = 32

    @EnvironmentObject private var account: AccountStore

    var body: some View {
        let liked = account.isLiked(trackID)
        PlayerIconButton(
            icon: liked ? "heart.fill" : "heart", size: size, diameter: diameter,
            isActive: liked
        ) {
            Task { await account.toggleLike(trackID: trackID) }
        }
        .accessibilityLabel(liked ? "取消喜欢" : "喜欢")
    }
}

// MARK: - Scrubber

struct ScrubberLane: View {
    @EnvironmentObject private var player: PlayerService
    @ObservedObject private var clock = PlayerService.shared.clock
    @Environment(\.colorScheme) private var colorScheme

    @State private var hoverFraction: Double?
    @State private var isDragging = false
    @State private var dragProgress: Double = 0

    private var isHovering: Bool { hoverFraction != nil }

    private var fraction: Double {
        guard player.duration > 0 else { return 0 }
        let value = isDragging ? dragProgress : clock.progress
        return min(max(value / player.duration, 0), 1)
    }

    var body: some View {
        track
        .frame(maxWidth: .infinity)
        .accessibilityElement(children: .ignore)
        .accessibilityLabel("播放进度")
        .accessibilityValue("\(Formatters.duration(isDragging ? dragProgress : clock.progress)) / \(Formatters.duration(player.duration))")
        .accessibilityAdjustableAction { direction in
            guard player.duration > 0 else { return }
            switch direction {
            case .increment: player.seek(to: min(player.duration, clock.progress + 5))
            case .decrement: player.seek(to: max(0, clock.progress - 5))
            @unknown default: break
            }
        }
        .onDisappear {
            hoverFraction = nil
            // Releasing the view mid-drag must also release the audio clock.
            if isDragging {
                isDragging = false
                player.isScrubbing = false
            }
        }
    }

    private var track: some View {
        GeometryReader { geo in
            let width = geo.size.width
            let previewFraction = isDragging ? fraction : (hoverFraction ?? fraction)
            ZStack(alignment: .leading) {
                Capsule()
                    .fill(colorScheme == .dark ? Color.white.opacity(0.18) : .black.opacity(0.15))
                    .frame(height: isHovering || isDragging ? 4 : 3)
                Capsule()
                    .fill(Theme.accent)
                    .frame(width: width * fraction, height: isHovering || isDragging ? 4 : 3)
                Circle()
                    .fill(.white)
                    .frame(width: thumbDiameter, height: thumbDiameter)
                    .shadow(color: .black.opacity(0.25), radius: 1.5, y: 0.5)
                    .offset(x: max(0, min(width - thumbDiameter, width * fraction - thumbDiameter / 2)))
                    .opacity(isHovering || isDragging ? 1 : 0)
            }
            .frame(maxHeight: .infinity)
            .overlay(alignment: .topLeading) {
                if (isHovering || isDragging), player.duration > 0 {
                    Text("\(Formatters.duration(previewFraction * player.duration)) / \(Formatters.duration(player.duration))")
                        .font(.system(size: 11).monospacedDigit())
                        .foregroundStyle(.primary)
                        .fixedSize()
                        .padding(.horizontal, 8)
                        .frame(height: 26)
                        .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 6))
                        .visualEffect { content, layout in
                            let previewWidth = layout.size.width
                            // Keep the fitted label centred on the pointer and inside the lane.
                            return content.offset(
                                x: max(4, min(width - previewWidth - 4, width * previewFraction - previewWidth / 2)),
                                y: -30
                            )
                        }
                        .allowsHitTesting(false)
                }
            }
            .contentShape(Rectangle())
            .gesture(
                DragGesture(minimumDistance: 0)
                    .onChanged { value in
                        guard player.duration > 0, width > 0 else { return }
                        isDragging = true
                        player.isScrubbing = true
                        dragProgress = min(max(value.location.x / width, 0), 1) * player.duration
                    }
                    .onEnded { _ in
                        guard isDragging else { return }
                        player.seek(to: dragProgress)
                        isDragging = false
                        player.isScrubbing = false
                    }
            )
            .onContinuousHover { phase in
                switch phase {
                case .active(let location):
                    guard width > 0 else { return }
                    // Preview the pointer's time without moving playback;
                    // seeking remains exclusive to a click or drag.
                    hoverFraction = min(max(location.x / width, 0), 1)
                case .ended:
                    hoverFraction = nil
                }
            }
        }
        .frame(height: 14)
        .animation(AppAnimation.quick, value: isHovering)
        .animation(.spring(response: 0.24, dampingFraction: 0.72), value: isDragging)
    }

    private var thumbDiameter: CGFloat {
        isDragging ? 12 : (isHovering ? 10 : 8)
    }
}

// MARK: - Vertical volume

struct VolumeControl: View {
    var diameter: CGFloat = 32
    var isExpanded = false
    @Binding var showsVolume: Bool
    @EnvironmentObject private var player: PlayerService
    @State private var dragStartVolume: Float?

    var body: some View {
        VStack(spacing: 4) {
            if isExpanded { verticalVolume }
            if showsVolume && !isExpanded {
                Color.clear.frame(width: diameter, height: diameter)
            } else {
                PlayerIconButton(icon: volumeIcon, size: 16, diameter: diameter) {
                    showsVolume.toggle()
                }
                .controlHint(String(localized: "音量"), isPresented: showsVolume ? false : nil)
                .accessibilityLabel("音量")
                .accessibilityValue("\(Int(player.volume * 100))%")
                .accessibilityIdentifier("volume-button")
                .gesture(volumeDrag)
            }
        }
        .fixedSize()
        .background {
            if !isExpanded {
                GeometryReader { proxy in
                    Color.clear.preference(key: VolumeSwipeBoundsKey.self,
                                           value: proxy.frame(in: .named(VolumeSwipeBoundsKey.coordinateSpace)))
                }
            }
        }
    }

    private var verticalVolume: some View {
        GeometryReader { geo in
            let travel = geo.size.height - 10
            ZStack(alignment: .bottom) {
                Capsule().fill(.primary.opacity(0.18))
                Capsule().fill(.primary.opacity(0.8))
                    .frame(height: travel * CGFloat(player.volume))
            }
            .frame(width: 4, height: travel)
            .overlay(alignment: .bottom) {
                Circle().fill(.primary).frame(width: 8, height: 8)
                    .offset(y: 4 - travel * CGFloat(player.volume))
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
            .contentShape(Rectangle())
            .gesture(DragGesture(minimumDistance: 0)
                .onChanged { value in
                    player.volume = Float(min(max(1 - (value.location.y - 5) / travel, 0), 1))
                })
        }
        .frame(width: diameter, height: 96)
        .padding(.vertical, 4)
        .background(.regularMaterial, in: Capsule())
        .accessibilityElement(children: .ignore)
        .accessibilityLabel("音量")
        .accessibilityValue("\(Int(player.volume * 100))%")
        .accessibilityIdentifier("volume-slider")
        .accessibilityAdjustableAction { direction in
            switch direction {
            case .increment: player.volume = min(1, player.volume + 0.05)
            case .decrement: player.volume = max(0, player.volume - 0.05)
            @unknown default: break
            }
        }
    }

    private var volumeDrag: some Gesture {
        // The vertical slider sets volume directly; sliding the icon adjusts it
        // relatively so revealing the control never makes the volume jump.
        DragGesture(minimumDistance: 20)
            .onChanged { value in
                guard abs(value.translation.width) > abs(value.translation.height) * 1.5 else { return }
                if dragStartVolume == nil { dragStartVolume = player.volume }
                if let dragStartVolume {
                    player.volume = Self.volume(afterSliding: value.translation.width, from: dragStartVolume)
                }
            }
            .onEnded { _ in dragStartVolume = nil }
    }

    static func volume(afterSliding distance: CGFloat, from volume: Float) -> Float {
        min(max(volume + Float(distance / 240), 0), 1)
    }

    private var volumeIcon: String {
        switch player.volume {
        case 0: return "speaker.slash"
        case ..<0.4: return "speaker.wave.1"
        case ..<0.75: return "speaker.wave.2"
        default: return "speaker.wave.3"
        }
    }
}
