import SwiftUI

/// 我的歌单 — playlists created by the signed-in user.
struct CreatedPlaylistsView: View {
    @EnvironmentObject private var account: AccountStore
    @State private var showNewPlaylist = false
    @State private var newPlaylistName = ""

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 20) {
                HStack {
                    Spacer()
                    Button {
                        showNewPlaylist = true
                    } label: {
                        Label("新建歌单", systemImage: "plus")
                    }
                    .controlSize(.small)
                }
                .padding(.horizontal, Theme.Layout.contentInset)
                .padding(.top, 12)

                if account.createdPlaylists.isEmpty {
                    EmptyStateView(icon: "music.note.list", title: "还没有创建歌单")
                        .frame(minHeight: 300)
                } else {
                    CardGrid {
                        ForEach(account.createdPlaylists) { playlist in
                            NavigationLink(value: Destination.playlist(playlist.id)) {
                                CoverCardBody(
                                    coverURL: playlist.coverURL?.resizedImageURL(384),
                                    title: playlist.name,
                                    subtitle: String(localized: "\(playlist.trackCount) 首")
                                )
                            }
                            .buttonStyle(.interactiveCard)
                            .contextMenu {
                                Button("播放") {
                                    Task {
                                        do { try await PlaylistPlayback.start(id: playlist.id) }
                                        catch { ToastCenter.shared.show(error.localizedDescription) }
                                    }
                                }
                                Divider()
                                Button("删除歌单", role: .destructive) {
                                    Task {
                                        try? await NeteaseAPI.deletePlaylist(id: playlist.id)
                                        await account.refreshLibrary()
                                    }
                                }
                            }
                        }
                    }
                    .padding(.horizontal, Theme.Layout.contentInset)
                }
                PlayerClearanceSpacer()
            }
        }
        .navigationTitle("我的歌单")
        .alert("新建歌单", isPresented: $showNewPlaylist) {
            TextField("歌单名称", text: $newPlaylistName)
            Button("创建") {
                let name = newPlaylistName.trimmingCharacters(in: .whitespaces)
                newPlaylistName = ""
                guard !name.isEmpty else { return }
                Task {
                    do {
                        try await NeteaseAPI.createPlaylist(name: name, isPrivate: false)
                        await account.refreshLibrary()
                        ToastCenter.shared.show(String(localized: "歌单已创建"))
                    } catch {
                        ToastCenter.shared.show(error.localizedDescription)
                    }
                }
            }
            Button("取消", role: .cancel) { newPlaylistName = "" }
        }
    }

}
