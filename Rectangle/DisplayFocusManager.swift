import Cocoa

/// Moves focus to the next display relative to the active window.
final class DisplayFocusManager {
    private let screenDetection: ScreenDetection
    private let frontWindowProvider: () -> AccessibilityElement?
    private let warpCursor: (CGPoint) -> CGError
    private let coordinator: SpaceOperationCoordinator
    private let mousePressed: () -> Bool
    private let windowListProvider: () -> [WindowInfo]
    private let windowProvider: (WindowInfo) -> AccessibilityElement?
    private let activateWindow: (AccessibilityElement) -> Void

    init(screenDetection: ScreenDetection = ScreenDetection(),
         frontWindowProvider: @escaping () -> AccessibilityElement? = { AccessibilityElement.getFrontWindowElement() },
         warpCursor: @escaping (CGPoint) -> CGError = { CGWarpMouseCursorPosition($0) },
         coordinator: SpaceOperationCoordinator = .shared,
         mousePressed: @escaping () -> Bool = { CGEventSource.buttonState(.combinedSessionState, button: .left) },
         windowListProvider: @escaping () -> [WindowInfo] = { WindowUtil.getWindowList(forceRefresh: true) },
         windowProvider: @escaping (WindowInfo) -> AccessibilityElement? = { info in
             AccessibilityElement(info.pid).windowElements?.first { $0.windowId == info.id }
         },
         activateWindow: @escaping (AccessibilityElement) -> Void = { $0.bringToFront(force: true) }) {
        self.screenDetection = screenDetection
        self.frontWindowProvider = frontWindowProvider
        self.warpCursor = warpCursor
        self.coordinator = coordinator
        self.mousePressed = mousePressed
        self.windowListProvider = windowListProvider
        self.windowProvider = windowProvider
        self.activateWindow = activateWindow
    }

    func focusNextDisplay() {
        guard !mousePressed(), let operation = coordinator.begin() else { return }
        defer { withExtendedLifetime(operation) {} }
        guard let activeWindow = frontWindowProvider(), activeWindow.frame.isFiniteAndNonEmpty,
              let screens = screenDetection.detectScreens(using: activeWindow), screens.numScreens > 1,
              screenDetection.screenContaining(activeWindow.frame, screens: screens.screensOrdered) != nil,
              let destination = screens.adjacentScreens?.next, screenDetection.isAvailable(destination) else { return }
        guard warpCursor(destination.frame.screenFlipped.centerPoint) == .success else {
            Logger.log("Unable to move the cursor to the next display")
            return
        }

        // The on-screen window list is ordered front to back and excludes windows
        // on other Spaces. The first ordinary window centered on this display is
        // the one a user would see in front after moving there.
        var windows = windowListProvider()
        while let candidate = Self.frontWindow(on: destination.frame, from: windows) {
            windows.removeAll { $0.id == candidate.id }
            guard let window = windowProvider(candidate), window.windowId == candidate.id,
                  window.pid == candidate.pid, window.isWindow == true,
                  window.isSheet != true, window.isModal != true, window.isMinimized != true,
                  window.isHidden != true, window.isSystemDialog != true else { continue }
            // AX resolution can take time. A vanished display or a window that
            // left the visible Space must not be activated using stale CG info.
            guard coordinator.canContinue, screenDetection.isAvailable(destination) else { return }
            guard Self.frontWindow(on: destination.frame, from: windowListProvider().filter {
                $0.id == candidate.id && $0.pid == candidate.pid
            }) != nil else { continue }
            activateWindow(window)
            return
        }
    }

    static func frontWindow(on displayFrame: CGRect, from windows: [WindowInfo]) -> WindowInfo? {
        let destination = displayFrame.screenFlipped
        let ownPID = ProcessInfo.processInfo.processIdentifier
        return windows.first { info in
            info.level == 0 && info.alpha > 0 && info.frame.isFiniteAndNonEmpty &&
            destination.contains(info.frame.centerPoint) &&
            info.pid != ownPID &&
            !["Dock", "WindowManager", "Notification Center"].contains(info.processName)
        }
    }
}
