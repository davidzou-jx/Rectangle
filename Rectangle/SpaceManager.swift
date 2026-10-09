/// SpaceManager.swift

import Cocoa

let spaceMoveSyntheticEventTag: Int64 = 0x5245_4354_5350_4345

protocol SpaceActionExecuting {
    func execute(parameters: ExecutionParameters) -> Bool
    func execute(parameters: ExecutionParameters, continuing operation: SpaceOperationCoordinator.Operation?) -> Bool
    var isSpaceActionInProgress: Bool { get }
}

extension SpaceActionExecuting {
    func execute(parameters: ExecutionParameters, continuing operation: SpaceOperationCoordinator.Operation?) -> Bool {
        execute(parameters: parameters)
    }

    var isSpaceActionInProgress: Bool { false }
}

enum SpaceSwitchingMethod: Int {
    case automatic = 0
    case dockGesture = 1
    case systemShortcut = 2
}

enum SpaceMouseDragPhase: Equatable {
    case outward
    case back
    case hold
}

protocol SpaceMoveEventPosting: AnyObject {
    var mouseLocation: CGPoint? { get }
    var accessibilityAuthorized: Bool { get }
    var leftMouseButtonPressed: Bool { get }
    var gesturePhaseDelay: TimeInterval { get }

    func prepare(direction: SpaceDirection, at dragPoint: CGPoint, probePoint: CGPoint) -> Bool
    func warpMouse(to point: CGPoint) -> Bool
    func postMouseDown() -> Bool
    func postMouseDragged(_ phase: SpaceMouseDragPhase) -> Bool
    func postGesturePhase(_ phase: SpaceGesturePhase) -> Bool
    func postMouseUp(at point: CGPoint) -> Bool
    func discardPreparedEvents()
}

protocol SpacePhysicalInputMonitoring: AnyObject {
    func start(_ handler: @escaping () -> Void)
    func stop()
}

final class SpacePhysicalInputMonitor: SpacePhysicalInputMonitoring {
    private var globalMonitor: Any?
    private var localMonitor: Any?
    private let ignoringEvent: (NSEvent) -> Bool

    init(ignoringEvent: @escaping (NSEvent) -> Bool = { _ in false }) {
        self.ignoringEvent = ignoringEvent
    }

    func start(_ handler: @escaping () -> Void) {
        stop()
        let mask: NSEvent.EventTypeMask = [
            .leftMouseDown, .leftMouseUp, .leftMouseDragged,
            .rightMouseDown, .rightMouseUp, .rightMouseDragged,
            .otherMouseDown, .otherMouseUp, .otherMouseDragged,
            .scrollWheel, .keyDown, .swipe, .gesture, .beginGesture, .endGesture
        ]
        let handle: (NSEvent) -> Void = { [ignoringEvent] event in
            guard event.cgEvent?.getIntegerValueField(.eventSourceUserData) != spaceMoveSyntheticEventTag,
                  !ignoringEvent(event) else {
                return
            }
            DispatchQueue.main.async(execute: handler)
        }
        globalMonitor = NSEvent.addGlobalMonitorForEvents(matching: mask, handler: handle)
        localMonitor = NSEvent.addLocalMonitorForEvents(matching: mask) { event in
            handle(event)
            return event
        }
    }

    func stop() {
        if let globalMonitor {
            NSEvent.removeMonitor(globalMonitor)
            self.globalMonitor = nil
        }
        if let localMonitor {
            NSEvent.removeMonitor(localMonitor)
            self.localMonitor = nil
        }
    }

    deinit {
        stop()
    }
}

final class CoreGraphicsSpaceMoveEventPoster: SpaceMoveEventPosting {
    private struct GesturePair {
        let phase: SpaceGesturePhase
        let dock: CGEvent
        let companion: CGEvent
    }

    private let eventSource = CGEventSource(stateID: .hidSystemState)
    private let augmentedEvents: Bool
    private let keyboardFallback: Bool
    private let keyboardShortcutProvider: (SpaceDirection) -> (CGKeyCode, CGEventFlags)
    private let naturalScrollingProvider: () -> Bool
    private var mouseDown: CGEvent?
    private var mouseUp: CGEvent?
    private var mouseDraggedOutward: CGEvent?
    private var mouseDraggedBack: CGEvent?
    private var mouseDraggedHold: CGEvent?
    private var keyboardDown: CGEvent?
    private var keyboardUp: CGEvent?
    private var gesturePairs = [GesturePair]()

    init(
        augmentedEvents: Bool = ProcessInfo.processInfo.isOperatingSystemAtLeast(
            OperatingSystemVersion(majorVersion: 27, minorVersion: 0, patchVersion: 0)
        ),
        keyboardFallback: Bool? = nil,
        switchingMethod: SpaceSwitchingMethod = SpaceSwitchingMethod(
            rawValue: UserDefaults.standard.integer(forKey: "spaceSwitchingMethod")
        ) ?? .automatic,
        keyboardShortcutProvider: @escaping (SpaceDirection) -> (CGKeyCode, CGEventFlags) =
            { CoreGraphicsSpaceMoveEventPoster.systemShortcut(for: $0) },
        naturalScrollingProvider: @escaping () -> Bool = {
            UserDefaults.standard.object(forKey: "com.apple.swipescrolldirection") as? Bool ?? true
        }
    ) {
        self.augmentedEvents = augmentedEvents
        switch switchingMethod {
        case .automatic:
            self.keyboardFallback = keyboardFallback ?? Self.requiresKeyboardFallback
        case .dockGesture:
            self.keyboardFallback = keyboardFallback ?? false
        case .systemShortcut:
            self.keyboardFallback = keyboardFallback ?? true
        }
        self.keyboardShortcutProvider = keyboardShortcutProvider
        self.naturalScrollingProvider = naturalScrollingProvider
    }

    var mouseLocation: CGPoint? {
        CGEvent(source: eventSource)?.location
    }

    var accessibilityAuthorized: Bool {
        AXIsProcessTrusted()
    }

    var leftMouseButtonPressed: Bool {
        CGEventSource.buttonState(.combinedSessionState, button: .left)
    }

    var gesturePhaseDelay: TimeInterval {
        augmentedEvents && !keyboardFallback ? 0.01 : 0
    }

    private static var requiresKeyboardFallback: Bool {
        let version = ProcessInfo.processInfo.operatingSystemVersion
        return version.majorVersion == 26 && version.minorVersion < 6
    }

    static func systemShortcut(for direction: SpaceDirection, defaults: UserDefaults = .standard) -> (CGKeyCode, CGEventFlags) {
        let keyCodeKey = direction == .next ? "nextSpaceSwitchKeyCode" : "previousSpaceSwitchKeyCode"
        let defaultKeyCode = direction == .next ? 124 : 123
        let keyCode = defaults.object(forKey: keyCodeKey) == nil
            ? defaultKeyCode
            : defaults.integer(forKey: keyCodeKey)
        let defaultFlags = CGEventFlags.maskControl.rawValue | CGEventFlags.maskSecondaryFn.rawValue
        let flagsKey = "spaceSwitchModifierFlags"
        let rawFlags = defaults.object(forKey: flagsKey) == nil
            ? defaultFlags
            : UInt64(exactly: defaults.integer(forKey: flagsKey)) ?? defaultFlags
        return (CGKeyCode(exactly: keyCode) ?? CGKeyCode(defaultKeyCode), CGEventFlags(rawValue: rawFlags))
    }

    func prepare(direction: SpaceDirection, at dragPoint: CGPoint, probePoint: CGPoint) -> Bool {
        discardPreparedEvents()
        let eventNumber = Int64(bitPattern: mach_absolute_time() & UInt64(Int64.max))
        guard let mouseDown = makeMouseEvent(.leftMouseDown,
                                             at: dragPoint,
                                             eventNumber: eventNumber),
              let mouseDraggedOutward = makeMouseEvent(.leftMouseDragged,
                                                       at: probePoint,
                                                       eventNumber: eventNumber,
                                                       deltaFrom: dragPoint),
              let mouseDraggedBack = makeMouseEvent(.leftMouseDragged,
                                                    at: dragPoint,
                                                    eventNumber: eventNumber,
                                                    deltaFrom: probePoint),
              let mouseDraggedHold = makeMouseEvent(.leftMouseDragged,
                                                    at: dragPoint,
                                                    eventNumber: eventNumber,
                                                    deltaFrom: dragPoint),
              let mouseUp = makeMouseEvent(.leftMouseUp,
                                           at: dragPoint,
                                           eventNumber: eventNumber)
        else {
            return false
        }

        if keyboardFallback {
            guard let eventSource else { return false }
            let (keyCode, flags) = keyboardShortcutProvider(direction)
            guard let keyboardDown = CGEvent(keyboardEventSource: eventSource,
                                             virtualKey: keyCode,
                                             keyDown: true),
                  let keyboardUp = CGEvent(keyboardEventSource: eventSource,
                                           virtualKey: keyCode,
                                           keyDown: false)
            else {
                return false
            }
            keyboardDown.flags = flags
            keyboardUp.flags = flags
            tag(keyboardDown)
            tag(keyboardUp)
            self.mouseDown = mouseDown
            self.mouseUp = mouseUp
            self.mouseDraggedOutward = mouseDraggedOutward
            self.mouseDraggedBack = mouseDraggedBack
            self.mouseDraggedHold = mouseDraggedHold
            self.keyboardDown = keyboardDown
            self.keyboardUp = keyboardUp
            return true
        }

        let dockDirection = Self.dockDirection(
            requested: direction,
            augmented: augmentedEvents,
            naturalScrolling: naturalScrollingProvider()
        )

        var pairs = [GesturePair]()
        for phase in SpaceGesturePhase.allCases {
            guard let dock = makeDockEvent(phase: phase, direction: dockDirection),
                  let companion = makeCompanionEvent()
            else {
                return false
            }
            pairs.append(GesturePair(phase: phase, dock: dock, companion: companion))
        }

        // Publish the cached events only after the complete transaction exists.
        self.mouseDown = mouseDown
        self.mouseUp = mouseUp
        self.mouseDraggedOutward = mouseDraggedOutward
        self.mouseDraggedBack = mouseDraggedBack
        self.mouseDraggedHold = mouseDraggedHold
        gesturePairs = pairs
        return true
    }

    func warpMouse(to point: CGPoint) -> Bool {
        CGWarpMouseCursorPosition(point) == .success
    }

    func postMouseDown() -> Bool {
        guard let mouseDown else { return false }
        mouseDown.post(tap: .cghidEventTap)
        return true
    }

    func postMouseDragged(_ phase: SpaceMouseDragPhase) -> Bool {
        let event: CGEvent?
        switch phase {
        case .outward:
            event = mouseDraggedOutward
        case .back:
            event = mouseDraggedBack
        case .hold:
            event = mouseDraggedHold
        }
        guard let event else { return false }
        event.post(tap: .cghidEventTap)
        return true
    }

    func postGesturePhase(_ phase: SpaceGesturePhase) -> Bool {
        if let keyboardDown, let keyboardUp {
            switch phase {
            case .began: keyboardDown.post(tap: .cghidEventTap)
            case .changed: keyboardUp.post(tap: .cghidEventTap)
            case .ended: break
            }
            return true
        }
        guard let pair = gesturePairs.first(where: { $0.phase == phase }) else { return false }
        pair.dock.post(tap: .cgSessionEventTap)
        pair.companion.post(tap: .cgSessionEventTap)
        return true
    }

    func postMouseUp(at point: CGPoint) -> Bool {
        guard let mouseUp else { return false }
        mouseUp.location = point
        mouseUp.post(tap: .cghidEventTap)
        return true
    }

    func discardPreparedEvents() {
        mouseDown = nil
        mouseUp = nil
        mouseDraggedOutward = nil
        mouseDraggedBack = nil
        mouseDraggedHold = nil
        keyboardDown = nil
        keyboardUp = nil
        gesturePairs.removeAll(keepingCapacity: true)
    }

    static func dockDirection(
        requested: SpaceDirection,
        augmented: Bool,
        naturalScrolling: Bool
    ) -> SpaceDirection {
        guard augmented && naturalScrolling else { return requested }
        return requested == .next ? .previous : .next
    }

    private func makeDockEvent(phase: SpaceGesturePhase, direction: SpaceDirection) -> CGEvent? {
        guard let event = CGEvent(source: nil) else { return nil }
        let timestamp = mach_absolute_time()
        for field in SpaceGesture.fields(
            for: phase,
            direction: direction,
            augmented: augmentedEvents,
            timestamp: timestamp
        ) {
            guard let eventField = CGEventField(rawValue: field.raw) else { return nil }
            switch field.value {
            case .integer(let value):
                event.setIntegerValueField(eventField, value: value)
            case .double(let value):
                event.setDoubleValueField(eventField, value: value)
            }
        }

        let preparedEvent: CGEvent
        if augmentedEvents {
            guard var bytes = event.data as Data?,
                  bytes.starts(with: [0, 0, 0, 2])
            else {
                return nil
            }
            bytes.append(SpaceGesture.payloadRecord(
                for: phase,
                direction: direction,
                timestamp: timestamp
            ))
            guard let augmented = CGEvent(withDataAllocator: nil, data: bytes as CFData) else {
                return nil
            }
            preparedEvent = augmented
        } else {
            preparedEvent = event
        }

        tag(preparedEvent)
        return preparedEvent
    }

    private func makeCompanionEvent() -> CGEvent? {
        guard let event = CGEvent(source: nil),
              let eventTypeField = CGEventField(rawValue: 55)
        else {
            return nil
        }
        event.setIntegerValueField(eventTypeField, value: 29)
        tag(event)
        return event
    }

    func makeMouseEvent(
        _ type: CGEventType,
        at point: CGPoint,
        eventNumber: Int64,
        deltaFrom previousPoint: CGPoint? = nil
    ) -> CGEvent? {
        guard point.x.isFinite, point.y.isFinite, let eventSource,
              let event = CGEvent(mouseEventSource: eventSource,
                                  mouseType: type,
                                  mouseCursorPosition: point,
                                  mouseButton: .left)
        else {
            return nil
        }
        event.flags = type == .leftMouseDragged ? [.maskNonCoalesced] : []
        event.setIntegerValueField(.mouseEventNumber, value: eventNumber)
        event.setIntegerValueField(.mouseEventClickState, value: 1)
        if let previousPoint {
            guard let deltaX = Int64(exactly: (point.x - previousPoint.x).rounded()),
                  let deltaY = Int64(exactly: (point.y - previousPoint.y).rounded()) else { return nil }
            event.setIntegerValueField(.mouseEventDeltaX,
                                       value: deltaX)
            event.setIntegerValueField(.mouseEventDeltaY,
                                       value: deltaY)
        }
        tag(event)
        return event
    }

    private func tag(_ event: CGEvent) {
        event.setIntegerValueField(.eventSourceUserData, value: spaceMoveSyntheticEventTag)
    }
}

typealias SpaceMoveScheduler = (_ delay: TimeInterval, _ action: @escaping () -> Void) -> Void

struct SpaceWindowSnapshot: Equatable {
    let windowId: CGWindowID?
    let pid: pid_t?
    let frame: CGRect
    let level: CGWindowLevel
    let isOnScreen: Bool

    static func current(for window: AccessibilityElement) -> SpaceWindowSnapshot? {
        guard let windowID = window.windowId,
              let infos = CGWindowListCopyWindowInfo(.optionIncludingWindow, windowID) as? [[String: Any]],
              let info = infos.first(where: { ($0[kCGWindowNumber as String] as? NSNumber)?.uint32Value == windowID }),
              let bounds = info[kCGWindowBounds as String] as? [String: Any],
              let frame = CGRect(dictionaryRepresentation: bounds as CFDictionary),
              let level = info[kCGWindowLayer as String] as? NSNumber else { return nil }
        return SpaceWindowSnapshot(windowId: windowID,
                                   pid: (info[kCGWindowOwnerPID as String] as? NSNumber)?.int32Value,
                                   frame: frame, level: level.int32Value,
                                   isOnScreen: info[kCGWindowIsOnscreen as String] as? Bool ?? false)
    }
}

typealias SpaceWindowSnapshotProvider = (AccessibilityElement) -> SpaceWindowSnapshot?

final class SpaceManager: SpaceActionExecuting {
    private static let spaceReader = SkyLightWindowSpaceTransfer()
    private enum State {
        case idle
        case probing
        case restoringProbe
        case postingGesture
        case awaitingSpaceChange
        case confirmingWindow
        case confirmingOrder
    }

    private let eventPoster: SpaceMoveEventPosting
    private let physicalInputMonitor: SpacePhysicalInputMonitoring
    private let dragTargetResolver: SpaceDragTargetResolving
    private let scheduler: SpaceMoveScheduler
    private let frontWindowProvider: () -> AccessibilityElement?
    private let windowSnapshotProvider: SpaceWindowSnapshotProvider
    private let neighborAvailable: (SpaceDirection, CGPoint) -> Bool?
    private let displayIdentifierAtPoint: (CGPoint) -> String?
    private let windowDisplayIdentifier: (CGWindowID) -> String?
    private let workspaceNotificationCenter: NotificationCenter
    private let mouseDownRecognitionDelay: TimeInterval
    private let probeObservationDelay: TimeInterval
    private let windowStabilityPollDelay: TimeInterval
    private let releaseTimeout: TimeInterval
    private let coordinator: SpaceOperationCoordinator
    private let raiseWindow: (AccessibilityElement) -> Void
    private let windowIsFrontmost: (CGWindowID, String) -> Bool?
    private let targetSpaceProvider: (CGWindowID, SpaceDirection) -> AdjacentManagedSpace?
    private let windowSpacesProvider: (CGWindowID) -> [UInt64]?
    private let currentSpaceProvider: (String) -> UInt64?
    private let cancelWindowAnimation: (AccessibilityElement) -> Void
    private var expectedSpace: AdjacentManagedSpace?
    private var spacePollScheduled = false
    private var operation: SpaceOperationCoordinator.Operation?

    var isSpaceActionInProgress: Bool { moveInProgress }

    private var state = State.idle
    private var moveInProgress = false
    private var executionID: UInt64 = 0
    private var mouseDownPosted = false
    private var gestureStarted = false
    private var gestureEnded = false
    private var spaceChangeObserved = false
    private var targetWindow: AccessibilityElement?
    private var trackedWindowId: CGWindowID?
    private var direction: SpaceDirection?
    private var sourceDisplayIdentifier: String?
    private var candidates = [SpaceDragTarget]()
    private var candidateIndex = 0
    private var currentCandidate: SpaceDragTarget?
    private var baselineWindowFrame: CGRect = .null
    private var probePollCount = 0
    private var restorationPollCount = 0
    private var lastStableFrame: CGRect?
    private var stableFrameCount = 0
    private var originalMouseLocation: CGPoint?
    private var dragPoint: CGPoint?
    private var probePoint: CGPoint?
    private var expectedMouseLocation: CGPoint?
    private var spaceChangeObserver: NSObjectProtocol?

    init(
        eventPoster: SpaceMoveEventPosting = CoreGraphicsSpaceMoveEventPoster(),
        physicalInputMonitor: SpacePhysicalInputMonitoring = SpacePhysicalInputMonitor(),
        dragTargetResolver: SpaceDragTargetResolving = SpaceDragTargetResolver(),
        scheduler: @escaping SpaceMoveScheduler = { delay, action in
            DispatchQueue.main.asyncAfter(deadline: .now() + delay, execute: action)
        },
        frontWindowProvider: @escaping () -> AccessibilityElement? = AccessibilityElement.getFrontWindowElement,
        windowSnapshotProvider: @escaping SpaceWindowSnapshotProvider = SpaceManager.currentSnapshot,
        neighborAvailable: @escaping (SpaceDirection, CGPoint) -> Bool? = { direction, point in
            SkyLightSpaceNeighborChecker.shared.hasNeighbor(direction: direction, at: point, scope: .normal)
        },
        displayIdentifierAtPoint: @escaping (CGPoint) -> String? = {
            SkyLightSpaceNeighborChecker.shared.displayIdentifier(at: $0)
        },
        windowDisplayIdentifier: @escaping (CGWindowID) -> String? = {
            SkyLightSpaceNeighborChecker.shared.displayIdentifier(for: $0)
        },
        workspaceNotificationCenter: NotificationCenter = NSWorkspace.shared.notificationCenter,
        mouseDownRecognitionDelay: TimeInterval = 0.035,
        probeObservationDelay: TimeInterval = 0.025,
        windowStabilityPollDelay: TimeInterval = 0.04,
        releaseTimeout: TimeInterval = 1.5,
        coordinator: SpaceOperationCoordinator = .shared,
        raiseWindow: @escaping (AccessibilityElement) -> Void = { $0.bringToFront(force: true) },
        windowIsFrontmost: ((CGWindowID, String) -> Bool?)? = nil,
        targetSpaceProvider: @escaping (CGWindowID, SpaceDirection) -> AdjacentManagedSpace? = { windowID, direction in
            guard let display = SkyLightSpaceNeighborChecker.shared.displayIdentifier(for: windowID),
                  let spaces = SpaceManager.spaceReader.spaces(for: windowID),
                  let displays = SkyLightSpaceNeighborChecker.shared.managedDisplaySpaces() else { return nil }
            return ManagedSpaceTopology.adjacentForGesture(to: spaces, direction: direction, on: display, in: displays)
        },
        windowSpacesProvider: @escaping (CGWindowID) -> [UInt64]? = { SpaceManager.spaceReader.spaces(for: $0) },
        currentSpaceProvider: @escaping (String) -> UInt64? = { SpaceManager.spaceReader.currentSpace(for: $0) },
        cancelWindowAnimation: @escaping (AccessibilityElement) -> Void = { WindowAnimator.shared.cancel(for: $0) }
    ) {
        self.eventPoster = eventPoster
        self.physicalInputMonitor = physicalInputMonitor
        self.dragTargetResolver = dragTargetResolver
        self.scheduler = scheduler
        self.frontWindowProvider = frontWindowProvider
        self.windowSnapshotProvider = windowSnapshotProvider
        self.neighborAvailable = neighborAvailable
        self.displayIdentifierAtPoint = displayIdentifierAtPoint
        self.windowDisplayIdentifier = windowDisplayIdentifier
        self.workspaceNotificationCenter = workspaceNotificationCenter
        self.mouseDownRecognitionDelay = mouseDownRecognitionDelay
        self.probeObservationDelay = probeObservationDelay
        self.windowStabilityPollDelay = windowStabilityPollDelay
        self.releaseTimeout = releaseTimeout
        self.coordinator = coordinator
        self.raiseWindow = raiseWindow
        self.targetSpaceProvider = targetSpaceProvider
        self.windowSpacesProvider = windowSpacesProvider
        self.currentSpaceProvider = currentSpaceProvider
        self.cancelWindowAnimation = cancelWindowAnimation
        self.windowIsFrontmost = windowIsFrontmost ?? { windowID, displayIdentifier in
            SpaceWindowOrder.isFrontmost(windowID: windowID,
                                        in: WindowUtil.getWindowList(forceRefresh: true)) { candidate in
                SkyLightSpaceNeighborChecker.shared.displayIdentifier(for: candidate)
                    .map { $0 == displayIdentifier }
            }
        }
    }

    deinit {
        physicalInputMonitor.stop()
        removeSpaceChangeObserver()
        endInterruptedGesture()
        if mouseDownPosted {
            let currentMouseLocation = eventPoster.mouseLocation
            _ = eventPoster.postMouseUp(at: currentMouseLocation ?? dragPoint ?? .zero)
            if let currentMouseLocation,
               let expectedMouseLocation,
               let originalMouseLocation,
               hypot(currentMouseLocation.x - expectedMouseLocation.x,
                     currentMouseLocation.y - expectedMouseLocation.y) <= 2
            {
                _ = eventPoster.warpMouse(to: originalMouseLocation)
            }
        }
        eventPoster.discardPreparedEvents()
    }

    func execute(parameters: ExecutionParameters) -> Bool {
        execute(parameters: parameters, continuing: nil)
    }

    func execute(parameters: ExecutionParameters, continuing operation: SpaceOperationCoordinator.Operation?) -> Bool {
        guard let direction = SpaceDirection(action: parameters.action) else {
            return false
        }

        guard !moveInProgress else {
            Logger.log("Ignoring Space move while another Space move is in progress")
            return true
        }

        guard let operation = coordinator.begin(continuing: operation) else { return true }

        guard eventPoster.accessibilityAuthorized else {
            fail("Accessibility permission is required to move a window between Spaces")
            return true
        }

        guard !eventPoster.leftMouseButtonPressed else {
            fail("Unable to move a window between Spaces while the left mouse button is pressed")
            return true
        }

        guard let requestedElement = parameters.windowElement ?? frontWindowProvider() else {
            fail("Unable to obtain the active window for a Space move")
            return true
        }
        let windowElement = requestedElement.topLevelElement ?? requestedElement.windowElement ?? requestedElement
        windowElement.setMessagingTimeout(0.25)
        cancelWindowAnimation(windowElement)
        Logger.log("Space move target app: \(windowElement.bundleIdentifier ?? "unknown"), role: \(windowElement.role?.rawValue ?? "unknown")")

        let initialSnapshot = windowSnapshotProvider(windowElement)
        guard eligible(windowElement, snapshot: initialSnapshot) else {
            return true
        }

        guard let windowID = initialSnapshot?.windowId ?? windowElement.windowId,
              let sourceDisplayIdentifier = displayIdentifierAtPoint(windowElement.frame.centerPoint),
              windowDisplayIdentifier(windowID) == sourceDisplayIdentifier
        else {
            Logger.log("Ignoring Space move: unable to confirm the window's display")
            return true
        }

        guard let hasNeighbor = neighborAvailable(direction, windowElement.frame.centerPoint) else {
            Logger.log("Ignoring Space move: unable to determine the adjacent Space")
            return true
        }
        if !hasNeighbor {
            Logger.log("Ignoring Space move at the end of this display's normal Spaces")
            return true
        }
        guard let target = targetSpaceProvider(windowID, direction), target.displayIdentifier == sourceDisplayIdentifier,
              target.sourceID != target.destinationID,
              windowSpacesProvider(windowID) == [target.sourceID],
              currentSpaceProvider(sourceDisplayIdentifier) == target.sourceID else {
            Logger.log("Ignoring drag move: unable to verify an adjacent normal desktop for the gesture")
            return true
        }

        guard let originalMouseLocation = eventPoster.mouseLocation else {
            fail("Unable to determine the current mouse location")
            return true
        }

        var candidates = dragTargetResolver.candidates(for: windowElement)
        if candidates.isEmpty {
            windowElement.bringToFront(force: true)
            candidates = dragTargetResolver.candidates(for: windowElement)
        }
        guard !candidates.isEmpty else {
            fail("Unable to find a safe draggable area for this window")
            return true
        }

        executionID &+= 1
        let currentExecutionID = executionID
        state = .probing
        moveInProgress = true
        self.operation = operation
        mouseDownPosted = false
        gestureStarted = false
        gestureEnded = false
        spaceChangeObserved = false
        targetWindow = windowElement
        trackedWindowId = windowID
        self.direction = direction
        self.sourceDisplayIdentifier = sourceDisplayIdentifier
        expectedSpace = target
        spacePollScheduled = false
        self.candidates = candidates
        candidateIndex = 0
        currentCandidate = nil
        baselineWindowFrame = .null
        probePollCount = 0
        restorationPollCount = 0
        lastStableFrame = nil
        stableFrameCount = 0
        self.originalMouseLocation = originalMouseLocation
        dragPoint = nil
        probePoint = nil
        expectedMouseLocation = originalMouseLocation
        observeSpaceChanges(executionID: currentExecutionID)
        Logger.log("Starting \(direction == .next ? "next" : "previous") Space move with \(candidates.count) drag target candidates")

        scheduler(releaseTimeout) { [weak self] in
            guard let self, self.isActive(currentExecutionID) else { return }
            Logger.log("Space move timed out in state \(self.state)")
            self.finish(executionID: currentExecutionID, restoreCursor: true, succeeded: false)
        }
        attemptCandidate(executionID: currentExecutionID)
        return true
    }

    private func eligible(_ windowElement: AccessibilityElement, snapshot: SpaceWindowSnapshot?) -> Bool {
        if windowElement.isSheet == true || windowElement.isModal == true {
            fail("Unable to move a window with an active modal sheet between Spaces")
            return false
        }
        if windowElement.isMinimized == true {
            fail("Unable to move a minimized window between Spaces")
            return false
        }
        if windowElement.isFullScreen == true {
            fail("Native full-screen and Split View windows cannot be moved between Spaces")
            return false
        }
        if windowElement.isPositionSettable == false {
            Logger.log("Space move window does not expose settable AXPosition; relying on drag acquisition")
        }
        let frame = windowElement.frame
        guard frame.isFiniteAndNonEmpty, frame.width >= 20, frame.height >= 10 else {
            fail("Unable to determine a movable window frame")
            return false
        }
        guard let snapshot, snapshot.level == 0, snapshot.isOnScreen, snapshot.frame.isFiniteAndNonEmpty else {
            fail("This window style cannot be moved between Spaces")
            return false
        }
        return true
    }

    private func attemptCandidate(executionID: UInt64) {
        guard coordinator.canContinue else {
            finish(executionID: executionID, restoreCursor: true, succeeded: false)
            return
        }
        guard isActive(executionID),
              let direction,
              let window = targetWindow,
              candidates.indices.contains(candidateIndex)
        else {
            exhaustCandidates(executionID: executionID)
            return
        }

        let candidate = candidates[candidateIndex]
        let point = candidate.point
        let probe = Self.probePoint(from: point, in: window.frame)
        guard let sourceDisplayIdentifier,
              displayIdentifierAtPoint(point) == sourceDisplayIdentifier,
              displayIdentifierAtPoint(probe) == sourceDisplayIdentifier
        else {
            rejectCandidate(candidate, reason: "drag point crosses the window's display", executionID: executionID)
            return
        }
        guard dragTargetResolver.isValid(candidate, for: window) else {
            rejectCandidate(candidate, reason: "AX target changed before preparation", executionID: executionID)
            return
        }
        guard eventPoster.prepare(direction: direction, at: point, probePoint: probe) else {
            rejectCandidate(candidate, reason: "event preparation failed", executionID: executionID)
            return
        }
        guard eventPoster.warpMouse(to: point) else {
            rejectCandidate(candidate, reason: "cursor warp failed", executionID: executionID)
            return
        }
        expectedMouseLocation = point
        guard dragTargetResolver.isValid(candidate, for: window) else {
            rejectCandidate(candidate, reason: "AX target changed after cursor warp", executionID: executionID)
            return
        }
        guard eventPoster.postMouseDown() else {
            rejectCandidate(candidate, reason: "mouse-down failed", executionID: executionID)
            return
        }

        Logger.log("Probing Space drag target \(candidate.source.rawValue) at \(NSStringFromPoint(point))")
        state = .probing
        currentCandidate = candidate
        baselineWindowFrame = observedFrame(for: window)
        dragPoint = point
        probePoint = probe
        expectedMouseLocation = point
        probePollCount = 0
        restorationPollCount = 0
        mouseDownPosted = true
        physicalInputMonitor.start { [weak self] in
            guard let self, self.isActive(executionID) else { return }
            Logger.log("Cancelling Space move after physical mouse input")
            self.finish(executionID: executionID, restoreCursor: false, succeeded: false)
        }

        scheduler(mouseDownRecognitionDelay) { [weak self] in
            self?.beginProbe(executionID: executionID)
        }
    }

    private func beginProbe(executionID: UInt64) {
        guard isActive(executionID), cursorStillControlled, coordinator.canContinue else {
            finish(executionID: executionID, restoreCursor: false, succeeded: false)
            return
        }
        if likelyMaximized(baselineWindowFrame) {
            guard eventPoster.postMouseDragged(.hold) else {
                retryCandidate(reason: "stationary drag event failed", executionID: executionID)
                return
            }
            expectedMouseLocation = dragPoint
            scheduler(probeObservationDelay) { [weak self] in
                self?.dragAcquired(executionID: executionID)
            }
            return
        }

        guard eventPoster.postMouseDragged(.outward) else {
            retryCandidate(reason: "probe drag event failed", executionID: executionID)
            return
        }
        expectedMouseLocation = probePoint

        scheduler(probeObservationDelay) { [weak self] in
            self?.observeProbe(executionID: executionID)
        }
    }

    private func observeProbe(executionID: UInt64) {
        guard isActive(executionID), cursorStillControlled, coordinator.canContinue, let window = targetWindow else {
            finish(executionID: executionID, restoreCursor: false, succeeded: false)
            return
        }
        let frame = observedFrame(for: window)
        if Self.frameMoved(frame, from: baselineWindowFrame) {
            guard eventPoster.postMouseDragged(.back) else {
                finish(executionID: executionID, restoreCursor: true, succeeded: false)
                return
            }
            state = .restoringProbe
            expectedMouseLocation = dragPoint
            scheduler(probeObservationDelay) { [weak self] in
                self?.confirmProbeRestored(executionID: executionID)
            }
            return
        }

        probePollCount += 1
        if probePollCount < 6 {
            scheduler(probeObservationDelay) { [weak self] in
                self?.observeProbe(executionID: executionID)
            }
        } else {
            retryCandidate(reason: "window frame did not follow probe", executionID: executionID)
        }
    }

    private func confirmProbeRestored(executionID: UInt64) {
        guard isActive(executionID), cursorStillControlled, coordinator.canContinue, let window = targetWindow else {
            finish(executionID: executionID, restoreCursor: false, succeeded: false)
            return
        }
        if Self.framesMatch(observedFrame(for: window), baselineWindowFrame, tolerance: 1.5) {
            dragAcquired(executionID: executionID)
            return
        }
        restorationPollCount += 1
        if restorationPollCount < 3 {
            scheduler(probeObservationDelay) { [weak self] in
                self?.confirmProbeRestored(executionID: executionID)
            }
        } else {
            Logger.log("Space drag probe moved the window but could not restore its frame")
            finish(executionID: executionID, restoreCursor: true, succeeded: false)
        }
    }

    private func rejectCandidate(_ candidate: SpaceDragTarget,
                                 reason: String,
                                 executionID: UInt64) {
        guard isActive(executionID) else { return }
        Logger.log("Rejected Space drag target \(candidate.source.rawValue): \(reason)")
        if candidate.source == .remembered, let targetWindow {
            dragTargetResolver.forgetSuccess(for: targetWindow)
        }
        physicalInputMonitor.stop()
        eventPoster.discardPreparedEvents()
        candidateIndex += 1
        attemptCandidate(executionID: executionID)
    }

    private func retryCandidate(reason: String, executionID: UInt64) {
        guard isActive(executionID) else { return }
        if let currentCandidate {
            Logger.log("Rejected Space drag target \(currentCandidate.source.rawValue): \(reason)")
            if currentCandidate.source == .remembered, let targetWindow {
                dragTargetResolver.forgetSuccess(for: targetWindow)
            }
        }
        if mouseDownPosted {
            _ = eventPoster.postMouseUp(at: expectedMouseLocation ?? dragPoint ?? .zero)
            mouseDownPosted = false
        }
        physicalInputMonitor.stop()
        eventPoster.discardPreparedEvents()
        candidateIndex += 1
        currentCandidate = nil
        attemptCandidate(executionID: executionID)
    }

    private func exhaustCandidates(executionID: UInt64) {
        guard isActive(executionID) else { return }
        fail("Unable to acquire a window drag from any safe title-bar area")
        finish(executionID: executionID, restoreCursor: true, succeeded: false)
    }

    private func dragAcquired(executionID: UInt64) {
        guard isActive(executionID), cursorStillControlled, coordinator.canContinue else {
            finish(executionID: executionID, restoreCursor: false, succeeded: false)
            return
        }
        guard let trackedWindowId,
              let sourceDisplayIdentifier,
              let expectedSpace, let targetWindow,
              targetWindow.windowId == trackedWindowId,
              targetWindow.isMinimized != true, targetWindow.isFullScreen != true,
              targetWindow.isSheet != true, targetWindow.isModal != true,
              currentSpaceProvider(sourceDisplayIdentifier) == expectedSpace.sourceID,
              windowSpacesProvider(trackedWindowId) == [expectedSpace.sourceID],
              windowDisplayIdentifier(trackedWindowId) == sourceDisplayIdentifier
        else {
            Logger.log("Cancelling Space move after the window changed displays during drag acquisition")
            finish(executionID: executionID, restoreCursor: true, succeeded: false)
            return
        }
        Logger.log("Space window drag acquired")
        state = .postingGesture
        postGesturePhase(at: 0, executionID: executionID)
    }

    private func postGesturePhase(at index: Int, executionID: UInt64) {
        guard isActive(executionID), cursorStillControlled, coordinator.canContinue,
              SpaceGesturePhase.allCases.indices.contains(index)
        else {
            if isActive(executionID) {
                finish(executionID: executionID, restoreCursor: false, succeeded: false)
            }
            return
        }
        let phase = SpaceGesturePhase.allCases[index]
        guard eventPoster.postGesturePhase(phase) else {
            Logger.log("Unable to post a Space gesture phase")
            finish(executionID: executionID, restoreCursor: true, succeeded: false)
            return
        }
        if phase == .began { gestureStarted = true }
        if phase == .ended { gestureEnded = true }

        let nextIndex = index + 1
        guard SpaceGesturePhase.allCases.indices.contains(nextIndex) else {
            gestureEnded = true
            state = .awaitingSpaceChange
            checkSpaceArrival(executionID: executionID)
            return
        }
        let delay = eventPoster.gesturePhaseDelay
        if delay > 0 {
            scheduler(delay) { [weak self] in
                self?.postGesturePhase(at: nextIndex, executionID: executionID)
            }
        } else {
            postGesturePhase(at: nextIndex, executionID: executionID)
        }
    }

    private func observeSpaceChanges(executionID: UInt64) {
        spaceChangeObserver = workspaceNotificationCenter.addObserver(
            forName: NSWorkspace.activeSpaceDidChangeNotification,
            object: nil,
            queue: .main
        ) { [weak self] _ in
            guard let self, self.isActive(executionID), self.gestureStarted else { return }
            self.spaceChangeObserved = true
            if self.gestureEnded {
                self.checkSpaceArrival(executionID: executionID)
            }
        }
    }

    private func checkSpaceArrival(executionID: UInt64) {
        guard isActive(executionID), state == .awaitingSpaceChange, let expectedSpace, let trackedWindowId else { return }
        guard coordinator.canContinue, cursorStillControlled else {
            finish(executionID: executionID, restoreCursor: false, succeeded: false); return
        }
        let current = currentSpaceProvider(expectedSpace.displayIdentifier)
        let memberships = windowSpacesProvider(trackedWindowId)
        if let current, current != expectedSpace.sourceID, current != expectedSpace.destinationID {
            finish(executionID: executionID, restoreCursor: false, succeeded: false); return
        }
        if current == expectedSpace.destinationID, memberships == [expectedSpace.destinationID] {
            beginWindowConfirmation(executionID: executionID)
            return
        }
        guard !spacePollScheduled else { return }
        spacePollScheduled = true
        scheduler(windowStabilityPollDelay) { [weak self] in
            guard let self, self.isActive(executionID) else { return }
            self.spacePollScheduled = false
            self.checkSpaceArrival(executionID: executionID)
        }
    }

    private var destinationStillOwned: Bool {
        guard let expectedSpace, let trackedWindowId else { return false }
        return currentSpaceProvider(expectedSpace.displayIdentifier) == expectedSpace.destinationID
            && windowSpacesProvider(trackedWindowId) == [expectedSpace.destinationID]
    }

    private func beginWindowConfirmation(executionID: UInt64) {
        guard isActive(executionID), state != .confirmingWindow, state != .confirmingOrder else { return }
        state = .confirmingWindow
        lastStableFrame = nil
        stableFrameCount = 0
        scheduler(windowStabilityPollDelay) { [weak self] in
            self?.confirmWindowStable(executionID: executionID)
        }
    }

    private func confirmWindowStable(executionID: UInt64) {
        guard isActive(executionID), cursorStillControlled, coordinator.canContinue, destinationStillOwned, let targetWindow else {
            finish(executionID: executionID, restoreCursor: false, succeeded: false)
            return
        }
        guard let trackedWindowId,
              let snapshot = windowSnapshotProvider(targetWindow),
              snapshot.isOnScreen,
              snapshot.level == 0,
              snapshot.frame.isFiniteAndNonEmpty,
              snapshot.windowId == trackedWindowId
        else {
            stableFrameCount = 0
            lastStableFrame = nil
            scheduler(windowStabilityPollDelay) { [weak self] in
                self?.confirmWindowStable(executionID: executionID)
            }
            return
        }

        if let lastStableFrame, Self.framesMatch(lastStableFrame, snapshot.frame, tolerance: 1) {
            stableFrameCount += 1
        } else {
            lastStableFrame = snapshot.frame
            stableFrameCount = 1
        }
        if stableFrameCount >= 2 {
            // Let go before activating the destination window. Keep observing
            // physical input until its focus and stacking order have settled.
            if mouseDownPosted {
                _ = eventPoster.postMouseUp(at: eventPoster.mouseLocation ?? dragPoint ?? .zero)
                mouseDownPosted = false
            }
            state = .confirmingOrder
            confirmWindowOrder(poll: 0, stablePolls: 0, executionID: executionID)
        } else {
            scheduler(windowStabilityPollDelay) { [weak self] in
                self?.confirmWindowStable(executionID: executionID)
            }
        }
    }

    private func confirmWindowOrder(poll: Int, stablePolls: Int, executionID: UInt64) {
        guard isActive(executionID) else { return }
        guard cursorStillControlled, coordinator.canContinue, destinationStillOwned,
              let targetWindow, let trackedWindowId, let sourceDisplayIdentifier,
              targetWindow.windowId == trackedWindowId,
              targetWindow.isMinimized != true, targetWindow.isFullScreen != true,
              targetWindow.isSheet != true, targetWindow.isModal != true,
              windowDisplayIdentifier(trackedWindowId) == sourceDisplayIdentifier
        else {
            finish(executionID: executionID, restoreCursor: false, succeeded: false)
            return
        }
        var nextStablePolls = 0
        if let snapshot = windowSnapshotProvider(targetWindow) {
            guard snapshot.windowId == trackedWindowId, snapshot.level == 0 else {
                finish(executionID: executionID, restoreCursor: true, succeeded: false)
                return
            }
            if snapshot.isOnScreen {
                if poll > 0, windowIsFrontmost(trackedWindowId, sourceDisplayIdentifier) == true,
                   frontWindowProvider()?.windowId == trackedWindowId {
                    nextStablePolls = stablePolls + 1
                    if nextStablePolls >= 3 {
                        finish(executionID: executionID, restoreCursor: true, succeeded: true)
                        return
                    }
                } else {
                    raiseWindow(targetWindow)
                }
            }
        }
        guard poll < 20 else {
            fail("Moved window's destination stacking order could not be confirmed")
            finish(executionID: executionID, restoreCursor: true, succeeded: false)
            return
        }
        scheduler(windowStabilityPollDelay) { [weak self] in
            self?.confirmWindowOrder(poll: poll + 1, stablePolls: nextStablePolls, executionID: executionID)
        }
    }

    private func finish(executionID: UInt64, restoreCursor: Bool, succeeded: Bool) {
        guard isActive(executionID) else { return }

        endInterruptedGesture()
        let currentMouseLocation = eventPoster.mouseLocation
        if mouseDownPosted {
            _ = eventPoster.postMouseUp(at: currentMouseLocation ?? dragPoint ?? .zero)
        }
        if restoreCursor,
           let currentMouseLocation,
           let expectedMouseLocation,
           let originalMouseLocation,
           hypot(currentMouseLocation.x - expectedMouseLocation.x,
                 currentMouseLocation.y - expectedMouseLocation.y) <= 2,
           hypot(currentMouseLocation.x - originalMouseLocation.x,
                 currentMouseLocation.y - originalMouseLocation.y) > 0.5
        {
            _ = eventPoster.warpMouse(to: originalMouseLocation)
        }

        removeSpaceChangeObserver()
        physicalInputMonitor.stop()
        if succeeded, let currentCandidate, let targetWindow {
            dragTargetResolver.recordSuccess(currentCandidate, for: targetWindow)
        }
        Logger.log("Space move finished (success: \(succeeded))")
        eventPoster.discardPreparedEvents()
        state = .idle
        mouseDownPosted = false
        gestureStarted = false
        gestureEnded = false
        spaceChangeObserved = false
        targetWindow = nil
        trackedWindowId = nil
        direction = nil
        sourceDisplayIdentifier = nil
        expectedSpace = nil
        spacePollScheduled = false
        candidates.removeAll(keepingCapacity: true)
        candidateIndex = 0
        currentCandidate = nil
        baselineWindowFrame = .null
        lastStableFrame = nil
        stableFrameCount = 0
        originalMouseLocation = nil
        dragPoint = nil
        probePoint = nil
        expectedMouseLocation = nil
        moveInProgress = false
        operation = nil
    }

    private func endInterruptedGesture() {
        guard gestureStarted, !gestureEnded else { return }
        // End Dock's gesture before releasing the held window and discarding
        // the prepared events, including cancellation between paced phases.
        _ = eventPoster.postGesturePhase(.ended)
        gestureEnded = true
    }

    private func isActive(_ candidateExecutionID: UInt64) -> Bool {
        moveInProgress && executionID == candidateExecutionID
    }

    private func removeSpaceChangeObserver() {
        if let spaceChangeObserver {
            workspaceNotificationCenter.removeObserver(spaceChangeObserver)
            self.spaceChangeObserver = nil
        }
    }

    private var cursorStillControlled: Bool {
        guard let current = eventPoster.mouseLocation, let expectedMouseLocation else { return false }
        return hypot(current.x - expectedMouseLocation.x, current.y - expectedMouseLocation.y) <= 2
    }

    private func observedFrame(for window: AccessibilityElement) -> CGRect {
        if let snapshot = windowSnapshotProvider(window),
           snapshot.isOnScreen,
           trackedWindowId == nil || snapshot.windowId == trackedWindowId,
           !snapshot.frame.isNull {
            return snapshot.frame
        }
        return window.frame
    }

    private func likelyMaximized(_ frame: CGRect) -> Bool {
        NSScreen.screens.contains { screen in
            Self.framesMatch(frame, screen.visibleFrame.screenFlipped, tolerance: 4)
                || Self.framesMatch(frame, screen.frame.screenFlipped, tolerance: 4)
        }
    }

    private static func probePoint(from dragPoint: CGPoint, in windowFrame: CGRect) -> CGPoint {
        let distance: CGFloat = 8
        let displayFrame = NSScreen.screens
            .map(\.frame.screenFlipped)
            .first(where: { $0.contains(dragPoint) })
        let clip = displayFrame.map { $0.intersection(windowFrame) } ?? windowFrame
        if dragPoint.x + distance <= clip.maxX - 2 {
            return CGPoint(x: dragPoint.x + distance, y: dragPoint.y)
        }
        return CGPoint(x: max(clip.minX + 2, dragPoint.x - distance), y: dragPoint.y)
    }

    private static func frameMoved(_ frame: CGRect, from baseline: CGRect) -> Bool {
        guard !frame.isNull, !baseline.isNull else { return false }
        return hypot(frame.minX - baseline.minX, frame.minY - baseline.minY) >= 1
    }

    private static func framesMatch(_ lhs: CGRect, _ rhs: CGRect, tolerance: CGFloat) -> Bool {
        guard !lhs.isNull, !rhs.isNull else { return false }
        return abs(lhs.minX - rhs.minX) <= tolerance
            && abs(lhs.minY - rhs.minY) <= tolerance
            && abs(lhs.width - rhs.width) <= tolerance
            && abs(lhs.height - rhs.height) <= tolerance
    }

    private static func currentSnapshot(for window: AccessibilityElement) -> SpaceWindowSnapshot? {
        let onScreenWindows = WindowUtil.getWindowList(forceRefresh: true)
        if let windowId = window.windowId {
            guard let info = onScreenWindows.first(where: { $0.id == windowId }) else {
                return nil
            }
            return SpaceWindowSnapshot(windowId: info.id,
                                       pid: info.pid,
                                       frame: info.frame,
                                       level: info.level,
                                       isOnScreen: true)
        }
        let frame = window.frame
        guard let pid = window.pid, !frame.isNull else { return nil }
        let matching = onScreenWindows.filter {
            $0.pid == pid && framesMatch($0.frame, frame, tolerance: 2)
        }
        guard matching.count == 1, let info = matching.first else { return nil }
        return SpaceWindowSnapshot(windowId: info.id,
                                   pid: info.pid,
                                   frame: info.frame,
                                   level: info.level,
                                   isOnScreen: true)
    }

    private func fail(_ message: String) {
        NSSound.beep()
        Logger.log(message)
    }
}
