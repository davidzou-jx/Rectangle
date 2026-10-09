/// ReverseAllManager.swift

import Cocoa
import MASShortcut

class ReverseAllManager {

    static func reverseAll(windowElement: AccessibilityElement? = nil) {
        let sd = ScreenDetection()

        let currentWindow = windowElement ?? AccessibilityElement.getFrontWindowElement()
        guard let screens = sd.detectScreens(using: currentWindow) else { return }
        let currentScreen = screens.currentScreen
        let visibleInfo = WindowUtil.getWindowList(forceRefresh: true)
        let windows = MultiWindowManager.windowsOnScreen(
            screens: screens, windows: AccessibilityElement.getAllWindowElements(from: visibleInfo),
            focusedWindow: currentWindow, visibleWindowInfo: visibleInfo,
            screenFor: { sd.detectScreens(using: $0)?.currentScreen }).windows

        let screenFrame = currentScreen.adjustedVisibleFrame()
        guard screenFrame.isFiniteAndNonEmpty else { return }

        for w in windows {
            reverseWindowPosition(w, screenFrame: screenFrame)
        }
    }

    private static func reverseWindowPosition(_ w: AccessibilityElement, screenFrame: CGRect) {
        var rect = w.frame

        let offsetFromLeft = rect.minX - screenFrame.minX

        rect.origin.x = screenFrame.maxX - offsetFromLeft - rect.width

        w.setFrame(rect)
    }
}
