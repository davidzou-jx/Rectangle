import Cocoa

/// Moves focus to the next display relative to the active window.
final class DisplayFocusManager {
    private let screenDetection: ScreenDetection
    private let frontWindowProvider: () -> AccessibilityElement?
    private let warpCursor: (CGPoint) -> CGError

    init(screenDetection: ScreenDetection = ScreenDetection(),
         frontWindowProvider: @escaping () -> AccessibilityElement? = { AccessibilityElement.getFrontWindowElement() },
         warpCursor: @escaping (CGPoint) -> CGError = { CGWarpMouseCursorPosition($0) }) {
        self.screenDetection = screenDetection
        self.frontWindowProvider = frontWindowProvider
        self.warpCursor = warpCursor
    }

    func focusNextDisplay() {
        guard let activeWindow = frontWindowProvider(),
              let destination = screenDetection.detectScreens(using: activeWindow)?.adjacentScreens?.next else { return }
        guard warpCursor(destination.frame.screenFlipped.centerPoint) == .success else {
            Logger.log("Unable to move the cursor to the next display")
            return
        }

        // The on-screen window list is ordered front to back and excludes windows
        // on other Spaces. The first ordinary window centered on this display is
        // the one a user would see in front after moving there.
        let windows = WindowUtil.getWindowList(forceRefresh: true)
        guard let candidate = Self.frontWindow(on: destination.frame, from: windows) else { return }
        let appElement = AccessibilityElement(candidate.pid)
        guard let window = appElement.windowElements?.first(where: { $0.windowId == candidate.id }),
              window.isWindow == true,
              window.isSheet != true,
              window.isMinimized != true,
              window.isHidden != true,
              window.isSystemDialog != true else { return }

        // Raising and activating through macOS keeps the app's main window and
        // keyboard focus in sync with Rectangle's other window actions.
        window.bringToFront(force: true)
    }

    static func frontWindow(on displayFrame: CGRect, from windows: [WindowInfo]) -> WindowInfo? {
        let destination = displayFrame.screenFlipped
        let ownPID = ProcessInfo.processInfo.processIdentifier
        return windows.first { info in
            info.level == 0 && info.alpha > 0 && !info.frame.isEmpty &&
            destination.contains(info.frame.centerPoint) &&
            info.pid != ownPID &&
            !["Dock", "WindowManager", "Notification Center"].contains(info.processName)
        }
    }
}
