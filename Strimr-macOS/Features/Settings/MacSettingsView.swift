import SwiftUI

@MainActor
struct MacSettingsView: View {
    enum Category: String, CaseIterable, Identifiable {
        case interface
        case playback
        case audio
        case subtitles
        case accountPreferences
        case downloads
        case storage
        case accounts
        case profiles
        case privacy
        case about

        var id: String { rawValue }

        var titleKey: LocalizedStringKey {
            switch self {
            case .interface: "settings.interface.title"
            case .playback: "settings.playback.title"
            case .audio: "settings.playback.audio.title"
            case .subtitles: "settings.playback.subtitles.title"
            case .accountPreferences: "settings.accountPreferences.title"
            case .downloads: "settings.downloads.title"
            case .storage: "settings.storage.title"
            case .accounts: "settings.accounts.title"
            case .profiles: "profiles.title"
            case .privacy: "settings.privacy.title"
            case .about: "settings.about.title"
            }
        }

        var systemImage: String {
            switch self {
            case .interface: "macwindow"
            case .playback: "play.circle.fill"
            case .audio: "speaker.wave.2.fill"
            case .subtitles: "captions.bubble.fill"
            case .accountPreferences: "person.text.rectangle.fill"
            case .downloads: "arrow.down.circle.fill"
            case .storage: "internaldrive.fill"
            case .accounts: "person.crop.circle.fill"
            case .profiles: "person.2.fill"
            case .privacy: "hand.raised.fill"
            case .about: "info.circle.fill"
            }
        }

        var tint: Color {
            switch self {
            case .interface: .blue
            case .playback: .orange
            case .audio: .pink
            case .subtitles: .teal
            case .accountPreferences: .indigo
            case .downloads: .green
            case .storage: .gray
            case .accounts: .cyan
            case .profiles: .purple
            case .privacy: .blue
            case .about: .secondary
            }
        }
    }

    @Environment(SettingsManager.self) private var settingsManager
    @Environment(LibraryStore.self) private var libraryStore
    @Environment(SessionManager.self) private var sessionManager
    @State private var selection: Category = .playback

    private var generalCategories: [Category] {
        [.interface, .playback, .audio, .subtitles, .accountPreferences]
    }

    private var storageCategories: [Category] {
        [.downloads, .storage]
    }

    private var accountCategories: [Category] {
        sessionManager.canManageAccounts ? [.accounts, .profiles] : []
    }

    private var otherCategories: [Category] {
        [.privacy, .about]
    }

    var body: some View {
        HStack(spacing: 0) {
            List(selection: $selection) {
                Section {
                    ForEach(generalCategories) { category in
                        categoryRow(category)
                    }
                }
                Section {
                    ForEach(storageCategories) { category in
                        categoryRow(category)
                    }
                }
                if !accountCategories.isEmpty {
                    Section {
                        ForEach(accountCategories) { category in
                            categoryRow(category)
                        }
                    }
                }
                Section {
                    ForEach(otherCategories) { category in
                        categoryRow(category)
                    }
                }
            }
            .listStyle(.sidebar)
            .frame(width: 215)

            Divider()

            NavigationStack {
                detailView(for: selection)
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
            }
            .id(selection)
        }
        .navigationTitle("settings.title")
    }

    private func categoryRow(_ category: Category) -> some View {
        Label {
            Text(category.titleKey)
        } icon: {
            Image(systemName: category.systemImage)
                .foregroundStyle(category.tint)
        }
        .tag(category)
    }

    @ViewBuilder
    private func detailView(for category: Category) -> some View {
        switch category {
        case .interface:
            SettingsInterfaceView(
                settingsManager: settingsManager,
                libraryStore: libraryStore,
            )
        case .playback:
            SettingsPlaybackView()
        case .audio:
            SettingsAudioView()
        case .subtitles:
            SettingsSubtitlesView()
        case .accountPreferences:
            AccountPreferencesView()
        case .downloads:
            SettingsDownloadsView()
        case .storage:
            SettingsStorageView()
        case .accounts:
            AccountsSettingsView()
        case .profiles:
            ProfilesSettingsView()
        case .privacy:
            SettingsPrivacyView()
        case .about:
            SettingsAboutView()
        }
    }
}
