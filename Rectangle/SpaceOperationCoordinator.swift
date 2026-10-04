import Cocoa

/// Space actions and their scheduled callbacks run on the main queue. A move
/// and its follow gesture share one operation; unrelated commands cannot join it.
final class SpaceOperationCoordinator {
    static let shared = SpaceOperationCoordinator()

    final class Operation {
        fileprivate init() {}
    }

    private weak var activeOperation: Operation?
    private let environmentIsSafe: () -> Bool
    private let clock: () -> TimeInterval
    private let workspaceNotificationCenter: NotificationCenter
    private let quietPeriod: TimeInterval
    private var lastSpaceChange: TimeInterval?
    private var spaceObserver: NSObjectProtocol?

    init(environmentIsSafe: @escaping () -> Bool = { !WindowAnimationInterruptionPolicy.missionControlActive },
         clock: @escaping () -> TimeInterval = { ProcessInfo.processInfo.systemUptime },
         workspaceNotificationCenter: NotificationCenter = NSWorkspace.shared.notificationCenter,
         quietPeriod: TimeInterval = 0.15) {
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
    }

    var canContinue: Bool { environmentIsSafe() }

    func begin(continuing operation: Operation? = nil) -> Operation? {
        guard canContinue else {
            Logger.log("Ignoring Space action while Mission Control is active")
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
        return operation
    }

    deinit {
        if let spaceObserver { workspaceNotificationCenter.removeObserver(spaceObserver) }
    }
}
