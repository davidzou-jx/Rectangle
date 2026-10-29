/// ChangeSizeCalculation.swift

import Foundation

enum SizeScalingMode: Int {
    case percentage
    case widthPixels
    case heightPixels
    case absolutePixels
}

class ChangeSizeCalculation: WindowCalculation, ChangeWindowDimensionCalculation {

    let screenEdgeGapSize: CGFloat
    let curtainChangeSize = Defaults.curtainChangeSize.enabled != false
    let smallerShrinksMaximizedHeight = Defaults.smallerShrinksMaximizedHeight.enabled

    var sizeOffsetAbs: CGFloat {
        let configured = Defaults.sizeOffset.value
        return configured > 0 ? CGFloat(configured) : 30
    }

    var widthOffsetAbs: CGFloat {
        CGFloat(Defaults.widthStepSize.value)
    }

    override init() {
        let windowGapSize = Defaults.gapSize.value
        screenEdgeGapSize = (windowGapSize <= 0) ? 5.0 : CGFloat(windowGapSize)

    }

    override func calculateRect(_ params: RectCalculationParameters) -> RectResult {

        if (params.action == .larger || params.action == .smaller),
           Defaults.sizeScalingMode.value != .absolutePixels {
            return RectResult(scaledRect(params))
        }

        let sizeOffset: CGFloat
        switch params.action {
            case .larger, .largerHeight:
                sizeOffset = sizeOffsetAbs
            case .smaller, .smallerHeight:
                sizeOffset = -sizeOffsetAbs
            case .largerWidth:
                sizeOffset = widthOffsetAbs
            case .smallerWidth:
                sizeOffset = -widthOffsetAbs
            default:
                sizeOffset = 0
        }

        let visibleFrameOfScreen = params.visibleFrameOfScreen
        let window = params.window

        // Calculate Width

        var resizedWindowRect = window.rect

        if [.larger, .smaller, .largerWidth, .smallerWidth].contains(params.action) {
            resizedWindowRect.size.width = resizedWindowRect.width + sizeOffset
            resizedWindowRect.origin.x = resizedWindowRect.minX - floor(sizeOffset / 2.0)

            if curtainChangeSize {
                resizedWindowRect = againstLeftAndRightScreenEdges(
                    originalWindowRect: window.rect,
                    resizedWindowRect: resizedWindowRect,
                    visibleFrameOfScreen: visibleFrameOfScreen
                )
            }

            if resizedWindowRect.width >= visibleFrameOfScreen.width {
                resizedWindowRect.size.width = visibleFrameOfScreen.width
            }
        }

        // Calculate Height

        if [.larger, .smaller, .largerHeight, .smallerHeight].contains(params.action) {
            resizedWindowRect.size.height = resizedWindowRect.height + sizeOffset
            resizedWindowRect.origin.y = resizedWindowRect.minY - floor(sizeOffset / 2.0)

            // The height-only Smaller command skips the top/bottom edge curtain so it can
            // shrink even a full-height window. The legacy option extends this to Smaller.
            let heightCurtainActions: [WindowAction] = smallerShrinksMaximizedHeight
                ? [.smaller, .smallerHeight]
                : [.smallerHeight]

            if curtainChangeSize, !heightCurtainActions.contains(params.action) {
                resizedWindowRect = againstTopAndBottomScreenEdges(
                    originalWindowRect: window.rect,
                    resizedWindowRect: resizedWindowRect,
                    visibleFrameOfScreen: visibleFrameOfScreen
                )
            }

            if resizedWindowRect.height >= visibleFrameOfScreen.height {
                resizedWindowRect.size.height = visibleFrameOfScreen.height
                resizedWindowRect.origin.y = params.window.rect.minY
            }
        }


        if againstAllScreenEdges(windowRect: window.rect, visibleFrameOfScreen: visibleFrameOfScreen) && (sizeOffset < 0) {
            if [.smaller, .smallerWidth].contains(params.action) {
                resizedWindowRect.size.width = params.window.rect.width + sizeOffset
                resizedWindowRect.origin.x = params.window.rect.origin.x - floor(sizeOffset / 2.0)
            }
            if [.smaller, .smallerHeight].contains(params.action) {
                resizedWindowRect.size.height = params.window.rect.height + sizeOffset
                resizedWindowRect.origin.y = params.window.rect.origin.y - floor(sizeOffset / 2.0)
            }
        }
        
        if [.smaller, .smallerWidth, .smallerHeight].contains(params.action), resizedWindowRectIsTooSmall(windowRect: resizedWindowRect, visibleFrameOfScreen: visibleFrameOfScreen) {
            resizedWindowRect = window.rect
        }

        return RectResult(resizedWindowRect)
    }

    private func scaledRect(_ params: RectCalculationParameters) -> CGRect {
        let original = params.window.rect
        let screen = params.visibleFrameOfScreen
        guard original.width > 0, original.height > 0, screen.width > 0, screen.height > 0 else {
            return original
        }

        let mode = Defaults.sizeScalingMode.value
        let step: CGFloat
        switch mode {
        case .percentage:
            let configuredPercent = Defaults.sizeScalePercent.value
            let percent = configuredPercent.isFinite && configuredPercent > 0 && configuredPercent < 100
                ? CGFloat(configuredPercent)
                : 5
            step = percent / 100
        case .widthPixels, .heightPixels:
            let configuredPixels = Defaults.sizeScalePixels.value
            let pixels = configuredPixels.isFinite && configuredPixels > 0
                ? CGFloat(configuredPixels)
                : 30
            let base = mode == .widthPixels ? original.width : original.height
            step = pixels / base
        case .absolutePixels:
            return original
        }
        var scale: CGFloat
        if params.action == .larger {
            scale = 1 + step
        } else {
            scale = mode == .percentage ? 1 / (1 + step) : 1 - step
        }

        if params.action == .larger {
            scale = min(scale, screen.width / original.width, screen.height / original.height)
            guard scale > 1 else { return original }
        } else {
            // The same factor must fit both minimum dimensions to preserve the aspect ratio.
            let minimumWidth = max(1, floor(screen.width * minimumWindowFraction(Defaults.minimumWindowWidth)))
            let minimumHeight = max(1, floor(screen.height * minimumWindowFraction(Defaults.minimumWindowHeight)))
            scale = max(scale, minimumWidth / original.width, minimumHeight / original.height)
            guard scale < 1 else { return original }
        }

        let width = original.width * scale
        let height = original.height * scale
        let gap = CGFloat(Defaults.gapSize.value)
        let halfWidthChange = (width - original.width) / 2
        let halfHeightChange = (height - original.height) / 2
        let xOffset = mode == .percentage ? halfWidthChange : floor(halfWidthChange)
        let yOffset = mode == .percentage ? halfHeightChange : floor(halfHeightChange)
        var result = CGRect(x: original.minX - xOffset,
                            y: original.minY - yOffset,
                            width: width,
                            height: height)

        if curtainChangeSize {
            let left = againstLeftScreenEdge(original, screen)
            let right = againstRightScreenEdge(original, screen)
            let bottom = againstBottomScreenEdge(original, screen)
            let top = againstTopScreenEdge(original, screen)

            if left != right {
                result.origin.x = left ? screen.minX + gap : screen.maxX - width - gap
            }
            if bottom != top {
                result.origin.y = bottom ? screen.minY + gap : screen.maxY - height - gap
            }
        }

        return result
    }

    private func againstScreenEdge(_ gap: CGFloat) -> Bool {
        return abs(gap) <= screenEdgeGapSize
    }

    private func againstLeftScreenEdge(_ windowRect: CGRect, _ visibleFrameOfScreen: CGRect) -> Bool {
        return againstScreenEdge(windowRect.minX - visibleFrameOfScreen.minX)
    }

    private func againstRightScreenEdge(_ windowRect: CGRect, _ visibleFrameOfScreen: CGRect) -> Bool {
        return againstScreenEdge(windowRect.maxX - visibleFrameOfScreen.maxX)
    }

    private func againstTopScreenEdge(_ windowRect: CGRect, _ visibleFrameOfScreen: CGRect) -> Bool {
        return againstScreenEdge(windowRect.maxY - visibleFrameOfScreen.maxY)
    }

    private func againstBottomScreenEdge(_ windowRect: CGRect, _ visibleFrameOfScreen: CGRect) -> Bool {
        return againstScreenEdge(windowRect.minY - visibleFrameOfScreen.minY)
    }

    private func againstAllScreenEdges(windowRect: CGRect, visibleFrameOfScreen: CGRect) -> Bool {
        return (againstLeftScreenEdge(windowRect, visibleFrameOfScreen)
            && againstRightScreenEdge(windowRect, visibleFrameOfScreen)
            && againstTopScreenEdge(windowRect, visibleFrameOfScreen)
            && againstBottomScreenEdge(windowRect, visibleFrameOfScreen))
    }

    private func againstLeftAndRightScreenEdges(originalWindowRect: CGRect, resizedWindowRect: CGRect, visibleFrameOfScreen: CGRect) -> CGRect {
        var adjustedWindowRect = resizedWindowRect
        if againstRightScreenEdge(originalWindowRect, visibleFrameOfScreen) {
            adjustedWindowRect.origin.x = visibleFrameOfScreen.maxX - adjustedWindowRect.width - CGFloat(Defaults.gapSize.value)
            if againstLeftScreenEdge(originalWindowRect, visibleFrameOfScreen) {
                adjustedWindowRect.size.width = visibleFrameOfScreen.width - (CGFloat(Defaults.gapSize.value) * 2)
            }
        }
        if againstLeftScreenEdge(originalWindowRect, visibleFrameOfScreen) {
            adjustedWindowRect.origin.x = visibleFrameOfScreen.minX + CGFloat(Defaults.gapSize.value)
        }
        return adjustedWindowRect
    }

    private func againstTopAndBottomScreenEdges(originalWindowRect: CGRect, resizedWindowRect: CGRect, visibleFrameOfScreen: CGRect) -> CGRect{
        var adjustedWindowRect = resizedWindowRect
        if againstTopScreenEdge(originalWindowRect, visibleFrameOfScreen) {
            adjustedWindowRect.origin.y = visibleFrameOfScreen.maxY - adjustedWindowRect.height - CGFloat(Defaults.gapSize.value)
            if againstBottomScreenEdge(originalWindowRect, visibleFrameOfScreen) {
                adjustedWindowRect.size.height = visibleFrameOfScreen.height - (CGFloat(Defaults.gapSize.value) * 2)
            }
        }
        if againstBottomScreenEdge(originalWindowRect, visibleFrameOfScreen) {
            adjustedWindowRect.origin.y = visibleFrameOfScreen.minY + CGFloat(Defaults.gapSize.value)
        }
        return adjustedWindowRect
    }

}
