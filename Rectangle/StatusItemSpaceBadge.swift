/// StatusItemSpaceBadge.swift

import Cocoa
import CoreText

enum StatusItemIconLayout {
    static let topMargin: CGFloat = 2
    static let bottomMargin: CGFloat = 0
    static let horizontalMargin: CGFloat = 1
    static let maximumBadgeWidth: CGFloat = 24
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
    struct Number {
        let path: CGPath
        let isInternal: Bool
        var frame: CGRect { path.boundingBoxOfPath }
    }

    struct Layout {
        let size: NSSize
        let contentRect: CGRect
        let graphicFrame: CGRect
        let numbers: [Number]
        let border: CGFloat

    }

    static func image(base: NSImage, numbers: StatusItemSpaceNumbers, style: StatusItemSpaceBadgeStyle) -> NSImage {
        guard let layout = layout(base: base, numbers: numbers, style: style) else { return base }
        let image = NSImage(size: layout.size, flipped: false) { _ in
            base.draw(in: layout.graphicFrame, from: .zero, operation: .sourceOver, fraction: 1)
            guard let context = NSGraphicsContext.current?.cgContext else { return false }
            context.saveGState()
            context.clip(to: layout.contentRect)
            context.setFillColor(NSColor.black.cgColor)
            context.setStrokeColor(NSColor.black.cgColor)
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

    static func layout(base: NSImage, numbers: StatusItemSpaceNumbers, style: StatusItemSpaceBadgeStyle) -> Layout? {
        guard base.size.width.isFinite, base.size.height.isFinite,
              base.size.width > 0, base.size.height > 0 else { return nil }
        let top = min(max(0, StatusItemIconLayout.topMargin), base.size.height / 4)
        let bottom = min(max(0, StatusItemIconLayout.bottomMargin), base.size.height / 4)
        let contentHeight = base.size.height - top - bottom
        let border = min(style.borderWidth, min(base.size.width, contentHeight) / 4)
        let hasBoth = (numbers.internalDisplay ?? 0) > 0 && (numbers.externalDisplay ?? 0) > 0
        var graphicFrame = CGRect(origin: .zero, size: base.size)

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
        guard !badges.isEmpty else { return nil }

        // Reserve exactly the horizontal space needed by the graphic, digits, and transparent outlines.
        var extent = graphicFrame
        for badge in badges { extent = extent.union(badge.frame.insetBy(dx: -border, dy: 0)) }
        let margin = StatusItemIconLayout.horizontalMargin
        let width = ceil(extent.width + 2 * margin)
        let shift = margin - extent.minX + (width - extent.width - 2 * margin) / 2
        graphicFrame.origin.x += shift
        var translation = CGAffineTransform(translationX: shift, y: 0)
        let translated = badges.compactMap { badge -> Number? in
            guard let path = badge.path.copy(using: &translation) else { return nil }
            return Number(path: path, isInternal: badge.isInternal)
        }
        return Layout(size: NSSize(width: width, height: base.size.height),
                      contentRect: CGRect(x: 0, y: bottom, width: width, height: contentHeight),
                      graphicFrame: graphicFrame, numbers: translated, border: border)
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
