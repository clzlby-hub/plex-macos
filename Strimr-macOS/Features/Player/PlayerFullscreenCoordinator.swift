import AppKit
import Observation
import os
import SwiftUI

private let playerWinLog = Logger(subsystem: "tv.plex.macos.custom", category: "PlayerWindow")

@MainActor
@Observable
final class PlayerFullscreenCoordinator: NSObject {
    private enum FullScreenPhase: String {
        case windowed
        case entering
        case fullScreen
        case exiting
    }

    private(set) static weak var currentWindow: NSWindow?

    private(set) var isFullScreen = false
    private(set) var isTransitioning = false

    @ObservationIgnored private var fullScreenPhase: FullScreenPhase = .windowed
    @ObservationIgnored private weak var window: NSWindow?
    @ObservationIgnored private var notificationObservers: [NSObjectProtocol] = []
    @ObservationIgnored private var pendingHide = false
    @ObservationIgnored private var activePresentationID: UUID?
    @ObservationIgnored private var hideDispatchWorkItem: DispatchWorkItem?
    @ObservationIgnored private var hideFallbackWorkItem: DispatchWorkItem?
    @ObservationIgnored private var hideFallbackStage = 0
    @ObservationIgnored private var onCloseRequested: (() -> Void)?
    @ObservationIgnored private var onCloseOwnerID: UUID?

    var hasLiveWindow: Bool {
        window != nil
    }

    static func isPlayerWindow(_ candidate: NSWindow) -> Bool {
        if let currentWindow, candidate === currentWindow {
            return true
        }
        guard let rawIdentifier = candidate.identifier?.rawValue else { return false }
        return rawIdentifier == AppModel.playerWindowID
            || rawIdentifier.hasPrefix("\(AppModel.playerWindowID)-")
    }

    func attach(to window: NSWindow) {
        if let currentWindow = self.window {
            if currentWindow === window {
                installCloseButtonAction(on: window)
                if fullScreenPhase == .windowed, !window.styleMask.contains(.fullScreen) {
                    configureWindowForFullScreen(window)
                }
                return
            }
            detach()
        }

        self.window = window
        Self.currentWindow = window
        window.isReleasedWhenClosed = false

        let currentlyFullScreen = window.styleMask.contains(.fullScreen)
        fullScreenPhase = currentlyFullScreen ? .fullScreen : .windowed
        isFullScreen = currentlyFullScreen
        isTransitioning = false

        playerWinLog.notice(
            "attach window=\(ObjectIdentifier(window).debugDescription, privacy: .public) id=\(window.identifier?.rawValue ?? "nil", privacy: .public) visible=\(window.isVisible) fs=\(currentlyFullScreen) style=\(window.styleMask.rawValue) cb=\(window.collectionBehavior.rawValue)",
        )

        if !currentlyFullScreen {
            configureWindowForFullScreen(window)
        }
        installCloseButtonAction(on: window)
        installObservers(for: window)

        if pendingHide {
            scheduleHideExecution(on: window, delay: currentlyFullScreen ? 0.06 : 0)
        } else if let presentationID = activePresentationID {
            DispatchQueue.main.async { [weak self, weak window] in
                guard let self, let window else { return }
                self.installCloseButtonAction(on: window)
                self.bringToFront(window, for: presentationID)
            }
        }
    }

    func setCloseHandler(for presentationID: UUID, handler: @escaping () -> Void) {
        onCloseOwnerID = presentationID
        onCloseRequested = handler
        if let window {
            installCloseButtonAction(on: window)
        }
    }

    func clearCloseHandler(for presentationID: UUID) {
        guard onCloseOwnerID == presentationID else { return }
        onCloseOwnerID = nil
        onCloseRequested = nil
    }

    func prepareForPresentation(id presentationID: UUID) {
        activePresentationID = presentationID
        pendingHide = false
        hideFallbackStage = 0
        cancelPendingHideWork()

        guard let target = window else { return }
        installCloseButtonAction(on: target)

        playerWinLog.notice(
            "prepareForPresentation presID=\(presentationID.uuidString, privacy: .public) phase=\(self.fullScreenPhase.rawValue, privacy: .public) fs=\(target.styleMask.contains(.fullScreen)) visible=\(target.isVisible)",
        )

        if fullScreenPhase != .entering, fullScreenPhase != .exiting {
            bringToFront(target, for: presentationID)
        }
    }

    func bringCurrentWindowToFront() {
        guard let target = resolveWindow(), !pendingHide else { return }
        NSApp.activate(ignoringOtherApps: true)
        if target.isMiniaturized {
            target.deminiaturize(nil)
        }
        target.makeKeyAndOrderFront(nil)
        target.orderFrontRegardless()
    }

    func toggleFullScreen() {
        guard !isTransitioning, let target = resolveWindow() else { return }
        ensureFullScreenToggleAllowed(on: target)
        target.toggleFullScreen(nil)
    }

    func hideWindow() {
        activePresentationID = nil
        pendingHide = true
        hideFallbackStage = 0
        cancelPendingHideWork()

        let target = resolveWindow()
        playerWinLog.notice(
            "hideWindow targetFound=\(target != nil) phase=\(self.fullScreenPhase.rawValue, privacy: .public) visible=\(target?.isVisible ?? false) fs=\(target?.styleMask.contains(.fullScreen) ?? false) key=\(target?.isKeyWindow ?? false) activeSpace=\(target?.isOnActiveSpace ?? false) totalWins=\(NSApp.windows.count)",
        )
        guard let target else { return }

        let needsFullScreenExit = target.styleMask.contains(.fullScreen)
            || fullScreenPhase == .fullScreen
            || fullScreenPhase == .entering
            || fullScreenPhase == .exiting

        // Give the close-button click inside NSToolbarFullScreenWindow and SwiftUI's PlayerView
        // teardown a brief settle tick before requesting toggleFullScreen so AppKit does not
        // reject the exit transition due to an in-flight titlebar gesture or view destruction.
        scheduleHideExecution(on: target, delay: needsFullScreenExit ? 0.06 : 0)
    }

    func detach() {
        if let window {
            playerWinLog.notice(
                "detach window=\(ObjectIdentifier(window).debugDescription, privacy: .public) phase=\(self.fullScreenPhase.rawValue, privacy: .public) pendingHide=\(self.pendingHide)",
            )
        }
        let notificationCenter = NotificationCenter.default
        notificationObservers.forEach(notificationCenter.removeObserver)
        notificationObservers.removeAll()
        cancelPendingHideWork()
        if let window, Self.currentWindow === window {
            Self.currentWindow = nil
        }
        window = nil
        fullScreenPhase = .windowed
        isFullScreen = false
        isTransitioning = false
        pendingHide = false
        hideFallbackStage = 0
    }

    @objc private func handleWindowCloseButton(_ sender: Any?) {
        playerWinLog.notice(
            "handleWindowCloseButton hasCallback=\(self.onCloseRequested != nil) phase=\(self.fullScreenPhase.rawValue, privacy: .public) fs=\(self.window?.styleMask.contains(.fullScreen) ?? false)",
        )
        if let onCloseRequested {
            onCloseRequested()
        } else {
            hideWindow()
        }
    }

    private func resolveWindow() -> NSWindow? {
        if let window {
            return window
        }
        if let fallback = NSApp.windows.first(where: {
            Self.isPlayerWindow($0) && ($0.isVisible || $0.styleMask.contains(.fullScreen))
        }) {
            attach(to: fallback)
            return fallback
        }
        return nil
    }

    private func cancelPendingHideWork() {
        hideDispatchWorkItem?.cancel()
        hideDispatchWorkItem = nil
        hideFallbackWorkItem?.cancel()
        hideFallbackWorkItem = nil
    }

    private func scheduleHideExecution(on target: NSWindow, delay: TimeInterval) {
        hideDispatchWorkItem?.cancel()
        let workItem = DispatchWorkItem { [weak self, weak target] in
            guard let self, let target, self.pendingHide else { return }
            self.hideDispatchWorkItem = nil
            self.executePendingHide(on: target)
        }
        hideDispatchWorkItem = workItem
        if delay > 0 {
            DispatchQueue.main.asyncAfter(deadline: .now() + delay, execute: workItem)
        } else {
            DispatchQueue.main.async(execute: workItem)
        }
    }

    private func installCloseButtonAction(on window: NSWindow) {
        guard let closeBtn = window.standardWindowButton(.closeButton) else { return }
        if closeBtn.target !== self || closeBtn.action != #selector(handleWindowCloseButton(_:)) {
            closeBtn.target = self
            closeBtn.action = #selector(handleWindowCloseButton(_:))
        }
    }

    private func installObservers(for window: NSWindow) {
        let notificationCenter = NotificationCenter.default
        notificationObservers = [
            notificationCenter.addObserver(
                forName: NSWindow.willEnterFullScreenNotification,
                object: window,
                queue: .main,
            ) { [weak self] _ in
                MainActor.assumeIsolated {
                    guard let self else { return }
                    self.fullScreenPhase = .entering
                    self.isFullScreen = true
                    self.isTransitioning = true
                    playerWinLog.notice("willEnterFullScreen pendingHide=\(self.pendingHide)")
                }
            },
            notificationCenter.addObserver(
                forName: NSWindow.didEnterFullScreenNotification,
                object: window,
                queue: .main,
            ) { [weak self, weak window] _ in
                MainActor.assumeIsolated {
                    guard let self else { return }
                    self.fullScreenPhase = .fullScreen
                    self.isFullScreen = true
                    self.isTransitioning = false
                    playerWinLog.notice("didEnterFullScreen pendingHide=\(self.pendingHide)")
                    guard let window else { return }
                    self.installCloseButtonAction(on: window)
                    if self.pendingHide {
                        self.scheduleHideExecution(on: window, delay: 0.05)
                    }
                }
            },
            notificationCenter.addObserver(
                forName: NSWindow.willExitFullScreenNotification,
                object: window,
                queue: .main,
            ) { [weak self] _ in
                MainActor.assumeIsolated {
                    guard let self else { return }
                    self.fullScreenPhase = .exiting
                    self.isTransitioning = true
                    playerWinLog.notice("willExitFullScreen pendingHide=\(self.pendingHide)")
                }
            },
            notificationCenter.addObserver(
                forName: NSWindow.didExitFullScreenNotification,
                object: window,
                queue: .main,
            ) { [weak self, weak window] _ in
                MainActor.assumeIsolated {
                    guard let self else { return }
                    self.fullScreenPhase = .windowed
                    self.isFullScreen = false
                    self.isTransitioning = false
                    self.cancelPendingHideWork()

                    guard let window else { return }
                    playerWinLog.notice(
                        "didExitFullScreen pendingHide=\(self.pendingHide) fs=\(window.styleMask.contains(.fullScreen)) visible=\(window.isVisible)",
                    )
                    self.configureWindowForFullScreen(window)
                    self.installCloseButtonAction(on: window)

                    if self.pendingHide {
                        self.pendingHide = false
                        self.hideFallbackStage = 0
                        // Defer orderOut to the next runloop turn so AppKit completes post-Space
                        // teardown cleanly before removing the window from the desktop Space.
                        DispatchQueue.main.async { [weak self, weak window] in
                            guard let self, let window, self.activePresentationID == nil else { return }
                            self.orderOutWindow(window)
                        }
                    } else if let presentationID = self.activePresentationID {
                        self.bringToFront(window, for: presentationID)
                    }
                }
            },
            notificationCenter.addObserver(
                forName: NSWindow.willCloseNotification,
                object: window,
                queue: .main,
            ) { [weak self, weak window] _ in
                MainActor.assumeIsolated {
                    guard let self, let window, self.window === window else { return }
                    playerWinLog.notice("willClose window=\(ObjectIdentifier(window).debugDescription, privacy: .public)")
                    self.detach()
                }
            },
        ]
    }

    private func executePendingHide(on target: NSWindow) {
        guard pendingHide else { return }

        let isStyleFullScreen = target.styleMask.contains(.fullScreen)
        if fullScreenPhase == .windowed, isStyleFullScreen {
            fullScreenPhase = .fullScreen
            isFullScreen = true
        } else if fullScreenPhase == .fullScreen, !isStyleFullScreen {
            fullScreenPhase = .windowed
            isFullScreen = false
        }

        playerWinLog.notice(
            "executePendingHide phase=\(self.fullScreenPhase.rawValue, privacy: .public) isStyleFS=\(isStyleFullScreen) visible=\(target.isVisible) key=\(target.isKeyWindow) activeSpace=\(target.isOnActiveSpace) style=\(target.styleMask.rawValue) cb=\(target.collectionBehavior.rawValue) zoomEnabled=\(target.standardWindowButton(.zoomButton)?.isEnabled ?? false)",
        )

        switch fullScreenPhase {
        case .entering:
            scheduleHideFallback(for: target, delay: 1.0)

        case .exiting:
            scheduleHideFallback(for: target, delay: 1.0)

        case .fullScreen:
            ensureFullScreenToggleAllowed(on: target)
            NSApp.activate(ignoringOtherApps: true)
            if !target.isKeyWindow {
                target.makeKey()
            }
            scheduleHideFallback(for: target, delay: 0.7)
            playerWinLog.notice("executePendingHide -> toggleFullScreen(nil)")
            target.toggleFullScreen(nil)

        case .windowed:
            pendingHide = false
            hideFallbackStage = 0
            cancelPendingHideWork()
            orderOutWindow(target)
        }
    }

    private func scheduleHideFallback(for target: NSWindow, delay: TimeInterval) {
        hideFallbackWorkItem?.cancel()
        let workItem = DispatchWorkItem { [weak self, weak target] in
            guard let self, let target, self.pendingHide else { return }
            self.hideFallbackWorkItem = nil

            let stillFullScreen = target.styleMask.contains(.fullScreen)
            playerWinLog.notice(
                "hideFallback stage=\(self.hideFallbackStage) phase=\(self.fullScreenPhase.rawValue, privacy: .public) stillFS=\(stillFullScreen) visible=\(target.isVisible) key=\(target.isKeyWindow) activeSpace=\(target.isOnActiveSpace) style=\(target.styleMask.rawValue) cb=\(target.collectionBehavior.rawValue)",
            )

            guard stillFullScreen else {
                self.fullScreenPhase = .windowed
                self.isFullScreen = false
                self.isTransitioning = false
                self.pendingHide = false
                self.hideFallbackStage = 0
                self.orderOutWindow(target)
                return
            }

            // If AppKit already posted willExitFullScreenNotification, allow the native animation
            // up to one extra cycle to complete before escalating.
            if self.fullScreenPhase == .exiting, self.hideFallbackStage == 0 {
                self.hideFallbackStage = 1
                self.scheduleHideFallback(for: target, delay: 1.2)
                return
            }

            switch self.hideFallbackStage {
            case 0:
                // willExitFullScreen never fired; re-ensure collectionBehavior/focus and retry toggleFullScreen.
                self.hideFallbackStage = 1
                self.ensureFullScreenToggleAllowed(on: target)
                NSApp.activate(ignoringOtherApps: true)
                target.makeKeyAndOrderFront(nil)
                playerWinLog.notice("hideFallback stage=0 retry -> toggleFullScreen(nil)")
                target.toggleFullScreen(nil)
                self.scheduleHideFallback(for: target, delay: 1.0)

            case 1:
                // Try the green zoom/fullscreen button click path or responder-chain toggleFullScreen.
                self.hideFallbackStage = 2
                self.ensureFullScreenToggleAllowed(on: target)
                NSApp.activate(ignoringOtherApps: true)
                target.makeKeyAndOrderFront(nil)
                if let zoomButton = target.standardWindowButton(.zoomButton), zoomButton.isEnabled {
                    playerWinLog.notice("hideFallback stage=1 retry -> zoomButton.performClick(nil)")
                    zoomButton.performClick(nil)
                } else {
                    playerWinLog.notice("hideFallback stage=1 retry -> NSApp.sendAction(toggleFullScreen:)")
                    NSApp.sendAction(#selector(NSWindow.toggleFullScreen(_:)), to: target, from: nil)
                }
                self.scheduleHideFallback(for: target, delay: 1.2)

            default:
                // Never call orderOut(nil) while styleMask.contains(.fullScreen), which orphans a
                // black fullscreen Space. As a final escape hatch, close the window natively so
                // AppKit tears down the fullscreen Space cleanly; willCloseNotification detaches
                // the coordinator and ContentView will recreate/reopen the window on next play.
                playerWinLog.error(
                    "hideFallback final escape hatch -> target.close(), stillFS=\(stillFullScreen) phase=\(self.fullScreenPhase.rawValue, privacy: .public)",
                )
                self.pendingHide = false
                self.hideFallbackStage = 0
                target.close()
                self.activateMainWindowIfVisible(excluding: target)
            }
        }
        hideFallbackWorkItem = workItem
        DispatchQueue.main.asyncAfter(deadline: .now() + delay, execute: workItem)
    }

    private func orderOutWindow(_ target: NSWindow) {
        guard !target.styleMask.contains(.fullScreen) else {
            playerWinLog.error("orderOutWindow blocked because window is still fullscreen")
            return
        }
        target.orderOut(nil)
        playerWinLog.notice("orderOutWindow done visibleAfter=\(target.isVisible) fs=\(target.styleMask.contains(.fullScreen))")
        activateMainWindowIfVisible(excluding: target)
        DispatchQueue.main.async { [weak self, weak target] in
            guard let self, let target,
                  self.activePresentationID == nil,
                  !target.styleMask.contains(.fullScreen)
            else { return }
            if target.isVisible {
                target.orderOut(nil)
                playerWinLog.notice("orderOutWindow async re-orderedOut visibleAfter=\(target.isVisible)")
            }
        }
    }

    private func activateMainWindowIfVisible(excluding playerWindow: NSWindow) {
        guard let mainWindow = NSApp.windows.first(where: { window in
            window !== playerWindow
                && !Self.isPlayerWindow(window)
                && window.isVisible
                && !(window is NSPanel)
                && window.sheetParent == nil
                && window.styleMask.contains(.titled)
        }) else {
            return
        }
        mainWindow.makeKeyAndOrderFront(nil)
    }

    private func bringToFront(_ target: NSWindow, for presentationID: UUID) {
        guard activePresentationID == presentationID, !pendingHide else { return }
        NSApp.activate(ignoringOtherApps: true)
        if target.isMiniaturized {
            target.deminiaturize(nil)
        }
        target.makeKeyAndOrderFront(nil)
        target.orderFrontRegardless()
        for delay in [0.05, 0.15] {
            DispatchQueue.main.asyncAfter(deadline: .now() + delay) { [weak self, weak target] in
                guard let self, let target,
                      self.activePresentationID == presentationID,
                      !self.pendingHide
                else { return }
                NSApp.activate(ignoringOtherApps: true)
                if target.isMiniaturized {
                    target.deminiaturize(nil)
                }
                target.makeKeyAndOrderFront(nil)
                target.orderFrontRegardless()
            }
        }
    }

    /// Ensures the window satisfies AppKit's preconditions for `toggleFullScreen(_:)`
    /// (both entering and exiting: `NSWindow.h` documents that without `.fullScreenPrimary`
    /// or `.fullScreenAuxiliary`, `toggleFullScreen:` may silently do nothing).
    private func ensureFullScreenToggleAllowed(on window: NSWindow) {
        let requiresUpdate = !window.styleMask.contains(.resizable)
            || window.collectionBehavior.contains(.fullScreenNone)
            || window.collectionBehavior.contains(.fullScreenAuxiliary)
            || !window.collectionBehavior.contains(.fullScreenPrimary)

        guard requiresUpdate else { return }

        playerWinLog.notice(
            "ensureFullScreenToggleAllowed updating style=\(window.styleMask.rawValue) cb=\(window.collectionBehavior.rawValue)",
        )
        window.styleMask.insert(.resizable)
        window.collectionBehavior.remove(.fullScreenNone)
        window.collectionBehavior.remove(.fullScreenAuxiliary)
        window.collectionBehavior.insert(.fullScreenPrimary)
    }

    private func configureWindowForFullScreen(_ window: NSWindow) {
        let requiresUpdate = !window.styleMask.contains(.resizable)
            || window.collectionBehavior.contains(.fullScreenNone)
            || window.collectionBehavior.contains(.fullScreenAuxiliary)
            || !window.collectionBehavior.contains(.fullScreenPrimary)
            || window.standardWindowButton(.zoomButton)?.isEnabled != true

        guard requiresUpdate else { return }

        window.styleMask.insert(.resizable)
        window.collectionBehavior.remove(.fullScreenNone)
        window.collectionBehavior.remove(.fullScreenAuxiliary)
        window.collectionBehavior.insert(.fullScreenPrimary)
        window.standardWindowButton(.zoomButton)?.isEnabled = true
    }
}

struct PlayerWindowReader: NSViewRepresentable {
    var onWindowAvailable: (NSWindow) -> Void

    func makeNSView(context _: Context) -> PlayerWindowReaderView {
        PlayerWindowReaderView(onWindowAvailable: onWindowAvailable)
    }

    func updateNSView(_ nsView: PlayerWindowReaderView, context _: Context) {
        nsView.onWindowAvailable = onWindowAvailable
        nsView.reportWindowIfAttached()
    }
}

final class PlayerWindowReaderView: NSView {
    var onWindowAvailable: (NSWindow) -> Void

    init(onWindowAvailable: @escaping (NSWindow) -> Void) {
        self.onWindowAvailable = onWindowAvailable
        super.init(frame: .zero)
    }

    @available(*, unavailable)
    required init?(coder _: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    override func viewDidMoveToWindow() {
        super.viewDidMoveToWindow()
        reportWindow()
    }

    func reportWindow() {
        guard let window else { return }
        onWindowAvailable(window)
    }

    func reportWindowIfAttached() {
        guard let window else { return }
        DispatchQueue.main.async { [weak self, weak window] in
            guard let self, let window, self.window === window else { return }
            self.onWindowAvailable(window)
        }
    }
}
