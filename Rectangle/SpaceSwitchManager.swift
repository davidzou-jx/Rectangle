import Cocoa

/// Carbon hotkeys and NSEvent monitors can receive the same physical press in
/// either order. Only a bound, standalone switch shortcut extends a burst.
final class SpaceSwitchShortcutPolicy {
    static let shared = SpaceSwitchShortcutPolicy()

    struct Shortcut: Hashable {
        let keyCode: Int
        let modifiers: UInt

        init(keyCode: Int, modifiers: NSEvent.ModifierFlags) {
            self.keyCode = keyCode
            self.modifiers = modifiers.intersection([.command, .option, .control, .shift]).rawValue
        }
    }

    var shortcuts = Set<Shortcut>()

    func matches(_ event: NSEvent) -> Bool {
        event.type == .keyDown && shortcuts.contains(
            Shortcut(keyCode: Int(event.keyCode), modifiers: event.modifierFlags)
        )
    }
}

/// Serializes switch-only bursts while keeping one bounded destination per
/// display. Window moves continue to use the coordinator's stricter entry path.
final class SpaceSwitchManager: SpaceActionExecuting {
    private struct Space: Equatable {
        let id: UInt64
        let type: Int
    }
    private struct Display {
        let identifier: String
        let current: UInt64
        let spaces: [Space]
    }
    private struct Intent {
        let display: String
        let destination: UInt64
        let screen: NSScreen?
        let requiresDirect: Bool
    }
    private struct Transition {
        let target: ManagedDisplaySpaceSwitch
        let direct: Bool
    }

    private let activation: ManagedDisplaySpaceActivating
    private let directSwitcher: NumberedSpaceSwitcher
    private let gestureSwitcher: SpaceSwitcher
    private let coordinator: SpaceOperationCoordinator
    private let topologyProvider: () -> [[String: Any]]?
    private let displayProvider: (NSScreen?) -> String?
    private let screenProvider: (String) -> NSScreen?
    private let scheduler: SpaceMoveScheduler
    private let clock: () -> TimeInterval
    private let mousePressed: () -> Bool
    private let inputMonitor: SpacePhysicalInputMonitoring
    private let workspaceNotificationCenter: NotificationCenter
    private var spaceObserver: NSObjectProtocol?
    private var operation: SpaceOperationCoordinator.Operation?
    private var pending = [Intent]()
    private var active: Transition?
    private var expectedState = [String: UInt64]()
    private var expectedLayout = [String: [Space]]()
    private var interrupted = false
    private var verifyingGesture = false
    private var stableSamples = 0
    private var lastSampleTime: TimeInterval?
    private var deadline: TimeInterval = 0
    private var pollScheduled = false
    private var executionID: UInt64 = 0

    var isSpaceActionInProgress: Bool { operation != nil }

    init(activation: ManagedDisplaySpaceActivating = SkyLightDisplaySpaceActivation(),
         coordinator: SpaceOperationCoordinator = .shared,
         topologyProvider: @escaping () -> [[String: Any]]? = {
             SkyLightSpaceNeighborChecker.shared.managedDisplaySpaces()
         },
         displayProvider: @escaping (NSScreen?) -> String? = { screen in
             guard let point = screen.map({ $0.frame.screenFlipped.centerPoint })
                 ?? CGEvent(source: nil)?.location else { return nil }
             return SkyLightSpaceNeighborChecker.shared.displayIdentifier(at: point)
         },
         screenProvider: @escaping (String) -> NSScreen? = { identifier in
             NSScreen.screens.first {
                 SkyLightSpaceNeighborChecker.shared.displayIdentifier(at: $0.frame.screenFlipped.centerPoint) == identifier
             }
         },
         scheduler: @escaping SpaceMoveScheduler = { delay, action in
             DispatchQueue.main.asyncAfter(deadline: .now() + delay, execute: action)
         },
         clock: @escaping () -> TimeInterval = { ProcessInfo.processInfo.systemUptime },
         accessibilityAuthorized: @escaping () -> Bool = AXIsProcessTrusted,
         mousePressed: @escaping () -> Bool = { CGEventSource.buttonState(.combinedSessionState, button: .left) },
         inputMonitor: SpacePhysicalInputMonitoring = SpacePhysicalInputMonitor(ignoringEvent: SpaceSwitchShortcutPolicy.shared.matches),
         directInputMonitor: SpacePhysicalInputMonitoring = SpacePhysicalInputMonitor(ignoringEvent: SpaceSwitchShortcutPolicy.shared.matches),
         gestureInputMonitor: SpacePhysicalInputMonitoring = SpacePhysicalInputMonitor(ignoringEvent: SpaceSwitchShortcutPolicy.shared.matches),
         eventPoster: DisplaySpaceSwitchEventPosting = CoreGraphicsDisplaySpaceSwitchEventPoster(),
         workspaceNotificationCenter: NotificationCenter = NSWorkspace.shared.notificationCenter) {
        self.activation = activation
        self.coordinator = coordinator
        self.topologyProvider = topologyProvider
        self.displayProvider = displayProvider
        self.screenProvider = screenProvider
        self.scheduler = scheduler
        self.clock = clock
        self.mousePressed = mousePressed
        self.inputMonitor = inputMonitor
        self.workspaceNotificationCenter = workspaceNotificationCenter
        directSwitcher = NumberedSpaceSwitcher(
            activation: activation, coordinator: coordinator, scheduler: scheduler,
            accessibilityAuthorized: accessibilityAuthorized, mousePressed: mousePressed,
            inputMonitor: directInputMonitor, clock: clock, workspaceNotificationCenter: workspaceNotificationCenter
        )
        gestureSwitcher = SpaceSwitcher(
            eventPoster: eventPoster, scheduler: scheduler,
            neighborAvailable: { direction, screen in
                guard let raw = topologyProvider(), let display = displayProvider(screen) else { return nil }
                return ManagedSpaceTopology.hasAdjacentDisplayedSpace(on: display, direction: direction, scope: .all, in: raw)
            }, coordinator: coordinator,
            currentSpaceProvider: { screen in
                guard let raw = topologyProvider(), let display = displayProvider(screen) else { return nil }
                return ManagedSpaceTopology.currentSpace(for: display, in: raw)
            }, leftMouseButtonPressed: mousePressed, physicalInputMonitor: gestureInputMonitor,
            clock: clock, workspaceNotificationCenter: workspaceNotificationCenter
        )
        spaceObserver = workspaceNotificationCenter.addObserver(
            forName: NSWorkspace.activeSpaceDidChangeNotification, object: nil, queue: .main
        ) { [weak self] _ in
            guard let self else { return }
            if self.operation != nil {
                guard let displays = self.readTopology(), self.owns(displays) else { self.cancel(); return }
                if self.verifyingGesture { self.confirmGesture() }
            } else if self.readTopology().map(Self.state) != self.expectedState {
                self.coordinator.invalidateVerifiedSwitch()
            }
        }
    }

    func execute(parameters: ExecutionParameters) -> Bool {
        let direction = SpaceDirection(switchAction: parameters.action)
        let number = parameters.action.desktopNumber
        guard direction != nil || number != nil else { return false }
        guard coordinator.canContinue, !mousePressed(), !interrupted,
              let raw = topologyProvider(), let displays = Self.parse(raw) else { cancel(); return true }
        if operation != nil, !owns(displays) { cancel(); return true }

        let intent: Intent
        if let number {
            guard let target = ManagedSpaceTopology.desktop(number: number, in: raw) else { return true }
            intent = Intent(display: target.displayIdentifier, destination: target.destinationID,
                            screen: screenProvider(target.displayIdentifier), requiresDirect: true)
        } else {
            guard let direction, let identifier = displayProvider(parameters.screen),
                  let display = displays.first(where: { $0.identifier == identifier }) else { return true }
            // Current Space IDs can lag behind submission. Advance from intent,
            // clamping every press, rather than accumulating a signed delta.
            let base = pending.first(where: { $0.display == identifier })?.destination
                ?? (active?.target.displayIdentifier == identifier ? active?.target.destinationID : nil)
                ?? display.current
            guard let index = display.spaces.firstIndex(where: { $0.id == base }) else { cancel(); return true }
            let next = min(max(index + (direction == .next ? 1 : -1), 0), display.spaces.count - 1)
            intent = Intent(display: identifier, destination: display.spaces[next].id,
                            screen: parameters.screen ?? screenProvider(identifier), requiresDirect: false)
        }

        if operation == nil {
            let state = Self.state(displays)
            guard let operation = coordinator.beginSwitch(currentState: state) else { return true }
            self.operation = operation
            expectedState = state
            expectedLayout = Self.layout(displays)
            executionID &+= 1
            // Remains installed after completion to invalidate the short-lived
            // fast path on native gestures, clicks, or unrelated keyboard input.
            inputMonitor.start { [weak self] in self?.cancel() }
        }
        if let index = pending.firstIndex(where: { $0.display == intent.display }) {
            pending[index] = intent
        } else {
            pending.append(intent)
        }
        if active == nil { advance() }
        return true
    }

    private func advance() {
        guard let operation, !interrupted, coordinator.canContinue,
              let displays = readTopology(), owns(displays) else { finish(verified: false); return }
        guard !pending.isEmpty else { finish(verified: true); return }
        let intent = pending.removeFirst()
        guard let display = displays.first(where: { $0.identifier == intent.display }),
              let sourceIndex = display.spaces.firstIndex(where: { $0.id == display.current }),
              let destinationIndex = display.spaces.firstIndex(where: { $0.id == intent.destination })
        else { finish(verified: false); return }
        if sourceIndex == destinationIndex { advance(); return }
        let direct = activation.isAvailable && display.spaces[sourceIndex].type == 0
            && display.spaces[destinationIndex].type == 0
        // Numbered commands keep their existing direct-API requirement. Relative
        // full-screen transitions use the proven gesture path, even on macOS 27.
        if intent.requiresDirect && !activation.isAvailable { NSSound.beep(); finish(verified: false); return }
        let stepIndex = direct ? destinationIndex
            : sourceIndex + (destinationIndex > sourceIndex ? 1 : -1)
        let target = ManagedDisplaySpaceSwitch(sourceID: display.current, destinationID: display.spaces[stepIndex].id,
                                              displayIdentifier: intent.display)
        let useDirect = direct
        active = Transition(target: target, direct: useDirect)
        if stepIndex != destinationIndex { pending.insert(intent, at: 0) }
        let id = executionID
        if useDirect {
            directSwitcher.switchSpace(to: target, continuing: operation, ownershipIsValid: { [weak self] in
                guard let self, let displays = self.readTopology() else { return false }
                return self.owns(displays)
            }) { [weak self] success in
                guard let self, self.executionID == id else { return }
                self.completed(success: success)
            }
        } else {
            // Capture the display at request time, even if the pointer changes
            // displays while an earlier request is still in flight.
            guard let screen = intent.screen else { finish(verified: false); return }
            let action: WindowAction = destinationIndex > sourceIndex ? .switchNextSpace : .switchPrevSpace
            gestureSwitcher.switchSpace(parameters: ExecutionParameters(action, screen: screen),
                                        destinationID: target.destinationID, continuing: operation) { [weak self] success in
                guard let self, self.executionID == id else { return }
                guard success, !self.interrupted else { self.finish(verified: false); return }
                self.verifyingGesture = true
                self.stableSamples = 0
                self.lastSampleTime = nil
                self.deadline = self.clock() + 1.5
                self.confirmGesture()
            }
        }
    }

    private func confirmGesture() {
        guard verifyingGesture, let active else { return }
        guard !interrupted, coordinator.canContinue, let displays = readTopology(), owns(displays) else {
            completed(success: false); return
        }
        let now = clock()
        // Older systems may lack the visibility reader. Preserve their gesture
        // fallback with stable exact-ID checks; never relax direct verification.
        if Self.state(displays)[active.target.displayIdentifier] == active.target.destinationID,
           activation.destinationIsVisible(active.target) != false {
            if lastSampleTime.map({ now - $0 >= 0.01 - 0.000001 }) ?? true {
                stableSamples += 1
                lastSampleTime = now
            }
        } else {
            stableSamples = 0
            lastSampleTime = nil
        }
        if stableSamples >= 3 { completed(success: true); return }
        if now >= deadline { completed(success: false); return }
        guard !pollScheduled else { return }
        pollScheduled = true
        let id = executionID
        scheduler(0.01) { [weak self] in
            guard let self, self.executionID == id, self.verifyingGesture else { return }
            self.pollScheduled = false
            self.confirmGesture()
        }
    }

    private func completed(success: Bool) {
        guard success, !interrupted, let active, let displays = readTopology(), owns(displays),
              Self.state(displays)[active.target.displayIdentifier] == active.target.destinationID else {
            finish(verified: false); return
        }
        expectedState[active.target.displayIdentifier] = active.target.destinationID
        self.active = nil
        verifyingGesture = false
        pollScheduled = false
        executionID &+= 1
        advance()
    }

    private func cancel() {
        coordinator.invalidateVerifiedSwitch()
        pending.removeAll()
        guard operation != nil else { return }
        interrupted = true
        if active?.direct == true, directSwitcher.isSpaceActionInProgress {
            directSwitcher.interrupt()
        } else {
            gestureSwitcher.cancel()
            if operation != nil { finish(verified: false) }
        }
    }

    private func finish(verified: Bool) {
        if verified, let operation, let displays = readTopology(), owns(displays) {
            coordinator.verifiedSwitch(operation, currentState: Self.state(displays))
        } else {
            coordinator.invalidateVerifiedSwitch()
        }
        operation = nil
        pending.removeAll()
        active = nil
        interrupted = false
        verifyingGesture = false
        pollScheduled = false
        executionID &+= 1
    }

    private func owns(_ displays: [Display]) -> Bool {
        guard Self.layout(displays) == expectedLayout else { return false }
        return displays.allSatisfy { display in
            if let active, active.target.displayIdentifier == display.identifier {
                return display.current == active.target.sourceID || display.current == active.target.destinationID
            }
            return display.current == expectedState[display.identifier]
        }
    }

    private func readTopology() -> [Display]? { topologyProvider().flatMap(Self.parse) }
    private static func state(_ displays: [Display]) -> [String: UInt64] {
        Dictionary(uniqueKeysWithValues: displays.map { ($0.identifier, $0.current) })
    }
    private static func layout(_ displays: [Display]) -> [String: [Space]] {
        Dictionary(uniqueKeysWithValues: displays.map { ($0.identifier, $0.spaces) })
    }

    private static func parse(_ raw: [[String: Any]]) -> [Display]? {
        guard ManagedSpaceTopology.isValid(raw) else { return nil }
        var displays = [Display]()
        var identifiers = Set<String>()
        for entry in raw {
            guard let identifier = entry["Display Identifier"] as? String, !identifier.isEmpty,
                  identifiers.insert(identifier).inserted,
                  let current = entry["Current Space"] as? [String: Any],
                  let currentID = (current["id64"] as? NSNumber)?.uint64Value,
                  let entries = entry["Spaces"] as? [[String: Any]], !entries.isEmpty else { return nil }
            var spaces = [Space]()
            var ids = Set<UInt64>()
            for entry in entries {
                guard let id = (entry["id64"] as? NSNumber)?.uint64Value, id != 0,
                      ids.insert(id).inserted, let type = (entry["type"] as? NSNumber)?.intValue else { return nil }
                spaces.append(Space(id: id, type: type))
            }
            guard ids.contains(currentID) else { return nil }
            displays.append(Display(identifier: identifier, current: currentID, spaces: spaces))
        }
        return displays.isEmpty ? nil : displays
    }

    deinit {
        inputMonitor.stop()
        if let spaceObserver { workspaceNotificationCenter.removeObserver(spaceObserver) }
    }
}
