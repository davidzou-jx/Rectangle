import Cocoa
import Darwin

struct ManagedDisplaySpaceSwitch: Equatable {
    let sourceID: UInt64
    let destinationID: UInt64
    let displayIdentifier: String

    var reversed: ManagedDisplaySpaceSwitch {
        ManagedDisplaySpaceSwitch(sourceID: destinationID, destinationID: sourceID,
                                  displayIdentifier: displayIdentifier)
    }
}

extension ManagedSpaceTopology {
    /// The inverse of desktop(number:in:), using the same numbering as numbered shortcuts.
    /// Native full-screen Spaces have no desktop number.
    static func currentDesktopNumber(on displayIdentifier: String, in displays: [[String: Any]]) -> Int? {
        guard let currentID = currentSpace(for: displayIdentifier, in: displays) else { return nil }
        var ordinal = 0
        for display in displays {
            guard let spaces = display["Spaces"] as? [[String: Any]] else { return nil }
            for space in spaces where (space["type"] as? NSNumber)?.intValue == 0 {
                ordinal += 1
                if (display["Display Identifier"] as? String) == displayIdentifier,
                   (space["id64"] as? NSNumber)?.uint64Value == currentID { return ordinal }
            }
        }
        return nil
    }

    /// Desktop numbers span displays, but exclude native full-screen Spaces.
    /// Resolve a fresh ID each time: Mission Control can reorder/remove desktops.
    static func desktop(number: Int, in displays: [[String: Any]]) -> ManagedDisplaySpaceSwitch? {
        guard number > 0, isValid(displays) else { return nil }
        var ordinal = 0
        for display in displays {
            guard let identifier = display["Display Identifier"] as? String,
                  !identifier.isEmpty,
                  let current = display["Current Space"] as? [String: Any],
                  let source = (current["id64"] as? NSNumber)?.uint64Value,
                  source != 0,
                  let spaces = display["Spaces"] as? [[String: Any]],
                  spaces.contains(where: { ($0["id64"] as? NSNumber)?.uint64Value == source }) else { return nil }
            for space in spaces {
                guard let type = (space["type"] as? NSNumber)?.intValue else { return nil }
                if type != 0 { continue }
                guard let destination = (space["id64"] as? NSNumber)?.uint64Value,
                      destination != 0 else { return nil }
                ordinal += 1
                if ordinal == number {
                    return ManagedDisplaySpaceSwitch(sourceID: source, destinationID: destination,
                                                     displayIdentifier: identifier)
                }
            }
        }
        return nil
    }
}

protocol ManagedDisplaySpaceActivating: AnyObject {
    var isAvailable: Bool { get }
    func desktop(number: Int) -> ManagedDisplaySpaceSwitch?
    func currentSpace(on displayIdentifier: String) -> UInt64?
    func destinationIsVisible(_ target: ManagedDisplaySpaceSwitch) -> Bool?
    func activate(_ target: ManagedDisplaySpaceSwitch) -> Bool
}

/// On macOS 27 the setter is asynchronous, despite the published header's
/// synchronous declaration. Changing the ID alone leaves both Spaces visible:
/// submit WillSwitch/Show/Hide/SetCurrent together, then verify asynchronously.
final class SkyLightDisplaySpaceActivation: ManagedDisplaySpaceActivating {
    private typealias MainConnection = @convention(c) () -> Int32
    private typealias CopySpacesForWindows = @convention(c) (Int32, Int32, CFArray) -> Unmanaged<CFArray>?
    private let framework: UnsafeMutableRawPointer?
    private let connection: Int32?
    private let copySpacesForWindows: CopySpacesForWindows?
    private let operationNames = [
        "SLSBridgedWillSwitchSpacesOperation", "SLSBridgedShowSpacesOperation",
        "SLSBridgedHideSpacesOperation", "SLSBridgedManagedDisplaySetCurrentSpaceOperation"
    ]

    init() {
        let framework = dlopen("/System/Library/PrivateFrameworks/SkyLight.framework/Versions/A/SkyLight", RTLD_NOW)
        self.framework = framework
        if let framework, let main = dlsym(framework, "SLSMainConnectionID"),
           let spaces = dlsym(framework, "SLSCopySpacesForWindows") {
            connection = unsafeBitCast(main, to: MainConnection.self)()
            copySpacesForWindows = unsafeBitCast(spaces, to: CopySpacesForWindows.self)
        } else {
            connection = nil
            copySpacesForWindows = nil
        }
    }

    var isAvailable: Bool {
        guard framework != nil, connection != nil, copySpacesForWindows != nil else { return false }
        return operationNames.allSatisfy { name in
            guard let cls = NSClassFromString(name),
                  hasMethod(cls, "performWithWMBridgeDelegate", encoding: "v16@0:8") else { return false }
            if name == "SLSBridgedManagedDisplaySetCurrentSpaceOperation" {
                return hasMethod(cls, "initWithDisplayIdentifier:spaceID:", encoding: "@32@0:8@16Q24")
            }
            return hasMethod(cls, "initWithSpaces:", encoding: "@24@0:8@16")
        }
    }

    private func hasMethod(_ cls: AnyClass, _ name: String, encoding: String) -> Bool {
        guard let method = class_getInstanceMethod(cls, NSSelectorFromString(name)),
              let actual = method_getTypeEncoding(method) else { return false }
        return String(cString: actual) == encoding
    }

    func desktop(number: Int) -> ManagedDisplaySpaceSwitch? {
        guard let displays = SkyLightSpaceNeighborChecker.shared.managedDisplaySpaces() else { return nil }
        return ManagedSpaceTopology.desktop(number: number, in: displays)
    }

    func currentSpace(on displayIdentifier: String) -> UInt64? {
        guard let displays = SkyLightSpaceNeighborChecker.shared.managedDisplaySpaces() else { return nil }
        return ManagedSpaceTopology.currentSpace(for: displayIdentifier, in: displays)
    }

    func destinationIsVisible(_ target: ManagedDisplaySpaceSwitch) -> Bool? {
        guard currentSpace(on: target.displayIdentifier) == target.destinationID else { return false }
        if target.sourceID == target.destinationID { return true }
        guard let connection, let copySpacesForWindows,
              let visible = CGWindowListCopyWindowInfo([.optionOnScreenOnly, .excludeDesktopElements], kCGNullWindowID)
                as? [[String: Any]] else { return nil }
        for window in visible {
            guard (window[kCGWindowLayer as String] as? NSNumber)?.intValue == 0,
                  (window[kCGWindowAlpha as String] as? NSNumber)?.doubleValue ?? 1 > 0,
                  let id = window[kCGWindowNumber as String] as? NSNumber else { continue }
            let windows = [id] as NSArray
            guard let memberships = copySpacesForWindows(connection, 7, unsafeBitCast(windows, to: CFArray.self))?
                .takeRetainedValue() as? [NSNumber] else { return nil }
            // Sticky windows may be visible on both Spaces. A resident source
            // window still visible indicates the setter-only failure mode.
            if memberships.count == 1, memberships[0].uint64Value == target.sourceID { return false }
        }
        return true
    }

    func activate(_ target: ManagedDisplaySpaceSwitch) -> Bool {
        guard isAvailable, target.sourceID != 0, target.destinationID != 0,
              currentSpace(on: target.displayIdentifier) == target.sourceID,
              let displays = SkyLightSpaceNeighborChecker.shared.managedDisplaySpaces(),
              let display = displays.first(where: { ($0["Display Identifier"] as? String) == target.displayIdentifier }),
              let spaces = display["Spaces"] as? [[String: Any]],
              ManagedSpaceTopology.isValid(displays),
              spaces.contains(where: { ($0["id64"] as? NSNumber)?.uint64Value == target.destinationID })
        else { return false }
        if target.sourceID == target.destinationID { return true }
        // Prepare the entire batch before changing any WindowServer state.
        var operations = [AnyObject]()
        for name in operationNames {
            guard let cls = NSClassFromString(name),
                  let allocated = (cls as AnyObject).perform(NSSelectorFromString("alloc"))?.takeUnretainedValue()
            else { return false }
            let operation: AnyObject?
            if name == "SLSBridgedManagedDisplaySetCurrentSpaceOperation" {
                let selector = NSSelectorFromString("initWithDisplayIdentifier:spaceID:")
                typealias Initialize = @convention(c) (AnyObject, Selector, NSString, UInt64) -> AnyObject?
                let initialize = unsafeBitCast(allocated.method(for: selector), to: Initialize.self)
                operation = initialize(allocated, selector, target.displayIdentifier as NSString, target.destinationID)
            } else {
                let selector = NSSelectorFromString("initWithSpaces:")
                typealias Initialize = @convention(c) (AnyObject, Selector, NSArray) -> AnyObject?
                let initialize = unsafeBitCast(allocated.method(for: selector), to: Initialize.self)
                let spaceID = name == "SLSBridgedHideSpacesOperation" ? target.sourceID : target.destinationID
                operation = initialize(allocated, selector, [NSNumber(value: spaceID)] as NSArray)
            }
            guard let operation else { return false }
            operations.append(operation)
        }
        let selector = NSSelectorFromString("performWithWMBridgeDelegate")
        typealias Perform = @convention(c) (AnyObject, Selector) -> Void
        for operation in operations {
            let perform = unsafeBitCast(operation.method(for: selector), to: Perform.self)
            perform(operation, selector)
        }
        return true
    }
}

final class NumberedSpaceSwitcher: SpaceActionExecuting {
    private let activation: ManagedDisplaySpaceActivating
    private let coordinator: SpaceOperationCoordinator
    private let scheduler: SpaceMoveScheduler
    private let accessibilityAuthorized: () -> Bool
    private let mousePressed: () -> Bool
    private let inputMonitor: SpacePhysicalInputMonitoring
    private let clock: () -> TimeInterval
    private let workspaceNotificationCenter: NotificationCenter
    private var spaceObserver: NSObjectProtocol?
    private var operation: SpaceOperationCoordinator.Operation?
    private var target: ManagedDisplaySpaceSwitch?
    private var interrupted = false
    private var recovering = false
    private var deadline: TimeInterval = 0
    private var stableSamples = 0
    private var lastSampleTime: TimeInterval?
    private var pollScheduled = false
    private var completion: ((Bool) -> Void)?
    private var ownershipIsValid: () -> Bool = { true }
    private var executionID: UInt64 = 0
    var isSpaceActionInProgress: Bool { operation != nil }

    init(activation: ManagedDisplaySpaceActivating = SkyLightDisplaySpaceActivation(),
         coordinator: SpaceOperationCoordinator = .shared,
         scheduler: @escaping SpaceMoveScheduler = { delay, action in
             DispatchQueue.main.asyncAfter(deadline: .now() + delay, execute: action)
         },
         accessibilityAuthorized: @escaping () -> Bool = AXIsProcessTrusted,
         mousePressed: @escaping () -> Bool = { CGEventSource.buttonState(.combinedSessionState, button: .left) },
         inputMonitor: SpacePhysicalInputMonitoring = SpacePhysicalInputMonitor(),
         clock: @escaping () -> TimeInterval = { ProcessInfo.processInfo.systemUptime },
         workspaceNotificationCenter: NotificationCenter = NSWorkspace.shared.notificationCenter) {
        self.activation = activation
        self.coordinator = coordinator
        self.scheduler = scheduler
        self.accessibilityAuthorized = accessibilityAuthorized
        self.mousePressed = mousePressed
        self.inputMonitor = inputMonitor
        self.clock = clock
        self.workspaceNotificationCenter = workspaceNotificationCenter
        spaceObserver = workspaceNotificationCenter.addObserver(
            forName: NSWorkspace.activeSpaceDidChangeNotification, object: nil, queue: .main
        ) { [weak self] _ in self?.confirm() }
    }

    func execute(parameters: ExecutionParameters) -> Bool {
        guard let number = parameters.action.desktopNumber else { return false }
        guard let target = activation.desktop(number: number) else { return true }
        start(target, continuing: nil, ownershipIsValid: { true }, completion: nil)
        return true
    }

    func switchSpace(to target: ManagedDisplaySpaceSwitch,
                     continuing operation: SpaceOperationCoordinator.Operation,
                     ownershipIsValid: @escaping () -> Bool = { true },
                     completion: @escaping (Bool) -> Void) {
        start(target, continuing: operation, ownershipIsValid: ownershipIsValid, completion: completion)
    }

    private func start(_ target: ManagedDisplaySpaceSwitch,
                       continuing operation: SpaceOperationCoordinator.Operation?,
                       ownershipIsValid: @escaping () -> Bool,
                       completion: ((Bool) -> Void)?) {
        guard !isSpaceActionInProgress, !mousePressed(),
              let operation = coordinator.begin(continuing: operation) else { completion?(false); return }
        guard activation.isAvailable, accessibilityAuthorized() else {
            NSSound.beep()
            Logger.log("Direct desktop switching requires the bridged Space operations and Accessibility permission")
            completion?(false)
            return
        }
        guard target.sourceID != target.destinationID else { completion?(true); return }
        self.operation = operation
        self.completion = completion
        self.ownershipIsValid = ownershipIsValid
        self.target = target
        interrupted = false
        recovering = false
        stableSamples = 0
        lastSampleTime = nil
        pollScheduled = false
        deadline = clock() + 1.5
        executionID &+= 1
        inputMonitor.start { [weak self] in self?.interrupt() }
        guard activation.activate(target) else {
            finish(success: false)
            Logger.log("Unable to submit the direct desktop switch")
            NSSound.beep()
            return
        }
        scheduleConfirmation()
    }

    // A submitted bridged operation cannot be cancelled. Retain its lease until
    // it settles, but discard queued intent and never undo the user's choice.
    func interrupt() { interrupted = true }

    private func scheduleConfirmation() {
        guard isSpaceActionInProgress, !pollScheduled else { return }
        pollScheduled = true
        let id = executionID
        scheduler(0.01) { [weak self] in
            guard let self, self.isSpaceActionInProgress, self.executionID == id else { return }
            self.pollScheduled = false
            self.confirm()
        }
    }

    private func confirm() {
        guard isSpaceActionInProgress, let target else { return }
        if !coordinator.canContinue { interrupted = true }
        // Validate every display before recovery, regardless of workspace
        // observer ordering. Keep the lease while a submitted switch settles.
        if !ownershipIsValid() { interrupted = true }
        let current = activation.currentSpace(on: target.displayIdentifier)
        if let current, current != target.sourceID, current != target.destinationID {
            // Another switch owns this display now. Never switch it back.
            finish(success: false)
            return
        }
        let now = clock()
        if current == target.destinationID && activation.destinationIsVisible(target) == true {
            // Multiple notifications in one run-loop turn are one sample.
            if lastSampleTime.map({ now - $0 >= 0.01 - 0.000001 }) ?? true {
                stableSamples += 1
                lastSampleTime = now
            }
        } else {
            stableSamples = 0
            lastSampleTime = nil
        }
        if stableSamples >= 3 { finish(success: !recovering && !interrupted); return }
        guard now < deadline else {
            Logger.log("Direct desktop switch did not settle on its destination")
            if !recovering, !interrupted, current == target.destinationID {
                // A partial Show/Hide/SetCurrent must not strand visible windows
                // from two desktops. Restore only while our destination is current.
                let original = target.reversed
                // Arm recovery before submission: a workspace notification may
                // arrive from the activation call itself.
                self.target = original
                recovering = true
                stableSamples = 0
                lastSampleTime = nil
                deadline = clock() + 1.5
                if activation.activate(original) {
                    scheduleConfirmation()
                    return
                }
            }
            finish(success: false)
            NSSound.beep()
            return
        }
        scheduleConfirmation()
    }

    private func finish(success: Bool) {
        inputMonitor.stop()
        let completion = self.completion
        self.completion = nil
        ownershipIsValid = { true }
        target = nil
        pollScheduled = false
        operation = nil
        completion?(success)
    }

    deinit {
        inputMonitor.stop()
        if let spaceObserver { workspaceNotificationCenter.removeObserver(spaceObserver) }
    }
}
