/// BridgedSpaceManager.swift

import Cocoa
import Darwin

struct AdjacentManagedSpace: Equatable {
    let sourceID: UInt64
    let destinationID: UInt64
    let displayIdentifier: String
}

enum ManagedSpaceScope: Equatable {
    case all
    case normal
}

/// The order in `Spaces` is the Mission Control order for one display. Space
/// IDs are not necessarily consecutive, and other displays have separate rows.
enum ManagedSpaceTopology {
    static func hasAdjacentDisplayedSpace(
        on displayIdentifier: String,
        direction: SpaceDirection,
        scope: ManagedSpaceScope,
        in displays: [[String: Any]]
    ) -> Bool? {
        guard let display = displays.first(where: {
            ($0["Display Identifier"] as? String) == displayIdentifier
        }),
        let current = display["Current Space"] as? [String: Any],
        let currentID = (current["id64"] as? NSNumber)?.uint64Value,
        let spaces = display["Spaces"] as? [[String: Any]]
        else { return nil }

        let spaceIDs = spaces.compactMap { entry -> UInt64? in
            if scope == .normal, (entry["type"] as? NSNumber)?.intValue != 0 {
                return nil
            }
            return (entry["id64"] as? NSNumber)?.uint64Value
        }
        guard let index = spaceIDs.firstIndex(of: currentID) else { return nil }
        return spaceIDs.indices.contains(direction == .next ? index + 1 : index - 1)
    }

    static func adjacent(
        to sourceIDs: [UInt64],
        direction: SpaceDirection,
        on displayIdentifier: String,
        in displays: [[String: Any]]
    ) -> AdjacentManagedSpace? {
        guard sourceIDs.count == 1, let sourceID = sourceIDs.first else { return nil }
        guard let display = displays.first(where: {
            ($0["Display Identifier"] as? String) == displayIdentifier
        }),
        let current = display["Current Space"] as? [String: Any],
        (current["id64"] as? NSNumber)?.uint64Value == sourceID,
        let spaces = display["Spaces"] as? [[String: Any]]
        else { return nil }

        let desktops = spaces.compactMap { entry -> UInt64? in
            guard (entry["type"] as? NSNumber)?.intValue == 0 else { return nil }
            return (entry["id64"] as? NSNumber)?.uint64Value
        }
        guard let index = desktops.firstIndex(of: sourceID) else { return nil }
        let neighborIndex = direction == .next ? index + 1 : index - 1
        guard desktops.indices.contains(neighborIndex) else { return nil }
        return AdjacentManagedSpace(sourceID: sourceID,
                                    destinationID: desktops[neighborIndex],
                                    displayIdentifier: displayIdentifier)
    }

    static func currentSpace(for displayIdentifier: String,
                             in displays: [[String: Any]]) -> UInt64? {
        guard let display = displays.first(where: {
            ($0["Display Identifier"] as? String) == displayIdentifier
        }), let current = display["Current Space"] as? [String: Any] else { return nil }
        return (current["id64"] as? NSNumber)?.uint64Value
    }
}

/// Reads the current display's Mission Control order without requiring the
/// bridged window-move operation. A nil result means the topology could not be
/// read, so callers should avoid sending a gesture with an unknown destination.
final class SkyLightSpaceNeighborChecker {
    static let shared = SkyLightSpaceNeighborChecker()

    private typealias MainConnection = @convention(c) () -> Int32
    private typealias CopyManagedDisplaySpaces = @convention(c) (Int32) -> Unmanaged<CFArray>?
    private typealias CopyBestManagedDisplayForPoint = @convention(c) (Int32, CGPoint) -> Unmanaged<CFString>?
    private typealias CopyManagedDisplayForWindow = @convention(c) (Int32, CGWindowID) -> Unmanaged<CFString>?
    private typealias CopyBestManagedDisplayForRect = @convention(c) (Int32, CGRect) -> Unmanaged<CFString>?
    private typealias GetWindowBounds = @convention(c) (Int32, CGWindowID, UnsafeMutablePointer<CGRect>) -> Int32
    private typealias CopyWindowsWithOptionsAndTags = @convention(c) (
        Int32, UInt32, CFArray, UInt32, UnsafeMutablePointer<UInt64>, UnsafeMutablePointer<UInt64>
    ) -> Unmanaged<CFArray>?

    private let framework: UnsafeMutableRawPointer?
    private let connection: Int32?
    private let copyManagedDisplaySpaces: CopyManagedDisplaySpaces?
    private let copyBestManagedDisplayForPoint: CopyBestManagedDisplayForPoint?
    private let copyManagedDisplayForWindow: CopyManagedDisplayForWindow?
    private let copyBestManagedDisplayForRect: CopyBestManagedDisplayForRect?
    private let getWindowBounds: GetWindowBounds?
    private let copyWindowsWithOptionsAndTags: CopyWindowsWithOptionsAndTags?

    private init() {
        let path = "/System/Library/PrivateFrameworks/SkyLight.framework/Versions/A/SkyLight"
        let framework = dlopen(path, RTLD_NOW)
        self.framework = framework
        if let framework,
           let mainSymbol = dlsym(framework, "SLSMainConnectionID"),
           let spacesSymbol = dlsym(framework, "SLSCopyManagedDisplaySpaces"),
           let displaySymbol = dlsym(framework, "SLSCopyBestManagedDisplayForPoint") {
            let main = unsafeBitCast(mainSymbol, to: MainConnection.self)
            connection = main()
            copyManagedDisplaySpaces = unsafeBitCast(spacesSymbol, to: CopyManagedDisplaySpaces.self)
            copyBestManagedDisplayForPoint = unsafeBitCast(displaySymbol, to: CopyBestManagedDisplayForPoint.self)
            copyManagedDisplayForWindow = dlsym(framework, "SLSCopyManagedDisplayForWindow")
                .map { unsafeBitCast($0, to: CopyManagedDisplayForWindow.self) }
            copyBestManagedDisplayForRect = dlsym(framework, "SLSCopyBestManagedDisplayForRect")
                .map { unsafeBitCast($0, to: CopyBestManagedDisplayForRect.self) }
            getWindowBounds = dlsym(framework, "SLSGetWindowBounds")
                .map { unsafeBitCast($0, to: GetWindowBounds.self) }
            copyWindowsWithOptionsAndTags = dlsym(framework, "SLSCopyWindowsWithOptionsAndTags")
                .map { unsafeBitCast($0, to: CopyWindowsWithOptionsAndTags.self) }
        } else {
            connection = nil
            copyManagedDisplaySpaces = nil
            copyBestManagedDisplayForPoint = nil
            copyManagedDisplayForWindow = nil
            copyBestManagedDisplayForRect = nil
            getWindowBounds = nil
            copyWindowsWithOptionsAndTags = nil
        }
    }

    func displayIdentifier(at point: CGPoint) -> String? {
        guard let connection, let copyBestManagedDisplayForPoint else { return nil }
        return copyBestManagedDisplayForPoint(connection, point)?.takeRetainedValue() as String?
    }

    func displayIdentifier(for windowID: CGWindowID) -> String? {
        guard let connection else { return nil }
        if let identifier = copyManagedDisplayForWindow?(connection, windowID)?.takeRetainedValue() as String? {
            return identifier
        }
        guard let getWindowBounds, let copyBestManagedDisplayForRect else { return nil }
        var frame = CGRect.null
        guard getWindowBounds(connection, windowID, &frame) == 0 else { return nil }
        return copyBestManagedDisplayForRect(connection, frame)?.takeRetainedValue() as String?
    }

    func hasNeighbor(direction: SpaceDirection, at point: CGPoint, scope: ManagedSpaceScope) -> Bool? {
        guard framework != nil,
              let connection,
              let copyManagedDisplaySpaces,
              let displayIdentifier = displayIdentifier(at: point),
              let displays = copyManagedDisplaySpaces(connection)?.takeRetainedValue() as? [[String: Any]]
        else { return nil }
        return ManagedSpaceTopology.hasAdjacentDisplayedSpace(
            on: displayIdentifier, direction: direction, scope: scope, in: displays
        )
    }

    func currentSpace(at point: CGPoint) -> UInt64? {
        guard let connection, let copyManagedDisplaySpaces,
              let identifier = displayIdentifier(at: point),
              let displays = copyManagedDisplaySpaces(connection)?.takeRetainedValue() as? [[String: Any]]
        else { return nil }
        return ManagedSpaceTopology.currentSpace(for: identifier, in: displays)
    }

    func windows(in spaceID: UInt64) -> [CGWindowID]? {
        guard let connection, let copyWindowsWithOptionsAndTags else { return nil }
        let spaces = [NSNumber(value: spaceID)] as NSArray
        var setTags: UInt64 = 0
        var clearTags: UInt64 = 0
        // The per-Space WindowServer list preserves stacking order on inactive
        // Spaces too. Like Yabai/Hammerspoon, use 0x2 to exclude minimized windows.
        guard let result = copyWindowsWithOptionsAndTags(
            connection, 0, unsafeBitCast(spaces, to: CFArray.self), 0x2, &setTags, &clearTags
        )?.takeRetainedValue() else { return nil }
        return (result as NSArray).compactMap { ($0 as? NSNumber)?.uint32Value }
    }
}

protocol WindowSpaceTransferring: AnyObject {
    var isAvailable: Bool { get }
    func spaces(for windowID: CGWindowID) -> [UInt64]?
    func adjacentSpace(for windowID: CGWindowID,
                       direction: SpaceDirection) -> AdjacentManagedSpace?
    func currentSpace(for displayIdentifier: String) -> UInt64?
    func move(windowID: CGWindowID, to spaceID: UInt64) -> Bool
}

/// WindowServer lists are front to back. Check ordinary application windows
/// only, scoped to the destination display and Space rather than global focus.
enum SpaceWindowOrder {
    static func isFrontmost(windowID: CGWindowID, orderedIDs: [CGWindowID],
                            descriptions: [WindowInfo], onDestination: (CGWindowID) -> Bool?) -> Bool? {
        let byID = Dictionary(descriptions.map { ($0.id, $0) }, uniquingKeysWith: { first, _ in first })
        let windows = orderedIDs.compactMap { byID[$0] }
        guard windows.count == orderedIDs.count else { return nil }
        return isFrontmost(windowID: windowID, in: windows, onDestination: onDestination)
    }

    static func isFrontmost(windowID: CGWindowID, in windows: [WindowInfo],
                            onDestination: (CGWindowID) -> Bool?) -> Bool? {
        let candidates = windows.filter {
            $0.level == 0 && $0.alpha > 0 && !$0.frame.isEmpty && !$0.frame.isNull
                && !["Dock", "WindowManager", "Notification Center"].contains($0.processName)
        }
        guard candidates.contains(where: { $0.id == windowID }) else { return nil }
        for candidate in candidates {
            guard let belongs = onDestination(candidate.id) else { return nil }
            if belongs { return candidate.id == windowID }
        }
        return nil
    }

    static func raise(_ window: AccessibilityElement, activate: Bool) {
        if activate {
            window.bringToFront(force: true)
        } else {
            // Ordering a background window must not activate its application
            // or follow it to the other Space when the follow option is off.
            window.raiseWithoutActivating()
        }
    }
}

/// Yabai 7.1.25 uses SLSBridgedMoveWindowsToManagedSpaceOperation on modern
/// macOS. The selector path is also used by DockDoor and avoids linking a
/// private framework or relying on a running Yabai daemon.
/// https://github.com/asmvik/yabai/blob/master/src/space_manager.c
/// https://github.com/ejbills/DockDoor/blob/main/DockDoor/Utilities/PrivateApis.swift
final class SkyLightWindowSpaceTransfer: WindowSpaceTransferring {
    private typealias MainConnection = @convention(c) () -> Int32
    private typealias CopyManagedDisplaySpaces = @convention(c) (Int32) -> Unmanaged<CFArray>?
    private typealias CopySpacesForWindows = @convention(c) (Int32, Int32, CFArray) -> Unmanaged<CFArray>?

    private let framework: UnsafeMutableRawPointer?
    private let connection: Int32?
    private let copyManagedDisplaySpaces: CopyManagedDisplaySpaces?
    private let copySpacesForWindows: CopySpacesForWindows?

    init() {
        let path = "/System/Library/PrivateFrameworks/SkyLight.framework/Versions/A/SkyLight"
        let framework = dlopen(path, RTLD_NOW)
        self.framework = framework
        if let framework,
           let mainSymbol = dlsym(framework, "SLSMainConnectionID"),
           let displaysSymbol = dlsym(framework, "SLSCopyManagedDisplaySpaces"),
           let spacesSymbol = dlsym(framework, "SLSCopySpacesForWindows") {
            let main = unsafeBitCast(mainSymbol, to: MainConnection.self)
            connection = main()
            copyManagedDisplaySpaces = unsafeBitCast(displaysSymbol, to: CopyManagedDisplaySpaces.self)
            copySpacesForWindows = unsafeBitCast(spacesSymbol, to: CopySpacesForWindows.self)
        } else {
            connection = nil
            copyManagedDisplaySpaces = nil
            copySpacesForWindows = nil
        }
    }

    var isAvailable: Bool {
        ProcessInfo.processInfo.isOperatingSystemAtLeast(
            OperatingSystemVersion(majorVersion: 26, minorVersion: 4, patchVersion: 0)
        )
            && framework != nil && connection != nil
            && copyManagedDisplaySpaces != nil && copySpacesForWindows != nil
            && NSClassFromString("SLSBridgedMoveWindowsToManagedSpaceOperation") != nil
    }

    func spaces(for windowID: CGWindowID) -> [UInt64]? {
        guard let connection, let copySpacesForWindows else { return nil }
        let windows = [NSNumber(value: windowID)] as NSArray
        guard let result = copySpacesForWindows(connection, 7,
                                               unsafeBitCast(windows, to: CFArray.self))?.takeRetainedValue()
        else { return nil }
        return (result as NSArray).compactMap { ($0 as? NSNumber)?.uint64Value }
    }

    func adjacentSpace(for windowID: CGWindowID,
                       direction: SpaceDirection) -> AdjacentManagedSpace? {
        guard let displayIdentifier = SkyLightSpaceNeighborChecker.shared.displayIdentifier(for: windowID),
              let sourceIDs = spaces(for: windowID),
              let displays = managedDisplaySpaces() else { return nil }
        return ManagedSpaceTopology.adjacent(
            to: sourceIDs, direction: direction, on: displayIdentifier, in: displays
        )
    }

    func currentSpace(for displayIdentifier: String) -> UInt64? {
        guard let displays = managedDisplaySpaces() else { return nil }
        return ManagedSpaceTopology.currentSpace(for: displayIdentifier, in: displays)
    }

    func move(windowID: CGWindowID, to spaceID: UInt64) -> Bool {
        guard isAvailable,
              let operationClass = NSClassFromString("SLSBridgedMoveWindowsToManagedSpaceOperation")
        else { return false }

        let initSelector = NSSelectorFromString("initWithWindows:spaceID:")
        let performSelector = NSSelectorFromString("performWithWMBridgeDelegate")
        guard let allocated = (operationClass as AnyObject)
            .perform(NSSelectorFromString("alloc"))?.takeUnretainedValue(),
            allocated.responds(to: initSelector)
        else { return false }

        typealias InitFunction = @convention(c) (AnyObject, Selector, NSArray, UInt64) -> AnyObject
        let initialize = unsafeBitCast(allocated.method(for: initSelector), to: InitFunction.self)
        let operation = initialize(allocated, initSelector,
                                   [NSNumber(value: windowID)] as NSArray, spaceID)
        guard operation.responds(to: performSelector) else { return false }
        typealias PerformFunction = @convention(c) (AnyObject, Selector) -> Void
        let perform = unsafeBitCast(operation.method(for: performSelector), to: PerformFunction.self)
        perform(operation, performSelector)
        return true
    }

    private func managedDisplaySpaces() -> [[String: Any]]? {
        guard let connection, let copyManagedDisplaySpaces,
              let result = copyManagedDisplaySpaces(connection)?.takeRetainedValue()
        else { return nil }
        return result as? [[String: Any]]
    }
}

/// Submits a followed window's transfer at the display switch's commit phase,
/// then verifies membership, visibility, and destination stacking order.
final class BridgedSpaceManager: SpaceActionExecuting {
    private let transfer: WindowSpaceTransferring
    private let switcher: DisplaySpaceSwitching
    private let fallback: SpaceActionExecuting
    private let scheduler: SpaceMoveScheduler
    private let frontWindowProvider: () -> AccessibilityElement?
    private let windowSnapshotProvider: SpaceWindowSnapshotProvider
    private let accessibilityAuthorized: () -> Bool
    private let screenProvider: (CGRect) -> NSScreen?
    private let displayIdentifierAtPoint: (CGPoint) -> String?
    private let raiseWindow: (AccessibilityElement, Bool) -> Void
    private let windowIsFrontmost: (CGWindowID, AdjacentManagedSpace) -> Bool?
    private let followMovedWindowProvider: () -> Bool
    private let coordinator: SpaceOperationCoordinator
    private let physicalInputMonitor: SpacePhysicalInputMonitoring
    private var operation: SpaceOperationCoordinator.Operation?
    private var userInterrupted = false
    private var moveInProgress = false
    private var transferRequested = false
    private var executionID: UInt64 = 0
    private let pollDelay: TimeInterval = 0.05
    private let maxPolls = 20

    var isSpaceActionInProgress: Bool {
        moveInProgress || switcher.isSpaceActionInProgress || fallback.isSpaceActionInProgress
    }

    init(
        transfer: WindowSpaceTransferring = SkyLightWindowSpaceTransfer(),
        switcher: DisplaySpaceSwitching? = nil,
        fallback: SpaceActionExecuting? = nil,
        scheduler: @escaping SpaceMoveScheduler = { delay, action in
            DispatchQueue.main.asyncAfter(deadline: .now() + delay, execute: action)
        },
        frontWindowProvider: @escaping () -> AccessibilityElement? = AccessibilityElement.getFrontWindowElement,
        windowSnapshotProvider: @escaping SpaceWindowSnapshotProvider = SpaceWindowSnapshot.current,
        accessibilityAuthorized: @escaping () -> Bool = AXIsProcessTrusted,
        screenProvider: @escaping (CGRect) -> NSScreen? = { frame in
            let screen = NSScreen.screens.max {
                $0.frame.screenFlipped.intersection(frame).width
                    * $0.frame.screenFlipped.intersection(frame).height
                < $1.frame.screenFlipped.intersection(frame).width
                    * $1.frame.screenFlipped.intersection(frame).height
            }
            guard let screen,
                  screen.frame.screenFlipped.intersection(frame).width
                    * screen.frame.screenFlipped.intersection(frame).height > 0
            else { return nil }
            return screen
        },
        displayIdentifierAtPoint: @escaping (CGPoint) -> String? = {
            SkyLightSpaceNeighborChecker.shared.displayIdentifier(at: $0)
        },
        raiseWindow: @escaping (AccessibilityElement, Bool) -> Void = SpaceWindowOrder.raise,
        windowIsFrontmost: ((CGWindowID, AdjacentManagedSpace) -> Bool?)? = nil,
        followMovedWindowProvider: @escaping () -> Bool = { !Defaults.followMovedWindowToSpace.userDisabled },
        coordinator: SpaceOperationCoordinator = .shared,
        physicalInputMonitor: SpacePhysicalInputMonitoring = SpacePhysicalInputMonitor()
    ) {
        self.transfer = transfer
        self.switcher = switcher ?? SpaceSwitcher(coordinator: coordinator)
        self.fallback = fallback ?? SpaceManager(coordinator: coordinator)
        self.scheduler = scheduler
        self.frontWindowProvider = frontWindowProvider
        self.windowSnapshotProvider = windowSnapshotProvider
        self.accessibilityAuthorized = accessibilityAuthorized
        self.screenProvider = screenProvider
        self.displayIdentifierAtPoint = displayIdentifierAtPoint
        self.raiseWindow = raiseWindow
        self.windowIsFrontmost = windowIsFrontmost ?? { windowID, target in
            guard let orderedIDs = SkyLightSpaceNeighborChecker.shared.windows(in: target.destinationID) else { return nil }
            let descriptions = WindowUtil.getWindowList(ids: orderedIDs, forceRefresh: true)
            return SpaceWindowOrder.isFrontmost(windowID: windowID, orderedIDs: orderedIDs,
                                                descriptions: descriptions) { candidate in
                SkyLightSpaceNeighborChecker.shared.displayIdentifier(for: candidate)
                    .map { $0 == target.displayIdentifier }
            }
        }
        self.followMovedWindowProvider = followMovedWindowProvider
        self.coordinator = coordinator
        self.physicalInputMonitor = physicalInputMonitor
    }

    func execute(parameters: ExecutionParameters) -> Bool {
        guard let direction = SpaceDirection(action: parameters.action) else { return false }
        guard !moveInProgress else {
            Logger.log("Ignoring overlapping bridged Space move")
            return true
        }
        guard let operation = coordinator.begin() else { return true }
        let followMovedWindow = followMovedWindowProvider()
        guard transfer.isAvailable else {
            guard followMovedWindow else {
                fail("Moving without switching Spaces requires the bridged window move operation")
                return true
            }
            return fallback.execute(parameters: parameters, continuing: operation)
        }
        guard accessibilityAuthorized() else {
            fail("Accessibility permission is required to move a window between Spaces")
            return true
        }
        guard let requested = parameters.windowElement ?? frontWindowProvider() else {
            fail("Unable to obtain the active window for a Space move")
            return true
        }
        let window = requested.topLevelElement ?? requested.windowElement ?? requested
        window.setMessagingTimeout(0.25)
        let snapshot = windowSnapshotProvider(window)
        guard window.isSheet != true, window.isModal != true,
              window.isMinimized != true, window.isFullScreen != true,
              !window.frame.isNull,
              let windowID = window.windowId ?? parameters.windowId ?? snapshot?.windowId,
              let snapshot,
              snapshot.windowId == windowID,
              snapshot.isOnScreen,
              snapshot.level == 0
        else {
            fail("This window cannot be moved between normal Spaces")
            return true
        }
        guard let target = transfer.adjacentSpace(for: windowID, direction: direction) else {
            Logger.log("Ignoring Space move: no adjacent normal Space exists for this window")
            return true
        }
        guard let screen = screenProvider(snapshot.frame),
              displayIdentifierAtPoint(screen.frame.screenFlipped.centerPoint) == target.displayIdentifier
        else {
            Logger.log("Ignoring Space move: the window's screen does not match its Space display")
            return true
        }
        Logger.log("Moving window \(windowID) from Space \(target.sourceID) to \(target.destinationID)")
        moveInProgress = true
        transferRequested = false
        self.operation = operation
        userInterrupted = false
        executionID &+= 1
        let currentExecutionID = executionID
        physicalInputMonitor.start { [weak self] in
            guard let self, self.moveInProgress, self.executionID == currentExecutionID else { return }
            self.userInterrupted = true
        }
        let moveWindow = { [weak self] in
            guard let self, self.moveInProgress, self.executionID == currentExecutionID,
                  !self.userInterrupted, self.coordinator.canContinue else { return }
            self.transferRequested = self.transfer.move(windowID: windowID, to: target.destinationID)
            if !self.transferRequested {
                self.fail("SkyLight did not accept the Space move")
                self.finish(success: false, executionID: currentExecutionID)
            }
        }
        if followMovedWindow {
            let action: WindowAction = direction == .next ? .switchNextSpace : .switchPrevSpace
            _ = switcher.execute(parameters: ExecutionParameters(action, screen: screen),
                                 continuing: operation, beforeSwitch: moveWindow)
        } else {
            moveWindow()
        }
        verifyMove(windowID: windowID, window: window, target: target,
                   followMovedWindow: followMovedWindow,
                   poll: 0, executionID: currentExecutionID)
        return true
    }

    private func verifyMove(windowID: CGWindowID,
                            window: AccessibilityElement,
                            target: AdjacentManagedSpace,
                            followMovedWindow: Bool,
                            poll: Int,
                            executionID: UInt64) {
        guard moveInProgress, self.executionID == executionID else { return }
        guard !userInterrupted, coordinator.canContinue else {
            finish(success: false, executionID: executionID)
            return
        }
        if !transferRequested, !switcher.isSpaceActionInProgress {
            // A rejected or interrupted switch must not move the window later.
            finish(success: false, executionID: executionID)
            return
        }
        if transferRequested, let memberships = transfer.spaces(for: windowID),
           memberships == [target.destinationID] {
            Logger.log("Verified window \(windowID) on Space \(target.destinationID)")
            if !followMovedWindow {
                confirmWindowOrder(target: target, window: window, windowID: windowID,
                                   activate: false, poll: 0, stablePolls: 0, executionID: executionID)
            } else {
                verifyDisplay(target: target, window: window, windowID: windowID,
                              poll: 0, executionID: executionID)
            }
            return
        }
        guard poll < maxPolls else {
            fail("Window did not arrive on the destination Space")
            finish(success: false, executionID: executionID)
            return
        }
        scheduler(pollDelay) { [weak self] in
            self?.verifyMove(windowID: windowID, window: window, target: target,
                             followMovedWindow: followMovedWindow,
                             poll: poll + 1, executionID: executionID)
        }
    }

    private func verifyDisplay(target: AdjacentManagedSpace,
                               window: AccessibilityElement,
                               windowID: CGWindowID,
                               poll: Int,
                               executionID: UInt64) {
        guard moveInProgress, self.executionID == executionID else { return }
        guard !userInterrupted, coordinator.canContinue else {
            finish(success: false, executionID: executionID)
            return
        }
        let ready = !switcher.isSpaceActionInProgress
            && transfer.currentSpace(for: target.displayIdentifier) == target.destinationID
        if ready {
            confirmWindowOrder(target: target, window: window, windowID: windowID,
                               activate: true, poll: 0, stablePolls: 0, executionID: executionID)
            return
        }
        guard poll < maxPolls + 10 else {
            fail("Window moved, but the destination Space did not become visible")
            finish(success: false, executionID: executionID)
            return
        }
        scheduler(pollDelay) { [weak self] in
            self?.verifyDisplay(target: target, window: window, windowID: windowID,
                                poll: poll + 1, executionID: executionID)
        }
    }

    private func confirmWindowOrder(target: AdjacentManagedSpace,
                                    window: AccessibilityElement,
                                    windowID: CGWindowID,
                                    activate: Bool,
                                    poll: Int,
                                    stablePolls: Int,
                                    executionID: UInt64) {
        guard moveInProgress, self.executionID == executionID else { return }
        guard !userInterrupted, coordinator.canContinue,
              window.windowId == windowID,
              window.isMinimized != true, window.isFullScreen != true,
              window.isSheet != true, window.isModal != true,
              let memberships = transfer.spaces(for: windowID),
              memberships == [target.destinationID],
              !activate || transfer.currentSpace(for: target.displayIdentifier) == target.destinationID
        else {
            finish(success: false, executionID: executionID)
            return
        }

        var nextStablePolls = 0
        if let snapshot = windowSnapshotProvider(window) {
            guard snapshot.windowId == windowID, snapshot.level == 0 else {
                finish(success: false, executionID: executionID)
                return
            }
            if !activate || snapshot.isOnScreen {
                if poll > 0, windowIsFrontmost(windowID, target) == true,
                   !activate || frontWindowProvider()?.windowId == windowID {
                    nextStablePolls = stablePolls + 1
                    if nextStablePolls >= 3 {
                        finish(success: true, executionID: executionID)
                        return
                    }
                } else {
                    // Space activation can restore another window's focus.
                    // Physical input, not that automatic focus change, cancels
                    // the move's intended raise. Verify again after each raise.
                    raiseWindow(window, activate)
                }
            }
        }
        guard poll < maxPolls else {
            fail("Window moved, but its destination stacking order could not be confirmed")
            finish(success: false, executionID: executionID)
            return
        }
        scheduler(pollDelay) { [weak self] in
            self?.confirmWindowOrder(target: target, window: window, windowID: windowID,
                                     activate: activate, poll: poll + 1, stablePolls: nextStablePolls,
                                     executionID: executionID)
        }
    }

    private func finish(success: Bool, executionID: UInt64) {
        guard moveInProgress, self.executionID == executionID else { return }
        Logger.log("Bridged Space move finished (success: \(success))")
        moveInProgress = false
        transferRequested = false
        physicalInputMonitor.stop()
        operation = nil
    }

    deinit { physicalInputMonitor.stop() }

    private func fail(_ message: String) {
        NSSound.beep()
        Logger.log(message)
    }
}
