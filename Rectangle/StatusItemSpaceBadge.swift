/// StatusItemSpaceBadge.swift

import Cocoa
import CoreText

enum StatusItemIconLayout {
    static let topMargin: CGFloat = 2
    static let bottomMargin: CGFloat = 0
    static let horizontalMargin: CGFloat = 1
    static let maximumBadgeWidth: CGFloat = 24
}

enum StatusItemSpaceLabelStyle {
    static let fontSize: CGFloat = 13
    static let maxCharacters = 3
    static let maximumWidth: CGFloat = 36
    static let defaultDelimiter = "-"
    static let horizontalInset: CGFloat = 1
    static let badgeClearance: CGFloat = 2
    static let opticalCenteringStrength: CGFloat = 1
    static let maximumOpticalOffset: CGFloat = 1.5
    static let ascenderDescenderWeight: CGFloat = 0.25
}

struct StatusItemSpaceNumbers: Equatable {
    let internalDisplay: Int?
    let externalDisplay: Int?

    init(internalDisplay: Int? = nil, externalDisplay: Int? = nil) {
        self.internalDisplay = internalDisplay
        self.externalDisplay = externalDisplay
    }
}

/// At zero horizontal inset, the badge and its outline sit just outside the graphic.
/// Positive insets move inward; negative insets leave a gap. Values are in points.
struct StatusItemSpaceBadgeStyle: Equatable {
    let fontSize: CGFloat
    let borderWidth: CGFloat
    let rightInset: CGFloat
    let leftInset: CGFloat
    let bottomInset: CGFloat

    init(fontSize: CGFloat = 9, borderWidth: CGFloat = 1.5,
         rightInset: CGFloat = 4, leftInset: CGFloat = 4, bottomInset: CGFloat = 0) {
        self.fontSize = fontSize.isFinite ? min(max(fontSize, 6), 14) : 9
        self.borderWidth = borderWidth.isFinite ? min(max(borderWidth, 0), 3) : 1.5
        self.rightInset = rightInset.isFinite ? min(max(rightInset, -64), 64) : 4
        self.leftInset = leftInset.isFinite ? min(max(leftInset, -64), 64) : 4
        self.bottomInset = bottomInset.isFinite ? min(max(bottomInset, -64), 64) : 0
    }
}

enum StatusItemSpaceBadge {
    struct Label {
        let line: CTLine
        let bounds: CGRect
        let scale: CGFloat
        let horizontalOffset: CGFloat
    }

    struct Number {
        let path: CGPath
        let isInternal: Bool
        var frame: CGRect { path.boundingBoxOfPath }
    }

    struct Layout {
        let size: NSSize
        let contentRect: CGRect
        let graphicFrame: CGRect
        let label: Label?
        let numbers: [Number]
        let border: CGFloat

        var labelFrame: CGRect? {
            guard let label else { return nil }
            let width = label.bounds.width * label.scale
            return CGRect(x: graphicFrame.midX - width / 2 + label.horizontalOffset,
                          y: graphicFrame.minY, width: width, height: graphicFrame.height)
        }
    }

    static func image(base: NSImage, numbers: StatusItemSpaceNumbers, style: StatusItemSpaceBadgeStyle,
                      label: String? = nil) -> NSImage {
        guard let layout = layout(base: base, numbers: numbers, style: style, label: label) else { return base }
        let image = NSImage(size: layout.size, flipped: false) { _ in
            if layout.label == nil {
                base.draw(in: layout.graphicFrame, from: .zero, operation: .sourceOver, fraction: 1)
            }
            guard let context = NSGraphicsContext.current?.cgContext else { return false }
            context.saveGState()
            context.clip(to: layout.contentRect)
            context.setFillColor(NSColor.black.cgColor)
            context.setStrokeColor(NSColor.black.cgColor)
            if let label = layout.label, let frame = layout.labelFrame {
                context.saveGState()
                context.translateBy(x: frame.minX, y: frame.minY)
                context.scaleBy(x: label.scale, y: label.scale)
                context.textMatrix = .identity
                context.textPosition = CGPoint(x: -label.bounds.minX, y: -label.bounds.minY)
                CTLineDraw(label.line, context)
                context.restoreGState()
            }
            if layout.border > 0 {
                // Clear both halos before drawing either number so neither can erase the other.
                context.setBlendMode(.destinationOut)
                context.setLineWidth(layout.border * 2)
                context.setLineJoin(.round)
                for number in layout.numbers {
                    context.addPath(number.path)
                    context.drawPath(using: .fillStroke)
                }
            }
            context.setBlendMode(.normal)
            for number in layout.numbers {
                context.addPath(number.path)
                context.fillPath()
            }
            context.restoreGState()
            return true
        }
        image.isTemplate = true
        return image
    }

    static func layout(base: NSImage, numbers: StatusItemSpaceNumbers, style: StatusItemSpaceBadgeStyle,
                       label: String? = nil) -> Layout? {
        guard base.size.width.isFinite, base.size.height.isFinite,
              base.size.width > 0, base.size.height > 0 else { return nil }
        let top = min(max(0, StatusItemIconLayout.topMargin), base.size.height / 4)
        let bottom = min(max(0, StatusItemIconLayout.bottomMargin), base.size.height / 4)
        let contentHeight = base.size.height - top - bottom
        let border = min(style.borderWidth, min(base.size.width, contentHeight) / 4)
        let hasBoth = (numbers.internalDisplay ?? 0) > 0 && (numbers.externalDisplay ?? 0) > 0
        let labelDrawing = labelLine(label)
        let labelLayout: Label?
        var graphicFrame: CGRect
        if let (line, bounds) = labelDrawing {
            let maxWidth = max(1, StatusItemSpaceLabelStyle.maximumWidth - 2 * StatusItemSpaceLabelStyle.horizontalInset)
            let scale = min(1, maxWidth / bounds.width, contentHeight / bounds.height)
            let offset = horizontalOpticalOffset(line: line, bounds: bounds, scale: scale)
            labelLayout = Label(line: line, bounds: bounds, scale: scale, horizontalOffset: offset)
            let clearance = (numbers.internalDisplay ?? 0) > 0 || (numbers.externalDisplay ?? 0) > 0
                ? StatusItemSpaceLabelStyle.badgeClearance : 0
            let y = max(bottom, min(base.size.height - top - bounds.height * scale,
                                    bottom + (contentHeight - bounds.height * scale) / 2 + clearance))
            // Keep the shifted ink inside the anchor frame so zero-inset badges still cannot overlap it.
            graphicFrame = CGRect(x: 0, y: y, width: bounds.width * scale + 2 * abs(offset),
                                  height: bounds.height * scale)
        } else {
            labelLayout = nil
            graphicFrame = CGRect(origin: .zero, size: base.size)
        }

        var badges: [Number] = []
        for (value, isInternal, inset) in [(numbers.externalDisplay, false, style.leftInset),
                                          (numbers.internalDisplay, true, style.rightInset)] {
            guard let path = numberPath(value, style: style) else { continue }
            let bounds = path.boundingBoxOfPath
            let scale = min(1, StatusItemIconLayout.maximumBadgeWidth / bounds.width,
                            (contentHeight - 2 * border) / bounds.height)
            let width = bounds.width * scale
            let height = bounds.height * scale
            // Zero starts outside the graphic, including the halo. Positive values overlap it.
            let inward = hasBoth ? min(inset, graphicFrame.width / 2) : min(inset, graphicFrame.width)
            let x = isInternal ? graphicFrame.maxX + border - inward
                               : graphicFrame.minX - border - width + inward
            let y = max(bottom + border, min(base.size.height - top - border - height,
                                            bottom + border + style.bottomInset))
            var transform = CGAffineTransform(a: scale, b: 0, c: 0, d: scale,
                                             tx: x - bounds.minX * scale, ty: y - bounds.minY * scale)
            if let positioned = path.copy(using: &transform) {
                badges.append(Number(path: positioned, isInternal: isInternal))
            }
        }
        guard !badges.isEmpty || labelLayout != nil else { return nil }

        // Reserve exactly the horizontal space needed by the graphic, digits, and transparent outlines.
        var extent = graphicFrame
        for badge in badges { extent = extent.union(badge.frame.insetBy(dx: -border, dy: 0)) }
        let margin = StatusItemIconLayout.horizontalMargin
        let width: CGFloat
        let shift: CGFloat
        if labelLayout != nil {
            // Unequal badges must not pull the label away from the item's optical center.
            let halfWidth = max(graphicFrame.midX - extent.minX, extent.maxX - graphicFrame.midX)
            width = ceil(2 * (halfWidth + margin))
            shift = width / 2 - graphicFrame.midX
        } else {
            width = ceil(extent.width + 2 * margin)
            shift = margin - extent.minX + (width - extent.width - 2 * margin) / 2
        }
        graphicFrame.origin.x += shift
        var translation = CGAffineTransform(translationX: shift, y: 0)
        let translated = badges.compactMap { badge -> Number? in
            guard let path = badge.path.copy(using: &translation) else { return nil }
            return Number(path: path, isInternal: badge.isInternal)
        }
        return Layout(size: NSSize(width: width, height: base.size.height),
                      contentRect: CGRect(x: 0, y: bottom, width: width, height: contentHeight),
                      graphicFrame: graphicFrame, label: labelLayout, numbers: translated, border: border)
    }

    private static func horizontalOpticalOffset(line: CTLine, bounds: CGRect, scale: CGFloat) -> CGFloat {
        let strength = min(max(StatusItemSpaceLabelStyle.opticalCenteringStrength, 0), 1)
        guard strength > 0 else { return 0 }
        // Measure at a fixed resolution, independent of the menu bar's current display scale.
        let sampling: CGFloat = 4
        let width = Int(ceil(bounds.width * scale * sampling)) + 2
        let height = Int(ceil(bounds.height * scale * sampling)) + 2
        guard let context = CGContext(data: nil, width: width, height: height, bitsPerComponent: 8,
                                      bytesPerRow: width * 4, space: CGColorSpaceCreateDeviceRGB(),
                                      bitmapInfo: CGBitmapInfo.byteOrder32Big.rawValue | CGImageAlphaInfo.premultipliedLast.rawValue),
              let pixels = context.data?.assumingMemoryBound(to: UInt8.self) else { return 0 }
        context.clear(CGRect(x: 0, y: 0, width: width, height: height))
        context.setAllowsFontSmoothing(false)
        context.setShouldSubpixelPositionFonts(true)
        context.setShouldSubpixelQuantizeFonts(false)
        context.translateBy(x: 1, y: 1)
        context.scaleBy(x: sampling * scale, y: sampling * scale)
        context.textMatrix = .identity
        context.textPosition = CGPoint(x: -bounds.minX, y: -bounds.minY)
        CTLineDraw(line, context)
        context.flush()

        let xHeight = NSFont.systemFont(ofSize: StatusItemSpaceLabelStyle.fontSize, weight: .bold).xHeight
        let outerWeight = min(max(StatusItemSpaceLabelStyle.ascenderDescenderWeight, 0), 1)
        var weight: CGFloat = 0, moment: CGFloat = 0
        for y in 0..<height {
            // Bitmap rows run top-to-bottom; map them back to the font's baseline coordinates.
            let fontY = (CGFloat(height - y) - 1.5) / (sampling * scale) + bounds.minY
            let bodyWeight: CGFloat = fontY >= 0 && fontY <= xHeight ? 1 : outerWeight
            for x in 0..<width {
                let alpha = CGFloat(pixels[y * context.bytesPerRow + x * 4 + 3]) * bodyWeight
                weight += alpha
                moment += (CGFloat(x) - 0.5) / sampling * alpha
            }
        }
        guard weight > 0 else { return 0 }
        let limit = min(StatusItemSpaceLabelStyle.maximumOpticalOffset, bounds.width * scale * 0.05)
        let correction = max(-limit, min(limit, (bounds.width * scale / 2 - moment / weight) * strength))
        // Ignore subpixel noise for balanced words instead of changing their padding.
        return abs(correction) < 0.1 ? 0 : correction
    }

    private static func labelLine(_ label: String?) -> (CTLine, CGRect)? {
        guard let label, !label.isEmpty else { return nil }
        let text = NSAttributedString(string: String(label.prefix(max(0, StatusItemSpaceLabelStyle.maxCharacters))), attributes: [
            .font: NSFont.systemFont(ofSize: StatusItemSpaceLabelStyle.fontSize, weight: .bold), .foregroundColor: NSColor.black
        ])
        let line = CTLineCreateWithAttributedString(text)
        let bounds = CTLineGetBoundsWithOptions(line, [.useGlyphPathBounds])
        guard !bounds.isNull, bounds.origin.x.isFinite, bounds.origin.y.isFinite,
              bounds.width.isFinite, bounds.height.isFinite, bounds.width > 0, bounds.height > 0 else { return nil }
        return (line, bounds)
    }

    private static func numberPath(_ number: Int?, style: StatusItemSpaceBadgeStyle) -> CGPath? {
        guard let number, number > 0 else { return nil }
        let font = NSFont.monospacedDigitSystemFont(ofSize: style.fontSize, weight: .bold) as CTFont
        let characters = Array(String(number).utf16)
        var glyphs = [CGGlyph](repeating: 0, count: characters.count)
        guard CTFontGetGlyphsForCharacters(font, characters, &glyphs, characters.count) else { return nil }
        var advances = [CGSize](repeating: .zero, count: glyphs.count)
        CTFontGetAdvancesForGlyphs(font, .horizontal, glyphs, &advances, glyphs.count)
        let textPath = CGMutablePath()
        var x: CGFloat = 0
        for (index, glyph) in glyphs.enumerated() {
            if let path = CTFontCreatePathForGlyph(font, glyph, nil) {
                textPath.addPath(path, transform: CGAffineTransform(translationX: x, y: 0))
            }
            x += advances[index].width
        }

        return textPath.isEmpty ? nil : textPath
    }
}
