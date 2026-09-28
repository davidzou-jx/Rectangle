/// SpaceDragTargetResolver.swift

import Cocoa

/// A point that has been checked against both the system-wide accessibility
/// hierarchy and the target application's hierarchy.
struct SpaceDragTarget: Equatable {
    enum Source: String {
        case remembered
        case title
        case titleBar
        case toolbar
        case topBand
    }

    let point: CGPoint
    let source: Source
    let hitRole: NSAccessibility.Role?
    let score: Int
}

protocol SpaceDragTargetResolving: AnyObject {
    func candidates(for windowElement: AccessibilityElement) -> [SpaceDragTarget]
    func isValid(_ target: SpaceDragTarget, for windowElement: AccessibilityElement) -> Bool
    func recordSuccess(_ target: SpaceDragTarget, for windowElement: AccessibilityElement)
    func forgetSuccess(for windowElement: AccessibilityElement)
}

/// Finds title-bar points that are likely to begin a window drag without
/// activating a control. The resolver is intentionally separate from the
/// drag transaction: callers can try candidates in order, then report the one
/// that actually acquired a drag.
final class SpaceDragTargetResolver: SpaceDragTargetResolving {
    typealias HitTest = (_ position: CGPoint) -> AccessibilityElement?
    typealias ApplicationHitTest = (_ pid: pid_t, _ position: CGPoint) -> AccessibilityElement?

    private struct CacheKey: Hashable {
        let bundleIdentifier: String
        let role: String
        let subrole: String
        let titleBarHeight: Int
        let toolbarHeight: Int
    }

    private struct Seed {
        let point: CGPoint
        let source: SpaceDragTarget.Source
        let score: Int
    }

    private struct Obstacle {
        let frame: CGRect
        let role: String
    }

    private struct NormalizedPoint {
        let x: CGFloat
        let y: CGFloat

        init(point: CGPoint, in frame: CGRect) {
            x = (point.x - frame.minX) / frame.width
            y = (point.y - frame.minY) / frame.height
        }

        func point(in frame: CGRect) -> CGPoint {
            CGPoint(x: frame.minX + x * frame.width,
                    y: frame.minY + y * frame.height)
        }
    }

    private static let actionableRoles: Set<String> = [
        "AXButton", "AXCheckBox", "AXComboBox", "AXDisclosureTriangle",
        "AXLink", "AXMenuButton", "AXMenuItem", "AXPopUpButton",
        "AXRadioButton", "AXScrollBar", "AXSlider", "AXTab",
        "AXTextArea", "AXTextField"
    ]
    private static let actionableActions: Set<String> = [
        "AXPress", "AXPick", "AXShowMenu", "AXConfirm", "AXIncrement", "AXDecrement"
    ]
    private static let structuralRoles: Set<String> = [
        "AXWindow", "AXSplitGroup", "AXTabGroup", "AXToolbar", "AXTitleBar", "AXScrollArea"
    ]

    private let displayFramesProvider: () -> [CGRect]
    private let systemHitTest: HitTest
    private let applicationHitTest: ApplicationHitTest
    private let cacheLock = NSLock()
    private var successfulPoints = [CacheKey: NormalizedPoint]()

    init(
        displayFramesProvider: @escaping () -> [CGRect] = {
            NSScreen.screens.map(\.frame.screenFlipped)
        },
        systemHitTest: @escaping HitTest = { AccessibilityElement($0) },
        applicationHitTest: @escaping ApplicationHitTest = { pid, point in
            let application = AccessibilityElement(pid)
            application.setMessagingTimeout(0.1)
            return application.getElementAtPosition(point)
        }
    ) {
        self.displayFramesProvider = displayFramesProvider
        self.systemHitTest = systemHitTest
        self.applicationHitTest = applicationHitTest
    }

    /// Returns safe candidates in preferred order. Each returned point belongs
    /// to the requested PID and window in both AX hit-test hierarchies.
    func candidates(for windowElement: AccessibilityElement) -> [SpaceDragTarget] {
        let window = windowElement.windowElement ?? windowElement
        let windowFrame = window.frame
        let rawTitleBar = validFrame(window.titleBarFrame)
        guard let pid = window.pid,
              !windowFrame.isNull,
              windowFrame.width >= 20,
              windowFrame.height >= 10,
              let displayClip = displayClip(for: windowFrame, preferredFrame: rawTitleBar)
        else {
            Logger.log("Space drag target search could not obtain window geometry or a display clip")
            return []
        }

        let titleBar = clipped(window.titleBarFrame, to: displayClip)
        let title = clipped(window.titleElement?.frame, to: displayClip)
        let toolbarElement = window.getChildElement(.toolbar)
        let toolbar = clipped(toolbarElement?.frame, to: displayClip)
        let interestFrame = topInterestFrame(
            windowFrame: windowFrame,
            displayClip: displayClip,
            titleBar: titleBar,
            toolbar: toolbar
        )
        let obstacles = actionableFrames(in: window, intersecting: interestFrame)
        let cacheKey = cacheKey(for: window, titleBar: titleBar, toolbar: toolbar)
        let targetWindowId = window.windowId

        var seeds = [Seed]()
        if let remembered = successfulPoint(for: cacheKey) {
            seeds.append(Seed(point: remembered.point(in: windowFrame),
                              source: .remembered,
                              score: 1_000))
        }
        if let title {
            seeds.append(contentsOf: makeSeeds(in: title,
                                              source: .title,
                                              baseScore: 850,
                                              verticalFractions: [0.5],
                                              horizontalFractions: [0.5, 0.25, 0.75]))
        }
        if let titleBar {
            seeds.append(contentsOf: makeSeeds(in: titleBar,
                                              source: .titleBar,
                                              baseScore: 700,
                                              verticalFractions: [0.5, 0.7],
                                              horizontalFractions: [0.5, 0.35, 0.65, 0.2, 0.8]))
            let leftClearPoint = CGPoint(x: min(titleBar.maxX - 4, titleBar.minX + 100),
                                         y: titleBar.midY)
            seeds.append(Seed(point: leftClearPoint, source: .titleBar, score: 725))
        }
        if let toolbar {
            seeds.append(contentsOf: makeSeeds(in: toolbar,
                                              source: .toolbar,
                                              baseScore: 500,
                                              verticalFractions: [0.5],
                                              horizontalFractions: [0.5, 0.33, 0.67, 0.2, 0.8]))
        }
        seeds.append(contentsOf: topBandSeeds(in: interestFrame, windowFrame: windowFrame))

        var seen = Set<String>()
        var results = [SpaceDragTarget]()
        var rejections = [String: Int]()
        func reject(_ reason: String) {
            rejections[reason, default: 0] += 1
        }
        for seed in seeds {
            if results.count >= 8 { break }
            guard displayClip.contains(seed.point), windowFrame.contains(seed.point) else {
                reject("outside window or display")
                continue
            }
            let identity = "\(Int(seed.point.x.rounded())):\(Int(seed.point.y.rounded()))"
            guard seen.insert(identity).inserted else { continue }
            guard !obstacles.contains(where: { $0.frame.insetBy(dx: -3, dy: -3).contains(seed.point) }) else {
                reject("covered by AX control")
                continue
            }
            guard let hit = validate(
                point: seed.point,
                targetWindow: window,
                targetPid: pid,
                targetWindowId: targetWindowId,
                onReject: reject
            ) else {
                continue
            }
            let roleScore = safetyScore(for: hit.role)
            guard roleScore >= 0 else {
                reject("unsupported role \(hit.role?.rawValue ?? "unknown")")
                continue
            }
            results.append(SpaceDragTarget(point: seed.point,
                                           source: seed.source,
                                           hitRole: hit.role,
                                           score: seed.score + roleScore))
        }

        if results.isEmpty {
            let summary = rejections.keys.sorted().map { "\($0): \(rejections[$0] ?? 0)" }.joined(separator: ", ")
            Logger.log("No safe Space drag targets among \(seeds.count) seeds (\(summary))")
            let obstacleSummary = Dictionary(grouping: obstacles, by: \.role)
                .map { "\($0.key): \($0.value.count)" }
                .sorted()
                .joined(separator: ", ")
            Logger.log("Space drag AX obstacles: \(obstacleSummary)")
        }

        return results.sorted {
            if $0.score != $1.score { return $0.score > $1.score }
            if $0.point.x != $1.point.x { return $0.point.x < $1.point.x }
            return $0.point.y < $1.point.y
        }
    }

    func isValid(_ target: SpaceDragTarget, for windowElement: AccessibilityElement) -> Bool {
        let window = windowElement.windowElement ?? windowElement
        guard let pid = window.pid else { return false }
        return validate(point: target.point,
                        targetWindow: window,
                        targetPid: pid,
                        targetWindowId: window.windowId) != nil
    }

    /// Remembers a candidate only after the caller proves that it acquired a
    /// drag. Normalization lets the point follow later window-size changes.
    func recordSuccess(_ target: SpaceDragTarget, for windowElement: AccessibilityElement) {
        let window = windowElement.windowElement ?? windowElement
        let frame = window.frame
        guard !frame.isNull, frame.width > 0, frame.height > 0, frame.contains(target.point) else {
            return
        }
        let titleBar = validFrame(window.titleBarFrame)
        let toolbar = validFrame(window.getChildElement(.toolbar)?.frame)
        let key = cacheKey(for: window, titleBar: titleBar, toolbar: toolbar)
        let normalized = NormalizedPoint(point: target.point, in: frame)
        cacheLock.lock()
        successfulPoints[key] = normalized
        cacheLock.unlock()
    }

    func forgetSuccess(for windowElement: AccessibilityElement) {
        let window = windowElement.windowElement ?? windowElement
        let key = cacheKey(for: window,
                           titleBar: validFrame(window.titleBarFrame),
                           toolbar: validFrame(window.getChildElement(.toolbar)?.frame))
        cacheLock.lock()
        successfulPoints.removeValue(forKey: key)
        cacheLock.unlock()
    }

    private func displayClip(for windowFrame: CGRect, preferredFrame: CGRect?) -> CGRect? {
        let selectionFrame = preferredFrame ?? windowFrame
        let displayFrame = displayFramesProvider()
            .filter { !$0.isNull && $0.width > 0 && $0.height > 0 }
            .max {
                area(of: $0.intersection(selectionFrame)) < area(of: $1.intersection(selectionFrame))
            }
        guard let displayFrame else { return nil }
        let clip = displayFrame.insetBy(dx: 2, dy: 2).intersection(windowFrame)
        return validFrame(clip)
    }

    private func topInterestFrame(windowFrame: CGRect,
                                  displayClip: CGRect,
                                  titleBar: CGRect?,
                                  toolbar: CGRect?) -> CGRect {
        var bottom = min(windowFrame.maxY, windowFrame.minY + 64)
        if let titleBar { bottom = max(bottom, titleBar.maxY) }
        if let toolbar { bottom = max(bottom, toolbar.maxY) }
        return CGRect(x: displayClip.minX,
                      y: max(windowFrame.minY, displayClip.minY),
                      width: displayClip.width,
                      height: max(0, min(bottom, displayClip.maxY) - max(windowFrame.minY, displayClip.minY)))
    }

    private func makeSeeds(in frame: CGRect,
                           source: SpaceDragTarget.Source,
                           baseScore: Int,
                           verticalFractions: [CGFloat],
                           horizontalFractions: [CGFloat]) -> [Seed] {
        guard let frame = validFrame(frame) else { return [] }
        return verticalFractions.flatMap { y in
            horizontalFractions.map { x in
                Seed(point: CGPoint(x: frame.minX + frame.width * x,
                                    y: frame.minY + frame.height * y),
                     source: source,
                     score: baseScore)
            }
        }
    }

    private func topBandSeeds(in interestFrame: CGRect, windowFrame: CGRect) -> [Seed] {
        guard let interestFrame = validFrame(interestFrame) else { return [] }
        let yOffsets: [CGFloat] = [10, 18, 28, 40, 52]
        let xFractions: [CGFloat] = [0.5, 0.35, 0.65, 0.2, 0.8]
        // Visit every height at the center before moving sideways. A browser
        // tab strip can cover the first few heights, while a lower band can
        // still have a clear draggable point.
        return xFractions.flatMap { fraction in
            yOffsets.compactMap { offset -> Seed? in
                let y = windowFrame.minY + offset
                guard y >= interestFrame.minY, y < interestFrame.maxY else { return nil }
                return Seed(point: CGPoint(x: interestFrame.minX + interestFrame.width * fraction, y: y),
                            source: .topBand,
                            score: 300 - Int(offset))
            }
        }
    }

    private func actionableFrames(in root: AccessibilityElement, intersecting interest: CGRect) -> [Obstacle] {
        guard !interest.isNull, interest.width > 0, interest.height > 0 else { return [] }
        var frames = [Obstacle]()
        var pending = (root.childElements ?? []).map { (element: $0, depth: 0) }
        var visited = Set<AccessibilityElement>()
        var inspected = 0

        while !pending.isEmpty, inspected < 32 {
            let entry = pending.removeFirst()
            guard visited.insert(entry.element).inserted else { continue }
            inspected += 1
            let children = entry.element.childElements ?? []
            if let frame = validFrame(entry.element.frame) {
                guard frame.intersects(interest) else { continue }
                let isContainerWithControls = entry.element.role?.rawValue == "AXGroup"
                    && !children.isEmpty
                if isActionable(entry.element) && !isContainerWithControls {
                    frames.append(Obstacle(frame: frame,
                                           role: entry.element.role?.rawValue ?? "unknown"))
                    continue
                }
            }
            if entry.depth < 4 {
                pending.append(contentsOf: children.map {
                    (element: $0, depth: entry.depth + 1)
                })
            }
        }
        return frames
    }

    private func validate(point: CGPoint,
                          targetWindow: AccessibilityElement,
                          targetPid: pid_t,
                          targetWindowId: CGWindowID?,
                          onReject: ((String) -> Void)? = nil) -> AccessibilityElement? {
        guard let systemHit = systemHitTest(point) else {
            onReject?("system hit missing")
            return nil
        }
        guard let applicationHit = applicationHitTest(targetPid, point) else {
            onReject?("application hit missing")
            return nil
        }
        systemHit.setMessagingTimeout(0.1)
        applicationHit.setMessagingTimeout(0.1)
        guard belongsToTarget(systemHit,
                              window: targetWindow,
                              pid: targetPid,
                              windowId: targetWindowId) else {
            onReject?("system window mismatch \(systemHit.role?.rawValue ?? "unknown")")
            return nil
        }
        guard belongsToTarget(applicationHit,
                              window: targetWindow,
                              pid: targetPid,
                              windowId: targetWindowId) else {
            onReject?("application window mismatch \(applicationHit.role?.rawValue ?? "unknown")")
            return nil
        }
        guard !isActionable(systemHit) else {
            onReject?("system actionable \(systemHit.role?.rawValue ?? "unknown")")
            return nil
        }
        guard !isActionable(applicationHit) else {
            onReject?("application actionable \(applicationHit.role?.rawValue ?? "unknown")")
            return nil
        }
        return systemHit
    }

    private func belongsToTarget(_ hit: AccessibilityElement,
                                 window targetWindow: AccessibilityElement,
                                 pid targetPid: pid_t,
                                 windowId targetWindowId: CGWindowID?) -> Bool {
        guard hit.pid == targetPid else { return false }
        let hitWindow = hit.topLevelElement ?? hit.windowElement
        guard let hitWindow else { return false }
        if let targetWindowId {
            return hitWindow.windowId == targetWindowId
        }
        if hitWindow == targetWindow { return true }
        return framesMatch(hitWindow.frame, targetWindow.frame)
    }

    private func isActionable(_ element: AccessibilityElement) -> Bool {
        if let role = element.role?.rawValue, Self.actionableRoles.contains(role) {
            return true
        }
        // Safari and other apps can expose actions on a container covering
        // the whole toolbar. Its descendants identify the actual controls.
        if let role = element.role?.rawValue, Self.structuralRoles.contains(role) {
            return false
        }
        return !Self.actionableActions.isDisjoint(with: element.actionNames)
    }

    private func safetyScore(for role: NSAccessibility.Role?) -> Int {
        guard let role else { return -1 }
        if Self.actionableRoles.contains(role.rawValue) { return -1 }
        switch role.rawValue {
        case "AXWindow": return 90
        case "AXStaticText": return 80
        case "AXTitleBar": return 75
        case "AXToolbar": return 70
        case "AXGroup": return 60
        case "AXTabGroup": return 50
        case "AXSplitGroup": return 40
        default: return -1
        }
    }

    private func cacheKey(for window: AccessibilityElement,
                          titleBar: CGRect?,
                          toolbar: CGRect?) -> CacheKey {
        CacheKey(
            bundleIdentifier: window.bundleIdentifier ?? "pid:\(window.pid ?? 0)",
            role: window.role?.rawValue ?? "",
            subrole: window.subrole?.rawValue ?? "",
            titleBarHeight: Int((titleBar?.height ?? 0).rounded()),
            toolbarHeight: Int((toolbar?.height ?? 0).rounded())
        )
    }

    private func successfulPoint(for key: CacheKey) -> NormalizedPoint? {
        cacheLock.lock()
        defer { cacheLock.unlock() }
        return successfulPoints[key]
    }

    private func validFrame(_ frame: CGRect?) -> CGRect? {
        guard let frame, !frame.isNull, frame.width > 0, frame.height > 0 else { return nil }
        return frame
    }

    private func clipped(_ frame: CGRect?, to clip: CGRect) -> CGRect? {
        guard let frame = validFrame(frame) else { return nil }
        return validFrame(frame.intersection(clip))
    }

    private func area(of frame: CGRect) -> CGFloat {
        guard !frame.isNull else { return 0 }
        return max(0, frame.width) * max(0, frame.height)
    }

    private func framesMatch(_ lhs: CGRect, _ rhs: CGRect, tolerance: CGFloat = 1) -> Bool {
        guard !lhs.isNull, !rhs.isNull else { return false }
        return abs(lhs.minX - rhs.minX) <= tolerance
            && abs(lhs.minY - rhs.minY) <= tolerance
            && abs(lhs.width - rhs.width) <= tolerance
            && abs(lhs.height - rhs.height) <= tolerance
    }
}
