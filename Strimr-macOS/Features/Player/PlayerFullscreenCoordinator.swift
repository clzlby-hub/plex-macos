import AppKit
import Observation
import SwiftUI

@MainActor
@Observable
final class PlayerFullscreenCoordinator: NSObject {
    private enum FullScreenPhase {
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
    @ObservationIgnored private var hideFallbackWorkItem: DispatchWorkItem?
    @ObservationIgnored private var retryCountForCurrentHide = 0
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
                if fullScreenPhase == .windowed {
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

        if !currentlyFullScreen {
            configureWindowForFullScreen(window)
        }
        installCloseButtonAction(on: window)
        installObservers(for: window)

        if pendingHide {
            DispatchQueue.main.async { [weak self, weak window] in
                guard let self, let window, self.pendingHide else { return }
                self.executePendingHide(on: window)
            }
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
        retryCountForCurrentHide = 0
        hideFallbackWorkItem?.cancel()
        hideFallbackWorkItem = nil

        guard let window else { return }
        installCloseButtonAction(on: window)

        if fullScreenPhase != .entering, fullScreenPhase != .exiting {
            bringToFront(window, for: presentationID)
        }
    }

    func bringCurrentWindowToFront() {
        guard let window, !pendingHide else { return }
        NSApp.activate(ignoringOtherApps: true)
        if window.isMiniaturized {
            window.deminiaturize(nil)
        }
        window.makeKeyAndOrderFront(nil)
        window.orderFrontRegardless()
    }

    func toggleFullScreen() {
        guard !isTransitioning, let window else { return }
        if !window.styleMask.contains(.fullScreen) {
            configureWindowForFullScreen(window)
        }
        window.toggleFullScreen(nil)
    }

    func hideWindow() {
        activePresentationID = nil
        pendingHide = true
        retryCountForCurrentHide = 0
        hideFallbackWorkItem?.cancel()
        hideFallbackWorkItem = nil

        guard let target = window else { return }

        DispatchQueue.main.async { [weak self, weak target] in
            guard let self, let target, self.pendingHide else { return }
            self.executePendingHide(on: target)
        }
    }

    func detach() {
        let notificationCenter = NotificationCenter.default
        notificationObservers.forEach(notificationCenter.removeObserver)
        notificationObservers.removeAll()
        hideFallbackWorkItem?.cancel()
        hideFallbackWorkItem = nil
        if let window, Self.currentWindow === window {
            Self.currentWindow = nil
        }
        window = nil
        fullScreenPhase = .windowed
        isFullScreen = false
        isTransitioning = false
        pendingHide = false
        retryCountForCurrentHide = 0
    }

    @objc private func handleWindowCloseButton(_ sender: Any?) {
        if let onCloseRequested {
            onCloseRequested()
        } else {
            hideWindow()
        }
    }

    private func installCloseButtonAction(on window: NSWindow) {
        if let closeBtn = window.standardWindowButton(.closeButton) {
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
                    if self.pendingHide, let window {
                        DispatchQueue.main.async { [weak self, weak window] in
                            guard let self, let window, self.pendingHide else { return }
                            self.executePendingHide(on: window)
                        }
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
                    self.hideFallbackWorkItem?.cancel()
                    self.hideFallbackWorkItem = nil

                    guard let window else { return }
                    self.configureWindowForFullScreen(window)
                    self.installCloseButtonAction(on: window)

                    if self.pendingHide {
                        self.pendingHide = false
                        self.retryCountForCurrentHide = 0
                        self.orderOutWindow(window)
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

        switch fullScreenPhase {
        case .entering:
            scheduleHideFallback(for: target)

        case .exiting:
            scheduleHideFallback(for: target)

        case .fullScreen:
            scheduleHideFallback(for: target)
            target.toggleFullScreen(nil)

        case .windowed:
            pendingHide = false
            retryCountForCurrentHide = 0
            hideFallbackWorkItem?.cancel()
            hideFallbackWorkItem = nil
            orderOutWindow(target)
        }
    }

    private func scheduleHideFallback(for target: NSWindow) {
        hideFallbackWorkItem?.cancel()
        let workItem = DispatchWorkItem { [weak self, weak target] in
            guard let self, let target, self.pendingHide else { return }
            if target.styleMask.contains(.fullScreen) {
                if self.retryCountForCurrentHide < 2 {
                    self.retryCountForCurrentHide += 1
                    NSApp.activate(ignoringOtherApps: true)
                    target.makeKeyAndOrderFront(nil)
                    target.toggleFullScreen(nil)
                    self.scheduleHideFallback(for: target)
                }
            } else {
                self.fullScreenPhase = .windowed
                self.isFullScreen = false
                self.isTransitioning = false
                self.pendingHide = false
                self.retryCountForCurrentHide = 0
                self.orderOutWindow(target)
            }
        }
        hideFallbackWorkItem = workItem
        DispatchQueue.main.asyncAfter(deadline: .now() + 1.5, execute: workItem)
    }

    private func orderOutWindow(_ target: NSWindow) {
        target.orderOut(nil)
        DispatchQueue.main.async { [weak self, weak target] in
            guard let self, let target,
                  self.activePresentationID == nil,
                  !target.styleMask.contains(.fullScreen)
            else { return }
            target.orderOut(nil)
        }
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

    private func configureWindowForFullScreen(_ window: NSWindow) {
        let requiresUpdate = !window.styleMask.contains(.resizable)
            || window.collectionBehavior.contains(.fullScreenAuxiliary)
            || !window.collectionBehavior.contains(.fullScreenPrimary)
            || window.standardWindowButton(.zoomButton)?.isEnabled != true

        guard requiresUpdate else { return }

        window.styleMask.insert(.resizable)
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
}
