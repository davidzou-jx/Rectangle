/// CGExtension.swift

import Foundation

extension CGPoint {
    var screenFlipped: CGPoint {
        screenFlipped(primaryScreenMaxY: NSScreen.screens.first?.frame.maxY)
    }

    func screenFlipped(primaryScreenMaxY: CGFloat?) -> CGPoint {
        guard let primaryScreenMaxY else { return self }
        return .init(x: x, y: primaryScreenMaxY - y)
    }
}

extension CGRect {
    var screenFlipped: CGRect {
        screenFlipped(primaryScreenMaxY: NSScreen.screens.first?.frame.maxY)
    }

    func screenFlipped(primaryScreenMaxY: CGFloat?) -> CGRect {
        guard !isNull, let primaryScreenMaxY else { return self }
        return .init(origin: .init(x: origin.x, y: primaryScreenMaxY - maxY), size: size)
    }

    var isFiniteAndNonEmpty: Bool {
        !isNull && origin.x.isFinite && origin.y.isFinite && size.width.isFinite && size.height.isFinite
            && size.width > 0 && size.height > 0 && maxX.isFinite && maxY.isFinite
    }

    var isLandscape: Bool { width > height }
    
    var centerPoint: CGPoint {
        NSMakePoint(NSMidX(self), NSMidY(self))
    }
    
    func numSharedEdges(withRect rect: CGRect) -> Int {
        var sharedEdgeCount = 0
        if minX == rect.minX { sharedEdgeCount += 1 }
        if maxX == rect.maxX { sharedEdgeCount += 1 }
        if minY == rect.minY { sharedEdgeCount += 1 }
        if maxY == rect.maxY { sharedEdgeCount += 1 }
        return sharedEdgeCount
    }

    func sharedEdges(withRect rect: CGRect, tolerance: CGFloat = 0) -> Edge {
        var edges: Edge = .none
        if abs(minX - rect.minX) <= tolerance { edges.insert(.left) }
        if abs(maxX - rect.maxX) <= tolerance { edges.insert(.right) }
        if abs(maxY - rect.maxY) <= tolerance { edges.insert(.top) }
        if abs(minY - rect.minY) <= tolerance { edges.insert(.bottom) }
        return edges
    }
}

extension OptionSet where RawValue: FixedWidthInteger {
    var count: Int {
        rawValue.nonzeroBitCount
    }
}
