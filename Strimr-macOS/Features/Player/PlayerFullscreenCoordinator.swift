import AppKit
import Observation
import os
import SwiftUI

private let playerWinLog = Logger(subsystem: "tv.plex.macos.custom", category: "PlayerWindow")

@MainActor
@Observable
final class PlayerFullscreenCoordinator: NSObject {
    private(set) var isFullScreen = false
    private(set) var isTransitioning = false

    @ObservationIgnored private weak var window: NSWindow?
    @ObservationIgnored private var notificationObservers: [NSObjectProtocol] = []
    @ObservationIgnored var onCloseButtonClicked: (() -> Void)?

    func attach(to window: NSWindow, onClose: (() -> Void)? = nil) {
        playerWinLog.notice("attach window=\(ObjectIdentifier(window).debugDescription, privacy: .public) id=\(window.identifier?.rawValue ?? "nil", privacy: .public) visible=\(window.isVisible) fs=\(window.styleMask.contains(.fullScreen))")
        if let onClose {
            onCloseButtonClicked = onClose
        }
        DispatchQueue.main.async { [weak self, weak window] in
            guard let self, let window else { return }
            window.identifier = NSUserInterfaceItemIdentifier(AppModel.playerWindowID)
            window.isReleasedWhenClosed = false
            if let closeBtn = window.standardWindowButton(.closeButton) {
                closeBtn.target = self
                closeBtn.action = #selector(self.handleWindowCloseButton(_:))
            }
            self.bringToFront(window)
        }

        if let currentWindow = self.window {
            if currentWindow === window, !isFullScreen, !isTransitioning {
                configureWindowForFullScreen(currentWindow)
            }
            return
        }

        self.window = window
        configureWindowForFullScreen(window)
        updateState()

        let notificationCenter = NotificationCenter.default
        notificationObservers = [
            notificationCenter.addObserver(
                forName: NSWindow.willEnterFullScreenNotification,
                object: window,
                queue: .main,
            ) { [weak self] _ in
                MainActor.assumeIsolated {
                    self?.isFullScreen = true
                    self?.isTransitioning = true
                }
            },
            notificationCenter.addObserver(
                forName: NSWindow.didEnterFullScreenNotification,
                object: window,
                queue: .main,
            ) { [weak self] _ in
                MainActor.assumeIsolated {
                    self?.isFullScreen = true
                    self?.isTransitioning = false
                }
            },
            notificationCenter.addObserver(
                forName: NSWindow.willExitFullScreenNotification,
                object: window,
                queue: .main,
            ) { [weak self] _ in
                MainActor.assumeIsolated {
                    self?.isTransitioning = true
                }
            },
            notificationCenter.addObserver(
                forName: NSWindow.didExitFullScreenNotification,
                object: window,
                queue: .main,
            ) { [weak self] _ in
                MainActor.assumeIsolated {
                    guard let self else { return }
                    self.isFullScreen = false
                    self.isTransitioning = false
                    if let window = self.window {
                        self.configureWindowForFullScreen(window)
                    }
                }
            },
        ]
    }

    @objc private func handleWindowCloseButton(_ sender: Any?) {
        playerWinLog.notice("handleWindowCloseButton hasCallback=\(self.onCloseButtonClicked != nil)")
        if let onCloseButtonClicked {
            onCloseButtonClicked()
        } else {
            hideWindow()
        }
    }

    func toggleFullScreen() {
        guard !isTransitioning, let window else { return }
        configureWindowForFullScreen(window)
        window.toggleFullScreen(nil)
    }

    func bringToFront(_ targetWindow: NSWindow? = nil) {
        let win = targetWindow ?? window
        guard let win else { return }
        NSApp.activate(ignoringOtherApps: true)
        if win.isMiniaturized {
            win.deminiaturize(nil)
        }
        win.makeKeyAndOrderFront(nil)
        win.orderFrontRegardless()
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.08) { [weak win] in
            guard let win, win.isVisible else { return }
            NSApp.activate(ignoringOtherApps: true)
            win.makeKeyAndOrderFront(nil)
            win.orderFrontRegardless()
        }
    }

    func hideWindow() {
        let target = window ?? NSApp.windows.first(where: {
            $0.identifier?.rawValue == AppModel.playerWindowID
        })
        playerWinLog.notice("hideWindow targetFound=\(target != nil) visible=\(target?.isVisible ?? false) fs=\(target?.styleMask.contains(.fullScreen) ?? false) totalWins=\(NSApp.windows.count)")
        guard let target else { return }
        DispatchQueue.main.async {
            let isFS = target.styleMask.contains(.fullScreen)
            playerWinLog.notice("hideWindow async executing isFS=\(isFS) visible=\(target.isVisible)")
            if isFS {
                target.toggleFullScreen(nil)
                DispatchQueue.main.asyncAfter(deadline: .now() + 0.4) {
                    playerWinLog.notice("hideWindow 0.4s after toggleFS -> orderOut, stillFS=\(target.styleMask.contains(.fullScreen)) visible=\(target.isVisible)")
                    target.orderOut(nil)
                }
            } else {
                target.orderOut(nil)
                playerWinLog.notice("hideWindow orderedOut visibleAfter=\(target.isVisible)")
            }
        }
    }

    func detach() {
        let notificationCenter = NotificationCenter.default
        notificationObservers.forEach(notificationCenter.removeObserver)
        notificationObservers.removeAll()
        window = nil
        isFullScreen = false
        isTransitioning = false
    }

    private func updateState() {
        isFullScreen = window?.styleMask.contains(.fullScreen) == true
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
