import AppKit
import SwiftUI

@main
struct StrimrApp: App {
    @NSApplicationDelegateAdaptor(StrimrAppDelegate.self) private var appDelegate
    @State private var sessionManager: SessionManager
    @State private var settingsManager: SettingsManager
    @State private var downloadManager: DownloadManager
    @State private var libraryStore: LibraryStore
    @State private var seerrStore: SeerrStore
    @State private var appModel: AppModel
    @State private var sharePlayCoordinator: SharePlayCoordinator
    @State private var externalPlaybackCallbackRouter = ExternalPlaybackCallbackRouter()

    init() {
        URLCache.shared = URLCache(
            memoryCapacity: 256 * 1024 * 1024,
            diskCapacity: 1024 * 1024 * 1024,
            directory: nil
        )
        let favoritesStore = FavoritesStore()
        #if DEBUG
            let demoStores = DemoStores.makeIfEnabled()
            let settingsManager = demoStores.map { SettingsManager(userDefaults: $0.defaults) } ?? SettingsManager()
        #else
            let settingsManager = SettingsManager()
        #endif
        let trackSelectionCoordinator = TrackSelectionCoordinator(
            store: TrackSelectionStore(),
            settingsManager: settingsManager,
        )
        #if DEBUG
            let sessionManager = SessionManager(
                settingsManager: settingsManager,
                favoritesStore: favoritesStore,
                trackSelectionCoordinator: trackSelectionCoordinator,
                versionSelectionStore: MediaVersionSelectionStore(),
                accountStore: demoStores?.accountStore,
                profileStore: demoStores?.profileStore,
            )
        #else
            let sessionManager = SessionManager(
                settingsManager: settingsManager,
                favoritesStore: favoritesStore,
                trackSelectionCoordinator: trackSelectionCoordinator,
                versionSelectionStore: MediaVersionSelectionStore(),
            )
        #endif

        _sessionManager = State(initialValue: sessionManager)
        _settingsManager = State(initialValue: settingsManager)
        _downloadManager = State(initialValue: DownloadManager(settingsManager: settingsManager))
        _libraryStore = State(initialValue: LibraryStore(
            sessionManager: sessionManager,
            settingsManager: settingsManager,
        ))
        #if DEBUG
            _seerrStore = State(initialValue: SeerrStore(userDefaults: demoStores?.defaults ?? .standard))
        #else
            _seerrStore = State(initialValue: SeerrStore())
        #endif
        _appModel = State(initialValue: AppModel(settingsManager: settingsManager))
        _sharePlayCoordinator = State(initialValue: SharePlayCoordinator(
            sessionManager: sessionManager,
        ))
    }

    var body: some Scene {
        WindowGroup("Plex") {
            configured(ContentView())
                .flushesTrackerQueue()
                .frame(minWidth: 960, minHeight: 640)
                .toastHost()
                .preferredColorScheme(.dark)
        }
        .defaultSize(width: 1440, height: 900)
        .windowToolbarStyle(.unified)

        Window("player.window.title", id: AppModel.playerWindowID) {
            configured(PlayerWindowView())
                .frame(minWidth: 720, minHeight: 405)
                .toastHost()
                .preferredColorScheme(.dark)
        }
        .defaultSize(width: 1120, height: 630)
        .windowResizability(.contentMinSize)
        .windowToolbarStyle(.unified)
        .restorationBehavior(.disabled)

        Settings {
            configured(
                MacSettingsView()
                    .frame(minWidth: 780, minHeight: 560)
                    .preferredColorScheme(.dark)
            )
        }
    }

    private func configured(_ content: some View) -> some View {
        content
            .environment(sessionManager)
            .environment(sessionManager.registry)
            .environment(settingsManager)
            .environment(downloadManager)
            .environment(libraryStore)
            .environment(seerrStore)
            .environment(appModel)
            .environment(sharePlayCoordinator)
            .environment(OfflineCoordinator.shared)
            .environment(externalPlaybackCallbackRouter)
    }
}

@MainActor
private final class StrimrAppDelegate: NSObject, NSApplicationDelegate {
    private var windowCloseObserver: NSObjectProtocol?

    func applicationDidFinishLaunching(_ notification: Notification) {
        windowCloseObserver = NotificationCenter.default.addObserver(
            forName: NSWindow.willCloseNotification,
            object: nil,
            queue: .main
        ) { [weak self] note in
            guard let closingWindow = note.object as? NSWindow else { return }
            MainActor.assumeIsolated {
                self?.handleWindowWillClose(closingWindow)
            }
        }
    }

    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool {
        true
    }

    private func handleWindowWillClose(_ closingWindow: NSWindow) {
        guard !(closingWindow is NSPanel),
              closingWindow.sheetParent == nil,
              closingWindow.styleMask.contains(.titled),
              !PlayerFullscreenCoordinator.isPlayerWindow(closingWindow)
        else { return }

        let hasOtherVisibleWindow = NSApp.windows.contains { window in
            window !== closingWindow
                && window.isVisible
                && !(window is NSPanel)
                && window.sheetParent == nil
                && window.styleMask.contains(.titled)
        }

        if !hasOtherVisibleWindow {
            DispatchQueue.main.async {
                NSApp.terminate(nil)
            }
        }
    }
}
