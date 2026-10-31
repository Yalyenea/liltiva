import Combine
import Foundation
import AppKit

/// Login state and the user's library: profile, liked track IDs, playlists.
@MainActor
final class AccountStore: ObservableObject {
    static let shared = AccountStore()

    @Published var profile: UserProfile?
    @Published var likedTrackIDs: Set<Int> = []
    @Published var userPlaylists: [PlaylistSummary] = []
    @Published var likedAlbums: [AlbumSummary] = []
    @Published var likedArtists: [ArtistSummary] = []
    @Published private(set) var hasLoadedLikedAlbums = false
    @Published private(set) var hasLoadedLikedArtists = false
    @Published private(set) var isRefreshingSublists = false
    @Published private(set) var sublistsError: String?
    @Published var isBootstrapped = false
    @Published private(set) var membership: MusicMembership?
    @Published private(set) var isRefreshingMembership = false
    @Published private(set) var membershipRefreshFailed = false

    var membershipTier: MusicMembershipTier {
        authenticatedAccountID == nil ? .free : membership?.tier() ?? .free
    }
    var availableAudioQualities: [AudioQuality] { AudioQuality.available(for: membershipTier) }
    var playbackQuality: AudioQuality {
        let selected = SettingsManager.shared.audioQuality
        return selected.requiredMembership <= membershipTier ? selected : .exhigh
    }

    var isLoggedIn: Bool { NeteaseClient.shared.isLoggedIn && profile != nil }
    var hasAuthCookie: Bool { NeteaseClient.shared.isLoggedIn }
    var authenticatedAccountID: Int? {
        guard isLoggedIn, profileBinding == NeteaseClient.shared.authenticationFingerprint else { return nil }
        return profile?.userId
    }
    var vipType: Int { profile?.vipType ?? 0 }
    var socialSession: String? {
        authenticatedAccountID == nil ? nil : NeteaseClient.shared.authenticationFingerprint
    }
    var offlineScope: String? {
        guard hasAuthCookie else { return "guest" }
        guard profileBinding == NeteaseClient.shared.authenticationFingerprint else { return nil }
        return profile.map { "netease:\($0.userId)" }
    }
    private var profileBinding: String?
    private var bootstrapGeneration = 0
    private var playlistSyncTask: Task<Void, Never>?
    private var playlistSyncID = UUID()
    private var networkObserver: AnyCancellable?
    private var activationObserver: AnyCancellable?
    private var membershipRequestID = UUID()
    private var sublistsTask: Task<Void, Never>?
    private var sublistsRequestID = UUID()
    private var sublistsScope: String?
    private var sublistsSession: String?

    var likedSongsPlaylist: PlaylistSummary? {
        userPlaylists.first(where: \.isLikedSongsList) ?? userPlaylists.first
    }

    var createdPlaylists: [PlaylistSummary] {
        guard let uid = profile?.userId else { return [] }
        return userPlaylists.filter { $0.creator?.userId == uid && !$0.isLikedSongsList }
    }

    var subscribedPlaylists: [PlaylistSummary] {
        guard let uid = profile?.userId else { return [] }
        return userPlaylists.filter { $0.creator?.userId != uid }
    }

    private init() {
        if let snapshot = AccountSnapshotStorage.shared.load(fingerprint: NeteaseClient.shared.authenticationFingerprint) {
            profile = snapshot.profile
            likedTrackIDs = snapshot.likedTrackIDs
            userPlaylists = snapshot.playlists
            profileBinding = snapshot.authenticationFingerprint
            membership = snapshot.membership
            likedAlbums = snapshot.likedAlbums ?? []
            likedArtists = snapshot.likedArtists ?? []
            hasLoadedLikedAlbums = snapshot.likedAlbums != nil
            hasLoadedLikedArtists = snapshot.likedArtists != nil
        }
    }

    /// Called at launch and after login succeeds.
    func bootstrap() async {
        observeLibraryNetwork()
        bootstrapGeneration += 1
        let generation = bootstrapGeneration
        defer { if generation == bootstrapGeneration { isBootstrapped = true } }
        guard hasAuthCookie else { applyProfile(nil, binding: nil); return }
        if profileBinding != NeteaseClient.shared.authenticationFingerprint { applyProfile(nil, binding: nil) }
        await refreshCookieIfNeeded()
        guard generation == bootstrapGeneration, let binding = NeteaseClient.shared.authenticationFingerprint else { return }
        if profileBinding != binding { applyProfile(nil, binding: nil) }
        do {
            let fetched = try await NeteaseAPI.userAccount()
            guard generation == bootstrapGeneration, binding == NeteaseClient.shared.authenticationFingerprint else { return }
            applyProfile(fetched, binding: binding)
            saveSnapshot()
        } catch {
            return
        }
        await refreshLibrary()
    }

    func refreshLibrary() async {
        guard let uid = profile?.userId else { return }
        async let refreshedMembership: Void = refreshMembership()
        async let refreshedSublists: Void = refreshSublists()
        async let playlists = try? NeteaseAPI.userPlaylists(uid: uid)
        async let liked = try? NeteaseAPI.likedTrackIDs(uid: uid)
        let (fetchedPlaylists, fetchedLiked) = await (playlists, liked)
        await refreshedMembership
        await refreshedSublists
        guard profile?.userId == uid, profileBinding == NeteaseClient.shared.authenticationFingerprint else { return }
        userPlaylists = fetchedPlaylists ?? userPlaylists
        if let ids = fetchedLiked { likedTrackIDs = Set(ids) }
        saveSnapshot()
        syncPlaylistContents()
    }

    func refreshMembership() async {
        guard let uid = authenticatedAccountID, !isRefreshingMembership else { return }
        let binding = profileBinding
        let requestID = UUID()
        membershipRequestID = requestID
        isRefreshingMembership = true
        defer { if membershipRequestID == requestID { isRefreshingMembership = false } }
        do {
            let fetched = try await NeteaseAPI.membership()
            guard membershipRequestID == requestID, authenticatedAccountID == uid,
                  binding == profileBinding else { return }
            membership = fetched
            membershipRefreshFailed = false
            saveSnapshot()
            let selected = SettingsManager.shared.audioQuality
            if selected.requiredMembership > fetched.tier() {
                PlayerService.shared.setAudioQuality(.exhigh)
                ToastCenter.shared.show(String(localized: "会员权益已更新，播放音质已调整为极高"))
            }
        } catch {
            guard membershipRequestID == requestID, authenticatedAccountID == uid,
                  binding == profileBinding else { return }
            membershipRefreshFailed = true
        }
    }

    private func observeLibraryNetwork() {
        guard networkObserver == nil else { return }
        activationObserver = NotificationCenter.default.publisher(for: NSApplication.didBecomeActiveNotification)
            .receive(on: DispatchQueue.main)
            .sink { [weak self] _ in Task { await self?.refreshMembership() } }
        networkObserver = DownloadManager.shared.$network.map(\.connected).removeDuplicates().dropFirst()
            .receive(on: DispatchQueue.main)
            .sink { [weak self] connected in
                guard let self else { return }
                if connected { Task { await self.refreshLibrary() } }
                else { self.cancelPlaylistSync() }
            }
    }

    private func cancelPlaylistSync() {
        playlistSyncID = UUID()
        playlistSyncTask?.cancel()
        playlistSyncTask = nil
    }

    private func syncPlaylistContents() {
        guard playlistSyncTask == nil, let scope = offlineScope, profile != nil else { return }
        let ticket = UUID()
        playlistSyncID = ticket
        let playlists = userPlaylists.sorted { $0.isLikedSongsList && !$1.isLikedSongsList }
        playlistSyncTask = Task(priority: .utility) { [weak self] in
            defer { if self?.playlistSyncID == ticket { self?.playlistSyncTask = nil } }
            for playlist in playlists {
                guard !Task.isCancelled, self?.offlineScope == scope else { return }
                let network = DownloadManager.shared.network
                guard !network.isKnown || network.connected else { return }
                let model = PlaylistContent(playlistID: playlist.id)
                await model.load(summary: playlist, background: true)
            }
        }
    }

    func refreshSublists(force: Bool = false) async {
        guard let scope = offlineScope, let session = socialSession else { return }
        if !force, sublistsScope == scope, sublistsSession == session, let sublistsTask {
            await sublistsTask.value
            return
        }
        sublistsTask?.cancel()
        let requestID = UUID()
        sublistsRequestID = requestID
        sublistsScope = scope
        sublistsSession = session
        isRefreshingSublists = true
        sublistsError = nil
        let task = Task { [weak self] in
            guard let self else { return }
            await self.loadSublists(scope: scope, session: session, requestID: requestID, force: force)
        }
        sublistsTask = task
        await task.value
    }

    private func loadSublists(scope: String, session: String, requestID: UUID, force: Bool) async {
        defer {
            if sublistsRequestID == requestID {
                isRefreshingSublists = false
                sublistsTask = nil
            }
        }
        let cache = PageDataCache.shared
        let cachedAlbums = await cache.load([AlbumSummary].self, key: "liked-albums", scope: scope)
        let cachedArtists = await cache.load([ArtistSummary].self, key: "liked-artists", scope: scope)
        guard sublistsAreCurrent(scope: scope, session: session, requestID: requestID) else { return }
        if let cachedAlbums {
            likedAlbums = cachedAlbums.value
            hasLoadedLikedAlbums = true
        }
        if let cachedArtists {
            likedArtists = cachedArtists.value
            hasLoadedLikedArtists = true
        }
        if force {
            // Invalidate the cache revision before starting new reads after a mutation.
            for key in ["liked-albums", "liked-artists"] {
                do { try await cache.remove(key: key, scope: scope) }
                catch {
                    guard sublistsAreCurrent(scope: scope, session: session, requestID: requestID) else { return }
                    sublistsError = error.localizedDescription
                }
            }
        }
        guard sublistsAreCurrent(scope: scope, session: session, requestID: requestID) else { return }
        async let albums = cache.fetch([AlbumSummary].self, key: "liked-albums", scope: scope,
                                       maxAge: 300, force: force, session: session) {
            guard self.offlineScope == scope, self.socialSession == session else { throw CancellationError() }
            let value = try await NeteaseAPI.likedAlbums()
            guard self.offlineScope == scope, self.socialSession == session else { throw CancellationError() }
            return value
        }
        async let artists = cache.fetch([ArtistSummary].self, key: "liked-artists", scope: scope,
                                        maxAge: 300, force: force, session: session) {
            guard self.offlineScope == scope, self.socialSession == session else { throw CancellationError() }
            let value = try await NeteaseAPI.likedArtists()
            guard self.offlineScope == scope, self.socialSession == session else { throw CancellationError() }
            return value
        }
        do {
            let value = try await albums
            guard sublistsAreCurrent(scope: scope, session: session, requestID: requestID) else { return }
            likedAlbums = value
            hasLoadedLikedAlbums = true
        } catch {
            guard sublistsAreCurrent(scope: scope, session: session, requestID: requestID) else { return }
            sublistsError = error.localizedDescription
        }
        do {
            let value = try await artists
            guard sublistsAreCurrent(scope: scope, session: session, requestID: requestID) else { return }
            likedArtists = value
            hasLoadedLikedArtists = true
        } catch {
            guard sublistsAreCurrent(scope: scope, session: session, requestID: requestID) else { return }
            sublistsError = error.localizedDescription
        }
        saveSnapshot()
    }

    private func sublistsAreCurrent(scope: String, session: String, requestID: UUID) -> Bool {
        !Task.isCancelled && sublistsRequestID == requestID && offlineScope == scope && socialSession == session
    }

    func isLiked(_ trackID: Int) -> Bool {
        likedTrackIDs.contains(trackID)
    }

    func toggleLike(trackID: Int) async {
        guard isLoggedIn else {
            ToastCenter.shared.show(String(localized: "登录后即可收藏歌曲"))
            return
        }
        let like = !likedTrackIDs.contains(trackID)
        let scope = offlineScope
        // Optimistic update
        if like { likedTrackIDs.insert(trackID) } else { likedTrackIDs.remove(trackID) }
        do {
            try await NeteaseAPI.likeTrack(id: trackID, like: like)
        } catch {
            guard scope == offlineScope else { return }
            if like { likedTrackIDs.remove(trackID) } else { likedTrackIDs.insert(trackID) }
            ToastCenter.shared.show(error.localizedDescription)
        }
        guard scope == offlineScope else { return }
        saveSnapshot()
        NowPlayingManager.shared.refreshLikeState()
    }

    /// Revoke by default. A login another device still offers is kept alive
    /// for it; sync still withdraws this device's record after sign-out.
    func logout() async throws {
        let cookies = NeteaseClient.shared.authenticationCookies()
        let revokeSession = SyncService.shared.shouldRevokeLoginSession(accountID: authenticatedAccountID)
        try NeteaseClient.shared.clearAuthCookies()
        bootstrapGeneration += 1
        AccountSnapshotStorage.shared.clear()
        applyProfile(nil, binding: nil)
        if revokeSession { try await NeteaseAPI.logout(detachedCookies: cookies) }
    }

    /// Verify a received session in isolation. A failed or superseded import must
    /// leave the current device's cookies, profile and library intact.
    func importLogin(accountID: Int, cookies: [String: String], authorization: () -> Bool) async throws {
        guard accountID > 0, cookies["MUSIC_U"]?.isEmpty == false else { throw SyncError.invalidRecord }
        guard authorization() else { throw CancellationError() }
        let generation = bootstrapGeneration
        let binding = NeteaseClient.shared.authenticationFingerprint
        let candidate = NeteaseClient(configuration: .ephemeral, persistsCookies: false)
        candidate.setCookies(cookies)
        guard let verified = try await NeteaseAPI.userAccount(using: candidate),
              verified.userId == accountID else { throw NeteaseAPIError.needLogin }
        guard authorization(), generation == bootstrapGeneration,
              binding == NeteaseClient.shared.authenticationFingerprint else { throw CancellationError() }
        try NeteaseClient.shared.replaceAuthentication(with: candidate.authenticationCookies())
        bootstrapGeneration += 1
        PlayerService.shared.suspendForAccountChange()
        UserDefaults.standard.removeObject(forKey: "auth.lastCookieRefresh")
        applyProfile(verified, binding: NeteaseClient.shared.authenticationFingerprint)
        saveSnapshot()
    }

    private func applyProfile(_ value: UserProfile?, binding: String?) {
        let oldID = profile?.userId
        let changedSession = profileBinding != binding
        profile = value
        profileBinding = binding
        if oldID != value?.userId || changedSession {
            membershipRequestID = UUID()
            membership = nil
            isRefreshingMembership = false
            membershipRefreshFailed = false
            cancelPlaylistSync()
            likedTrackIDs = []
            userPlaylists = []
            likedAlbums = []
            likedArtists = []
            sublistsRequestID = UUID()
            sublistsTask?.cancel()
            sublistsTask = nil
            sublistsScope = nil
            sublistsSession = nil
            hasLoadedLikedAlbums = false
            hasLoadedLikedArtists = false
            isRefreshingSublists = false
            sublistsError = nil
            PlayerService.shared.activateAccount(scope: offlineScope)
            CloudContent.shared.activateAccount(scope: authenticatedAccountID.map { "netease:\($0)" }, session: socialSession)
        }
        DownloadManager.shared.activate(accountScope: offlineScope)
    }

    private func saveSnapshot() {
        guard let profile, let binding = profileBinding, binding == NeteaseClient.shared.authenticationFingerprint else { return }
        try? AccountSnapshotStorage.shared.save(.init(authenticationFingerprint: binding, profile: profile,
                                                      likedTrackIDs: likedTrackIDs, playlists: userPlaylists,
                                                      savedAt: Date(), membership: membership,
                                                      likedAlbums: hasLoadedLikedAlbums ? likedAlbums : nil,
                                                      likedArtists: hasLoadedLikedArtists ? likedArtists : nil))
    }

    /// Refresh the login cookie at most once per calendar day.
    private func refreshCookieIfNeeded() async {
        let key = "auth.lastCookieRefresh"
        let today = Calendar.current.startOfDay(for: .now).timeIntervalSince1970
        guard UserDefaults.standard.double(forKey: key) < today else { return }
        UserDefaults.standard.set(today, forKey: key)
        await NeteaseAPI.refreshLogin()
    }
}

// MARK: - Toasts

struct Toast: Identifiable, Equatable {
    let id = UUID()
    let message: String
}

@MainActor
final class ToastCenter: ObservableObject {
    static let shared = ToastCenter()

    @Published var current: Toast?
    private var dismissTask: Task<Void, Never>?

    private init() {}

    func show(_ message: String) {
        current = Toast(message: message)
        dismissTask?.cancel()
        dismissTask = Task {
            try? await Task.sleep(for: .seconds(3))
            guard !Task.isCancelled else { return }
            current = nil
        }
    }
}
