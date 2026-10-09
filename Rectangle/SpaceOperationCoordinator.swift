import Cocoa

/// Space actions and their scheduled callbacks run on the main queue. A move
/// and its follow gesture share one operation; unrelated commands cannot join it.
final class SpaceOperationCoordinator {
    static let shared = SpaceOperationCoordinator()

    final class Operation {
        fileprivate init() {}
        fileprivate var cancelled = false
    }

    private weak var activeOperation: Operation?
    private let environmentIsSafe: () -> Bool
    private let clock: () -> TimeInterval
    private let workspaceNotificationCenter: NotificationCenter
    private let quietPeriod: TimeInterval
    private var lastSpaceChange: TimeInterval?
    private var spaceObserver: NSObjectProtocol?
    private var verifiedSwitchState: [String: UInt64]?
    private var verifiedSwitchTime: TimeInterval?
    private var lifecycleObservers = [(NotificationCenter, NSObjectProtocol)]()
    private var sessionActive = true
    private var awake = true

    init(environmentIsSafe: @escaping () -> Bool = { !WindowAnimationInterruptionPolicy.missionControlActive },
         clock: @escaping () -> TimeInterval = { ProcessInfo.processInfo.systemUptime },
         workspaceNotificationCenter: NotificationCenter = NSWorkspace.shared.notificationCenter,
         quietPeriod: TimeInterval = 0.15,
         notificationCenter: NotificationCenter = .default) {
        self.environmentIsSafe = environmentIsSafe
        self.clock = clock
        self.workspaceNotificationCenter = workspaceNotificationCenter
        self.quietPeriod = quietPeriod
        spaceObserver = workspaceNotificationCenter.addObserver(
            forName: NSWorkspace.activeSpaceDidChangeNotification, object: nil, queue: .main
        ) { [weak self] _ in
            guard let self else { return }
            self.lastSpaceChange = self.clock()
        }
        for name in [NSWorkspace.sessionDidResignActiveNotification, NSWorkspace.willSleepNotification,
                     NSWorkspace.sessionDidBecomeActiveNotification, NSWorkspace.didWakeNotification] {
            let observer = workspaceNotificationCenter.addObserver(forName: name, object: nil, queue: .main) { [weak self] _ in
                guard let self else { return }
                if name == NSWorkspace.sessionDidResignActiveNotification { self.sessionActive = false }
                if name == NSWorkspace.sessionDidBecomeActiveNotification { self.sessionActive = true }
                if name == NSWorkspace.willSleepNotification { self.awake = false }
                if name == NSWorkspace.didWakeNotification { self.awake = true }
                self.interrupt()
            }
            lifecycleObservers.append((workspaceNotificationCenter, observer))
        }
        let screenObserver = notificationCenter.addObserver(
            forName: NSApplication.didChangeScreenParametersNotification, object: nil, queue: .main
        ) { [weak self] _ in self?.interrupt() }
        lifecycleObservers.append((notificationCenter, screenObserver))
    }

    var isOperationInProgress: Bool { activeOperation != nil }
    var canContinue: Bool { sessionActive && awake && activeOperation?.cancelled != true && environmentIsSafe() }

    private func interrupt() {
        activeOperation?.cancelled = true
        lastSpaceChange = clock()
        invalidateVerifiedSwitch()
    }

    func begin(continuing operation: Operation? = nil) -> Operation? {
        guard canContinue else {
            Logger.log("Ignoring Space action while the session or window environment is unavailable")
            return nil
        }
        if let operation {
            return activeOperation === operation ? operation : nil
        }
        guard activeOperation == nil else {
            Logger.log("Ignoring Space action while another Space operation is in progress")
            return nil
        }
        // This also covers native Space changes. SkyLight's animation query
        // does not reliably report transitions on supported macOS versions.
        if let lastSpaceChange, clock() - lastSpaceChange < quietPeriod {
            Logger.log("Ignoring Space action while a Space change is settling")
            return nil
        }
        let operation = Operation()
        activeOperation = operation
        invalidateVerifiedSwitch()
        return operation
    }

    // Only switch-only callers can reuse a recently verified topology. Window
    // moves still use begin(), including its protection around native changes.
    func beginSwitch(currentState: [String: UInt64]) -> Operation? {
        guard canContinue, activeOperation == nil else { return nil }
        if verifiedSwitchState == currentState, let verifiedSwitchTime,
           clock() - verifiedSwitchTime < quietPeriod * 2 {
            let operation = Operation()
            activeOperation = operation
            invalidateVerifiedSwitch()
            return operation
        }
        return begin()
    }

    func verifiedSwitch(_ operation: Operation, currentState: [String: UInt64]) {
        guard activeOperation === operation else { return }
        verifiedSwitchState = currentState
        verifiedSwitchTime = clock()
    }

    func invalidateVerifiedSwitch() {
        verifiedSwitchState = nil
        verifiedSwitchTime = nil
    }

    deinit {
        if let spaceObserver { workspaceNotificationCenter.removeObserver(spaceObserver) }
        for (center, observer) in lifecycleObservers { center.removeObserver(observer) }
    }
}
