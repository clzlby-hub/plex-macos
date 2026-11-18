import SwiftUI

struct ContentView: View {
    @Environment(\.openWindow) private var openWindow
    @Environment(SessionManager.self) private var sessionManager
    @Environment(ServerRegistry.self) private var registry
    @Environment(SettingsManager.self) private var settingsManager
    @Environment(LibraryStore.self) private var libraryStore
    @Environment(AppModel.self) private var appModel
    @Environment(DownloadManager.self) private var downloadManager
    @Environment(OfflineCoordinator.self) private var offlineCoordinator
    @Environment(ExternalPlaybackCallbackRouter.self) private var externalPlaybackCallbackRouter
    @Environment(\.scenePhase) private var scenePhase

    init() {
        ErrorReporter.start()
    }

    var body: some View {
        ZStack {
            Color("Background").ignoresSafeArea()

            if showsStaticDownloads {
                NavigationStack {
                    DownloadsView()
                }
            } else {
                sessionContent
            }
        }
        .onChange(of: offlineCoordinator.availability.hasNetworkPath) { _, hasNetworkPath in
            guard hasNetworkPath, sessionManager.status == .migrationFailed else { return }
            Task { await sessionManager.hydrate() }
        }
        .onChange(of: scenePhase) { _, phase in
            switch phase {
            case .active:
                offlineCoordinator.availability.refresh()
                registry.retryUnavailable()
            case .background:
                offlineCoordinator.evictCacheIfNeeded()
            case .inactive:
                break
            @unknown default:
                break
            }
        }
        .onChange(of: settingsManager.downloads.offlineCacheLimitMB, initial: true) { _, megabytes in
            offlineCoordinator.setCacheLimit(megabytes: megabytes)
        }
        .onChange(of: appModel.playerPresentation?.id) { _, presentationID in
            guard let presentationID else { return }
            openWindow(id: AppModel.playerWindowID)
            for delay in [0.02, 0.1, 0.25] {
                DispatchQueue.main.asyncAfter(deadline: .now() + delay) {
                    guard appModel.playerPresentation?.id == presentationID else { return }
                    NSApp.activate(ignoringOtherApps: true)
                    if let playerWin = NSApp.windows.first(where: {
                        $0.identifier?.rawValue == AppModel.playerWindowID
                            || $0.title == String(localized: "player.window.title")
                    }) {
                        if playerWin.isMiniaturized {
                            playerWin.deminiaturize(nil)
                        }
                        playerWin.makeKeyAndOrderFront(nil)
                        playerWin.orderFrontRegardless()
                    }
                }
            }
        }
        .onChange(of: registry.connectedServices.map(ObjectIdentifier.init), initial: true) { _, _ in
            downloadManager.activateSession(services: registry.connectedServices)
        }
        // This window takes the external player callbacks so the window group does not open a new one.
        .onOpenURL { externalPlaybackCallbackRouter.receive($0) }
        .handlesExternalEvents(preferring: ["*"], allowing: ["*"])
    }

    /// Without a restorable session and without network, downloads are shown directly at launch.
    private var showsStaticDownloads: Bool {
        guard !offlineCoordinator.availability.hasNetworkPath, downloadManager.playableCount > 0 else { return false }
        switch sessionManager.status {
        case .needsAccount, .migrationFailed:
            return true
        case .hydrating, .needsProfileSelection, .ready:
            return false
        }
    }

    @ViewBuilder
    private var sessionContent: some View {
        switch sessionManager.status {
        case .hydrating:
            if let profile = sessionManager.activeProfile {
                ProfileActivationView(profile: profile)
                    .transition(.profileActivation)
            } else {
                ProgressView(sessionManager.loadingPhase.title)
                    .controlSize(.large)
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
            }
        case .needsAccount:
            AccountSetupView(purpose: .firstLaunch, sessionManager: sessionManager)
        case .needsProfileSelection:
            NavigationStack {
                ProfileSwitcherView(viewModel: ProfileSwitcherViewModel(sessionManager: sessionManager))
            }
        case .migrationFailed:
            MigrationFailedView()
        case .ready:
            MainView(
                homeViewModel: HomeViewModel(sessionManager: sessionManager, settingsManager: settingsManager),
                libraryViewModel: LibraryViewModel(
                    sessionManager: sessionManager,
                    libraryStore: libraryStore,
                    settingsManager: settingsManager,
                ),
            )
            .id(registry.generation)
        }
    }
}
