/// SpaceSwitcher.swift

import Cocoa

protocol DisplaySpaceSwitching: SpaceActionExecuting {
    func execute(parameters: ExecutionParameters,
                 continuing operation: SpaceOperationCoordinator.Operation?,
                 beforeSwitch: (() -> Void)?) -> Bool
}

protocol DisplaySpaceSwitchEventPosting: AnyObject {
    var accessibilityAuthorized: Bool { get }
    var phaseDelay: TimeInterval { get }

    func prepare(direction: SpaceDirection) -> Bool
    func post(_ phase: SpaceGesturePhase) -> Bool
    func discardPreparedEvents()
}

/// Builds the instant Dock swipe used by Tinycast. Unlike the window-moving
/// transaction, this posts no mouse events and no companion gesture event.
final class CoreGraphicsDisplaySpaceSwitchEventPoster: DisplaySpaceSwitchEventPosting {
    private struct PreparedPhase {
        let phase: SpaceGesturePhase
        let event: CGEvent
    }

    private let augmentedEvents: Bool
    private let naturalScrollingProvider: () -> Bool
    private var preparedPhases = [PreparedPhase]()

    init(
        augmentedEvents: Bool = ProcessInfo.processInfo.isOperatingSystemAtLeast(
            OperatingSystemVersion(majorVersion: 27, minorVersion: 0, patchVersion: 0)
        ),
        naturalScrollingProvider: @escaping () -> Bool = {
            UserDefaults.standard.object(forKey: "com.apple.swipescrolldirection") as? Bool ?? true
        }
    ) {
        self.augmentedEvents = augmentedEvents
        self.naturalScrollingProvider = naturalScrollingProvider
    }

    var accessibilityAuthorized: Bool {
        AXIsProcessTrusted()
    }

    var phaseDelay: TimeInterval {
        augmentedEvents ? 0.01 : 0
    }

    func prepare(direction requestedDirection: SpaceDirection) -> Bool {
        discardPreparedEvents()
        let direction = augmentedEvents && naturalScrollingProvider()
            ? requestedDirection.reversed
            : requestedDirection
        var phases = [PreparedPhase]()
        for phase in SpaceGesturePhase.allCases {
            guard let event = makeEvent(phase: phase, direction: direction) else {
                return false
            }
            phases.append(PreparedPhase(phase: phase, event: event))
        }
        preparedPhases = phases
        return true
    }

    func post(_ phase: SpaceGesturePhase) -> Bool {
        guard let prepared = preparedPhases.first(where: { $0.phase == phase }) else {
            return false
        }
        prepared.event.post(tap: .cgSessionEventTap)
        return true
    }

    func discardPreparedEvents() {
        preparedPhases.removeAll(keepingCapacity: true)
    }

    private func makeEvent(phase: SpaceGesturePhase, direction: SpaceDirection) -> CGEvent? {
        guard let event = CGEvent(source: nil) else { return nil }
        let timestamp = mach_absolute_time()
        for field in SpaceGesture.fields(
            for: phase,
            direction: direction,
            augmented: augmentedEvents,
            timestamp: timestamp,
            profile: .displaySwitch
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
            guard var bytes = event.data as Data?, bytes.starts(with: [0, 0, 0, 2]) else {
                return nil
            }
            bytes.append(SpaceGesture.payloadRecord(
                for: phase,
                direction: direction,
                timestamp: timestamp,
                profile: .displaySwitch
            ))
            guard let augmented = CGEvent(withDataAllocator: nil, data: bytes as CFData) else {
                return nil
            }
            preparedEvent = augmented
        } else {
            preparedEvent = event
        }
        preparedEvent.setIntegerValueField(.eventSourceUserData, value: spaceMoveSyntheticEventTag)
        return preparedEvent
    }
}

final class SpaceSwitcher: DisplaySpaceSwitching {
    private let eventPoster: DisplaySpaceSwitchEventPosting
    private let scheduler: SpaceMoveScheduler
    private let neighborAvailable: (SpaceDirection, NSScreen?) -> Bool?
    private let settleDelay: TimeInterval
    private let coordinator: SpaceOperationCoordinator
    private let currentSpaceProvider: (NSScreen?) -> UInt64?
    private let leftMouseButtonPressed: () -> Bool
    private let physicalInputMonitor: SpacePhysicalInputMonitoring
    private var operation: SpaceOperationCoordinator.Operation?
    private var initialSpaceID: UInt64?
    private var gestureStarted = false
    private var gestureEnded = false
    private var switchInProgress = false
    private var executionID: UInt64 = 0
    private var originalMouseLocation: CGPoint?
    private var warpedMouseLocation: CGPoint?
    private var beforeSwitch: (() -> Void)?

    var isSpaceActionInProgress: Bool { switchInProgress }

    init(
        eventPoster: DisplaySpaceSwitchEventPosting = CoreGraphicsDisplaySpaceSwitchEventPoster(),
        scheduler: @escaping SpaceMoveScheduler = { delay, action in
            DispatchQueue.main.asyncAfter(deadline: .now() + delay, execute: action)
        },
        neighborAvailable: @escaping (SpaceDirection, NSScreen?) -> Bool? = { direction, screen in
            guard let point = screen.map({ $0.frame.screenFlipped.centerPoint })
                ?? CGEvent(source: nil)?.location else { return nil }
            return SkyLightSpaceNeighborChecker.shared.hasNeighbor(
                direction: direction, at: point, scope: .all
            )
        },
        settleDelay: TimeInterval = 0.06,
        coordinator: SpaceOperationCoordinator = .shared,
        currentSpaceProvider: @escaping (NSScreen?) -> UInt64? = { screen in
            guard let point = screen.map({ $0.frame.screenFlipped.centerPoint })
                ?? CGEvent(source: nil)?.location else { return nil }
            return SkyLightSpaceNeighborChecker.shared.currentSpace(at: point)
        },
        leftMouseButtonPressed: @escaping () -> Bool = {
            CGEventSource.buttonState(.combinedSessionState, button: .left)
        },
        physicalInputMonitor: SpacePhysicalInputMonitoring = SpacePhysicalInputMonitor()
    ) {
        self.eventPoster = eventPoster
        self.scheduler = scheduler
        self.neighborAvailable = neighborAvailable
        self.settleDelay = settleDelay
        self.coordinator = coordinator
        self.currentSpaceProvider = currentSpaceProvider
        self.leftMouseButtonPressed = leftMouseButtonPressed
        self.physicalInputMonitor = physicalInputMonitor
    }

    func execute(parameters: ExecutionParameters) -> Bool {
        execute(parameters: parameters, continuing: nil)
    }

    func execute(parameters: ExecutionParameters, continuing operation: SpaceOperationCoordinator.Operation?) -> Bool {
        execute(parameters: parameters, continuing: operation, beforeSwitch: nil)
    }

    func execute(parameters: ExecutionParameters,
                 continuing operation: SpaceOperationCoordinator.Operation?,
                 beforeSwitch: (() -> Void)?) -> Bool {
        guard let direction = SpaceDirection(switchAction: parameters.action) else {
            return false
        }
        guard !switchInProgress else {
            Logger.log("Ignoring overlapping Space switch")
            return true
        }
        guard let operation = coordinator.begin(continuing: operation), !leftMouseButtonPressed() else { return true }
        // Keep confirmation on the original display even if the user moves
        // the pointer to another display while the gesture is in flight.
        let cursor = CGEvent(source: nil)?.location
        let targetScreen = parameters.screen ?? NSScreen.screens.first { screen in
            cursor.map { screen.frame.screenFlipped.contains($0) } == true
        }
        guard let hasNeighbor = neighborAvailable(direction, targetScreen) else {
            Logger.log("Ignoring Space switch: unable to determine the adjacent Space")
            return true
        }
        if !hasNeighbor {
            Logger.log("Ignoring Space switch at the end of this display's Spaces")
            return true
        }
        guard eventPoster.accessibilityAuthorized else {
            NSSound.beep()
            Logger.log("Accessibility permission is required to switch Spaces")
            return true
        }
        guard let initialSpaceID = currentSpaceProvider(targetScreen) else {
            Logger.log("Ignoring Space switch: unable to confirm the currently displayed Space")
            return true
        }
        guard eventPoster.prepare(direction: direction) else {
            NSSound.beep()
            Logger.log("Unable to prepare the Space switch gesture")
            return true
        }

        if let screen = parameters.screen {
            guard let currentLocation = CGEvent(source: nil)?.location else {
                eventPoster.discardPreparedEvents()
                NSSound.beep()
                Logger.log("Unable to locate the cursor for a display-specific Space switch")
                return true
            }
            let displayFrame = screen.frame.screenFlipped
            if !displayFrame.contains(currentLocation) {
                let destination = displayFrame.centerPoint
                guard CGWarpMouseCursorPosition(destination) == .success else {
                    eventPoster.discardPreparedEvents()
                    NSSound.beep()
                    Logger.log("Unable to target the window's display for a Space switch")
                    return true
                }
                originalMouseLocation = currentLocation
                warpedMouseLocation = destination
            }
        }

        executionID &+= 1
        let currentExecutionID = executionID
        switchInProgress = true
        self.operation = operation
        self.initialSpaceID = initialSpaceID
        self.beforeSwitch = beforeSwitch
        gestureStarted = false
        gestureEnded = false
        physicalInputMonitor.start { [weak self] in
            self?.finish(executionID: currentExecutionID, restoreCursor: false)
        }
        if warpedMouseLocation != nil {
            scheduler(0.03) { [weak self] in
                self?.postPhase(at: 0, screen: targetScreen, executionID: currentExecutionID)
            }
        } else {
            postPhase(at: 0, screen: targetScreen, executionID: currentExecutionID)
        }
        return true
    }

    private func postPhase(at index: Int, screen: NSScreen?, executionID: UInt64) {
        guard switchInProgress,
              self.executionID == executionID,
              SpaceGesturePhase.allCases.indices.contains(index)
        else { return }

        guard coordinator.canContinue else {
            finish(executionID: executionID)
            return
        }

        let phase = SpaceGesturePhase.allCases[index]
        if phase == .ended {
            // The final velocity commits the instant Dock swipe. Submit a
            // followed window's transfer immediately beside that event, after
            // cursor targeting and gesture pacing, with no verification wait.
            let action = beforeSwitch
            beforeSwitch = nil
            action?()
        }
        guard eventPoster.post(phase) else {
            finish(executionID: executionID)
            return
        }
        if phase == .began { gestureStarted = true }
        if phase == .ended { gestureEnded = true }

        let nextIndex = index + 1
        if SpaceGesturePhase.allCases.indices.contains(nextIndex) {
            let delay = eventPoster.phaseDelay
            if delay > 0 {
                scheduler(delay) { [weak self] in
                    self?.postPhase(at: nextIndex, screen: screen, executionID: executionID)
                }
            } else {
                postPhase(at: nextIndex, screen: screen, executionID: executionID)
            }
        } else {
            scheduler(settleDelay) { [weak self] in
                self?.confirmSpaceChange(screen: screen, poll: 0, executionID: executionID)
            }
        }
    }

    private func confirmSpaceChange(screen: NSScreen?, poll: Int, executionID: UInt64) {
        guard switchInProgress, self.executionID == executionID else { return }
        if !coordinator.canContinue {
            finish(executionID: executionID)
        } else if let current = currentSpaceProvider(screen), current != initialSpaceID {
            finish(executionID: executionID)
        } else if poll >= 30 {
            Logger.log("Space switch timed out waiting for the displayed Space to change")
            finish(executionID: executionID)
        } else {
            scheduler(0.05) { [weak self] in
                self?.confirmSpaceChange(screen: screen, poll: poll + 1, executionID: executionID)
            }
        }
    }

    private func finish(executionID: UInt64, restoreCursor: Bool = true) {
        guard switchInProgress, self.executionID == executionID else { return }
        if gestureStarted, !gestureEnded {
            _ = eventPoster.post(.ended)
        }
        physicalInputMonitor.stop()
        if restoreCursor, let originalMouseLocation, let warpedMouseLocation,
           let currentLocation = CGEvent(source: nil)?.location,
           hypot(currentLocation.x - warpedMouseLocation.x,
                 currentLocation.y - warpedMouseLocation.y) <= 2 {
            _ = CGWarpMouseCursorPosition(originalMouseLocation)
        }
        originalMouseLocation = nil
        warpedMouseLocation = nil
        beforeSwitch = nil
        eventPoster.discardPreparedEvents()
        switchInProgress = false
        initialSpaceID = nil
        gestureStarted = false
        gestureEnded = false
        operation = nil
    }

    deinit {
        if switchInProgress {
            finish(executionID: executionID)
        } else {
            eventPoster.discardPreparedEvents()
        }
    }
}
