import Cocoa
import XCTest
@testable import Rectangle

class SpaceManagerTests: XCTestCase {

    private final class TestElement: AccessibilityElement {
        let testTitleBarFrame: CGRect?
        let testBundleIdentifier: String?
        var testFrame: CGRect
        var testSheet = false
        var testModal = false
        var testMinimized = false
        var testFullScreen = false
        var testPositionSettable = true

        init(titleBarFrame: CGRect?, bundleIdentifier: String? = nil, frame: CGRect? = nil) {
            testTitleBarFrame = titleBarFrame
            testBundleIdentifier = bundleIdentifier
            testFrame = frame ?? titleBarFrame.map {
                CGRect(x: $0.minX, y: $0.minY, width: $0.width, height: max(300, $0.height))
            } ?? .null
            super.init(AXUIElementCreateSystemWide())
        }

        override var titleBarFrame: CGRect? { testTitleBarFrame }
        override var bundleIdentifier: String? { testBundleIdentifier }
        override var frame: CGRect { testFrame }
        override var pid: pid_t? { 42 }
        override var isSheet: Bool? { testSheet }
        override var isModal: Bool? { testModal }
        override var isMinimized: Bool? { testMinimized }
        override var isFullScreen: Bool? { testFullScreen }
        override var isPositionSettable: Bool? { testPositionSettable }
    }

    private final class DragResolverSpy: SpaceDragTargetResolving {
        var targets: [SpaceDragTarget]
        var valid = true
        private(set) var recorded = [SpaceDragTarget]()
        private(set) var forgotten = 0

        init(points: [CGPoint]) {
            targets = points.enumerated().map {
                SpaceDragTarget(point: $0.element,
                                source: .titleBar,
                                hitRole: .window,
                                score: 100 - $0.offset)
            }
        }

        func candidates(for windowElement: AccessibilityElement) -> [SpaceDragTarget] { targets }
        func isValid(_ target: SpaceDragTarget, for windowElement: AccessibilityElement) -> Bool { valid }
        func recordSuccess(_ target: SpaceDragTarget, for windowElement: AccessibilityElement) {
            recorded.append(target)
        }
        func forgetSuccess(for windowElement: AccessibilityElement) {
            forgotten += 1
        }
    }

    private final class EventPosterSpy: SpaceMoveEventPosting {
        var mouseLocation: CGPoint?
        var accessibilityAuthorized = true
        var leftMouseButtonPressed = false
        var gesturePhaseDelay: TimeInterval = 0
        var prepareResult = true
        var warpResult = true
        var mouseDownResult = true
        var failedDragPhase: SpaceMouseDragPhase?
        var failedPhase: SpaceGesturePhase?
        var dragHandler: ((SpaceMouseDragPhase) -> Void)?

        private(set) var prepared = [(SpaceDirection, CGPoint, CGPoint)]()
        private(set) var warps = [CGPoint]()
        private(set) var mouseDownCount = 0
        private(set) var dragPhases = [SpaceMouseDragPhase]()
        private(set) var phases = [SpaceGesturePhase]()
        private(set) var mouseUpPoints = [CGPoint]()
        private(set) var discardCount = 0

        init(mouseLocation: CGPoint?) {
            self.mouseLocation = mouseLocation
        }

        func prepare(direction: SpaceDirection, at dragPoint: CGPoint, probePoint: CGPoint) -> Bool {
            prepared.append((direction, dragPoint, probePoint))
            return prepareResult
        }

        func warpMouse(to point: CGPoint) -> Bool {
            warps.append(point)
            if warpResult {
                mouseLocation = point
            }
            return warpResult
        }

        func postMouseDown() -> Bool {
            mouseDownCount += 1
            return mouseDownResult
        }

        func postMouseDragged(_ phase: SpaceMouseDragPhase) -> Bool {
            dragPhases.append(phase)
            guard phase != failedDragPhase else { return false }
            if let prepared = prepared.last {
                mouseLocation = phase == .outward ? prepared.2 : prepared.1
            }
            dragHandler?(phase)
            return true
        }

        func postGesturePhase(_ phase: SpaceGesturePhase) -> Bool {
            phases.append(phase)
            return phase != failedPhase
        }

        func postMouseUp(at point: CGPoint) -> Bool {
            mouseUpPoints.append(point)
            return true
        }

        func discardPreparedEvents() {
            discardCount += 1
        }
    }

    private final class PhysicalInputMonitorSpy: SpacePhysicalInputMonitoring {
        private var handler: (() -> Void)?
        private(set) var startCount = 0
        private(set) var stopCount = 0

        func start(_ handler: @escaping () -> Void) {
            startCount += 1
            self.handler = handler
        }

        func stop() {
            stopCount += 1
            handler = nil
        }

        func trigger() {
            handler?()
        }
    }

    private final class SchedulerSpy {
        private struct Scheduled {
            let deadline: TimeInterval
            let order: Int
            let action: () -> Void
        }

        private(set) var delays = [TimeInterval]()
        private var scheduled = [Scheduled]()
        private var now: TimeInterval = 0
        private var nextOrder = 0

        func schedule(delay: TimeInterval, action: @escaping () -> Void) {
            delays.append(delay)
            scheduled.append(Scheduled(deadline: now + delay, order: nextOrder, action: action))
            nextOrder += 1
        }

        func runNext(file: StaticString = #filePath, line: UInt = #line) {
            guard let nextIndex = scheduled.indices.min(by: {
                let lhs = scheduled[$0]
                let rhs = scheduled[$1]
                return lhs.deadline == rhs.deadline ? lhs.order < rhs.order : lhs.deadline < rhs.deadline
            }) else {
                XCTFail("Expected a scheduled Space move event", file: file, line: line)
                return
            }
            let next = scheduled.remove(at: nextIndex)
            now = next.deadline
            next.action()
        }

        func runUntil(
            _ condition: () -> Bool,
            limit: Int = 30,
            file: StaticString = #filePath,
            line: UInt = #line
        ) {
            for _ in 0..<limit {
                if condition() { return }
                runNext(file: file, line: line)
            }
            XCTFail("Scheduled Space move did not reach the expected state", file: file, line: line)
        }
    }

    private func manager(
        poster: EventPosterSpy,
        scheduler: SchedulerSpy,
        window: AccessibilityElement?,
        notificationCenter: NotificationCenter = NotificationCenter(),
        resolver: DragResolverSpy? = nil,
        physicalInputMonitor: PhysicalInputMonitorSpy = PhysicalInputMonitorSpy(),
        snapshotProvider: SpaceWindowSnapshotProvider? = nil,
        neighborAvailable: @escaping (SpaceDirection, CGPoint) -> Bool? = { _, _ in true },
        displayIdentifierAtPoint: @escaping (CGPoint) -> String? = { _ in "display" },
        windowDisplayIdentifier: @escaping (CGWindowID) -> String? = { _ in "display" }
    ) -> SpaceManager {
        let testWindow = window as? TestElement
        let originalFrame = testWindow?.testFrame
        poster.dragHandler = { phase in
            guard let testWindow, let originalFrame else { return }
            switch phase {
            case .outward:
                testWindow.testFrame.origin.x = originalFrame.origin.x + 8
            case .back, .hold:
                testWindow.testFrame = originalFrame
            }
        }
        let dragPoint = window?.titleBarFrame.map {
            CGPoint(x: $0.minX + min(100, $0.width / 2), y: $0.midY)
        } ?? .zero
        let resolver = resolver ?? DragResolverSpy(points: [dragPoint])
        return SpaceManager(
            eventPoster: poster,
            physicalInputMonitor: physicalInputMonitor,
            dragTargetResolver: resolver,
            scheduler: scheduler.schedule,
            frontWindowProvider: { window },
            windowSnapshotProvider: snapshotProvider ?? { element in
                SpaceWindowSnapshot(windowId: 42,
                                    pid: element.pid,
                                    frame: element.frame,
                                    level: 0,
                                    isOnScreen: !element.frame.isNull)
            },
            neighborAvailable: neighborAvailable,
            displayIdentifierAtPoint: displayIdentifierAtPoint,
            windowDisplayIdentifier: windowDisplayIdentifier,
            workspaceNotificationCenter: notificationCenter
        )
    }

    func testDragFallbackOnlyTriesTargetsOnTheWindowDisplay() {
        let poster = EventPosterSpy(mouseLocation: .zero)
        let scheduler = SchedulerSpy()
        let resolver = DragResolverSpy(points: [
            CGPoint(x: 600, y: 115),
            CGPoint(x: 200, y: 115)
        ])
        let manager = manager(
            poster: poster,
            scheduler: scheduler,
            window: TestElement(titleBarFrame: CGRect(x: 100, y: 100, width: 600, height: 30)),
            resolver: resolver,
            displayIdentifierAtPoint: { $0.x < 500 ? "left" : "right" },
            windowDisplayIdentifier: { _ in "left" }
        )

        XCTAssertTrue(manager.execute(parameters: ExecutionParameters(.nextSpace)))
        XCTAssertEqual(poster.prepared.map(\.1), [CGPoint(x: 200, y: 115)])
        XCTAssertEqual(poster.warps, [CGPoint(x: 200, y: 115)])
    }

    func testDragFallbackRejectsWindowAssignedToAnotherDisplay() {
        let poster = EventPosterSpy(mouseLocation: .zero)
        let scheduler = SchedulerSpy()
        let manager = manager(
            poster: poster,
            scheduler: scheduler,
            window: TestElement(titleBarFrame: CGRect(x: 100, y: 100, width: 500, height: 30)),
            displayIdentifierAtPoint: { _ in "left" },
            windowDisplayIdentifier: { _ in "right" }
        )

        XCTAssertTrue(manager.execute(parameters: ExecutionParameters(.nextSpace)))
        XCTAssertTrue(poster.prepared.isEmpty)
        XCTAssertTrue(poster.warps.isEmpty)
        XCTAssertTrue(scheduler.delays.isEmpty)
    }

    func testDragFallbackDoesNothingAtEitherSpaceBoundary() {
        let availabilities: [Bool?] = [false, nil]
        for hasNeighbor in availabilities {
            let poster = EventPosterSpy(mouseLocation: .zero)
            let scheduler = SchedulerSpy()
            let window = TestElement(titleBarFrame: CGRect(x: 20, y: 60, width: 600, height: 24))
            let manager = manager(
                poster: poster,
                scheduler: scheduler,
                window: window,
                neighborAvailable: { _, _ in hasNeighbor }
            )

            XCTAssertTrue(manager.execute(parameters: ExecutionParameters(.prevSpace)))
            XCTAssertTrue(manager.execute(parameters: ExecutionParameters(.nextSpace)))
            XCTAssertTrue(poster.prepared.isEmpty)
            XCTAssertTrue(poster.warps.isEmpty)
            XCTAssertEqual(poster.mouseDownCount, 0)
            XCTAssertTrue(scheduler.delays.isEmpty)
        }
    }

    func testMovePostsCompleteGestureAndReleasesAfterSpaceChange() {
        let window = TestElement(titleBarFrame: CGRect(x: 1_200, y: 40, width: 800, height: 28))
        let originalCursor = CGPoint(x: -400, y: 300)
        let poster = EventPosterSpy(mouseLocation: originalCursor)
        let scheduler = SchedulerSpy()
        let notifications = NotificationCenter()
        let manager = manager(
            poster: poster,
            scheduler: scheduler,
            window: window,
            notificationCenter: notifications
        )

        XCTAssertTrue(manager.execute(parameters: ExecutionParameters(.nextSpace)))

        let dragPoint = CGPoint(x: 1_300, y: 54)
        XCTAssertEqual(poster.prepared.first?.0, .next)
        XCTAssertEqual(poster.prepared.first?.1, dragPoint)
        XCTAssertEqual(poster.warps, [dragPoint])
        XCTAssertEqual(poster.mouseDownCount, 1)
        XCTAssertEqual(scheduler.delays, [1.5, 0.035])

        scheduler.runUntil { poster.phases == [.began, .changed, .ended] }

        XCTAssertEqual(poster.phases, [.began, .changed, .ended])
        XCTAssertEqual(poster.dragPhases, [.outward, .back])
        notifications.post(name: NSWorkspace.activeSpaceDidChangeNotification, object: nil)
        scheduler.runUntil { poster.mouseUpPoints.count == 1 }

        XCTAssertEqual(poster.mouseUpPoints, [dragPoint])
        XCTAssertEqual(poster.warps, [dragPoint, originalCursor])
        XCTAssertEqual(poster.discardCount, 1)

        // The timeout remains queued but is invalidated by the transaction ID.
        scheduler.runNext()
        XCTAssertEqual(poster.mouseUpPoints.count, 1)
    }

    func testMacOS27GesturePhasesArePaced() {
        let poster = EventPosterSpy(mouseLocation: .zero)
        poster.gesturePhaseDelay = 0.01
        let scheduler = SchedulerSpy()
        let manager = manager(
            poster: poster,
            scheduler: scheduler,
            window: TestElement(titleBarFrame: CGRect(x: 100, y: 100, width: 500, height: 30))
        )

        XCTAssertTrue(manager.execute(parameters: ExecutionParameters(.nextSpace)))
        scheduler.runUntil { poster.phases == [.began] }
        XCTAssertEqual(poster.phases, [.began])
        XCTAssertEqual(scheduler.delays.last, 0.01)

        scheduler.runNext()
        XCTAssertEqual(poster.phases, [.began, .changed])

        scheduler.runNext()
        XCTAssertEqual(poster.phases, [.began, .changed, .ended])
    }

    func testTimeoutAlwaysReleasesDragAndAllowsAnotherMove() {
        let poster = EventPosterSpy(mouseLocation: CGPoint(x: 300, y: 300))
        let scheduler = SchedulerSpy()
        let window = TestElement(titleBarFrame: CGRect(x: 100, y: 100, width: 500, height: 30))
        let manager = manager(poster: poster, scheduler: scheduler, window: window)

        XCTAssertTrue(manager.execute(parameters: ExecutionParameters(.nextSpace)))
        XCTAssertTrue(manager.execute(parameters: ExecutionParameters(.nextSpace)))
        XCTAssertEqual(poster.mouseDownCount, 1)

        scheduler.runUntil { poster.mouseUpPoints.count == 1 }

        XCTAssertEqual(poster.mouseUpPoints.count, 1)
        XCTAssertTrue(manager.execute(parameters: ExecutionParameters(.nextSpace)))
        XCTAssertEqual(poster.mouseDownCount, 2)
    }

    func testDeinitReleasesDragAndRestoresUntouchedCursor() {
        let originalCursor = CGPoint(x: 300, y: 300)
        let poster = EventPosterSpy(mouseLocation: originalCursor)
        let scheduler = SchedulerSpy()
        var subject: SpaceManager? = manager(
            poster: poster,
            scheduler: scheduler,
            window: TestElement(titleBarFrame: CGRect(x: 100, y: 100, width: 500, height: 30))
        )

        XCTAssertTrue(subject?.execute(parameters: ExecutionParameters(.nextSpace)) == true)
        subject = nil

        XCTAssertEqual(poster.mouseUpPoints, [CGPoint(x: 200, y: 115)])
        XCTAssertEqual(poster.warps, [CGPoint(x: 200, y: 115), originalCursor])
    }

    func testCursorIsNotRestoredAfterUserMovesIt() {
        let poster = EventPosterSpy(mouseLocation: CGPoint(x: 300, y: 300))
        let scheduler = SchedulerSpy()
        let notifications = NotificationCenter()
        let manager = manager(
            poster: poster,
            scheduler: scheduler,
            window: TestElement(titleBarFrame: CGRect(x: 100, y: 100, width: 500, height: 30)),
            notificationCenter: notifications
        )

        XCTAssertTrue(manager.execute(parameters: ExecutionParameters(.nextSpace)))
        scheduler.runUntil { poster.phases == [.began, .changed, .ended] }
        let userLocation = CGPoint(x: 900, y: 700)
        poster.mouseLocation = userLocation
        notifications.post(name: NSWorkspace.activeSpaceDidChangeNotification, object: nil)
        scheduler.runNext()

        XCTAssertEqual(poster.mouseUpPoints, [userLocation])
        XCTAssertEqual(poster.warps.count, 1)
    }

    func testGestureFailureImmediatelyReleasesDrag() {
        let poster = EventPosterSpy(mouseLocation: .zero)
        poster.failedPhase = .changed
        let scheduler = SchedulerSpy()
        let manager = manager(
            poster: poster,
            scheduler: scheduler,
            window: TestElement(titleBarFrame: CGRect(x: 100, y: 100, width: 500, height: 30))
        )

        XCTAssertTrue(manager.execute(parameters: ExecutionParameters(.prevSpace)))
        scheduler.runUntil { poster.mouseUpPoints.count == 1 }

        XCTAssertEqual(poster.phases, [.began, .changed])
        XCTAssertEqual(poster.mouseUpPoints.count, 1)
        XCTAssertEqual(poster.discardCount, 1)
    }

    func testPreparationFailureDoesNotMoveCursorOrPressMouse() {
        let poster = EventPosterSpy(mouseLocation: CGPoint(x: 40, y: 50))
        poster.prepareResult = false
        let scheduler = SchedulerSpy()
        let manager = manager(
            poster: poster,
            scheduler: scheduler,
            window: TestElement(titleBarFrame: CGRect(x: 20, y: 60, width: 600, height: 24))
        )

        XCTAssertTrue(manager.execute(parameters: ExecutionParameters(.nextSpace)))
        XCTAssertTrue(poster.warps.isEmpty)
        XCTAssertEqual(poster.mouseDownCount, 0)
        XCTAssertEqual(scheduler.delays, [1.5])
    }

    func testRejectsMoveWhilePhysicalLeftButtonIsPressed() {
        let poster = EventPosterSpy(mouseLocation: .zero)
        poster.leftMouseButtonPressed = true
        let scheduler = SchedulerSpy()
        let manager = manager(
            poster: poster,
            scheduler: scheduler,
            window: TestElement(titleBarFrame: CGRect(x: 20, y: 60, width: 600, height: 24))
        )

        XCTAssertTrue(manager.execute(parameters: ExecutionParameters(.nextSpace)))
        XCTAssertTrue(poster.prepared.isEmpty)
    }

    func testRejectsMoveWithoutAccessibilityPermission() {
        let poster = EventPosterSpy(mouseLocation: .zero)
        poster.accessibilityAuthorized = false
        let scheduler = SchedulerSpy()
        let manager = manager(
            poster: poster,
            scheduler: scheduler,
            window: TestElement(titleBarFrame: CGRect(x: 20, y: 60, width: 600, height: 24))
        )

        XCTAssertTrue(manager.execute(parameters: ExecutionParameters(.nextSpace)))
        XCTAssertTrue(poster.prepared.isEmpty)
    }

    func testIgnoresOtherActions() {
        let poster = EventPosterSpy(mouseLocation: .zero)
        let scheduler = SchedulerSpy()
        let manager = manager(poster: poster, scheduler: scheduler, window: nil)

        XCTAssertFalse(manager.execute(parameters: ExecutionParameters(.leftHalf)))
        XCTAssertTrue(poster.prepared.isEmpty)
        XCTAssertTrue(scheduler.delays.isEmpty)
    }

    func testProvidedWindowTakesPrecedenceAndMapsPreviousDirection() {
        let poster = EventPosterSpy(mouseLocation: .zero)
        let scheduler = SchedulerSpy()
        let provided = TestElement(titleBarFrame: CGRect(x: 20, y: 60, width: 600, height: 24))
        let manager = manager(poster: poster, scheduler: scheduler, window: nil)

        XCTAssertTrue(manager.execute(parameters: ExecutionParameters(.prevSpace, windowElement: provided)))
        XCTAssertEqual(poster.prepared.first?.0, .previous)
    }

    func testRejectsUnsupportedWindowStatesBeforeResolvingTargets() {
        let poster = EventPosterSpy(mouseLocation: .zero)
        let scheduler = SchedulerSpy()
        let resolver = DragResolverSpy(points: [CGPoint(x: 100, y: 100)])
        let window = TestElement(titleBarFrame: CGRect(x: 10, y: 20, width: 500, height: 30))

        window.testSheet = true
        XCTAssertTrue(manager(poster: poster, scheduler: scheduler, window: window, resolver: resolver)
            .execute(parameters: ExecutionParameters(.nextSpace)))
        XCTAssertTrue(poster.prepared.isEmpty)

        window.testSheet = false
        window.testFullScreen = true
        XCTAssertTrue(manager(poster: poster, scheduler: scheduler, window: window, resolver: resolver)
            .execute(parameters: ExecutionParameters(.nextSpace)))
        XCTAssertTrue(poster.prepared.isEmpty)
    }

    func testRetriesAnotherCandidateWhenTheFirstPointDoesNotAcquireADrag() {
        let window = TestElement(titleBarFrame: CGRect(x: 100, y: 100, width: 500, height: 30))
        let originalFrame = window.testFrame
        let poster = EventPosterSpy(mouseLocation: CGPoint(x: 40, y: 50))
        let scheduler = SchedulerSpy()
        let notifications = NotificationCenter()
        let resolver = DragResolverSpy(points: [
            CGPoint(x: 200, y: 115),
            CGPoint(x: 350, y: 115)
        ])
        let manager = manager(
            poster: poster,
            scheduler: scheduler,
            window: window,
            notificationCenter: notifications,
            resolver: resolver
        )
        poster.dragHandler = { phase in
            guard poster.prepared.count == 2 else { return }
            window.testFrame = phase == .outward
                ? originalFrame.offsetBy(dx: 8, dy: 0)
                : originalFrame
        }

        XCTAssertTrue(manager.execute(parameters: ExecutionParameters(.nextSpace)))
        scheduler.runUntil { poster.phases == [.began, .changed, .ended] }

        XCTAssertEqual(poster.prepared.map(\.1), [
            CGPoint(x: 200, y: 115),
            CGPoint(x: 350, y: 115)
        ])
        XCTAssertEqual(poster.mouseDownCount, 2)
        XCTAssertEqual(poster.mouseUpPoints.count, 1)

        notifications.post(name: NSWorkspace.activeSpaceDidChangeNotification, object: nil)
        scheduler.runUntil { poster.mouseUpPoints.count == 2 }

        XCTAssertEqual(resolver.recorded, [resolver.targets[1]])
    }

    func testDoesNotSwitchSpacesWhenNoCandidateAcquiresADrag() {
        let poster = EventPosterSpy(mouseLocation: CGPoint(x: 40, y: 50))
        let scheduler = SchedulerSpy()
        let resolver = DragResolverSpy(points: [
            CGPoint(x: 200, y: 115),
            CGPoint(x: 350, y: 115)
        ])
        let manager = manager(
            poster: poster,
            scheduler: scheduler,
            window: TestElement(titleBarFrame: CGRect(x: 100, y: 100, width: 500, height: 30)),
            resolver: resolver
        )
        poster.dragHandler = { _ in }

        XCTAssertTrue(manager.execute(parameters: ExecutionParameters(.nextSpace)))
        scheduler.runUntil { poster.mouseUpPoints.count == 2 }

        XCTAssertTrue(poster.phases.isEmpty)
        XCTAssertTrue(resolver.recorded.isEmpty)
    }

    func testEarlySpaceChangeWaitsForGestureEndAndStableDestinationWindow() {
        let window = TestElement(titleBarFrame: CGRect(x: 100, y: 100, width: 500, height: 30))
        let poster = EventPosterSpy(mouseLocation: .zero)
        poster.gesturePhaseDelay = 0.01
        let scheduler = SchedulerSpy()
        let notifications = NotificationCenter()
        var spaceChanged = false
        var confirmationPoll = 0
        let manager = manager(
            poster: poster,
            scheduler: scheduler,
            window: window,
            notificationCenter: notifications,
            snapshotProvider: { element in
                guard spaceChanged else {
                    return SpaceWindowSnapshot(windowId: 12, pid: element.pid,
                                               frame: element.frame, level: 0, isOnScreen: true)
                }
                confirmationPoll += 1
                switch confirmationPoll {
                case 1:
                    return nil
                case 2:
                    return SpaceWindowSnapshot(windowId: 12, pid: element.pid,
                                               frame: element.frame, level: 0, isOnScreen: false)
                case 3:
                    return SpaceWindowSnapshot(windowId: 12, pid: element.pid,
                                               frame: element.frame.offsetBy(dx: 12, dy: 0),
                                               level: 0, isOnScreen: true)
                default:
                    return SpaceWindowSnapshot(windowId: 12, pid: element.pid,
                                               frame: element.frame.offsetBy(dx: 20, dy: 0),
                                               level: 0, isOnScreen: true)
                }
            }
        )

        XCTAssertTrue(manager.execute(parameters: ExecutionParameters(.nextSpace)))
        scheduler.runUntil { poster.phases == [.began] }
        spaceChanged = true
        notifications.post(name: NSWorkspace.activeSpaceDidChangeNotification, object: nil)
        XCTAssertTrue(poster.mouseUpPoints.isEmpty)

        scheduler.runUntil { poster.phases == [.began, .changed, .ended] }
        XCTAssertTrue(poster.mouseUpPoints.isEmpty)
        scheduler.runUntil { poster.mouseUpPoints.count == 1 }

        XCTAssertGreaterThanOrEqual(confirmationPoll, 5)
    }

    func testPhysicalMouseInputCancelsHeldDragWithoutRestoringCursor() {
        let poster = EventPosterSpy(mouseLocation: CGPoint(x: 40, y: 50))
        let scheduler = SchedulerSpy()
        let monitor = PhysicalInputMonitorSpy()
        let manager = manager(
            poster: poster,
            scheduler: scheduler,
            window: TestElement(titleBarFrame: CGRect(x: 100, y: 100, width: 500, height: 30)),
            physicalInputMonitor: monitor
        )

        XCTAssertTrue(manager.execute(parameters: ExecutionParameters(.nextSpace)))
        XCTAssertEqual(monitor.startCount, 1)
        monitor.trigger()

        XCTAssertEqual(poster.mouseUpPoints.count, 1)
        XCTAssertEqual(poster.warps.count, 1)
        XCTAssertGreaterThanOrEqual(monitor.stopCount, 1)
    }

    func testMaximizedWindowUsesStationaryHoldWithoutChangingGeometry() throws {
        let screen = try XCTUnwrap(NSScreen.screens.first)
        let frame = screen.visibleFrame.screenFlipped
        let titleBar = CGRect(x: frame.minX, y: frame.minY, width: frame.width, height: 30)
        let window = TestElement(titleBarFrame: titleBar, frame: frame)
        let poster = EventPosterSpy(mouseLocation: CGPoint(x: 40, y: 50))
        let scheduler = SchedulerSpy()
        let manager = manager(poster: poster, scheduler: scheduler, window: window)

        XCTAssertTrue(manager.execute(parameters: ExecutionParameters(.nextSpace)))
        scheduler.runUntil { poster.phases == [.began, .changed, .ended] }

        XCTAssertEqual(poster.dragPhases, [.hold])
        XCTAssertEqual(window.testFrame, frame)
    }

    func testMissingStableWindowIdentityDoesNotStartADrag() {
        let poster = EventPosterSpy(mouseLocation: CGPoint(x: 40, y: 50))
        let scheduler = SchedulerSpy()
        let notifications = NotificationCenter()
        let resolver = DragResolverSpy(points: [CGPoint(x: 200, y: 115)])
        let manager = manager(
            poster: poster,
            scheduler: scheduler,
            window: TestElement(titleBarFrame: CGRect(x: 100, y: 100, width: 500, height: 30)),
            notificationCenter: notifications,
            resolver: resolver,
            snapshotProvider: { element in
                SpaceWindowSnapshot(windowId: nil, pid: element.pid,
                                    frame: element.frame, level: 0, isOnScreen: true)
            }
        )

        XCTAssertTrue(manager.execute(parameters: ExecutionParameters(.nextSpace)))
        XCTAssertTrue(poster.prepared.isEmpty)
        XCTAssertTrue(poster.phases.isEmpty)
        XCTAssertTrue(scheduler.delays.isEmpty)
        XCTAssertTrue(resolver.recorded.isEmpty)
    }

    func testWindowActionsHaveStableSpaceMetadata() {
        XCTAssertEqual(WindowAction.nextSpace.rawValue, 131)
        XCTAssertEqual(WindowAction.prevSpace.rawValue, 132)
        XCTAssertEqual(WindowAction.switchNextSpace.rawValue, 133)
        XCTAssertEqual(WindowAction.switchPrevSpace.rawValue, 134)
        XCTAssertEqual(WindowAction.nextSpace.name, "nextSpace")
        XCTAssertEqual(WindowAction.prevSpace.name, "prevSpace")
        XCTAssertEqual(WindowAction.switchNextSpace.name, "switchNextSpace")
        XCTAssertEqual(WindowAction.switchPrevSpace.name, "switchPrevSpace")
        XCTAssertTrue(WindowAction.active.contains(.nextSpace))
        XCTAssertTrue(WindowAction.active.contains(.prevSpace))
        XCTAssertTrue(WindowAction.active.contains(.switchNextSpace))
        XCTAssertTrue(WindowAction.active.contains(.switchPrevSpace))

        for action in [WindowAction.nextSpace, .prevSpace, .switchNextSpace, .switchPrevSpace] {
            XCTAssertFalse(action.resizes)
            XCTAssertFalse(action.isDragSnappable)
            XCTAssertFalse(action.positionCycles)
            XCTAssertEqual(action.classification, .display)
            XCTAssertEqual(action.gapsApplicable, .none)
        }
    }
}

class BridgedSpaceManagerTests: XCTestCase {
    private final class TestWindow: AccessibilityElement {
        override var windowId: CGWindowID? { 101 }
        override var frame: CGRect { CGRect(x: 100, y: 100, width: 500, height: 300) }
        override var isSheet: Bool? { false }
        override var isModal: Bool? { false }
        override var isMinimized: Bool? { false }
        override var isFullScreen: Bool? { false }

        init() { super.init(AXUIElementCreateSystemWide()) }
    }

    private final class TransferSpy: WindowSpaceTransferring {
        var isAvailable = true
        var memberships: [UInt64]? = [57]
        var displayedSpace: UInt64? = 57
        var adjacent: AdjacentManagedSpace? = AdjacentManagedSpace(
            sourceID: 57, destinationID: 10, displayIdentifier: "secondary"
        )
        var events = [String]()

        func spaces(for windowID: CGWindowID) -> [UInt64]? { memberships }
        func adjacentSpace(for windowID: CGWindowID,
                           direction: SpaceDirection) -> AdjacentManagedSpace? {
            adjacent
        }
        func currentSpace(for displayIdentifier: String) -> UInt64? { displayedSpace }
        func move(windowID: CGWindowID, to spaceID: UInt64) -> Bool {
            events.append("move:\(windowID):\(spaceID)")
            return true
        }
    }

    private final class SwitchSpy: SpaceActionExecuting {
        let transfer: TransferSpy
        init(transfer: TransferSpy) { self.transfer = transfer }
        func execute(parameters: ExecutionParameters) -> Bool {
            transfer.events.append("switch:\(parameters.action.name)")
            return true
        }
    }

    private func display(_ identifier: String, current: UInt64,
                         spaces: [(UInt64, Int)]) -> [String: Any] {
        ["Display Identifier": identifier,
         "Current Space": ["id64": NSNumber(value: current)],
         "Spaces": spaces.map { ["id64": NSNumber(value: $0.0),
                                  "type": NSNumber(value: $0.1)] }]
    }

    func testAdjacentSpaceUsesWindowDisplayAndSkipsFullScreenSpaces() {
        let displays = [
            display("main", current: 9, spaces: [(4, 0), (9, 0)]),
            display("secondary", current: 57, spaces: [(57, 0), (81, 4), (10, 0)])
        ]

        XCTAssertEqual(ManagedSpaceTopology.adjacent(to: [57], direction: .next,
                                                     on: "secondary", in: displays),
                       AdjacentManagedSpace(sourceID: 57, destinationID: 10,
                                            displayIdentifier: "secondary"))
        XCTAssertNil(ManagedSpaceTopology.adjacent(to: [57], direction: .previous,
                                                   on: "secondary", in: displays))
        XCTAssertNil(ManagedSpaceTopology.adjacent(to: [57, 9], direction: .next,
                                                   on: "secondary", in: displays))
        XCTAssertNil(ManagedSpaceTopology.adjacent(to: [57], direction: .next,
                                                   on: "main", in: displays))
        XCTAssertNil(ManagedSpaceTopology.adjacent(to: [9], direction: .next,
                                                   on: "main", in: displays))
        XCTAssertEqual(ManagedSpaceTopology.currentSpace(for: "main", in: displays), 9)
    }

    func testPreviousSpaceUsesTheEarlierDesktopOnTheSameDisplay() {
        let displays = [
            display("main", current: 9, spaces: [(4, 0), (9, 0)]),
            display("secondary", current: 10, spaces: [(57, 0), (81, 4), (10, 0)])
        ]

        XCTAssertEqual(ManagedSpaceTopology.adjacent(to: [10], direction: .previous,
                                                     on: "secondary", in: displays),
                       AdjacentManagedSpace(sourceID: 10, destinationID: 57,
                                            displayIdentifier: "secondary"))
    }

    func testDisplayedSpaceBoundaryUsesTheSelectedDisplayAndIncludesFullScreenSpaces() {
        let displays = [
            display("main", current: 9, spaces: [(4, 0), (9, 0)]),
            display("secondary", current: 57, spaces: [(57, 0), (81, 4), (10, 0)])
        ]

        XCTAssertEqual(ManagedSpaceTopology.hasAdjacentDisplayedSpace(
            on: "main", direction: .next, scope: .all, in: displays
        ), false)
        XCTAssertEqual(ManagedSpaceTopology.hasAdjacentDisplayedSpace(
            on: "secondary", direction: .previous, scope: .all, in: displays
        ), false)
        XCTAssertEqual(ManagedSpaceTopology.hasAdjacentDisplayedSpace(
            on: "secondary", direction: .next, scope: .all, in: displays
        ), true)
        XCTAssertEqual(ManagedSpaceTopology.hasAdjacentDisplayedSpace(
            on: "secondary", direction: .next, scope: .normal, in: displays
        ), true)
        XCTAssertNil(ManagedSpaceTopology.hasAdjacentDisplayedSpace(
            on: "missing", direction: .next, scope: .all, in: displays
        ))
    }

    func testBridgedMoveDoesNothingWhenThereIsNoAdjacentSpace() {
        let transfer = TransferSpy()
        transfer.adjacent = nil
        let window = TestWindow()
        var scheduled = [() -> Void]()
        let manager = BridgedSpaceManager(
            transfer: transfer,
            scheduler: { _, action in scheduled.append(action) },
            frontWindowProvider: { window },
            windowSnapshotProvider: { _ in
                SpaceWindowSnapshot(windowId: 101, pid: 42,
                                    frame: window.frame, level: 0, isOnScreen: true)
            },
            accessibilityAuthorized: { true }
        )

        XCTAssertTrue(manager.execute(parameters: ExecutionParameters(.prevSpace)))
        XCTAssertTrue(manager.execute(parameters: ExecutionParameters(.nextSpace)))
        XCTAssertTrue(transfer.events.isEmpty)
        XCTAssertTrue(scheduled.isEmpty)
    }

    func testMoveIsVerifiedBeforeSwitchingDisplayedSpace() {
        let transfer = TransferSpy()
        let window = TestWindow()
        let screen = NSScreen.screens.first
        var scheduled = [() -> Void]()
        let manager = BridgedSpaceManager(
            transfer: transfer,
            switcher: SwitchSpy(transfer: transfer),
            scheduler: { _, action in scheduled.append(action) },
            frontWindowProvider: { window },
            windowSnapshotProvider: { _ in
                SpaceWindowSnapshot(windowId: 101, pid: 42,
                                    frame: window.frame, level: 0, isOnScreen: true)
            },
            accessibilityAuthorized: { true },
            screenProvider: { _ in screen },
            displayIdentifierAtPoint: { _ in "secondary" },
            raiseWindow: { _ in transfer.events.append("raise") },
            followMovedWindowProvider: { true }
        )

        XCTAssertTrue(manager.execute(parameters: ExecutionParameters(.nextSpace)))
        XCTAssertEqual(transfer.events, ["move:101:10"])
        XCTAssertEqual(scheduled.count, 1)

        transfer.memberships = [10]
        scheduled.removeFirst()()
        XCTAssertEqual(transfer.events, ["move:101:10", "switch:switchNextSpace"])
        XCTAssertEqual(scheduled.count, 1)

        transfer.displayedSpace = 10
        scheduled.removeFirst()()
        XCTAssertEqual(transfer.events, ["move:101:10", "switch:switchNextSpace", "raise"])
        XCTAssertTrue(scheduled.isEmpty)
    }

    func testMoveWithoutFollowingLeavesDisplayedSpaceAlone() {
        let transfer = TransferSpy()
        let window = TestWindow()
        let screen = NSScreen.screens.first
        var scheduled = [() -> Void]()
        var followMovedWindow = false
        let manager = BridgedSpaceManager(
            transfer: transfer,
            switcher: SwitchSpy(transfer: transfer),
            scheduler: { _, action in scheduled.append(action) },
            frontWindowProvider: { window },
            windowSnapshotProvider: { _ in
                SpaceWindowSnapshot(windowId: 101, pid: 42,
                                    frame: window.frame, level: 0, isOnScreen: true)
            },
            accessibilityAuthorized: { true },
            screenProvider: { _ in screen },
            displayIdentifierAtPoint: { _ in "secondary" },
            raiseWindow: { _ in transfer.events.append("raise") },
            followMovedWindowProvider: { followMovedWindow }
        )

        XCTAssertTrue(manager.execute(parameters: ExecutionParameters(.nextSpace)))
        XCTAssertEqual(transfer.events, ["move:101:10"])
        XCTAssertEqual(scheduled.count, 1)

        // Changing the preference during an in-flight move does not change that move's behavior.
        followMovedWindow = true
        transfer.memberships = [10]
        scheduled.removeFirst()()
        XCTAssertEqual(transfer.events, ["move:101:10"])
        XCTAssertEqual(transfer.displayedSpace, 57)
        XCTAssertTrue(scheduled.isEmpty)
    }

    func testBridgedMoveRejectsWindowSpaceOnAnotherDisplay() {
        let transfer = TransferSpy()
        let window = TestWindow()
        let screen = NSScreen.screens.first
        var scheduled = [() -> Void]()
        let manager = BridgedSpaceManager(
            transfer: transfer,
            scheduler: { _, action in scheduled.append(action) },
            frontWindowProvider: { window },
            windowSnapshotProvider: { _ in
                SpaceWindowSnapshot(windowId: 101, pid: 42,
                                    frame: window.frame, level: 0, isOnScreen: true)
            },
            accessibilityAuthorized: { true },
            screenProvider: { _ in screen },
            displayIdentifierAtPoint: { _ in "main" }
        )

        XCTAssertTrue(manager.execute(parameters: ExecutionParameters(.nextSpace)))
        XCTAssertTrue(transfer.events.isEmpty)
        XCTAssertTrue(scheduled.isEmpty)
    }
}

class SpaceDragTargetResolverTests: XCTestCase {

    private final class TestElement: AccessibilityElement {
        let testPid: pid_t
        let testRole: NSAccessibility.Role
        let testFrame: CGRect
        let testTitleBarFrame: CGRect?
        let testWindowId: CGWindowID?
        let testActions: [String]
        var testTopLevel: AccessibilityElement?
        var testTitleElement: AccessibilityElement?
        var testToolbar: AccessibilityElement?
        var testChildren = [AccessibilityElement]()

        init(pid: pid_t = 123,
             role: NSAccessibility.Role,
             frame: CGRect,
             titleBarFrame: CGRect? = nil,
             windowId: CGWindowID? = 77,
             actions: [String] = []) {
            testPid = pid
            testRole = role
            testFrame = frame
            testTitleBarFrame = titleBarFrame
            testWindowId = windowId
            testActions = actions
            super.init(AXUIElementCreateApplication(pid))
        }

        override var pid: pid_t? { testPid }
        override var role: NSAccessibility.Role? { testRole }
        override var frame: CGRect { testFrame }
        override var titleBarFrame: CGRect? { testTitleBarFrame }
        override var windowId: CGWindowID? { testWindowId }
        override var bundleIdentifier: String? { "test.drag-target" }
        override var actionNames: [String] { testActions }
        override var childElements: [AccessibilityElement]? { testChildren }
        override var titleElement: AccessibilityElement? { testTitleElement }
        override func getChildElement(_ role: NSAccessibility.Role) -> AccessibilityElement? {
            role == .toolbar ? testToolbar : nil
        }
        override var topLevelElement: AccessibilityElement? {
            testRole == .window ? self : testTopLevel
        }
        override var windowElement: AccessibilityElement? {
            testRole == .window ? self : testTopLevel
        }
    }

    func testUsesDisplayContainingMostOfTitleBarAndRemembersSuccessfulPoint() throws {
        let frame = CGRect(x: 900, y: 100, width: 400, height: 400)
        let window = TestElement(role: .window,
                                 frame: frame,
                                 titleBarFrame: CGRect(x: 900, y: 100, width: 400, height: 40))
        let hit = TestElement(role: .staticText, frame: frame)
        hit.testTopLevel = window
        let resolver = SpaceDragTargetResolver(
            displayFramesProvider: {
                [CGRect(x: 0, y: 0, width: 1_000, height: 800),
                 CGRect(x: 1_000, y: 0, width: 1_000, height: 800)]
            },
            systemHitTest: { _ in hit },
            applicationHitTest: { _, _ in hit }
        )

        let candidates = resolver.candidates(for: window)
        XCTAssertFalse(candidates.isEmpty)
        XCTAssertTrue(candidates.allSatisfy { $0.point.x >= 1_002 && $0.point.x <= 1_298 })

        let successful = try XCTUnwrap(candidates.first)
        resolver.recordSuccess(successful, for: window)
        let remembered = try XCTUnwrap(resolver.candidates(for: window).first)

        XCTAssertEqual(remembered.source, .remembered)
        XCTAssertEqual(remembered.point, successful.point)
    }

    func testRejectsHitTargetsThatExposeAnAction() {
        let frame = CGRect(x: 100, y: 100, width: 600, height: 400)
        let window = TestElement(role: .window,
                                 frame: frame,
                                 titleBarFrame: CGRect(x: 100, y: 100, width: 600, height: 40))
        let button = TestElement(role: .button, frame: frame, actions: ["AXPress"])
        button.testTopLevel = window
        let resolver = SpaceDragTargetResolver(
            displayFramesProvider: { [CGRect(x: 0, y: 0, width: 1_000, height: 800)] },
            systemHitTest: { _ in button },
            applicationHitTest: { _, _ in button }
        )

        XCTAssertTrue(resolver.candidates(for: window).isEmpty)
    }

    func testRejectsUnknownContentRoleEvenWithoutAdvertisedActions() {
        let frame = CGRect(x: 100, y: 100, width: 600, height: 400)
        let window = TestElement(role: .window,
                                 frame: frame,
                                 titleBarFrame: CGRect(x: 100, y: 100, width: 600, height: 40))
        let webArea = TestElement(role: NSAccessibility.Role(rawValue: "AXWebArea"), frame: frame)
        webArea.testTopLevel = window
        let resolver = SpaceDragTargetResolver(
            displayFramesProvider: { [CGRect(x: 0, y: 0, width: 1_000, height: 800)] },
            systemHitTest: { _ in webArea },
            applicationHitTest: { _, _ in webArea }
        )

        XCTAssertTrue(resolver.candidates(for: window).isEmpty)
    }

    func testFindsClearBrowserTabStripBelowTabs() {
        let frame = CGRect(x: 100, y: 100, width: 1_000, height: 650)
        let window = TestElement(role: .window,
                                 frame: frame,
                                 titleBarFrame: CGRect(x: 100, y: 100, width: 1_000, height: 40))
        let tab = TestElement(role: NSAccessibility.Role(rawValue: "AXTab"),
                              frame: CGRect(x: 100, y: 100, width: 1_000, height: 43),
                              actions: ["AXPress"])
        let clearTabGroup = TestElement(role: .tabGroup,
                                        frame: CGRect(x: 100, y: 143, width: 1_000, height: 20))
        tab.testTopLevel = window
        clearTabGroup.testTopLevel = window
        window.testChildren = [tab]
        window.testTitleElement = tab
        window.testToolbar = TestElement(role: .toolbar,
                                         frame: CGRect(x: 100, y: 140, width: 1_000, height: 24))
        let hitTest: (CGPoint) -> AccessibilityElement? = { point in
            point.y < 143 ? tab : clearTabGroup
        }
        let resolver = SpaceDragTargetResolver(
            displayFramesProvider: { [CGRect(x: 0, y: 0, width: 1_200, height: 900)] },
            systemHitTest: hitTest,
            applicationHitTest: { _, point in hitTest(point) }
        )

        let candidates = resolver.candidates(for: window)
        XCTAssertTrue(candidates.contains { $0.point.y >= 143 && $0.hitRole == .tabGroup })
        XCTAssertTrue(candidates.allSatisfy { $0.point.y >= 143 })
    }

    func testSearchesBeyondCenterWhenSafariToolbarCoversIt() {
        let frame = CGRect(x: 100, y: 100, width: 1_000, height: 650)
        let window = TestElement(role: .window,
                                 frame: frame,
                                 titleBarFrame: CGRect(x: 100, y: 100, width: 1_000, height: 40))
        let blocked = TestElement(role: .button, frame: frame, actions: ["AXPress"])
        let clear = TestElement(role: .group, frame: frame)
        blocked.testTopLevel = window
        clear.testTopLevel = window
        window.testTitleElement = blocked
        window.testToolbar = TestElement(role: .toolbar,
                                         frame: CGRect(x: 100, y: 140, width: 1_000, height: 24))
        let hitTest: (CGPoint) -> AccessibilityElement? = { point in
            abs(point.x - 300) < 10 && point.y >= 140 ? clear : blocked
        }
        let resolver = SpaceDragTargetResolver(
            displayFramesProvider: { [CGRect(x: 0, y: 0, width: 1_200, height: 900)] },
            systemHitTest: hitTest,
            applicationHitTest: { _, point in hitTest(point) }
        )

        let candidates = resolver.candidates(for: window)
        XCTAssertTrue(candidates.contains { abs($0.point.x - 300) < 10 && $0.point.y >= 140 })
    }

    func testSafariStructuralContainerDoesNotCoverClearDragArea() {
        let frame = CGRect(x: 100, y: 100, width: 1_000, height: 650)
        let window = TestElement(role: .window,
                                 frame: frame,
                                 titleBarFrame: CGRect(x: 100, y: 100, width: 1_000, height: 60))
        let container = TestElement(role: NSAccessibility.Role(rawValue: "AXSplitGroup"),
                                    frame: frame,
                                    actions: ["AXPress"])
        let button = TestElement(role: .button,
                                 frame: CGRect(x: 100, y: 100, width: 150, height: 60),
                                 actions: ["AXPress"])
        container.testTopLevel = window
        button.testTopLevel = window
        container.testChildren = [button]
        window.testChildren = [container]
        let hitTest: (CGPoint) -> AccessibilityElement? = { point in
            point.x < 250 ? button : container
        }
        let resolver = SpaceDragTargetResolver(
            displayFramesProvider: { [CGRect(x: 0, y: 0, width: 1_200, height: 900)] },
            systemHitTest: hitTest,
            applicationHitTest: { _, point in hitTest(point) }
        )

        let candidates = resolver.candidates(for: window)
        XCTAssertFalse(candidates.isEmpty)
        XCTAssertTrue(candidates.allSatisfy { $0.point.x >= 250 })
    }

    func testSafariActionableGroupUsesChildControlFrames() {
        let frame = CGRect(x: 100, y: 100, width: 1_000, height: 650)
        let window = TestElement(role: .window,
                                 frame: frame,
                                 titleBarFrame: CGRect(x: 100, y: 100, width: 1_000, height: 60))
        let group = TestElement(role: .group,
                                frame: CGRect(x: 100, y: 100, width: 1_000, height: 64),
                                actions: ["AXPress"])
        let button = TestElement(role: .button,
                                 frame: CGRect(x: 100, y: 100, width: 150, height: 60),
                                 actions: ["AXPress"])
        let clear = TestElement(role: .group, frame: frame)
        group.testTopLevel = window
        button.testTopLevel = window
        clear.testTopLevel = window
        group.testChildren = [button]
        window.testChildren = [group]
        let hitTest: (CGPoint) -> AccessibilityElement? = { point in
            point.x < 250 ? button : clear
        }
        let resolver = SpaceDragTargetResolver(
            displayFramesProvider: { [CGRect(x: 0, y: 0, width: 1_200, height: 900)] },
            systemHitTest: hitTest,
            applicationHitTest: { _, point in hitTest(point) }
        )

        let candidates = resolver.candidates(for: window)
        XCTAssertFalse(candidates.isEmpty)
        XCTAssertTrue(candidates.allSatisfy { $0.point.x >= 250 })
    }
}

class SpaceGestureTests: XCTestCase {

    func testLegacyFieldsCarryStableProgressAndVelocityOnEveryPhase() {
        for phase in SpaceGesturePhase.allCases {
            let fields = SpaceGesture.fields(
                for: phase,
                direction: .previous,
                augmented: false,
                timestamp: 123
            )

            XCTAssertEqual(integer(in: fields, raw: 55), 30)
            XCTAssertEqual(integer(in: fields, raw: 110), 23)
            XCTAssertEqual(integer(in: fields, raw: 132), phase.rawValue)
            XCTAssertEqual(double(in: fields, raw: 124), -0.0001)
            XCTAssertEqual(integer(in: fields, raw: 123), 1)
            XCTAssertEqual(double(in: fields, raw: 129), -1_000)
            XCTAssertEqual(double(in: fields, raw: 130), -1_000)
        }
    }

    func testAugmentedFieldsPutVelocityOnlyOnTerminalPhase() {
        let began = SpaceGesture.fields(
            for: .began,
            direction: .next,
            augmented: true,
            timestamp: 456
        )
        let ended = SpaceGesture.fields(
            for: .ended,
            direction: .next,
            augmented: true,
            timestamp: 456
        )

        XCTAssertEqual(double(in: began, raw: 124), 0.0001)
        XCTAssertEqual(integer(in: began, raw: 134), SpaceGesturePhase.began.rawValue)
        XCTAssertEqual(double(in: began, raw: 138), 3)
        XCTAssertEqual(double(in: began, raw: 169), 456)
        XCTAssertEqual(double(in: began, raw: 125), 0.1)
        XCTAssertNil(double(in: began, raw: 129))
        XCTAssertEqual(double(in: ended, raw: 129), 1_000)
    }

    func testAugmentedPayloadLengthsAndRecordHeader() {
        let began = SpaceGesture.payload(for: .began, direction: .next, timestamp: 123)
        let ended = SpaceGesture.payload(for: .ended, direction: .previous, timestamp: 123)
        let record = SpaceGesture.payloadRecord(for: .began, direction: .next, timestamp: 123)

        XCTAssertEqual(began.count, 68)
        XCTAssertEqual(ended.count, 96)
        XCTAssertEqual(record.count, 72)
        XCTAssertEqual(Array(record.prefix(4)), [0, 68, 0x10, 0x6d])
        XCTAssertEqual(Array(began.prefix(8)), [123, 0, 0, 0, 0, 0, 0, 0])
        XCTAssertEqual(Array(began[24..<28]), [1, 0, 0, 0])
        XCTAssertEqual(int32LittleEndian(in: began, at: 64), 6)
        XCTAssertEqual(int32LittleEndian(in: ended, at: 64), -6)
        XCTAssertEqual(int32LittleEndian(in: ended, at: 84), -65_536_000)
    }

    func testDisplaySwitchProfileMatchesTinycastProgressEncoding() {
        let legacy = SpaceGesture.fields(
            for: .began,
            direction: .next,
            augmented: false,
            timestamp: 123,
            profile: .displaySwitch
        )
        let augmented = SpaceGesture.fields(
            for: .ended,
            direction: .previous,
            augmented: true,
            timestamp: 123,
            profile: .displaySwitch
        )
        let payload = SpaceGesture.payload(
            for: .ended,
            direction: .previous,
            timestamp: 123,
            profile: .displaySwitch
        )

        XCTAssertEqual(double(in: legacy, raw: 124), Double(Float.leastNonzeroMagnitude))
        XCTAssertEqual(double(in: augmented, raw: 124), -0.000016)
        XCTAssertEqual(int32LittleEndian(in: payload, at: 64), -1)
        XCTAssertEqual(int32LittleEndian(in: payload, at: 84), -65_536_000)
    }

    func testFixedPointKeepsSmallDirectionAndUsesNormalProgress() {
        XCTAssertEqual(SpaceGesture.fixed1616(0.0001), 6)
        XCTAssertEqual(SpaceGesture.fixed1616(-0.0001), -6)
        XCTAssertEqual(SpaceGesture.fixed1616(Double.leastNonzeroMagnitude), 1)
        XCTAssertEqual(SpaceGesture.fixed1616(-Double.leastNonzeroMagnitude), -1)
    }

    func testCorePosterPrebuildsLegacyAndAugmentedTransactions() {
        let dragPoint = CGPoint(x: 100, y: 100)
        for augmented in [false, true] {
            let poster = CoreGraphicsSpaceMoveEventPoster(
                augmentedEvents: augmented,
                keyboardFallback: false,
                naturalScrollingProvider: { true }
            )
            XCTAssertTrue(poster.prepare(direction: .next,
                                         at: dragPoint,
                                         probePoint: CGPoint(x: 108, y: 100)))
            poster.discardPreparedEvents()
        }

        let fallback = CoreGraphicsSpaceMoveEventPoster(
            augmentedEvents: false,
            keyboardFallback: true
        )
        XCTAssertTrue(fallback.prepare(direction: .previous,
                                       at: dragPoint,
                                       probePoint: CGPoint(x: 108, y: 100)))
    }

    func testNaturalScrollingOnlyReversesAugmentedGestureDirection() {
        XCTAssertEqual(CoreGraphicsSpaceMoveEventPoster.dockDirection(
            requested: .next,
            augmented: true,
            naturalScrolling: true
        ), .previous)
        XCTAssertEqual(CoreGraphicsSpaceMoveEventPoster.dockDirection(
            requested: .next,
            augmented: true,
            naturalScrolling: false
        ), .next)
        XCTAssertEqual(CoreGraphicsSpaceMoveEventPoster.dockDirection(
            requested: .previous,
            augmented: false,
            naturalScrolling: true
        ), .previous)
    }

    func testMouseDragProbeUsesOneEventSequenceWithExplicitDeltas() throws {
        let poster = CoreGraphicsSpaceMoveEventPoster(
            augmentedEvents: false,
            keyboardFallback: true
        )
        let eventNumber: Int64 = 812
        let event = try XCTUnwrap(poster.makeMouseEvent(
            .leftMouseDragged,
            at: CGPoint(x: 108, y: 100),
            eventNumber: eventNumber,
            deltaFrom: CGPoint(x: 100, y: 100)
        ))

        XCTAssertEqual(event.getIntegerValueField(.mouseEventNumber), eventNumber)
        XCTAssertEqual(event.getIntegerValueField(.mouseEventClickState), 1)
        XCTAssertEqual(event.getIntegerValueField(.mouseEventDeltaX), 8)
        XCTAssertEqual(event.getIntegerValueField(.mouseEventDeltaY), 0)
        XCTAssertEqual(event.getIntegerValueField(.eventSourceUserData), spaceMoveSyntheticEventTag)
        XCTAssertTrue(event.flags.contains(.maskNonCoalesced))
    }

    private func integer(in fields: [SpaceGesture.Field], raw: UInt32) -> Int64? {
        guard let field = fields.first(where: { $0.raw == raw }),
              case let .integer(value) = field.value
        else {
            return nil
        }
        return value
    }

    private func double(in fields: [SpaceGesture.Field], raw: UInt32) -> Double? {
        guard let field = fields.first(where: { $0.raw == raw }),
              case let .double(value) = field.value
        else {
            return nil
        }
        return value
    }

    private func int32LittleEndian(in data: Data, at offset: Int) -> Int32 {
        let bytes = [UInt8](data[offset..<(offset + 4)])
        let value = UInt32(bytes[0])
            | (UInt32(bytes[1]) << 8)
            | (UInt32(bytes[2]) << 16)
            | (UInt32(bytes[3]) << 24)
        return Int32(bitPattern: value)
    }
}

class SpaceSwitcherTests: XCTestCase {

    private final class PosterSpy: DisplaySpaceSwitchEventPosting {
        var accessibilityAuthorized = true
        var phaseDelay: TimeInterval = 0.01
        var prepareResult = true
        var failedPhase: SpaceGesturePhase?
        private(set) var directions = [SpaceDirection]()
        private(set) var phases = [SpaceGesturePhase]()
        private(set) var discardCount = 0

        func prepare(direction: SpaceDirection) -> Bool {
            directions.append(direction)
            return prepareResult
        }

        func post(_ phase: SpaceGesturePhase) -> Bool {
            phases.append(phase)
            return phase != failedPhase
        }

        func discardPreparedEvents() {
            discardCount += 1
        }
    }

    private final class SchedulerSpy {
        private(set) var delays = [TimeInterval]()
        private var actions = [() -> Void]()

        func schedule(delay: TimeInterval, action: @escaping () -> Void) {
            delays.append(delay)
            actions.append(action)
        }

        func runNext(file: StaticString = #filePath, line: UInt = #line) {
            guard !actions.isEmpty else {
                XCTFail("Expected a scheduled Space switch phase", file: file, line: line)
                return
            }
            actions.removeFirst()()
        }
    }

    func testPostsTinycastPhasesAndDropsOverlappingSwitch() {
        let poster = PosterSpy()
        let scheduler = SchedulerSpy()
        let switcher = SpaceSwitcher(eventPoster: poster, scheduler: scheduler.schedule,
                                    neighborAvailable: { _, _ in true })

        XCTAssertTrue(switcher.execute(parameters: ExecutionParameters(.switchNextSpace)))
        XCTAssertEqual(poster.directions, [.next])
        XCTAssertEqual(poster.phases, [.began])
        XCTAssertTrue(switcher.execute(parameters: ExecutionParameters(.switchPrevSpace)))
        XCTAssertEqual(poster.directions, [.next])

        scheduler.runNext()
        scheduler.runNext()
        XCTAssertEqual(poster.phases, [.began, .changed, .ended])
        XCTAssertEqual(scheduler.delays, [0.01, 0.01, 0.06])

        scheduler.runNext()
        XCTAssertEqual(poster.discardCount, 1)
        XCTAssertTrue(switcher.execute(parameters: ExecutionParameters(.switchPrevSpace)))
        XCTAssertEqual(poster.directions, [.next, .previous])
    }

    func testIgnoresWindowMoveActionsAndRequiresAccessibility() {
        let poster = PosterSpy()
        let scheduler = SchedulerSpy()
        let switcher = SpaceSwitcher(eventPoster: poster, scheduler: scheduler.schedule,
                                    neighborAvailable: { _, _ in true })

        XCTAssertFalse(switcher.execute(parameters: ExecutionParameters(.nextSpace)))
        poster.accessibilityAuthorized = false
        XCTAssertTrue(switcher.execute(parameters: ExecutionParameters(.switchNextSpace)))
        XCTAssertTrue(poster.directions.isEmpty)
    }

    func testSwitchDoesNothingAtEitherSpaceBoundary() {
        let availabilities: [Bool?] = [false, nil]
        for hasNeighbor in availabilities {
            let poster = PosterSpy()
            let scheduler = SchedulerSpy()
            let switcher = SpaceSwitcher(
                eventPoster: poster,
                scheduler: scheduler.schedule,
                neighborAvailable: { _, _ in hasNeighbor }
            )

            XCTAssertTrue(switcher.execute(parameters: ExecutionParameters(.switchPrevSpace)))
            XCTAssertTrue(switcher.execute(parameters: ExecutionParameters(.switchNextSpace)))
            XCTAssertTrue(poster.directions.isEmpty)
            XCTAssertTrue(poster.phases.isEmpty)
            XCTAssertTrue(scheduler.delays.isEmpty)
        }
    }

    func testCorePosterPrebuildsLegacyAndAugmentedGestures() {
        for augmented in [false, true] {
            let poster = CoreGraphicsDisplaySpaceSwitchEventPoster(
                augmentedEvents: augmented,
                naturalScrollingProvider: { true }
            )
            XCTAssertTrue(poster.prepare(direction: .next))
            XCTAssertEqual(poster.phaseDelay, augmented ? 0.01 : 0)
            poster.discardPreparedEvents()
        }
    }
}

class SpaceMoveEventTagTests: XCTestCase {

    func testSnappingRecognizesTaggedSpaceMoveMouseEvents() throws {
        let cgEvent = try XCTUnwrap(CGEvent(
            mouseEventSource: nil,
            mouseType: .leftMouseDown,
            mouseCursorPosition: .zero,
            mouseButton: .left
        ))
        cgEvent.setIntegerValueField(.eventSourceUserData, value: spaceMoveSyntheticEventTag)
        let event = try XCTUnwrap(NSEvent(cgEvent: cgEvent))

        XCTAssertTrue(SnappingManager.isSpaceMoveEvent(event))
    }
}
