/// RectangleTests.swift

import Carbon.HIToolbox
import CoreText
import MASShortcut
import XCTest
@testable import Rectangle

final class YabaiSpaceLabelTests: XCTestCase {
    func testUsesFirstLiteralDelimiterSeparatedPartAndThreeCharacters() {
        XCTAssertEqual(YabaiSpaceLabel.abbreviated("Work-project", delimiter: "-"), "Wor")
        XCTAssertEqual(YabaiSpaceLabel.abbreviated(" Web :: browser :: docs ", delimiter: "::"), "Web")
        XCTAssertEqual(YabaiSpaceLabel.abbreviated("Dev*project", delimiter: "*"), "Dev")
        XCTAssertEqual(YabaiSpaceLabel.abbreviated("Tools-project", delimiter: ""), "Too")
        XCTAssertEqual(YabaiSpaceLabel.abbreviated("Hi", delimiter: "-"), "Hi")
        XCTAssertEqual(YabaiSpaceLabel.abbreviated("👩🏽‍💻研究室-work", delimiter: "-"), "👩🏽‍💻研究")
    }

    func testMissingLabelsAndEmptyPrefixesFallBackToTheIcon() {
        for label in [nil, "", "  \n ", "-suffix", "  -suffix"] as [String?] {
            XCTAssertNil(YabaiSpaceLabel.abbreviated(label, delimiter: "-"))
        }
    }

    func testDecodesFocusedSpaceResponseAndRejectsInvalidResponses() {
        XCTAssertEqual(YabaiSpaceLabel.label(from: Data(#"{"id":57,"label":"Code-app","has-focus":true}"#.utf8)), "Code-app")
        for invalid in ["not JSON", "[]", "{}", #"{"label":null}"#, #"{"label":42}"#] {
            XCTAssertNil(YabaiSpaceLabel.label(from: Data(invalid.utf8)))
        }
    }

    private func executable(_ script: String) throws -> URL {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        addTeardownBlock { try? FileManager.default.removeItem(at: directory) }
        let url = directory.appendingPathComponent("yabai")
        try ("#!/bin/sh\n" + script).write(to: url, atomically: true, encoding: .utf8)
        try FileManager.default.setAttributes([.posixPermissions: 0o700], ofItemAtPath: url.path)
        return url
    }

    func testReaderQueriesFocusedSpaceOffMainAndCompletesOnMain() throws {
        let url = try executable(#"if [ "$*" != '-m query --spaces --space' ]; then exit 3; fi"# + "\n" +
                                 #"printf '%s' '{"label":"Work-project"}'"#)
        let completed = expectation(description: "Yabai label")
        let reader = YabaiSpaceLabelReader(executableProvider: {
            XCTAssertFalse(Thread.isMainThread)
            return url
        })
        reader.read { label in
            XCTAssertTrue(Thread.isMainThread)
            XCTAssertEqual(label, "Work-project")
            completed.fulfill()
        }
        wait(for: [completed], timeout: 2)
    }

    func testMissingExecutableFailedCommandAndBadJSONReturnNoLabel() throws {
        let invalid = try executable("printf '%s' 'invalid JSON'")
        let urls: [URL?] = [nil, URL(fileURLWithPath: "/nonexistent/yabai"),
                            URL(fileURLWithPath: "/usr/bin/false"), invalid]
        let completed = urls.map { _ in expectation(description: "Fallback") }
        for (index, url) in urls.enumerated() {
            YabaiSpaceLabelReader(executableProvider: { url }).read { label in
                XCTAssertNil(label)
                completed[index].fulfill()
            }
        }
        wait(for: completed, timeout: 2)
    }

    func testUnresponsiveYabaiTimesOut() throws {
        let url = try executable("exec /bin/sleep 10")
        let completed = expectation(description: "Timed out")
        YabaiSpaceLabelReader(executableProvider: { url }, timeout: 0.05).read { label in
            XCTAssertNil(label)
            completed.fulfill()
        }
        wait(for: [completed], timeout: 1)
    }
}

final class StatusItemSpaceBadgeTests: XCTestCase {
    private let displays: [[String: Any]] = [
        ["Display Identifier": "A", "Current Space": ["id64": 57],
         "Spaces": [["id64": 10, "type": 0], ["id64": 99, "type": 4], ["id64": 57, "type": 0]]],
        ["Display Identifier": "B", "Current Space": ["id64": 901],
         "Spaces": [["id64": 900, "type": 0], ["id64": 901, "type": 0]]]
    ]

    func testBadgeNumbersMatchNumberedShortcutsAcrossDisplays() {
        for identifier in ["A", "B"] {
            let number = ManagedSpaceTopology.currentDesktopNumber(on: identifier, in: displays)
            XCTAssertEqual(number, identifier == "A" ? 2 : 4)
            let target = number.flatMap { ManagedSpaceTopology.desktop(number: $0, in: displays) }
            XCTAssertEqual(target?.displayIdentifier, identifier)
            XCTAssertEqual(target?.destinationID, ManagedSpaceTopology.currentSpace(for: identifier, in: displays))
        }
    }

    func testDesktopReorderingRefreshesTheNumberWithoutChangingTheSpaceID() {
        var reordered = displays
        reordered[0]["Spaces"] = [["id64": 57, "type": 0], ["id64": 10, "type": 0], ["id64": 99, "type": 4]]
        XCTAssertEqual(ManagedSpaceTopology.currentDesktopNumber(on: "A", in: reordered), 1)
    }

    func testFullscreenUnknownDisplayAndIncompleteTopologyHaveNoNumber() {
        var fullscreen = displays
        fullscreen[0]["Current Space"] = ["id64": 99]
        XCTAssertNil(ManagedSpaceTopology.currentDesktopNumber(on: "A", in: fullscreen))
        XCTAssertNil(ManagedSpaceTopology.currentDesktopNumber(on: "missing", in: displays))
        var malformed = displays
        malformed[0]["Spaces"] = [["id64": 57, "type": 0], ["type": 0]]
        // A malformed earlier display must not silently renumber the later display.
        XCTAssertNil(ManagedSpaceTopology.currentDesktopNumber(on: "B", in: malformed))
        XCTAssertNil(ManagedSpaceTopology.currentDesktopNumber(on: "A", in: []))
    }

    func testInternalAndExternalNumbersFollowHardwareRolesInsteadOfScreenOrder() {
        let screens = [(identifier: "B", isBuiltIn: false), (identifier: "A", isBuiltIn: true)]
        let expected = StatusItemSpaceNumbers(internalDisplay: 2, externalDisplay: 4)
        XCTAssertEqual(StatusItemSpaceNumbers.current(for: screens, in: displays), expected)
        XCTAssertEqual(StatusItemSpaceNumbers.current(for: Array(screens.reversed()), in: displays), expected)

        var changed = displays
        changed[1]["Current Space"] = ["id64": 900]
        XCTAssertEqual(StatusItemSpaceNumbers.current(for: screens, in: changed),
                       StatusItemSpaceNumbers(internalDisplay: 2, externalDisplay: 3))
        changed[0]["Current Space"] = ["id64": 10]
        XCTAssertEqual(StatusItemSpaceNumbers.current(for: screens, in: changed),
                       StatusItemSpaceNumbers(internalDisplay: 1, externalDisplay: 3))
    }

    func testDisconnectAndFullscreenOnlyRemoveTheAffectedDisplaysNumber() {
        XCTAssertEqual(StatusItemSpaceNumbers.current(for: [("A", true)], in: displays),
                       StatusItemSpaceNumbers(internalDisplay: 2))
        XCTAssertEqual(StatusItemSpaceNumbers.current(for: [("B", false)], in: displays),
                       StatusItemSpaceNumbers(externalDisplay: 4))
        var fullscreen = displays
        fullscreen[0]["Current Space"] = ["id64": 99]
        XCTAssertEqual(StatusItemSpaceNumbers.current(for: [("A", true), ("B", false)], in: fullscreen),
                       StatusItemSpaceNumbers(externalDisplay: 4))
        XCTAssertEqual(StatusItemSpaceNumbers.current(for: [], in: displays), StatusItemSpaceNumbers())
        XCTAssertEqual(StatusItemSpaceNumbers.current(for: [("unknown", true)], in: []), StatusItemSpaceNumbers())
    }

    func testAdditionalDisplaysAreSafelyIgnoredAfterTheFirstOfEachKind() {
        let screens = [("A", true), ("B", false), ("unused", false), ("unusedInternal", true)]
        XCTAssertEqual(StatusItemSpaceNumbers.current(for: screens, in: displays),
                       StatusItemSpaceNumbers(internalDisplay: 2, externalDisplay: 4))
    }

    private func baseImage() -> NSImage {
        NSImage(size: NSSize(width: 22, height: 22), flipped: false) { rect in
            NSColor.black.setFill()
            rect.fill()
            return true
        }
    }

    private func bitmap(_ image: NSImage, scale: Int) -> NSBitmapImageRep {
        let bitmap = NSBitmapImageRep(bitmapDataPlanes: nil,
                                      pixelsWide: Int(ceil(image.size.width * CGFloat(scale))),
                                      pixelsHigh: Int(ceil(image.size.height * CGFloat(scale))),
                                      bitsPerSample: 8, samplesPerPixel: 4, hasAlpha: true, isPlanar: false,
                                      colorSpaceName: .deviceRGB, bytesPerRow: 0, bitsPerPixel: 0)!
        NSGraphicsContext.saveGraphicsState()
        let context = NSGraphicsContext(bitmapImageRep: bitmap)!
        NSGraphicsContext.current = context
        context.cgContext.scaleBy(x: CGFloat(scale), y: CGFloat(scale))
        image.draw(in: NSRect(origin: .zero, size: image.size), from: .zero, operation: .sourceOver, fraction: 1)
        NSGraphicsContext.restoreGraphicsState()
        return bitmap
    }

    func testOutlineClearsPixelsInsteadOfPaintingAContrastingColorAtBothScales() throws {
        for scale in [1, 2] {
            let base = baseImage()
            let numbers = StatusItemSpaceNumbers(internalDisplay: 8)
            let style = StatusItemSpaceBadgeStyle()
            let layout = try XCTUnwrap(StatusItemSpaceBadge.layout(base: base, numbers: numbers, style: style))
            let pixels = bitmap(StatusItemSpaceBadge.image(base: base, numbers: numbers, style: style), scale: scale)
            var clearedPixels = 0
            for y in 0..<pixels.pixelsHigh {
                for x in 0..<pixels.pixelsWide {
                    let pointX = (CGFloat(x) + 0.5) / CGFloat(scale)
                    let color = pixels.colorAt(x: x, y: y)!
                    if pointX > layout.graphicFrame.minX + 1, pointX < layout.graphicFrame.maxX - 1,
                       color.alphaComponent < 0.1 {
                        clearedPixels += 1
                        XCTAssertGreaterThan(pointX, layout.graphicFrame.midX)
                    }
                    if color.alphaComponent > 0.1 {
                        XCTAssertLessThan(color.redComponent, 0.01)
                        XCTAssertLessThan(color.greenComponent, 0.01)
                        XCTAssertLessThan(color.blueComponent, 0.01)
                    }
                }
            }
            XCTAssertGreaterThan(clearedPixels, 0, "The outline must clear the opaque graphic underneath")
        }
    }

    func testBothCornersRetainTheirDigitsAndTransparentOutlinesAtBothScales() throws {
        let style = StatusItemSpaceBadgeStyle(borderWidth: 1.5)
        for scale in [1, 2] {
            let base = baseImage()
            let numbers = StatusItemSpaceNumbers(internalDisplay: 2, externalDisplay: 8)
            let layout = try XCTUnwrap(StatusItemSpaceBadge.layout(base: base, numbers: numbers, style: style))
            let empty = NSImage(size: base.size)
            let digits = bitmap(StatusItemSpaceBadge.image(base: empty, numbers: numbers, style: style), scale: scale)
            let outlined = bitmap(StatusItemSpaceBadge.image(base: base, numbers: numbers, style: style), scale: scale)
            for number in layout.numbers {
                var visible = 0, cleared = 0
                for y in 0..<digits.pixelsHigh {
                    for x in 0..<digits.pixelsWide {
                        let point = CGPoint(x: (CGFloat(x) + 0.5) / CGFloat(scale),
                                            y: base.size.height - (CGFloat(y) + 0.5) / CGFloat(scale))
                        if number.frame.contains(point), digits.colorAt(x: x, y: y)!.alphaComponent > 0.9 { visible += 1 }
                        if layout.graphicFrame.contains(point), number.frame.insetBy(dx: -style.borderWidth, dy: -style.borderWidth).contains(point),
                           outlined.colorAt(x: x, y: y)!.alphaComponent < 0.1 { cleared += 1 }
                    }
                }
                XCTAssertGreaterThan(visible, 0)
                XCTAssertGreaterThan(cleared, 0)
            }
        }
    }

    func testTwoMultiDigitNumbersRemainVisibleWithCustomizedInsets() throws {
        let base = NSImage(size: NSSize(width: 22, height: 22))
        let numbers = StatusItemSpaceNumbers(internalDisplay: 12, externalDisplay: 34)
        for style in [StatusItemSpaceBadgeStyle(),
                      StatusItemSpaceBadgeStyle(fontSize: 14, borderWidth: 1.5,
                                               rightInset: 100, leftInset: -100, bottomInset: -100)] {
            let layout = try XCTUnwrap(StatusItemSpaceBadge.layout(base: base, numbers: numbers, style: style))
            let image = StatusItemSpaceBadge.image(base: base, numbers: numbers, style: style)
            XCTAssertEqual(image.size.height, base.size.height)
            let pixels = bitmap(image, scale: 2)
            for number in layout.numbers {
                XCTAssertGreaterThanOrEqual(number.frame.minX - style.borderWidth, 0)
                XCTAssertLessThanOrEqual(number.frame.maxX + style.borderWidth, image.size.width)
                XCTAssertTrue((0..<pixels.pixelsHigh).contains { y in
                    (0..<pixels.pixelsWide).contains { x in
                        let point = CGPoint(x: (CGFloat(x) + 0.5) / 2, y: base.size.height - (CGFloat(y) + 0.5) / 2)
                        return number.frame.contains(point) && pixels.colorAt(x: x, y: y)!.alphaComponent > 0.1
                    }
                })
            }
        }
    }

    func testWideNumbersAndExtremeStylesFitADynamicCanvas() {
        let base = NSImage(size: NSSize(width: 22, height: 22))
        for number in [1, 12, 123, Int.max] {
            for style in [StatusItemSpaceBadgeStyle(),
                          StatusItemSpaceBadgeStyle(fontSize: 14, borderWidth: 3, rightInset: 100, bottomInset: -100),
                          StatusItemSpaceBadgeStyle(fontSize: .nan, borderWidth: .infinity)] {
                let image = StatusItemSpaceBadge.image(base: base, numbers: .init(internalDisplay: number), style: style)
                XCTAssertEqual(image.size.height, base.size.height)
                XCTAssertLessThan(image.size.width, 200)
                XCTAssertTrue(image.isTemplate)
                let pixels = bitmap(image, scale: 2)
                XCTAssertTrue((0..<pixels.pixelsHigh).contains { y in
                    (0..<pixels.pixelsWide).contains { pixels.colorAt(x: $0, y: y)!.alphaComponent > 0.1 }
                }, "The digits should remain visible after fitting and clamping")
            }
        }
        let plain = StatusItemSpaceBadge.image(base: base, numbers: .init(), style: .init())
        let invalid = StatusItemSpaceBadge.image(base: base, numbers: .init(internalDisplay: 0, externalDisplay: -1), style: .init())
        XCTAssertEqual(plain.size.width, StatusItemIconLayout.minimumWidth)
        XCTAssertEqual(invalid.size, plain.size)
        XCTAssertEqual(bitmap(invalid, scale: 2).tiffRepresentation, bitmap(plain, scale: 2).tiffRepresentation)
    }

    func testSpaceNumbersOverlayTheLabelWithTransparentOutlines() throws {
        for scale in [1, 2] {
            let base = baseImage()
            let style = StatusItemSpaceBadgeStyle()
            let numbers = StatusItemSpaceNumbers(internalDisplay: 2, externalDisplay: 8)
            let labelOnly = StatusItemSpaceBadge.image(base: base, numbers: .init(), style: style, label: "Web")
            let labelLayout = try XCTUnwrap(StatusItemSpaceBadge.layout(base: base, numbers: .init(), style: style, label: "Web"))
            let layout = try XCTUnwrap(StatusItemSpaceBadge.layout(base: base, numbers: numbers, style: style, label: "Web"))
            let withNumbers = StatusItemSpaceBadge.image(base: base, numbers: numbers, style: style, label: "Web")
            XCTAssertTrue(withNumbers.isTemplate)
            XCTAssertEqual(withNumbers.size.height, base.size.height)
            let alignedLabel = NSImage(size: layout.size, flipped: false) { _ in
                let origin = CGPoint(x: layout.graphicFrame.minX - labelLayout.graphicFrame.minX,
                                     y: layout.graphicFrame.minY - labelLayout.graphicFrame.minY)
                labelOnly.draw(in: CGRect(origin: origin, size: labelOnly.size))
                return true
            }
            let labelPixels = bitmap(alignedLabel, scale: scale)
            let pixels = bitmap(withNumbers, scale: scale)
            var clearedLabelPixels = 0
            for y in 0..<pixels.pixelsHigh {
                for x in 0..<pixels.pixelsWide {
                    if labelPixels.colorAt(x: x, y: y)!.alphaComponent > 0.5,
                       pixels.colorAt(x: x, y: y)!.alphaComponent < 0.1 { clearedLabelPixels += 1 }
                }
            }
            for number in layout.numbers {
                XCTAssertFalse(number.frame.intersection(layout.graphicFrame).isEmpty)
            }
            XCTAssertGreaterThan(clearedLabelPixels, 0, "The outlines should clear the label behind the numbers")
        }
    }

    func testRenderedIconsKeepVerticalPaddingWithLabelsAndCustomizedBadges() throws {
        let base = try XCTUnwrap(NSImage(named: "StatusTemplate"))
        for scale in [1, 2] {
            for label in [nil, "Web", "eee", "gjp", "Éee", "研究室", "👩🏽‍💻We"] as [String?] {
                for style in [StatusItemSpaceBadgeStyle(),
                              StatusItemSpaceBadgeStyle(fontSize: 14, borderWidth: 3, bottomInset: -100),
                              StatusItemSpaceBadgeStyle(fontSize: 14, borderWidth: 3, bottomInset: 100)] {
                    let pixels = bitmap(StatusItemSpaceBadge.image(base: base,
                        numbers: .init(internalDisplay: 2, externalDisplay: 8), style: style, label: label), scale: scale)
                    let top = Int(StatusItemIconLayout.topMargin) * scale
                    let bottom = Int(StatusItemIconLayout.bottomMargin) * scale
                    for y in Array(0..<top) + Array((pixels.pixelsHigh - bottom)..<pixels.pixelsHigh) {
                        for x in 0..<pixels.pixelsWide {
                            XCTAssertEqual(pixels.colorAt(x: x, y: y)!.alphaComponent, 0,
                                           "The top and bottom padding must stay transparent")
                        }
                    }
                }
            }
        }
    }

    func testZeroInsetsHaveNoOverlapAndWidthTracksOutwardPlacement() throws {
        let base = NSImage(size: NSSize(width: 22, height: 22))
        let numbers = StatusItemSpaceNumbers(internalDisplay: 2, externalDisplay: 8)
        let zero = try XCTUnwrap(StatusItemSpaceBadge.layout(base: base, numbers: numbers,
            style: .init(rightInset: 0, leftInset: 0), label: "Hbb"))
        for number in zero.numbers {
            if number.isInternal {
                XCTAssertEqual(number.frame.minX - zero.border, zero.graphicFrame.maxX, accuracy: 0.001)
            } else {
                XCTAssertEqual(number.frame.maxX + zero.border, zero.graphicFrame.minX, accuracy: 0.001)
            }
        }
        let half = try XCTUnwrap(StatusItemSpaceBadge.layout(base: base, numbers: numbers, style: .init(), label: "Hbb"))
        let gap = try XCTUnwrap(StatusItemSpaceBadge.layout(base: base, numbers: numbers,
            style: .init(rightInset: -5, leftInset: -5), label: "Hbb"))
        XCTAssertLessThanOrEqual(half.size.width, zero.size.width)
        XCTAssertGreaterThanOrEqual(gap.size.width, zero.size.width)
        // Once outside the minimum width, five more points of gap on each side add ten points.
        let outward = try XCTUnwrap(StatusItemSpaceBadge.layout(base: base, numbers: numbers,
            style: .init(rightInset: -20, leftInset: -20), label: "Hbb"))
        let further = try XCTUnwrap(StatusItemSpaceBadge.layout(base: base, numbers: numbers,
            style: .init(rightInset: -25, leftInset: -25), label: "Hbb"))
        XCTAssertEqual(further.size.width - outward.size.width, 10, accuracy: 0.001)
        for number in half.numbers {
            let overlap = number.frame.intersection(half.graphicFrame).width / number.frame.width
            XCTAssertGreaterThan(overlap, 0.35)
            XCTAssertLessThan(overlap, 0.65)
        }
    }

    func testDefaultBadgesUseTheExtraSpaceAtTheBottom() throws {
        let base = NSImage(size: NSSize(width: 22, height: 22))
        let layout = try XCTUnwrap(StatusItemSpaceBadge.layout(base: base,
            numbers: .init(internalDisplay: 2, externalDisplay: 8), style: .init(), label: "Web"))
        for number in layout.numbers {
            XCTAssertLessThanOrEqual(number.frame.minY, 2)
            XCTAssertGreaterThanOrEqual(number.frame.minY - layout.border, 0)
        }
    }

    func testMinimumWidthStabilizesLabelsAndFallbackWhileAllowingWiderNumbers() throws {
        for alignment in [StatusItemSpaceLabelAlignment.ink, .letterShapes] {
            for text in [nil, "", "I", "Cal", "Foo"] as [String?] {
                for numbers in [StatusItemSpaceNumbers(), .init(internalDisplay: 5),
                                .init(internalDisplay: 5, externalDisplay: 8)] {
                    let layout = try XCTUnwrap(StatusItemSpaceBadge.layout(base: baseImage(), numbers: numbers,
                        style: .init(), label: text, labelAlignment: alignment))
                    XCTAssertEqual(layout.size.width, StatusItemIconLayout.minimumWidth, text ?? "Rectangle fallback")
                    if (layout.label != nil && alignment == .ink) || numbers == StatusItemSpaceNumbers() {
                        XCTAssertEqual(layout.graphicFrame.midX, layout.size.width / 2, accuracy: 0.001)
                    }
                }
            }
            let wide = try XCTUnwrap(StatusItemSpaceBadge.layout(base: baseImage(),
                numbers: .init(internalDisplay: Int.max, externalDisplay: Int.max),
                style: .init(), label: "mmm", labelAlignment: alignment))
            XCTAssertGreaterThan(wide.size.width, StatusItemIconLayout.minimumWidth)
            for number in wide.numbers {
                XCTAssertGreaterThanOrEqual(number.frame.minX - wide.border, StatusItemIconLayout.horizontalMargin - 0.001)
                XCTAssertLessThanOrEqual(number.frame.maxX + wide.border, wide.size.width - StatusItemIconLayout.horizontalMargin + 0.001)
            }
        }
    }

    func testOpticalCenteringMovesWebLeftAndReducesItsVisualImbalance() throws {
        let base = NSImage(size: NSSize(width: 22, height: 22))
        let layout = try XCTUnwrap(StatusItemSpaceBadge.layout(base: base, numbers: .init(), style: .init(), label: "Web"))
        let label = try XCTUnwrap(layout.label)
        let frame = try XCTUnwrap(layout.labelFrame)
        XCTAssertLessThan(label.horizontalOffset, -0.1)
        XCTAssertLessThan(frame.midX, layout.size.width / 2)

        // Evaluate visible ink in the lowercase body band, rather than the rectangle's midpoint.
        let scale: CGFloat = 4
        let pixels = bitmap(StatusItemSpaceBadge.image(base: base, numbers: .init(), style: .init(), label: "Web"), scale: Int(scale))
        let xHeight = NSFont.systemFont(ofSize: StatusItemSpaceLabelStyle.fontSize, weight: .bold).xHeight
        var weight: CGFloat = 0, moment: CGFloat = 0
        for y in 0..<pixels.pixelsHigh {
            let fontY = (layout.size.height - (CGFloat(y) + 0.5) / scale - frame.minY) / label.scale + label.bounds.minY
            let bodyWeight: CGFloat = fontY >= 0 && fontY <= xHeight ? 1 : StatusItemSpaceLabelStyle.ascenderDescenderWeight
            for x in 0..<pixels.pixelsWide {
                let alpha = pixels.colorAt(x: x, y: y)!.alphaComponent * bodyWeight
                weight += alpha
                moment += (CGFloat(x) + 0.5) / scale * alpha
            }
        }
        XCTAssertGreaterThan(weight, 0)
        let center = moment / weight
        let correctedError = abs(center - layout.size.width / 2)
        let uncorrectedError = abs(center - label.horizontalOffset - layout.size.width / 2)
        XCTAssertLessThan(correctedError, uncorrectedError)
    }

    func testUnequalBadgesDoNotPullTheLabelOffCenter() throws {
        let base = NSImage(size: NSSize(width: 22, height: 22))
        for inset: CGFloat in [0, 4] {
            let style = StatusItemSpaceBadgeStyle(rightInset: inset, leftInset: inset)
            for numbers in [StatusItemSpaceNumbers(internalDisplay: 1, externalDisplay: 88),
                            .init(internalDisplay: 88, externalDisplay: 1),
                            .init(internalDisplay: 7), .init(externalDisplay: 7)] {
                let layout = try XCTUnwrap(StatusItemSpaceBadge.layout(base: base, numbers: numbers, style: style, label: "Web"))
                XCTAssertEqual(layout.graphicFrame.midX, layout.size.width / 2, accuracy: 0.001)
                for number in layout.numbers {
                    XCTAssertGreaterThanOrEqual(number.frame.minX - layout.border, 0)
                    XCTAssertLessThanOrEqual(number.frame.maxX + layout.border, layout.size.width)
                }
            }
        }
    }

    func testOpticalCorrectionIsBoundedAndPreservesZeroInsetSeparation() throws {
        let base = NSImage(size: NSSize(width: 22, height: 22))
        let neutral = try XCTUnwrap(StatusItemSpaceBadge.layout(base: base, numbers: .init(), style: .init(), label: "WWW"))
        XCTAssertEqual(try XCTUnwrap(neutral.label).horizontalOffset, 0, accuracy: 0.01)
        for text in ["Web", "Cal", "Foo", "iii", "研究室", "👩🏽‍💻ab", "I"] {
            let layout = try XCTUnwrap(StatusItemSpaceBadge.layout(base: base,
                numbers: .init(internalDisplay: 2, externalDisplay: 8),
                style: .init(rightInset: 0, leftInset: 0), label: text))
            let label = try XCTUnwrap(layout.label)
            let frame = try XCTUnwrap(layout.labelFrame)
            XCTAssertLessThanOrEqual(abs(label.horizontalOffset), StatusItemSpaceLabelStyle.maximumOpticalOffset)
            XCTAssertLessThanOrEqual(abs(label.horizontalOffset), frame.width * 0.05 + 0.001)
            XCTAssertGreaterThanOrEqual(frame.minX, layout.graphicFrame.minX - 0.001)
            XCTAssertLessThanOrEqual(frame.maxX, layout.graphicFrame.maxX + 0.001)
            for number in layout.numbers {
                XCTAssertFalse(number.frame.insetBy(dx: -layout.border, dy: 0).intersects(frame))
            }
        }
    }

    func testLabelRenderingTruncatesAndMissingLabelsPreserveTheIconLayout() {
        let base = baseImage()
        let numbers = StatusItemSpaceNumbers(internalDisplay: 2, externalDisplay: 8)
        let style = StatusItemSpaceBadgeStyle()
        let short = StatusItemSpaceBadge.image(base: base, numbers: numbers, style: style, label: "Wor")
        let long = StatusItemSpaceBadge.image(base: base, numbers: numbers, style: style, label: "Workplace")
        XCTAssertEqual(short.size, long.size)
        XCTAssertEqual(bitmap(short, scale: 2).tiffRepresentation, bitmap(long, scale: 2).tiffRepresentation)
        let originalImage = StatusItemSpaceBadge.image(base: base, numbers: numbers, style: style)
        let original = bitmap(originalImage, scale: 2)
        for label in ["", "   "] {
            let fallback = StatusItemSpaceBadge.image(base: base, numbers: numbers, style: style, label: label)
            XCTAssertEqual(fallback.size, originalImage.size)
            XCTAssertEqual(original.tiffRepresentation, bitmap(fallback, scale: 2).tiffRepresentation)
        }
    }

    func testLabelsShareTheBaselineAndVerticalScaleRegardlessOfTextOrBadges() throws {
        var referenceBaseline: CGFloat?, referenceScale: CGFloat?
        for alignment in [StatusItemSpaceLabelAlignment.ink, .letterShapes] {
            for text in ["eee", "Wee", "gee", "Éee", "WWW", "研究室", "👩🏽‍💻We"] {
                for numbers in [StatusItemSpaceNumbers(), .init(internalDisplay: 5, externalDisplay: 8),
                                .init(internalDisplay: 5), .init(externalDisplay: 8)] {
                    let layout = try XCTUnwrap(StatusItemSpaceBadge.layout(base: baseImage(), numbers: numbers,
                        style: .init(), label: text, labelAlignment: alignment))
                    let label = try XCTUnwrap(layout.label), frame = try XCTUnwrap(layout.labelFrame)
                    let baseline = frame.minY - label.bounds.minY * label.scale
                    if referenceBaseline == nil { referenceBaseline = baseline; referenceScale = label.scale }
                    XCTAssertEqual(baseline, try XCTUnwrap(referenceBaseline), accuracy: 0.001, text)
                    XCTAssertEqual(label.scale, try XCTUnwrap(referenceScale), accuracy: 0.001, text)
                    XCTAssertLessThanOrEqual(label.horizontalScale, label.scale)
                    XCTAssertGreaterThanOrEqual(frame.minY, layout.contentRect.minY - 0.001)
                    XCTAssertLessThanOrEqual(frame.maxY, layout.contentRect.maxY + 0.001)
                    if text == "WWW" || text == "👩🏽‍💻We" {
                        XCTAssertLessThan(label.horizontalScale, label.scale, "Wide labels should fit without shrinking letter height")
                    }
                }
            }
        }
    }

    func testRenderedEStaysAtTheSameHeightWithAscendersDescendersAndWidthFitting() throws {
        for scale in [1, 2] {
            var referenceRows: Set<Int>?
            for text in ["eee", "Wee", "Vee", "gee", "Éee", "👩🏽‍💻We"] {
                let layout = try XCTUnwrap(StatusItemSpaceBadge.layout(base: baseImage(), numbers: .init(), style: .init(), label: text))
                let label = try XCTUnwrap(layout.label), frame = try XCTUnwrap(layout.labelFrame)
                let start = CTLineGetOffsetForStringIndex(label.line, text.utf16.count - 1, nil)
                let end = CTLineGetOffsetForStringIndex(label.line, text.utf16.count, nil)
                let minX = frame.minX + (start - label.bounds.minX) * label.horizontalScale
                let maxX = frame.minX + (end - label.bounds.minX) * label.horizontalScale
                let pixels = bitmap(StatusItemSpaceBadge.image(base: baseImage(), numbers: .init(), style: .init(), label: text), scale: scale)
                var rows: Set<Int> = []
                for y in 0..<pixels.pixelsHigh {
                    var coverage: CGFloat = 0
                    for x in 0..<pixels.pixelsWide {
                        let pointX = (CGFloat(x) + 0.5) / CGFloat(scale)
                        if pointX >= minX, pointX < maxX { coverage += pixels.colorAt(x: x, y: y)!.alphaComponent }
                    }
                    // Ignore weak antialias fringes and the preceding glyph's small overhang.
                    if coverage / (CGFloat(scale) * label.horizontalScale) > 0.5 { rows.insert(y) }
                }
                XCTAssertFalse(rows.isEmpty)
                if referenceRows == nil { referenceRows = rows }
                XCTAssertEqual(rows, referenceRows, "The final e must retain its rendered vertical position: \(text) at \(scale)x")
            }
        }
    }

    func testInkAlignmentAddsStrongerTucksOnlyAtOpenCornersAndKeepsItsInkCorrection() throws {
        let numbers = StatusItemSpaceNumbers(internalDisplay: 5, externalDisplay: 8)
        func insets(_ text: String) throws -> (left: CGFloat, right: CGFloat) {
            let layout = try XCTUnwrap(StatusItemSpaceBadge.layout(base: baseImage(), numbers: numbers, style: .init(), label: text))
            let left = try XCTUnwrap(layout.numbers.first { !$0.isInternal }).frame
            let right = try XCTUnwrap(layout.numbers.first { $0.isInternal }).frame
            return (left.maxX + layout.border - layout.graphicFrame.minX,
                    layout.graphicFrame.maxX + layout.border - right.minX)
        }
        let flat = try insets("HeH")
        XCTAssertEqual(flat.left, 4, accuracy: 0.001)
        XCTAssertEqual(flat.right, 4, accuracy: 0.001)
        for letter in "WVYT7vwy" {
            let tuck = try insets("\(letter)ee")
            XCTAssertGreaterThan(tuck.left, flat.left + 1)
            XCTAssertEqual(tuck.right, flat.right, accuracy: 0.001)
        }
        for letter in "WVYTFP7rfvwy" {
            let tuck = try insets("ee\(letter)")
            XCTAssertGreaterThan(tuck.right, flat.right + 1)
            XCTAssertEqual(tuck.left, flat.left, accuracy: 0.001)
        }
        let web = try XCTUnwrap(StatusItemSpaceBadge.layout(base: baseImage(), numbers: numbers, style: .init(), label: "Web"))
        XCTAssertLessThan(try XCTUnwrap(web.label).horizontalOffset, -0.1)
        XCTAssertEqual(web.graphicFrame.midX, web.size.width / 2, accuracy: 0.001)
    }

    func testInkOpenCornersStillRespectZeroAndNegativeInsetSeparation() throws {
        for text in ["WeW", "VeV", "YeY", "TeT", "I", "yey"] {
            for inset: CGFloat in [0, -5] {
                let layout = try XCTUnwrap(StatusItemSpaceBadge.layout(base: baseImage(),
                    numbers: .init(internalDisplay: 5, externalDisplay: 8),
                    style: .init(rightInset: inset, leftInset: inset), label: text))
                let frame = try XCTUnwrap(layout.labelFrame)
                for number in layout.numbers {
                    let gap = number.isInternal ? number.frame.minX - layout.border - layout.graphicFrame.maxX
                                                : layout.graphicFrame.minX - number.frame.maxX - layout.border
                    XCTAssertEqual(gap, -inset, accuracy: 0.001)
                    XCTAssertFalse(number.frame.insetBy(dx: -layout.border, dy: 0).intersects(frame))
                }
            }
        }
    }

    func testInkOpenCornerTucksKeepNarrowLabelsAndWideNumbersInsideTheCanvas() throws {
        for text in ["W", "V", "Y", "T", "WWW", "WeW", "I"] {
            for numbers in [StatusItemSpaceNumbers(internalDisplay: 5, externalDisplay: 8),
                            .init(internalDisplay: Int.max, externalDisplay: Int.max), .init(internalDisplay: 88)] {
                for style in [StatusItemSpaceBadgeStyle(),
                              .init(fontSize: 14, borderWidth: 3, rightInset: 64, leftInset: 64),
                              .init(fontSize: 6, borderWidth: 0, rightInset: -64, leftInset: -64)] {
                    let layout = try XCTUnwrap(StatusItemSpaceBadge.layout(base: baseImage(), numbers: numbers, style: style, label: text))
                    for number in layout.numbers {
                        XCTAssertGreaterThanOrEqual(number.frame.minX - layout.border, -0.001)
                        XCTAssertLessThanOrEqual(number.frame.maxX + layout.border, layout.size.width + 0.001)
                    }
                    if let left = layout.numbers.first(where: { !$0.isInternal }),
                       let right = layout.numbers.first(where: { $0.isInternal }) {
                        XCTAssertLessThanOrEqual(left.frame.maxX + layout.border, right.frame.minX - layout.border + 0.001)
                    }
                }
            }
        }
    }

    func testLetterShapeTucksRespondToEachVisibleEndIndependently() throws {
        let base = baseImage()
        let numbers = StatusItemSpaceNumbers(internalDisplay: 5, externalDisplay: 8)
        func overlaps(_ text: String) throws -> (left: CGFloat, right: CGFloat) {
            let layout = try XCTUnwrap(StatusItemSpaceBadge.layout(base: base, numbers: numbers,
                style: .init(), label: text, labelAlignment: .letterShapes))
            let frame = try XCTUnwrap(layout.labelFrame)
            let left = try XCTUnwrap(layout.numbers.first { !$0.isInternal }).frame
            let right = try XCTUnwrap(layout.numbers.first { $0.isInternal }).frame
            return ((left.maxX - frame.minX) / left.width, (frame.maxX - right.minX) / right.width)
        }
        let leftDiagonal = try overlaps("Wbb"), leftRound = try overlaps("Obb"), leftFlat = try overlaps("Hbb")
        XCTAssertGreaterThan(leftDiagonal.left, leftRound.left)
        XCTAssertGreaterThan(leftRound.left, leftFlat.left)
        XCTAssertEqual(leftDiagonal.right, leftRound.right, accuracy: 0.001)
        XCTAssertEqual(leftRound.right, leftFlat.right, accuracy: 0.001)
        let rightDiagonal = try overlaps("abW"), rightRound = try overlaps("abO"), rightFlat = try overlaps("abH")
        XCTAssertGreaterThan(rightDiagonal.right, rightRound.right)
        XCTAssertGreaterThan(rightRound.right, rightFlat.right)
        XCTAssertEqual(rightDiagonal.left, rightRound.left, accuracy: 0.001)
        XCTAssertEqual(rightRound.left, rightFlat.left, accuracy: 0.001)

        // The heuristic must inspect the displayed prefix's last letter, not the full label's end.
        let short = StatusItemSpaceBadge.image(base: base, numbers: numbers, style: .init(),
            label: "Web", labelAlignment: .letterShapes)
        let long = StatusItemSpaceBadge.image(base: base, numbers: numbers, style: .init(),
            label: "WebH", labelAlignment: .letterShapes)
        XCTAssertEqual(bitmap(short, scale: 2).tiffRepresentation, bitmap(long, scale: 2).tiffRepresentation)
    }

    func testLetterShapeCenteringBalancesTheWordAndAsymmetricOuterBounds() throws {
        for numbers in [StatusItemSpaceNumbers(internalDisplay: 1, externalDisplay: 88),
                        .init(internalDisplay: 88, externalDisplay: 1),
                        .init(internalDisplay: 7), .init(externalDisplay: 7)] {
            let layout = try XCTUnwrap(StatusItemSpaceBadge.layout(base: baseImage(), numbers: numbers,
                style: .init(), label: "Web", labelAlignment: .letterShapes))
            let frame = try XCTUnwrap(layout.labelFrame)
            let extent = layout.numbers.reduce(frame) { $0.union($1.frame.insetBy(dx: -layout.border, dy: 0)) }
            let left = frame.minX - extent.minX, right = extent.maxX - frame.maxX
            let wordOffset = frame.midX - layout.size.width / 2
            XCTAssertGreaterThan(wordOffset * (left - right), 0)
            XCTAssertLessThan(abs(wordOffset), abs(left - right) / 2)
            XCTAssertLessThan(abs(extent.midX - layout.size.width / 2), abs(left - right) / 2)
            // Weighted centering needs more room than simply summing the two protrusions.
            XCTAssertGreaterThanOrEqual(extent.minX, StatusItemIconLayout.horizontalMargin - 0.001)
            XCTAssertLessThanOrEqual(extent.maxX, layout.size.width - StatusItemIconLayout.horizontalMargin + 0.001)
            if layout.size.width > StatusItemIconLayout.minimumWidth {
                XCTAssertLessThan(min(extent.minX, layout.size.width - extent.maxX), StatusItemIconLayout.horizontalMargin + 0.5)
            }
        }
    }

    func testLetterShapeInsetsStillStartOutsideTheOutlineAndAllowAGap() throws {
        for inset: CGFloat in [0, -5] {
            let layout = try XCTUnwrap(StatusItemSpaceBadge.layout(base: baseImage(),
                numbers: .init(internalDisplay: 5, externalDisplay: 8),
                style: .init(rightInset: inset, leftInset: inset), label: "Web", labelAlignment: .letterShapes))
            let frame = try XCTUnwrap(layout.labelFrame)
            for number in layout.numbers {
                let gap = number.isInternal ? number.frame.minX - layout.border - frame.maxX
                                            : frame.minX - number.frame.maxX - layout.border
                XCTAssertEqual(gap, -inset, accuracy: 0.001)
            }
        }
    }

    func testLetterShapeLayoutSafelyFitsNarrowLabelsWideNumbersAndExtremeInsets() throws {
        for text in ["I", "W", "Web", "WWW", "研究室", "👩🏽‍💻ab", "iii"] {
            for numbers in [StatusItemSpaceNumbers(internalDisplay: 1, externalDisplay: 88),
                            .init(internalDisplay: Int.max, externalDisplay: Int.max),
                            .init(internalDisplay: 7), .init(externalDisplay: 7), .init()] {
                for style in [StatusItemSpaceBadgeStyle(),
                              .init(fontSize: 14, borderWidth: 3, rightInset: 64, leftInset: 64, bottomInset: 64),
                              .init(fontSize: 6, borderWidth: 0, rightInset: -64, leftInset: -64, bottomInset: -64)] {
                    let layout = try XCTUnwrap(StatusItemSpaceBadge.layout(base: baseImage(), numbers: numbers,
                        style: style, label: text, labelAlignment: .letterShapes))
                    let frame = try XCTUnwrap(layout.labelFrame)
                    XCTAssertLessThan(layout.size.width, 250)
                    XCTAssertGreaterThanOrEqual(frame.minX, 0)
                    XCTAssertLessThanOrEqual(frame.maxX, layout.size.width)
                    for number in layout.numbers {
                        XCTAssertGreaterThanOrEqual(number.frame.minX - layout.border, -0.001)
                        XCTAssertLessThanOrEqual(number.frame.maxX + layout.border, layout.size.width + 0.001)
                        XCTAssertGreaterThanOrEqual(number.frame.minY - layout.border, -0.001)
                        XCTAssertLessThanOrEqual(number.frame.maxY + layout.border, layout.contentRect.maxY + 0.001)
                    }
                    if let left = layout.numbers.first(where: { !$0.isInternal }),
                       let right = layout.numbers.first(where: { $0.isInternal }) {
                        XCTAssertLessThanOrEqual(left.frame.maxX + layout.border, right.frame.minX - layout.border + 0.001)
                    }
                }
            }
        }
    }

    func testLetterShapeRenderingKeepsBothDigitsMonochromeAndTopPaddingAtBothScales() throws {
        for scale in [1, 2] {
            for text in ["Web", "Job", "I", "研究室"] {
                let layout = try XCTUnwrap(StatusItemSpaceBadge.layout(base: baseImage(),
                    numbers: .init(internalDisplay: 5, externalDisplay: 8), style: .init(), label: text,
                    labelAlignment: .letterShapes))
                let image = StatusItemSpaceBadge.image(base: baseImage(), numbers: .init(internalDisplay: 5, externalDisplay: 8),
                    style: .init(), label: text, labelAlignment: .letterShapes)
                let pixels = bitmap(image, scale: scale)
                XCTAssertTrue(image.isTemplate)
                var visibleDigits: Set<Bool> = []
                for y in 0..<pixels.pixelsHigh { for x in 0..<pixels.pixelsWide {
                    let color = pixels.colorAt(x: x, y: y)!
                    if y < Int(StatusItemIconLayout.topMargin) * scale {
                        XCTAssertEqual(color.alphaComponent, 0)
                    }
                    if color.alphaComponent > 0.9 {
                        XCTAssertLessThan(color.redComponent, 0.01)
                        XCTAssertLessThan(color.greenComponent, 0.01)
                        XCTAssertLessThan(color.blueComponent, 0.01)
                        let point = CGPoint(x: (CGFloat(x) + 0.5) / CGFloat(scale),
                                            y: layout.size.height - (CGFloat(y) + 0.5) / CGFloat(scale))
                        for number in layout.numbers where number.path.contains(point) { visibleDigits.insert(number.isInternal) }
                    }
                }}
                XCTAssertEqual(visibleDigits, [false, true])
            }
        }
    }

    func testLetterShapesWithoutALabelStillUseTheCurrentRectangleIcon() {
        let base = baseImage()
        for label in [nil, "", "   "] as [String?] {
            let numbers = StatusItemSpaceNumbers(internalDisplay: 5, externalDisplay: 8)
            let current = StatusItemSpaceBadge.image(base: base, numbers: numbers, style: .init(), label: label)
            let experiment = StatusItemSpaceBadge.image(base: base, numbers: numbers, style: .init(), label: label,
                labelAlignment: .letterShapes)
            XCTAssertEqual(current.size, experiment.size)
            XCTAssertEqual(bitmap(current, scale: 2).tiffRepresentation, bitmap(experiment, scale: 2).tiffRepresentation)
        }
    }
}

class RectangleTests: XCTestCase {

    override func setUp() {
    }

    override func tearDown() {
    }
}

class WindowActionMenuTests: XCTestCase {

    func testFocusNextDisplayIsAvailableWithoutMovingAWindow() {
        let menu = makeMenu(showAdditional: false, showAllActions: false)
        let item = menu.items.first { $0.representedObject as? WindowAction == .focusNextDisplay }
        XCTAssertEqual(item?.title, "Focus Next Display")
        XCTAssertEqual(WindowAction.focusNextDisplay.name, "focusNextDisplay")
        XCTAssertFalse(WindowAction.focusNextDisplay.resizes)
        XCTAssertFalse(WindowAction.focusNextDisplay.isDragSnappable)
    }

    func testSpaceActionsAreAvailableAsTopLevelCommands() {
        let menu = makeMenu(showAdditional: false, showAllActions: false)
        let itemsByAction = Dictionary(uniqueKeysWithValues: menu.items.compactMap { item in
            (item.representedObject as? WindowAction).map { ($0, item) }
        })

        XCTAssertEqual(itemsByAction[.nextSpace]?.title, "Next Space")
        XCTAssertEqual(itemsByAction[.prevSpace]?.title, "Previous Space")
        XCTAssertEqual(itemsByAction[.switchNextSpace]?.title, "Switch to Next Space")
        XCTAssertEqual(itemsByAction[.switchPrevSpace]?.title, "Switch to Previous Space")
        XCTAssertFalse(itemsByAction[.nextSpace]?.isHidden ?? true)
        XCTAssertFalse(itemsByAction[.prevSpace]?.isHidden ?? true)
        XCTAssertFalse(itemsByAction[.switchNextSpace]?.isHidden ?? true)
        XCTAssertFalse(itemsByAction[.switchPrevSpace]?.isHidden ?? true)
    }

    func testRowsAndColumnsShareOptionalSubmenu() throws {
        for showAdditional in [false, true] {
            let menu = makeMenu(showAdditional: showAdditional, showAllActions: false)
            let tilingItems = menu.items.filter { item in
                item.submenu?.items.contains { $0.representedObject as? WindowAction == .tileRows } == true
            }
            XCTAssertEqual(tilingItems.count, 1)
            let tilingItem = try XCTUnwrap(tilingItems.first)
            XCTAssertEqual(tilingItem.submenu?.items.compactMap { $0.representedObject as? WindowAction },
                           [.tileRows, .tileColumns])
            XCTAssertEqual(tilingItem.isHidden, !showAdditional)
            let topLevelActions = menu.items.compactMap { $0.representedObject as? WindowAction }
            XCTAssertFalse(topLevelActions.contains(.tileRows))
            XCTAssertFalse(topLevelActions.contains(.tileColumns))
            XCTAssertTrue(topLevelActions.contains(.maximize))
        }
    }

    func testShowAllActionsKeepsRowsAndColumnsFlat() {
        let menu = makeMenu(showAdditional: false, showAllActions: true)
        let visibleActions = menu.items.filter { !$0.isHidden }.compactMap { $0.representedObject as? WindowAction }
        XCTAssertTrue(visibleActions.contains(.tileRows))
        XCTAssertTrue(visibleActions.contains(.tileColumns))
        XCTAssertFalse(menu.items.contains { $0.submenu != nil })
    }

    private func makeMenu(showAdditional: Bool, showAllActions: Bool) -> NSMenu {
        let menu = NSMenu()
        let delegate = AppDelegate()
        delegate.mainStatusMenu = menu
        delegate.addWindowActionMenuItems(showAdditional: showAdditional, showAllActions: showAllActions)
        return menu
    }
}

class DisplayFocusManagerTests: XCTestCase {

    private final class TestScreen: NSScreen {
        private let testFrame: CGRect

        init(frame: CGRect) {
            testFrame = frame
            super.init()
        }

        override var frame: NSRect { testFrame }
        override func isEqual(_ object: Any?) -> Bool { (object as? TestScreen) === self }
    }

    private final class TestWindow: AccessibilityElement {
        private let testFrame: CGRect
        var testID: CGWindowID = 42
        var testPID: pid_t = 99
        var modal = false

        init(frame: CGRect) {
            testFrame = frame
            super.init(AXUIElementCreateSystemWide())
        }

        override var frame: CGRect { testFrame }
        override var windowId: CGWindowID? { testID }
        override var pid: pid_t? { testPID }
        override var isWindow: Bool? { true }
        override var isModal: Bool? { modal }
    }

    private final class TestScreenDetection: ScreenDetection {
        private(set) var cursorDetections = 0

        override func detectScreensAtCursor() -> UsableScreens? {
            cursorDetections += 1
            return nil
        }
    }

    func testNextDisplayUsesActiveWindowIncludingWraparoundAndSpanningWindows() {
        let left = TestScreen(frame: CGRect(x: -900, y: 0, width: 900, height: 600))
        let middle = TestScreen(frame: CGRect(x: 0, y: 0, width: 900, height: 600))
        let right = TestScreen(frame: CGRect(x: 900, y: 0, width: 900, height: 600))
        let detection = TestScreenDetection(screens: { [right, left, middle] }, logicalFrame: { _ in nil })
        let savedCursorDetection = Defaults.useCursorScreenDetection.toCodable()
        defer { Defaults.useCursorScreenDetection.load(from: savedCursorDetection) }

        let cases: [(CGRect, NSScreen)] = [
            (left.frame.insetBy(dx: 100, dy: 100), middle),
            (middle.frame.insetBy(dx: 100, dy: 100), right),
            (right.frame.insetBy(dx: 100, dy: 100), left),
            (CGRect(x: 700, y: 100, width: 700, height: 300), left)
        ]
        for useCursor in [false, true] {
            Defaults.useCursorScreenDetection.enabled = useCursor
            for (frame, destination) in cases {
                let window = TestWindow(frame: frame.screenFlipped)
                var cursorPositions: [CGPoint] = []
                let manager = DisplayFocusManager(screenDetection: detection, frontWindowProvider: { window },
                                                  warpCursor: { cursorPositions.append($0); return .failure },
                                                  coordinator: SpaceOperationCoordinator(environmentIsSafe: { true }, workspaceNotificationCenter: NotificationCenter()),
                                                  mousePressed: { false })
                manager.focusNextDisplay()
                XCTAssertEqual(cursorPositions, [destination.frame.screenFlipped.centerPoint])
            }
        }
        XCTAssertEqual(detection.cursorDetections, 0)
    }

    func testNoActiveWindowDoesNotMoveCursorOrChooseItsDisplay() {
        let detection = TestScreenDetection()
        var cursorPositions: [CGPoint] = []
        let manager = DisplayFocusManager(screenDetection: detection, frontWindowProvider: { nil },
                                          warpCursor: { cursorPositions.append($0); return .failure },
                                                  coordinator: SpaceOperationCoordinator(environmentIsSafe: { true }, workspaceNotificationCenter: NotificationCenter()),
                                                  mousePressed: { false })
        manager.focusNextDisplay()
        XCTAssertTrue(cursorPositions.isEmpty)
        XCTAssertEqual(detection.cursorDetections, 0)
    }

    func testFocusRejectsDraggingMissionControlAndAnOwnedSpaceOperation() throws {
        for scenario in 0..<3 {
            let coordinator = SpaceOperationCoordinator(environmentIsSafe: { scenario != 0 }, workspaceNotificationCenter: NotificationCenter())
            let lease = scenario == 2 ? try XCTUnwrap(coordinator.begin()) : nil
            var warps = 0
            let manager = DisplayFocusManager(frontWindowProvider: { TestWindow(frame: CGRect(x: 100, y: 100, width: 200, height: 200)) },
                                              warpCursor: { _ in warps += 1; return .success }, coordinator: coordinator,
                                              mousePressed: { scenario == 1 })
            manager.focusNextDisplay()
            XCTAssertEqual(warps, 0)
            withExtendedLifetime(lease) {}
        }
    }

    func testFocusSkipsModalWindowsAndRevalidatesCandidateAfterAXLookup() {
        for vanished in [false, true] {
            let left = TestScreen(frame: CGRect(x: 0, y: 0, width: 600, height: 400))
            let right = TestScreen(frame: CGRect(x: 600, y: 0, width: 600, height: 400))
            let source = TestWindow(frame: left.frame.insetBy(dx: 50, dy: 50).screenFlipped)
            let modal = TestWindow(frame: right.frame.insetBy(dx: 50, dy: 50).screenFlipped)
            modal.testID = 1; modal.testPID = 10; modal.modal = true
            let candidate = TestWindow(frame: modal.frame)
            candidate.testID = 2; candidate.testPID = 20
            var windows = [WindowInfo(id: 1, level: 0, frame: modal.frame, pid: 10, processName: "Modal"),
                           WindowInfo(id: 2, level: 0, frame: candidate.frame, pid: 20, processName: "Ordinary")]
            var activated = [CGWindowID]()
            let manager = DisplayFocusManager(
                screenDetection: ScreenDetection(screens: { [left, right] }, logicalFrame: { _ in nil }), frontWindowProvider: { source },
                warpCursor: { _ in .success },
                coordinator: SpaceOperationCoordinator(environmentIsSafe: { true }, workspaceNotificationCenter: NotificationCenter()),
                mousePressed: { false }, windowListProvider: { windows }, windowProvider: { info in
                    if info.id == 1 { return modal }
                    if vanished { windows.removeAll() }
                    return candidate
                }, activateWindow: { activated.append($0.windowId!) })
            manager.focusNextDisplay()
            XCTAssertEqual(activated, vanished ? [] : [2])
        }
    }

    func testFocusDoesNotActivateAfterDestinationDisplayDisconnects() {
        let left = TestScreen(frame: CGRect(x: 0, y: 0, width: 600, height: 400))
        let right = TestScreen(frame: CGRect(x: 600, y: 0, width: 600, height: 400))
        var screens: [NSScreen] = [left, right]
        let source = TestWindow(frame: left.frame.insetBy(dx: 50, dy: 50).screenFlipped)
        let candidate = TestWindow(frame: right.frame.insetBy(dx: 50, dy: 50).screenFlipped)
        var activated = false
        let manager = DisplayFocusManager(screenDetection: ScreenDetection(screens: { screens }, logicalFrame: { _ in nil }),
            frontWindowProvider: { source }, warpCursor: { _ in screens = [left]; return .success },
            coordinator: SpaceOperationCoordinator(environmentIsSafe: { true }, workspaceNotificationCenter: NotificationCenter()),
            mousePressed: { false },
            windowListProvider: { [WindowInfo(id: 42, level: 0, frame: candidate.frame, pid: 99, processName: "App")] },
            windowProvider: { _ in candidate }, activateWindow: { _ in activated = true })
        manager.focusNextDisplay()
        XCTAssertFalse(activated)
    }

    func testSingleDisplayAndOffscreenFocusDoNotWarpCursor() {
        let saved = Defaults.traverseSingleScreen.toCodable()
        defer { Defaults.traverseSingleScreen.load(from: saved) }
        Defaults.traverseSingleScreen.enabled = true
        let screen = TestScreen(frame: CGRect(x: 0, y: 0, width: 600, height: 400))
        for frame in [screen.frame, CGRect(x: 5000, y: 5000, width: 100, height: 100), .zero] {
            var warps = 0
            let manager = DisplayFocusManager(screenDetection: ScreenDetection(screens: { [screen] }, logicalFrame: { _ in nil }),
                frontWindowProvider: { TestWindow(frame: frame.screenFlipped) }, warpCursor: { _ in warps += 1; return .success },
                coordinator: SpaceOperationCoordinator(environmentIsSafe: { true }, workspaceNotificationCenter: NotificationCenter()),
                mousePressed: { false })
            manager.focusNextDisplay()
            XCTAssertEqual(warps, 0)
        }
    }

    func testSelectsFrontmostOrdinaryWindowCenteredOnDestinationDisplay() throws {
        let screen = try XCTUnwrap(NSScreen.screens.first)
        let destination = screen.frame.screenFlipped
        let inside = CGRect(x: destination.midX - 40, y: destination.midY - 40, width: 80, height: 80)
        let outside = CGRect(x: destination.maxX + 10, y: destination.midY, width: 80, height: 80)
        let windows = [
            WindowInfo(id: 1, level: 20, frame: inside, pid: 1, processName: "Overlay"),
            WindowInfo(id: 2, level: 0, frame: outside, pid: 2, processName: "Other Display"),
            WindowInfo(id: 3, level: 0, frame: inside, pid: 3, processName: "Invisible", alpha: 0),
            WindowInfo(id: 6, level: 0, frame: inside, pid: ProcessInfo.processInfo.processIdentifier,
                       processName: "Rectangle"),
            WindowInfo(id: 4, level: 0, frame: inside, pid: 4, processName: "Front"),
            WindowInfo(id: 5, level: 0, frame: inside, pid: 5, processName: "Back")
        ]

        XCTAssertEqual(DisplayFocusManager.frontWindow(on: screen.frame, from: windows)?.id, 4)
        XCTAssertNil(DisplayFocusManager.frontWindow(on: screen.frame, from: Array(windows.prefix(3))))
    }
}

class GridLimitDefaultsTests: XCTestCase {
    // Separate limits round-trip without replacing explicitly saved values or
    // writing an absent default into the user's preferences.
    func testIndependentDefaultsAndConfigRoundTripPreserveExplicitValues() {
        let suiteName = "RectangleGridDefaults-\(UUID().uuidString)"
        let preferences = UserDefaults(suiteName: suiteName)!
        defer { preferences.removePersistentDomain(forName: suiteName) }
        let columns = PositiveIntDefault(key: "columns", defaultValue: 3, userDefaults: preferences)
        let rows = PositiveIntDefault(key: "rows", defaultValue: 3, userDefaults: preferences)
        XCTAssertEqual(columns.value, 3)
        XCTAssertEqual(rows.value, 3)
        XCTAssertNil(preferences.object(forKey: "columns"))
        columns.value = 1
        rows.load(from: CodableDefault(int: 2))
        XCTAssertEqual(columns.toCodable().int, 1)
        XCTAssertEqual(rows.toCodable().int, 2)
        XCTAssertEqual(PositiveIntDefault(key: "columns", defaultValue: 3, userDefaults: preferences).value, 1)
        XCTAssertEqual(PositiveIntDefault(key: "rows", defaultValue: 3, userDefaults: preferences).value, 2)
        columns.load(from: CodableDefault())
        XCTAssertEqual(columns.value, 1)
    }

    func testInvalidSavedLimitsNormalizeWithoutWritingOnRead() {
        let suiteName = "RectangleGridDefaults-\(UUID().uuidString)"
        let preferences = UserDefaults(suiteName: suiteName)!
        defer { preferences.removePersistentDomain(forName: suiteName) }
        preferences.set("invalid", forKey: "limit")
        let limit = PositiveIntDefault(key: "limit", defaultValue: 3, userDefaults: preferences)
        XCTAssertEqual(limit.value, 1)
        XCTAssertEqual(preferences.string(forKey: "limit"), "invalid")
        limit.load(from: CodableDefault(int: 0))
        XCTAssertEqual(limit.value, 1)
        XCTAssertEqual(preferences.integer(forKey: "limit"), 1)
    }
}

class SpaceOperationCoordinatorTests: XCTestCase {

    func testDisplayChangesCancelTheLeaseAndInvalidateVerifiedFastPath() throws {
        let workspace = NotificationCenter(), app = NotificationCenter()
        var now: TimeInterval = 1
        let coordinator = SpaceOperationCoordinator(environmentIsSafe: { true }, clock: { now },
            workspaceNotificationCenter: workspace, notificationCenter: app)
        var lease: SpaceOperationCoordinator.Operation? = try XCTUnwrap(coordinator.begin())
        coordinator.verifiedSwitch(try XCTUnwrap(lease), currentState: ["A": 10])
        app.post(name: NSApplication.didChangeScreenParametersNotification, object: nil)
        XCTAssertFalse(coordinator.canContinue)
        XCTAssertNil(coordinator.begin(continuing: lease))
        lease = nil
        XCTAssertNil(coordinator.beginSwitch(currentState: ["A": 10]))
        now += 0.16
        XCTAssertNotNil(coordinator.begin())
    }

    func testSleepAndInactiveSessionBlockCommandsUntilBothReturn() throws {
        var now: TimeInterval = 1
        let workspace = NotificationCenter()
        let coordinator = SpaceOperationCoordinator(environmentIsSafe: { true }, clock: { now }, workspaceNotificationCenter: workspace)
        workspace.post(name: NSWorkspace.willSleepNotification, object: nil)
        workspace.post(name: NSWorkspace.sessionDidResignActiveNotification, object: nil)
        now += 1
        XCTAssertNil(coordinator.begin())
        workspace.post(name: NSWorkspace.didWakeNotification, object: nil)
        now += 1
        XCTAssertNil(coordinator.begin())
        workspace.post(name: NSWorkspace.sessionDidBecomeActiveNotification, object: nil)
        XCTAssertNil(coordinator.begin())
        now += 0.16
        XCTAssertNotNil(coordinator.begin())
    }

    func testOnlyVerifiedSwitchesCanBypassNativeSettling() throws {
        var now: TimeInterval = 1
        let notifications = NotificationCenter()
        let coordinator = SpaceOperationCoordinator(environmentIsSafe: { true }, clock: { now },
                                                    workspaceNotificationCenter: notifications)
        var operation: SpaceOperationCoordinator.Operation? = try XCTUnwrap(coordinator.begin())
        notifications.post(name: NSWorkspace.activeSpaceDidChangeNotification, object: nil)
        coordinator.verifiedSwitch(try XCTUnwrap(operation), currentState: ["A": 57, "B": 90])
        operation = nil
        XCTAssertNil(coordinator.begin()) // Window moves keep the native quiet period.
        XCTAssertNil(coordinator.beginSwitch(currentState: ["A": 58, "B": 90]))
        var next: SpaceOperationCoordinator.Operation? = coordinator.beginSwitch(currentState: ["A": 57, "B": 90])
        XCTAssertNotNil(next)
        coordinator.verifiedSwitch(try XCTUnwrap(next), currentState: ["A": 57, "B": 90])
        next = nil
        coordinator.invalidateVerifiedSwitch()
        XCTAssertNil(coordinator.beginSwitch(currentState: ["A": 57, "B": 90]))
        now += 0.2
        XCTAssertNotNil(coordinator.beginSwitch(currentState: ["A": 57, "B": 90]))
    }
    func testOnlyTheOwningMoveCanContinueItsOperation() throws {
        let coordinator = SpaceOperationCoordinator(environmentIsSafe: { true }, workspaceNotificationCenter: NotificationCenter())
        var operation = try XCTUnwrap(coordinator.begin())
        XCTAssertNil(coordinator.begin())
        XCTAssertTrue(coordinator.begin(continuing: operation) === operation)
        let other = SpaceOperationCoordinator(environmentIsSafe: { true }, workspaceNotificationCenter: NotificationCenter())
        XCTAssertNil(other.begin(continuing: operation))
        // A child retains the same lease until both move and gesture finish.
        var child: SpaceOperationCoordinator.Operation? = operation
        operation = try XCTUnwrap(other.begin())
        XCTAssertNil(coordinator.begin())
        child = nil
        XCTAssertNotNil(coordinator.begin())
        withExtendedLifetime((operation, child)) {}
    }

    func testMissionControlBlocksNewAndInheritedOperations() throws {
        var safe = true
        let coordinator = SpaceOperationCoordinator(environmentIsSafe: { safe }, workspaceNotificationCenter: NotificationCenter())
        let operation = try XCTUnwrap(coordinator.begin())
        safe = false
        XCTAssertFalse(coordinator.canContinue)
        XCTAssertNil(coordinator.begin(continuing: operation))
        XCTAssertNil(coordinator.begin())
    }

    func testNativeSpaceChangesHaveASettlingPeriod() {
        var now: TimeInterval = 1
        let notifications = NotificationCenter()
        let coordinator = SpaceOperationCoordinator(environmentIsSafe: { true }, clock: { now }, workspaceNotificationCenter: notifications)
        notifications.post(name: NSWorkspace.activeSpaceDidChangeNotification, object: nil)
        XCTAssertNil(coordinator.begin())
        now += 0.2
        XCTAssertNotNil(coordinator.begin())
    }
}

class SpaceManagerTests: XCTestCase {
    private final class SpaceState {
        var current: UInt64 = 57
        var memberships: [UInt64]? = [57]
        var target: AdjacentManagedSpace? = AdjacentManagedSpace(sourceID: 57, destinationID: 10, displayIdentifier: "display")
        var automaticArrival = true
        private let center: NotificationCenter
        private var observer: NSObjectProtocol?
        init(_ center: NotificationCenter) {
            self.center = center
            observer = center.addObserver(forName: NSWorkspace.activeSpaceDidChangeNotification, object: nil, queue: .main) { [weak self] _ in
                guard let self, self.automaticArrival, let target = self.target else { return }
                self.current = target.destinationID
                self.memberships = [target.destinationID]
            }
        }
        deinit { if let observer { center.removeObserver(observer) } }
    }

    private final class TestElement: AccessibilityElement {
        var testWindowID: CGWindowID? = 42
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
        override var windowId: CGWindowID? { testWindowID }
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
            limit: Int = 100,
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
        windowDisplayIdentifier: @escaping (CGWindowID) -> String? = { _ in "display" },
        coordinator: SpaceOperationCoordinator = SpaceOperationCoordinator(environmentIsSafe: { true }, workspaceNotificationCenter: NotificationCenter()),
        raise: @escaping (AccessibilityElement) -> Void = { _ in },
        frontmost: @escaping (CGWindowID, String) -> Bool? = { _, _ in true },
        spaceState: SpaceState? = nil
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
        let spaceState = spaceState ?? SpaceState(notificationCenter)
        if let display = windowDisplayIdentifier(window?.windowId ?? 42), let target = spaceState.target {
            spaceState.target = AdjacentManagedSpace(sourceID: target.sourceID, destinationID: target.destinationID,
                                                     displayIdentifier: display)
        }
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
            workspaceNotificationCenter: notificationCenter,
            coordinator: coordinator, raiseWindow: raise, windowIsFrontmost: frontmost,
            targetSpaceProvider: { _, _ in spaceState.target },
            windowSpacesProvider: { _ in spaceState.memberships }, currentSpaceProvider: { _ in spaceState.current }
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

    func testFallbackIgnoresUnrelatedNotificationsUntilExactDesktopAndMembershipArrive() {
        let notifications = NotificationCenter(), state = SpaceState(NotificationCenter())
        state.automaticArrival = false
        let poster = EventPosterSpy(mouseLocation: .zero), scheduler = SchedulerSpy()
        var raises = 0
        let subject = manager(poster: poster, scheduler: scheduler,
            window: TestElement(titleBarFrame: CGRect(x: 100, y: 100, width: 500, height: 30)),
            notificationCenter: notifications, raise: { _ in raises += 1 }, spaceState: state)
        XCTAssertTrue(subject.execute(parameters: ExecutionParameters(.nextSpace)))
        scheduler.runUntil { poster.phases == [.began, .changed, .ended] }
        notifications.post(name: NSWorkspace.activeSpaceDidChangeNotification, object: nil)
        for _ in 0..<3 { scheduler.runNext() }
        XCTAssertEqual(raises, 0)
        XCTAssertTrue(poster.mouseUpPoints.isEmpty)
        state.current = 10 // Switching without the window is still incomplete.
        for _ in 0..<3 { scheduler.runNext() }
        XCTAssertEqual(raises, 0)
        state.memberships = [10]
        scheduler.runUntil { !subject.isSpaceActionInProgress } // No notification is necessary.
        XCTAssertEqual(raises, 1)
    }

    func testFallbackNeverRaisesAfterAnUnexpectedSpaceChange() {
        let notifications = NotificationCenter(), state = SpaceState(NotificationCenter())
        state.automaticArrival = false
        let poster = EventPosterSpy(mouseLocation: .zero), scheduler = SchedulerSpy()
        var raises = 0
        let subject = manager(poster: poster, scheduler: scheduler,
            window: TestElement(titleBarFrame: CGRect(x: 100, y: 100, width: 500, height: 30)),
            notificationCenter: notifications, raise: { _ in raises += 1 }, spaceState: state)
        XCTAssertTrue(subject.execute(parameters: ExecutionParameters(.nextSpace)))
        scheduler.runUntil { poster.phases == [.began, .changed, .ended] }
        state.current = 999
        notifications.post(name: NSWorkspace.activeSpaceDidChangeNotification, object: nil)
        XCTAssertFalse(subject.isSpaceActionInProgress)
        XCTAssertEqual(raises, 0)
        XCTAssertEqual(poster.mouseUpPoints.count, 1)
    }

    func testFallbackRejectsUnknownTargetAndOffscreenSnapshotBeforeMouseDown() {
        for missingTarget in [true, false] {
            let state = SpaceState(NotificationCenter())
            if missingTarget { state.target = nil }
            let poster = EventPosterSpy(mouseLocation: .zero), scheduler = SchedulerSpy()
            let subject = manager(poster: poster, scheduler: scheduler,
                window: TestElement(titleBarFrame: CGRect(x: 100, y: 100, width: 500, height: 30)),
                snapshotProvider: { element in SpaceWindowSnapshot(windowId: 42, pid: element.pid, frame: element.frame,
                                                                  level: 0, isOnScreen: missingTarget) }, spaceState: state)
            XCTAssertTrue(subject.execute(parameters: ExecutionParameters(.nextSpace)))
            XCTAssertTrue(poster.prepared.isEmpty)
        }
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
        scheduler.runUntil { !manager.isSpaceActionInProgress }

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

    func testDragReleasesBeforeRaisingAndRetriesUntilDestinationOrderIsStable() {
        let window = TestElement(titleBarFrame: CGRect(x: 100, y: 100, width: 500, height: 30))
        let poster = EventPosterSpy(mouseLocation: .zero)
        let scheduler = SchedulerSpy()
        let notifications = NotificationCenter()
        var frontmost = false
        var raises = 0
        let manager = manager(poster: poster, scheduler: scheduler, window: window,
                              notificationCenter: notifications, raise: { _ in
            XCTAssertEqual(poster.mouseUpPoints.count, 1)
            raises += 1
            if raises == 2 { frontmost = true }
        }, frontmost: { _, _ in frontmost })
        XCTAssertTrue(manager.execute(parameters: ExecutionParameters(.nextSpace)))
        scheduler.runUntil { poster.phases == [.began, .changed, .ended] }
        notifications.post(name: NSWorkspace.activeSpaceDidChangeNotification, object: nil)
        scheduler.runUntil { !manager.isSpaceActionInProgress }
        XCTAssertEqual(raises, 2)
        XCTAssertEqual(poster.mouseUpPoints.count, 1)
        XCTAssertEqual(poster.warps.last, .zero)
    }

    func testUserInputAfterDragReleaseCancelsDestinationRaiseRetries() {
        let window = TestElement(titleBarFrame: CGRect(x: 100, y: 100, width: 500, height: 30))
        let poster = EventPosterSpy(mouseLocation: .zero)
        let scheduler = SchedulerSpy()
        let notifications = NotificationCenter()
        let input = PhysicalInputMonitorSpy()
        var raises = 0
        let manager = manager(poster: poster, scheduler: scheduler, window: window,
                              notificationCenter: notifications, physicalInputMonitor: input,
                              raise: { _ in raises += 1 }, frontmost: { _, _ in false })
        XCTAssertTrue(manager.execute(parameters: ExecutionParameters(.nextSpace)))
        scheduler.runUntil { poster.phases == [.began, .changed, .ended] }
        notifications.post(name: NSWorkspace.activeSpaceDidChangeNotification, object: nil)
        scheduler.runUntil { raises == 1 }
        input.trigger()
        scheduler.runNext()
        XCTAssertFalse(manager.isSpaceActionInProgress)
        XCTAssertEqual(raises, 1)
        XCTAssertEqual(poster.mouseUpPoints.count, 1)
        XCTAssertNotEqual(poster.warps.last, .zero)
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

        XCTAssertEqual(poster.phases, [.began, .changed, .ended])
        XCTAssertEqual(poster.mouseUpPoints.count, 1)
        XCTAssertEqual(poster.discardCount, 1)
    }

    func testPhysicalInputAfterGestureBeganClosesGestureBeforeReleasingDrag() {
        let poster = EventPosterSpy(mouseLocation: .zero)
        poster.gesturePhaseDelay = 0.01
        let scheduler = SchedulerSpy()
        let monitor = PhysicalInputMonitorSpy()
        let manager = manager(poster: poster, scheduler: scheduler,
                              window: TestElement(titleBarFrame: CGRect(x: 100, y: 100, width: 500, height: 30)),
                              physicalInputMonitor: monitor)
        XCTAssertTrue(manager.execute(parameters: ExecutionParameters(.nextSpace)))
        scheduler.runUntil { poster.phases == [.began] }
        monitor.trigger()
        XCTAssertEqual(poster.phases, [.began, .ended])
        XCTAssertEqual(poster.mouseUpPoints.count, 1)
        scheduler.runNext()
        XCTAssertEqual(poster.phases, [.began, .ended])
        XCTAssertFalse(manager.isSpaceActionInProgress)
    }

    func testDeinitClosesAnUnfinishedDragGesture() {
        let poster = EventPosterSpy(mouseLocation: .zero)
        poster.gesturePhaseDelay = 0.01
        let scheduler = SchedulerSpy()
        var manager: SpaceManager? = manager(poster: poster, scheduler: scheduler,
                                              window: TestElement(titleBarFrame: CGRect(x: 100, y: 100, width: 500, height: 30)))
        XCTAssertTrue(manager!.execute(parameters: ExecutionParameters(.nextSpace)))
        scheduler.runUntil { poster.phases == [.began] }
        manager = nil
        XCTAssertEqual(poster.phases, [.began, .ended])
        XCTAssertEqual(poster.mouseUpPoints.count, 1)
    }

    func testDragDoesNotStartDuringMissionControlOrAnotherSpaceOperation() throws {
        for missionControl in [true, false] {
            let coordinator = SpaceOperationCoordinator(environmentIsSafe: { !missionControl }, workspaceNotificationCenter: NotificationCenter())
            let operation = missionControl ? nil : try XCTUnwrap(coordinator.begin())
            let poster = EventPosterSpy(mouseLocation: .zero)
            let scheduler = SchedulerSpy()
            let manager = manager(poster: poster, scheduler: scheduler,
                                  window: TestElement(titleBarFrame: CGRect(x: 100, y: 100, width: 500, height: 30)),
                                  coordinator: coordinator)
            XCTAssertTrue(manager.execute(parameters: ExecutionParameters(.nextSpace)))
            XCTAssertTrue(poster.prepared.isEmpty)
            XCTAssertEqual(poster.mouseDownCount, 0)
            withExtendedLifetime(operation) {}
        }
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
        scheduler.runUntil { !manager.isSpaceActionInProgress }

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
        window.testWindowID = 12
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
        let window = TestElement(titleBarFrame: CGRect(x: 100, y: 100, width: 500, height: 30))
        window.testWindowID = nil
        let manager = manager(
            poster: poster,
            scheduler: scheduler,
            window: window,
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
        var testWindowID: CGWindowID = 101
        var testFrame = CGRect(x: 100, y: 100, width: 500, height: 300)
        var writtenFrames = [CGRect]()
        var minimized = false
        var fullscreen = false
        var sheet = false
        var modal = false
        override var windowId: CGWindowID? { testWindowID }
        override var frame: CGRect { testFrame }
        override var isSheet: Bool? { sheet }
        override var isModal: Bool? { modal }
        override var isMinimized: Bool? { minimized }
        override var isFullScreen: Bool? { fullscreen }
        override func setFrame(_ frame: CGRect, adjustSizeFirst: Bool = true, adjustPosition: Bool = true) {
            writtenFrames.append(frame)
            testFrame = frame
        }

        init() { super.init(AXUIElementCreateSystemWide()) }
    }

    private final class TransferSpy: WindowSpaceTransferring {
        var isAvailable = true
        var memberships: [UInt64]? = [57]
        var displayedSpace: UInt64? = 57
        var displayedSpaces = [String: UInt64]()
        var updateMembershipOnMove = false
        var moveResult = true
        var adjacent: AdjacentManagedSpace? = AdjacentManagedSpace(
            sourceID: 57, destinationID: 10, displayIdentifier: "secondary"
        )
        var events = [String]()

        func spaces(for windowID: CGWindowID) -> [UInt64]? { memberships }
        func adjacentSpace(for windowID: CGWindowID,
                           direction: SpaceDirection) -> AdjacentManagedSpace? {
            adjacent
        }
        func currentSpace(for displayIdentifier: String) -> UInt64? {
            displayedSpaces[displayIdentifier] ?? displayedSpace
        }
        func move(windowID: CGWindowID, to spaceID: UInt64) -> Bool {
            events.append("move:\(windowID):\(spaceID)")
            if moveResult, updateMembershipOnMove { memberships = [spaceID] }
            return moveResult
        }
    }

    private final class NumberedActivationSpy: ManagedDisplaySpaceActivating {
        let transfer: TransferSpy
        var isAvailable = true
        var destination: ManagedDisplaySpaceSwitch? = ManagedDisplaySpaceSwitch(
            sourceID: 57, destinationID: 10, displayIdentifier: "secondary"
        )
        var visible = true
        var acceptsSwitch = true
        var updatesDisplay = true
        var restoresVisibility = true
        var requestedNumbers = [Int]()
        init(_ transfer: TransferSpy) { self.transfer = transfer }
        func desktop(number: Int) -> ManagedDisplaySpaceSwitch? {
            requestedNumbers.append(number)
            return destination
        }
        func currentSpace(on displayIdentifier: String) -> UInt64? { transfer.currentSpace(for: displayIdentifier) }
        func destinationIsVisible(_ target: ManagedDisplaySpaceSwitch) -> Bool? {
            currentSpace(on: target.displayIdentifier) == target.destinationID && visible
        }
        func activate(_ target: ManagedDisplaySpaceSwitch) -> Bool {
            transfer.events.append("direct:\(target.displayIdentifier):\(target.destinationID)")
            if acceptsSwitch, updatesDisplay {
                transfer.displayedSpaces[target.displayIdentifier] = target.destinationID
                if target.destinationID == destination?.sourceID, restoresVisibility { visible = true }
            }
            return acceptsSwitch
        }
    }

    private final class TestScreen: NSScreen {
        let testFrame: CGRect
        init(_ frame: CGRect) { testFrame = frame; super.init() }
        override var frame: NSRect { testFrame }
        override var visibleFrame: NSRect { testFrame }
        override var safeAreaInsets: NSEdgeInsets { NSEdgeInsetsZero }
        override var hash: Int { ObjectIdentifier(self).hashValue }
        override func isEqual(_ object: Any?) -> Bool { (object as AnyObject?) === self }
    }

    private final class InputMonitorSpy: SpacePhysicalInputMonitoring {
        var handler: (() -> Void)?
        func start(_ handler: @escaping () -> Void) { self.handler = handler }
        func stop() { handler = nil }
        func trigger() { handler?() }
    }

    private final class SwitchSpy: DisplaySpaceSwitching {
        var isSpaceActionInProgress = false
        weak var receivedOperation: SpaceOperationCoordinator.Operation?
        var defersCommit = false
        var acceptsSwitch = true
        private var beforeSwitch: (() -> Void)?
        let transfer: TransferSpy
        init(transfer: TransferSpy) { self.transfer = transfer }
        func execute(parameters: ExecutionParameters) -> Bool {
            transfer.events.append("switch:\(parameters.action.name)")
            return true
        }
        func execute(parameters: ExecutionParameters, continuing operation: SpaceOperationCoordinator.Operation?) -> Bool {
            execute(parameters: parameters, continuing: operation, beforeSwitch: nil)
        }
        func execute(parameters: ExecutionParameters,
                     continuing operation: SpaceOperationCoordinator.Operation?,
                     beforeSwitch: (() -> Void)?) -> Bool {
            guard acceptsSwitch else { return true }
            receivedOperation = operation
            _ = execute(parameters: parameters)
            if defersCommit {
                isSpaceActionInProgress = true
                self.beforeSwitch = beforeSwitch
            } else {
                beforeSwitch?()
            }
            return true
        }
        func commit() {
            let action = beforeSwitch
            beforeSwitch = nil
            action?()
        }
        func finish() {
            beforeSwitch = nil
            isSpaceActionInProgress = false
        }
    }

    private final class MoveScheduler {
        var actions = [() -> Void]()
        func schedule(_ delay: TimeInterval, _ action: @escaping () -> Void) { actions.append(action) }
        func runNext() {
            guard !actions.isEmpty else { return XCTFail("Expected a Space move callback") }
            actions.removeFirst()()
        }
        func runUntil(_ condition: () -> Bool, limit: Int = 60) {
            for _ in 0..<limit {
                if condition() { return }
                runNext()
            }
            XCTFail("Space move did not finish")
        }
    }

    private func unavailableActivation(_ transfer: TransferSpy) -> NumberedActivationSpy {
        let activation = NumberedActivationSpy(transfer)
        activation.isAvailable = false
        return activation
    }

    private func makeManager(transfer: TransferSpy, window: TestWindow, scheduler: MoveScheduler,
                             switcher: SwitchSpy? = nil,
                             coordinator: SpaceOperationCoordinator = SpaceOperationCoordinator(environmentIsSafe: { true }, workspaceNotificationCenter: NotificationCenter()),
                             input: InputMonitorSpy = InputMonitorSpy(),
                             focusedWindow: (() -> AccessibilityElement?)? = nil,
                             snapshot: SpaceWindowSnapshotProvider? = nil,
                             raise: ((AccessibilityElement, Bool) -> Void)? = nil,
                             frontmost: @escaping (CGWindowID, AdjacentManagedSpace) -> Bool? = { _, _ in true },
                             follow: @escaping () -> Bool = { true },
                             numberedActivation: NumberedActivationSpy? = nil,
                             numberedFollow: (() -> Bool)? = nil,
                             sourceDisplay: String = "secondary",
                             sourceScreen: NSScreen? = nil, destinationScreen: NSScreen? = nil,
                             dragging: Bool = false,
                             adjacentActivation: NumberedActivationSpy? = nil,
                             gestureTargetIsAdjacent: @escaping (AdjacentManagedSpace, SpaceDirection) -> Bool = { _, _ in true }) -> BridgedSpaceManager {
        let gestureOnlyActivation = NumberedActivationSpy(transfer)
        gestureOnlyActivation.isAvailable = false
        return BridgedSpaceManager(
            transfer: transfer, switcher: switcher ?? SwitchSpy(transfer: transfer), scheduler: scheduler.schedule,
            frontWindowProvider: focusedWindow ?? { window },
            windowSnapshotProvider: snapshot ?? { _ in
                SpaceWindowSnapshot(windowId: 101, pid: 42, frame: window.frame, level: 0, isOnScreen: true)
            },
            accessibilityAuthorized: { true }, screenProvider: { _ in sourceScreen ?? NSScreen.screens.first },
            displayIdentifierAtPoint: { _ in sourceDisplay },
            raiseWindow: raise ?? { _, activate in transfer.events.append(activate ? "raise" : "order") },
            windowIsFrontmost: frontmost, followMovedWindowProvider: follow,
            numberedActivation: numberedActivation ?? NumberedActivationSpy(transfer),
            followNumberedWindowProvider: numberedFollow ?? { !Defaults.followMovedWindowToNumberedSpace.userDisabled },
            screenForDisplay: { _ in destinationScreen ?? NSScreen.screens.first }, mousePressed: { dragging },
            coordinator: coordinator, physicalInputMonitor: input,
            adjacentActivation: adjacentActivation ?? gestureOnlyActivation,
            gestureTargetIsAdjacent: gestureTargetIsAdjacent
        )
    }

    func testNumberedMoveCommandsHaveSeparateStableMetadataAndNoDefaultBindings() {
        XCTAssertEqual(WindowAction.numberedSpaceMoves.count, 9)
        XCTAssertTrue(Set(WindowAction.numberedSpaceMoves).isDisjoint(with: WindowAction.numberedSpaceSwitches))
        for (index, action) in WindowAction.numberedSpaceMoves.enumerated() {
            XCTAssertEqual(action.rawValue, 145 + index)
            XCTAssertEqual(action.moveDesktopNumber, index + 1)
            XCTAssertNil(action.desktopNumber)
            XCTAssertEqual(action.displayName, "Move to Desktop \(index + 1)")
            XCTAssertTrue(WindowAction.active.contains(action))
            XCTAssertFalse(action.resizes)
            XCTAssertFalse(action.isDragSnappable)
            XCTAssertFalse(action.positionCycles)
            XCTAssertEqual(action.gapsApplicable, .none)
            XCTAssertEqual(action.classification, .display)
            XCTAssertNil(action.spectacleDefault)
            XCTAssertNil(action.alternateDefault)
        }
        XCTAssertNil(WindowAction.switchSpaceOne.moveDesktopNumber)
        XCTAssertEqual(Set(WindowAction.numberedSpaceMoves.map(\.name)).count, 9)
    }

    func testUnreachableGestureTargetDoesNotMoveWindowOrSwitchDesktop() {
        let transfer = TransferSpy(), scheduler = MoveScheduler()
        let switcher = SwitchSpy(transfer: transfer)
        let subject = makeManager(transfer: transfer, window: TestWindow(), scheduler: scheduler,
                                  switcher: switcher, gestureTargetIsAdjacent: { _, _ in false })
        XCTAssertTrue(subject.execute(parameters: ExecutionParameters(.nextSpace)))
        XCTAssertTrue(transfer.events.isEmpty)
        XCTAssertNil(switcher.receivedOperation)
        XCTAssertFalse(subject.isSpaceActionInProgress)
    }

    func testDirectAdjacentFollowMovesAndSwitchesTogetherWithoutGesture() {
        let transfer = TransferSpy(), scheduler = MoveScheduler()
        transfer.updateMembershipOnMove = true
        let activation = NumberedActivationSpy(transfer)
        let subject = makeManager(transfer: transfer, window: TestWindow(), scheduler: scheduler, adjacentActivation: activation)
        XCTAssertTrue(subject.execute(parameters: ExecutionParameters(.nextSpace)))
        XCTAssertEqual(transfer.events, ["move:101:10", "direct:secondary:10"])
        scheduler.runUntil { !subject.isSpaceActionInProgress }
        XCTAssertEqual(transfer.events.last, "raise")
        XCTAssertEqual(transfer.memberships, [10])
    }

    func testInterruptedSubmittedMoveKeepsLeaseUntilArrivalWithoutFocusOrRollback() {
        let transfer = TransferSpy(), scheduler = MoveScheduler(), input = InputMonitorSpy()
        let activation = NumberedActivationSpy(transfer)
        let coordinator = SpaceOperationCoordinator(environmentIsSafe: { true }, workspaceNotificationCenter: NotificationCenter())
        let subject = makeManager(transfer: transfer, window: TestWindow(), scheduler: scheduler,
                                  coordinator: coordinator, input: input, adjacentActivation: activation)
        XCTAssertTrue(subject.execute(parameters: ExecutionParameters(.nextSpace)))
        input.trigger()
        scheduler.runNext()
        XCTAssertTrue(subject.isSpaceActionInProgress)
        XCTAssertNil(coordinator.begin())
        transfer.memberships = [10]
        scheduler.runUntil { !subject.isSpaceActionInProgress }
        XCTAssertEqual(transfer.events, ["move:101:10", "direct:secondary:10"])
        XCTAssertNotNil(coordinator.begin())
    }

    func testFailedAdjacentDirectFollowRestoresWindowToItsSource() {
        let transfer = TransferSpy(), scheduler = MoveScheduler()
        transfer.updateMembershipOnMove = true
        let activation = NumberedActivationSpy(transfer)
        activation.acceptsSwitch = false
        let subject = makeManager(transfer: transfer, window: TestWindow(), scheduler: scheduler, adjacentActivation: activation)
        XCTAssertTrue(subject.execute(parameters: ExecutionParameters(.nextSpace)))
        scheduler.runUntil { !subject.isSpaceActionInProgress }
        XCTAssertEqual(transfer.memberships, [57])
        XCTAssertFalse(transfer.events.contains("raise"))
    }

    func testDeferredTransferRechecksWindowAndSourceSpaceBeforeCommitting() {
        for minimized in [true, false] {
            let transfer = TransferSpy(), scheduler = MoveScheduler(), window = TestWindow()
            let switcher = SwitchSpy(transfer: transfer)
            switcher.defersCommit = true
            let subject = makeManager(transfer: transfer, window: window, scheduler: scheduler, switcher: switcher)
            XCTAssertTrue(subject.execute(parameters: ExecutionParameters(.nextSpace)))
            if minimized { window.minimized = true } else { transfer.memberships = [999] }
            switcher.commit()
            XCTAssertFalse(transfer.events.contains("move:101:10"))
            switcher.finish()
            scheduler.runUntil { !subject.isSpaceActionInProgress }
        }
    }

    func testCrossDisplayMoveStopsRestoringFocusIfSourceDisplayChangesSpace() {
        let transfer = TransferSpy(), scheduler = MoveScheduler()
        transfer.updateMembershipOnMove = true
        transfer.displayedSpaces = ["main": 57, "secondary": 300]
        let activation = NumberedActivationSpy(transfer)
        activation.destination = ManagedDisplaySpaceSwitch(sourceID: 300, destinationID: 10, displayIdentifier: "secondary")
        let subject = makeManager(transfer: transfer, window: TestWindow(), scheduler: scheduler,
                                  numberedActivation: activation, numberedFollow: { true }, sourceDisplay: "main")
        XCTAssertTrue(subject.execute(parameters: ExecutionParameters(.moveSpaceOne)))
        transfer.displayedSpaces["main"] = 999
        scheduler.runUntil { !subject.isSpaceActionInProgress }
        XCTAssertFalse(transfer.events.contains("raise"))
        XCTAssertFalse(transfer.events.contains("move:101:57"))
    }

    func testNumberedMoveOnlyUsesResolvedIDWithoutSwitching() {
        let transfer = TransferSpy(), scheduler = MoveScheduler()
        transfer.adjacent = nil
        transfer.updateMembershipOnMove = true
        let activation = NumberedActivationSpy(transfer)
        activation.destination = ManagedDisplaySpaceSwitch(sourceID: 57, destinationID: 9001, displayIdentifier: "secondary")
        let manager = makeManager(transfer: transfer, window: TestWindow(), scheduler: scheduler,
                                  numberedActivation: activation, numberedFollow: { false })
        XCTAssertTrue(manager.execute(parameters: ExecutionParameters(.moveSpaceFive)))
        scheduler.runUntil { !manager.isSpaceActionInProgress }
        XCTAssertEqual(activation.requestedNumbers, [5])
        XCTAssertEqual(transfer.memberships, [9001])
        XCTAssertEqual(transfer.currentSpace(for: "secondary"), 57)
        XCTAssertEqual(transfer.events, ["move:101:9001", "order"])
    }

    func testNumberedFollowSubmitsSwitchImmediatelyAndWaitsForWindowArrival() {
        let transfer = TransferSpy(), scheduler = MoveScheduler()
        let activation = NumberedActivationSpy(transfer)
        let coordinator = SpaceOperationCoordinator(environmentIsSafe: { true }, workspaceNotificationCenter: NotificationCenter())
        let manager = makeManager(transfer: transfer, window: TestWindow(), scheduler: scheduler,
                                  coordinator: coordinator, numberedActivation: activation, numberedFollow: { true })
        XCTAssertTrue(manager.execute(parameters: ExecutionParameters(.moveSpaceNine)))
        XCTAssertEqual(transfer.events, ["move:101:10", "direct:secondary:10"])
        XCTAssertTrue(manager.isSpaceActionInProgress)
        XCTAssertNil(coordinator.begin())
        scheduler.runNext()
        XCTAssertFalse(transfer.events.contains("raise"))
        transfer.memberships = [10]
        scheduler.runUntil { !manager.isSpaceActionInProgress }
        XCTAssertEqual(activation.requestedNumbers, [9])
        XCTAssertEqual(transfer.events.last, "raise")
        XCTAssertNotNil(coordinator.begin())
    }

    func testNumberedFollowDoesNotRaiseWhenOnlySpaceMetadataChanges() {
        let transfer = TransferSpy(), scheduler = MoveScheduler()
        transfer.updateMembershipOnMove = true
        let activation = NumberedActivationSpy(transfer)
        activation.visible = false
        let manager = makeManager(transfer: transfer, window: TestWindow(), scheduler: scheduler,
                                  numberedActivation: activation, numberedFollow: { true })
        XCTAssertTrue(manager.execute(parameters: ExecutionParameters(.moveSpaceOne)))
        for _ in 0..<5 { scheduler.runNext() }
        XCTAssertFalse(transfer.events.contains("raise"))
        XCTAssertTrue(manager.isSpaceActionInProgress)
        activation.visible = true
        scheduler.runUntil { !manager.isSpaceActionInProgress }
        XCTAssertEqual(transfer.events.last, "raise")
    }

    func testNumberedFollowRestoresTheMovedWindowAfterAutomaticFocusChange() {
        let transfer = TransferSpy(), scheduler = MoveScheduler(), window = TestWindow(), other = TestWindow()
        other.testWindowID = 202
        var focused: AccessibilityElement? = other
        transfer.updateMembershipOnMove = true
        let manager = makeManager(transfer: transfer, window: window, scheduler: scheduler,
                                  focusedWindow: { focused }, raise: { element, activate in
            XCTAssertTrue(activate)
            transfer.events.append("raise")
            focused = element
        }, numberedFollow: { true })
        XCTAssertTrue(manager.execute(parameters: ExecutionParameters(.moveSpaceTwo, windowElement: window)))
        scheduler.runUntil { !manager.isSpaceActionInProgress }
        XCTAssertEqual(focused?.windowId, 101)
        XCTAssertEqual(transfer.events.filter { $0 == "raise" }.count, 1)
    }

    func testNumberedMissingAndCurrentDesktopDoNothing() {
        for missing in [true, false] {
            let transfer = TransferSpy(), scheduler = MoveScheduler()
            let activation = NumberedActivationSpy(transfer)
            activation.destination = missing ? nil : ManagedDisplaySpaceSwitch(
                sourceID: 57, destinationID: 57, displayIdentifier: "secondary")
            let manager = makeManager(transfer: transfer, window: TestWindow(), scheduler: scheduler,
                                      numberedActivation: activation, numberedFollow: { true })
            XCTAssertTrue(manager.execute(parameters: ExecutionParameters(.moveSpaceOne)))
            XCTAssertTrue(transfer.events.isEmpty)
            XCTAssertTrue(scheduler.actions.isEmpty)
            XCTAssertFalse(manager.isSpaceActionInProgress)
        }
    }

    func testNumberedFollowPreferenceIsIndependentOfAdjacentMoves() {
        let adjacent = Defaults.followMovedWindowToSpace.enabled
        let numbered = Defaults.followMovedWindowToNumberedSpace.enabled
        defer {
            Defaults.followMovedWindowToSpace.enabled = adjacent
            Defaults.followMovedWindowToNumberedSpace.enabled = numbered
        }
        XCTAssertTrue(Defaults.array.contains { $0.key == Defaults.followMovedWindowToNumberedSpace.key })
        for follows in [false, true] {
            Defaults.followMovedWindowToSpace.enabled = !follows
            Defaults.followMovedWindowToNumberedSpace.enabled = follows
            let transfer = TransferSpy(), scheduler = MoveScheduler()
            transfer.updateMembershipOnMove = true
            let manager = makeManager(transfer: transfer, window: TestWindow(), scheduler: scheduler,
                                      follow: { !Defaults.followMovedWindowToSpace.userDisabled })
            XCTAssertTrue(manager.execute(parameters: ExecutionParameters(.moveSpaceThree)))
            scheduler.runUntil { !manager.isSpaceActionInProgress }
            XCTAssertEqual(transfer.events.contains("direct:secondary:10"), follows)
            XCTAssertEqual(transfer.events.last, follows ? "raise" : "order")
            XCTAssertEqual(Defaults.followMovedWindowToSpace.enabled, !follows)
        }
    }

    func testNumberedMoveRejectsUnsafeWindowsAndMembershipsBeforeSubmission() {
        for scenario in 0..<8 {
            let transfer = TransferSpy(), scheduler = MoveScheduler(), window = TestWindow()
            switch scenario {
            case 0: transfer.memberships = [57, 99]
            case 1: transfer.memberships = nil
            case 2: transfer.memberships = [99]
            case 3: window.minimized = true
            case 4: window.fullscreen = true
            case 5: window.sheet = true
            case 6: window.modal = true
            default: break
            }
            let manager = makeManager(transfer: transfer, window: window, scheduler: scheduler,
                                      numberedFollow: { true }, dragging: scenario == 7)
            XCTAssertTrue(manager.execute(parameters: ExecutionParameters(.moveSpaceOne)))
            XCTAssertTrue(transfer.events.isEmpty)
            XCTAssertFalse(manager.isSpaceActionInProgress)
        }
    }

    func testNumberedMoveRequiresTransferAndFollowRequiresActivation() {
        for scenario in 0..<3 {
            let transfer = TransferSpy(), scheduler = MoveScheduler()
            transfer.updateMembershipOnMove = true
            let activation = NumberedActivationSpy(transfer)
            transfer.isAvailable = scenario != 0
            activation.isAvailable = false
            let manager = makeManager(transfer: transfer, window: TestWindow(), scheduler: scheduler,
                                      numberedActivation: activation, numberedFollow: { scenario != 2 })
            XCTAssertTrue(manager.execute(parameters: ExecutionParameters(.moveSpaceOne)))
            if scenario == 2 {
                scheduler.runUntil { !manager.isSpaceActionInProgress }
                XCTAssertEqual(transfer.events, ["move:101:10", "order"])
            } else {
                XCTAssertTrue(transfer.events.isEmpty)
                XCTAssertFalse(manager.isSpaceActionInProgress)
            }
        }
    }

    func testNumberedCrossDisplayMoveKeepsWindowSourceAndDisplaySourceDistinct() {
        for follows in [false, true] {
            let transfer = TransferSpy(), scheduler = MoveScheduler(), window = TestWindow()
            transfer.updateMembershipOnMove = true
            transfer.displayedSpaces = ["main": 57, "secondary": 300]
            let activation = NumberedActivationSpy(transfer)
            activation.destination = ManagedDisplaySpaceSwitch(sourceID: 300, destinationID: 10, displayIdentifier: "secondary")
            let source = TestScreen(CGRect(x: 0, y: 0, width: 1200, height: 800))
            let destination = TestScreen(CGRect(x: 1200, y: 0, width: 800, height: 600))
            window.testFrame = source.frame.insetBy(dx: 100, dy: 100).screenFlipped
            let manager = makeManager(transfer: transfer, window: window, scheduler: scheduler,
                                      numberedActivation: activation, numberedFollow: { follows },
                                      sourceDisplay: "main", sourceScreen: source, destinationScreen: destination)
            XCTAssertTrue(manager.execute(parameters: ExecutionParameters(.moveSpaceSeven)))
            scheduler.runUntil { !manager.isSpaceActionInProgress }
            XCTAssertEqual(transfer.memberships, [10])
            XCTAssertEqual(transfer.currentSpace(for: "main"), 57)
            XCTAssertEqual(transfer.currentSpace(for: "secondary"), follows ? 10 : 300)
            XCTAssertEqual(window.writtenFrames.count, 1)
            XCTAssertTrue(destination.frame.screenFlipped.contains(window.frame))
            XCTAssertEqual(transfer.events.last, follows ? "raise" : "order")
        }
    }

    func testNumberedMoveToVisibleDesktopDoesNotRequireASwitchOperation() {
        let transfer = TransferSpy(), scheduler = MoveScheduler()
        transfer.updateMembershipOnMove = true
        transfer.displayedSpaces = ["main": 57, "secondary": 10]
        let activation = NumberedActivationSpy(transfer)
        activation.isAvailable = false
        activation.acceptsSwitch = false
        activation.destination = ManagedDisplaySpaceSwitch(sourceID: 10, destinationID: 10, displayIdentifier: "secondary")
        let manager = makeManager(transfer: transfer, window: TestWindow(), scheduler: scheduler,
                                  numberedActivation: activation, numberedFollow: { true }, sourceDisplay: "main")
        XCTAssertTrue(manager.execute(parameters: ExecutionParameters(.moveSpaceOne)))
        scheduler.runUntil { !manager.isSpaceActionInProgress }
        XCTAssertEqual(transfer.events, ["move:101:10", "raise"])
        XCTAssertEqual(transfer.currentSpace(for: "main"), 57)
    }

    func testNumberedCrossDisplayPlacementHonorsCenterAndMaximizeSettings() {
        let center = Defaults.centerAcrossDisplays.enabled
        let maximize = Defaults.autoMaximize.enabled
        defer {
            Defaults.centerAcrossDisplays.enabled = center
            Defaults.autoMaximize.enabled = maximize
        }
        let source = TestScreen(CGRect(x: 0, y: 0, width: 1200, height: 800))
        let destination = TestScreen(CGRect(x: 1200, y: 0, width: 2400, height: 1600))
        for maximized in [false, true] {
            for preserve in [false, true] {
                Defaults.centerAcrossDisplays.enabled = true
                Defaults.autoMaximize.enabled = preserve
                let transfer = TransferSpy(), scheduler = MoveScheduler(), window = TestWindow()
                transfer.updateMembershipOnMove = true
                transfer.displayedSpaces = ["main": 57, "secondary": 300]
                let activation = NumberedActivationSpy(transfer)
                activation.destination = ManagedDisplaySpaceSwitch(sourceID: 300, destinationID: 10, displayIdentifier: "secondary")
                window.testFrame = (maximized ? source.adjustedVisibleFrame()
                    : CGRect(x: 50, y: 50, width: 400, height: 300)).screenFlipped
                let size = window.frame.size
                let manager = makeManager(transfer: transfer, window: window, scheduler: scheduler,
                                          numberedActivation: activation, numberedFollow: { false }, sourceDisplay: "main",
                                          sourceScreen: source, destinationScreen: destination)
                XCTAssertTrue(manager.execute(parameters: ExecutionParameters(.moveSpaceOne)))
                scheduler.runUntil { !manager.isSpaceActionInProgress }
                let bounds = destination.adjustedVisibleFrame().screenFlipped
                let expected = maximized && preserve ? bounds : CGRect(
                    x: bounds.midX - size.width / 2, y: bounds.midY - size.height / 2,
                    width: size.width, height: size.height)
                XCTAssertEqual(window.frame, expected)
            }
        }
    }

    func testNumberedPhysicalInputAndExternalSpaceChangesCancelRestoration() {
        for physical in [false, true] {
            let transfer = TransferSpy(), scheduler = MoveScheduler(), input = InputMonitorSpy()
            transfer.updateMembershipOnMove = true
            let activation = NumberedActivationSpy(transfer)
            activation.visible = false
            let manager = makeManager(transfer: transfer, window: TestWindow(), scheduler: scheduler,
                                      input: input, numberedActivation: activation, numberedFollow: { true })
            XCTAssertTrue(manager.execute(parameters: ExecutionParameters(.moveSpaceOne)))
            if physical { input.trigger() } else { transfer.displayedSpaces["secondary"] = 999 }
            scheduler.runUntil { !manager.isSpaceActionInProgress }
            XCTAssertEqual(transfer.events, ["move:101:10", "direct:secondary:10"])
            XCTAssertNil(input.handler)
        }
    }

    func testNumberedRejectedSwitchRestoresWindowAndRetainsTheOperationLock() {
        let transfer = TransferSpy(), scheduler = MoveScheduler()
        transfer.updateMembershipOnMove = true
        let activation = NumberedActivationSpy(transfer)
        activation.acceptsSwitch = false
        let coordinator = SpaceOperationCoordinator(environmentIsSafe: { true }, workspaceNotificationCenter: NotificationCenter())
        let manager = makeManager(transfer: transfer, window: TestWindow(), scheduler: scheduler,
                                  coordinator: coordinator, numberedActivation: activation, numberedFollow: { true })
        XCTAssertTrue(manager.execute(parameters: ExecutionParameters(.moveSpaceOne)))
        XCTAssertEqual(transfer.events, ["move:101:10", "direct:secondary:10", "move:101:57"])
        XCTAssertTrue(manager.isSpaceActionInProgress)
        XCTAssertNil(coordinator.begin())
        scheduler.runUntil { !manager.isSpaceActionInProgress }
        XCTAssertEqual(transfer.memberships, [57])
        XCTAssertEqual(transfer.currentSpace(for: "secondary"), 57)
        XCTAssertNotNil(coordinator.begin())
    }

    func testNumberedPartialCrossDisplaySwitchRestoresTheActualWindowSource() {
        let transfer = TransferSpy(), scheduler = MoveScheduler(), window = TestWindow()
        transfer.updateMembershipOnMove = true
        transfer.displayedSpaces = ["main": 57, "secondary": 300]
        let activation = NumberedActivationSpy(transfer)
        activation.destination = ManagedDisplaySpaceSwitch(sourceID: 300, destinationID: 10, displayIdentifier: "secondary")
        activation.visible = false
        let originalFrame = window.frame
        let manager = makeManager(transfer: transfer, window: window, scheduler: scheduler,
                                  numberedActivation: activation, numberedFollow: { true }, sourceDisplay: "main")
        XCTAssertTrue(manager.execute(parameters: ExecutionParameters(.moveSpaceOne)))
        scheduler.runUntil { !manager.isSpaceActionInProgress }
        XCTAssertEqual(transfer.memberships, [57])
        XCTAssertEqual(transfer.displayedSpaces, ["main": 57, "secondary": 300])
        XCTAssertEqual(transfer.events, ["move:101:10", "direct:secondary:10", "move:101:57", "direct:secondary:300"])
        XCTAssertEqual(window.frame, originalFrame)
    }

    func testNumberedChangedWindowIsNotPositionedAfterTransfer() {
        let transfer = TransferSpy(), scheduler = MoveScheduler(), window = TestWindow()
        transfer.displayedSpaces = ["main": 57, "secondary": 300]
        let activation = NumberedActivationSpy(transfer)
        activation.destination = ManagedDisplaySpaceSwitch(sourceID: 300, destinationID: 10, displayIdentifier: "secondary")
        let manager = makeManager(transfer: transfer, window: window, scheduler: scheduler,
                                  numberedActivation: activation, numberedFollow: { false }, sourceDisplay: "main")
        XCTAssertTrue(manager.execute(parameters: ExecutionParameters(.moveSpaceOne)))
        window.testWindowID = 202
        transfer.memberships = [10]
        scheduler.runUntil { !manager.isSpaceActionInProgress }
        XCTAssertTrue(window.writtenFrames.isEmpty)
        XCTAssertEqual(transfer.events, ["move:101:10"])
    }

    func testNumberedRecoveryWaitsForRestoredVisibilityBeforeReleasingTheLock() {
        let transfer = TransferSpy(), scheduler = MoveScheduler()
        transfer.updateMembershipOnMove = true
        let activation = NumberedActivationSpy(transfer)
        activation.visible = false
        activation.restoresVisibility = false
        let coordinator = SpaceOperationCoordinator(environmentIsSafe: { true }, workspaceNotificationCenter: NotificationCenter())
        let manager = makeManager(transfer: transfer, window: TestWindow(), scheduler: scheduler,
                                  coordinator: coordinator, numberedActivation: activation, numberedFollow: { true })
        XCTAssertTrue(manager.execute(parameters: ExecutionParameters(.moveSpaceOne)))
        scheduler.runUntil { transfer.events.contains("direct:secondary:57") }
        for _ in 0..<5 { scheduler.runNext() }
        XCTAssertTrue(manager.isSpaceActionInProgress)
        XCTAssertNil(coordinator.begin())
        activation.visible = true
        scheduler.runUntil { !manager.isSpaceActionInProgress }
        XCTAssertEqual(transfer.memberships, [57])
        XCTAssertNotNil(coordinator.begin())
    }

    func testNumberedStaleRecoveryCallbackCannotAffectANewerMove() throws {
        let transfer = TransferSpy(), scheduler = MoveScheduler()
        transfer.updateMembershipOnMove = true
        let activation = NumberedActivationSpy(transfer)
        activation.acceptsSwitch = false
        let manager = makeManager(transfer: transfer, window: TestWindow(), scheduler: scheduler,
                                  numberedActivation: activation, numberedFollow: { true })
        XCTAssertTrue(manager.execute(parameters: ExecutionParameters(.moveSpaceOne)))
        let stale = try XCTUnwrap(scheduler.actions.first)
        scheduler.runUntil { !manager.isSpaceActionInProgress }
        activation.acceptsSwitch = true
        XCTAssertTrue(manager.execute(parameters: ExecutionParameters(.moveSpaceTwo)))
        let events = transfer.events
        stale()
        XCTAssertEqual(transfer.events, events)
        XCTAssertTrue(manager.isSpaceActionInProgress)
        scheduler.runUntil { !manager.isSpaceActionInProgress }
    }

    func testUserFocusChangeCancelsDestinationRestoration() {
        let transfer = TransferSpy()
        let window = TestWindow()
        let other = TestWindow()
        other.testWindowID = 202
        var focused: AccessibilityElement? = window
        let scheduler = MoveScheduler()
        let input = InputMonitorSpy()
        let manager = makeManager(transfer: transfer, window: window, scheduler: scheduler,
                                  input: input, focusedWindow: { focused })
        XCTAssertTrue(manager.execute(parameters: ExecutionParameters(.nextSpace)))
        transfer.memberships = [10]
        scheduler.runNext()
        focused = other
        input.trigger()
        transfer.displayedSpace = 10
        scheduler.runNext()
        XCTAssertEqual(transfer.events, ["switch:switchNextSpace", "move:101:10"])
        XCTAssertFalse(manager.isSpaceActionInProgress)
    }

    func testAutomaticDestinationFocusDoesNotSuppressTheMovedWindowRaise() {
        let transfer = TransferSpy()
        let window = TestWindow()
        let other = TestWindow()
        other.testWindowID = 202
        var focused: AccessibilityElement? = other
        let scheduler = MoveScheduler()
        let manager = makeManager(transfer: transfer, window: window, scheduler: scheduler,
                                  focusedWindow: { focused }, raise: { element, activate in
            XCTAssertTrue(activate)
            XCTAssertEqual(element.windowId, 101)
            transfer.events.append("raise")
            focused = window
        })

        XCTAssertTrue(manager.execute(parameters: ExecutionParameters(.nextSpace, windowElement: window)))
        transfer.memberships = [10]
        transfer.displayedSpace = 10
        scheduler.runNext()
        XCTAssertEqual(transfer.events.last, "raise")
        XCTAssertTrue(manager.isSpaceActionInProgress)
        scheduler.runUntil { !manager.isSpaceActionInProgress }
        XCTAssertEqual(focused?.windowId, 101)
        XCTAssertEqual(transfer.events.filter { $0 == "raise" }.count, 1)
    }

    func testLateDestinationOrderingChangeRestartsConfirmationAndRetriesTheRaise() {
        let transfer = TransferSpy()
        let scheduler = MoveScheduler()
        var frontmost = false
        var raises = 0
        let manager = makeManager(transfer: transfer, window: TestWindow(), scheduler: scheduler,
                                  raise: { _, _ in raises += 1; frontmost = true },
                                  frontmost: { _, _ in frontmost })
        XCTAssertTrue(manager.execute(parameters: ExecutionParameters(.nextSpace)))
        transfer.memberships = [10]
        transfer.displayedSpace = 10
        scheduler.runNext()
        scheduler.runNext()
        scheduler.runNext()
        XCTAssertTrue(manager.isSpaceActionInProgress)

        frontmost = false
        scheduler.runNext()
        XCTAssertEqual(raises, 2)
        for _ in 0..<2 { scheduler.runNext() }
        XCTAssertTrue(manager.isSpaceActionInProgress)
        scheduler.runNext()
        XCTAssertFalse(manager.isSpaceActionInProgress)
    }

    func testVisibilityLagAfterSpaceArrivalIsRetriedInsteadOfSkippingTheRaise() {
        let transfer = TransferSpy()
        let window = TestWindow()
        let scheduler = MoveScheduler()
        var visible = true
        var raises = 0
        var frontmost = false
        let manager = makeManager(transfer: transfer, window: window, scheduler: scheduler,
                                  snapshot: { _ in
            SpaceWindowSnapshot(windowId: 101, pid: 42, frame: window.frame, level: 0, isOnScreen: visible)
        }, raise: { _, _ in raises += 1; frontmost = true }, frontmost: { _, _ in frontmost })

        XCTAssertTrue(manager.execute(parameters: ExecutionParameters(.nextSpace)))
        transfer.memberships = [10]
        transfer.displayedSpace = 10
        visible = false
        scheduler.runNext()
        XCTAssertEqual(raises, 0)
        XCTAssertTrue(manager.isSpaceActionInProgress)
        visible = true
        scheduler.runUntil { !manager.isSpaceActionInProgress }
        XCTAssertEqual(raises, 1)
    }

    func testPhysicalInputCancelsOrderRetriesAfterTheFirstRaise() {
        let transfer = TransferSpy()
        let scheduler = MoveScheduler()
        let input = InputMonitorSpy()
        var raises = 0
        let manager = makeManager(transfer: transfer, window: TestWindow(), scheduler: scheduler,
                                  input: input, raise: { _, _ in raises += 1 }, frontmost: { _, _ in false })
        XCTAssertTrue(manager.execute(parameters: ExecutionParameters(.nextSpace)))
        transfer.memberships = [10]
        transfer.displayedSpace = 10
        scheduler.runNext()
        input.trigger()
        scheduler.runNext()
        XCTAssertEqual(raises, 1)
        XCTAssertFalse(manager.isSpaceActionInProgress)
        XCTAssertNil(input.handler)
    }

    func testOrderRetryStopsWhenTheWindowOrDisplayLeavesTheDestination() {
        for windowLeaves in [true, false] {
            let transfer = TransferSpy()
            let scheduler = MoveScheduler()
            var raises = 0
            let manager = makeManager(transfer: transfer, window: TestWindow(), scheduler: scheduler,
                                      raise: { _, _ in raises += 1 }, frontmost: { _, _ in false })
            XCTAssertTrue(manager.execute(parameters: ExecutionParameters(.nextSpace)))
            transfer.memberships = [10]
            transfer.displayedSpace = 10
            scheduler.runNext()
            if windowLeaves { transfer.memberships = [57] } else { transfer.displayedSpace = 57 }
            scheduler.runNext()
            XCTAssertEqual(raises, 1)
            XCTAssertFalse(manager.isSpaceActionInProgress)
        }
    }

    func testChangedWindowIdentityIsNeverRaisedOnTheDestination() {
        let transfer = TransferSpy()
        let window = TestWindow()
        let scheduler = MoveScheduler()
        var raises = 0
        let manager = makeManager(transfer: transfer, window: window, scheduler: scheduler,
                                  raise: { _, _ in raises += 1 })
        XCTAssertTrue(manager.execute(parameters: ExecutionParameters(.nextSpace)))
        transfer.memberships = [10]
        transfer.displayedSpace = 10
        window.testWindowID = 202
        scheduler.runNext()
        XCTAssertEqual(raises, 0)
        XCTAssertFalse(manager.isSpaceActionInProgress)
    }

    func testOldOrderCallbackCannotRaiseDuringANewerMove() throws {
        let transfer = TransferSpy()
        let scheduler = MoveScheduler()
        var raises = 0
        let manager = makeManager(transfer: transfer, window: TestWindow(), scheduler: scheduler,
                                  raise: { _, _ in raises += 1 })
        XCTAssertTrue(manager.execute(parameters: ExecutionParameters(.nextSpace)))
        transfer.memberships = [10]
        transfer.displayedSpace = 10
        scheduler.runNext()
        let oldCallback = try XCTUnwrap(scheduler.actions.first)
        scheduler.runUntil { !manager.isSpaceActionInProgress }
        transfer.memberships = [57]
        transfer.displayedSpace = 57
        XCTAssertTrue(manager.execute(parameters: ExecutionParameters(.nextSpace)))
        oldCallback()
        XCTAssertEqual(raises, 1)
        transfer.memberships = [10]
        transfer.displayedSpace = 10
        scheduler.runUntil { !manager.isSpaceActionInProgress }
        XCTAssertEqual(raises, 2)
    }

    func testMissionControlCancelsAWindowOrderRetry() {
        var safe = true
        let coordinator = SpaceOperationCoordinator(environmentIsSafe: { safe }, workspaceNotificationCenter: NotificationCenter())
        let transfer = TransferSpy()
        let scheduler = MoveScheduler()
        var raises = 0
        let manager = makeManager(transfer: transfer, window: TestWindow(), scheduler: scheduler,
                                  coordinator: coordinator, raise: { _, _ in raises += 1 }, frontmost: { _, _ in false })
        XCTAssertTrue(manager.execute(parameters: ExecutionParameters(.nextSpace)))
        transfer.memberships = [10]
        transfer.displayedSpace = 10
        scheduler.runNext()
        safe = false
        scheduler.runNext()
        XCTAssertEqual(raises, 1)
        XCTAssertFalse(manager.isSpaceActionInProgress)
        safe = true
        XCTAssertNotNil(coordinator.begin())
    }

    func testDeinitCancelsOrderRetriesAndReleasesTheOperation() {
        let transfer = TransferSpy()
        let scheduler = MoveScheduler()
        let input = InputMonitorSpy()
        let coordinator = SpaceOperationCoordinator(environmentIsSafe: { true }, workspaceNotificationCenter: NotificationCenter())
        var raises = 0
        var manager: BridgedSpaceManager? = makeManager(transfer: transfer, window: TestWindow(), scheduler: scheduler,
                                                        coordinator: coordinator, input: input,
                                                        raise: { _, _ in raises += 1 }, frontmost: { _, _ in false })
        XCTAssertTrue(manager?.execute(parameters: ExecutionParameters(.nextSpace)) == true)
        transfer.memberships = [10]
        transfer.displayedSpace = 10
        scheduler.runNext()
        manager = nil
        scheduler.runNext()
        XCTAssertEqual(raises, 1)
        XCTAssertNil(input.handler)
        XCTAssertNotNil(coordinator.begin())
    }

    func testUnconfirmedOrderHasABoundedRetryAndReleasesTheOperation() {
        let transfer = TransferSpy()
        let scheduler = MoveScheduler()
        let coordinator = SpaceOperationCoordinator(environmentIsSafe: { true }, workspaceNotificationCenter: NotificationCenter())
        var raises = 0
        let manager = makeManager(transfer: transfer, window: TestWindow(), scheduler: scheduler,
                                  coordinator: coordinator, raise: { _, _ in raises += 1 }, frontmost: { _, _ in nil })
        XCTAssertTrue(manager.execute(parameters: ExecutionParameters(.nextSpace)))
        transfer.memberships = [10]
        transfer.displayedSpace = 10
        scheduler.runUntil { !manager.isSpaceActionInProgress }
        XCTAssertEqual(raises, 21)
        XCTAssertNotNil(coordinator.begin())
    }

    func testBackgroundArrivalIsOrderedWithoutActivatingOrFollowingIt() {
        let transfer = TransferSpy()
        let window = TestWindow()
        let scheduler = MoveScheduler()
        var visible = true
        var frontmost = false
        var raises = 0
        let manager = makeManager(transfer: transfer, window: window, scheduler: scheduler,
                                  focusedWindow: { nil }, snapshot: { _ in
            SpaceWindowSnapshot(windowId: 101, pid: 42, frame: window.frame, level: 0, isOnScreen: visible)
        }, raise: { _, activate in
            XCTAssertFalse(activate)
            raises += 1
            frontmost = true
        }, frontmost: { _, _ in frontmost }, follow: { false })
        XCTAssertTrue(manager.execute(parameters: ExecutionParameters(.nextSpace, windowElement: window)))
        visible = false
        transfer.memberships = [10]
        scheduler.runUntil { !manager.isSpaceActionInProgress }
        XCTAssertEqual(raises, 1)
        XCTAssertEqual(transfer.displayedSpace, 57)
        XCTAssertEqual(transfer.events, ["move:101:10"])
    }

    func testPhysicalInputPreventsDeferredTransferOrRaisingTheMovedWindow() {
        for interruptBeforeCommit in [true, false] {
            let transfer = TransferSpy()
            let window = TestWindow()
            let scheduler = MoveScheduler()
            let input = InputMonitorSpy()
            let switcher = SwitchSpy(transfer: transfer)
            switcher.defersCommit = true
            let manager = makeManager(transfer: transfer, window: window, scheduler: scheduler,
                                      switcher: switcher, input: input)
            XCTAssertTrue(manager.execute(parameters: ExecutionParameters(.nextSpace)))
            if !interruptBeforeCommit { switcher.commit() }
            input.trigger()
            switcher.commit()
            switcher.finish()
            transfer.memberships = [10]
            transfer.displayedSpace = 10
            scheduler.runUntil { !manager.isSpaceActionInProgress }
            XCTAssertFalse(transfer.events.contains("raise"))
            XCTAssertEqual(transfer.events.contains("move:101:10"), !interruptBeforeCommit)
            XCTAssertFalse(manager.isSpaceActionInProgress)
            XCTAssertNil(input.handler)
        }
    }

    func testQueuedInputFromAnOlderMoveDoesNotCancelANewMove() throws {
        let transfer = TransferSpy()
        let scheduler = MoveScheduler()
        let input = InputMonitorSpy()
        let manager = makeManager(transfer: transfer, window: TestWindow(), scheduler: scheduler, input: input)
        XCTAssertTrue(manager.execute(parameters: ExecutionParameters(.nextSpace)))
        let staleInput = try XCTUnwrap(input.handler)
        transfer.memberships = [10]
        scheduler.runNext()
        transfer.displayedSpace = 10
        scheduler.runUntil { !manager.isSpaceActionInProgress }
        XCTAssertFalse(manager.isSpaceActionInProgress)

        transfer.memberships = [57]
        transfer.displayedSpace = 57
        XCTAssertTrue(manager.execute(parameters: ExecutionParameters(.nextSpace)))
        staleInput()
        transfer.memberships = [10]
        scheduler.runNext()
        transfer.displayedSpace = 10
        scheduler.runUntil { !manager.isSpaceActionInProgress }
        XCTAssertEqual(transfer.events.filter { $0 == "raise" }.count, 2)
        XCTAssertFalse(manager.isSpaceActionInProgress)
    }

    func testMoveDoesNotStartInMissionControlOrDuringAnotherSpaceOperation() throws {
        for missionControl in [true, false] {
            let coordinator = SpaceOperationCoordinator(environmentIsSafe: { !missionControl }, workspaceNotificationCenter: NotificationCenter())
            let operation = missionControl ? nil : try XCTUnwrap(coordinator.begin())
            let transfer = TransferSpy()
            let scheduler = MoveScheduler()
            let manager = makeManager(transfer: transfer, window: TestWindow(), scheduler: scheduler, coordinator: coordinator)
            XCTAssertTrue(manager.execute(parameters: ExecutionParameters(.nextSpace)))
            XCTAssertTrue(transfer.events.isEmpty)
            XCTAssertTrue(scheduler.actions.isEmpty)
            withExtendedLifetime(operation) {}
        }
    }

    func testMissionControlOpeningBeforeCommitPreventsTheWindowTransfer() {
        var safe = true
        let coordinator = SpaceOperationCoordinator(environmentIsSafe: { safe }, workspaceNotificationCenter: NotificationCenter())
        let transfer = TransferSpy()
        let scheduler = MoveScheduler()
        let switcher = SwitchSpy(transfer: transfer)
        switcher.defersCommit = true
        let manager = makeManager(transfer: transfer, window: TestWindow(), scheduler: scheduler,
                                  switcher: switcher, coordinator: coordinator)
        XCTAssertTrue(manager.execute(parameters: ExecutionParameters(.nextSpace)))
        safe = false
        switcher.commit()
        switcher.finish()
        scheduler.runNext()
        XCTAssertEqual(transfer.events, ["switch:switchNextSpace"])
        XCTAssertFalse(manager.isSpaceActionInProgress)
        safe = true
        XCTAssertNotNil(coordinator.begin())
    }

    func testRaiseWaitsUntilTheFollowGestureFinishes() throws {
        let transfer = TransferSpy()
        let scheduler = MoveScheduler()
        let coordinator = SpaceOperationCoordinator(environmentIsSafe: { true }, workspaceNotificationCenter: NotificationCenter())
        let switcher = SwitchSpy(transfer: transfer)
        switcher.isSpaceActionInProgress = true
        let manager = makeManager(transfer: transfer, window: TestWindow(), scheduler: scheduler,
                                  switcher: switcher, coordinator: coordinator)
        XCTAssertTrue(manager.execute(parameters: ExecutionParameters(.nextSpace)))
        transfer.memberships = [10]
        scheduler.runNext()
        let operation = try XCTUnwrap(switcher.receivedOperation)
        XCTAssertTrue(coordinator.begin(continuing: operation) === operation)
        transfer.displayedSpace = 10
        scheduler.runNext()
        XCTAssertFalse(transfer.events.contains("raise"))
        switcher.isSpaceActionInProgress = false
        scheduler.runNext()
        XCTAssertEqual(transfer.events.last, "raise")
    }

    func testChangedWindowVisibilityOrLevelPreventsRaising() {
        for hidden in [true, false] {
            let transfer = TransferSpy()
            let scheduler = MoveScheduler()
            let window = TestWindow()
            var moving = false
            let manager = makeManager(transfer: transfer, window: window, scheduler: scheduler, snapshot: { _ in
                SpaceWindowSnapshot(windowId: 101, pid: 42, frame: window.frame,
                                    level: moving && !hidden ? 3 : 0, isOnScreen: !moving || !hidden)
            })
            XCTAssertTrue(manager.execute(parameters: ExecutionParameters(.nextSpace)))
            moving = true
            transfer.memberships = [10]
            scheduler.runNext()
            transfer.displayedSpace = 10
            scheduler.runUntil { !manager.isSpaceActionInProgress }
            XCTAssertFalse(transfer.events.contains("raise"))
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
            accessibilityAuthorized: { true },
            coordinator: SpaceOperationCoordinator(environmentIsSafe: { true }, workspaceNotificationCenter: NotificationCenter()),
            physicalInputMonitor: InputMonitorSpy(), adjacentActivation: unavailableActivation(transfer), gestureTargetIsAdjacent: { _, _ in true }
        )

        XCTAssertTrue(manager.execute(parameters: ExecutionParameters(.prevSpace)))
        XCTAssertTrue(manager.execute(parameters: ExecutionParameters(.nextSpace)))
        XCTAssertTrue(transfer.events.isEmpty)
        XCTAssertTrue(scheduled.isEmpty)
    }

    func testFollowSwitchStartsWithoutWaitingForMoveConfirmation() {
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
            raiseWindow: { _, activate in transfer.events.append(activate ? "raise" : "order") }, windowIsFrontmost: { _, _ in true },
            followMovedWindowProvider: { true },
            coordinator: SpaceOperationCoordinator(environmentIsSafe: { true }, workspaceNotificationCenter: NotificationCenter()),
            physicalInputMonitor: InputMonitorSpy(), adjacentActivation: unavailableActivation(transfer), gestureTargetIsAdjacent: { _, _ in true }
        )

        XCTAssertTrue(manager.execute(parameters: ExecutionParameters(.nextSpace)))
        XCTAssertEqual(transfer.events, ["switch:switchNextSpace", "move:101:10"])
        XCTAssertEqual(scheduled.count, 1)

        transfer.memberships = [10]
        scheduled.removeFirst()()
        XCTAssertEqual(transfer.events, ["switch:switchNextSpace", "move:101:10"])
        XCTAssertEqual(scheduled.count, 1)

        transfer.displayedSpace = 10
        scheduled.removeFirst()()
        for _ in 0..<3 { scheduled.removeFirst()() }
        XCTAssertEqual(transfer.events, ["switch:switchNextSpace", "move:101:10", "raise"])
        XCTAssertTrue(scheduled.isEmpty)
    }

    func testRejectedFollowSwitchLeavesWindowOnItsOriginalSpace() {
        let transfer = TransferSpy()
        let scheduler = MoveScheduler()
        let switcher = SwitchSpy(transfer: transfer)
        switcher.acceptsSwitch = false
        let coordinator = SpaceOperationCoordinator(environmentIsSafe: { true }, workspaceNotificationCenter: NotificationCenter())
        let manager = makeManager(transfer: transfer, window: TestWindow(), scheduler: scheduler,
                                  switcher: switcher, coordinator: coordinator)

        XCTAssertTrue(manager.execute(parameters: ExecutionParameters(.nextSpace)))
        XCTAssertTrue(transfer.events.isEmpty)
        XCTAssertFalse(manager.isSpaceActionInProgress)
        XCTAssertTrue(scheduler.actions.isEmpty)
        XCTAssertNotNil(coordinator.begin())
    }

    func testCancelledFollowSwitchDoesNotSubmitALateWindowTransfer() {
        let transfer = TransferSpy()
        let scheduler = MoveScheduler()
        let switcher = SwitchSpy(transfer: transfer)
        switcher.defersCommit = true
        let manager = makeManager(transfer: transfer, window: TestWindow(), scheduler: scheduler, switcher: switcher)

        XCTAssertTrue(manager.execute(parameters: ExecutionParameters(.nextSpace)))
        XCTAssertEqual(transfer.events, ["switch:switchNextSpace"])
        switcher.finish()
        scheduler.runNext()
        switcher.commit()
        XCTAssertEqual(transfer.events, ["switch:switchNextSpace"])
        XCTAssertFalse(manager.isSpaceActionInProgress)
    }

    func testFailedTransferDoesNotRaiseTheWindowOrHoldTheOperation() {
        let transfer = TransferSpy()
        transfer.moveResult = false
        let scheduler = MoveScheduler()
        let coordinator = SpaceOperationCoordinator(environmentIsSafe: { true }, workspaceNotificationCenter: NotificationCenter())
        let manager = makeManager(transfer: transfer, window: TestWindow(), scheduler: scheduler, coordinator: coordinator)

        XCTAssertTrue(manager.execute(parameters: ExecutionParameters(.nextSpace)))
        XCTAssertEqual(transfer.events, ["switch:switchNextSpace", "move:101:10"])
        XCTAssertFalse(manager.isSpaceActionInProgress)
        XCTAssertTrue(scheduler.actions.isEmpty)
        XCTAssertNotNil(coordinator.begin())
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
            raiseWindow: { _, activate in transfer.events.append(activate ? "raise" : "order") }, windowIsFrontmost: { _, _ in true },
            followMovedWindowProvider: { followMovedWindow },
            coordinator: SpaceOperationCoordinator(environmentIsSafe: { true }, workspaceNotificationCenter: NotificationCenter()),
            physicalInputMonitor: InputMonitorSpy(), adjacentActivation: unavailableActivation(transfer), gestureTargetIsAdjacent: { _, _ in true }
        )

        XCTAssertTrue(manager.execute(parameters: ExecutionParameters(.nextSpace)))
        XCTAssertEqual(transfer.events, ["move:101:10"])
        XCTAssertEqual(scheduled.count, 1)

        // Changing the preference during an in-flight move does not change that move's behavior.
        followMovedWindow = true
        transfer.memberships = [10]
        scheduled.removeFirst()()
        for _ in 0..<3 { scheduled.removeFirst()() }
        XCTAssertEqual(transfer.events, ["move:101:10", "order"])
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
            displayIdentifierAtPoint: { _ in "main" },
            coordinator: SpaceOperationCoordinator(environmentIsSafe: { true }, workspaceNotificationCenter: NotificationCenter()),
            physicalInputMonitor: InputMonitorSpy(), adjacentActivation: unavailableActivation(transfer), gestureTargetIsAdjacent: { _, _ in true }
        )

        XCTAssertTrue(manager.execute(parameters: ExecutionParameters(.nextSpace)))
        XCTAssertTrue(transfer.events.isEmpty)
        XCTAssertTrue(scheduled.isEmpty)
    }
}

class SpaceWindowOrderTests: XCTestCase {
    private func info(_ id: CGWindowID, level: CGWindowLevel = 0, alpha: CGFloat = 1) -> WindowInfo {
        WindowInfo(id: id, level: level, frame: CGRect(x: 100, y: 100, width: 400, height: 300),
                   pid: 42, processName: "TestApp", alpha: alpha)
    }

    func testDestinationOrderIgnoresFloatingWindowsAndOtherSpacesOrDisplays() {
        let windows = [info(1, level: 27), info(2), info(3, alpha: 0), info(101), info(4)]
        XCTAssertEqual(SpaceWindowOrder.isFrontmost(windowID: 101, in: windows,
                                                   onDestination: { $0 == 101 || $0 == 4 }), true)
        XCTAssertEqual(SpaceWindowOrder.isFrontmost(windowID: 4, in: windows,
                                                   onDestination: { $0 == 101 || $0 == 4 }), false)
    }

    func testMissingWindowOrUnreadableDestinationCannotConfirmOrder() {
        XCTAssertNil(SpaceWindowOrder.isFrontmost(windowID: 101, in: [info(2)], onDestination: { _ in true }))
        XCTAssertNil(SpaceWindowOrder.isFrontmost(windowID: 101, in: [info(2), info(101)],
                                                  onDestination: { $0 == 101 ? true : nil }))
    }

    func testWindowDescriptionsCannotReorderOrOmitTheDestinationStack() {
        let descriptions = [info(101), info(2)]
        XCTAssertEqual(SpaceWindowOrder.isFrontmost(windowID: 101, orderedIDs: [2, 101],
                                                   descriptions: descriptions, onDestination: { _ in true }), false)
        XCTAssertEqual(SpaceWindowOrder.isFrontmost(windowID: 101, orderedIDs: [101, 2],
                                                   descriptions: descriptions, onDestination: { _ in true }), true)
        XCTAssertNil(SpaceWindowOrder.isFrontmost(windowID: 101, orderedIDs: [3, 101, 2],
                                                 descriptions: descriptions, onDestination: { _ in true }))
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

    func testCandidateRevalidationRejectsChangedHitRoleAndDisconnectedDisplay() throws {
        let frame = CGRect(x: 100, y: 100, width: 600, height: 400)
        let window = TestElement(role: .window, frame: frame,
                                 titleBarFrame: CGRect(x: 100, y: 100, width: 600, height: 40))
        let title = TestElement(role: .staticText, frame: frame)
        let webArea = TestElement(role: NSAccessibility.Role(rawValue: "AXWebArea"), frame: frame)
        title.testTopLevel = window; webArea.testTopLevel = window
        var hit = title
        var displays = [CGRect(x: 0, y: 0, width: 1000, height: 800)]
        let resolver = SpaceDragTargetResolver(displayFramesProvider: { displays }, systemHitTest: { _ in hit },
                                              applicationHitTest: { _, _ in hit })
        let target = try XCTUnwrap(resolver.candidates(for: window).first)
        XCTAssertTrue(resolver.isValid(target, for: window))
        hit = webArea
        XCTAssertFalse(resolver.isValid(target, for: window))
        hit = title
        displays = []
        XCTAssertFalse(resolver.isValid(target, for: window))
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
        var currentSpaceID: UInt64 = 57
        var changesSpace = true
        private(set) var directions = [SpaceDirection]()
        private(set) var phases = [SpaceGesturePhase]()
        private(set) var discardCount = 0
        var onPost: ((SpaceGesturePhase) -> Void)?

        func prepare(direction: SpaceDirection) -> Bool {
            directions.append(direction)
            return prepareResult
        }

        func post(_ phase: SpaceGesturePhase) -> Bool {
            phases.append(phase)
            onPost?(phase)
            if phase == .ended, phase != failedPhase, changesSpace { currentSpaceID += 1 }
            return phase != failedPhase
        }

        func discardPreparedEvents() {
            discardCount += 1
        }
    }

    private final class SchedulerSpy {
        private(set) var delays = [TimeInterval]()
        private var actions = [(TimeInterval, () -> Void)]()
        var now: TimeInterval = 0

        func schedule(delay: TimeInterval, action: @escaping () -> Void) {
            delays.append(delay)
            actions.append((now + delay, action))
        }

        func runNext(file: StaticString = #filePath, line: UInt = #line) {
            guard !actions.isEmpty else {
                XCTFail("Expected a scheduled Space switch phase", file: file, line: line)
                return
            }
            let (time, action) = actions.removeFirst()
            now = max(now, time)
            action()
        }
    }

    private final class InputMonitorSpy: SpacePhysicalInputMonitoring {
        var handler: (() -> Void)?
        func start(_ handler: @escaping () -> Void) { self.handler = handler }
        func stop() { handler = nil }
        func trigger() { handler?() }
    }

    private func makeSwitcher(poster: PosterSpy, scheduler: SchedulerSpy,
                              coordinator: SpaceOperationCoordinator = SpaceOperationCoordinator(environmentIsSafe: { true }, workspaceNotificationCenter: NotificationCenter()),
                              currentSpace: ((NSScreen?) -> UInt64?)? = nil,
                              mousePressed: @escaping () -> Bool = { false },
                              input: InputMonitorSpy = InputMonitorSpy()) -> SpaceSwitcher {
        SpaceSwitcher(eventPoster: poster, scheduler: scheduler.schedule, neighborAvailable: { _, _ in true },
                      coordinator: coordinator, currentSpaceProvider: currentSpace ?? { _ in poster.currentSpaceID },
                      leftMouseButtonPressed: mousePressed, physicalInputMonitor: input, clock: { scheduler.now },
                      workspaceNotificationCenter: NotificationCenter())
    }

    func testFollowedTransferRunsImmediatelyBeforeTheCommittingGesturePhase() {
        for phaseDelay in [0.0, 0.01] {
            let poster = PosterSpy()
            poster.phaseDelay = phaseDelay
            let scheduler = SchedulerSpy()
            let switcher = makeSwitcher(poster: poster, scheduler: scheduler)
            var events = [String]()
            poster.onPost = { events.append("phase:\($0)") }
            XCTAssertTrue(switcher.execute(parameters: ExecutionParameters(.switchNextSpace), continuing: nil,
                                           beforeSwitch: { events.append("transfer") }))
            if phaseDelay > 0 {
                XCTAssertEqual(events, ["phase:began"])
                scheduler.runNext()
                XCTAssertEqual(events, ["phase:began", "phase:changed"])
                scheduler.runNext()
            }
            XCTAssertEqual(events, ["phase:began", "phase:changed", "transfer", "phase:ended"])
            scheduler.runNext()
            XCTAssertFalse(switcher.isSpaceActionInProgress)
            XCTAssertEqual(events.filter { $0 == "transfer" }.count, 1)
        }
    }

    func testInterruptingTheFollowGestureNeverRunsItsPendingTransfer() {
        for interruptAfterChanged in [false, true] {
            let poster = PosterSpy()
            let scheduler = SchedulerSpy()
            let input = InputMonitorSpy()
            let switcher = makeSwitcher(poster: poster, scheduler: scheduler, input: input)
            var transfers = 0
            XCTAssertTrue(switcher.execute(parameters: ExecutionParameters(.switchNextSpace), continuing: nil,
                                           beforeSwitch: { transfers += 1 }))
            if interruptAfterChanged { scheduler.runNext() }
            input.trigger()
            scheduler.runNext()
            XCTAssertEqual(transfers, 0)
            XCTAssertFalse(switcher.isSpaceActionInProgress)
            XCTAssertEqual(poster.phases.last, .ended)
        }
    }

    func testFailedGesturePreparationDoesNotRetainThePendingTransfer() {
        let poster = PosterSpy()
        poster.prepareResult = false
        let scheduler = SchedulerSpy()
        let switcher = makeSwitcher(poster: poster, scheduler: scheduler)
        var transfers = 0
        XCTAssertTrue(switcher.execute(parameters: ExecutionParameters(.switchNextSpace), continuing: nil,
                                       beforeSwitch: { transfers += 1 }))
        poster.prepareResult = true
        XCTAssertTrue(switcher.execute(parameters: ExecutionParameters(.switchNextSpace)))
        for _ in 0..<3 { scheduler.runNext() }
        XCTAssertEqual(transfers, 0)
    }

    func testSeparateSwitchersCannotInterleaveTheirGestures() {
        let coordinator = SpaceOperationCoordinator(environmentIsSafe: { true }, workspaceNotificationCenter: NotificationCenter())
        let firstPoster = PosterSpy()
        let secondPoster = PosterSpy()
        let scheduler = SchedulerSpy()
        let first = makeSwitcher(poster: firstPoster, scheduler: scheduler, coordinator: coordinator)
        let second = makeSwitcher(poster: secondPoster, scheduler: scheduler, coordinator: coordinator)
        XCTAssertTrue(first.execute(parameters: ExecutionParameters(.switchNextSpace)))
        XCTAssertTrue(second.execute(parameters: ExecutionParameters(.switchPrevSpace)))
        XCTAssertTrue(secondPoster.phases.isEmpty)
        scheduler.runNext()
        scheduler.runNext()
        scheduler.runNext()
        XCTAssertTrue(second.execute(parameters: ExecutionParameters(.switchPrevSpace)))
        XCTAssertEqual(secondPoster.phases, [.began])
    }

    func testMoveAndItsFollowGestureExcludeDirectSwitchesUntilBothFinish() throws {
        final class UnavailableActivation: ManagedDisplaySpaceActivating {
            let isAvailable = false
            func desktop(number: Int) -> ManagedDisplaySpaceSwitch? { nil }
            func currentSpace(on displayIdentifier: String) -> UInt64? { nil }
            func destinationIsVisible(_ target: ManagedDisplaySpaceSwitch) -> Bool? { nil }
            func activate(_ target: ManagedDisplaySpaceSwitch) -> Bool { false }
        }
        final class Window: AccessibilityElement {
            override var windowId: CGWindowID? { 101 }
            override var frame: CGRect { CGRect(x: 100, y: 100, width: 500, height: 300) }
            override var isSheet: Bool? { false }
            override var isModal: Bool? { false }
            override var isMinimized: Bool? { false }
            override var isFullScreen: Bool? { false }
            init() { super.init(AXUIElementCreateSystemWide()) }
        }
        final class Transfer: WindowSpaceTransferring {
            var isAvailable = true
            var memberships: [UInt64]? = [57]
            let current: () -> UInt64
            init(current: @escaping () -> UInt64) { self.current = current }
            func spaces(for windowID: CGWindowID) -> [UInt64]? { memberships }
            func adjacentSpace(for windowID: CGWindowID, direction: SpaceDirection) -> AdjacentManagedSpace? {
                AdjacentManagedSpace(sourceID: 57, destinationID: 58, displayIdentifier: "display")
            }
            func currentSpace(for displayIdentifier: String) -> UInt64? { current() }
            func move(windowID: CGWindowID, to spaceID: UInt64) -> Bool { memberships = [spaceID]; return true }
        }
        let coordinator = SpaceOperationCoordinator(environmentIsSafe: { true }, workspaceNotificationCenter: NotificationCenter())
        let poster = PosterSpy()
        let directPoster = PosterSpy()
        let scheduler = SchedulerSpy()
        let follow = makeSwitcher(poster: poster, scheduler: scheduler, coordinator: coordinator)
        let direct = makeSwitcher(poster: directPoster, scheduler: scheduler, coordinator: coordinator)
        let window = Window()
        let cursor = try XCTUnwrap(CGEvent(source: nil)).location
        let screen = try XCTUnwrap(NSScreen.screens.first { $0.frame.screenFlipped.contains(cursor) })
        let transfer = Transfer(current: { poster.currentSpaceID })
        var raises = 0
        let move = BridgedSpaceManager(
            transfer: transfer, switcher: follow, scheduler: scheduler.schedule,
            frontWindowProvider: { window },
            windowSnapshotProvider: { _ in SpaceWindowSnapshot(windowId: 101, pid: 42, frame: window.frame, level: 0, isOnScreen: true) },
            accessibilityAuthorized: { true }, screenProvider: { _ in screen },
            displayIdentifierAtPoint: { _ in "display" }, raiseWindow: { _, _ in raises += 1 }, windowIsFrontmost: { _, _ in true },
            followMovedWindowProvider: { true }, coordinator: coordinator, physicalInputMonitor: InputMonitorSpy(),
            adjacentActivation: UnavailableActivation(), gestureTargetIsAdjacent: { _, _ in true }
        )
        XCTAssertTrue(move.execute(parameters: ExecutionParameters(.nextSpace)))
        XCTAssertEqual(poster.phases, [.began])
        XCTAssertTrue(direct.execute(parameters: ExecutionParameters(.switchPrevSpace)))
        XCTAssertTrue(directPoster.phases.isEmpty)
        for _ in 0..<8 {
            if !follow.isSpaceActionInProgress { break }
            scheduler.runNext()
        }
        XCTAssertFalse(follow.isSpaceActionInProgress)
        XCTAssertTrue(move.isSpaceActionInProgress)
        XCTAssertTrue(direct.execute(parameters: ExecutionParameters(.switchPrevSpace)))
        XCTAssertTrue(directPoster.phases.isEmpty)
        scheduler.runNext()
        for _ in 0..<3 { scheduler.runNext() }
        XCTAssertEqual(raises, 1)
        XCTAssertFalse(move.isSpaceActionInProgress)
        XCTAssertTrue(direct.execute(parameters: ExecutionParameters(.switchPrevSpace)))
        XCTAssertEqual(directPoster.phases, [.began])
    }

    func testPhysicalInputEndsTheGestureAndReleasesTheOperation() {
        let coordinator = SpaceOperationCoordinator(environmentIsSafe: { true }, workspaceNotificationCenter: NotificationCenter())
        let poster = PosterSpy()
        let scheduler = SchedulerSpy()
        let input = InputMonitorSpy()
        let switcher = makeSwitcher(poster: poster, scheduler: scheduler, coordinator: coordinator, input: input)
        XCTAssertTrue(switcher.execute(parameters: ExecutionParameters(.switchNextSpace)))
        input.trigger()
        XCTAssertEqual(poster.phases, [.began, .ended])
        XCTAssertFalse(switcher.isSpaceActionInProgress)
        XCTAssertNil(input.handler)
        XCTAssertNotNil(coordinator.begin())
        scheduler.runNext()
        XCTAssertEqual(poster.phases, [.began, .ended])
    }

    func testOperationRemainsHeldUntilTheDisplayedSpaceChanges() {
        let poster = PosterSpy()
        poster.changesSpace = false
        let scheduler = SchedulerSpy()
        let switcher = makeSwitcher(poster: poster, scheduler: scheduler)
        XCTAssertTrue(switcher.execute(parameters: ExecutionParameters(.switchNextSpace)))
        scheduler.runNext()
        scheduler.runNext()
        scheduler.runNext()
        XCTAssertTrue(switcher.isSpaceActionInProgress)
        XCTAssertTrue(switcher.execute(parameters: ExecutionParameters(.switchPrevSpace)))
        XCTAssertEqual(poster.directions, [.next])
        poster.currentSpaceID += 1
        scheduler.runNext()
        XCTAssertFalse(switcher.isSpaceActionInProgress)
    }

    func testSpaceConfirmationTimeoutReleasesOperation() {
        let coordinator = SpaceOperationCoordinator(environmentIsSafe: { true }, workspaceNotificationCenter: NotificationCenter())
        let poster = PosterSpy()
        poster.changesSpace = false
        let scheduler = SchedulerSpy()
        let switcher = makeSwitcher(poster: poster, scheduler: scheduler, coordinator: coordinator)
        XCTAssertTrue(switcher.execute(parameters: ExecutionParameters(.switchNextSpace)))
        for _ in 0..<160 {
            if !switcher.isSpaceActionInProgress { break }
            scheduler.runNext()
        }
        XCTAssertFalse(switcher.isSpaceActionInProgress)
        XCTAssertNotNil(coordinator.begin())
        XCTAssertEqual(poster.phases, [.began, .changed, .ended])
    }

    func testMissionControlInterruptsAndEndsAPacedGesture() {
        var safe = true
        let coordinator = SpaceOperationCoordinator(environmentIsSafe: { safe }, workspaceNotificationCenter: NotificationCenter())
        let poster = PosterSpy()
        let scheduler = SchedulerSpy()
        let switcher = makeSwitcher(poster: poster, scheduler: scheduler, coordinator: coordinator)
        XCTAssertTrue(switcher.execute(parameters: ExecutionParameters(.switchNextSpace)))
        safe = false
        scheduler.runNext()
        XCTAssertEqual(poster.phases, [.began, .ended])
        XCTAssertFalse(switcher.isSpaceActionInProgress)
        safe = true
        XCTAssertNotNil(coordinator.begin())
    }

    func testFailedPhaseAndDeinitCloseBegunGestures() {
        for deinitializing in [true, false] {
            let coordinator = SpaceOperationCoordinator(environmentIsSafe: { true }, workspaceNotificationCenter: NotificationCenter())
            let poster = PosterSpy()
            let scheduler = SchedulerSpy()
            var switcher: SpaceSwitcher? = makeSwitcher(poster: poster, scheduler: scheduler, coordinator: coordinator)
            XCTAssertTrue(switcher!.execute(parameters: ExecutionParameters(.switchNextSpace)))
            if deinitializing {
                switcher = nil
                XCTAssertEqual(poster.phases, [.began, .ended])
            } else {
                poster.failedPhase = .changed
                scheduler.runNext()
                XCTAssertEqual(poster.phases, [.began, .changed, .ended])
            }
            XCTAssertNotNil(coordinator.begin())
            XCTAssertEqual(poster.discardCount, 1)
        }
    }

    func testPreflightFailuresAndMissionControlNeverPostAGesture() {
        for failure in 0..<4 {
            let coordinator = SpaceOperationCoordinator(environmentIsSafe: { failure != 0 }, workspaceNotificationCenter: NotificationCenter())
            let poster = PosterSpy()
            poster.prepareResult = failure != 1
            let scheduler = SchedulerSpy()
            let switcher = makeSwitcher(poster: poster, scheduler: scheduler, coordinator: coordinator,
                                         currentSpace: { _ in failure == 2 ? nil : 57 },
                                         mousePressed: { failure == 3 })
            XCTAssertTrue(switcher.execute(parameters: ExecutionParameters(.switchNextSpace)))
            XCTAssertTrue(poster.phases.isEmpty)
            if failure != 0 { XCTAssertNotNil(coordinator.begin()) }
        }
    }

    func testPostsTinycastPhasesAndDropsOverlappingSwitch() {
        let poster = PosterSpy()
        let scheduler = SchedulerSpy()
        let switcher = SpaceSwitcher(eventPoster: poster, scheduler: scheduler.schedule,
                                    neighborAvailable: { _, _ in true },
                                    coordinator: SpaceOperationCoordinator(environmentIsSafe: { true }, workspaceNotificationCenter: NotificationCenter()),
                                    currentSpaceProvider: { _ in poster.currentSpaceID }, leftMouseButtonPressed: { false }, physicalInputMonitor: InputMonitorSpy())

        XCTAssertTrue(switcher.execute(parameters: ExecutionParameters(.switchNextSpace)))
        XCTAssertEqual(poster.directions, [.next])
        XCTAssertEqual(poster.phases, [.began])
        XCTAssertTrue(switcher.execute(parameters: ExecutionParameters(.switchPrevSpace)))
        XCTAssertEqual(poster.directions, [.next])

        scheduler.runNext()
        scheduler.runNext()
        XCTAssertEqual(poster.phases, [.began, .changed, .ended])
        XCTAssertEqual(scheduler.delays, [0.01, 0.01, 0.01])

        scheduler.runNext()
        XCTAssertEqual(poster.discardCount, 1)
        XCTAssertTrue(switcher.execute(parameters: ExecutionParameters(.switchPrevSpace)))
        XCTAssertEqual(poster.directions, [.next, .previous])
    }

    func testIgnoresWindowMoveActionsAndRequiresAccessibility() {
        let poster = PosterSpy()
        let scheduler = SchedulerSpy()
        let switcher = SpaceSwitcher(eventPoster: poster, scheduler: scheduler.schedule,
                                    neighborAvailable: { _, _ in true },
                                    coordinator: SpaceOperationCoordinator(environmentIsSafe: { true }, workspaceNotificationCenter: NotificationCenter()),
                                    currentSpaceProvider: { _ in poster.currentSpaceID }, leftMouseButtonPressed: { false }, physicalInputMonitor: InputMonitorSpy())

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
                neighborAvailable: { _, _ in hasNeighbor },
                coordinator: SpaceOperationCoordinator(environmentIsSafe: { true }, workspaceNotificationCenter: NotificationCenter()),
                currentSpaceProvider: { _ in poster.currentSpaceID }, leftMouseButtonPressed: { false }, physicalInputMonitor: InputMonitorSpy()
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

class BandTilingTests: XCTestCase {

    private typealias Manager = MultiWindowManager

    private func applyBandTiling(_ windows: [Manager.TilingWindow], bounds: Manager.BackingPixelBounds,
                                direction: Manager.BandDirection, constraints: [Manager.BandConstraint],
                                pointFrame: (CGRect) -> CGRect, backingFrame: (CGRect) -> CGRect) {
        let cross = GridTiling.Constraint.resizable(minimum: 0, maximum: bounds.extent(direction.cross))
        let sizes = constraints.map { primary in
            direction == .rows
                ? GridTiling.WindowConstraints(width: cross, height: primary)
                : GridTiling.WindowConstraints(width: primary, height: cross)
        }
        _ = GridTiling.apply(observedFrames: windows.map { backingFrame($0.element.frame) }, bounds: bounds,
                             direction: direction, subdivision: 1, constraints: sizes) { index, frame in
            windows[index].element.setFrame(pointFrame(frame))
            return backingFrame(windows[index].element.frame)
        }
    }

    private final class TestElement: AccessibilityElement {
        private var acceptedFrame: CGRect
        private(set) var setFrameCalls = 0
        let minimumHeight: CGFloat
        let maximumWidth: CGFloat
        let minimumHeightAtOrigin: (CGFloat) -> CGFloat
        let testWindowId: CGWindowID?
        var testIdentity: CFHashCode
        let reportedMinimumSize: CGSize?
        let canResize: Bool
        let ordinaryWindow: Bool
        var reportedFrameAfterWrite: CGRect?

        init(frame: CGRect = .zero, minimumHeight: CGFloat = 0, maximumWidth: CGFloat = .greatestFiniteMagnitude,
             minimumHeightAtOrigin: @escaping (CGFloat) -> CGFloat = { _ in 0 },
             windowId: CGWindowID? = nil, identity: CFHashCode = 0,
             reportedMinimumSize: CGSize? = .zero, canResize: Bool = true, ordinaryWindow: Bool = true) {
            acceptedFrame = frame
            self.minimumHeight = minimumHeight
            self.maximumWidth = maximumWidth
            self.minimumHeightAtOrigin = minimumHeightAtOrigin
            testWindowId = windowId
            testIdentity = identity
            self.reportedMinimumSize = reportedMinimumSize
            self.canResize = canResize
            self.ordinaryWindow = ordinaryWindow
            super.init(identity == 0 ? AXUIElementCreateSystemWide()
                                     : AXUIElementCreateApplication(pid_t(10_000 + identity)))
        }

        override var frame: CGRect { setFrameCalls > 0 ? reportedFrameAfterWrite ?? acceptedFrame : acceptedFrame }
        override var windowId: CGWindowID? { testWindowId }
        override var pid: pid_t? { 42 }
        override var minimumSize: CGSize? { reportedMinimumSize }
        override func isResizable() -> Bool { canResize }
        override var isWindow: Bool? { ordinaryWindow }
        override var isSheet: Bool? { false }
        override var isMinimized: Bool? { false }
        override var isHidden: Bool? { false }
        override var isSystemDialog: Bool? { false }

        override func setFrame(_ frame: CGRect, adjustSizeFirst: Bool = true, adjustPosition: Bool = true) {
            setFrameCalls += 1
            let originalOrigin = acceptedFrame.origin
            acceptedFrame = frame
            if !adjustPosition { acceptedFrame.origin = originalOrigin }
            acceptedFrame.size.height = max(frame.height, minimumHeight, minimumHeightAtOrigin(frame.minY))
            acceptedFrame.size.width = min(frame.width, maximumWidth)
        }
    }

    private func candidate(_ element: TestElement, frame: CGRect, identity: CFHashCode,
                           pid: pid_t = 42, windowId: CGWindowID? = nil, focused: Bool = false) -> Manager.TilingWindow {
        element.testIdentity = identity
        return Manager.TilingWindow(element: element, frame: frame, windowId: windowId, pid: pid,
                                    isFocused: focused)
    }

    private func testLabel(_ window: Manager.TilingWindow) -> CFHashCode {
        (window.element as! TestElement).testIdentity
    }

    private func visible(_ id: CGWindowID, frame: CGRect, pid: pid_t = 42) -> WindowInfo {
        WindowInfo(id: id, level: 0, frame: frame, pid: pid, processName: nil)
    }

    private func scaled(_ rect: CGRect, by scale: CGFloat) -> CGRect {
        CGRect(x: rect.minX * scale, y: rect.minY * scale,
               width: rect.width * scale, height: rect.height * scale)
    }

    private final class TestScreen: NSScreen {
        private let testFrame: CGRect

        init(frame: CGRect) {
            testFrame = frame
            super.init()
        }

        override var frame: NSRect { testFrame }
        override var visibleFrame: NSRect { testFrame }
        override var safeAreaInsets: NSEdgeInsets { NSEdgeInsetsZero }
        override var backingScaleFactor: CGFloat { 1 }
        override func convertRectToBacking(_ rect: NSRect) -> NSRect { rect }
        override func convertRectFromBacking(_ rect: NSRect) -> NSRect { rect }
        override var hash: Int { ObjectIdentifier(self).hashValue }
        override func isEqual(_ object: Any?) -> Bool { (object as AnyObject?) === self }
    }

    private final class TestScreenDetection: ScreenDetection {
        let screens: [NSScreen]
        let cursorScreen: NSScreen
        private(set) var cursorDetections = 0

        init(screens: [NSScreen], cursorScreen: NSScreen) {
            self.screens = screens
            self.cursorScreen = cursorScreen
        }

        override func detectScreens(using window: AccessibilityElement?) -> UsableScreens? {
            window.flatMap { screenContaining($0.frame, screens: screens) }.map {
                UsableScreens(currentScreen: $0, numScreens: screens.count)
            }
        }

        override func detectScreensAtCursor() -> UsableScreens? {
            cursorDetections += 1
            return UsableScreens(currentScreen: cursorScreen, numScreens: screens.count)
        }
    }

    func testTilingUsesFocusedDisplayOrPointerFallback() throws {
        if Defaults.todo.userEnabled, Defaults.todoMode.enabled {
            return // skip testing with todo mode enabled to avoid a crash with screen comparison against mock screen
        }
        
        let left = TestScreen(frame: CGRect(x: -900, y: 0, width: 900, height: 600))
        let right = TestScreen(frame: CGRect(x: 0, y: 0, width: 900, height: 600))

        for cursorScreen in [left, right] {
            let otherScreen = cursorScreen === left ? right : left
            for hasFocus in [true, false] {
                for action in [WindowAction.tileAll, .tileRows, .tileColumns] {
                    let focused = TestElement(frame: otherScreen.frame.insetBy(dx: 100, dy: 100).screenFlipped,
                                              windowId: 101, identity: 1)
                    let underPointer = TestElement(frame: cursorScreen.frame.insetBy(dx: 100, dy: 100).screenFlipped,
                                                   windowId: 102, identity: 2)
                    let detection = TestScreenDetection(screens: [left, right], cursorScreen: cursorScreen)
                    let context = try XCTUnwrap(Manager.tilingContext(focusedWindow: hasFocus ? focused : nil,
                                                                      screenDetection: detection))
                    let expectedScreen = hasFocus ? otherScreen : cursorScreen
                    XCTAssertTrue(context.screens.currentScreen === expectedScreen)
                    XCTAssertEqual(detection.cursorDetections, hasFocus ? 0 : 1)
                    let windows = Manager.windowsOnScreen(screens: context.screens,
                                                          windows: [focused, underPointer],
                                                          screenFor: { detection.detectScreens(using: $0)?.currentScreen }).windows
                    let visibleInfo = [visible(101, frame: focused.frame), visible(102, frame: underPointer.frame)]
                    switch action {
                    case .tileRows, .tileColumns:
                        Manager.tileWindowsInBands(action == .tileRows ? .rows : .columns,
                                                   focusedWindow: context.focusedWindow, windows: windows,
                                                   visibleWindowInfo: visibleInfo, screen: context.screens.currentScreen,
                                                   visibleFrame: context.screens.currentScreen.frame)
                    case .tileAll:
                        Manager.tileAllWindowsOnScreen(windows: windows, screen: context.screens.currentScreen)
                    default:
                        XCTFail("Unexpected tiling action")
                    }
                    XCTAssertGreaterThan((hasFocus ? focused : underPointer).setFrameCalls, 0)
                    XCTAssertEqual((hasFocus ? underPointer : focused).setFrameCalls, 0)
                }
            }
        }
    }

    func testNonWindowFocusUsesPointerDisplay() throws {
        let screen = TestScreen(frame: CGRect(x: 0, y: 0, width: 900, height: 600))
        let desktop = TestElement(frame: screen.frame, ordinaryWindow: false)
        let detection = TestScreenDetection(screens: [screen], cursorScreen: screen)
        let context = try XCTUnwrap(Manager.tilingContext(focusedWindow: desktop, screenDetection: detection))
        XCTAssertNil(context.focusedWindow)
        XCTAssertTrue(context.screens.currentScreen === screen)
        XCTAssertEqual(detection.cursorDetections, 1)
        XCTAssertEqual(desktop.setFrameCalls, 0)
    }

    func testBandTilingWithoutFocusStillRequiresCurrentSpaceEvidence() {
        let screen = TestScreen(frame: CGRect(x: 0, y: 0, width: 900, height: 600))
        let frame = screen.frame.insetBy(dx: 100, dy: 100).screenFlipped
        for direction in [Manager.BandDirection.rows, .columns] {
            let currentSpace = TestElement(frame: frame, windowId: 101, identity: 1)
            let otherSpace = TestElement(frame: frame, windowId: 999, identity: 2)
            Manager.tileWindowsInBands(direction, focusedWindow: nil, windows: [currentSpace, otherSpace],
                                       visibleWindowInfo: [visible(101, frame: frame)], screen: screen,
                                       visibleFrame: screen.frame)
            XCTAssertGreaterThan(currentSpace.setFrameCalls, 0)
            XCTAssertEqual(otherSpace.setFrameCalls, 0)
        }
    }

    func testSharedMultiWindowSelectionExcludesOtherSpacesBeforeAnyLayout() {
        let screen = TestScreen(frame: CGRect(x: 0, y: 0, width: 900, height: 600))
        let frame = screen.frame.insetBy(dx: 100, dy: 100).screenFlipped
        let focused = TestElement(frame: frame, windowId: 101, identity: 1)
        let covered = TestElement(frame: frame, windowId: 102, identity: 2)
        let otherSpace = TestElement(frame: frame, windowId: 999, identity: 3)
        let invalid = TestElement(frame: .null, windowId: 103, identity: 4)
        let selected = Manager.windowsOnScreen(screens: UsableScreens(currentScreen: screen, numScreens: 1),
            windows: [covered, otherSpace, invalid], focusedWindow: focused,
            visibleWindowInfo: [visible(102, frame: frame), visible(103, frame: .null)],
            isActiveTodoWindow: { _ in false }, screenFor: { _ in screen }).windows
        XCTAssertEqual(selected.map(\.windowId), [102, 101])
        Manager.tileAllWindowsOnScreen(windows: selected, screen: screen)
        XCTAssertGreaterThan(covered.setFrameCalls, 0)
        XCTAssertGreaterThan(focused.setFrameCalls, 0)
        XCTAssertEqual(otherSpace.setFrameCalls, 0)
        XCTAssertEqual(invalid.setFrameCalls, 0)
    }

    func testBandTilingHandlesAnInvalidAXFrameAfterPlacement() {
        let screen = TestScreen(frame: CGRect(x: 0, y: 0, width: 900, height: 600))
        let window = TestElement(frame: screen.frame.insetBy(dx: 100, dy: 100).screenFlipped, windowId: 101, identity: 1)
        window.reportedFrameAfterWrite = CGRect(x: CGFloat.nan, y: 100, width: 300, height: 200)
        Manager.tileWindowsInBands(.rows, focusedWindow: nil, windows: [window],
                                  visibleWindowInfo: [visible(101, frame: window.frame)], screen: screen, visibleFrame: screen.frame)
        XCTAssertEqual(window.setFrameCalls, 1)
    }

    func testEmptyPointerDisplayDoesNotMoveWindowsOnAnotherDisplay() throws {
        let emptyScreen = TestScreen(frame: CGRect(x: -900, y: 0, width: 900, height: 600))
        let occupiedScreen = TestScreen(frame: CGRect(x: 0, y: 0, width: 900, height: 600))
        let window = TestElement(frame: occupiedScreen.frame.insetBy(dx: 100, dy: 100).screenFlipped,
                                 windowId: 101, identity: 1)
        let detection = TestScreenDetection(screens: [emptyScreen, occupiedScreen], cursorScreen: emptyScreen)
        let context = try XCTUnwrap(Manager.tilingContext(focusedWindow: nil, screenDetection: detection))
        let windows = Manager.windowsOnScreen(screens: context.screens, windows: [window],
                                              screenFor: { detection.detectScreens(using: $0)?.currentScreen }).windows
        XCTAssertTrue(windows.isEmpty)
        for direction in [Manager.BandDirection.rows, .columns] {
            Manager.tileWindowsInBands(direction, focusedWindow: nil, windows: windows,
                                       visibleWindowInfo: [visible(101, frame: window.frame)], screen: emptyScreen,
                                       visibleFrame: emptyScreen.frame)
        }
        Manager.tileAllWindowsOnScreen(windows: windows, screen: emptyScreen)
        XCTAssertEqual(window.setFrameCalls, 0)
    }

    func testSelectionKeepsCoveredWindowsAndIdenticalOnScreenTwinsWithoutOtherSpaceWindows() {
        let sameFrame = CGRect(x: 10, y: 20, width: 200, height: 200)
        let first = candidate(TestElement(), frame: sameFrame, identity: 1, focused: true)
        let second = candidate(TestElement(), frame: sameFrame, identity: 2)
        let twoVisible = [visible(101, frame: sameFrame), visible(102, frame: sameFrame)]
        XCTAssertEqual(Manager.selectCurrentSpaceWindows([first, second], visibleWindowInfo: twoVisible)
            .map(testLabel), [1, 2])
        XCTAssertEqual(Manager.selectCurrentSpaceWindows([first, second], visibleWindowInfo: [twoVisible[0]])
            .map(testLabel), [1])

        let coveredFrame = CGRect(x: 300, y: 20, width: 200, height: 200)
        let covered = candidate(TestElement(), frame: coveredFrame, identity: 3)
        XCTAssertEqual(Manager.selectCurrentSpaceWindows([first, covered],
            visibleWindowInfo: [twoVisible[0], visible(103, frame: coveredFrame)])
            .map(testLabel), [1, 3])
    }

    func testIdlessSelectionDoesNotUseAnotherAppAsCurrentSpaceEvidence() {
        let focusedFrame = CGRect(x: 10, y: 20, width: 200, height: 200)
        let otherSpaceFrame = CGRect(x: 300, y: 20, width: 200, height: 200)
        let focused = candidate(TestElement(), frame: focusedFrame, identity: 1,
                                windowId: 101, focused: true)
        let otherSpace = candidate(TestElement(), frame: otherSpaceFrame, identity: 2)
        let onScreen = [visible(101, frame: focusedFrame),
                        visible(201, frame: otherSpaceFrame, pid: 43)]

        XCTAssertEqual(Manager.selectCurrentSpaceWindows([focused, otherSpace],
                                                         visibleWindowInfo: onScreen)
            .map(testLabel), [1])
    }

    func testSelectionUsesRawIdsAndAccountsForIdentifiedSameFrameWindows() {
        let frame = CGRect(x: 10, y: 20, width: 200, height: 200)
        let identified = candidate(TestElement(), frame: frame, identity: 1, windowId: 101)
        let unidentified = candidate(TestElement(), frame: frame, identity: 2)
        let otherSpace = candidate(TestElement(), frame: frame, identity: 3, windowId: 999)
        let onScreen = [visible(101, frame: frame), visible(102, frame: frame)]

        XCTAssertEqual(Manager.selectCurrentSpaceWindows([identified, unidentified, otherSpace],
                        visibleWindowInfo: onScreen).map(testLabel), [1, 2])
        XCTAssertEqual(Manager.selectCurrentSpaceWindows([identified, unidentified, otherSpace],
                        visibleWindowInfo: [onScreen[0]]).map(testLabel), [1])
    }

    func testIdlessSelectionToleratesFrameRoundingWithoutReusingAnIdentifiedCGWindow() {
        let axFrame = CGRect(x: 300.5, y: 20, width: 200.5, height: 200)
        let cgFrame = CGRect(x: 301, y: 20, width: 201, height: 200)
        let current = candidate(TestElement(), frame: axFrame, identity: 1)
        let onScreen = visible(101, frame: cgFrame)

        XCTAssertEqual(Manager.selectCurrentSpaceWindows([current], visibleWindowInfo: [onScreen],
                                                         frameTolerance: 0.5).map(testLabel), [1])

        let identified = candidate(TestElement(), frame: axFrame, identity: 2, windowId: 101)
        let otherSpace = candidate(TestElement(), frame: cgFrame, identity: 3)
        XCTAssertEqual(Manager.selectCurrentSpaceWindows([identified, otherSpace],
                                                         visibleWindowInfo: [onScreen],
                                                         frameTolerance: 0.5).map(testLabel), [2])

        let focused = candidate(TestElement(), frame: axFrame, identity: 4, focused: true)
        XCTAssertEqual(Manager.selectCurrentSpaceWindows([focused, otherSpace],
                                                         visibleWindowInfo: [onScreen],
                                                         frameTolerance: 0.5).map(testLabel), [4])
    }

    func testIdlessSelectionAppliesRoundingToleranceToEachFrameComponent() {
        let frame = CGRect(x: -300, y: -20, width: 200, height: 100)
        let window = candidate(TestElement(), frame: frame, identity: 1)
        let roundedFrames = [
            CGRect(x: -299.5, y: -19.5, width: 200.5, height: 100.5),
            CGRect(x: -300.5, y: -20.5, width: 199.5, height: 99.5)
        ]
        for rounded in roundedFrames {
            XCTAssertEqual(Manager.selectCurrentSpaceWindows([window],
                visibleWindowInfo: [visible(101, frame: rounded)], frameTolerance: 0.5).map(testLabel), [1])
        }

        // No single component may exceed the tolerance, even if changes to
        // position and size cancel out at the far edge.
        let differentFrames = [
            CGRect(x: -299.25, y: -20, width: 199.25, height: 100),
            CGRect(x: -300, y: -19.25, width: 200, height: 99.25),
            CGRect(x: -300.5, y: -20, width: 200.75, height: 100),
            CGRect(x: -300, y: -20.5, width: 200, height: 100.75)
        ]
        for different in differentFrames {
            XCTAssertTrue(Manager.selectCurrentSpaceWindows([window],
                visibleWindowInfo: [visible(101, frame: different)], frameTolerance: 0.5).isEmpty)
        }
    }

    func testSelectionIncludesDistinctMatchesAcrossOverlappingTolerance() {
        let frames = [CGFloat(0), 0.5, 1].map {
            CGRect(x: $0, y: 20, width: 100, height: 100)
        }
        let candidates = frames.enumerated().map { index, frame in
            candidate(TestElement(), frame: frame, identity: CFHashCode(index + 1), focused: index == 0)
        }
        let onScreen = frames.enumerated().map { index, frame in
            visible(CGWindowID(index + 101), frame: frame)
        }
        XCTAssertEqual(Manager.selectCurrentSpaceWindows(candidates, visibleWindowInfo: onScreen,
                                                         frameTolerance: 0.5).map(testLabel), [1, 2, 3])

        let shared = candidate(TestElement(), frame: frames[1], identity: 4)
        let onlyFirst = candidate(TestElement(), frame: frames[0], identity: 5)
        XCTAssertEqual(Manager.selectCurrentSpaceWindows([shared, onlyFirst],
                                                         visibleWindowInfo: [onScreen[0], onScreen[2]],
                                                         frameTolerance: 0.5).map(testLabel), [4, 5])
    }

    func testSelectionKeepsForcedMatchesAndExcludesAmbiguousOnes() {
        let sharedFrame = CGRect(x: 0, y: 20, width: 100, height: 100)
        let middleFrame = sharedFrame.offsetBy(dx: 0.5, dy: 0)
        let focused = candidate(TestElement(), frame: sharedFrame, identity: 1, focused: true)
        let ambiguous = candidate(TestElement(), frame: sharedFrame, identity: 2)
        let forced = candidate(TestElement(), frame: middleFrame, identity: 3)
        let onScreen = [visible(101, frame: sharedFrame),
                        visible(102, frame: sharedFrame.offsetBy(dx: 0.9, dy: 0)),
                        visible(103, frame: sharedFrame.offsetBy(dx: 1, dy: 0))]
        XCTAssertEqual(Manager.selectCurrentSpaceWindows([focused, ambiguous, forced],
                                                         visibleWindowInfo: onScreen,
                                                         frameTolerance: 0.5).map(testLabel), [1, 3])

        // Repeating the same CG ID must not manufacture a second witness.
        XCTAssertEqual(Manager.selectCurrentSpaceWindows([focused, ambiguous],
                                                         visibleWindowInfo: [onScreen[0], onScreen[0]],
                                                         frameTolerance: 0.5).map(testLabel), [1])
    }

    func testBandActionComposesCurrentSpaceSelectionOrderingAndPlacement() throws {
        let screen = TestScreen(frame: CGRect(x: 0, y: 0, width: 900, height: 600))
        let available = screen.frame.screenFlipped
        let bounds = Manager.BackingPixelBounds(screen.frame)
        let screens = UsableScreens(currentScreen: screen, numScreens: 2)
        let otherScreen = TestScreen(frame: screen.frame.offsetBy(dx: screen.frame.width, dy: 0))
        XCTAssertNotEqual(otherScreen, screen)
        let upperLeft = CGRect(x: available.minX + 10, y: available.minY + 10, width: 100, height: 100)
        let lowerRight = CGRect(x: available.minX + 60, y: available.minY + 60, width: 100, height: 100)

        for direction in [Manager.BandDirection.rows, .columns] {
            let focused = TestElement(frame: upperLeft, windowId: 101, identity: 1)
            let covered = TestElement(frame: lowerRight, windowId: 102, identity: 2)
            let otherSpace = TestElement(frame: lowerRight, windowId: 999, identity: 3)
            let otherDisplay = TestElement(frame: lowerRight, windowId: 103, identity: 4)
            let windows = Manager.windowsOnScreen(screens: screens,
                                                  windows: [covered, otherSpace, otherDisplay],
                                                  focusedWindow: focused,
                                                  screenFor: { $0 === otherDisplay ? otherScreen : screen }).windows
            Manager.tileWindowsInBands(direction, focusedWindow: focused,
                                       windows: windows,
                                       visibleWindowInfo: [visible(102, frame: lowerRight),
                                                           visible(103, frame: otherDisplay.frame)],
                                       screen: screen, visibleFrame: screen.frame)

            XCTAssertGreaterThan(focused.setFrameCalls, 0)
            XCTAssertGreaterThan(covered.setFrameCalls, 0)
            XCTAssertEqual(otherSpace.setFrameCalls, 0)
            XCTAssertEqual(otherSpace.frame, lowerRight)
            XCTAssertEqual(otherDisplay.setFrameCalls, 0)
            XCTAssertEqual(otherDisplay.frame, lowerRight)

            let first = screen.convertRectToBacking(focused.frame.screenFlipped)
            let second = screen.convertRectToBacking(covered.frame.screenFlipped)
            if direction == .rows {
                XCTAssertEqual(first.maxY, CGFloat(bounds.top), accuracy: 0.5)
                XCTAssertEqual(first.minY, second.maxY, accuracy: 0.5)
                XCTAssertEqual(second.minY, CGFloat(bounds.bottom), accuracy: 0.5)
                XCTAssertEqual(first.minX, CGFloat(bounds.left), accuracy: 0.5)
                XCTAssertEqual(second.maxX, CGFloat(bounds.right), accuracy: 0.5)
            } else {
                XCTAssertEqual(first.minX, CGFloat(bounds.left), accuracy: 0.5)
                XCTAssertEqual(first.maxX, second.minX, accuracy: 0.5)
                XCTAssertEqual(second.maxX, CGFloat(bounds.right), accuracy: 0.5)
                XCTAssertEqual(first.minY, CGFloat(bounds.bottom), accuracy: 0.5)
                XCTAssertEqual(second.maxY, CGFloat(bounds.top), accuracy: 0.5)
            }
        }
    }

    func testBandTilingExcludesTodoEvenWhenFocused() {
        let screen = TestScreen(frame: CGRect(x: 0, y: 0, width: 1000, height: 600))
        let screens = UsableScreens(currentScreen: screen, numScreens: 1)
        let workArea = CGRect(x: 0, y: 0, width: 800, height: 600)
        let sidebar = CGRect(x: 800, y: 0, width: 200, height: 600).screenFlipped

        for direction in [Manager.BandDirection.rows, .columns] {
            for todoIsFocused in [false, true] {
                let ordinary = TestElement(frame: workArea.insetBy(dx: 100, dy: 100).screenFlipped,
                                           windowId: 701, identity: 1)
                let todo = TestElement(frame: sidebar, windowId: 702, identity: 2)
                let focused = todoIsFocused ? todo : ordinary
                // Focus recovery must not reintroduce Todo after the exclusion.
                let windows = Manager.windowsOnScreen(screens: screens,
                                                      windows: todoIsFocused ? [ordinary] : [ordinary, todo],
                                                      focusedWindow: focused,
                                                      isActiveTodoWindow: { $0 === todo },
                                                      screenFor: { _ in screen }).windows
                XCTAssertEqual(windows.map(\.windowId), [701])
                Manager.tileWindowsInBands(direction, focusedWindow: focused, windows: windows,
                                           visibleWindowInfo: [visible(701, frame: ordinary.frame),
                                                               visible(702, frame: todo.frame)],
                                           screen: screen, visibleFrame: workArea)

                XCTAssertGreaterThan(ordinary.setFrameCalls, 0)
                XCTAssertEqual(ordinary.frame, workArea.screenFlipped)
                XCTAssertEqual(todo.setFrameCalls, 0)
                XCTAssertEqual(todo.frame, sidebar)
            }
        }
    }

    func testBandTilingHonorsCombinedDisplayBoundsAndSpaceSelection() {
        let left = TestScreen(frame: CGRect(x: 0, y: 0, width: 900, height: 600))
        let right = TestScreen(frame: CGRect(x: 900, y: 0, width: 900, height: 600))
        let screens = UsableScreens(currentScreen: left, numScreens: 2)

        for combineScreens in [false, true] {
            for direction in [Manager.BandDirection.rows, .columns] {
                let focused = TestElement(frame: left.frame.insetBy(dx: 100, dy: 100).screenFlipped,
                                          windowId: 901, identity: 1)
                let onRight = TestElement(frame: right.frame.insetBy(dx: 100, dy: 100).screenFlipped,
                                          windowId: 902, identity: 2)
                let otherSpace = TestElement(frame: onRight.frame, windowId: 999, identity: 3)
                let originalRightFrame = onRight.frame
                let windows = Manager.windowsOnScreen(screens: screens, windows: [focused, onRight, otherSpace],
                                                      focusedWindow: focused, combineScreens: combineScreens,
                                                      screenFor: { $0 === focused ? left : right }).windows
                let workArea = combineScreens ? left.frame.union(right.frame) : left.frame
                Manager.tileWindowsInBands(direction, focusedWindow: focused, windows: windows,
                                           visibleWindowInfo: [visible(901, frame: focused.frame),
                                                               visible(902, frame: onRight.frame)],
                                           screen: left, visibleFrame: workArea)

                XCTAssertEqual(otherSpace.setFrameCalls, 0)
                XCTAssertEqual(otherSpace.frame, originalRightFrame)
                if combineScreens {
                    let first = direction == .rows
                        ? CGRect(x: 0, y: 300, width: 1800, height: 300)
                        : CGRect(x: 0, y: 0, width: 900, height: 600)
                    let second = direction == .rows
                        ? CGRect(x: 0, y: 0, width: 1800, height: 300)
                        : CGRect(x: 900, y: 0, width: 900, height: 600)
                    XCTAssertEqual(focused.frame, first.screenFlipped)
                    XCTAssertEqual(onRight.frame, second.screenFlipped)
                    XCTAssertGreaterThan(onRight.setFrameCalls, 0)
                } else {
                    XCTAssertEqual(focused.frame, left.frame.screenFlipped)
                    XCTAssertEqual(onRight.frame, originalRightFrame)
                    XCTAssertEqual(onRight.setFrameCalls, 0)
                }
            }
        }
    }

    func testBandActionDerivesFixedAndReportedMinimumConstraints() throws {
        let screen = TestScreen(frame: CGRect(x: 0, y: 0, width: 900, height: 600))
        let available = screen.frame.screenFlipped
        let bounds = Manager.BackingPixelBounds(screen.frame)

        for direction in [Manager.BandDirection.rows, .columns] {
            let extent = bounds.extent(direction)
            guard extent > 400 else { throw XCTSkip("Display is too small for the constraint fixture") }
            let fixedPixels = extent / 8
            let minimumPixels = extent * 5 / 8
            let fixedPoints = CGFloat(fixedPixels) / screen.backingScaleFactor
            let minimumPoints = CGFloat(minimumPixels) / screen.backingScaleFactor
            let fixedFrame = CGRect(x: available.minX + 10, y: available.minY + 10,
                                    width: direction == .rows ? available.width : fixedPoints,
                                    height: direction == .rows ? fixedPoints : available.height)
            let laterFrame = CGRect(x: available.minX + 40, y: available.minY + 40,
                                    width: 100, height: 100)
            let reportedMinimum = direction == .rows
                ? CGSize(width: 0, height: minimumPoints)
                : CGSize(width: minimumPoints, height: 0)
            let fixed = TestElement(frame: fixedFrame, windowId: 501, identity: 1, canResize: false)
            let minimum = TestElement(frame: laterFrame, windowId: 502, identity: 2,
                                      reportedMinimumSize: reportedMinimum)
            let flexible = TestElement(frame: laterFrame.offsetBy(dx: 30, dy: 30), windowId: 503, identity: 3)
            let elements = [fixed, minimum, flexible]
            Manager.tileWindowsInBands(direction, focusedWindow: fixed, windows: elements,
                                       visibleWindowInfo: [visible(501, frame: fixed.frame),
                                                           visible(502, frame: minimum.frame),
                                                           visible(503, frame: flexible.frame)],
                                       screen: screen, visibleFrame: screen.frame)

            let lengths = elements.map { element in
                let size = screen.convertRectToBacking(element.frame.screenFlipped).size
                return Int((direction == .rows ? size.height : size.width).rounded())
            }
            XCTAssertEqual(lengths, [fixedPixels, minimumPixels, extent - fixedPixels - minimumPixels])
            XCTAssertTrue(elements.allSatisfy { $0.setFrameCalls > 0 })
        }
    }

    func testRowsAndColumnsUsePreMoveCorners() {
        let topRight = candidate(TestElement(), frame: CGRect(x: 400, y: 0, width: 100, height: 100),
                                 identity: 4, windowId: 104)
        let bottomLeft = candidate(TestElement(), frame: CGRect(x: 0, y: 400, width: 100, height: 100),
                                   identity: 5, windowId: 105)
        XCTAssertEqual(Manager.orderForBandTiling([bottomLeft, topRight], direction: .rows)
            .map(testLabel), [4, 5])
        XCTAssertEqual(Manager.orderForBandTiling([topRight, bottomLeft], direction: .columns)
            .map(testLabel), [5, 4])

        let sameRowLeft = candidate(TestElement(), frame: CGRect(x: 0, y: 20, width: 100, height: 100), identity: 7)
        let sameRowRight = candidate(TestElement(), frame: CGRect(x: 400, y: 20, width: 100, height: 100), identity: 6)
        XCTAssertEqual(Manager.orderForBandTiling([sameRowRight, sameRowLeft], direction: .rows)
            .map(testLabel), [7, 6])
        let sameColumnTop = candidate(TestElement(), frame: CGRect(x: 10, y: 0, width: 100, height: 100), identity: 9)
        let sameColumnBottom = candidate(TestElement(), frame: CGRect(x: 10, y: 400, width: 100, height: 100), identity: 8)
        XCTAssertEqual(Manager.orderForBandTiling([sameColumnBottom, sameColumnTop], direction: .columns)
            .map(testLabel), [9, 8])
    }

    func testMinimumBoundWindowsDoNotConsumeRemainderPixels() {
        let constraints: [Manager.BandConstraint] = [5, 5, 1, 1, 1].map {
            .resizable(minimum: $0, maximum: 17)
        }
        let result = GridTiling.balancedBandLengths(totalPixels: 17, constraints: constraints)
        XCTAssertTrue(result.feasible)
        XCTAssertEqual(result.lengths, [5, 5, 3, 2, 2])
    }

    func testRealizedRowsFillAtOneAndTwoPointScalesWithOnePixelRemainder() {
        let bounds = Manager.BackingPixelBounds(CGRect(x: 20, y: 10, width: 1200, height: 901))
        for scale in [CGFloat(1), CGFloat(2)] {
            let elements = (0..<3).map { _ in TestElement() }
            let windows = elements.enumerated().map { index, element in
                candidate(element, frame: CGRect(x: CGFloat(index * 100), y: 0, width: 100, height: 100),
                          identity: CFHashCode(index + 1))
            }
            let constraints = Array(repeating: Manager.BandConstraint.resizable(minimum: 0, maximum: 901), count: 3)
            applyBandTiling(windows, bounds: bounds, direction: .rows, constraints: constraints,
                                    pointFrame: { self.scaled($0, by: 1 / scale) },
                                    backingFrame: { self.scaled($0, by: scale) })
            let achieved = elements.map { scaled($0.frame, by: scale) }
            XCTAssertEqual(achieved.map(\.height), [301, 300, 300])
            XCTAssertEqual(achieved.map(\.width), [1200, 1200, 1200])
            XCTAssertEqual(achieved.first?.maxY, 911)
            XCTAssertEqual(achieved[0].minY, achieved[1].maxY)
            XCTAssertEqual(achieved[1].minY, achieved[2].maxY)
            XCTAssertEqual(achieved.last?.minY, 10)
        }
    }

    func testRealizedColumnsAndSingleWindowFillTheirBackingPixelBounds() {
        let bounds = Manager.BackingPixelBounds(CGRect(x: 10, y: 20, width: 901, height: 1200))
        let elements = (0..<3).map { _ in TestElement() }
        let windows = elements.enumerated().map { index, element in
            candidate(element, frame: CGRect(x: CGFloat(index * 100), y: 0, width: 100, height: 100),
                      identity: CFHashCode(index + 1))
        }
        let constraints = Array(repeating: Manager.BandConstraint.resizable(minimum: 0, maximum: 901), count: 3)
        applyBandTiling(windows, bounds: bounds, direction: .columns, constraints: constraints,
                                pointFrame: { self.scaled($0, by: 0.5) },
                                backingFrame: { self.scaled($0, by: 2) })
        let achieved = elements.map { scaled($0.frame, by: 2) }
        XCTAssertEqual(achieved.map(\.width), [301, 300, 300])
        XCTAssertEqual(achieved.map(\.height), [1200, 1200, 1200])
        XCTAssertEqual(achieved.first?.minX, 10)
        XCTAssertEqual(achieved[0].maxX, achieved[1].minX)
        XCTAssertEqual(achieved[1].maxX, achieved[2].minX)
        XCTAssertEqual(achieved.last?.maxX, 911)

        let single = TestElement()
        applyBandTiling([candidate(single, frame: .zero, identity: 4)],
                                bounds: bounds, direction: .rows,
                                constraints: [.resizable(minimum: 0, maximum: 1200)],
                                pointFrame: { $0 }, backingFrame: { $0 })
        XCTAssertEqual(single.frame, CGRect(x: 10, y: 20, width: 901, height: 1200))
    }

    func testFixedExtentAndUnreportedMinimumRebalanceAchievedFrames() {
        let bounds = Manager.BackingPixelBounds(CGRect(x: 0, y: 0, width: 600, height: 900))
        let fixed = TestElement()
        let flexible = TestElement()
        let fixedWindows = [candidate(fixed, frame: CGRect(x: 0, y: 0, width: 600, height: 100), identity: 1),
                            candidate(flexible, frame: CGRect(x: 0, y: 100, width: 600, height: 100), identity: 2)]
        applyBandTiling(fixedWindows, bounds: bounds, direction: .rows,
                                constraints: [.fixed(100), .resizable(minimum: 0, maximum: 900)],
                                pointFrame: { $0 }, backingFrame: { $0 })
        XCTAssertEqual([fixed.frame.height, flexible.frame.height], [100, 800])
        XCTAssertEqual(fixed.frame.minY, flexible.frame.maxY)
        XCTAssertEqual(flexible.frame.minY, 0)

        let clamped = TestElement(minimumHeight: 500)
        let others = [TestElement(), TestElement()]
        let elements = [clamped] + others
        let windows = elements.enumerated().map { index, element in
            candidate(element, frame: CGRect(x: 0, y: CGFloat(index * 100), width: 600, height: 100),
                      identity: CFHashCode(index + 1))
        }
        applyBandTiling(windows, bounds: bounds, direction: .rows,
                                constraints: Array(repeating: .resizable(minimum: 0, maximum: 900), count: 3),
                                pointFrame: { $0 }, backingFrame: { $0 })
        XCTAssertEqual(elements.map { $0.frame.height }, [500, 200, 200])
        XCTAssertEqual(elements[0].frame.maxY, 900)
        XCTAssertEqual(elements[0].frame.minY, elements[1].frame.maxY)
        XCTAssertEqual(elements[1].frame.minY, elements[2].frame.maxY)
        XCTAssertEqual(elements[2].frame.minY, 0)
    }

    func testObservedMaximumRedistributesToAnotherResizableWindow() {
        let bounds = Manager.BackingPixelBounds(CGRect(x: 0, y: 0, width: 900, height: 600))
        let capped = TestElement(maximumWidth: 200)
        let flexible = TestElement()
        let windows = [candidate(capped, frame: CGRect(x: 0, y: 0, width: 100, height: 600), identity: 1),
                       candidate(flexible, frame: CGRect(x: 100, y: 0, width: 100, height: 600), identity: 2)]
        applyBandTiling(windows, bounds: bounds, direction: .columns,
                                constraints: [.resizable(minimum: 0, maximum: 900), .resizable(minimum: 0, maximum: 900)],
                                pointFrame: { $0 }, backingFrame: { $0 })
        XCTAssertEqual([capped.frame.width, flexible.frame.width], [200, 700])
        XCTAssertEqual(capped.frame.maxX, flexible.frame.minX)
        XCTAssertEqual(flexible.frame.maxX, 900)
    }

    func testConstraintRefinementDoesNotReapplyAlreadyAchievedFrames() {
        let elements = [TestElement(minimumHeight: 1100), TestElement(minimumHeight: 975),
                        TestElement(minimumHeight: 965), TestElement()]
        let windows = elements.enumerated().map { index, element in
            candidate(element, frame: CGRect(x: 0, y: CGFloat(index * 100), width: 600, height: 100),
                      identity: CFHashCode(index + 1))
        }
        applyBandTiling(windows,
                                bounds: Manager.BackingPixelBounds(CGRect(x: 0, y: 0, width: 600, height: 4000)),
                                direction: .rows,
                                constraints: Array(repeating: .resizable(minimum: 0, maximum: 4000), count: 4),
                                pointFrame: { $0 }, backingFrame: { $0 })

        XCTAssertEqual(elements.map { $0.frame.height }, [1100, 975, 965, 960])
        XCTAssertLessThan(elements.map(\.setFrameCalls).reduce(0, +), 12)
    }

    func testFinalPositionClampReplansTheAchievedBands() {
        let positionSensitive = TestElement(minimumHeightAtOrigin: { $0 <= 400 ? 550 : 500 })
        let flexible = TestElement()
        let windows = [candidate(positionSensitive, frame: CGRect(x: 0, y: 0, width: 600, height: 100),
                                 identity: 1),
                       candidate(flexible, frame: CGRect(x: 0, y: 100, width: 600, height: 100),
                                 identity: 2)]
        applyBandTiling(windows,
                                bounds: Manager.BackingPixelBounds(CGRect(x: 0, y: 0, width: 600, height: 900)),
                                direction: .rows,
                                constraints: Array(repeating: .resizable(minimum: 0, maximum: 900), count: 2),
                                pointFrame: { $0 }, backingFrame: { $0 })

        XCTAssertEqual([positionSensitive.frame.height, flexible.frame.height], [550, 350])
        XCTAssertEqual(positionSensitive.frame.maxY, 900)
        XCTAssertEqual(positionSensitive.frame.minY, flexible.frame.maxY)
        XCTAssertEqual(flexible.frame.minY, 0)
    }

    func testImpossibleRestrictionsStillAttemptAllWindows() {
        let constraints: [Manager.BandConstraint] = [
            .resizable(minimum: 500, maximum: 900),
            .resizable(minimum: 500, maximum: 900),
            .resizable(minimum: 0, maximum: 900)
        ]
        let result = GridTiling.balancedBandLengths(totalPixels: 900, constraints: constraints)
        XCTAssertFalse(result.feasible)
        XCTAssertEqual(result.lengths, [300, 300, 300])

        // The first hidden minimum is feasible; the second makes the set
        // infeasible, so finish from the last feasible allocation.
        let elements = [TestElement(minimumHeight: 500), TestElement(minimumHeight: 500), TestElement()]
        let windows = elements.enumerated().map { index, element in
            candidate(element, frame: CGRect(x: 0, y: CGFloat(index * 100), width: 600, height: 100),
                      identity: CFHashCode(index + 1))
        }
        applyBandTiling(windows,
                                bounds: Manager.BackingPixelBounds(CGRect(x: 0, y: 0, width: 600, height: 900)),
                                direction: .rows,
                                constraints: Array(repeating: .resizable(minimum: 0, maximum: 900), count: 3),
                                pointFrame: { $0 }, backingFrame: { $0 })
        XCTAssertTrue(elements.allSatisfy { $0.setFrameCalls > 0 })
        XCTAssertEqual(elements.map { $0.frame.minY }, [400, 200, 0])
    }

}

final class FootprintAlphaDefaultsTests: XCTestCase {
    private var savedAlpha: Double = 0
    private var savedBlur = false
    private var storedAlpha: Any?
    private var storedBlur: Any?

    override func setUp() {
        super.setUp()
        savedAlpha = Defaults.footprintAlpha.value
        savedBlur = Defaults.footprintBlur.enabled
        storedAlpha = UserDefaults.standard.object(forKey: Defaults.footprintAlpha.key)
        storedBlur = UserDefaults.standard.object(forKey: Defaults.footprintBlur.key)
        UserDefaults.standard.removeObject(forKey: Defaults.footprintAlpha.key)
    }

    override func tearDown() {
        Defaults.footprintAlpha.value = savedAlpha
        Defaults.footprintBlur.enabled = savedBlur
        UserDefaults.standard.set(storedAlpha, forKey: Defaults.footprintAlpha.key)
        UserDefaults.standard.set(storedBlur, forKey: Defaults.footprintBlur.key)
        super.tearDown()
    }

    func testUnsetAlphaFollowsPreviewStyleWithoutSavingAValue() {
        let window = FootprintWindow(accessibility: {
            FootprintAccessibility(reduceMotion: false, reduceTransparency: false)
        })
        defer { window.close() }

        for blurred in [false, true, false] {
            Defaults.footprintBlur.enabled = blurred
            XCTAssertEqual(Defaults.effectiveFootprintAlpha, blurred ? 0 : 0.3)
            XCTAssertEqual(window.presentation.alpha, blurred ? 1 : 0.3)
            XCTAssertEqual(window.presentation.usesBlur, blurred)
            XCTAssertNil(UserDefaults.standard.object(forKey: Defaults.footprintAlpha.key))
        }
    }

    func testExplicitZeroSurvivesStyleChangesReloadAndConfigRoundTrip() throws {
        Defaults.footprintAlpha.value = 0
        for blurred in [false, true] {
            Defaults.footprintBlur.enabled = blurred
            XCTAssertEqual(Defaults.effectiveFootprintAlpha, 0)
            XCTAssertEqual(DoubleDefault(key: Defaults.footprintAlpha.key).value, 0)

            let exported = try exportedAlpha()
            XCTAssertEqual(exported.double, 0)
            XCTAssertNil(exported.float)
            Defaults.footprintAlpha.value = 0.8
            Defaults.footprintAlpha.load(from: exported)
            XCTAssertEqual(Defaults.effectiveFootprintAlpha, 0)
        }
    }

    func testLegacyFloatValuesAndDoublePrecisionArePreserved() throws {
        for json in [#"{"float":0}"#, #"{"float":0.4}"#, #"{"double":0.123456789012345}"#] {
            let imported = try JSONDecoder().decode(CodableDefault.self, from: Data(json.utf8))
            let expected = imported.double ?? Double(imported.float!)
            Defaults.footprintAlpha.load(from: imported)
            for blurred in [false, true] {
                Defaults.footprintBlur.enabled = blurred
                XCTAssertEqual(Defaults.effectiveFootprintAlpha, expected)
                XCTAssertEqual(DoubleDefault(key: Defaults.footprintAlpha.key).value, expected)
                XCTAssertEqual(try exportedAlpha().double, expected)
            }
        }
    }

    func testExportUsesTheEffectiveUnsetAlpha() throws {
        for blurred in [false, true] {
            UserDefaults.standard.removeObject(forKey: Defaults.footprintAlpha.key)
            Defaults.footprintBlur.enabled = blurred
            let exported = try exportedAlpha()
            XCTAssertEqual(exported.double, blurred ? 0 : 0.3)
            XCTAssertNil(UserDefaults.standard.object(forKey: Defaults.footprintAlpha.key))

            Defaults.footprintAlpha.value = 0.8
            Defaults.footprintAlpha.load(from: exported)
            XCTAssertEqual(Defaults.effectiveFootprintAlpha, blurred ? 0 : 0.3)
        }
    }

    private func exportedAlpha() throws -> CodableDefault {
        let json = try XCTUnwrap(Defaults.encoded())
        let config = try XCTUnwrap(Defaults.convert(jsonString: json))
        return try XCTUnwrap(config.defaults[Defaults.footprintAlpha.key])
    }
}

class PositionCyclesTests: XCTestCase {

    func testSixthsReturnTrue() {
        XCTAssertTrue(WindowAction.topLeftSixth.positionCycles)
        XCTAssertTrue(WindowAction.topCenterSixth.positionCycles)
        XCTAssertTrue(WindowAction.topRightSixth.positionCycles)
        XCTAssertTrue(WindowAction.bottomLeftSixth.positionCycles)
        XCTAssertTrue(WindowAction.bottomCenterSixth.positionCycles)
        XCTAssertTrue(WindowAction.bottomRightSixth.positionCycles)
    }

    func testEighthsReturnTrue() {
        XCTAssertTrue(WindowAction.topLeftEighth.positionCycles)
        XCTAssertTrue(WindowAction.topCenterLeftEighth.positionCycles)
        XCTAssertTrue(WindowAction.bottomRightEighth.positionCycles)
    }

    func testNinthsReturnTrue() {
        XCTAssertTrue(WindowAction.topLeftNinth.positionCycles)
        XCTAssertTrue(WindowAction.middleCenterNinth.positionCycles)
        XCTAssertTrue(WindowAction.bottomRightNinth.positionCycles)
    }

    func testTwelfthsReturnTrue() {
        XCTAssertTrue(WindowAction.topLeftTwelfth.positionCycles)
        XCTAssertTrue(WindowAction.middleCenterLeftTwelfth.positionCycles)
        XCTAssertTrue(WindowAction.bottomRightTwelfth.positionCycles)
    }

    func testSixteenthsReturnTrue() {
        XCTAssertTrue(WindowAction.topLeftSixteenth.positionCycles)
        XCTAssertTrue(WindowAction.upperMiddleCenterLeftSixteenth.positionCycles)
        XCTAssertTrue(WindowAction.lowerMiddleRightSixteenth.positionCycles)
        XCTAssertTrue(WindowAction.bottomRightSixteenth.positionCycles)
    }

    func testGridPositionsReturnTrue() {
        XCTAssertTrue(WindowAction.leftHalf.positionCycles)
        XCTAssertTrue(WindowAction.rightHalf.positionCycles)
        XCTAssertTrue(WindowAction.topLeft.positionCycles)
        XCTAssertTrue(WindowAction.bottomRight.positionCycles)
        XCTAssertTrue(WindowAction.firstThird.positionCycles)
        XCTAssertTrue(WindowAction.lastThird.positionCycles)
        XCTAssertTrue(WindowAction.firstFourth.positionCycles)
        XCTAssertTrue(WindowAction.topHalf.positionCycles)
        XCTAssertTrue(WindowAction.bottomHalf.positionCycles)
    }

    func testNonPositionalActionsReturnFalse() {
        XCTAssertFalse(WindowAction.maximize.positionCycles)
        XCTAssertFalse(WindowAction.maximizeHeight.positionCycles)
        XCTAssertFalse(WindowAction.almostMaximize.positionCycles)
        XCTAssertFalse(WindowAction.center.positionCycles)
        XCTAssertFalse(WindowAction.centerProminently.positionCycles)
        XCTAssertFalse(WindowAction.restore.positionCycles)
        XCTAssertFalse(WindowAction.moveLeft.positionCycles)
        XCTAssertFalse(WindowAction.moveRight.positionCycles)
        XCTAssertFalse(WindowAction.nextDisplay.positionCycles)
        XCTAssertFalse(WindowAction.previousDisplay.positionCycles)
        XCTAssertFalse(WindowAction.larger.positionCycles)
        XCTAssertFalse(WindowAction.smaller.positionCycles)
        XCTAssertFalse(WindowAction.tileAll.positionCycles)
        XCTAssertFalse(WindowAction.cascadeAll.positionCycles)
        XCTAssertFalse(WindowAction.specified.positionCycles)
    }
}

class CooperativeResizeSourceTests: XCTestCase {

    func testKeyboardShortcutsAndDragSnappingAllowCooperativeResize() {
        XCTAssertTrue(ExecutionSource.keyboardShortcut.allowsCooperativeResize)
        XCTAssertTrue(ExecutionSource.dragToSnap.allowsCooperativeResize)
    }

    func testNonSnappingSourcesDoNotAllowCooperativeResize() {
        XCTAssertFalse(ExecutionSource.menuItem.allowsCooperativeResize)
        XCTAssertFalse(ExecutionSource.url.allowsCooperativeResize)
        XCTAssertFalse(ExecutionSource.titleBar.allowsCooperativeResize)
    }
}

class ScreenFlippedTests: XCTestCase {

    func testScreenFlippedIsOwnInverse() {
        let rect = CGRect(x: 100, y: 200, width: 400, height: 300)
        let flipped = rect.screenFlipped
        let doubleFlipped = flipped.screenFlipped
        XCTAssertEqual(rect.origin.x, doubleFlipped.origin.x, accuracy: 0.001)
        XCTAssertEqual(rect.origin.y, doubleFlipped.origin.y, accuracy: 0.001)
        XCTAssertEqual(rect.width, doubleFlipped.width, accuracy: 0.001)
        XCTAssertEqual(rect.height, doubleFlipped.height, accuracy: 0.001)
    }

    func testScreenFlippedPreservesSize() {
        let rect = CGRect(x: 50, y: 100, width: 800, height: 600)
        let flipped = rect.screenFlipped
        XCTAssertEqual(rect.width, flipped.width, accuracy: 0.001)
        XCTAssertEqual(rect.height, flipped.height, accuracy: 0.001)
    }

    func testScreenFlippedPreservesX() {
        let rect = CGRect(x: 250, y: 300, width: 500, height: 400)
        let flipped = rect.screenFlipped
        XCTAssertEqual(rect.origin.x, flipped.origin.x, accuracy: 0.001)
    }

    func testScreenFlippedNullRectReturnsNull() {
        let nullRect = CGRect.null
        let flipped = nullRect.screenFlipped
        XCTAssertTrue(flipped.isNull)
    }

    func testScreenFlippedNegativeCoordinates() {
        let rect = CGRect(x: -1000, y: -500, width: 400, height: 300)
        let flipped = rect.screenFlipped
        let doubleFlipped = flipped.screenFlipped
        XCTAssertEqual(rect.origin.x, doubleFlipped.origin.x, accuracy: 0.001)
        XCTAssertEqual(rect.origin.y, doubleFlipped.origin.y, accuracy: 0.001)
    }
}

final class DockVisibleFrameTests: XCTestCase {
    private let screen = CGRect(x: 0, y: 0, width: 1440, height: 900)
    private let visibleWithoutDock = CGRect(x: 0, y: 0, width: 1440, height: 875)

    func testAddsMissingBottomDockInset() {
        let dock = CGRect(x: 400, y: 8, width: 640, height: 62)

        XCTAssertEqual(
            corrected(visibleFrame: visibleWithoutDock, dockFrame: dock),
            CGRect(x: 0, y: 70, width: 1440, height: 805)
        )
    }

    func testAddsMissingLeftDockInset() {
        let dock = CGRect(x: 8, y: 180, width: 62, height: 540)

        XCTAssertEqual(
            corrected(visibleFrame: visibleWithoutDock, dockFrame: dock),
            CGRect(x: 70, y: 0, width: 1370, height: 875)
        )
    }

    func testAddsMissingRightDockInset() {
        let dock = CGRect(x: 1370, y: 180, width: 62, height: 540)

        XCTAssertEqual(
            corrected(visibleFrame: visibleWithoutDock, dockFrame: dock),
            CGRect(x: 0, y: 0, width: 1370, height: 875)
        )
    }

    func testPreservesAccurateAppKitInsetWhenDockFrameDiffersSlightly() {
        let reportedVisibleFrame = CGRect(x: 0, y: 60, width: 1440, height: 815)
        let dock = CGRect(x: 30, y: 10, width: 1380, height: 53)

        XCTAssertEqual(
            corrected(visibleFrame: reportedVisibleFrame, dockFrame: dock),
            reportedVisibleFrame
        )
    }

    func testPreservesPlausibleAppKitInsetWhenAXDiffersMaterially() {
        let reportedVisibleFrame = CGRect(x: 0, y: 75, width: 1440, height: 800)
        let dock = CGRect(x: 400, y: 8, width: 640, height: 32)

        XCTAssertEqual(
            corrected(visibleFrame: reportedVisibleFrame, dockFrame: dock),
            reportedVisibleFrame
        )
    }

    func testReclaimsPhantomInsetAfterDockMovesToAnotherDisplay() {
        let externalScreen = CGRect(x: 1440, y: 0, width: 1920, height: 1080)
        let dock = CGRect(x: 1740, y: 8, width: 1320, height: 62)
        let staleVisibleFrame = CGRect(x: 0, y: 75, width: 1440, height: 800)

        XCTAssertEqual(
            corrected(
                visibleFrame: staleVisibleFrame,
                screenFrames: [screen, externalScreen],
                dockFrame: dock
            ),
            visibleWithoutDock
        )
    }

    func testCorrectsNewDockDisplayAfterMove() {
        let externalScreen = CGRect(x: 1440, y: 0, width: 1920, height: 1080)
        let externalVisibleFrame = CGRect(x: 1440, y: 0, width: 1920, height: 1055)
        let dock = CGRect(x: 1740, y: 8, width: 1320, height: 62)

        XCTAssertEqual(
            DockUtil.correctedVisibleFrame(
                screenFrame: externalScreen,
                visibleFrame: externalVisibleFrame,
                screenFrames: [screen, externalScreen],
                dockFrame: dock,
                dockAutoHideEnabled: false
            ),
            CGRect(x: 1440, y: 70, width: 1920, height: 985)
        )
    }

    func testAutoHideReclaimsStaleInsetAndPreservesSmallRevealBoundary() {
        let reportedVisibleFrame = CGRect(x: 70, y: 4, width: 1370, height: 871)

        XCTAssertEqual(
            corrected(
                visibleFrame: reportedVisibleFrame,
                dockFrame: nil,
                dockAutoHideEnabled: true
            ),
            CGRect(x: 0, y: 4, width: 1440, height: 871)
        )
    }

    func testAutoHideReclaimsStaleBottomInset() {
        let reportedVisibleFrame = CGRect(x: 0, y: 75, width: 1440, height: 800)

        XCTAssertEqual(
            corrected(
                visibleFrame: reportedVisibleFrame,
                dockFrame: nil,
                dockAutoHideEnabled: true
            ),
            visibleWithoutDock
        )
    }

    func testLiveDockClearsStaleWrongEdgeInset() {
        let staleLeftDockFrame = CGRect(x: 4, y: 0, width: 1436, height: 875)
        let currentBottomDock = CGRect(x: 400, y: 8, width: 640, height: 62)

        XCTAssertEqual(
            corrected(visibleFrame: staleLeftDockFrame, dockFrame: currentBottomDock),
            CGRect(x: 0, y: 70, width: 1440, height: 805)
        )
    }

    func testUnreadableDockKeepsReportedFrame() {
        let reportedVisibleFrame = CGRect(x: 0, y: 75, width: 1440, height: 800)

        XCTAssertEqual(
            corrected(visibleFrame: reportedVisibleFrame, dockFrame: nil),
            reportedVisibleFrame
        )
    }

    func testCenteredDockFrameIsIgnored() {
        let reportedVisibleFrame = CGRect(x: 0, y: 75, width: 1440, height: 800)
        let invalidDock = CGRect(x: 400, y: 300, width: 640, height: 62)

        XCTAssertEqual(
            corrected(visibleFrame: reportedVisibleFrame, dockFrame: invalidDock),
            reportedVisibleFrame
        )
    }

    func testOversizedDockFrameIsIgnoredBeforeReclaimingAnotherDisplay() {
        let externalScreen = CGRect(x: 1440, y: 0, width: 1920, height: 1080)
        let invalidDock = CGRect(x: 1440, y: 0, width: 1920, height: 500)
        let reportedVisibleFrame = CGRect(x: 0, y: 75, width: 1440, height: 800)

        XCTAssertEqual(
            corrected(
                visibleFrame: reportedVisibleFrame,
                screenFrames: [screen, externalScreen],
                dockFrame: invalidDock
            ),
            reportedVisibleFrame
        )
    }

    func testCorrectsDockOnNegativeOriginDisplay() {
        let externalScreen = CGRect(x: -1920, y: 0, width: 1920, height: 1080)
        let externalVisibleFrame = CGRect(x: -1920, y: 0, width: 1920, height: 1055)
        let dock = CGRect(x: -1912, y: 240, width: 62, height: 600)

        XCTAssertEqual(
            DockUtil.correctedVisibleFrame(
                screenFrame: externalScreen,
                visibleFrame: externalVisibleFrame,
                screenFrames: [externalScreen, screen],
                dockFrame: dock,
                dockAutoHideEnabled: false
            ),
            CGRect(x: -1850, y: 0, width: 1850, height: 1055)
        )
    }

    func testAmbiguousDockHostIsIgnored() {
        let upperScreen = CGRect(x: 0, y: 900, width: 1440, height: 900)
        let ambiguousDock = CGRect(x: 400, y: 870, width: 640, height: 60)
        let reportedVisibleFrame = CGRect(x: 0, y: 75, width: 1440, height: 800)

        XCTAssertEqual(
            corrected(
                visibleFrame: reportedVisibleFrame,
                screenFrames: [screen, upperScreen],
                dockFrame: ambiguousDock
            ),
            reportedVisibleFrame
        )
    }

    func testCombinedDisplayFrameRetainsOuterBottomDockInset() {
        let combinedScreen = CGRect(x: 0, y: 0, width: 3360, height: 1080)
        let combinedVisibleFrame = CGRect(x: 0, y: 0, width: 3360, height: 1055)
        let dock = CGRect(x: 400, y: 8, width: 640, height: 62)

        XCTAssertEqual(
            DockUtil.correctedVisibleFrame(
                screenFrame: combinedScreen,
                visibleFrame: combinedVisibleFrame,
                screenFrames: [combinedScreen],
                dockFrame: dock,
                dockAutoHideEnabled: false
            ),
            CGRect(x: 0, y: 70, width: 3360, height: 985)
        )
    }

    private func corrected(visibleFrame: CGRect,
                           screenFrames: [CGRect]? = nil,
                           dockFrame: CGRect?,
                           dockAutoHideEnabled: Bool = false) -> CGRect {
        DockUtil.correctedVisibleFrame(
            screenFrame: screen,
            visibleFrame: visibleFrame,
            screenFrames: screenFrames ?? [screen],
            dockFrame: dockFrame,
            dockAutoHideEnabled: dockAutoHideEnabled
        )
    }
}

class DefaultsExportTests: XCTestCase {

    func testOverlapDefaultsInExportArray() {
        let keys = Defaults.array.map { $0.key }
        XCTAssertTrue(keys.contains("cyclingOverlapOffset"), "cyclingOverlapOffset missing from Defaults.array")
        XCTAssertTrue(keys.contains("cyclingOverlapOffsetSize"), "cyclingOverlapOffsetSize missing from Defaults.array")
        XCTAssertTrue(keys.contains("cyclingOverlapMaxCascade"), "cyclingOverlapMaxCascade missing from Defaults.array")
        XCTAssertTrue(keys.contains("cooperativeCornerResize"), "cooperativeCornerResize missing from Defaults.array")
        XCTAssertTrue(keys.contains("stackBadge"), "stackBadge missing from Defaults.array")
    }
}

class ConfigImportTests: XCTestCase {

    private static let shortcutKeys = WindowAction.active.map(\.name) + TodoManager.defaultsKeys + StackBadgeManager.defaultsKeys
    private var storedValues = [String: Any]()
    private var absentKeys = Set<String>()

    override func setUp() {
        super.setUp()
        for key in Self.shortcutKeys {
            if let value = UserDefaults.standard.object(forKey: key) {
                storedValues[key] = value
            } else {
                absentKeys.insert(key)
            }
        }
    }

    override func tearDown() {
        for key in Self.shortcutKeys {
            if let value = storedValues[key] {
                UserDefaults.standard.set(value, forKey: key)
            } else if absentKeys.contains(key) {
                UserDefaults.standard.removeObject(forKey: key)
            }
        }
        storedValues.removeAll()
        absentKeys.removeAll()
        super.tearDown()
    }

    func testImportClearsOmittedActiveShortcut() throws {
        let action = WindowAction.almostMaximize
        store(Shortcut(NSEvent.ModifierFlags.command.rawValue, 10), forKey: action.name)

        try loadConfig(shortcuts: [:])

        XCTAssertNil(UserDefaults.standard.object(forKey: action.name))
    }

    func testImportClearsOmittedTodoShortcut() throws {
        let defaultsKey = TodoManager.toggleDefaultsKey
        store(Shortcut(NSEvent.ModifierFlags.command.rawValue, 11), forKey: defaultsKey)

        try loadConfig(shortcuts: [:])

        XCTAssertNil(UserDefaults.standard.object(forKey: defaultsKey))
    }

    func testImportClearsOmittedStackBadgeShortcut() throws {
        let defaultsKey = StackBadgeManager.toggleDefaultsKey
        store(Shortcut(NSEvent.ModifierFlags.command.rawValue, 14), forKey: defaultsKey)

        try loadConfig(shortcuts: [:])

        XCTAssertNil(UserDefaults.standard.object(forKey: defaultsKey))
    }

    func testImportAppliesSuppliedActiveShortcut() throws {
        let action = WindowAction.almostMaximize
        let importedShortcut = Shortcut(NSEvent.ModifierFlags.command.rawValue, 12)

        try loadConfig(shortcuts: [action.name: importedShortcut])

        let storedShortcut = try XCTUnwrap(ShortcutCycle.shortcut(for: action))
        XCTAssertEqual(storedShortcut.keyCode, importedShortcut.keyCode)
        XCTAssertEqual(storedShortcut.modifierFlags.rawValue, importedShortcut.modifierFlags)
    }

    func testImportUsesActiveShortcutAlias() throws {
        let action = WindowAction.leftHalf
        let alias = try XCTUnwrap(action.aliasName)
        let importedShortcut = Shortcut(NSEvent.ModifierFlags.command.rawValue, 13)

        try loadConfig(shortcuts: [alias: importedShortcut])

        let storedShortcut = try XCTUnwrap(ShortcutCycle.shortcut(for: action))
        XCTAssertEqual(storedShortcut.keyCode, importedShortcut.keyCode)
        XCTAssertEqual(storedShortcut.modifierFlags.rawValue, importedShortcut.modifierFlags)
    }

    func testImportClearsInvalidActiveShortcut() throws {
        let action = WindowAction.almostMaximize
        store(Shortcut(NSEvent.ModifierFlags.command.rawValue, 14), forKey: action.name)

        try loadConfig(shortcuts: [action.name: Shortcut(NSEvent.ModifierFlags.command.rawValue, -1)])

        XCTAssertNil(UserDefaults.standard.object(forKey: action.name))
    }

    private func store(_ shortcut: Shortcut, forKey key: String) {
        let transformer = ValueTransformer(forName: NSValueTransformerName(rawValue: MASDictionaryTransformerName))!
        let value = transformer.reverseTransformedValue(shortcut.toMASSHortcut())
        UserDefaults.standard.set(value, forKey: key)
    }

    private func loadConfig(shortcuts: [String: Shortcut]) throws {
        let config = Config(bundleId: "com.knollsoft.Rectangle",
                            version: "ConfigImportTests",
                            shortcuts: shortcuts,
                            defaults: [:])
        let data = try JSONEncoder().encode(config)
        let fileURL = FileManager.default.temporaryDirectory
            .appendingPathComponent("ConfigImportTests-\(UUID().uuidString).json")
        defer { try? FileManager.default.removeItem(at: fileURL) }
        try data.write(to: fileURL, options: .atomic)

        Defaults.load(fileUrl: fileURL, notificationCenter: NotificationCenter())
    }
}

class StackBadgeGeometryTests: XCTestCase {

    private let laptopFrame = CGRect(x: 0, y: 0, width: 2336, height: 1510)
    // Real rig geometry: external 4K TVs with negative origins.
    private let tvFrame = CGRect(x: -5212, y: 1510, width: 3840, height: 2160)

    func testCornerCountMatchesUnionOfGridFractions() {
        // Column fractions across all grids: 0, 1/4, 1/3, 1/2, 2/3, 3/4 (6 values).
        // Row fractions are the same set. 6 x 6 = 36 unique corners.
        let corners = StackBadgeGeometry.cornerPoints(in: laptopFrame)
        XCTAssertEqual(corners.count, 36)
    }

    func testCoincidentCornersAreDeduplicated() {
        // The half corner and the quarter corner at x = width/2 coincide;
        // they must appear once, not once per grid.
        let corners = StackBadgeGeometry.cornerPoints(in: laptopFrame)
        let midTop = corners.filter { abs($0.x - 1168) < 1 && abs($0.y - 1510) < 1 }
        XCTAssertEqual(midTop.count, 1)
    }

    func testScreenOriginIsACorner() {
        let corners = StackBadgeGeometry.cornerPoints(in: laptopFrame)
        XCTAssertTrue(corners.contains { abs($0.x - 0) < 1 && abs($0.y - 1510) < 1 },
                      "top-left of the screen must be a corner")
    }

    func testFarEdgesAreNotCorners() {
        // A cell's top-left can never sit on the right or bottom screen edge.
        let corners = StackBadgeGeometry.cornerPoints(in: laptopFrame)
        XCTAssertFalse(corners.contains { abs($0.x - laptopFrame.maxX) < 1 })
        XCTAssertFalse(corners.contains { abs($0.y - laptopFrame.minY) < 1 })
    }

    func testNegativeOriginScreenCorners() {
        let corners = StackBadgeGeometry.cornerPoints(in: tvFrame)
        XCTAssertEqual(corners.count, 36)
        XCTAssertTrue(corners.contains { abs($0.x - (-5212)) < 1 && abs($0.y - 3670) < 1 },
                      "top-left corner of a negative-origin screen")
        XCTAssertTrue(corners.contains { abs($0.x - (-5212 + 3840.0 / 3)) < 1 && abs($0.y - (3670 - 2160.0 / 3)) < 1 },
                      "interior ninth corner on a negative-origin screen")
    }

    func testEmptyFrameYieldsNoCorners() {
        XCTAssertTrue(StackBadgeGeometry.cornerPoints(in: .zero).isEmpty)
        XCTAssertTrue(StackBadgeGeometry.cornerPoints(in: .null).isEmpty)
    }

    func testHoverZoneHitInsideZone() {
        let corners = [CGPoint(x: 100, y: 500)]
        // 20pt right, 20pt below (AppKit y down = minus y) - inside a 30pt zone.
        let hit = StackBadgeGeometry.corner(near: CGPoint(x: 120, y: 480), in: corners, zone: 30)
        XCTAssertEqual(hit, corners[0])
    }

    func testHoverZoneMissOutsideZone() {
        let corners = [CGPoint(x: 100, y: 500)]
        XCTAssertNil(StackBadgeGeometry.corner(near: CGPoint(x: 140, y: 480), in: corners, zone: 30))
        // Above the corner is the neighboring cell - must not trigger.
        XCTAssertNil(StackBadgeGeometry.corner(near: CGPoint(x: 110, y: 520), in: corners, zone: 30))
        // Left of the corner is the neighboring cell - must not trigger.
        XCTAssertNil(StackBadgeGeometry.corner(near: CGPoint(x: 80, y: 490), in: corners, zone: 30))
    }

    func testHoverZonePicksNearestOfTwoCandidates() {
        let near = CGPoint(x: 100, y: 500)
        let far = CGPoint(x: 90, y: 510)
        let hit = StackBadgeGeometry.corner(near: CGPoint(x: 105, y: 495), in: [far, near], zone: 30)
        XCTAssertEqual(hit, near)
    }

    // Regression: the cascade offset runs +x but UP in AX y (it's applied in
    // AppKit coordinates and the y-axis flips), so clustering must accept
    // origins above the anchor. Real-world origins from a two-window stack
    // that the first implementation failed to count.
    func testStackClusterAcceptsUpwardCascade() {
        let origins = [CGPoint(x: 903, y: -2121), CGPoint(x: 892, y: -2110)]
        let indices = StackBadgeGeometry.stackIndices(among: origins, cascadeRange: 15, tolerance: 4)
        XCTAssertEqual(indices.count, 2)
    }

    // Regression: with maxCascade capped at 1, the second and third windows
    // share an origin. All three belong to the stack.
    func testStackClusterCountsCascadeCapSharedOrigins() {
        let origins = [
            CGPoint(x: 903, y: -2121),
            CGPoint(x: 903, y: -2121),
            CGPoint(x: 892, y: -2110)
        ]
        let indices = StackBadgeGeometry.stackIndices(among: origins, cascadeRange: 15, tolerance: 4)
        XCTAssertEqual(indices.count, 3)
    }

    func testStackClusterExcludesUnrelatedNeighbor() {
        // A window 30pt away from the anchor is a neighbor, not a stack member,
        // even though a gap-widened candidate box may have caught it.
        let origins = [CGPoint(x: 100, y: 100), CGPoint(x: 111, y: 89), CGPoint(x: 130, y: 130)]
        let indices = StackBadgeGeometry.stackIndices(among: origins, cascadeRange: 15, tolerance: 4)
        XCTAssertEqual(indices.sorted(), [0, 1])
    }

    func testStackClusterAcceptsDownwardCascade() {
        // Edge clamping can flip the cascade direction locally; both must count.
        let origins = [CGPoint(x: 100, y: 100), CGPoint(x: 111, y: 111)]
        let indices = StackBadgeGeometry.stackIndices(among: origins, cascadeRange: 15, tolerance: 4)
        XCTAssertEqual(indices.count, 2)
    }

    func testStackClusterEmptyInput() {
        XCTAssertTrue(StackBadgeGeometry.stackIndices(among: [], cascadeRange: 15, tolerance: 4).isEmpty)
    }





    // Regression (review finding): an unrelated window that happens to be the
    // leftmost candidate in the gap-widened box must not mask the real stack.
    func testStackClusterLeftOutlierDoesNotMaskStack() {
        let origins = [
            CGPoint(x: 100, y: 105),   // unrelated leftmost outlier
            CGPoint(x: 120, y: 100),   // buried
            CGPoint(x: 131, y: 89)     // front (cascade +11, -11)
        ]
        let indices = StackBadgeGeometry.stackIndices(among: origins, cascadeRange: 15, tolerance: 4)
        XCTAssertEqual(indices.sorted(), [1, 2])
    }

    func testTodoSidebarWidthUnitInExportArray() {
        let keys = Defaults.array.map { $0.key }
        XCTAssertTrue(keys.contains("todoSidebarWidthUnit"), "todoSidebarWidthUnit missing from Defaults.array")
    }
}

/// The cascade math itself. Asserting the resulting rect matters: an earlier
/// version of this feature was certified by a test that only checked an
/// eligibility flag, while the offset it enabled was a no-op for anyone
/// running the default of no gaps.
class OverlapOffsetGeometryTests: XCTestCase {

    private let screen = CGRect(x: 0, y: 0, width: 1000, height: 800)
    private let offset: CGFloat = 11

    private func cascade(_ rect: CGRect, occupied: [CGPoint], maxCascade: Int = 1) -> CGRect {
        OverlapOffsetGeometry.cascadedRect(rect,
                                           occupiedTopLefts: occupied,
                                           screenFrame: screen,
                                           offset: offset,
                                           maxCascade: maxCascade)
    }

    /// A maximized window with no gaps fills the visible frame, so there is
    /// nowhere to shift it - and the caller skips the window scan entirely.
    func testMaximizedWithoutGapsCannotOffset() {
        let maximized = screen
        XCTAssertFalse(OverlapOffsetGeometry.canOffset(maximized, in: screen, by: offset))
        XCTAssertEqual(cascade(maximized, occupied: [OverlapOffsetGeometry.topLeft(of: maximized)]),
                       maximized)
    }

    /// Gaps larger than the offset leave room, so maximized windows cascade.
    func testMaximizedWithGapsOffsets() {
        let maximized = CGRect(x: 22, y: 22, width: 956, height: 756)
        XCTAssertTrue(OverlapOffsetGeometry.canOffset(maximized, in: screen, by: offset))
        XCTAssertEqual(cascade(maximized, occupied: [OverlapOffsetGeometry.topLeft(of: maximized)]),
                       CGRect(x: 33, y: 33, width: 956, height: 756))
    }

    /// Gaps smaller than the offset must not shift the window part way: it
    /// would end up flush against the far edges, deleting the gaps there.
    func testGapsSmallerThanOffsetDoNotOffset() {
        let maximized = CGRect(x: 5, y: 5, width: 990, height: 790)
        XCTAssertFalse(OverlapOffsetGeometry.canOffset(maximized, in: screen, by: offset))
        XCTAssertEqual(cascade(maximized, occupied: [OverlapOffsetGeometry.topLeft(of: maximized)]),
                       maximized)
    }

    /// A half with no gaps has room across but not up, and still offsets on
    /// the axis that fits - the behavior shipped in v0.96.
    func testHalfOffsetsOnTheAxisWithRoom() {
        let leftHalf = CGRect(x: 0, y: 0, width: 500, height: 800)
        XCTAssertEqual(cascade(leftHalf, occupied: [OverlapOffsetGeometry.topLeft(of: leftHalf)]),
                       CGRect(x: 11, y: 0, width: 500, height: 800))
    }

    func testNoOverlapLeavesTheRectAlone() {
        let leftHalf = CGRect(x: 0, y: 0, width: 500, height: 800)
        XCTAssertEqual(cascade(leftHalf, occupied: [CGPoint(x: 500, y: 800)]), leftHalf)
    }

    func testCascadeStopsAtMaxCascade() {
        let quarter = CGRect(x: 0, y: 0, width: 400, height: 400)
        let occupied = [CGPoint(x: 0, y: 400), CGPoint(x: 11, y: 411), CGPoint(x: 22, y: 422)]
        XCTAssertEqual(cascade(quarter, occupied: occupied, maxCascade: 1).origin,
                       CGPoint(x: 11, y: 11))
        XCTAssertEqual(cascade(quarter, occupied: occupied, maxCascade: 3).origin,
                       CGPoint(x: 33, y: 33))
    }

    /// Matching is by top-left corner, so a smaller window landing on a larger
    /// one at the same corner counts as an overlap - an eighth arriving on a
    /// quarter. Both sit against the top of the screen here, so the window
    /// offsets across but not up.
    func testMatchesMixedSizesAtTheSameCorner() {
        let eighth = CGRect(x: 0, y: 600, width: 250, height: 200)
        let quarterTopLeft = OverlapOffsetGeometry.topLeft(of: CGRect(x: 0, y: 400, width: 500, height: 400))
        XCTAssertEqual(quarterTopLeft, OverlapOffsetGeometry.topLeft(of: eighth))
        XCTAssertEqual(cascade(eighth, occupied: [quarterTopLeft]),
                       CGRect(x: 11, y: 600, width: 250, height: 200))
    }

    func testCoversScreen() {
        XCTAssertTrue(OverlapOffsetGeometry.coversScreen(screen, screenFrame: screen))
        XCTAssertTrue(OverlapOffsetGeometry.coversScreen(CGRect(x: 22, y: 22, width: 956, height: 756),
                                                         screenFrame: screen))
        XCTAssertFalse(OverlapOffsetGeometry.coversScreen(CGRect(x: 0, y: 0, width: 500, height: 800),
                                                          screenFrame: screen))
    }
}

/// Which actions are eligible for the overlap offset. `positionCycles` alone
/// excluded maximize, so two maximized windows landed exactly on top of each
/// other. Eligibility is only half of it - whether an eligible window actually
/// moves is covered by OverlapOffsetGeometryTests.
class OverlapOffsetEligibilityTests: XCTestCase {

    func testMaximizeGetsTheOffset() {
        XCTAssertTrue(WindowAction.maximize.overlapOffsetApplies)
    }

    func testGridPositionsGetTheOffset() {
        for action in [WindowAction.leftHalf, .topLeft, .topLeftSixth,
                       .topLeftNinth, .topLeftEighth, .topLeftTwelfth, .topLeftSixteenth] {
            XCTAssertTrue(action.overlapOffsetApplies, "\(action) should get the overlap offset")
        }
    }

    /// Actions that move or resize in place have no "landed on top of
    /// something" notion, so offsetting them would just displace the window.
    func testMovesAndResizesDoNotGetTheOffset() {
        for action in [WindowAction.center, .restore, .moveLeft, .moveRight, .moveUp, .moveDown,
                       .larger, .smaller, .nextDisplay, .previousDisplay,
                       .almostMaximize, .maximizeHeight, .tileAll, .cascadeAll] {
            XCTAssertFalse(action.overlapOffsetApplies, "\(action) should not get the overlap offset")
        }
    }
}

/// The stacked-window list is driven by an event tap, so it decides which
/// keystrokes to take from the app underneath. Taking the wrong ones would
/// break typing system-wide while the list is open.
class StackBadgeKeyHandlingTests: XCTestCase {

    /// The flags macOS actually puts on an arrow keystroke. Every arrow event
    /// carries them, so a test that passes an empty modifier set is asserting
    /// against an event the system never delivers - which is exactly how a
    /// guard that rejected .function shipped with the suite green.
    private static let arrowFlags: NSEvent.ModifierFlags = [.function, .numericPad]

    private func key(_ code: UInt16, _ modifiers: NSEvent.ModifierFlags = []) -> StackBadgeManager.NavigationKey? {
        StackBadgeManager.navigationKey(forKeyCode: code, modifiers: modifiers)
    }

    func testNavigationKeysAreClaimed() {
        XCTAssertEqual(key(UInt16(kVK_UpArrow), Self.arrowFlags), .up)
        XCTAssertEqual(key(UInt16(kVK_DownArrow), Self.arrowFlags), .down)
        XCTAssertEqual(key(UInt16(kVK_Return)), .commit)
        XCTAssertEqual(key(UInt16(kVK_ANSI_KeypadEnter), .numericPad), .commit)
        XCTAssertEqual(key(UInt16(kVK_Escape)), .escape)
    }

    /// Caps lock is not something the user is holding for this keystroke, and
    /// a window list that stops navigating because caps lock is on would be
    /// its own bug report.
    func testCapsLockStillNavigates() {
        XCTAssertEqual(key(UInt16(kVK_UpArrow), Self.arrowFlags.union(.capsLock)), .up)
    }

    func testOrdinaryKeysArePassedThrough() {
        for code in [kVK_ANSI_A, kVK_ANSI_Q, kVK_Tab, kVK_Space, kVK_Delete, kVK_PageUp, kVK_Home] {
            XCTAssertNil(key(UInt16(code)), "keyCode \(code) must reach the app underneath")
        }
        for code in [kVK_LeftArrow, kVK_RightArrow] {
            XCTAssertNil(key(UInt16(code), Self.arrowFlags),
                         "keyCode \(code) must reach the app underneath")
        }
    }

    /// A held modifier means the keystroke belongs to the frontmost app. Shift
    /// is included deliberately: shift-return inserts a newline in chat apps
    /// and shift-arrow extends a selection, so claiming those would break
    /// ordinary typing whenever the list happened to be open. The arrow cases
    /// carry the flags macOS sends, so the modifier under test is the only
    /// difference from a keystroke that must be claimed.
    func testModifiedKeysArePassedThrough() {
        for modifier in [NSEvent.ModifierFlags.command, .option, .control, .shift] {
            for code in [kVK_UpArrow, kVK_DownArrow] {
                XCTAssertNil(key(UInt16(code), Self.arrowFlags.union(modifier)),
                             "arrow \(code) with \(modifier) must reach the app underneath")
            }
            for code in [kVK_Return, kVK_Escape] {
                XCTAssertNil(key(UInt16(code), modifier),
                             "keyCode \(code) with \(modifier) must reach the app underneath")
            }
        }
        XCTAssertNil(key(UInt16(kVK_UpArrow), Self.arrowFlags.union([.command, .option])))
        XCTAssertNil(key(UInt16(kVK_Return), [.shift]))
    }

    func testSelectionClampsAtBothEnds() {
        XCTAssertEqual(StackBadgeManager.selection(from: 0, movedBy: -1, count: 4), 0)
        XCTAssertEqual(StackBadgeManager.selection(from: 3, movedBy: 1, count: 4), 3)
        XCTAssertEqual(StackBadgeManager.selection(from: 1, movedBy: 1, count: 4), 2)
        XCTAssertEqual(StackBadgeManager.selection(from: 1, movedBy: -1, count: 4), 0)
    }

    func testSelectionWithNoRowsIsNil() {
        XCTAssertNil(StackBadgeManager.selection(from: 0, movedBy: 1, count: 0))
    }

    /// Rows that would be clipped are never built, so the arrow keys can't
    /// select - and Return can't raise - a window with no visible row.
    func testRowsThatFitIsBoundedByTheScreenBottom() {
        XCTAssertEqual(StackBadgeManager.rowsThatFit(below: 500, above: 0), 22)
        XCTAssertEqual(StackBadgeManager.rowsThatFit(below: 60, above: 0), 2)
        XCTAssertEqual(StackBadgeManager.rowsThatFit(below: 10, above: 0), 0)
        XCTAssertEqual(StackBadgeManager.rowsThatFit(below: 0, above: 100), 0)
    }
}

/// Which windows at a shared corner count as one stack. A window covering the
/// screen shares its corner with every half and corner placement, so it can
/// only join a stack, never create one - otherwise an everyday layout (one
/// maximized window, one tiled to the left half) reads as a stack of two.
/// Size plays no part in stack membership. A window pegged to the corner is in
/// the stack whether it is maximized or a sixteenth - and a maximized window
/// sitting on a smaller one is the case where the smaller window cannot be
/// seen any other way, which is what the list exists to reveal.
///
/// The list briefly excluded screen-covering windows, borrowed from the
/// overlap offset where the exclusion is necessary (a maximized window shares
/// its origin with every placement and would otherwise shift them all, #1766).
/// The list moves nothing, so it never needed it, and the exclusion made a
/// maximized window over a half-screen window show no list at all.
class StackBadgeSizeAgnosticTests: XCTestCase {

    private let corner = CGPoint(x: 0, y: 0)
    private let cascaded = CGPoint(x: 11, y: -11)

    private func stack(_ origins: [CGPoint]) -> [Int] {
        StackBadgeGeometry.stackIndices(among: origins, cascadeRange: 15, tolerance: 4)
    }

    /// The reported case: one maximized window over one half-screen window,
    /// both pegged to the same corner, showed nothing at all.
    func testMaximizedOverTiledIsAStack() {
        XCTAssertEqual(stack([corner, corner]).sorted(), [0, 1])
    }

    /// The maximized windows carry the overlap offset, so they sit a cascade
    /// step forward of the tiled window they hide.
    func testOffsetMaximizedWindowsStillIncludeTheTiledOneBeneath() {
        XCTAssertEqual(stack([cascaded, cascaded, corner]).sorted(), [0, 1, 2])
    }

    func testSeveralMaximizedWindowsAreAStack() {
        XCTAssertEqual(stack([corner, cascaded]).count, 2)
    }

    func testTiledStackIsUnaffected() {
        XCTAssertEqual(stack([corner, cascaded]).count, 2)
    }

    /// This returns the densest cluster, which for a single window is that
    /// window; the caller is what requires two before showing anything.
    func testLoneWindowIsItsOwnClusterAndTheCallerRejectsIt() {
        XCTAssertEqual(stack([corner]), [0])
    }

    func testWindowAtAnotherCornerIsNotInTheCluster() {
        XCTAssertEqual(stack([corner, CGPoint(x: 900, y: 0)]).count, 1)
    }
}

class ChangeSizeCalculationTests: XCTestCase {
    private let visibleFrame = CGRect(x: 0, y: 0, width: 2560, height: 1415)
    private let issueWindowRect = CGRect(x: 1895, y: 0, width: 665, height: 1415)
    private var minimumWindowWidth: Double = 0
    private var minimumWindowHeight: Double = 0
    private var sizeOffset: Float = 0
    private var sizeScalingMode: SizeScalingMode = .percentage
    private var sizeScalePercent: Float = 0
    private var gapSize: Float = 0
    private var curtainChangeSize: Bool?
    private var storedMinimumWindowWidth: Any?
    private var storedMinimumWindowHeight: Any?

    override func setUp() {
        super.setUp()

        minimumWindowWidth = Defaults.minimumWindowWidth.value
        minimumWindowHeight = Defaults.minimumWindowHeight.value
        sizeOffset = Defaults.sizeOffset.value
        sizeScalingMode = Defaults.sizeScalingMode.value
        sizeScalePercent = Defaults.sizeScalePercent.value
        gapSize = Defaults.gapSize.value
        curtainChangeSize = Defaults.curtainChangeSize.enabled
        storedMinimumWindowWidth = UserDefaults.standard.object(forKey: Defaults.minimumWindowWidth.key)
        storedMinimumWindowHeight = UserDefaults.standard.object(forKey: Defaults.minimumWindowHeight.key)

        Defaults.minimumWindowWidth.value = 0
        Defaults.minimumWindowHeight.value = 0
        Defaults.sizeOffset.value = 30
        Defaults.sizeScalingMode.value = .percentage
        Defaults.sizeScalePercent.value = 5
        Defaults.gapSize.value = 0
        Defaults.curtainChangeSize.enabled = true
    }

    override func tearDown() {
        Defaults.minimumWindowWidth.value = minimumWindowWidth
        Defaults.minimumWindowHeight.value = minimumWindowHeight
        restoreStoredValue(storedMinimumWindowWidth, for: Defaults.minimumWindowWidth.key)
        restoreStoredValue(storedMinimumWindowHeight, for: Defaults.minimumWindowHeight.key)
        Defaults.sizeOffset.value = sizeOffset
        Defaults.sizeScalingMode.value = sizeScalingMode
        Defaults.sizeScalePercent.value = sizeScalePercent
        Defaults.gapSize.value = gapSize
        Defaults.curtainChangeSize.enabled = curtainChangeSize

        super.tearDown()
    }

    func testExplicitZeroDisablesScreenFractionMinimum() {
        let result = smallerResult(for: issueWindowRect)
        XCTAssertEqual(result.width * 1.05, issueWindowRect.width, accuracy: 0.0001)
        XCTAssertEqual(result.height * 1.05, issueWindowRect.height, accuracy: 0.0001)
        XCTAssertEqual(result.maxX, visibleFrame.maxX, accuracy: 0.0001)
        XCTAssertEqual(result.midY, issueWindowRect.midY, accuracy: 0.0001)
    }

    func testDoubleDefaultDistinguishesAbsentFromExplicitZero() {
        let key = "ChangeSizeCalculationTests.minimumWindowWidth"
        UserDefaults.standard.removeObject(forKey: key)
        defer { UserDefaults.standard.removeObject(forKey: key) }

        let absentPreference = DoubleDefault(key: key, defaultValue: 0.25)
        XCTAssertEqual(absentPreference.value, 0.25)
        XCTAssertEqual(absentPreference.toCodable().double, 0.25)
        XCTAssertNil(absentPreference.toCodable().float)

        absentPreference.value = 0
        let explicitZeroPreference = DoubleDefault(key: key, defaultValue: 0.25)
        XCTAssertEqual(explicitZeroPreference.value, 0)
        XCTAssertEqual(explicitZeroPreference.toCodable().double, 0)
        XCTAssertNil(explicitZeroPreference.toCodable().float)
    }

    func testDoubleDefaultLoadsLegacyFloatAndNewDoubleConfigValues() throws {
        let key = "ChangeSizeCalculationTests.minimumWindowWidthConfig"
        UserDefaults.standard.removeObject(forKey: key)
        defer { UserDefaults.standard.removeObject(forKey: key) }

        let preference = DoubleDefault(key: key, defaultValue: 0.25)
        let legacyZero = try JSONDecoder().decode(
            CodableDefault.self,
            from: Data(#"{"float":0}"#.utf8)
        )
        let legacyFraction = try JSONDecoder().decode(
            CodableDefault.self,
            from: Data(#"{"float":0.01}"#.utf8)
        )
        let currentZero = try JSONDecoder().decode(
            CodableDefault.self,
            from: Data(#"{"double":0}"#.utf8)
        )
        let currentFraction = try JSONDecoder().decode(
            CodableDefault.self,
            from: Data(#"{"double":0.123456789012345}"#.utf8)
        )

        preference.load(from: legacyZero)
        XCTAssertEqual(preference.value, 0.25)

        preference.load(from: legacyFraction)
        XCTAssertEqual(preference.value, Double(Float(0.01)))

        preference.load(from: currentFraction)
        XCTAssertEqual(preference.value, 0.123456789012345)

        preference.load(from: currentZero)
        XCTAssertEqual(preference.value, 0)
    }

    func testSmallerCanReachExactConfiguredMinimum() {
        Defaults.minimumWindowWidth.value = 0.25
        let windowRect = CGRect(x: 1890, y: 0, width: 670, height: 1415)

        let result = smallerResult(for: windowRect)
        XCTAssertEqual(result.width, 640, accuracy: 0.0001)
        XCTAssertEqual(result.width / windowRect.width,
                       result.height / windowRect.height, accuracy: 0.0001)
    }

    func testSmallerHonorsConfiguredScreenFractionMinimum() {
        Defaults.minimumWindowWidth.value = 0.25

        let result = smallerResult(for: issueWindowRect)
        XCTAssertEqual(result.width, 640, accuracy: 0.0001)
        XCTAssertEqual(result.width / issueWindowRect.width,
                       result.height / issueWindowRect.height, accuracy: 0.0001)
    }

    func testSmallerScalesBothDimensionsOfFullHeightWindow() {
        let fullHeightHalf = CGRect(x: 0, y: 0, width: 1280, height: 1415)

        let result = smallerResult(for: fullHeightHalf)
        XCTAssertEqual(result.width * 1.05, fullHeightHalf.width, accuracy: 0.0001)
        XCTAssertEqual(result.height * 1.05, fullHeightHalf.height, accuracy: 0.0001)
        XCTAssertEqual(result.minX, fullHeightHalf.minX, accuracy: 0.0001)
        XCTAssertEqual(result.midY, fullHeightHalf.midY, accuracy: 0.0001)
    }

    func testSmallConfiguredScreenFractionAllowsIssueRegressionStep() {
        Defaults.minimumWindowWidth.value = 0.01

        let result = smallerResult(for: issueWindowRect)
        XCTAssertEqual(result.width * 1.05, issueWindowRect.width, accuracy: 0.0001)
        XCTAssertEqual(result.height * 1.05, issueWindowRect.height, accuracy: 0.0001)
    }

    func testExplicitZeroStillRejectsNonpositiveSize() {
        let narrowWindow = CGRect(x: 100, y: 100, width: 1, height: 100)

        XCTAssertEqual(smallerResult(for: narrowWindow), narrowWindow)
    }

    private func smallerResult(for windowRect: CGRect) -> CGRect {
        ChangeSizeCalculation().calculateRect(
            RectCalculationParameters(window: Window(id: 1, rect: windowRect),
                                      visibleFrameOfScreen: visibleFrame,
                                      action: .smaller,
                                      lastAction: nil)
        ).rect
    }

    private func restoreStoredValue(_ value: Any?, for key: String) {
        if let value {
            UserDefaults.standard.set(value, forKey: key)
        } else {
            UserDefaults.standard.removeObject(forKey: key)
        }
    }
}

class EnhancedUITests: XCTestCase {
    private func adjustmentEvents(
        mode: EnhancedUI,
        bundleIdentifier: String? = "com.google.Chrome",
        builtInAssistiveTechnologyEnabled: Bool = false,
        initialEnhancedUI: Bool?
    ) -> [String] {
        var events = [String]()
        mode.performWindowAdjustment(
            bundleIdentifier: bundleIdentifier,
            builtInAssistiveTechnologyEnabled: builtInAssistiveTechnologyEnabled,
            readEnhancedUI: {
                events.append("read")
                return initialEnhancedUI
            },
            writeEnhancedUI: { events.append("write:\($0)") },
            adjustment: { events.append("adjust") }
        )
        return events
    }

    func testAutomaticModeLeavesEnhancedUIDisabledForChromium() {
        XCTAssertEqual(
            adjustmentEvents(mode: .automatic, initialEnhancedUI: true),
            ["read", "write:false", "adjust"]
        )
    }

    func testAutomaticModeRestoresEnhancedUIForOtherApps() {
        XCTAssertEqual(
            adjustmentEvents(
                mode: .automatic,
                bundleIdentifier: "com.apple.Safari",
                initialEnhancedUI: true
            ),
            ["read", "write:false", "adjust", "write:true"]
        )
        XCTAssertEqual(
            adjustmentEvents(
                mode: .automatic,
                bundleIdentifier: nil,
                initialEnhancedUI: true
            ),
            ["read", "write:false", "adjust", "write:true"]
        )
    }

    func testAutomaticModeRestoresEnhancedUIForBuiltInAssistiveTechnology() {
        XCTAssertEqual(
            adjustmentEvents(
                mode: .automatic,
                builtInAssistiveTechnologyEnabled: true,
                initialEnhancedUI: true
            ),
            ["read", "write:false", "adjust", "write:true"]
        )
    }

    func testExplicitModesKeepTheirExistingRestoreBehavior() {
        XCTAssertEqual(
            adjustmentEvents(mode: .disableEnable, initialEnhancedUI: true),
            ["read", "write:false", "adjust", "write:true"]
        )
        XCTAssertEqual(
            adjustmentEvents(mode: .disableOnly, initialEnhancedUI: true),
            ["read", "write:false", "adjust"]
        )
        XCTAssertEqual(
            adjustmentEvents(mode: .frontmostDisable, initialEnhancedUI: true),
            ["read", "write:false", "adjust"]
        )
    }

    func testDisabledOrUnavailableEnhancedUIDoesNotWrite() {
        XCTAssertEqual(
            adjustmentEvents(mode: .automatic, initialEnhancedUI: false),
            ["read", "adjust"]
        )
        XCTAssertEqual(
            adjustmentEvents(mode: .automatic, initialEnhancedUI: nil),
            ["read", "adjust"]
        )
    }

    func testApplicationActivationPolicy() {
        XCTAssertTrue(
            EnhancedUI.automatic.disablesEnhancedUIOnApplicationActivation(
                bundleIdentifier: "com.google.Chrome",
                builtInAssistiveTechnologyEnabled: false
            )
        )
        XCTAssertFalse(
            EnhancedUI.automatic.disablesEnhancedUIOnApplicationActivation(
                bundleIdentifier: "com.google.Chrome",
                builtInAssistiveTechnologyEnabled: true
            )
        )
        XCTAssertFalse(
            EnhancedUI.automatic.disablesEnhancedUIOnApplicationActivation(
                bundleIdentifier: "com.apple.Safari",
                builtInAssistiveTechnologyEnabled: false
            )
        )
        XCTAssertFalse(
            EnhancedUI.automatic.disablesEnhancedUIOnApplicationActivation(
                bundleIdentifier: nil,
                builtInAssistiveTechnologyEnabled: false
            )
        )
        XCTAssertTrue(
            EnhancedUI.frontmostDisable.disablesEnhancedUIOnApplicationActivation(
                bundleIdentifier: "com.apple.Safari",
                builtInAssistiveTechnologyEnabled: true
            )
        )
        XCTAssertFalse(
            EnhancedUI.disableEnable.disablesEnhancedUIOnApplicationActivation(
                bundleIdentifier: "com.google.Chrome",
                builtInAssistiveTechnologyEnabled: false
            )
        )
        XCTAssertFalse(
            EnhancedUI.disableOnly.disablesEnhancedUIOnApplicationActivation(
                bundleIdentifier: "com.google.Chrome",
                builtInAssistiveTechnologyEnabled: false
            )
        )
    }

    func testKnownChromiumBrowserBundleIdentifiers() {
        let matchingBundleIdentifiers = [
            "com.google.Chrome",
            "com.google.Chrome.canary",
            "org.chromium.Chromium",
            "com.microsoft.edgemac",
            "com.microsoft.edgemac.Beta",
            "com.brave.Browser",
            "com.brave.Browser.nightly",
            "com.vivaldi.Vivaldi",
            "com.operasoftware.Opera",
            "com.operasoftware.OperaNext",
            "com.operasoftware.OperaDeveloper",
            "com.operasoftware.OperaNightly",
            "com.operasoftware.OperaGX",
            "com.operasoftware.OperaGXNext",
            "com.operasoftware.OperaGXDeveloper",
            "com.operasoftware.OperaGXNightly",
            "company.thebrowser.Browser",
            "company.thebrowser.dia",
            "ai.perplexity.comet",
            "com.openai.atlas"
        ]
        let nonmatchingBundleIdentifiers: [String?] = [
            nil,
            "com.apple.Safari",
            "com.google.Chromecast",
            "com.google.ChromeHelper",
            "com.brave.BrowserHelper"
        ]

        for bundleIdentifier in matchingBundleIdentifiers {
            XCTAssertTrue(EnhancedUI.isKnownChromiumBrowser(bundleIdentifier: bundleIdentifier))
        }
        for bundleIdentifier in nonmatchingBundleIdentifiers {
            XCTAssertFalse(EnhancedUI.isKnownChromiumBrowser(bundleIdentifier: bundleIdentifier))
        }
    }

    func testEnhancedUIPreferenceMigrationAndRawValues() {
        let key = "RectangleTests.enhancedUI.\(UUID().uuidString)"
        defer { UserDefaults.standard.removeObject(forKey: key) }

        let absentPreference = IntEnumDefault<EnhancedUI>(
            key: key,
            defaultValue: .automatic,
            invalidValueFallback: .disableEnable
        )
        XCTAssertEqual(absentPreference.value.rawValue, 4)

        UserDefaults.standard.set(0, forKey: key)
        let legacyZeroPreference = IntEnumDefault<EnhancedUI>(
            key: key,
            defaultValue: .automatic,
            invalidValueFallback: .disableEnable
        )
        XCTAssertEqual(legacyZeroPreference.value.rawValue, 1)

        for rawValue in 1...4 {
            UserDefaults.standard.set(rawValue, forKey: key)
            let preference = IntEnumDefault<EnhancedUI>(
                key: key,
                defaultValue: .automatic,
                invalidValueFallback: .disableEnable
            )
            XCTAssertEqual(preference.value.rawValue, rawValue)
        }

        legacyZeroPreference.load(from: CodableDefault(int: 0))
        XCTAssertEqual(legacyZeroPreference.value.rawValue, 1)
    }
}

class CooperativeCornerResizeTests: XCTestCase {
    private let screenFrame = CGRect(x: 0, y: 0, width: 1200, height: 900)
    private let minimumSize = CGSize(width: 100, height: 100)
    private let tolerance: CGFloat = 8

    func testBottomLeftVerticalExpansionShrinksTopLeftNeighbor() {
        let focusedOld = CGRect(x: 0, y: 0, width: 800, height: 300)
        let focusedNew = CGRect(x: 0, y: 0, width: 800, height: 600)
        let topLeft = CooperativeCornerResize.Candidate(id: 2, frame: CGRect(x: 0, y: 300, width: 800, height: 600))

        let adjustments = cooperativeAdjustments(focusedOld: focusedOld, focusedNew: focusedNew, candidates: [topLeft], axis: .vertical)

        XCTAssertEqual(adjustments.count, 1)
        assertRect(adjustments[0].newFrame, equals: CGRect(x: 0, y: 600, width: 800, height: 300))
        XCTAssertEqual(focusedNew.maxY, adjustments[0].newFrame.minY, accuracy: 0.001)
    }

    func testBottomLeftVerticalExpansionKeepsFullTwoThirdsWhenFeasible() {
        let focusedOld = CGRect(x: 0, y: 0, width: 800, height: 300)
        let focusedNew = CGRect(x: 0, y: 0, width: 800, height: 600)
        let topLeft = CooperativeCornerResize.Candidate(id: 2, frame: CGRect(x: 0, y: 300, width: 800, height: 600))

        guard let plan = cooperativePlan(focusedOld: focusedOld, focusedNew: focusedNew, candidates: [topLeft], axis: .vertical) else {
            XCTFail("Expected cooperative resize plan")
            return
        }

        assertRect(plan.focusedFrame, equals: focusedNew)
        assertRect(plan.adjustments[0].newFrame, equals: CGRect(x: 0, y: 600, width: 800, height: 300))
    }

    func testBottomLeftVerticalExpansionIsReducedByCooperatingMinimumHeight() {
        let focusedOld = CGRect(x: 0, y: 0, width: 800, height: 300)
        let focusedNew = CGRect(x: 0, y: 0, width: 800, height: 600)
        let topLeft = CooperativeCornerResize.Candidate(id: 2,
                                                        frame: CGRect(x: 0, y: 300, width: 800, height: 600),
                                                        minimumSize: CGSize(width: 100, height: 400))

        guard let plan = cooperativePlan(focusedOld: focusedOld, focusedNew: focusedNew, candidates: [topLeft], axis: .vertical) else {
            XCTFail("Expected cooperative resize plan")
            return
        }

        assertRect(plan.focusedFrame, equals: CGRect(x: 0, y: 0, width: 800, height: 500))
        assertRect(plan.adjustments[0].newFrame, equals: CGRect(x: 0, y: 500, width: 800, height: 400))
        XCTAssertTrue(plan.debugLog.contains { $0.contains("reduced requested movement") })
    }

    func testBottomLeftVerticalExpansionUsesVisibleFrameInsteadOfRawScreenFrame() {
        let visibleFrame = CGRect(x: 0, y: 0, width: 1200, height: 840)
        let focusedOld = CGRect(x: 0, y: 0, width: 800, height: 300)
        let focusedNew = CGRect(x: 0, y: 0, width: 800, height: 600)
        let topLeft = CooperativeCornerResize.Candidate(id: 2,
                                                        frame: CGRect(x: 0, y: 300, width: 800, height: 600),
                                                        minimumSize: CGSize(width: 100, height: 300))

        guard let plan = cooperativePlan(focusedOld: focusedOld,
                                         focusedNew: focusedNew,
                                         screenFrame: visibleFrame,
                                         candidates: [topLeft],
                                         axis: .vertical) else {
            XCTFail("Expected cooperative resize plan")
            return
        }

        assertRect(plan.focusedFrame, equals: CGRect(x: 0, y: 0, width: 800, height: 540))
        assertRect(plan.adjustments[0].newFrame, equals: CGRect(x: 0, y: 540, width: 800, height: 300))
        XCTAssertLessThanOrEqual(plan.adjustments[0].newFrame.maxY, visibleFrame.maxY)
    }

    func testVerticalExpansionRoundsSharedEdgeAtOneThirdTwoThirdsBoundary() {
        let screenFrame = CGRect(x: 0, y: 0, width: 1200, height: 1000)
        let oneThird = screenFrame.height / 3.0
        let twoThirds = screenFrame.height * 2.0 / 3.0
        let focusedOld = CGRect(x: 0, y: 0, width: 800, height: oneThird)
        let focusedNew = CGRect(x: 0, y: 0, width: 800, height: twoThirds)
        let topLeft = CooperativeCornerResize.Candidate(id: 2, frame: CGRect(x: 0, y: oneThird, width: 800, height: twoThirds))

        guard let plan = cooperativePlan(focusedOld: focusedOld,
                                         focusedNew: focusedNew,
                                         screenFrame: screenFrame,
                                         candidates: [topLeft],
                                         axis: .vertical) else {
            XCTFail("Expected cooperative resize plan")
            return
        }

        assertRect(plan.focusedFrame, equals: CGRect(x: 0, y: 0, width: 800, height: 667))
        assertRect(plan.adjustments[0].newFrame, equals: CGRect(x: 0, y: 667, width: 800, height: 333))
        XCTAssertEqual(plan.focusedFrame.maxY, plan.adjustments[0].newFrame.minY, accuracy: 0.001)
    }

    func testAffectedWindowsReceiveOneFinalFrameEach() {
        let focusedOld = CGRect(x: 0, y: 0, width: 800, height: 900)
        let focusedNew = CGRect(x: 0, y: 0, width: 400, height: 900)
        let bottomLeft = CooperativeCornerResize.Candidate(id: 2, frame: CGRect(x: 0, y: 0, width: 800, height: 300))
        let bottomRight = CooperativeCornerResize.Candidate(id: 3, frame: CGRect(x: 800, y: 0, width: 400, height: 300))
        let topRight = CooperativeCornerResize.Candidate(id: 4, frame: CGRect(x: 800, y: 300, width: 400, height: 600))

        guard let plan = cooperativePlan(focusedOld: focusedOld,
                                         focusedNew: focusedNew,
                                         candidates: [bottomLeft, bottomRight, topRight],
                                         axis: .horizontal) else {
            XCTFail("Expected cooperative resize plan")
            return
        }

        let adjustedIds = plan.adjustments.map(\.id)
        XCTAssertEqual(adjustedIds.count, Set(adjustedIds).count)
        XCTAssertEqual(adjustedIds.sorted(), [2, 3, 4])
    }

    func testUnrelatedWindowsAreNotMoved() {
        let focusedOld = CGRect(x: 0, y: 0, width: 800, height: 300)
        let focusedNew = CGRect(x: 0, y: 0, width: 800, height: 600)
        let topLeft = CooperativeCornerResize.Candidate(id: 2, frame: CGRect(x: 0, y: 300, width: 800, height: 600))
        let unrelated = CooperativeCornerResize.Candidate(id: 3, frame: CGRect(x: 850, y: 50, width: 250, height: 250))

        guard let plan = cooperativePlan(focusedOld: focusedOld,
                                         focusedNew: focusedNew,
                                         candidates: [topLeft, unrelated],
                                         axis: .vertical) else {
            XCTFail("Expected cooperative resize plan")
            return
        }

        XCTAssertEqual(plan.adjustments.map(\.id), [topLeft.id])
    }

    func testNearGridNeighborIsDetectedAndNormalized() {
        let focusedOld = CGRect(x: 0, y: 0, width: 800, height: 300)
        let focusedNew = CGRect(x: 0, y: 0, width: 800, height: 600)
        let terminalLikeTop = CooperativeCornerResize.Candidate(id: 2, frame: CGRect(x: 5, y: 304, width: 790, height: 596))

        guard let plan = cooperativePlan(focusedOld: focusedOld,
                                         focusedNew: focusedNew,
                                         candidates: [terminalLikeTop],
                                         axis: .vertical,
                                         tolerance: 20) else {
            XCTFail("Expected cooperative resize plan")
            return
        }

        assertRect(plan.adjustments[0].newFrame, equals: CGRect(x: 0, y: 600, width: 800, height: 300))
    }

    func testInitialCornerPushPlansAgainstRequestedSharedBoundary() {
        let focusedOld = CGRect(x: 225, y: 120, width: 420, height: 360)
        let focusedNew = CGRect(x: 0, y: 0, width: 600, height: 450)
        let topLeft = CooperativeCornerResize.Candidate(id: 2, frame: CGRect(x: 0, y: 450, width: 600, height: 450))

        guard let plan = cooperativePlan(focusedOld: focusedOld,
                                         focusedNew: focusedNew,
                                         candidates: [topLeft],
                                         axis: .vertical,
                                         movedEdgeOverride: .top,
                                         candidateDiscoveryFrame: focusedNew,
                                         actionDescription: "initial corner/side cooperative placement") else {
            XCTFail("Expected initial cooperative placement plan")
            return
        }

        assertRect(plan.focusedFrame, equals: focusedNew)
        assertRect(plan.adjustments[0].newFrame, equals: topLeft.frame)
        XCTAssertFalse(CooperativeCornerResize.frameNeedsApplication(currentFrame: topLeft.frame,
                                                                     solvedFrame: plan.adjustments[0].newFrame,
                                                                     screenFrame: screenFrame,
                                                                     layoutTolerance: 4))
        XCTAssertTrue(plan.debugLog.contains { $0.contains("initial corner/side cooperative placement") })
    }

    func testInitialCornerPushWithOversizedFocusedMinimumMovesBoundaryBeforeOverlap() {
        let focusedOld = CGRect(x: 225, y: 120, width: 420, height: 360)
        let focusedNew = CGRect(x: 0, y: 0, width: 600, height: 450)
        let topLeft = CooperativeCornerResize.Candidate(id: 2, frame: CGRect(x: 0, y: 450, width: 600, height: 450))

        guard let plan = cooperativePlan(focusedOld: focusedOld,
                                         focusedNew: focusedNew,
                                         candidates: [topLeft],
                                         axis: .vertical,
                                         focusedMinimumSize: CGSize(width: 100, height: 520),
                                         movedEdgeOverride: .top,
                                         candidateDiscoveryFrame: focusedNew) else {
            XCTFail("Expected oversized focused cooperative placement plan")
            return
        }

        assertRect(plan.focusedFrame, equals: CGRect(x: 0, y: 0, width: 600, height: 520))
        assertRect(plan.adjustments[0].newFrame, equals: CGRect(x: 0, y: 520, width: 600, height: 380))
        XCTAssertEqual(plan.focusedFrame.maxY, plan.adjustments[0].newFrame.minY, accuracy: 0.001)
        XCTAssertLessThanOrEqual(plan.adjustments[0].newFrame.maxY, screenFrame.maxY)
    }

    func testInitialSidePushWithOversizedNeighborGivesFocusedWindowPartialTarget() {
        let focusedOld = CGRect(x: 180, y: 80, width: 480, height: 640)
        let focusedNew = CGRect(x: 0, y: 0, width: 600, height: 900)
        let rightSide = CooperativeCornerResize.Candidate(id: 2,
                                                          frame: CGRect(x: 600, y: 0, width: 600, height: 900),
                                                          minimumSize: CGSize(width: 700, height: 100))

        guard let plan = cooperativePlan(focusedOld: focusedOld,
                                         focusedNew: focusedNew,
                                         candidates: [rightSide],
                                         axis: .horizontal,
                                         movedEdgeOverride: .right,
                                         candidateDiscoveryFrame: focusedNew) else {
            XCTFail("Expected initial side cooperative placement plan")
            return
        }

        assertRect(plan.focusedFrame, equals: CGRect(x: 0, y: 0, width: 500, height: 900))
        assertRect(plan.adjustments[0].newFrame, equals: CGRect(x: 500, y: 0, width: 700, height: 900))
        XCTAssertEqual(plan.focusedFrame.maxX, plan.adjustments[0].newFrame.minX, accuracy: 0.001)
    }

    func testInitialCornerPushWithOversizedFocusedWindowAdjustsBothAxesWithoutSpill() {
        let focusedOld = CGRect(x: 250, y: 160, width: 320, height: 260)
        let focusedNew = CGRect(x: 0, y: 0, width: 400, height: 450)
        let topLeft = CooperativeCornerResize.Candidate(id: 2, frame: CGRect(x: 0, y: 450, width: 400, height: 450))

        guard let plan = cooperativePlan(focusedOld: focusedOld,
                                         focusedNew: focusedNew,
                                         candidates: [topLeft],
                                         axis: .vertical,
                                         focusedMinimumSize: CGSize(width: 700, height: 520),
                                         movedEdgeOverride: .top,
                                         candidateDiscoveryFrame: focusedNew) else {
            XCTFail("Expected both-axis oversized cooperative placement plan")
            return
        }

        assertRect(plan.focusedFrame, equals: CGRect(x: 0, y: 0, width: 700, height: 520))
        assertRect(plan.adjustments[0].newFrame, equals: CGRect(x: 0, y: 520, width: 400, height: 380))
        XCTAssertLessThanOrEqual(plan.focusedFrame.maxX, screenFrame.maxX)
        XCTAssertLessThanOrEqual(plan.adjustments[0].newFrame.maxY, screenFrame.maxY)
        XCTAssertEqual(plan.focusedFrame.maxY, plan.adjustments[0].newFrame.minY, accuracy: 0.001)
        XCTAssertFalse(plan.focusedFrame.intersects(plan.adjustments[0].newFrame))
    }

    func testExistingCorrectInitialLayoutIsNoOpForAllSolvedFrames() {
        let focusedOld = CGRect(x: 0, y: 0, width: 800, height: 600)
        let focusedNew = focusedOld
        let topLeft = CooperativeCornerResize.Candidate(id: 2, frame: CGRect(x: 0, y: 600, width: 800, height: 300))

        guard let plan = cooperativePlan(focusedOld: focusedOld,
                                         focusedNew: focusedNew,
                                         candidates: [topLeft],
                                         axis: .vertical,
                                         movedEdgeOverride: .top,
                                         candidateDiscoveryFrame: focusedNew) else {
            XCTFail("Expected cooperative no-op plan")
            return
        }

        XCTAssertFalse(CooperativeCornerResize.frameNeedsApplication(currentFrame: focusedOld,
                                                                     solvedFrame: plan.focusedFrame,
                                                                     screenFrame: screenFrame,
                                                                     layoutTolerance: 4))
        XCTAssertFalse(CooperativeCornerResize.frameNeedsApplication(currentFrame: topLeft.frame,
                                                                     solvedFrame: plan.adjustments[0].newFrame,
                                                                     screenFrame: screenFrame,
                                                                     layoutTolerance: 4))
    }

    func testInitialCornerPlacementPreservesExplicitlyShrunkOccupiedCell() {
        let focusedOld = CGRect(x: 225, y: 120, width: 420, height: 360)
        let focusedDefault = CGRect(x: 0, y: 300, width: 800, height: 600)
        let topLeft = CooperativeCornerResize.Candidate(id: 2, frame: CGRect(x: 0, y: 600, width: 800, height: 300))
        let bottomLeft = CooperativeCornerResize.Candidate(id: 3, frame: CGRect(x: 0, y: 0, width: 800, height: 600))
        let focusedNew = CooperativeCornerResize.focusedFramePreservingOccupiedCell(requestedFocusedFrame: focusedDefault,
                                                                                    screenFrame: screenFrame,
                                                                                    candidates: [topLeft, bottomLeft],
                                                                                    axis: .vertical,
                                                                                    movedEdge: .bottom,
                                                                                    tolerance: tolerance)

        guard let plan = cooperativePlan(focusedOld: focusedOld,
                                         focusedNew: focusedNew,
                                         candidates: [topLeft, bottomLeft],
                                         axis: .vertical,
                                         captureTolerance: 72,
                                         movedEdgeOverride: .bottom,
                                         candidateDiscoveryFrame: focusedNew,
                                         actionDescription: "initial corner/side cooperative placement") else {
            XCTFail("Expected initial cooperative placement plan")
            return
        }

        assertRect(focusedNew, equals: topLeft.frame)
        assertRect(plan.focusedFrame, equals: topLeft.frame)
        assertRect(plan.adjustments[0].newFrame, equals: topLeft.frame)
        assertRect(plan.adjustments[1].newFrame, equals: bottomLeft.frame)
    }

    func testInitialCornerPlacementUsesLargerRealizedBoundaryBeforePlanning() {
        let focusedOld = CGRect(x: 225, y: 120, width: 420, height: 360)
        let focusedDefault = CGRect(x: 400, y: 600, width: 800, height: 300)
        let constrainedTopRight = CooperativeCornerResize.Candidate(id: 2,
                                                                    frame: CGRect(x: 400, y: 540, width: 800, height: 360))
        let focusedNew = CooperativeCornerResize.focusedFrameResolvingRealizedCornerBoundary(requestedFocusedFrame: focusedDefault,
                                                                                             screenFrame: screenFrame,
                                                                                             candidates: [constrainedTopRight],
                                                                                             axis: .vertical,
                                                                                             movedEdge: .bottom,
                                                                                             tolerance: tolerance)

        guard let plan = cooperativePlan(focusedOld: focusedOld,
                                         focusedNew: focusedNew,
                                         candidates: [constrainedTopRight],
                                         axis: .vertical,
                                         movedEdgeOverride: .bottom,
                                         candidateDiscoveryFrame: focusedNew,
                                         actionDescription: "initial corner/side cooperative placement") else {
            XCTFail("Expected initial cooperative placement plan")
            return
        }

        assertRect(focusedNew, equals: constrainedTopRight.frame)
        assertRect(plan.focusedFrame, equals: constrainedTopRight.frame)
        assertRect(plan.adjustments[0].newFrame, equals: constrainedTopRight.frame)
        XCTAssertFalse(CooperativeCornerResize.frameNeedsApplication(currentFrame: constrainedTopRight.frame,
                                                                     solvedFrame: plan.adjustments[0].newFrame,
                                                                     screenFrame: screenFrame,
                                                                     layoutTolerance: 4))
    }

    func testInitialCornerPlacementUsesObservedCyclicBoundaryBeforePlanning() {
        let focusedDefault = CGRect(x: 400, y: 600, width: 800, height: 300)
        let cycledTopRight = CooperativeCornerResize.Candidate(id: 2,
                                                               frame: CGRect(x: 400, y: 300, width: 800, height: 600))

        let focusedNew = CooperativeCornerResize.focusedFrameResolvingRealizedCornerBoundary(requestedFocusedFrame: focusedDefault,
                                                                                             screenFrame: screenFrame,
                                                                                             candidates: [cycledTopRight],
                                                                                             axis: .vertical,
                                                                                             movedEdge: .bottom,
                                                                                             tolerance: tolerance)

        assertRect(focusedNew, equals: cycledTopRight.frame)
    }

    func testCornerCleanupRebalancesRemainingWindowsAfterMinConstrainedWindowLeaves() {
        let removedTopRight = CGRect(x: 400, y: 540, width: 800, height: 360)
        let targetTopRight = CGRect(x: 400, y: 600, width: 800, height: 300)
        let remainingTopRight = CooperativeCornerResize.Candidate(id: 2,
                                                                  frame: CGRect(x: 400, y: 540, width: 800, height: 360))
        let bottomRight = CooperativeCornerResize.Candidate(id: 3,
                                                            frame: CGRect(x: 400, y: 0, width: 800, height: 540))

        guard let plan = cooperativePlan(focusedOld: removedTopRight,
                                         focusedNew: targetTopRight,
                                         candidates: [remainingTopRight, bottomRight],
                                         axis: .vertical,
                                         focusedMinimumSize: CGSize(width: 1, height: 1),
                                         movedEdgeOverride: .bottom,
                                         candidateDiscoveryFrame: removedTopRight,
                                         actionDescription: "cooperative resize cleanup after focused window left corner") else {
            XCTFail("Expected cleanup cooperative plan")
            return
        }

        assertRect(plan.focusedFrame, equals: targetTopRight)
        assertRect(plan.adjustments[0].newFrame, equals: targetTopRight)
        assertRect(plan.adjustments[1].newFrame, equals: CGRect(x: 400, y: 0, width: 800, height: 600))
    }

    func testCornerCleanupKeepsConstrainedLayoutWhenRemainingWindowCannotFitTarget() {
        let removedTopRight = CGRect(x: 400, y: 540, width: 800, height: 360)
        let targetTopRight = CGRect(x: 400, y: 600, width: 800, height: 300)
        let remainingTopRight = CooperativeCornerResize.Candidate(id: 2,
                                                                  frame: CGRect(x: 400, y: 540, width: 800, height: 360),
                                                                  minimumSize: CGSize(width: 100, height: 360))
        let bottomRight = CooperativeCornerResize.Candidate(id: 3,
                                                            frame: CGRect(x: 400, y: 0, width: 800, height: 540))

        guard let plan = cooperativePlan(focusedOld: removedTopRight,
                                         focusedNew: targetTopRight,
                                         candidates: [remainingTopRight, bottomRight],
                                         axis: .vertical,
                                         focusedMinimumSize: CGSize(width: 1, height: 1),
                                         movedEdgeOverride: .bottom,
                                         candidateDiscoveryFrame: removedTopRight,
                                         actionDescription: "cooperative resize cleanup after focused window left corner") else {
            XCTFail("Expected constrained cleanup cooperative plan")
            return
        }

        assertRect(plan.focusedFrame, equals: removedTopRight)
        assertRect(plan.adjustments[0].newFrame, equals: remainingTopRight.frame)
        assertRect(plan.adjustments[1].newFrame, equals: bottomRight.frame)
    }

    func testCornerCleanupRebalancesFocusedAdjacentDestinationAfterMinConstrainedWindowLeaves() {
        let removedTopLeft = CGRect(x: 0, y: 540, width: 800, height: 360)
        let targetTopLeft = CGRect(x: 0, y: 600, width: 800, height: 300)
        let remainingTopLeft = CooperativeCornerResize.Candidate(id: 2,
                                                                 frame: removedTopLeft)
        let focusedBottomLeft = CooperativeCornerResize.Candidate(id: 99,
                                                                  frame: CGRect(x: 0, y: 0, width: 800, height: 540))

        guard let plan = cooperativePlan(focusedOld: removedTopLeft,
                                         focusedNew: targetTopLeft,
                                         candidates: [remainingTopLeft, focusedBottomLeft],
                                         axis: .vertical,
                                         focusedMinimumSize: CGSize(width: 1, height: 1),
                                         movedEdgeOverride: .bottom,
                                         candidateDiscoveryFrame: removedTopLeft,
                                         actionDescription: "cooperative resize cleanup after focused window left corner") else {
            XCTFail("Expected focused destination cleanup cooperative plan")
            return
        }

        let focusedDestinationAdjustment = plan.adjustments.first { $0.id == focusedBottomLeft.id }

        assertRect(plan.focusedFrame, equals: targetTopLeft)
        assertRect(focusedDestinationAdjustment?.newFrame ?? .null,
                   equals: CGRect(x: 0, y: 0, width: 800, height: 600))
    }

    func testNearbyWindowEightPercentOffGridIsCapturedAndNormalized() {
        let focusedOld = CGRect(x: 250, y: 160, width: 320, height: 260)
        let focusedNew = CGRect(x: 0, y: 0, width: 800, height: 600)
        let offGridTop = CooperativeCornerResize.Candidate(id: 2, frame: CGRect(x: 90, y: 660, width: 620, height: 240))

        guard let plan = cooperativePlan(focusedOld: focusedOld,
                                         focusedNew: focusedNew,
                                         candidates: [offGridTop],
                                         axis: .vertical,
                                         captureTolerance: 72,
                                         movedEdgeOverride: .top,
                                         candidateDiscoveryFrame: focusedNew) else {
            XCTFail("Expected off-grid nearby window to be captured")
            return
        }

        XCTAssertEqual(plan.adjustments.map(\.id), [offGridTop.id])
        assertRect(plan.adjustments[0].newFrame, equals: CGRect(x: 0, y: 600, width: 800, height: 300))
        XCTAssertTrue(plan.debugLog.contains { $0.contains("capture-tolerance") })
    }

    func testBoundaryCrossingWindowIsCapturedAndAssignedAdjacent() {
        let focusedOld = CGRect(x: 250, y: 160, width: 320, height: 260)
        let focusedNew = CGRect(x: 0, y: 0, width: 800, height: 600)
        let crossingTop = CooperativeCornerResize.Candidate(id: 2, frame: CGRect(x: 0, y: 560, width: 800, height: 340))

        guard let plan = cooperativePlan(focusedOld: focusedOld,
                                         focusedNew: focusedNew,
                                         candidates: [crossingTop],
                                         axis: .vertical,
                                         captureTolerance: 72,
                                         movedEdgeOverride: .top,
                                         candidateDiscoveryFrame: focusedNew) else {
            XCTFail("Expected boundary-crossing window to be captured")
            return
        }

        XCTAssertEqual(plan.adjustments[0].kind, .adjacent)
        assertRect(plan.adjustments[0].newFrame, equals: CGRect(x: 0, y: 600, width: 800, height: 300))
        XCTAssertTrue(plan.debugLog.contains { $0.contains("boundary crossing") })
    }

    func testGapConsumingWindowIsCorrectedWhenFeasible() {
        let focusedOld = CGRect(x: 0, y: 0, width: 800, height: 600)
        let focusedNew = focusedOld
        let topLeft = CooperativeCornerResize.Candidate(id: 2, frame: CGRect(x: 0, y: 605, width: 800, height: 295))

        guard let plan = cooperativePlan(focusedOld: focusedOld,
                                         focusedNew: focusedNew,
                                         candidates: [topLeft],
                                         axis: .vertical,
                                         gapSize: 12,
                                         captureTolerance: 72,
                                         movedEdgeOverride: .top,
                                         candidateDiscoveryFrame: focusedNew) else {
            XCTFail("Expected gap-consuming window to be corrected")
            return
        }

        assertRect(plan.focusedFrame, equals: focusedNew)
        assertRect(plan.adjustments[0].newFrame, equals: CGRect(x: 0, y: 612, width: 800, height: 288))
        XCTAssertEqual(plan.adjustments[0].newFrame.minY - plan.focusedFrame.maxY, 12, accuracy: 0.001)
    }

    func testAggressiveCaptureIgnoresUnrelatedFloatingWindow() {
        let focusedOld = CGRect(x: 250, y: 160, width: 320, height: 260)
        let focusedNew = CGRect(x: 0, y: 0, width: 800, height: 600)
        let floating = CooperativeCornerResize.Candidate(id: 2, frame: CGRect(x: 900, y: 620, width: 180, height: 160))

        let plan = cooperativePlan(focusedOld: focusedOld,
                                   focusedNew: focusedNew,
                                   candidates: [floating],
                                   axis: .vertical,
                                   captureTolerance: 72,
                                   movedEdgeOverride: .top,
                                   candidateDiscoveryFrame: focusedNew)

        XCTAssertNil(plan)
    }

    func testConfiguredGapIsPreservedForVerticalStack() {
        let focusedOld = CGRect(x: 0, y: 0, width: 800, height: 300)
        let focusedNew = CGRect(x: 0, y: 0, width: 800, height: 600)
        let topLeft = CooperativeCornerResize.Candidate(id: 2, frame: CGRect(x: 0, y: 312, width: 800, height: 588))

        guard let plan = cooperativePlan(focusedOld: focusedOld,
                                         focusedNew: focusedNew,
                                         candidates: [topLeft],
                                         axis: .vertical,
                                         gapSize: 12) else {
            XCTFail("Expected cooperative resize plan")
            return
        }

        assertRect(plan.focusedFrame, equals: focusedNew)
        assertRect(plan.adjustments[0].newFrame, equals: CGRect(x: 0, y: 612, width: 800, height: 288))
        XCTAssertEqual(plan.adjustments[0].newFrame.minY - plan.focusedFrame.maxY, 12, accuracy: 0.001)
    }

    func testConfiguredGapAndOversizedNeighborReduceExpansion() {
        let focusedOld = CGRect(x: 0, y: 0, width: 800, height: 300)
        let focusedNew = CGRect(x: 0, y: 0, width: 800, height: 600)
        let topLeft = CooperativeCornerResize.Candidate(id: 2,
                                                        frame: CGRect(x: 0, y: 312, width: 800, height: 588),
                                                        minimumSize: CGSize(width: 100, height: 350))

        guard let plan = cooperativePlan(focusedOld: focusedOld,
                                         focusedNew: focusedNew,
                                         candidates: [topLeft],
                                         axis: .vertical,
                                         gapSize: 12) else {
            XCTFail("Expected cooperative resize plan")
            return
        }

        assertRect(plan.focusedFrame, equals: CGRect(x: 0, y: 0, width: 800, height: 538))
        assertRect(plan.adjustments[0].newFrame, equals: CGRect(x: 0, y: 550, width: 800, height: 350))
        XCTAssertEqual(plan.adjustments[0].newFrame.minY - plan.focusedFrame.maxY, 12, accuracy: 0.001)
    }

    func testCapturedGapPerimeterSurvivesOversizedNeighbor() {
        let focusedOld = CGRect(x: 12, y: 12, width: 782, height: 282)
        let focusedNew = CGRect(x: 12, y: 12, width: 782, height: 582)
        let topLeft = CooperativeCornerResize.Candidate(id: 2,
                                                        frame: CGRect(x: 102, y: 654, width: 602, height: 234),
                                                        minimumSize: CGSize(width: 100, height: 350))

        guard let plan = cooperativePlan(focusedOld: focusedOld,
                                         focusedNew: focusedNew,
                                         candidates: [topLeft],
                                         axis: .vertical,
                                         gapSize: 12,
                                         captureTolerance: 72,
                                         movedEdgeOverride: .top,
                                         candidateDiscoveryFrame: focusedNew) else {
            XCTFail("Expected gap-aware cooperative resize plan")
            return
        }

        assertRect(plan.focusedFrame, equals: CGRect(x: 12, y: 12, width: 782, height: 514))
        assertRect(plan.adjustments[0].newFrame, equals: CGRect(x: 12, y: 538, width: 782, height: 350))
        XCTAssertEqual(plan.adjustments[0].newFrame.minY - plan.focusedFrame.maxY, 12, accuracy: 0.001)
        XCTAssertEqual(plan.adjustments[0].newFrame.maxY, screenFrame.maxY - 12, accuracy: 0.001)
    }

    func testCapturedHorizontalGapPerimeterSurvivesOversizedNeighbor() {
        let focusedOld = CGRect(x: 12, y: 12, width: 282, height: 876)
        let focusedNew = CGRect(x: 12, y: 12, width: 582, height: 876)
        let rightSide = CooperativeCornerResize.Candidate(id: 2,
                                                          frame: CGRect(x: 654, y: 72, width: 534, height: 756),
                                                          minimumSize: CGSize(width: 700, height: 100))

        guard let plan = cooperativePlan(focusedOld: focusedOld,
                                         focusedNew: focusedNew,
                                         candidates: [rightSide],
                                         axis: .horizontal,
                                         gapSize: 12,
                                         captureTolerance: 96,
                                         movedEdgeOverride: .right,
                                         candidateDiscoveryFrame: focusedNew) else {
            XCTFail("Expected horizontal gap-aware cooperative resize plan")
            return
        }

        assertRect(plan.focusedFrame, equals: CGRect(x: 12, y: 12, width: 464, height: 876))
        assertRect(plan.adjustments[0].newFrame, equals: CGRect(x: 488, y: 12, width: 700, height: 876))
        XCTAssertEqual(plan.adjustments[0].newFrame.minX - plan.focusedFrame.maxX, 12, accuracy: 0.001)
        XCTAssertEqual(plan.adjustments[0].newFrame.maxX, screenFrame.maxX - 12, accuracy: 0.001)
    }

    func testSettlingPassAdjustsVerticalOversizedNeighbor() {
        let focusedOld = CGRect(x: 0, y: 0, width: 800, height: 300)
        let focusedNew = CGRect(x: 0, y: 0, width: 800, height: 600)
        let topLeft = CooperativeCornerResize.Candidate(id: 2, frame: CGRect(x: 0, y: 300, width: 800, height: 600))

        guard let planned = cooperativePlan(focusedOld: focusedOld, focusedNew: focusedNew, candidates: [topLeft], axis: .vertical),
              let correction = correctionPlan(focusedOld: focusedOld,
                                              focusedNew: focusedNew,
                                              plannedPlan: planned,
                                              candidates: [topLeft],
                                              actualFocusedFrame: planned.focusedFrame,
                                              actualCandidateFramesById: [2: CGRect(x: 0, y: 500, width: 800, height: 400)],
                                              axis: .vertical) else {
            XCTFail("Expected cooperative correction plan")
            return
        }

        assertRect(correction.focusedFrame, equals: CGRect(x: 0, y: 0, width: 800, height: 500))
        assertRect(correction.adjustments[0].newFrame, equals: CGRect(x: 0, y: 500, width: 800, height: 400))
    }

    func testPreFocusedSettlingPreservesGapForOversizedTopNeighbor() {
        let focusedOld = CGRect(x: 1600, y: 160, width: 620, height: 540)
        let focusedNew = CGRect(x: 1077, y: 160, width: 2103, height: 1060)
        let topRight = CooperativeCornerResize.Candidate(id: 2, frame: CGRect(x: 1077, y: 1155, width: 2103, height: 600))

        guard let planned = cooperativePlan(focusedOld: focusedOld,
                                            focusedNew: focusedNew,
                                            screenFrame: CGRect(x: 0, y: 140, width: 3200, height: 1635),
                                            candidates: [topRight],
                                            axis: .vertical,
                                            tolerance: 24,
                                            gapSize: 20,
                                            captureTolerance: 96,
                                            movedEdgeOverride: .top,
                                            candidateDiscoveryFrame: focusedNew),
              let correction = CooperativeCornerResize.correctionPlan(oldFocusedFrame: focusedOld,
                                                                      requestedFocusedFrame: focusedNew,
                                                                      plannedPlan: planned,
                                                                      screenFrame: CGRect(x: 0, y: 140, width: 3200, height: 1635),
                                                                      candidates: [topRight],
                                                                      actualFocusedFrame: planned.focusedFrame,
                                                                      actualCandidateFramesById: [topRight.id: topRight.frame],
                                                                      axis: .vertical,
                                                                      tolerance: 24,
                                                                      layoutTolerance: 4,
                                                                      minimumSize: minimumSize,
                                                                      gapSize: 20,
                                                                      captureTolerance: 96,
                                                                      movedEdgeOverride: .top,
                                                                      candidateDiscoveryFrame: focusedNew) else {
            XCTFail("Expected pre-focused correction plan")
            return
        }

        assertRect(correction.focusedFrame, equals: CGRect(x: 1077, y: 160, width: 2103, height: 975))
        assertRect(correction.adjustments[0].newFrame, equals: CGRect(x: 1077, y: 1155, width: 2103, height: 600))
        XCTAssertEqual(correction.adjustments[0].newFrame.minY - correction.focusedFrame.maxY, 20, accuracy: 0.001)
    }

    func testSettlingPassAdjustsHorizontalOversizedNeighbor() {
        let focusedOld = CGRect(x: 0, y: 0, width: 600, height: 900)
        let focusedNew = CGRect(x: 0, y: 0, width: 800, height: 900)
        let rightSide = CooperativeCornerResize.Candidate(id: 2, frame: CGRect(x: 600, y: 0, width: 600, height: 900))

        guard let planned = cooperativePlan(focusedOld: focusedOld, focusedNew: focusedNew, candidates: [rightSide], axis: .horizontal),
              let correction = correctionPlan(focusedOld: focusedOld,
                                              focusedNew: focusedNew,
                                              plannedPlan: planned,
                                              candidates: [rightSide],
                                              actualFocusedFrame: planned.focusedFrame,
                                              actualCandidateFramesById: [2: CGRect(x: 700, y: 0, width: 500, height: 900)],
                                              axis: .horizontal) else {
            XCTFail("Expected cooperative correction plan")
            return
        }

        assertRect(correction.focusedFrame, equals: CGRect(x: 0, y: 0, width: 700, height: 900))
        assertRect(correction.adjustments[0].newFrame, equals: CGRect(x: 700, y: 0, width: 500, height: 900))
    }

    func testSettlingPassHandlesBothAxisOversizedNeighborWithoutSpill() {
        let focusedOld = CGRect(x: 0, y: 0, width: 400, height: 300)
        let focusedNew = CGRect(x: 0, y: 0, width: 400, height: 600)
        let topLeft = CooperativeCornerResize.Candidate(id: 2, frame: CGRect(x: 0, y: 300, width: 400, height: 600))

        guard let planned = cooperativePlan(focusedOld: focusedOld, focusedNew: focusedNew, candidates: [topLeft], axis: .vertical),
              let correction = correctionPlan(focusedOld: focusedOld,
                                              focusedNew: focusedNew,
                                              plannedPlan: planned,
                                              candidates: [topLeft],
                                              actualFocusedFrame: planned.focusedFrame,
                                              actualCandidateFramesById: [2: CGRect(x: 0, y: 500, width: 700, height: 400)],
                                              axis: .vertical) else {
            XCTFail("Expected cooperative correction plan")
            return
        }

        assertRect(correction.focusedFrame, equals: CGRect(x: 0, y: 0, width: 400, height: 500))
        assertRect(correction.adjustments[0].newFrame, equals: CGRect(x: 0, y: 500, width: 700, height: 400))
        XCTAssertLessThanOrEqual(correction.adjustments[0].newFrame.maxX, screenFrame.maxX)
        XCTAssertLessThanOrEqual(correction.adjustments[0].newFrame.maxY, screenFrame.maxY)
    }

    func testSettlingPassHandlesOversizedInitiatingWindow() {
        let focusedOld = CGRect(x: 0, y: 0, width: 800, height: 300)
        let focusedNew = CGRect(x: 0, y: 0, width: 800, height: 600)
        let topLeft = CooperativeCornerResize.Candidate(id: 2, frame: CGRect(x: 0, y: 300, width: 800, height: 600))

        guard let planned = cooperativePlan(focusedOld: focusedOld, focusedNew: focusedNew, candidates: [topLeft], axis: .vertical),
              let correction = correctionPlan(focusedOld: focusedOld,
                                              focusedNew: focusedNew,
                                              plannedPlan: planned,
                                              candidates: [topLeft],
                                              actualFocusedFrame: CGRect(x: 0, y: 0, width: 800, height: 700),
                                              actualCandidateFramesById: [2: planned.adjustments[0].newFrame],
                                              axis: .vertical) else {
            XCTFail("Expected cooperative correction plan")
            return
        }

        assertRect(correction.focusedFrame, equals: CGRect(x: 0, y: 0, width: 800, height: 700))
        assertRect(correction.adjustments[0].newFrame, equals: CGRect(x: 0, y: 700, width: 800, height: 200))
    }

    func testSettlingPassIsSkippedWhenActualFramesMatchPlan() {
        let focusedOld = CGRect(x: 0, y: 0, width: 800, height: 300)
        let focusedNew = CGRect(x: 0, y: 0, width: 800, height: 600)
        let topLeft = CooperativeCornerResize.Candidate(id: 2, frame: CGRect(x: 0, y: 300, width: 800, height: 600))

        guard let planned = cooperativePlan(focusedOld: focusedOld, focusedNew: focusedNew, candidates: [topLeft], axis: .vertical) else {
            XCTFail("Expected cooperative resize plan")
            return
        }

        let correction = correctionPlan(focusedOld: focusedOld,
                                        focusedNew: focusedNew,
                                        plannedPlan: planned,
                                        candidates: [topLeft],
                                        actualFocusedFrame: planned.focusedFrame,
                                        actualCandidateFramesById: [2: planned.adjustments[0].newFrame],
                                        axis: .vertical)

        XCTAssertNil(correction)
    }

    func testBottomLeftVerticalShrinkExpandsTopLeftNeighbor() {
        let focusedOld = CGRect(x: 0, y: 0, width: 800, height: 600)
        let focusedNew = CGRect(x: 0, y: 0, width: 800, height: 300)
        let topLeft = CooperativeCornerResize.Candidate(id: 2, frame: CGRect(x: 0, y: 600, width: 800, height: 300))

        let adjustments = cooperativeAdjustments(focusedOld: focusedOld, focusedNew: focusedNew, candidates: [topLeft], axis: .vertical)

        XCTAssertEqual(adjustments.count, 1)
        assertRect(adjustments[0].newFrame, equals: CGRect(x: 0, y: 300, width: 800, height: 600))
        XCTAssertEqual(focusedNew.maxY, adjustments[0].newFrame.minY, accuracy: 0.001)
    }

    func testMatchingBottomLeftWindowShrinksWithFocusedWindowBeforeNeighborExpands() {
        let focusedOld = CGRect(x: 0, y: 0, width: 800, height: 600)
        let focusedNew = CGRect(x: 0, y: 0, width: 800, height: 300)
        let matchingBottomLeft = CooperativeCornerResize.Candidate(id: 2, frame: focusedOld)
        let topLeft = CooperativeCornerResize.Candidate(id: 3, frame: CGRect(x: 0, y: 600, width: 800, height: 300))

        let adjustments = cooperativeAdjustments(focusedOld: focusedOld, focusedNew: focusedNew, candidates: [matchingBottomLeft, topLeft], axis: .vertical)

        XCTAssertEqual(adjustments.count, 2)
        XCTAssertEqual(adjustments[0].id, matchingBottomLeft.id)
        XCTAssertEqual(adjustments[0].kind, .matchingFocusedFrame)
        assertRect(adjustments[0].newFrame, equals: focusedNew)
        XCTAssertEqual(adjustments[1].id, topLeft.id)
        XCTAssertEqual(adjustments[1].kind, .adjacent)
        assertRect(adjustments[1].newFrame, equals: CGRect(x: 0, y: 300, width: 800, height: 600))
    }

    func testTopLeftHorizontalExpansionShrinksTopRightNeighbor() {
        let focusedOld = CGRect(x: 0, y: 300, width: 600, height: 600)
        let focusedNew = CGRect(x: 0, y: 300, width: 800, height: 600)
        let topRight = CooperativeCornerResize.Candidate(id: 2, frame: CGRect(x: 600, y: 300, width: 600, height: 600))

        let adjustments = cooperativeAdjustments(focusedOld: focusedOld, focusedNew: focusedNew, candidates: [topRight], axis: .horizontal)

        XCTAssertEqual(adjustments.count, 1)
        assertRect(adjustments[0].newFrame, equals: CGRect(x: 800, y: 300, width: 400, height: 600))
        XCTAssertEqual(focusedNew.maxX, adjustments[0].newFrame.minX, accuracy: 0.001)
    }

    func testTopLeftHorizontalShrinkExpandsTopRightNeighbor() {
        let focusedOld = CGRect(x: 0, y: 300, width: 800, height: 600)
        let focusedNew = CGRect(x: 0, y: 300, width: 600, height: 600)
        let topRight = CooperativeCornerResize.Candidate(id: 2, frame: CGRect(x: 800, y: 300, width: 400, height: 600))

        let adjustments = cooperativeAdjustments(focusedOld: focusedOld, focusedNew: focusedNew, candidates: [topRight], axis: .horizontal)

        XCTAssertEqual(adjustments.count, 1)
        assertRect(adjustments[0].newFrame, equals: CGRect(x: 600, y: 300, width: 600, height: 600))
        XCTAssertEqual(focusedNew.maxX, adjustments[0].newFrame.minX, accuracy: 0.001)
    }

    func testLeftSideHorizontalExpansionShrinksRightSideNeighbor() {
        let focusedOld = CGRect(x: 0, y: 0, width: 600, height: 900)
        let focusedNew = CGRect(x: 0, y: 0, width: 800, height: 900)
        let rightSide = CooperativeCornerResize.Candidate(id: 2, frame: CGRect(x: 600, y: 0, width: 600, height: 900))

        let adjustments = cooperativeAdjustments(focusedOld: focusedOld, focusedNew: focusedNew, candidates: [rightSide], axis: .horizontal)

        XCTAssertEqual(adjustments.count, 1)
        assertRect(adjustments[0].newFrame, equals: CGRect(x: 800, y: 0, width: 400, height: 900))
        XCTAssertEqual(focusedNew.maxX, adjustments[0].newFrame.minX, accuracy: 0.001)
    }

    func testLeftSideHorizontalExpansionShrinksStackedRightCornerNeighbors() {
        let focusedOld = CGRect(x: 0, y: 0, width: 600, height: 900)
        let focusedNew = CGRect(x: 0, y: 0, width: 800, height: 900)
        let bottomRight = CooperativeCornerResize.Candidate(id: 2, frame: CGRect(x: 600, y: 0, width: 600, height: 450))
        let topRight = CooperativeCornerResize.Candidate(id: 3, frame: CGRect(x: 600, y: 450, width: 600, height: 450))

        let adjustments = cooperativeAdjustments(focusedOld: focusedOld, focusedNew: focusedNew, candidates: [bottomRight, topRight], axis: .horizontal)

        XCTAssertEqual(adjustments.count, 2)
        assertRect(adjustments[0].newFrame, equals: CGRect(x: 800, y: 0, width: 400, height: 450))
        assertRect(adjustments[1].newFrame, equals: CGRect(x: 800, y: 450, width: 400, height: 450))
    }

    func testLeftSideHorizontalShrinkExpandsRightSideNeighbor() {
        let focusedOld = CGRect(x: 0, y: 0, width: 800, height: 900)
        let focusedNew = CGRect(x: 0, y: 0, width: 600, height: 900)
        let rightSide = CooperativeCornerResize.Candidate(id: 2, frame: CGRect(x: 800, y: 0, width: 400, height: 900))

        let adjustments = cooperativeAdjustments(focusedOld: focusedOld, focusedNew: focusedNew, candidates: [rightSide], axis: .horizontal)

        XCTAssertEqual(adjustments.count, 1)
        assertRect(adjustments[0].newFrame, equals: CGRect(x: 600, y: 0, width: 600, height: 900))
        XCTAssertEqual(focusedNew.maxX, adjustments[0].newFrame.minX, accuracy: 0.001)
    }

    func testMatchingLeftSideWindowShrinksWithFocusedWindowBeforeRightSideNeighborExpands() {
        let focusedOld = CGRect(x: 0, y: 0, width: 800, height: 900)
        let focusedNew = CGRect(x: 0, y: 0, width: 600, height: 900)
        let matchingLeftSide = CooperativeCornerResize.Candidate(id: 2, frame: focusedOld)
        let rightSide = CooperativeCornerResize.Candidate(id: 3, frame: CGRect(x: 800, y: 0, width: 400, height: 900))

        let adjustments = cooperativeAdjustments(focusedOld: focusedOld, focusedNew: focusedNew, candidates: [matchingLeftSide, rightSide], axis: .horizontal)

        XCTAssertEqual(adjustments.count, 2)
        XCTAssertEqual(adjustments[0].id, matchingLeftSide.id)
        XCTAssertEqual(adjustments[0].kind, .matchingFocusedFrame)
        assertRect(adjustments[0].newFrame, equals: focusedNew)
        XCTAssertEqual(adjustments[1].id, rightSide.id)
        XCTAssertEqual(adjustments[1].kind, .adjacent)
        assertRect(adjustments[1].newFrame, equals: CGRect(x: 600, y: 0, width: 600, height: 900))
    }

    func testLeftSideShrinkAlsoShrinksPartialBottomLeftOccupant() {
        let focusedOld = CGRect(x: 0, y: 0, width: 800, height: 900)
        let focusedNew = CGRect(x: 0, y: 0, width: 400, height: 900)
        let bottomLeft = CooperativeCornerResize.Candidate(id: 2, frame: CGRect(x: 0, y: 0, width: 800, height: 300))
        let bottomRight = CooperativeCornerResize.Candidate(id: 3, frame: CGRect(x: 800, y: 0, width: 400, height: 300))
        let topRight = CooperativeCornerResize.Candidate(id: 4, frame: CGRect(x: 800, y: 300, width: 400, height: 600))

        let adjustments = cooperativeAdjustments(focusedOld: focusedOld,
                                                focusedNew: focusedNew,
                                                candidates: [bottomLeft, bottomRight, topRight],
                                                axis: .horizontal)

        XCTAssertEqual(adjustments.count, 3)
        XCTAssertEqual(adjustments[0].id, bottomLeft.id)
        XCTAssertEqual(adjustments[0].kind, .matchingFocusedFrame)
        assertRect(adjustments[0].newFrame, equals: CGRect(x: 0, y: 0, width: 400, height: 300))
        assertRect(adjustments[1].newFrame, equals: CGRect(x: 400, y: 0, width: 800, height: 300))
        assertRect(adjustments[2].newFrame, equals: CGRect(x: 400, y: 300, width: 800, height: 600))
    }

    func testRightSideHorizontalExpansionShrinksLeftSideNeighbor() {
        let focusedOld = CGRect(x: 600, y: 0, width: 600, height: 900)
        let focusedNew = CGRect(x: 400, y: 0, width: 800, height: 900)
        let leftSide = CooperativeCornerResize.Candidate(id: 2, frame: CGRect(x: 0, y: 0, width: 600, height: 900))

        let adjustments = cooperativeAdjustments(focusedOld: focusedOld, focusedNew: focusedNew, candidates: [leftSide], axis: .horizontal)

        XCTAssertEqual(adjustments.count, 1)
        assertRect(adjustments[0].newFrame, equals: CGRect(x: 0, y: 0, width: 400, height: 900))
        XCTAssertEqual(adjustments[0].newFrame.maxX, focusedNew.minX, accuracy: 0.001)
    }

    func testTopSideVerticalExpansionShrinksBottomSideNeighbor() {
        let focusedOld = CGRect(x: 0, y: 450, width: 1200, height: 450)
        let focusedNew = CGRect(x: 0, y: 300, width: 1200, height: 600)
        let bottomSide = CooperativeCornerResize.Candidate(id: 2, frame: CGRect(x: 0, y: 0, width: 1200, height: 450))

        let adjustments = cooperativeAdjustments(focusedOld: focusedOld, focusedNew: focusedNew, candidates: [bottomSide], axis: .vertical)

        XCTAssertEqual(adjustments.count, 1)
        assertRect(adjustments[0].newFrame, equals: CGRect(x: 0, y: 0, width: 1200, height: 300))
        XCTAssertEqual(adjustments[0].newFrame.maxY, focusedNew.minY, accuracy: 0.001)
    }

    func testTopSideVerticalExpansionShrinksStackedBottomCornerNeighbors() {
        let focusedOld = CGRect(x: 0, y: 450, width: 1200, height: 450)
        let focusedNew = CGRect(x: 0, y: 300, width: 1200, height: 600)
        let bottomLeft = CooperativeCornerResize.Candidate(id: 2, frame: CGRect(x: 0, y: 0, width: 600, height: 450))
        let bottomRight = CooperativeCornerResize.Candidate(id: 3, frame: CGRect(x: 600, y: 0, width: 600, height: 450))

        let adjustments = cooperativeAdjustments(focusedOld: focusedOld, focusedNew: focusedNew, candidates: [bottomLeft, bottomRight], axis: .vertical)

        XCTAssertEqual(adjustments.count, 2)
        assertRect(adjustments[0].newFrame, equals: CGRect(x: 0, y: 0, width: 600, height: 300))
        assertRect(adjustments[1].newFrame, equals: CGRect(x: 600, y: 0, width: 600, height: 300))
    }

    func testTopSideVerticalShrinkExpandsBottomSideNeighbor() {
        let focusedOld = CGRect(x: 0, y: 300, width: 1200, height: 600)
        let focusedNew = CGRect(x: 0, y: 450, width: 1200, height: 450)
        let bottomSide = CooperativeCornerResize.Candidate(id: 2, frame: CGRect(x: 0, y: 0, width: 1200, height: 300))

        let adjustments = cooperativeAdjustments(focusedOld: focusedOld, focusedNew: focusedNew, candidates: [bottomSide], axis: .vertical)

        XCTAssertEqual(adjustments.count, 1)
        assertRect(adjustments[0].newFrame, equals: CGRect(x: 0, y: 0, width: 1200, height: 450))
        XCTAssertEqual(adjustments[0].newFrame.maxY, focusedNew.minY, accuracy: 0.001)
    }

    func testBottomSideVerticalExpansionShrinksTopSideNeighbor() {
        let focusedOld = CGRect(x: 0, y: 0, width: 1200, height: 450)
        let focusedNew = CGRect(x: 0, y: 0, width: 1200, height: 600)
        let topSide = CooperativeCornerResize.Candidate(id: 2, frame: CGRect(x: 0, y: 450, width: 1200, height: 450))

        let adjustments = cooperativeAdjustments(focusedOld: focusedOld, focusedNew: focusedNew, candidates: [topSide], axis: .vertical)

        XCTAssertEqual(adjustments.count, 1)
        assertRect(adjustments[0].newFrame, equals: CGRect(x: 0, y: 600, width: 1200, height: 300))
        XCTAssertEqual(focusedNew.maxY, adjustments[0].newFrame.minY, accuracy: 0.001)
    }

    func testNoAdjacentCandidateFound() {
        let focusedOld = CGRect(x: 0, y: 0, width: 800, height: 300)
        let focusedNew = CGRect(x: 0, y: 0, width: 800, height: 600)

        let adjustments = cooperativeAdjustments(focusedOld: focusedOld, focusedNew: focusedNew, candidates: [], axis: .vertical)

        XCTAssertTrue(adjustments.isEmpty)
    }

    func testAmbiguousFloatingWindowIsIgnored() {
        let focusedOld = CGRect(x: 0, y: 0, width: 800, height: 300)
        let focusedNew = CGRect(x: 0, y: 0, width: 800, height: 600)
        let floating = CooperativeCornerResize.Candidate(id: 2, frame: CGRect(x: 20, y: 302, width: 500, height: 240))

        let adjustments = cooperativeAdjustments(focusedOld: focusedOld, focusedNew: focusedNew, candidates: [floating], axis: .vertical)

        XCTAssertTrue(adjustments.isEmpty)
    }

    func testToleranceMatchesNormalTiledNeighborsWithGaps() {
        let focusedOld = CGRect(x: 0, y: 0, width: 800, height: 300)
        let focusedNew = CGRect(x: 0, y: 0, width: 800, height: 600)
        let topLeft = CooperativeCornerResize.Candidate(id: 2, frame: CGRect(x: 3, y: 305, width: 794, height: 592))

        let adjustments = cooperativeAdjustments(focusedOld: focusedOld, focusedNew: focusedNew, candidates: [topLeft], axis: .vertical)

        XCTAssertEqual(adjustments.count, 1)
        XCTAssertEqual(adjustments[0].newFrame.minY, focusedNew.maxY, accuracy: 0.001)
    }

    func testNonCycledAxisRemainsUnchanged() {
        let focusedOld = CGRect(x: 0, y: 300, width: 600, height: 600)
        let focusedNew = CGRect(x: 0, y: 300, width: 800, height: 600)
        let topRight = CooperativeCornerResize.Candidate(id: 2, frame: CGRect(x: 600, y: 300, width: 600, height: 600))

        let adjustments = cooperativeAdjustments(focusedOld: focusedOld, focusedNew: focusedNew, candidates: [topRight], axis: .horizontal)

        XCTAssertEqual(adjustments.count, 1)
        XCTAssertEqual(adjustments[0].newFrame.minY, topRight.frame.minY, accuracy: 0.001)
        XCTAssertEqual(adjustments[0].newFrame.height, topRight.frame.height, accuracy: 0.001)
    }

    private func cooperativeAdjustments(focusedOld: CGRect,
                                        focusedNew: CGRect,
                                        candidates: [CooperativeCornerResize.Candidate],
                                        axis: CornerCycleExpansionAxis,
                                        gapSize: CGFloat = 0) -> [CooperativeCornerResize.Adjustment] {
        CooperativeCornerResize.adjustments(oldFocusedFrame: focusedOld,
                                            newFocusedFrame: focusedNew,
                                            screenFrame: screenFrame,
                                            candidates: candidates,
                                            axis: axis,
                                            tolerance: tolerance,
                                            minimumSize: minimumSize,
                                            gapSize: gapSize)
    }

    private func cooperativePlan(focusedOld: CGRect,
                                 focusedNew: CGRect,
                                 screenFrame: CGRect? = nil,
                                 candidates: [CooperativeCornerResize.Candidate],
                                 axis: CornerCycleExpansionAxis,
                                 tolerance: CGFloat? = nil,
                                 gapSize: CGFloat = 0,
                                 focusedMinimumSize: CGSize? = nil,
                                 captureTolerance: CGFloat? = nil,
                                 movedEdgeOverride: CooperativeCornerResize.MovedEdge? = nil,
                                 candidateDiscoveryFrame: CGRect? = nil,
                                 actionDescription: String = "test cooperative resize") -> CooperativeCornerResize.Plan? {
        CooperativeCornerResize.plan(oldFocusedFrame: focusedOld,
                                     newFocusedFrame: focusedNew,
                                     screenFrame: screenFrame ?? self.screenFrame,
                                     candidates: candidates,
                                     axis: axis,
                                     tolerance: tolerance ?? self.tolerance,
                                     minimumSize: minimumSize,
                                     focusedMinimumSize: focusedMinimumSize,
                                     gapSize: gapSize,
                                     captureTolerance: captureTolerance,
                                     movedEdgeOverride: movedEdgeOverride,
                                     candidateDiscoveryFrame: candidateDiscoveryFrame,
                                     actionDescription: actionDescription)
    }

    private func correctionPlan(focusedOld: CGRect,
                                focusedNew: CGRect,
                                plannedPlan: CooperativeCornerResize.Plan,
                                candidates: [CooperativeCornerResize.Candidate],
                                actualFocusedFrame: CGRect,
                                actualCandidateFramesById: [CGWindowID: CGRect],
                                axis: CornerCycleExpansionAxis,
                                gapSize: CGFloat = 0,
                                captureTolerance: CGFloat? = nil,
                                movedEdgeOverride: CooperativeCornerResize.MovedEdge? = nil,
                                candidateDiscoveryFrame: CGRect? = nil) -> CooperativeCornerResize.Plan? {
        CooperativeCornerResize.correctionPlan(oldFocusedFrame: focusedOld,
                                               requestedFocusedFrame: focusedNew,
                                               plannedPlan: plannedPlan,
                                               screenFrame: screenFrame,
                                               candidates: candidates,
                                               actualFocusedFrame: actualFocusedFrame,
                                               actualCandidateFramesById: actualCandidateFramesById,
                                               axis: axis,
                                               tolerance: tolerance,
                                               layoutTolerance: 4,
                                               minimumSize: minimumSize,
                                               gapSize: gapSize,
                                               captureTolerance: captureTolerance,
                                               movedEdgeOverride: movedEdgeOverride,
                                               candidateDiscoveryFrame: candidateDiscoveryFrame)
    }

    private func assertRect(_ rect: CGRect, equals expected: CGRect, file: StaticString = #filePath, line: UInt = #line) {
        XCTAssertEqual(rect.origin.x, expected.origin.x, accuracy: 0.001, file: file, line: line)
        XCTAssertEqual(rect.origin.y, expected.origin.y, accuracy: 0.001, file: file, line: line)
        XCTAssertEqual(rect.width, expected.width, accuracy: 0.001, file: file, line: line)
        XCTAssertEqual(rect.height, expected.height, accuracy: 0.001, file: file, line: line)
    }
}

class CycleSizeRatioPresetTests: XCTestCase {

    func testPercentValuesMatchCycleSizeFractions() {
        XCTAssertEqual(CycleSize.oneHalf.percentValue, 50, accuracy: 0.001)
        XCTAssertEqual(CycleSize.twoThirds.percentValue, 66.666, accuracy: 0.001)
        XCTAssertEqual(CycleSize.oneThird.percentValue, 33.333, accuracy: 0.001)
    }

    func testMatchingPercentValueUsesTolerance() {
        XCTAssertEqual(CycleSize.matching(percentValue: 33.3334), .oneThird)
        XCTAssertEqual(CycleSize.matching(percentValue: 66.6666), .twoThirds)
    }

    func testCustomPercentValueDoesNotMatchPreset() {
        XCTAssertNil(CycleSize.matching(percentValue: 60))
    }
}

class ActiveSideSplitRatiosCooperativeTests: XCTestCase {
    private let screenFrame = CGRect(x: 10, y: 20, width: 1200, height: 900)
    private let gapSize: CGFloat = 20
    private var savedHorizontalSplitRatio: Float = 50
    private var savedVerticalSplitRatio: Float = 50
    private var savedCornerCycleExpansionAxis: CornerCycleExpansionAxis = .horizontal
    private var savedSubsequentExecutionMode: SubsequentExecutionMode = .resize

    override func setUp() {
        super.setUp()
        savedHorizontalSplitRatio = Defaults.horizontalSplitRatio.value
        savedVerticalSplitRatio = Defaults.verticalSplitRatio.value
        savedCornerCycleExpansionAxis = Defaults.cornerCycleExpansionAxis.value
        savedSubsequentExecutionMode = Defaults.subsequentExecutionMode.value
        Defaults.horizontalSplitRatio.value = CycleSize.oneQuarter.percentValue
        Defaults.verticalSplitRatio.value = CycleSize.oneThird.percentValue
        Defaults.cornerCycleExpansionAxis.value = .vertical
        Defaults.subsequentExecutionMode.value = .resize
        ActiveSideSplitRatios.shared.resetAll()
    }

    override func tearDown() {
        Defaults.horizontalSplitRatio.value = savedHorizontalSplitRatio
        Defaults.verticalSplitRatio.value = savedVerticalSplitRatio
        Defaults.cornerCycleExpansionAxis.value = savedCornerCycleExpansionAxis
        Defaults.subsequentExecutionMode.value = savedSubsequentExecutionMode
        ActiveSideSplitRatios.shared.resetAll()
        super.tearDown()
    }

    func testMinWidthConstrainedTopLeftRecordsAchievedHorizontalSplit() throws {
        guard Defaults.cooperativeCornerResize.enabled else { return }
        let plan = try XCTUnwrap(topLeftPlan(focusedMinimumSize: CGSize(width: 360, height: 100)))

        ActiveSideSplitRatios.shared.recordAchievedCooperativeAction(.topLeft,
                                                                    achievedFrame: plan.focusedFrame,
                                                                    screenFrame: screenFrame,
                                                                    gapSize: gapSize)

        XCTAssertEqual(plan.focusedFrame.width, 360, accuracy: 0.001)
        XCTAssertEqual(ActiveSideSplitRatios.shared.horizontalRatio(for: screenFrame), 0.325, accuracy: 0.001)
    }

    func testBottomLeftAfterMinWidthConstraintUsesAchievedHorizontalSplit() throws {
        guard Defaults.cooperativeCornerResize.enabled else { return }
        let plan = try XCTUnwrap(topLeftPlan(focusedMinimumSize: CGSize(width: 360, height: 100)))
        ActiveSideSplitRatios.shared.recordAchievedCooperativeAction(.topLeft,
                                                                    achievedFrame: plan.focusedFrame,
                                                                    screenFrame: screenFrame,
                                                                    gapSize: gapSize)

        let bottomLeft = WindowCalculationFactory.lowerLeftCalculation.calculateRect(params(for: .bottomLeft)).rect
        let gappedBottomLeft = GapCalculation.applyGaps(bottomLeft,
                                                        sharedEdges: WindowAction.bottomLeft.gapSharedEdge,
                                                        gapSize: Float(gapSize))

        XCTAssertEqual(bottomLeft.width, 390, accuracy: 0.001)
        XCTAssertEqual(gappedBottomLeft.width, plan.focusedFrame.width, accuracy: 0.001)
        XCTAssertEqual(gappedBottomLeft.maxX, plan.focusedFrame.maxX, accuracy: 0.001)
    }

    func testMinHeightConstrainedTopLeftRecordsAchievedVerticalSplit() throws {
        guard Defaults.cooperativeCornerResize.enabled else { return }
        let plan = try XCTUnwrap(topLeftPlan(focusedMinimumSize: CGSize(width: 100, height: 360)))

        ActiveSideSplitRatios.shared.recordAchievedCooperativeAction(.topLeft,
                                                                    achievedFrame: plan.focusedFrame,
                                                                    screenFrame: screenFrame,
                                                                    gapSize: gapSize)

        XCTAssertEqual(plan.focusedFrame.height, 360, accuracy: 0.001)
        XCTAssertEqual(ActiveSideSplitRatios.shared.verticalRatio(for: screenFrame), 390.0 / 900.0, accuracy: 0.001)
        XCTAssertEqual(WindowCalculationFactory.topHalfCalculation.calculateRect(params(for: .topHalf)).rect.height,
                       390,
                       accuracy: 0.001)
    }

    func testRightAndBottomConstraintsRecordSymmetricLeadingSplits() {
        guard Defaults.cooperativeCornerResize.enabled else { return }
        let constrainedTopRight = gappedCornerFrame(horizontalSide: .trailing,
                                                    verticalSide: .leading,
                                                    horizontalFraction: 390.0 / 1200.0,
                                                    verticalFraction: CycleSize.oneThird.fraction,
                                                    action: .topRight)
        ActiveSideSplitRatios.shared.recordAchievedCooperativeAction(.topRight,
                                                                    achievedFrame: constrainedTopRight,
                                                                    screenFrame: screenFrame,
                                                                    gapSize: gapSize)

        XCTAssertEqual(ActiveSideSplitRatios.shared.horizontalRatio(for: screenFrame), 0.675, accuracy: 0.001)
        XCTAssertEqual(WindowCalculationFactory.rightHalfCalculation.calculateRect(params(for: .rightHalf)).rect.width,
                       390,
                       accuracy: 0.001)

        let constrainedBottomRight = gappedCornerFrame(horizontalSide: .trailing,
                                                       verticalSide: .trailing,
                                                       horizontalFraction: 390.0 / 1200.0,
                                                       verticalFraction: 390.0 / 900.0,
                                                       action: .bottomRight)
        ActiveSideSplitRatios.shared.recordAchievedCooperativeAction(.bottomRight,
                                                                    achievedFrame: constrainedBottomRight,
                                                                    screenFrame: screenFrame,
                                                                    gapSize: gapSize)

        XCTAssertEqual(ActiveSideSplitRatios.shared.verticalRatio(for: screenFrame), 1.0 - 390.0 / 900.0, accuracy: 0.001)
        XCTAssertEqual(WindowCalculationFactory.bottomHalfCalculation.calculateRect(params(for: .bottomHalf)).rect.height,
                       390,
                       accuracy: 0.001)
    }

    func testAchievedCooperativeRatiosDoNotChangeSavedDefaults() throws {
        guard Defaults.cooperativeCornerResize.enabled else { return }
        let savedHorizontal = Defaults.horizontalSplitRatio.value
        let savedVertical = Defaults.verticalSplitRatio.value
        let plan = try XCTUnwrap(topLeftPlan(focusedMinimumSize: CGSize(width: 360, height: 360)))

        ActiveSideSplitRatios.shared.recordAchievedCooperativeAction(.topLeft,
                                                                    achievedFrame: plan.focusedFrame,
                                                                    screenFrame: screenFrame,
                                                                    gapSize: gapSize)

        XCTAssertEqual(Defaults.horizontalSplitRatio.value, savedHorizontal, accuracy: 0.001)
        XCTAssertEqual(Defaults.verticalSplitRatio.value, savedVertical, accuracy: 0.001)
        XCTAssertNotEqual(ActiveSideSplitRatios.shared.horizontalRatio(for: screenFrame), savedHorizontal / 100.0)
        XCTAssertNotEqual(ActiveSideSplitRatios.shared.verticalRatio(for: screenFrame), savedVertical / 100.0)
    }

    func testGapIsIncludedWhenDerivingAchievedSplit() throws {
        guard Defaults.cooperativeCornerResize.enabled else { return }
        let plan = try XCTUnwrap(topLeftPlan(focusedMinimumSize: CGSize(width: 360, height: 100)))
        ActiveSideSplitRatios.shared.recordAchievedCooperativeAction(.topLeft,
                                                                    achievedFrame: plan.focusedFrame,
                                                                    screenFrame: screenFrame,
                                                                    gapSize: gapSize)

        let ratioIgnoringInternalHalfGap = Float((plan.focusedFrame.maxX - screenFrame.minX) / screenFrame.width)
        XCTAssertEqual(ratioIgnoringInternalHalfGap, 380.0 / 1200.0, accuracy: 0.001)
        XCTAssertEqual(ActiveSideSplitRatios.shared.horizontalRatio(for: screenFrame), 390.0 / 1200.0, accuracy: 0.001)
    }

    func testCyclicCornerAfterConstraintUsesAchievedPerpendicularRatio() throws {
        guard Defaults.cooperativeCornerResize.enabled else { return }
        let plan = try XCTUnwrap(topLeftPlan(focusedMinimumSize: CGSize(width: 360, height: 100)))
        ActiveSideSplitRatios.shared.recordAchievedCooperativeAction(.topLeft,
                                                                    achievedFrame: plan.focusedFrame,
                                                                    screenFrame: screenFrame,
                                                                    gapSize: gapSize)

        let firstBottomLeft = WindowCalculationFactory.lowerLeftCalculation.calculateRect(params(for: .bottomLeft)).rect
        let cycledBottomLeft = WindowCalculationFactory.lowerLeftCalculation.calculateRect(
            RectCalculationParameters(window: Window(id: 1, rect: firstBottomLeft),
                                      visibleFrameOfScreen: screenFrame,
                                      action: .bottomLeft,
                                      lastAction: RectangleAction(action: .bottomLeft,
                                                                  subAction: nil,
                                                                  rect: firstBottomLeft,
                                                                  count: 1))
        ).rect

        XCTAssertNotEqual(cycledBottomLeft.height, firstBottomLeft.height)
        XCTAssertEqual(cycledBottomLeft.width, 390, accuracy: 0.001)
    }

    private func topLeftPlan(focusedMinimumSize: CGSize) -> CooperativeCornerResize.Plan? {
        let requestedTopLeft = gappedCornerFrame(horizontalSide: .leading,
                                                 verticalSide: .leading,
                                                 horizontalFraction: CycleSize.oneQuarter.fraction,
                                                 verticalFraction: CycleSize.oneThird.fraction,
                                                 action: .topLeft)
        let bottomLeft = gappedCornerFrame(horizontalSide: .leading,
                                           verticalSide: .trailing,
                                           horizontalFraction: CycleSize.oneQuarter.fraction,
                                           verticalFraction: 1.0 - CycleSize.oneThird.fraction,
                                           action: .bottomLeft)

        return CooperativeCornerResize.plan(oldFocusedFrame: CGRect(x: 300, y: 250, width: 400, height: 300),
                                            newFocusedFrame: requestedTopLeft,
                                            screenFrame: screenFrame,
                                            candidates: [CooperativeCornerResize.Candidate(id: 2, frame: bottomLeft)],
                                            axis: .vertical,
                                            tolerance: 8,
                                            minimumSize: CGSize(width: 100, height: 100),
                                            focusedMinimumSize: focusedMinimumSize,
                                            gapSize: gapSize,
                                            captureTolerance: 72,
                                            movedEdgeOverride: .bottom,
                                            candidateDiscoveryFrame: requestedTopLeft,
                                            actionDescription: "test constrained top-left placement")
    }

    private func gappedCornerFrame(horizontalSide: HalfSplitSide,
                                   verticalSide: HalfSplitSide,
                                   horizontalFraction: Float,
                                   verticalFraction: Float,
                                   action: WindowAction) -> CGRect {
        let rawFrame = HalfSplitFrameCalculation.cornerRect(in: screenFrame,
                                                            horizontalSide: horizontalSide,
                                                            verticalSide: verticalSide,
                                                            horizontalFraction: horizontalFraction,
                                                            verticalFraction: verticalFraction)
        return GapCalculation.applyGaps(rawFrame,
                                        sharedEdges: action.gapSharedEdge,
                                        gapSize: Float(gapSize))
    }

    private func params(for action: WindowAction) -> RectCalculationParameters {
        RectCalculationParameters(window: Window(id: 1, rect: screenFrame),
                                  visibleFrameOfScreen: screenFrame,
                                  action: action,
                                  lastAction: nil)
    }
}

class HalfSplitCornerCalculationTests: XCTestCase {
    
    private var savedHorizontalSplitRatio: Float = 50
    private var savedVerticalSplitRatio: Float = 50
    private var savedSubsequentExecutionMode: SubsequentExecutionMode = .resize
    private var savedCornerCycleExpansionAxis: CornerCycleExpansionAxis = .horizontal
    private var savedCycleSizesIsChanged = false
    private var savedSelectedCycleSizes = Set<CycleSize>()
    private var savedGapSize: Float = 0
    private var savedSkipGapTopEdge = false
    private let visibleFrame = CGRect(x: 10, y: 20, width: 1200, height: 900)
    
    override func setUp() {
        super.setUp()
        savedHorizontalSplitRatio = Defaults.horizontalSplitRatio.value
        savedVerticalSplitRatio = Defaults.verticalSplitRatio.value
        savedSubsequentExecutionMode = Defaults.subsequentExecutionMode.value
        savedCornerCycleExpansionAxis = Defaults.cornerCycleExpansionAxis.value
        savedCycleSizesIsChanged = Defaults.cycleSizesIsChanged.enabled
        savedSelectedCycleSizes = Defaults.selectedCycleSizes.value
        savedGapSize = Defaults.gapSize.value
        savedSkipGapTopEdge = Defaults.skipGapTopEdge.enabled
        Defaults.subsequentExecutionMode.value = .resize
        Defaults.cycleSizesIsChanged.enabled = false
        Defaults.gapSize.value = 0
        Defaults.skipGapTopEdge.enabled = false
        ActiveSideSplitRatios.shared.resetAll()
    }
    
    override func tearDown() {
        Defaults.horizontalSplitRatio.value = savedHorizontalSplitRatio
        Defaults.verticalSplitRatio.value = savedVerticalSplitRatio
        Defaults.subsequentExecutionMode.value = savedSubsequentExecutionMode
        Defaults.cornerCycleExpansionAxis.value = savedCornerCycleExpansionAxis
        Defaults.cycleSizesIsChanged.enabled = savedCycleSizesIsChanged
        Defaults.selectedCycleSizes.value = savedSelectedCycleSizes
        Defaults.gapSize.value = savedGapSize
        Defaults.skipGapTopEdge.enabled = savedSkipGapTopEdge
        ActiveSideSplitRatios.shared.resetAll()
        super.tearDown()
    }
    
    func testCornersUseHalfSplitRatioOneHalf() {
        setSplitRatio(50)
        
        assertCornerRects(
            topLeft: CGRect(x: 10, y: 470, width: 600, height: 450),
            topRight: CGRect(x: 610, y: 470, width: 600, height: 450),
            bottomLeft: CGRect(x: 10, y: 20, width: 600, height: 450),
            bottomRight: CGRect(x: 610, y: 20, width: 600, height: 450)
        )
    }
    
    func testCornersUseHalfSplitRatioTwoThirds() {
        setSplitRatio(CycleSize.twoThirds.percentValue)
        
        assertCornerRects(
            topLeft: CGRect(x: 10, y: 320, width: 800, height: 600),
            topRight: CGRect(x: 810, y: 320, width: 400, height: 600),
            bottomLeft: CGRect(x: 10, y: 20, width: 800, height: 300),
            bottomRight: CGRect(x: 810, y: 20, width: 400, height: 300)
        )
    }
    
    func testCornersUseHalfSplitRatioThreeQuarters() {
        setSplitRatio(CycleSize.threeQuarters.percentValue)
        
        assertCornerRects(
            topLeft: CGRect(x: 10, y: 245, width: 900, height: 675),
            topRight: CGRect(x: 910, y: 245, width: 300, height: 675),
            bottomLeft: CGRect(x: 10, y: 20, width: 900, height: 225),
            bottomRight: CGRect(x: 910, y: 20, width: 300, height: 225)
        )
    }
    
    func testCornersUseCustomHalfSplitRatio() {
        setSplitRatio(60)
        
        assertCornerRects(
            topLeft: CGRect(x: 10, y: 380, width: 720, height: 540),
            topRight: CGRect(x: 730, y: 380, width: 480, height: 540),
            bottomLeft: CGRect(x: 10, y: 20, width: 720, height: 360),
            bottomRight: CGRect(x: 730, y: 20, width: 480, height: 360)
        )
    }
    
    func testHalfActionsStillUseHalfSplitRatio() {
        setSplitRatio(60)
        
        assertRect(WindowCalculationFactory.leftHalfCalculation.calculateRect(params(for: .leftHalf)).rect,
                   equals: CGRect(x: 10, y: 20, width: 720, height: 900))
        assertRect(WindowCalculationFactory.rightHalfCalculation.calculateRect(params(for: .rightHalf)).rect,
                   equals: CGRect(x: 730, y: 20, width: 480, height: 900))
        assertRect(WindowCalculationFactory.topHalfCalculation.calculateRect(params(for: .topHalf)).rect,
                   equals: CGRect(x: 10, y: 380, width: 1200, height: 540))
        assertRect(WindowCalculationFactory.bottomHalfCalculation.calculateRect(params(for: .bottomHalf)).rect,
                   equals: CGRect(x: 10, y: 20, width: 1200, height: 360))
    }

    func testRepeatedCornersWithHorizontalExpansionCycleWidthOnly() {
        setSplitRatio(60)
        Defaults.cornerCycleExpansionAxis.value = .horizontal

        assertRepeatedCornerRects(
            topLeft: CGRect(x: 10, y: 380, width: 800, height: 540),
            topRight: CGRect(x: 410, y: 380, width: 800, height: 540),
            bottomLeft: CGRect(x: 10, y: 20, width: 800, height: 360),
            bottomRight: CGRect(x: 410, y: 20, width: 800, height: 360)
        )
    }

    func testSecondRepeatedCornerShortcutBeginsCyclingImmediately() {
        guard Defaults.cooperativeCornerResize.enabled else { return }
        setSplitRatio(CycleSize.twoThirds.percentValue)
        Defaults.cornerCycleExpansionAxis.value = .horizontal

        let firstFrame = WindowCalculationFactory.upperLeftCalculation.calculateRect(params(for: .topLeft)).rect
        let secondFrame = WindowCalculationFactory.upperLeftCalculation.calculateRect(repeatedParams(for: .topLeft, currentRect: firstFrame, count: 1)).rect
        let thirdFrame = WindowCalculationFactory.upperLeftCalculation.calculateRect(repeatedParams(for: .topLeft, currentRect: secondFrame, count: 2)).rect

        assertRect(firstFrame, equals: CGRect(x: 10, y: 320, width: 800, height: 600))
        assertRect(secondFrame, equals: CGRect(x: 10, y: 320, width: 400, height: 600))
        assertRect(thirdFrame, equals: CGRect(x: 10, y: 320, width: 600, height: 600))
    }

    func testRepeatedCornerCyclingDoesNotReturnNoOpFrameWhenBaseMatchesCycleSize() {
        guard Defaults.cooperativeCornerResize.enabled else { return }
        setSplitRatio(CycleSize.twoThirds.percentValue)
        Defaults.cornerCycleExpansionAxis.value = .vertical

        let firstFrame = WindowCalculationFactory.upperRightCalculation.calculateRect(params(for: .topRight)).rect
        let secondFrame = WindowCalculationFactory.upperRightCalculation.calculateRect(repeatedParams(for: .topRight, currentRect: firstFrame, count: 1)).rect

        XCTAssertFalse(firstFrame.equalTo(secondFrame))
        XCTAssertEqual(firstFrame.maxY, secondFrame.maxY, accuracy: 0.001)
        XCTAssertEqual(firstFrame.origin.x, secondFrame.origin.x, accuracy: 0.001)
        XCTAssertEqual(firstFrame.width, secondFrame.width, accuracy: 0.001)
    }

    func testRepeatedCornerCyclingRecognizesGapAdjustedCooperativeBoundary() {
        guard Defaults.cooperativeCornerResize.enabled else { return }
        Defaults.horizontalSplitRatio.value = CycleSize.twoThirds.percentValue
        Defaults.verticalSplitRatio.value = CycleSize.oneThird.percentValue
        Defaults.cornerCycleExpansionAxis.value = .vertical
        Defaults.gapSize.value = 20

        let rawTwoThirdsFrame = WindowCalculationFactory.lowerRightCalculation.calculateRect(params(for: .bottomRight)).rect
        var cooperativeCurrentFrame = GapCalculation.applyGaps(rawTwoThirdsFrame,
                                                               dimension: .both,
                                                               sharedEdges: WindowAction.bottomRight.gapSharedEdge,
                                                               gapSize: Defaults.gapSize.value,
                                                               skipTopGap: Defaults.skipGapTopEdge.enabled)
        cooperativeCurrentFrame.size.height = rawTwoThirdsFrame.height

        let repeatedFrame = WindowCalculationFactory.lowerRightCalculation.calculateRect(repeatedParams(for: .bottomRight,
                                                                                                        currentRect: cooperativeCurrentFrame,
                                                                                                        count: 1)).rect

        assertRect(rawTwoThirdsFrame, equals: CGRect(x: 810, y: 20, width: 400, height: 600))
        assertRect(cooperativeCurrentFrame, equals: CGRect(x: 820, y: 40, width: 370, height: 600))
        assertRect(repeatedFrame, equals: CGRect(x: 810, y: 20, width: 400, height: 300))
    }

    func testCleanupTargetSkipsCornerReducedByAdjacentMinimumConstraint() {
        Defaults.horizontalSplitRatio.value = CycleSize.twoThirds.percentValue
        Defaults.verticalSplitRatio.value = CycleSize.oneThird.percentValue
        Defaults.cornerCycleExpansionAxis.value = .vertical

        let reducedBottomLeft = CGRect(x: 10, y: 20, width: 800, height: 500)
        let cleanupTarget = WindowManager().cleanupTargetFrame(action: .bottomLeft,
                                                              observedFrame: reducedBottomLeft,
                                                              screenFrame: visibleFrame,
                                                              axis: .vertical,
                                                              movedEdge: .top,
                                                              tolerance: 8,
                                                              includeCycleTargets: true)

        XCTAssertNil(cleanupTarget)
    }

    func testCleanupSourceFinderSupportsSideActionsAndIgnoresCorners() {
        setSplitRatio(50)

        let expandedLeft = CGRect(x: 10, y: 20, width: 700, height: 900)
        let remainingLeft = CooperativeCornerResize.Candidate(id: 2,
                                                              frame: expandedLeft)
        let cornerWidthMatch = CooperativeCornerResize.Candidate(id: 3,
                                                                 frame: CGRect(x: 10, y: 470, width: 800, height: 450))
        let sourceFrame = WindowManager().observedCooperativeSourceFrame(action: .leftHalf,
                                                                         oldFocusedFrame: expandedLeft,
                                                                         candidates: [cornerWidthMatch, remainingLeft],
                                                                         screenFrame: visibleFrame,
                                                                         axis: .horizontal,
                                                                         movedEdge: .right,
                                                                         tolerance: 8,
                                                                         captureTolerance: 96,
                                                                         gapSize: 0)

        assertRect(sourceFrame ?? .null, equals: expandedLeft)
    }

    func testCleanupTargetShrinksExpandedSideSource() {
        setSplitRatio(50)

        let expandedLeft = CGRect(x: 10, y: 20, width: 700, height: 900)
        let cleanupTarget = WindowManager().cleanupTargetFrame(action: .leftHalf,
                                                              observedFrame: expandedLeft,
                                                              screenFrame: visibleFrame,
                                                              axis: .horizontal,
                                                              movedEdge: .right,
                                                              tolerance: 8,
                                                              includeCycleTargets: false)

        assertRect(cleanupTarget ?? .null, equals: CGRect(x: 10, y: 20, width: 600, height: 900))
    }

    func testCooperativeHistoryActionMapsAdjacentSideAndCornerActions() {
        let manager = WindowManager()

        XCTAssertEqual(manager.cooperativeHistoryAction(for: .matchingFocusedFrame,
                                                        sourceAction: .leftHalf,
                                                        movedEdge: .right),
                       .leftHalf)
        XCTAssertEqual(manager.cooperativeHistoryAction(for: .adjacent,
                                                        sourceAction: .leftHalf,
                                                        movedEdge: .right),
                       .rightHalf)
        XCTAssertEqual(manager.cooperativeHistoryAction(for: .adjacent,
                                                        sourceAction: .topLeft,
                                                        movedEdge: .bottom),
                       .bottomLeft)
    }

    func testRecordActionCanPreserveCooperativeCorrectionCount() {
        let manager = WindowManager()
        let windowId = CGWindowID(987_654)
        let originalRect = CGRect(x: 10, y: 20, width: 600, height: 900)
        let correctedRect = CGRect(x: 10, y: 20, width: 800, height: 900)
        AppDelegate.windowHistory.lastRectangleActions[windowId] = RectangleAction(action: .leftHalf,
                                                                                   subAction: nil,
                                                                                   rect: originalRect,
                                                                                   count: 3)
        defer {
            AppDelegate.windowHistory.lastRectangleActions.removeValue(forKey: windowId)
        }

        manager.recordAction(windowId: windowId,
                             resultingRect: correctedRect,
                             action: .leftHalf,
                             subAction: nil,
                             incrementCount: false)

        let recorded = AppDelegate.windowHistory.lastRectangleActions[windowId]
        XCTAssertEqual(recorded?.count, 3)
        assertRect(recorded?.rect ?? .null, equals: correctedRect)
    }

    func testCleanupTargetAllowsExpandedMinimumConstrainedCorner() {
        Defaults.horizontalSplitRatio.value = CycleSize.twoThirds.percentValue
        Defaults.verticalSplitRatio.value = CycleSize.oneThird.percentValue
        Defaults.cornerCycleExpansionAxis.value = .vertical

        let expandedTopLeft = CGRect(x: 10, y: 400, width: 800, height: 520)
        let cleanupTarget = WindowManager().cleanupTargetFrame(action: .topLeft,
                                                              observedFrame: expandedTopLeft,
                                                              screenFrame: visibleFrame,
                                                              axis: .vertical,
                                                              movedEdge: .bottom,
                                                              tolerance: 8,
                                                              includeCycleTargets: false)

        assertRect(cleanupTarget ?? .null, equals: CGRect(x: 10, y: 620, width: 800, height: 300))
    }

    func testCleanupTargetShrinksMinimumRestrictedSourceAtConfiguredSize() {
        Defaults.horizontalSplitRatio.value = 50
        Defaults.verticalSplitRatio.value = 40
        Defaults.cornerCycleExpansionAxis.value = .vertical

        let minimumRestrictedTopRight = CGRect(x: 610, y: 560, width: 600, height: 360)

        let cleanupTarget = WindowManager().cleanupTargetFrame(action: .topRight,
                                                              observedFrame: minimumRestrictedTopRight,
                                                              screenFrame: visibleFrame,
                                                              axis: .vertical,
                                                              movedEdge: .bottom,
                                                              tolerance: 8,
                                                              includeCycleTargets: false)

        assertRect(cleanupTarget ?? .null, equals: CGRect(x: 610, y: 620, width: 600, height: 300))
    }

    func testCleanupDestinationAllowsNonAdjacentMinimumRestrictedSourceCleanup() {
        Defaults.horizontalSplitRatio.value = 50
        Defaults.verticalSplitRatio.value = 40
        Defaults.cornerCycleExpansionAxis.value = .vertical

        let manager = WindowManager()
        let minimumRestrictedTopRight = CGRect(x: 610, y: 560, width: 600, height: 360)
        let focusedTopLeftDestination = CGRect(x: 10, y: 620, width: 600, height: 300)
        guard let cleanupTarget = manager.cleanupTargetFrame(action: .topRight,
                                                            observedFrame: minimumRestrictedTopRight,
                                                            screenFrame: visibleFrame,
                                                            axis: .vertical,
                                                            movedEdge: .bottom,
                                                            tolerance: 8,
                                                            includeCycleTargets: false)
        else {
            XCTFail("Expected minimum-restricted cleanup target")
            return
        }

        XCTAssertFalse(manager.frameIsAdjacentToCleanupSource(focusedTopLeftDestination,
                                                              sourceFrame: minimumRestrictedTopRight,
                                                              movedEdge: .bottom,
                                                              axis: .vertical,
                                                              tolerance: 8,
                                                              gapSize: 0))
        XCTAssertTrue(manager.cleanupDestinationAllowsSourceResize(action: .topRight,
                                                                   observedFrame: minimumRestrictedTopRight,
                                                                   targetFrame: cleanupTarget,
                                                                   focusedDestinationFrame: focusedTopLeftDestination,
                                                                   screenFrame: visibleFrame,
                                                                   axis: .vertical,
                                                                   movedEdge: .bottom,
                                                                   tolerance: 8,
                                                                   gapSize: 0))
    }

    func testCleanupSourceFallsBackToDepartedMinimumRestrictedCornerAndExpandsAdjacent() {
        Defaults.horizontalSplitRatio.value = 50
        Defaults.verticalSplitRatio.value = 40
        Defaults.cornerCycleExpansionAxis.value = .vertical

        let manager = WindowManager()
        let departedTopRight = CGRect(x: 610, y: 560, width: 600, height: 360)
        let bottomRight = CooperativeCornerResize.Candidate(id: 2,
                                                            frame: CGRect(x: 610, y: 20, width: 600, height: 540))
        guard let sourceFrame = manager.cleanupSourceFrame(action: .topRight,
                                                           oldFocusedFrame: departedTopRight,
                                                           candidates: [bottomRight],
                                                           screenFrame: visibleFrame,
                                                           axis: .vertical,
                                                           movedEdge: .bottom,
                                                           tolerance: 8,
                                                           captureTolerance: 96,
                                                           gapSize: 0),
              let targetFrame = manager.cleanupTargetFrame(action: .topRight,
                                                           observedFrame: sourceFrame,
                                                           screenFrame: visibleFrame,
                                                           axis: .vertical,
                                                           movedEdge: .bottom,
                                                           tolerance: 8,
                                                           includeCycleTargets: false),
              let plan = CooperativeCornerResize.plan(oldFocusedFrame: sourceFrame,
                                                      newFocusedFrame: targetFrame,
                                                      screenFrame: visibleFrame,
                                                      candidates: [bottomRight],
                                                      axis: .vertical,
                                                      tolerance: 8,
                                                      minimumSize: CGSize(width: 100, height: 100),
                                                      focusedMinimumSize: CGSize(width: 1, height: 1),
                                                      movedEdgeOverride: .bottom,
                                                      candidateDiscoveryFrame: sourceFrame,
                                                      actionDescription: "cooperative resize cleanup after focused window left source")
        else {
            XCTFail("Expected departed minimum-restricted corner cleanup plan")
            return
        }

        assertRect(sourceFrame, equals: departedTopRight)
        assertRect(targetFrame, equals: CGRect(x: 610, y: 620, width: 600, height: 300))
        assertRect(plan.adjustments[0].newFrame, equals: CGRect(x: 610, y: 20, width: 600, height: 600))
    }

    func testCleanupSourceDoesNotFallBackToDepartedCycleCorner() {
        setSplitRatio(50)
        Defaults.cornerCycleExpansionAxis.value = .vertical

        let cycledTopRight = CGRect(x: 610, y: 320, width: 600, height: 600)
        let bottomRight = CooperativeCornerResize.Candidate(id: 2,
                                                            frame: CGRect(x: 610, y: 20, width: 600, height: 300))

        let sourceFrame = WindowManager().cleanupSourceFrame(action: .topRight,
                                                            oldFocusedFrame: cycledTopRight,
                                                            candidates: [bottomRight],
                                                            screenFrame: visibleFrame,
                                                            axis: .vertical,
                                                            movedEdge: .bottom,
                                                            tolerance: 8,
                                                            captureTolerance: 96,
                                                            gapSize: 0)

        XCTAssertNil(sourceFrame)
    }

    func testCleanupDestinationRejectsNonAdjacentCycleSourceCleanup() {
        setSplitRatio(50)
        Defaults.cornerCycleExpansionAxis.value = .vertical

        let manager = WindowManager()
        let cycledBottomRight = CGRect(x: 610, y: 20, width: 600, height: 600)
        let focusedTopLeftDestination = CGRect(x: 10, y: 620, width: 600, height: 300)
        let hypotheticalCleanupTarget = CGRect(x: 610, y: 20, width: 600, height: 450)

        XCTAssertFalse(manager.frameIsAdjacentToCleanupSource(focusedTopLeftDestination,
                                                              sourceFrame: cycledBottomRight,
                                                              movedEdge: .top,
                                                              axis: .vertical,
                                                              tolerance: 8,
                                                              gapSize: 0))
        XCTAssertFalse(manager.cleanupDestinationAllowsSourceResize(action: .bottomRight,
                                                                    observedFrame: cycledBottomRight,
                                                                    targetFrame: hypotheticalCleanupTarget,
                                                                    focusedDestinationFrame: focusedTopLeftDestination,
                                                                    screenFrame: visibleFrame,
                                                                    axis: .vertical,
                                                                    movedEdge: .top,
                                                                    tolerance: 8,
                                                                    gapSize: 0))
    }

    func testCleanupTargetDoesNotShrinkComplementOfMinimumRestrictedAdjacent() {
        Defaults.horizontalSplitRatio.value = 50
        Defaults.verticalSplitRatio.value = CycleSize.oneThird.percentValue
        Defaults.cornerCycleExpansionAxis.value = .vertical

        let complementaryBottomRight = CGRect(x: 610, y: 20, width: 600, height: 540)
        let minimumBandTopRight = CooperativeCornerResize.Candidate(id: 2,
                                                                    frame: CGRect(x: 610, y: 560, width: 600, height: 360))

        let cleanupTarget = WindowManager().cleanupTargetFrame(action: .bottomRight,
                                                              observedFrame: complementaryBottomRight,
                                                              screenFrame: visibleFrame,
                                                              axis: .vertical,
                                                              movedEdge: .top,
                                                              tolerance: 8,
                                                              includeCycleTargets: false,
                                                              candidates: [minimumBandTopRight])

        XCTAssertNil(cleanupTarget)
    }

    func testCleanupTargetDoesNotShrinkInitialCycleSourceWithMinimumCycleAdjacent() {
        Defaults.horizontalSplitRatio.value = 50
        Defaults.verticalSplitRatio.value = CycleSize.oneThird.percentValue
        Defaults.cornerCycleExpansionAxis.value = .vertical

        let cycledBottomLeft = CGRect(x: 10, y: 20, width: 600, height: 600)
        let selectedCycleTopLeft = CooperativeCornerResize.Candidate(id: 2,
                                                                     frame: CGRect(x: 10, y: 620, width: 600, height: 300))

        let cleanupTarget = WindowManager().cleanupTargetFrame(action: .bottomLeft,
                                                              observedFrame: cycledBottomLeft,
                                                              screenFrame: visibleFrame,
                                                              axis: .vertical,
                                                              movedEdge: .top,
                                                              tolerance: 8,
                                                              includeCycleTargets: false,
                                                              candidates: [selectedCycleTopLeft])

        XCTAssertNil(cleanupTarget)
    }

    func testCleanupTargetDoesNotShrinkRepeatedCycleSourceWithMinimumCycleAdjacent() {
        Defaults.horizontalSplitRatio.value = 50
        Defaults.verticalSplitRatio.value = CycleSize.oneThird.percentValue
        Defaults.cornerCycleExpansionAxis.value = .vertical

        let cycledBottomLeft = CGRect(x: 10, y: 20, width: 600, height: 600)
        let selectedCycleTopLeft = CooperativeCornerResize.Candidate(id: 2,
                                                                     frame: CGRect(x: 10, y: 620, width: 600, height: 300))

        let cleanupTarget = WindowManager().cleanupTargetFrame(action: .bottomLeft,
                                                              observedFrame: cycledBottomLeft,
                                                              screenFrame: visibleFrame,
                                                              axis: .vertical,
                                                              movedEdge: .top,
                                                              tolerance: 8,
                                                              includeCycleTargets: true,
                                                              candidates: [selectedCycleTopLeft])

        XCTAssertNil(cleanupTarget)
    }

    func testCleanupTargetDoesNotShrinkValidCycleCornerFromOriginalLocation() {
        setSplitRatio(50)
        Defaults.cornerCycleExpansionAxis.value = .vertical

        let cycledTopRight = CGRect(x: 610, y: 320, width: 600, height: 600)
        let minimumCycleBottomRight = CooperativeCornerResize.Candidate(id: 2,
                                                                        frame: CGRect(x: 610, y: 20, width: 600, height: 300))

        let cleanupTarget = WindowManager().cleanupTargetFrame(action: .topRight,
                                                              observedFrame: cycledTopRight,
                                                              screenFrame: visibleFrame,
                                                              axis: .vertical,
                                                              movedEdge: .bottom,
                                                              tolerance: 8,
                                                              includeCycleTargets: false,
                                                              candidates: [minimumCycleBottomRight])

        XCTAssertNil(cleanupTarget)
    }

    func testCleanupTargetDoesNotShrinkComplementOfSelectedAdjacentCycleSize() {
        setSplitRatio(50)
        Defaults.cornerCycleExpansionAxis.value = .vertical
        Defaults.cycleSizesIsChanged.enabled = true
        Defaults.selectedCycleSizes.value = [.oneHalf, .oneThird]

        let complementaryBottomLeft = CGRect(x: 10, y: 20, width: 600, height: 600)
        let selectedCycleTopLeft = CooperativeCornerResize.Candidate(id: 2,
                                                                     frame: CGRect(x: 10, y: 620, width: 600, height: 300))

        let cleanupTarget = WindowManager().cleanupTargetFrame(action: .bottomLeft,
                                                              observedFrame: complementaryBottomLeft,
                                                              screenFrame: visibleFrame,
                                                              axis: .vertical,
                                                              movedEdge: .top,
                                                              tolerance: 8,
                                                              includeCycleTargets: false,
                                                              candidates: [selectedCycleTopLeft])

        XCTAssertNil(cleanupTarget)
    }

    func testCleanupTargetDoesNotShrinkBalancedCorner() {
        setSplitRatio(50)
        Defaults.cornerCycleExpansionAxis.value = .vertical

        let bottomRight = CGRect(x: 610, y: 20, width: 600, height: 450)
        let balancedTopRight = CooperativeCornerResize.Candidate(id: 2,
                                                                 frame: CGRect(x: 610, y: 470, width: 600, height: 450))

        let cleanupTarget = WindowManager().cleanupTargetFrame(action: .bottomRight,
                                                              observedFrame: bottomRight,
                                                              screenFrame: visibleFrame,
                                                              axis: .vertical,
                                                              movedEdge: .top,
                                                              tolerance: 8,
                                                              includeCycleTargets: false,
                                                              candidates: [balancedTopRight])

        XCTAssertNil(cleanupTarget)
    }

    func testRepeatedCornerLookAheadSkipsExpansionWhenAdjacentIsInMinimumCycleBand() {
        setSplitRatio(50)
        Defaults.cornerCycleExpansionAxis.value = .vertical

        let oldFocusedFrame = CGRect(x: 10, y: 20, width: 600, height: 540)
        let requestedTwoThirdsFrame = CGRect(x: 10, y: 20, width: 600, height: 600)
        let minimumRestrictedTop = CooperativeCornerResize.Candidate(id: 2,
                                                                     frame: CGRect(x: 10, y: 560, width: 600, height: 360))

        let lookAheadTarget = WindowManager().cycleLookAheadTargetForMinimumRestrictedAdjacent(action: .bottomLeft,
                                                                                               oldFocusedFrame: oldFocusedFrame,
                                                                                               requestedFocusedFrame: requestedTwoThirdsFrame,
                                                                                               screenFrame: visibleFrame,
                                                                                               candidates: [minimumRestrictedTop],
                                                                                               axis: .vertical,
                                                                                               movedEdge: .top,
                                                                                               tolerance: 8,
                                                                                               gapSize: 0)

        XCTAssertEqual(lookAheadTarget?.skippedCycleSize, .twoThirds)
        XCTAssertEqual(lookAheadTarget?.targetCycleSize, .oneThird)
        XCTAssertEqual(lookAheadTarget?.restrictedAdjacentId, 2)
        assertRect(lookAheadTarget?.rawFrame ?? .null, equals: CGRect(x: 10, y: 20, width: 600, height: 300))
        assertRect(lookAheadTarget?.gappedFrame ?? .null, equals: CGRect(x: 10, y: 20, width: 600, height: 300))
    }

    func testRepeatedCornerLookAheadDoesNotSkipWhenAdjacentIsAtCycleBoundary() {
        setSplitRatio(50)
        Defaults.cornerCycleExpansionAxis.value = .vertical

        let oldFocusedFrame = CGRect(x: 10, y: 20, width: 600, height: 450)
        let requestedTwoThirdsFrame = CGRect(x: 10, y: 20, width: 600, height: 600)
        let halfHeightTop = CooperativeCornerResize.Candidate(id: 2,
                                                              frame: CGRect(x: 10, y: 470, width: 600, height: 450))

        let lookAheadTarget = WindowManager().cycleLookAheadTargetForMinimumRestrictedAdjacent(action: .bottomLeft,
                                                                                               oldFocusedFrame: oldFocusedFrame,
                                                                                               requestedFocusedFrame: requestedTwoThirdsFrame,
                                                                                               screenFrame: visibleFrame,
                                                                                               candidates: [halfHeightTop],
                                                                                               axis: .vertical,
                                                                                               movedEdge: .top,
                                                                                               tolerance: 8,
                                                                                               gapSize: 0)

        XCTAssertNil(lookAheadTarget)
    }

    func testRepeatedCornerLookAheadWrapsPastMaximumBlockedByMinimumRestrictedAdjacent() {
        let screenFrame = CGRect(x: 0, y: 140, width: 3200, height: 1660)
        Defaults.horizontalSplitRatio.value = CycleSize.twoThirds.percentValue
        Defaults.verticalSplitRatio.value = CycleSize.oneThird.percentValue
        Defaults.cornerCycleExpansionAxis.value = .vertical
        Defaults.cycleSizesIsChanged.enabled = true
        Defaults.selectedCycleSizes.value = Set(CycleSize.allCases)
        Defaults.gapSize.value = 20
        ActiveSideSplitRatios.shared.resetAll()

        let achievedBottomLeft = CGRect(x: 20, y: 160, width: 2200, height: 1100)
        ActiveSideSplitRatios.shared.recordAchievedCooperativeAction(.bottomLeft,
                                                                    achievedFrame: achievedBottomLeft,
                                                                    screenFrame: screenFrame,
                                                                    gapSize: 20)
        let cycleParams = RectCalculationParameters(window: Window(id: 1, rect: achievedBottomLeft),
                                                    visibleFrameOfScreen: screenFrame,
                                                    action: .bottomLeft,
                                                    lastAction: nil)
        let rawThreeQuarters = WindowCalculationFactory.lowerLeftCalculation.calculateFractionalRect(cycleParams,
                                                                                                      fraction: CycleSize.threeQuarters.fraction).rect
        let requestedThreeQuarters = GapCalculation.applyGaps(rawThreeQuarters,
                                                              sharedEdges: WindowAction.bottomLeft.gapSharedEdge,
                                                              gapSize: 20)
        let minimumRestrictedTop = CooperativeCornerResize.Candidate(id: 2,
                                                                     frame: CGRect(x: 20, y: 1280, width: 2200, height: 500))

        let lookAheadTarget = WindowManager().cycleLookAheadTargetForMinimumRestrictedAdjacent(action: .bottomLeft,
                                                                                               oldFocusedFrame: achievedBottomLeft,
                                                                                               requestedFocusedFrame: requestedThreeQuarters,
                                                                                               screenFrame: screenFrame,
                                                                                               candidates: [minimumRestrictedTop],
                                                                                               axis: .vertical,
                                                                                               movedEdge: .top,
                                                                                               tolerance: 24,
                                                                                               gapSize: 20)

        XCTAssertEqual(lookAheadTarget?.skippedCycleSize, .threeQuarters)
        XCTAssertEqual(lookAheadTarget?.targetCycleSize, .oneQuarter)
        XCTAssertEqual(lookAheadTarget?.gappedFrame.height ?? -1, 385, accuracy: 0.001)
    }

    func testRestrictedHeightCornerLeavingAttemptsNextSmallerCycleSize() {
        let screenFrame = CGRect(x: 0, y: 140, width: 3200, height: 1660)
        Defaults.horizontalSplitRatio.value = CycleSize.twoThirds.percentValue
        Defaults.verticalSplitRatio.value = CycleSize.oneThird.percentValue
        Defaults.cornerCycleExpansionAxis.value = .vertical
        Defaults.cycleSizesIsChanged.enabled = true
        Defaults.selectedCycleSizes.value = Set(CycleSize.allCases)
        Defaults.gapSize.value = 20
        ActiveSideSplitRatios.shared.resetAll()

        let minimumRestrictedTop = CGRect(x: 20, y: 1280, width: 2200, height: 500)
        ActiveSideSplitRatios.shared.recordAchievedCooperativeAction(.topLeft,
                                                                    achievedFrame: minimumRestrictedTop,
                                                                    screenFrame: screenFrame,
                                                                    gapSize: 20)

        let cleanupTarget = WindowManager().cleanupTargetFrame(action: .topLeft,
                                                              observedFrame: minimumRestrictedTop,
                                                              screenFrame: screenFrame,
                                                              axis: .vertical,
                                                              movedEdge: .bottom,
                                                              tolerance: 24,
                                                              includeCycleTargets: false,
                                                              gapSize: 20)

        assertRect(cleanupTarget ?? .null, equals: CGRect(x: 20, y: 1395, width: 2200, height: 385))
    }

    func testCleanupSourceAdjacencyOnlyMatchesDirectDestination() {
        let manager = WindowManager()
        let sourceTopLeft = CGRect(x: 10, y: 400, width: 800, height: 520)
        let adjacentBottomLeft = CGRect(x: 10, y: 20, width: 800, height: 380)
        let otherBottom = CGRect(x: 810, y: 20, width: 400, height: 380)
        let sourceBottomRight = CGRect(x: 610, y: 20, width: 600, height: 540)
        let diagonalTopLeft = CGRect(x: 10, y: 560, width: 600, height: 360)

        XCTAssertTrue(manager.frameIsAdjacentToCleanupSource(adjacentBottomLeft,
                                                             sourceFrame: sourceTopLeft,
                                                             movedEdge: .bottom,
                                                             axis: .vertical,
                                                             tolerance: 8,
                                                             gapSize: 0))
        XCTAssertFalse(manager.frameIsAdjacentToCleanupSource(otherBottom,
                                                              sourceFrame: sourceTopLeft,
                                                              movedEdge: .bottom,
                                                              axis: .vertical,
                                                              tolerance: 8,
                                                              gapSize: 0))
        XCTAssertFalse(manager.frameIsAdjacentToCleanupSource(adjacentBottomLeft,
                                                              sourceFrame: sourceTopLeft,
                                                              movedEdge: .right,
                                                              axis: .vertical,
                                                              tolerance: 8,
                                                              gapSize: 0))
        XCTAssertFalse(manager.frameIsAdjacentToCleanupSource(diagonalTopLeft,
                                                              sourceFrame: sourceBottomRight,
                                                              movedEdge: .top,
                                                              axis: .vertical,
                                                              tolerance: 8,
                                                              gapSize: 0))
    }

    func testRepeatedCornersWithVerticalExpansionCycleHeightOnly() {
        setSplitRatio(60)
        Defaults.cornerCycleExpansionAxis.value = .vertical

        assertRepeatedCornerRects(
            topLeft: CGRect(x: 10, y: 320, width: 720, height: 600),
            topRight: CGRect(x: 730, y: 320, width: 480, height: 600),
            bottomLeft: CGRect(x: 10, y: 20, width: 720, height: 600),
            bottomRight: CGRect(x: 730, y: 20, width: 480, height: 600)
        )
    }

    func testRepeatedHalfActionsStillCycleOnTheirNaturalAxis() {
        setSplitRatio(60)
        Defaults.cornerCycleExpansionAxis.value = .vertical

        assertRect(WindowCalculationFactory.leftHalfCalculation.calculateRepeatedRect(repeatedParams(for: .leftHalf)).rect,
                   equals: CGRect(x: 10, y: 20, width: 800, height: 900))
        assertRect(WindowCalculationFactory.rightHalfCalculation.calculateRepeatedRect(repeatedParams(for: .rightHalf)).rect,
                   equals: CGRect(x: 410, y: 20, width: 800, height: 900))

        Defaults.cornerCycleExpansionAxis.value = .horizontal

        assertRect(WindowCalculationFactory.topHalfCalculation.calculateRect(repeatedParams(for: .topHalf)).rect,
                   equals: CGRect(x: 10, y: 320, width: 1200, height: 600))
        assertRect(WindowCalculationFactory.bottomHalfCalculation.calculateRect(repeatedParams(for: .bottomHalf)).rect,
                   equals: CGRect(x: 10, y: 20, width: 1200, height: 600))
    }

    func testRepeatedHalfActionStartsAtFirstSelectedCycleSizeWhenOneHalfIsDeselected() {
        setSplitRatio(50)
        Defaults.cycleSizesIsChanged.enabled = true
        Defaults.selectedCycleSizes.value = [.oneThird, .twoThirds]

        let firstRepeatedRect = WindowCalculationFactory.bottomHalfCalculation.calculateRepeatedRect(repeatedParams(for: .bottomHalf)).rect
        let secondRepeatedRect = WindowCalculationFactory.bottomHalfCalculation.calculateRepeatedRect(repeatedParams(for: .bottomHalf, currentRect: firstRepeatedRect, count: 2)).rect

        assertRect(firstRepeatedRect, equals: CGRect(x: 10, y: 20, width: 1200, height: 600))
        assertRect(secondRepeatedRect, equals: CGRect(x: 10, y: 20, width: 1200, height: 300))
    }

    func testRepeatedBottomCornerStartsAtFirstSelectedCycleSizeWhenOneHalfIsDeselected() {
        setSplitRatio(50)
        Defaults.cornerCycleExpansionAxis.value = .vertical
        Defaults.cycleSizesIsChanged.enabled = true
        Defaults.selectedCycleSizes.value = [.oneThird, .twoThirds]

        let firstRect = WindowCalculationFactory.lowerLeftCalculation.calculateRect(params(for: .bottomLeft)).rect
        let firstRepeatedRect = WindowCalculationFactory.lowerLeftCalculation.calculateRect(repeatedParams(for: .bottomLeft, currentRect: firstRect)).rect
        let secondRepeatedRect = WindowCalculationFactory.lowerLeftCalculation.calculateRect(repeatedParams(for: .bottomLeft, currentRect: firstRepeatedRect, count: 2)).rect

        assertRect(firstRect, equals: CGRect(x: 10, y: 20, width: 600, height: 450))
        assertRect(firstRepeatedRect, equals: CGRect(x: 10, y: 20, width: 600, height: 600))
        assertRect(secondRepeatedRect, equals: CGRect(x: 10, y: 20, width: 600, height: 300))
    }

    func testRepeatedSideShortcutAdvancesWhenCurrentFrameMatchesSplitRatioCycleSize() {
        guard Defaults.cooperativeCornerResize.enabled else { return }
        setSplitRatio(CycleSize.twoThirds.percentValue)

        let leftFrame = WindowCalculationFactory.leftHalfCalculation.calculateRect(params(for: .leftHalf)).rect
        let repeatedLeftFrame = WindowCalculationFactory.leftHalfCalculation.calculateRepeatedRect(repeatedParams(for: .leftHalf, currentRect: leftFrame)).rect

        assertRect(leftFrame, equals: CGRect(x: 10, y: 20, width: 800, height: 900))
        assertRect(repeatedLeftFrame, equals: CGRect(x: 10, y: 20, width: 400, height: 900))
    }

    func testRepeatedTopShortcutAdvancesWhenCurrentFrameMatchesSplitRatioCycleSize() {
        guard Defaults.cooperativeCornerResize.enabled else { return }
        setSplitRatio(CycleSize.twoThirds.percentValue)

        let topFrame = WindowCalculationFactory.topHalfCalculation.calculateRect(params(for: .topHalf)).rect
        let repeatedTopFrame = WindowCalculationFactory.topHalfCalculation.calculateRepeatedRect(repeatedParams(for: .topHalf, currentRect: topFrame)).rect

        assertRect(topFrame, equals: CGRect(x: 10, y: 320, width: 1200, height: 600))
        assertRect(repeatedTopFrame, equals: CGRect(x: 10, y: 620, width: 1200, height: 300))
    }

    func testRepeatedRightShortcutUpdatesActiveSplitForSubsequentCorners() {
        guard Defaults.cooperativeCornerResize.enabled else { return }
        Defaults.horizontalSplitRatio.value = CycleSize.twoThirds.percentValue
        Defaults.verticalSplitRatio.value = 50
        ActiveSideSplitRatios.shared.resetAll()

        let firstRightFrame = WindowCalculationFactory.rightHalfCalculation.calculateRect(params(for: .rightHalf)).rect
        let repeatedRightFrame = WindowCalculationFactory.rightHalfCalculation.calculateRepeatedRect(repeatedParams(for: .rightHalf,
                                                                                                                    currentRect: firstRightFrame)).rect

        ActiveSideSplitRatios.shared.recordSideAction(.rightHalf,
                                                      targetFrame: repeatedRightFrame,
                                                      screenFrame: visibleFrame)

        let topRightFrame = WindowCalculationFactory.upperRightCalculation.calculateRect(params(for: .topRight)).rect
        let topLeftFrame = WindowCalculationFactory.upperLeftCalculation.calculateRect(params(for: .topLeft)).rect

        assertRect(firstRightFrame, equals: CGRect(x: 810, y: 20, width: 400, height: 900))
        assertRect(repeatedRightFrame, equals: CGRect(x: 410, y: 20, width: 800, height: 900))
        assertRect(topRightFrame, equals: CGRect(x: 410, y: 470, width: 800, height: 450))
        assertRect(topLeftFrame, equals: CGRect(x: 10, y: 470, width: 400, height: 450))
        XCTAssertEqual(Defaults.horizontalSplitRatio.value, CycleSize.twoThirds.percentValue, accuracy: 0.001)
    }

    func testRepeatedBottomShortcutUpdatesActiveSplitForSubsequentCorners() {
        guard Defaults.cooperativeCornerResize.enabled else { return }
        Defaults.horizontalSplitRatio.value = 50
        Defaults.verticalSplitRatio.value = CycleSize.twoThirds.percentValue
        ActiveSideSplitRatios.shared.resetAll()

        let firstBottomFrame = WindowCalculationFactory.bottomHalfCalculation.calculateRect(params(for: .bottomHalf)).rect
        let repeatedBottomFrame = WindowCalculationFactory.bottomHalfCalculation.calculateRepeatedRect(repeatedParams(for: .bottomHalf,
                                                                                                                      currentRect: firstBottomFrame)).rect

        ActiveSideSplitRatios.shared.recordSideAction(.bottomHalf,
                                                      targetFrame: repeatedBottomFrame,
                                                      screenFrame: visibleFrame)

        let bottomRightFrame = WindowCalculationFactory.lowerRightCalculation.calculateRect(params(for: .bottomRight)).rect
        let topRightFrame = WindowCalculationFactory.upperRightCalculation.calculateRect(params(for: .topRight)).rect

        assertRect(firstBottomFrame, equals: CGRect(x: 10, y: 20, width: 1200, height: 300))
        assertRect(repeatedBottomFrame, equals: CGRect(x: 10, y: 20, width: 1200, height: 600))
        assertRect(bottomRightFrame, equals: CGRect(x: 610, y: 20, width: 600, height: 600))
        assertRect(topRightFrame, equals: CGRect(x: 610, y: 620, width: 600, height: 300))
        XCTAssertEqual(Defaults.verticalSplitRatio.value, CycleSize.twoThirds.percentValue, accuracy: 0.001)
    }

    func testActiveSideSplitIsScopedToDisplayFrame() {
        guard Defaults.cooperativeCornerResize.enabled else { return }
        Defaults.horizontalSplitRatio.value = CycleSize.twoThirds.percentValue
        ActiveSideSplitRatios.shared.resetAll()

        let cycledRightFrame = CGRect(x: 410, y: 20, width: 800, height: 900)
        let otherDisplayFrame = CGRect(x: 2000, y: 20, width: 1200, height: 900)

        ActiveSideSplitRatios.shared.recordSideAction(.rightHalf,
                                                      targetFrame: cycledRightFrame,
                                                      screenFrame: visibleFrame)

        XCTAssertEqual(ActiveSideSplitRatios.shared.horizontalRatio(for: visibleFrame),
                       CycleSize.oneThird.fraction,
                       accuracy: 0.001)
        XCTAssertEqual(ActiveSideSplitRatios.shared.horizontalRatio(for: otherDisplayFrame),
                       CycleSize.twoThirds.fraction,
                       accuracy: 0.001)
    }

    func testChangingSavedSplitRatioResetsActiveRuntimeSplit() {
        Defaults.horizontalSplitRatio.value = CycleSize.twoThirds.percentValue
        ActiveSideSplitRatios.shared.resetAll()
        ActiveSideSplitRatios.shared.recordSideAction(.rightHalf,
                                                      targetFrame: CGRect(x: 410, y: 20, width: 800, height: 900),
                                                      screenFrame: visibleFrame)

        Defaults.horizontalSplitRatio.value = 50

        XCTAssertEqual(ActiveSideSplitRatios.shared.horizontalRatio(for: visibleFrame), 0.5, accuracy: 0.001)
    }

    func testHorizontalCornerShortcutCanCycleAfterCompatibleSideShortcut() {
        guard Defaults.cooperativeCornerResize.enabled else { return }
        setSplitRatio(50)
        Defaults.cornerCycleExpansionAxis.value = .horizontal

        let leftFrame = WindowCalculationFactory.leftHalfCalculation.calculateRect(params(for: .leftHalf)).rect
        let topLeftFrame = WindowCalculationFactory.upperLeftCalculation.calculateRect(RectCalculationParameters(window: Window(id: 1, rect: leftFrame),
                                                                                                                visibleFrameOfScreen: visibleFrame,
                                                                                                                action: .topLeft,
                                                                                                                lastAction: RectangleAction(action: .leftHalf,
                                                                                                                                            subAction: nil,
                                                                                                                                            rect: leftFrame,
                                                                                                                                            count: 1))).rect

        assertRect(topLeftFrame, equals: CGRect(x: 10, y: 470, width: 800, height: 450))
    }

    func testVerticalCornerShortcutCanCycleAfterCompatibleSideShortcut() {
        guard Defaults.cooperativeCornerResize.enabled else { return }
        setSplitRatio(50)
        Defaults.cornerCycleExpansionAxis.value = .vertical

        let topFrame = WindowCalculationFactory.topHalfCalculation.calculateRect(params(for: .topHalf)).rect
        let topLeftFrame = WindowCalculationFactory.upperLeftCalculation.calculateRect(RectCalculationParameters(window: Window(id: 1, rect: topFrame),
                                                                                                                visibleFrameOfScreen: visibleFrame,
                                                                                                                action: .topLeft,
                                                                                                                lastAction: RectangleAction(action: .topHalf,
                                                                                                                                            subAction: nil,
                                                                                                                                            rect: topFrame,
                                                                                                                                            count: 1))).rect

        assertRect(topLeftFrame, equals: CGRect(x: 10, y: 320, width: 600, height: 600))
    }

    func testDifferentTopCornerShortcutDoesNotTriggerVerticalExpansionCycleAtOneThirdSplit() {
        setSplitRatio(CycleSize.oneThird.percentValue)
        Defaults.cornerCycleExpansionAxis.value = .vertical

        let topLeftFrame = WindowCalculationFactory.upperLeftCalculation.calculateRect(params(for: .topLeft)).rect
        let topRightFrame = WindowCalculationFactory.upperRightCalculation.calculateRect(RectCalculationParameters(window: Window(id: 1, rect: topLeftFrame),
                                                                                                                  visibleFrameOfScreen: visibleFrame,
                                                                                                                  action: .topRight,
                                                                                                                  lastAction: RectangleAction(action: .topLeft,
                                                                                                                                              subAction: nil,
                                                                                                                                              rect: topLeftFrame,
                                                                                                                                              count: 1))).rect

        assertRect(topLeftFrame, equals: CGRect(x: 10, y: 620, width: 400, height: 300))
        assertRect(topRightFrame, equals: CGRect(x: 410, y: 620, width: 800, height: 300))
    }

    func testRepeatedHalfActionWithNoCycleSizesSelectedUsesFirstRect() {
        setSplitRatio(60)
        Defaults.cycleSizesIsChanged.enabled = true
        Defaults.selectedCycleSizes.value = []

        assertRect(WindowCalculationFactory.leftHalfCalculation.calculateRepeatedRect(repeatedParams(for: .leftHalf)).rect,
                   equals: CGRect(x: 10, y: 20, width: 720, height: 900))
    }

    func testRepeatedCornerActionWithNoCycleSizesSelectedUsesFirstRect() {
        setSplitRatio(60)
        Defaults.cycleSizesIsChanged.enabled = true
        Defaults.selectedCycleSizes.value = []

        let firstRect = WindowCalculationFactory.upperLeftCalculation.calculateRect(params(for: .topLeft)).rect
        let repeatedRect = WindowCalculationFactory.upperLeftCalculation.calculateRect(repeatedParams(for: .topLeft, currentRect: firstRect)).rect

        assertRect(repeatedRect, equals: firstRect)
    }
    
    private func setSplitRatio(_ percent: Float) {
        Defaults.horizontalSplitRatio.value = percent
        Defaults.verticalSplitRatio.value = percent
    }
    
    private func assertCornerRects(topLeft: CGRect, topRight: CGRect, bottomLeft: CGRect, bottomRight: CGRect) {
        assertRect(WindowCalculationFactory.upperLeftCalculation.calculateRect(params(for: .topLeft)).rect, equals: topLeft)
        assertRect(WindowCalculationFactory.upperRightCalculation.calculateRect(params(for: .topRight)).rect, equals: topRight)
        assertRect(WindowCalculationFactory.lowerLeftCalculation.calculateRect(params(for: .bottomLeft)).rect, equals: bottomLeft)
        assertRect(WindowCalculationFactory.lowerRightCalculation.calculateRect(params(for: .bottomRight)).rect, equals: bottomRight)
    }

    private func assertRepeatedCornerRects(topLeft: CGRect, topRight: CGRect, bottomLeft: CGRect, bottomRight: CGRect) {
        let topLeftBase = WindowCalculationFactory.upperLeftCalculation.calculateRect(params(for: .topLeft)).rect
        let topRightBase = WindowCalculationFactory.upperRightCalculation.calculateRect(params(for: .topRight)).rect
        let bottomLeftBase = WindowCalculationFactory.lowerLeftCalculation.calculateRect(params(for: .bottomLeft)).rect
        let bottomRightBase = WindowCalculationFactory.lowerRightCalculation.calculateRect(params(for: .bottomRight)).rect

        assertRect(WindowCalculationFactory.upperLeftCalculation.calculateRect(repeatedParams(for: .topLeft, currentRect: topLeftBase)).rect, equals: topLeft)
        assertRect(WindowCalculationFactory.upperRightCalculation.calculateRect(repeatedParams(for: .topRight, currentRect: topRightBase)).rect, equals: topRight)
        assertRect(WindowCalculationFactory.lowerLeftCalculation.calculateRect(repeatedParams(for: .bottomLeft, currentRect: bottomLeftBase)).rect, equals: bottomLeft)
        assertRect(WindowCalculationFactory.lowerRightCalculation.calculateRect(repeatedParams(for: .bottomRight, currentRect: bottomRightBase)).rect, equals: bottomRight)
    }
    
    private func params(for action: WindowAction) -> RectCalculationParameters {
        RectCalculationParameters(window: Window(id: 1, rect: visibleFrame),
                                  visibleFrameOfScreen: visibleFrame,
                                  action: action,
                                  lastAction: nil)
    }

    private func repeatedParams(for action: WindowAction, currentRect: CGRect? = nil, count: Int = 1) -> RectCalculationParameters {
        RectCalculationParameters(window: Window(id: 1, rect: currentRect ?? visibleFrame),
                                  visibleFrameOfScreen: visibleFrame,
                                  action: action,
                                  lastAction: RectangleAction(action: action,
                                                              subAction: nil,
                                                              rect: currentRect ?? visibleFrame,
                                                              count: count))
    }
    
    private func assertRect(_ rect: CGRect, equals expected: CGRect, file: StaticString = #filePath, line: UInt = #line) {
        XCTAssertEqual(rect.origin.x, expected.origin.x, accuracy: 0.001, file: file, line: line)
        XCTAssertEqual(rect.origin.y, expected.origin.y, accuracy: 0.001, file: file, line: line)
        XCTAssertEqual(rect.width, expected.width, accuracy: 0.001, file: file, line: line)
        XCTAssertEqual(rect.height, expected.height, accuracy: 0.001, file: file, line: line)
    }
}

class OverlapOffsetGuardsTests: XCTestCase {

    func testMaxCascadeClampedToMinOne() {
        let result = min(5, max(1, 0))
        XCTAssertEqual(result, 1)
    }

    func testMaxCascadeClampedToMaxFive() {
        let result = min(5, max(1, 999))
        XCTAssertEqual(result, 5)
    }

    func testMaxCascadeNegativeClampsToOne() {
        let result = min(5, max(1, -10))
        XCTAssertEqual(result, 1)
    }

    func testMaxCascadeNormalValuePassesThrough() {
        let result = min(5, max(1, 3))
        XCTAssertEqual(result, 3)
    }

    func testOffsetClampingKeepsRectInScreen() {
        let screenFrame = CGRect(x: 0, y: 0, width: 2336, height: 1466)
        var candidate = CGRect(x: 2300, y: 1400, width: 400, height: 300)
        let overlapOffset: CGFloat = 11

        candidate.origin.x += overlapOffset
        candidate.origin.y += overlapOffset

        if candidate.origin.x + candidate.width > screenFrame.maxX {
            candidate.origin.x = screenFrame.maxX - candidate.width
        }
        if candidate.origin.y + candidate.height > screenFrame.maxY {
            candidate.origin.y = screenFrame.maxY - candidate.height
        }
        if candidate.origin.x < screenFrame.origin.x {
            candidate.origin.x = screenFrame.origin.x
        }
        if candidate.origin.y < screenFrame.origin.y {
            candidate.origin.y = screenFrame.origin.y
        }

        XCTAssertLessThanOrEqual(candidate.origin.x + candidate.width, screenFrame.maxX)
        XCTAssertLessThanOrEqual(candidate.origin.y + candidate.height, screenFrame.maxY)
        XCTAssertGreaterThanOrEqual(candidate.origin.x, screenFrame.origin.x)
        XCTAssertGreaterThanOrEqual(candidate.origin.y, screenFrame.origin.y)
    }

    func testOffsetClampingWithNegativeScreenOrigin() {
        let screenFrame = CGRect(x: -1372, y: 1510, width: 3840, height: 2160)
        var candidate = CGRect(x: -1372, y: 1510, width: 960, height: 540)
        let overlapOffset: CGFloat = 11

        candidate.origin.x += overlapOffset
        candidate.origin.y += overlapOffset

        if candidate.origin.x + candidate.width > screenFrame.maxX {
            candidate.origin.x = screenFrame.maxX - candidate.width
        }
        if candidate.origin.y + candidate.height > screenFrame.maxY {
            candidate.origin.y = screenFrame.maxY - candidate.height
        }
        if candidate.origin.x < screenFrame.origin.x {
            candidate.origin.x = screenFrame.origin.x
        }
        if candidate.origin.y < screenFrame.origin.y {
            candidate.origin.y = screenFrame.origin.y
        }

        XCTAssertLessThanOrEqual(candidate.origin.x + candidate.width, screenFrame.maxX)
        XCTAssertLessThanOrEqual(candidate.origin.y + candidate.height, screenFrame.maxY)
        XCTAssertGreaterThanOrEqual(candidate.origin.x, screenFrame.origin.x)
        XCTAssertGreaterThanOrEqual(candidate.origin.y, screenFrame.origin.y)
        XCTAssertEqual(candidate.origin.x, -1372 + 11, accuracy: 0.001)
        XCTAssertEqual(candidate.origin.y, 1510 + 11, accuracy: 0.001)
    }
}

final class WindowDragGeometryTests: XCTestCase {
    private let initial = CGRect(x: -1983, y: -964, width: 1920, height: 1016)

    func testDetectsMovementWhileAccessibilityStillReportsTheInitialFrame() throws {
        let moved = initial.offsetBy(dx: 0, dy: 2)
        var accessibilityReads = 0
        let geometry = try XCTUnwrap(WindowDragGeometry(initialFrame: initial, initialServerFrame: initial,
                                                        serverFrame: moved, accessibilityFrame: {
            accessibilityReads += 1
            return self.initial
        }))
        XCTAssertTrue(geometry.isMoving)
        XCTAssertTrue(geometry.movedWithoutResizing)
        XCTAssertEqual(geometry.currentFrame, moved)
        XCTAssertEqual(accessibilityReads, 0)
    }

    func testDifferentCoordinateSourcesDoNotCreateFalseMovement() throws {
        let accessibility = initial.offsetBy(dx: 1, dy: 1)
        let geometry = try XCTUnwrap(WindowDragGeometry(initialFrame: accessibility, initialServerFrame: initial,
                                                        serverFrame: initial, accessibilityFrame: { accessibility }))
        XCTAssertFalse(geometry.isMoving)
        XCTAssertFalse(geometry.isResizing)
    }

    func testUnavailableServerFrameFallsBackToAccessibilityBaseline() throws {
        let accessibility = initial.offsetBy(dx: 1, dy: 1)
        for unavailable in [nil, CGRect.null, CGRect.zero] as [CGRect?] {
            let geometry = try XCTUnwrap(WindowDragGeometry(initialFrame: accessibility, initialServerFrame: initial,
                                                            serverFrame: unavailable, accessibilityFrame: { accessibility }))
            XCTAssertFalse(geometry.isMoving)
            XCTAssertEqual(geometry.currentFrame, accessibility)
        }
    }

    func testServerFrameWithoutServerBaselineUsesAccessibility() throws {
        let geometry = try XCTUnwrap(WindowDragGeometry(initialFrame: initial, initialServerFrame: nil,
                                                        serverFrame: initial.offsetBy(dx: 20, dy: 20),
                                                        accessibilityFrame: { self.initial }))
        XCTAssertFalse(geometry.isMoving)
    }

    func testResizingFromEitherCornerDoesNotTriggerRestore() throws {
        let frames = [CGRect(x: initial.minX, y: initial.minY, width: 1800, height: 900),
                      CGRect(x: initial.minX + 120, y: initial.minY + 100, width: 1800, height: 916)]
        for frame in frames {
            let geometry = try XCTUnwrap(WindowDragGeometry(initialFrame: initial, initialServerFrame: initial,
                                                            serverFrame: frame, accessibilityFrame: { nil }))
            XCTAssertTrue(geometry.isResizing)
            XCTAssertFalse(geometry.isMoving)
            XCTAssertFalse(geometry.movedWithoutResizing)
        }
    }

    func testMovingAndChangingSizeAcrossDisplaysStillCountsAsMovement() throws {
        let geometry = try XCTUnwrap(WindowDragGeometry(initialFrame: initial, initialServerFrame: initial,
                                                        serverFrame: CGRect(x: 20, y: 30, width: 1400, height: 800),
                                                        accessibilityFrame: { nil }))
        XCTAssertTrue(geometry.isMoving)
        XCTAssertFalse(geometry.movedWithoutResizing)
    }

    func testMissingGeometryDoesNotCreateADrag() {
        XCTAssertNil(WindowDragGeometry(initialFrame: initial, initialServerFrame: nil,
                                        serverFrame: nil, accessibilityFrame: { nil }))
        XCTAssertNil(WindowDragGeometry(initialFrame: initial, initialServerFrame: nil,
                                        serverFrame: nil, accessibilityFrame: { .null }))
    }
}

final class DragRestorePlacementTests: XCTestCase {
    private let current = CGRect(x: -1983, y: -950, width: 1920, height: 1016)
    private let size = CGSize(width: 1100, height: 650)

    func testDisplayedFrameUsesTheOriginalGrabOffsetInsteadOfANewerMouseSample() {
        let initial = CGRect(x: -1983, y: -964, width: 1920, height: 1016)
        let displayed = initial.offsetBy(dx: 0, dy: 38)
        let reference = DragRestorePlacement.referenceCursor(current: displayed, initial: initial,
                                                              mouseDown: CGPoint(x: -255, y: -934),
                                                              fallback: CGPoint(x: -255, y: -858))
        XCTAssertEqual(reference, CGPoint(x: -255, y: -896))
        XCTAssertEqual(reference.y - displayed.minY, 30)
    }

    func testMissingMouseDownUsesTheAvailableCursorSample() {
        let cursor = CGPoint(x: -561, y: -920)
        XCTAssertEqual(DragRestorePlacement.referenceCursor(current: current, initial: current,
                                                            mouseDown: nil, fallback: cursor), cursor)
    }

    func testLeftGrabKeepsNativePosition() {
        let restored = DragRestorePlacement.frame(from: current, size: size, cursor: CGPoint(x: -1600, y: -920))
        XCTAssertEqual(restored.origin, current.origin)
        XCTAssertEqual(restored.size, size)
    }

    func testRightGrabMovesOnlyEnoughToKeepThePointerInside() {
        let cursor = CGPoint(x: -561, y: -920)
        let restored = DragRestorePlacement.frame(from: current, size: size, cursor: cursor)
        XCTAssertEqual(restored.minX, -1629)
        XCTAssertEqual(restored.maxX - cursor.x, 32)
        XCTAssertTrue(restored.contains(cursor))
        XCTAssertLessThan(restored.maxX, current.maxX)
    }

    func testNearbyGrabPointsDoNotSwitchToTheFarRightEdge() {
        let cutoff = current.minX + size.width - 32
        let left = DragRestorePlacement.frame(from: current, size: size, cursor: CGPoint(x: cutoff - 1, y: -920))
        let right = DragRestorePlacement.frame(from: current, size: size, cursor: CGPoint(x: cutoff + 1, y: -920))
        XCTAssertEqual(left.minX, current.minX)
        XCTAssertEqual(right.minX - left.minX, 1)
    }

    func testGrabAtTheFarRightDoesNotPushPastTheOriginalEdge() {
        let restored = DragRestorePlacement.frame(from: current, size: size,
                                                  cursor: CGPoint(x: current.maxX - 1, y: -920))
        XCTAssertEqual(restored.maxX, current.maxX)
    }

    func testGrowingFromAHalfScreenDoesNotReposition() {
        let half = CGRect(x: 400, y: 100, width: 800, height: 900)
        let restored = DragRestorePlacement.frame(from: half, size: size, cursor: CGPoint(x: 1190, y: 130))
        XCTAssertEqual(restored.origin, half.origin)
    }

    func testPlacementIsTheSameRelativeToEitherDisplay() {
        let cursor = CGPoint(x: -561, y: -920)
        let external = DragRestorePlacement.frame(from: current, size: size, cursor: cursor)
        let local = DragRestorePlacement.frame(from: current.offsetBy(dx: 2000, dy: 1000), size: size,
                                               cursor: CGPoint(x: cursor.x + 2000, y: cursor.y + 1000))
        XCTAssertEqual(local, external.offsetBy(dx: 2000, dy: 1000))
        XCTAssertEqual(DragRestorePlacement.frame(from: current, size: size, cursor: nil).origin, current.origin)
    }
}

final class DragRestoreReleaseTests: XCTestCase {
    private final class WindowElement: AccessibilityElement {
        var currentFrame = CGRect(x: 120, y: 120, width: 800, height: 600)
        var writes: [CGRect] = []
        override var frame: CGRect { currentFrame }
        override func beginAnimatedAdjustment() -> () -> Void { {} }
        override func setAnimationFrame(_ frame: CGRect, resizeOnly: Bool = false) -> Bool { true }
        override func setFrame(_ frame: CGRect, adjustSizeFirst: Bool = true, adjustPosition: Bool = true) {
            currentFrame.size = frame.size
            if adjustPosition { currentFrame.origin = frame.origin }
            writes.append(currentFrame)
        }
    }

    private final class Manager: SnappingManager {
        var restores = 0
        override func unsnapRestore(windowId: CGWindowID, currentRect: CGRect, cursorLoc: CGPoint?) {
            restores += 1
        }
        override func snapAreaContainingCursor(priorSnapArea: SnapArea?, at loc: CGPoint) -> SnapArea? { nil }
    }

    private func release(dragAlreadyDetected: Bool) throws -> Manager {
        let saved = Defaults.windowSnapping.enabled
        Defaults.windowSnapping.enabled = false
        defer { Defaults.windowSnapping.enabled = saved }
        let manager = Manager()
        manager.windowElement = WindowElement(AXUIElementCreateSystemWide())
        manager.windowId = .max
        manager.initialWindowRect = CGRect(x: 100, y: 100, width: 800, height: 600)
        manager.windowMoving = dragAlreadyDetected
        let event = try XCTUnwrap(NSEvent.mouseEvent(with: .leftMouseUp, location: .zero, modifierFlags: [],
                                                   timestamp: 1, windowNumber: 0, context: nil,
                                                   eventNumber: 1, clickCount: 1, pressure: 0))
        manager.handle(event: event)
        return manager
    }

    func testMouseUpDoesNotRestoreAgainWhenDisplayedSizeHasNotCaughtUp() throws {
        let manager = try release(dragAlreadyDetected: true)
        XCTAssertEqual(manager.restores, 0)
        XCTAssertFalse(manager.windowMoving)
        XCTAssertNil(manager.windowId)
        XCTAssertNil(manager.windowElement)
    }

    func testMouseUpStillRestoresAQuickDragThatHadNotBeenDetected() throws {
        let manager = try release(dragAlreadyDetected: false)
        XCTAssertEqual(manager.restores, 1)
        XCTAssertFalse(manager.windowMoving)
        XCTAssertNil(manager.initialWindowRect)
    }

    func testDirectAnimationWithoutServerIdentityCompletesOnceAndMouseUpDoesNotRepeatIt() throws {
        let saved = Defaults.experimentalWindowAnimations.enabled
        Defaults.experimentalWindowAnimations.enabled = true
        defer {
            WindowAnimator.shared.finish()
            Defaults.experimentalWindowAnimations.enabled = saved
        }
        try XCTSkipUnless(WindowAnimator.enabled, "Window animations are disabled by accessibility settings")
        let window = WindowElement(AXUIElementCreateSystemWide())
        XCTAssertNil(window.windowId, "Direct animation does not require a WindowServer identity")
        let destination = CGRect(x: 300, y: 120, width: 500, height: 400)
        var completedFrames: [CGRect] = []
        WindowAnimator.shared.animate(window, to: destination, duration: 0.18) { completedFrames.append($0) }

        XCTAssertTrue(completedFrames.isEmpty)
        XCTAssertEqual(WindowAnimator.shared.destination(for: window), destination)
        WindowAnimator.shared.finish()
        XCTAssertEqual(completedFrames, [destination])
        XCTAssertNil(WindowAnimator.shared.destination(for: window))

        let manager = try release(dragAlreadyDetected: true)

        XCTAssertEqual(completedFrames, [destination], "A later native release must not repeat the completed animation")
        XCTAssertEqual(manager.restores, 0)
        XCTAssertNil(WindowAnimator.shared.destination(for: window))
    }
}

class SnappingManagerSessionTests: XCTestCase {

    func testSpaceDisplayAndSessionChangesClearThePreviousDragTarget() throws {
        let screen = try XCTUnwrap(NSScreen.screens.first)
        for name in [NSWorkspace.activeSpaceDidChangeNotification, NSApplication.didChangeScreenParametersNotification,
                     NSWorkspace.willSleepNotification, NSWorkspace.sessionDidResignActiveNotification] {
            let manager = SnappingManager()
            manager.beginNativeDrag()
            manager.windowElement = AccessibilityElement(AXUIElementCreateSystemWide())
            manager.windowId = 42
            manager.initialWindowRect = CGRect(x: 100, y: 100, width: 300, height: 200)
            manager.windowMoving = true
            manager.windowIdAttempt = 4
            manager.currentSnapArea = SnapArea(screen: screen, directional: .l, action: .leftHalf)
            if name == NSApplication.didChangeScreenParametersNotification {
                NotificationCenter.default.post(name: name, object: nil)
            } else {
                // Exercise the handler without changing other managers' live
                // shared session state in this app-hosted test process.
                if name == NSWorkspace.activeSpaceDidChangeNotification { manager.receiveWorkspaceNote(Notification(name: name)) }
                else { manager.receiveSessionNote(Notification(name: name)) }
            }
            XCTAssertNil(manager.currentSnapArea)
            XCTAssertNil(manager.windowElement)
            XCTAssertNil(manager.windowId)
            XCTAssertNil(manager.initialWindowRect)
            XCTAssertFalse(manager.windowMoving)
            XCTAssertEqual(manager.windowIdAttempt, 0)
        }
    }

    private var savedSnappingEnabled: Bool?

    override func setUp() {
        super.setUp()
        savedSnappingEnabled = Defaults.windowSnapping.enabled
        Defaults.windowSnapping.enabled = false
    }

    override func tearDown() {
        super.tearDown()
        Defaults.windowSnapping.enabled = savedSnappingEnabled
    }

    func testSessionDidBecomeActiveTriggersCheckFullScreen() {
        let sm = SnappingManager()
        sm.isFullScreen = true

        NSWorkspace.shared.notificationCenter.post(
            name: NSWorkspace.sessionDidBecomeActiveNotification,
            object: nil
        )

        XCTAssertFalse(sm.isFullScreen,
            "receiveSessionNote should call checkFullScreen, re-evaluating isFullScreen")
    }

    func testSessionDidBecomeActiveEventMonitorPreserved() {
        Defaults.windowSnapping.enabled = true
        let sm = SnappingManager()
        let wasRunning = sm.eventMonitor?.running ?? false

        NSWorkspace.shared.notificationCenter.post(
            name: NSWorkspace.sessionDidBecomeActiveNotification,
            object: nil
        )

        let isRunning = sm.eventMonitor?.running ?? false
        XCTAssertEqual(isRunning, wasRunning,
            "toggleListening should be called but preserve event monitor state")
    }

    func testSessionDidBecomeActiveDoesNotEnableSnapping() {
        let sm = SnappingManager()

        NSWorkspace.shared.notificationCenter.post(
            name: NSWorkspace.sessionDidBecomeActiveNotification,
            object: nil
        )

        XCTAssertNil(sm.eventMonitor,
            "snapping should remain disabled after session became active notification")
    }

    func testSessionDidBecomeActiveMultiplePostsNoCrash() {
        let sm = SnappingManager()

        for _ in 0..<5 {
            NSWorkspace.shared.notificationCenter.post(
                name: NSWorkspace.sessionDidBecomeActiveNotification,
                object: nil
            )
        }

        XCTAssertFalse(sm.isFullScreen)
    }

    func testSleepWakeMaintainsSnapping() {
        Defaults.windowSnapping.enabled = true
        let sm = SnappingManager()
        let wasRunning = sm.eventMonitor?.running ?? false

        NSWorkspace.shared.notificationCenter.post(
            name: NSWorkspace.activeSpaceDidChangeNotification,
            object: nil
        )

        let isRunning = sm.eventMonitor?.running ?? false
        XCTAssertEqual(isRunning, wasRunning,
            "activeSpaceDidChange (simulating wake) should preserve event monitor state")
    }

    func testSessionUnlockThenWakeMaintainsSnapping() {
        Defaults.windowSnapping.enabled = true
        let sm = SnappingManager()
        let wasRunning = sm.eventMonitor?.running ?? false

        NSWorkspace.shared.notificationCenter.post(
            name: NSWorkspace.sessionDidBecomeActiveNotification,
            object: nil
        )

        NSWorkspace.shared.notificationCenter.post(
            name: NSWorkspace.activeSpaceDidChangeNotification,
            object: nil
        )

        let isRunning = sm.eventMonitor?.running ?? false
        XCTAssertEqual(isRunning, wasRunning,
            "session unlock followed by wake should restore event monitor state")
    }

    func testSessionUnlockWithDisabledSnapping() {
        let sm = SnappingManager()

        NSWorkspace.shared.notificationCenter.post(
            name: NSWorkspace.sessionDidBecomeActiveNotification,
            object: nil
        )

        NSWorkspace.shared.notificationCenter.post(
            name: NSWorkspace.activeSpaceDidChangeNotification,
            object: nil
        )

        XCTAssertNil(sm.eventMonitor,
            "session unlock -> wake should not enable snapping when disabled")
    }

    func testFullScreenThenWakeThenLeaveFullScreen() {
        Defaults.windowSnapping.enabled = true
        let sm = SnappingManager()
        let wasRunning = sm.eventMonitor?.running ?? false

        NSWorkspace.shared.notificationCenter.post(
            name: NSWorkspace.sessionDidBecomeActiveNotification,
            object: nil
        )

        let isRunning = sm.eventMonitor?.running ?? false
        XCTAssertEqual(isRunning, wasRunning,
            "session restore after full screen should preserve event monitor state")
    }

    func testSessionResignActiveDoesNotCrash() {
        let sm = SnappingManager()

        NSWorkspace.shared.notificationCenter.post(
            name: NSWorkspace.sessionDidResignActiveNotification,
            object: nil
        )

        XCTAssertFalse(sm.isFullScreen)
    }

    func testSessionResignActiveThenBecomeActive() {
        Defaults.windowSnapping.enabled = true
        let sm = SnappingManager()
        let wasRunning = sm.eventMonitor?.running ?? false

        NSWorkspace.shared.notificationCenter.post(
            name: NSWorkspace.sessionDidResignActiveNotification,
            object: nil
        )

        NSWorkspace.shared.notificationCenter.post(
            name: NSWorkspace.sessionDidBecomeActiveNotification,
            object: nil
        )

        let isRunning = sm.eventMonitor?.running ?? false
        XCTAssertEqual(isRunning, wasRunning,
            "session resign then become active should preserve event monitor state")
    }

    func testScreensDoNotSleepNotificationsBreakSnapping() {
        Defaults.windowSnapping.enabled = true
        let sm = SnappingManager()
        let wasRunning = sm.eventMonitor?.running ?? false

        NSWorkspace.shared.notificationCenter.post(
            name: NSWorkspace.screensDidSleepNotification,
            object: nil
        )

        NSWorkspace.shared.notificationCenter.post(
            name: NSWorkspace.activeSpaceDidChangeNotification,
            object: nil
        )

        let isRunning = sm.eventMonitor?.running ?? false
        XCTAssertEqual(isRunning, wasRunning,
            "screen sleep then wake should preserve event monitor state")
    }

    func testScreenSleepSessionResignThenWakeAndSessionActive() {
        Defaults.windowSnapping.enabled = true
        let sm = SnappingManager()
        let wasRunning = sm.eventMonitor?.running ?? false

        NSWorkspace.shared.notificationCenter.post(
            name: NSWorkspace.screensDidSleepNotification,
            object: nil
        )

        NSWorkspace.shared.notificationCenter.post(
            name: NSWorkspace.sessionDidResignActiveNotification,
            object: nil
        )

        NSWorkspace.shared.notificationCenter.post(
            name: NSWorkspace.sessionDidBecomeActiveNotification,
            object: nil
        )

        NSWorkspace.shared.notificationCenter.post(
            name: NSWorkspace.activeSpaceDidChangeNotification,
            object: nil
        )

        let isRunning = sm.eventMonitor?.running ?? false
        XCTAssertEqual(isRunning, wasRunning,
            "screen sleep + session resign -> session active + wake should restore event monitor state")
    }
}

class SnappingManagerUnsnapRestoreTests: XCTestCase {

    private let windowId = CGWindowID(918_273)
    private var savedSnappingEnabled: Bool?
    private var savedUnsnapRestore: Bool?
    private var savedUnsnapRestoreFromSizeChange: Bool?
    private var savedRestoreRects = [CGWindowID: CGRect]()
    private var savedActions = [CGWindowID: RectangleAction]()

    override func setUp() {
        super.setUp()
        savedSnappingEnabled = Defaults.windowSnapping.enabled
        savedUnsnapRestore = Defaults.unsnapRestore.enabled
        savedUnsnapRestoreFromSizeChange = Defaults.unsnapRestoreFromSizeChange.enabled
        savedRestoreRects = AppDelegate.windowHistory.restoreRects
        savedActions = AppDelegate.windowHistory.lastRectangleActions
        Defaults.windowSnapping.enabled = false
        Defaults.unsnapRestore.enabled = true
        AppDelegate.windowHistory.restoreRects.removeValue(forKey: windowId)
        AppDelegate.windowHistory.lastRectangleActions.removeValue(forKey: windowId)
    }

    override func tearDown() {
        Defaults.windowSnapping.enabled = savedSnappingEnabled
        Defaults.unsnapRestore.enabled = savedUnsnapRestore
        Defaults.unsnapRestoreFromSizeChange.enabled = savedUnsnapRestoreFromSizeChange
        AppDelegate.windowHistory.restoreRects = savedRestoreRects
        AppDelegate.windowHistory.lastRectangleActions = savedActions
        super.tearDown()
    }

    func testSuppressedSizeChangeRestoreKeepsTheUserPositionedRect() {
        Defaults.unsnapRestoreFromSizeChange.enabled = false
        let userRect = CGRect(x: 164, y: 73, width: 1414, height: 861)
        let smallerRect = CGRect(x: 179, y: 88, width: 1354, height: 801)
        AppDelegate.windowHistory.restoreRects[windowId] = userRect
        AppDelegate.windowHistory.lastRectangleActions[windowId] = RectangleAction(action: .smaller,
                                                                                   subAction: nil,
                                                                                   rect: smallerRect,
                                                                                   count: 2)
        let snappingManager = SnappingManager()
        snappingManager.initialWindowRect = smallerRect

        snappingManager.unsnapRestore(windowId: windowId,
                                      currentRect: smallerRect.offsetBy(dx: 40, dy: 0),
                                      cursorLoc: nil)

        XCTAssertEqual(AppDelegate.windowHistory.restoreRects[windowId], userRect)
    }

    func testDraggingAWindowRectangleDidNotPlaceRecordsTheRestoreRect() {
        let draggedFrom = CGRect(x: 100, y: 100, width: 800, height: 600)
        let snappingManager = SnappingManager()
        snappingManager.initialWindowRect = draggedFrom

        snappingManager.unsnapRestore(windowId: windowId,
                                      currentRect: draggedFrom.offsetBy(dx: 40, dy: 0),
                                      cursorLoc: nil)

        XCTAssertEqual(AppDelegate.windowHistory.restoreRects[windowId], draggedFrom)
    }
}

class ShortcutManagerSessionTests: XCTestCase {

    private final class ValueBox<Value> {
        var value: Value

        init(_ value: Value) {
            self.value = value
        }
    }

    private final class SpaceActionSpy: SpaceActionExecuting {
        let handledActions: Set<WindowAction>
        private(set) var actions = [WindowAction]()

        init(handledActions: Set<WindowAction> = [.nextSpace, .prevSpace]) {
            self.handledActions = handledActions
        }

        func execute(parameters: ExecutionParameters) -> Bool {
            actions.append(parameters.action)
            return handledActions.contains(parameters.action)
        }
    }

    private final class BindingStoreSpy: ShortcutBindingStore {
        private(set) var configureCallCount = 0
        private(set) var registeredDefaultKeys = Set<String>()
        private(set) var boundKeys = Set<String>()
        private(set) var bindCallCount = 0
        private(set) var breakBindingCallCount = 0

        func configure() {
            configureCallCount += 1
        }

        func registerDefaultShortcuts(_ shortcuts: [String: MASShortcut]) {
            registeredDefaultKeys.formUnion(shortcuts.keys)
        }

        func bindShortcut(withDefaultsKey defaultsKey: String, toAction action: @escaping () -> Void) {
            bindCallCount += 1
            boundKeys.insert(defaultsKey)
        }

        func breakBinding(withDefaultsKey defaultsKey: String) {
            breakBindingCallCount += 1
            boundKeys.remove(defaultsKey)
        }
    }

    private final class SchedulerSpy {
        private var scheduledActions = [() -> Void]()

        var pendingCount: Int {
            scheduledActions.count
        }

        func schedule(_ action: @escaping () -> Void) {
            scheduledActions.append(action)
        }

        func runNext() {
            guard !scheduledActions.isEmpty else {
                XCTFail("Expected a scheduled shortcut rebind")
                return
            }
            scheduledActions.removeFirst()()
        }
    }

    private struct Harness {
        let manager: ShortcutManager
        let bindingStore: BindingStoreSpy
        let notificationCenter: NotificationCenter
        let workspaceNotificationCenter: NotificationCenter
        let shortcuts: ValueBox<[WindowAction: MASShortcut]>
        let appDisabled: ValueBox<Bool>
        let scheduler: SchedulerSpy
        let todoSessionStates: ValueBox<[Bool]>
    }

    private func shortcut(_ keyCode: Int) -> MASShortcut {
        MASShortcut(keyCode: keyCode, modifierFlags: [.command, .option])
    }

    private func makeHarness(
        initiallyActive: Bool = true,
        appDisabled: Bool = false,
        shortcuts: [WindowAction: MASShortcut]? = nil,
        spaceManager: SpaceActionExecuting = SpaceManager(),
        spaceSwitcher: SpaceActionExecuting = SpaceSwitchManager()
    ) -> Harness {
        let bindingStore = BindingStoreSpy()
        let notificationCenter = NotificationCenter()
        let workspaceNotificationCenter = NotificationCenter()
        let shortcuts = ValueBox(shortcuts ?? [.leftHalf: shortcut(1)])
        let appDisabled = ValueBox(appDisabled)
        let scheduler = SchedulerSpy()
        let todoSessionStates = ValueBox<[Bool]>([])
        let manager = ShortcutManager(
            windowManager: WindowManager(),
            spaceManager: spaceManager,
            spaceSwitcher: spaceSwitcher,
            bindingStore: bindingStore,
            notificationCenter: notificationCenter,
            workspaceNotificationCenter: workspaceNotificationCenter,
            shortcutsProvider: { shortcuts.value },
            activeStateProvider: { initiallyActive },
            appDisabledProvider: { appDisabled.value },
            scheduler: { scheduler.schedule($0) },
            todoSessionStateChanged: { todoSessionStates.value.append($0) }
        )

        return Harness(
            manager: manager,
            bindingStore: bindingStore,
            notificationCenter: notificationCenter,
            workspaceNotificationCenter: workspaceNotificationCenter,
            shortcuts: shortcuts,
            appDisabled: appDisabled,
            scheduler: scheduler,
            todoSessionStates: todoSessionStates
        )
    }

    private func resignSession(_ harness: Harness) {
        harness.workspaceNotificationCenter.post(
            name: NSWorkspace.sessionDidResignActiveNotification,
            object: nil
        )
    }

    private func activateSession(_ harness: Harness) {
        harness.workspaceNotificationCenter.post(
            name: NSWorkspace.sessionDidBecomeActiveNotification,
            object: nil
        )
    }

    func testSpaceCommandsRegisterAsGlobalHotkeys() {
        let harness = makeHarness(shortcuts: [
            .nextSpace: shortcut(91),
            .prevSpace: shortcut(92),
            .switchNextSpace: shortcut(93),
            .switchPrevSpace: shortcut(94)
        ])

        XCTAssertEqual(harness.bindingStore.boundKeys, [
            WindowAction.nextSpace.name,
            WindowAction.prevSpace.name,
            WindowAction.switchNextSpace.name,
            WindowAction.switchPrevSpace.name
        ])
    }

    func testSpaceCommandNotificationRoutesToSpaceManager() {
        let spaceManager = SpaceActionSpy()
        let harness = makeHarness(shortcuts: [.nextSpace: shortcut(91)], spaceManager: spaceManager)

        harness.notificationCenter.post(
            name: WindowAction.nextSpace.notificationName,
            object: ExecutionParameters(.nextSpace)
        )

        XCTAssertEqual(spaceManager.actions, [.nextSpace])
    }

    func testDisplaySpaceCommandRoutesToSpaceSwitcher() {
        let spaceManager = SpaceActionSpy()
        let spaceSwitcher = SpaceActionSpy(handledActions: [.switchNextSpace, .switchPrevSpace])
        let harness = makeHarness(
            shortcuts: [.switchNextSpace: shortcut(93)],
            spaceManager: spaceManager,
            spaceSwitcher: spaceSwitcher
        )

        harness.notificationCenter.post(
            name: WindowAction.switchNextSpace.notificationName,
            object: ExecutionParameters(.switchNextSpace)
        )

        XCTAssertTrue(spaceManager.actions.isEmpty)
        XCTAssertEqual(spaceSwitcher.actions, [.switchNextSpace])
    }

    func testRepeatInputPolicyTracksStandaloneBindingsAndSessionSuspension() {
        let repeated = shortcut(124)
        let shared = shortcut(123)
        let harness = makeHarness(shortcuts: [.switchNextSpace: repeated, .switchPrevSpace: shared,
                                             .leftHalf: shared, .nextSpace: shortcut(125),
                                             .switchSpaceOne: shortcut(18)])
        let expected: Set<SpaceSwitchShortcutPolicy.Shortcut> = [
            .init(keyCode: 124, modifiers: [.command, .option]),
            .init(keyCode: 18, modifiers: [.command, .option])
        ]
        // Cycles and window-move shortcuts continue to interrupt a switch.
        XCTAssertEqual(SpaceSwitchShortcutPolicy.shared.shortcuts, expected)
        resignSession(harness)
        XCTAssertTrue(SpaceSwitchShortcutPolicy.shared.shortcuts.isEmpty)
        activateSession(harness)
        XCTAssertTrue(SpaceSwitchShortcutPolicy.shared.shortcuts.isEmpty)
        harness.scheduler.runNext()
        XCTAssertEqual(SpaceSwitchShortcutPolicy.shared.shortcuts, expected)
        harness.manager.unbindShortcuts()
        XCTAssertTrue(SpaceSwitchShortcutPolicy.shared.shortcuts.isEmpty)
    }

    func testNumberedSpaceCommandRoutesWithoutObtainingOrMovingAWindow() {
        let moves = SpaceActionSpy()
        let numbered = SpaceActionSpy(handledActions: Set(WindowAction.numberedSpaceSwitches))
        let harness = makeHarness(shortcuts: [.switchSpaceOne: shortcut(18)], spaceManager: moves,
                                  spaceSwitcher: numbered)
        harness.notificationCenter.post(name: WindowAction.switchSpaceOne.notificationName,
                                        object: ExecutionParameters(.switchSpaceOne))
        XCTAssertEqual(numbered.actions, [.switchSpaceOne])
        XCTAssertTrue(moves.actions.isEmpty)
        XCTAssertTrue(harness.bindingStore.boundKeys.contains(WindowAction.switchSpaceOne.name))
    }

    func testNumberedMoveCommandsBindAndRouteToTheWindowMoveManager() {
        let moves = SpaceActionSpy(handledActions: Set(WindowAction.numberedSpaceMoves))
        let numbered = SpaceActionSpy(handledActions: Set(WindowAction.numberedSpaceSwitches))
        let shortcuts = Dictionary(uniqueKeysWithValues: WindowAction.numberedSpaceMoves.enumerated().map {
            ($0.element, shortcut(18 + $0.offset))
        })
        let harness = makeHarness(shortcuts: shortcuts, spaceManager: moves,
                                  spaceSwitcher: numbered)
        for action in WindowAction.numberedSpaceMoves {
            harness.notificationCenter.post(name: action.notificationName, object: ExecutionParameters(action))
        }
        XCTAssertEqual(moves.actions, WindowAction.numberedSpaceMoves)
        XCTAssertEqual(numbered.actions, WindowAction.numberedSpaceMoves)
        XCTAssertEqual(harness.bindingStore.boundKeys, Set(WindowAction.numberedSpaceMoves.map(\.name)))
    }

    func testActiveSessionResignThenDelayedActivationRestoresBindings() {
        let harness = makeHarness()
        let expectedKeys: Set<String> = [WindowAction.leftHalf.name]

        XCTAssertEqual(harness.bindingStore.boundKeys, expectedKeys)
        XCTAssertEqual(harness.todoSessionStates.value, [true])

        resignSession(harness)

        XCTAssertTrue(harness.bindingStore.boundKeys.isEmpty)
        XCTAssertEqual(harness.scheduler.pendingCount, 0)
        XCTAssertEqual(harness.todoSessionStates.value, [true, false])

        activateSession(harness)

        XCTAssertTrue(harness.bindingStore.boundKeys.isEmpty)
        XCTAssertEqual(harness.scheduler.pendingCount, 1)
        XCTAssertEqual(harness.todoSessionStates.value, [true, false])

        harness.scheduler.runNext()

        XCTAssertEqual(harness.bindingStore.boundKeys, expectedKeys)
        XCTAssertEqual(harness.scheduler.pendingCount, 0)
        XCTAssertEqual(harness.todoSessionStates.value, [true, false, true])
    }

    func testDuplicateSessionNotificationsAreIdempotent() {
        let harness = makeHarness()

        resignSession(harness)
        let breakCallsAfterFirstResign = harness.bindingStore.breakBindingCallCount

        resignSession(harness)

        XCTAssertEqual(harness.bindingStore.breakBindingCallCount, breakCallsAfterFirstResign)

        activateSession(harness)
        activateSession(harness)

        XCTAssertEqual(harness.scheduler.pendingCount, 1)

        harness.scheduler.runNext()
        let bindCallsAfterActivation = harness.bindingStore.bindCallCount

        activateSession(harness)

        XCTAssertEqual(harness.scheduler.pendingCount, 0)
        XCTAssertEqual(harness.bindingStore.bindCallCount, bindCallsAfterActivation)
        XCTAssertEqual(harness.bindingStore.boundKeys, [WindowAction.leftHalf.name])
    }

    func testActivationRestoresCurrentLogicalShortcutsAfterTheyChangeWhileInactive() {
        let harness = makeHarness()

        resignSession(harness)
        harness.shortcuts.value = [.rightHalf: shortcut(2)]

        activateSession(harness)
        harness.scheduler.runNext()

        XCTAssertEqual(harness.bindingStore.boundKeys, [WindowAction.rightHalf.name])
        XCTAssertFalse(harness.bindingStore.boundKeys.contains(WindowAction.leftHalf.name))
    }

    func testDisabledApplicationBlocksSessionRestore() {
        let harness = makeHarness()

        resignSession(harness)
        harness.appDisabled.value = true

        activateSession(harness)
        harness.scheduler.runNext()

        XCTAssertTrue(harness.bindingStore.boundKeys.isEmpty)
    }

    func testRecordingBlocksSessionRestoreUntilRecordingEnds() throws {
        let binder = try XCTUnwrap(MASShortcutBinder.shared())
        let previousBindingOptions = binder.bindingOptions
        binder.bindingOptions = [NSBindingOption.valueTransformerName: MASDictionaryTransformerName]
        defer {
            TodoManager.setShortcutBindingsSuspended(false)
            binder.bindingOptions = previousBindingOptions
        }

        let harness = makeHarness()

        harness.notificationCenter.post(name: .shortcutRecording, object: true)
        XCTAssertTrue(harness.bindingStore.boundKeys.isEmpty)

        resignSession(harness)
        activateSession(harness)
        harness.scheduler.runNext()

        XCTAssertTrue(harness.bindingStore.boundKeys.isEmpty)

        harness.notificationCenter.post(name: .shortcutRecording, object: false)

        XCTAssertEqual(harness.bindingStore.boundKeys, [WindowAction.leftHalf.name])
    }

    func testInitiallyInactiveSessionDoesNotBindUntilActivationCompletes() {
        let harness = makeHarness(initiallyActive: false)

        XCTAssertTrue(harness.bindingStore.boundKeys.isEmpty)
        XCTAssertEqual(harness.scheduler.pendingCount, 0)
        XCTAssertEqual(harness.todoSessionStates.value, [false])

        activateSession(harness)

        XCTAssertTrue(harness.bindingStore.boundKeys.isEmpty)
        XCTAssertEqual(harness.scheduler.pendingCount, 1)
        XCTAssertEqual(harness.todoSessionStates.value, [false])

        harness.scheduler.runNext()

        XCTAssertEqual(harness.bindingStore.boundKeys, [WindowAction.leftHalf.name])
        XCTAssertEqual(harness.todoSessionStates.value, [false, true])
    }

    func testResignBeforeQueuedActivationCompletesCancelsRestore() {
        let harness = makeHarness()

        resignSession(harness)
        activateSession(harness)
        XCTAssertEqual(harness.scheduler.pendingCount, 1)

        resignSession(harness)
        harness.scheduler.runNext()

        XCTAssertTrue(harness.bindingStore.boundKeys.isEmpty)
        XCTAssertEqual(harness.scheduler.pendingCount, 0)
        XCTAssertEqual(harness.todoSessionStates.value, [true, false, false])
    }
}

class ShortcutCycleTests: XCTestCase {

    private func shortcut(_ keyCode: Int, _ flags: NSEvent.ModifierFlags) -> MASShortcut {
        MASShortcut(keyCode: keyCode, modifierFlags: flags)
    }

    func testSideShortcutActionsKeepLegacyDefaultsKeys() {
        XCTAssertEqual(WindowAction.leftHalf.name, "leftHalf")
        XCTAssertEqual(WindowAction.rightHalf.name, "rightHalf")
        XCTAssertEqual(WindowAction.centerHalf.name, "centerHalf")
        XCTAssertEqual(WindowAction.topHalf.name, "topHalf")
        XCTAssertEqual(WindowAction.bottomHalf.name, "bottomHalf")
    }

    func testRenamedSideShortcutAliasSyncWritesLegacyDefaultsKey() {
        let suiteName = "ShortcutCycleTests.\(UUID().uuidString)"
        let userDefaults = UserDefaults(suiteName: suiteName)!
        defer {
            userDefaults.removePersistentDomain(forName: suiteName)
        }

        let centerSectionShortcut = shortcut(1, [.option, .command])
        let dictTransformer = ValueTransformer(forName: NSValueTransformerName(rawValue: MASDictionaryTransformerName))!
        let shortcutDict = dictTransformer.reverseTransformedValue(centerSectionShortcut)
        userDefaults.setValue(shortcutDict, forKey: "centerSection")

        MASShortcutMigration.syncRenamedSideShortcutAliases(userDefaults: userDefaults)

        XCTAssertNil(userDefaults.object(forKey: "centerSection"))
        XCTAssertNotNil(userDefaults.object(forKey: "centerHalf"))
        XCTAssertNotNil(ShortcutCycle.shortcut(for: .centerHalf, userDefaults: userDefaults))

        let updatedCenterHalfShortcut = shortcut(2, [.option, .command])
        let updatedShortcutDict = dictTransformer.reverseTransformedValue(updatedCenterHalfShortcut)
        userDefaults.setValue(updatedShortcutDict, forKey: "centerHalf")

        MASShortcutMigration.syncRenamedSideShortcutAliases(userDefaults: userDefaults)
        XCTAssertEqual(ShortcutCycle.shortcut(for: .centerHalf, userDefaults: userDefaults)?.keyCode, updatedCenterHalfShortcut.keyCode)
    }

    func testUniqueShortcutsProduceSingletonGroups() {
        let groups = ShortcutCycle.groups(
            actions: [.centerHalf, .centerThird],
            shortcutsByAction: [
                .centerHalf: shortcut(1, [.option, .command]),
                .centerThird: shortcut(2, [.option, .command])
            ]
        )

        XCTAssertEqual(groups.map(\.actions), [[.centerHalf], [.centerThird]])
        XCTAssertFalse(groups.contains { $0.isCycle })
    }

    func testDuplicateShortcutsFollowWindowActionActiveOrder() {
        let groups = ShortcutCycle.groups(
            actions: WindowAction.active,
            shortcutsByAction: [
                .centerHalf: shortcut(1, [.option, .command]),
                .centerThird: shortcut(1, [.option, .command])
            ]
        )

        XCTAssertEqual(groups.count, 1)
        XCTAssertEqual(groups.first?.actions, [.centerHalf, .centerThird])
    }

    func testDuplicateShortcutStartsAtFirstActionWithoutPreviousAction() {
        let group = ShortcutCycle.Group(shortcut: shortcut(1, [.option, .command]), actions: [.centerHalf, .centerThird])

        XCTAssertEqual(group.action(after: nil), .centerHalf)
    }

    func testDuplicateShortcutSelectsNextActionAndWraps() {
        let group = ShortcutCycle.Group(shortcut: shortcut(1, [.option, .command]), actions: [.centerHalf, .centerThird])

        XCTAssertEqual(group.action(after: .centerHalf), .centerThird)
        XCTAssertEqual(group.action(after: .centerThird), .centerHalf)
    }

    func testDuplicateShortcutStartsAtFirstActionWhenPreviousActionIsOutsideGroup() {
        let group = ShortcutCycle.Group(shortcut: shortcut(1, [.option, .command]), actions: [.centerHalf, .centerThird])

        XCTAssertEqual(group.action(after: .maximize), .centerHalf)
    }

    func testStaleWindowHistoryIsIgnoredForCycleSelection() {
        let group = ShortcutCycle.Group(shortcut: shortcut(1, [.option, .command]), actions: [.centerHalf, .centerThird])
        let lastAction = RectangleAction(
            action: .centerHalf,
            subAction: nil,
            rect: CGRect(x: 0, y: 0, width: 500, height: 500),
            count: 1
        )

        let selectedAction = ShortcutCycle.action(
            in: group,
            lastAction: lastAction,
            currentWindowRect: CGRect(x: 20, y: 20, width: 500, height: 500)
        )

        XCTAssertEqual(selectedAction, .centerHalf)
    }

    func testDuplicateShortcutAssignmentsRemainReadableFromUserDefaults() {
        let suiteName = "ShortcutCycleTests.\(UUID().uuidString)"
        let userDefaults = UserDefaults(suiteName: suiteName)!
        defer {
            userDefaults.removePersistentDomain(forName: suiteName)
        }

        let duplicatedShortcut = shortcut(1, [.option, .command])
        let dictTransformer = ValueTransformer(forName: NSValueTransformerName(rawValue: MASDictionaryTransformerName))!
        let shortcutDict = dictTransformer.reverseTransformedValue(duplicatedShortcut)
        userDefaults.setValue(shortcutDict, forKey: WindowAction.centerHalf.name)
        userDefaults.setValue(shortcutDict, forKey: WindowAction.centerThird.name)

        let shortcutsByAction = ShortcutCycle.shortcutsByAction(actions: [.centerHalf, .centerThird], userDefaults: userDefaults)
        let groups = ShortcutCycle.groups(actions: [.centerHalf, .centerThird], shortcutsByAction: shortcutsByAction)

        XCTAssertNotNil(ShortcutCycle.shortcut(for: .centerHalf, userDefaults: userDefaults))
        XCTAssertNotNil(ShortcutCycle.shortcut(for: .centerThird, userDefaults: userDefaults))
        XCTAssertEqual(groups.map(\.actions), [[.centerHalf, .centerThird]])
        XCTAssertEqual(groups.first?.representativeAction, .centerHalf)
    }
}

class TodoShortcutValidatorTests: XCTestCase {

    private func shortcut(_ keyCode: Int, _ flags: NSEvent.ModifierFlags) -> MASShortcut {
        MASShortcut(keyCode: keyCode, modifierFlags: flags)
    }

    private func save(_ shortcut: MASShortcut, forKey key: String, in userDefaults: UserDefaults) {
        let dictTransformer = ValueTransformer(forName: NSValueTransformerName(rawValue: MASDictionaryTransformerName))!
        let shortcutDict = dictTransformer.reverseTransformedValue(shortcut)
        userDefaults.set(shortcutDict, forKey: key)
    }

    private func userDefaultsSuite() -> (String, UserDefaults) {
        let suiteName = "TodoShortcutValidatorTests.\(UUID().uuidString)"
        return (suiteName, UserDefaults(suiteName: suiteName)!)
    }

    func testInvalidatesShortcutUsedByWindowActionWithoutAlreadyTakenError() {
        let (suiteName, userDefaults) = userDefaultsSuite()
        defer {
            userDefaults.removePersistentDomain(forName: suiteName)
        }

        let duplicateShortcut = shortcut(1, [.option, .command])
        save(duplicateShortcut, forKey: WindowAction.centerHalf.name, in: userDefaults)
        let validator = TodoShortcutValidator(defaultsKey: TodoManager.toggleDefaultsKey, userDefaults: userDefaults)
        var explanation: NSString?

        let isTaken = validator.isShortcutAlreadyTaken(bySystem: duplicateShortcut, explanation: &explanation)

        XCTAssertFalse(validator.isShortcutValid(duplicateShortcut))
        XCTAssertFalse(isTaken)
        XCTAssertNil(explanation)
    }

    func testInvalidatesShortcutUsedByOtherTodoActionWithoutAlreadyTakenError() {
        let (suiteName, userDefaults) = userDefaultsSuite()
        defer {
            userDefaults.removePersistentDomain(forName: suiteName)
        }

        let duplicateShortcut = shortcut(1, [.option, .command])
        save(duplicateShortcut, forKey: TodoManager.reflowDefaultsKey, in: userDefaults)
        let validator = TodoShortcutValidator(defaultsKey: TodoManager.toggleDefaultsKey, userDefaults: userDefaults)
        var explanation: NSString?

        let isTaken = validator.isShortcutAlreadyTaken(bySystem: duplicateShortcut, explanation: &explanation)

        XCTAssertFalse(validator.isShortcutValid(duplicateShortcut))
        XCTAssertFalse(isTaken)
        XCTAssertNil(explanation)
    }

    func testAllowsExistingShortcutForSameTodoAction() {
        let (suiteName, userDefaults) = userDefaultsSuite()
        defer {
            userDefaults.removePersistentDomain(forName: suiteName)
        }

        let existingShortcut = shortcut(1, [.option, .command])
        save(existingShortcut, forKey: TodoManager.toggleDefaultsKey, in: userDefaults)
        let validator = TodoShortcutValidator(defaultsKey: TodoManager.toggleDefaultsKey, userDefaults: userDefaults)

        XCTAssertTrue(validator.isShortcutValid(existingShortcut))
        XCTAssertFalse(validator.isShortcutAlreadyTaken(bySystem: existingShortcut, explanation: nil))
    }
}

class WindowAnimationPlacementTests: XCTestCase {
    private let screen = CGRect(x: 0, y: 29, width: 1403, height: 869)

    private func placement(for zone: CGRect, screen: CGRect? = nil) -> WindowAnimationPlacement {
        let screen = screen ?? self.screen
        return WindowAnimationPlacement(screenFrame: screen, sharedEdges: zone.sharedEdges(withRect: screen),
                                        constrainToScreen: true, gap: 0)
    }

    func testMinimumSizeKeepsEverySelectedEdgeAndCorner() {
        let cases: [(CGRect, CGSize, CGPoint)] = [
            (CGRect(x: 702, y: 29, width: 701, height: 869), CGSize(width: 913, height: 869), CGPoint(x: 490, y: 29)),
            (CGRect(x: 0, y: 29, width: 701, height: 869), CGSize(width: 913, height: 869), CGPoint(x: 0, y: 29)),
            (CGRect(x: 0, y: 29, width: 1403, height: 434), CGSize(width: 1403, height: 600), CGPoint(x: 0, y: 29)),
            (CGRect(x: 0, y: 464, width: 1403, height: 434), CGSize(width: 1403, height: 600), CGPoint(x: 0, y: 298)),
            (CGRect(x: 0, y: 29, width: 701, height: 434), CGSize(width: 913, height: 600), CGPoint(x: 0, y: 29)),
            (CGRect(x: 702, y: 29, width: 701, height: 434), CGSize(width: 913, height: 600), CGPoint(x: 490, y: 29)),
            (CGRect(x: 0, y: 464, width: 701, height: 434), CGSize(width: 913, height: 600), CGPoint(x: 0, y: 298)),
            (CGRect(x: 702, y: 464, width: 701, height: 434), CGSize(width: 913, height: 600), CGPoint(x: 490, y: 298))
        ]
        for (zone, size, expected) in cases {
            let result = placement(for: zone).frame(for: zone, actualSize: size, origin: screen, progress: 1)
            XCTAssertEqual(result.origin, expected)
            XCTAssertEqual(result.size, size)
        }
    }

    func testWidthLimitDoesNotReverseMotionOrJumpAtTheEnd() {
        let origin = CGRect(x: 100, y: 100, width: 1100, height: 650)
        let target = CGRect(x: 702, y: 29, width: 701, height: 869)
        let placement = placement(for: target)
        var previous = origin
        for step in 1...100 {
            let t = CGFloat(step) / 100
            let requested = CGRect(x: origin.minX + (target.minX - origin.minX) * t,
                                   y: origin.minY + (target.minY - origin.minY) * t,
                                   width: origin.width + (target.width - origin.width) * t,
                                   height: origin.height + (target.height - origin.height) * t)
            let result = placement.frame(for: requested, actualSize: CGSize(width: max(913, requested.width), height: requested.height),
                                         origin: origin, progress: t)
            XCTAssertGreaterThanOrEqual(result.minX, previous.minX - 0.001)
            XCTAssertLessThan(abs(result.minX - previous.minX), 7)
            previous = result
        }
        XCTAssertEqual(previous.minX, 490, accuracy: 0.001)
    }

    func testMaximumAndAspectRatioSizesKeepTheRightEdgeAndVerticalCenter() {
        let target = CGRect(x: 702, y: 29, width: 701, height: 869)
        for size in [CGSize(width: 600, height: 400), CGSize(width: 600, height: 450)] {
            let result = placement(for: target).frame(for: target, actualSize: size, origin: screen, progress: 1)
            XCTAssertEqual(result.maxX, screen.maxX)
            XCTAssertEqual(result.midY, screen.midY, accuracy: 0.5)
            XCTAssertEqual(result.size, size)
        }
    }

    func testCenteredLayoutCentersBothConstrainedDimensions() {
        let target = CGRect(x: 351, y: 129, width: 702, height: 669)
        let result = placement(for: target).frame(for: target, actualSize: CGSize(width: 913, height: 400), origin: screen, progress: 1)
        XCTAssertEqual(result.midX, target.midX, accuracy: 0.5)
        XCTAssertEqual(result.midY, target.midY, accuracy: 0.5)
    }

    func testDockInsetsAndNegativeDisplayCoordinatesUseTheProvidedWorkArea() {
        let screens = [CGRect(x: 45, y: 29, width: 1395, height: 869), screen,
                       CGRect(x: 0, y: 29, width: 1440, height: 831),
                       CGRect(x: -1600, y: -870, width: 1600, height: 900)]
        for screen in screens {
            let target = CGRect(x: screen.midX, y: screen.minY, width: screen.width / 2, height: screen.height)
            let result = placement(for: target, screen: screen).frame(for: target, actualSize: CGSize(width: 913, height: 600), origin: screen, progress: 1)
            XCTAssertEqual(result.maxX, screen.maxX)
            XCTAssertEqual(result.midY, screen.midY, accuracy: 0.5)
        }
    }

    func testInitiallyOutOfBoundsWindowIsNotClippedOnItsFirstFrame() {
        let origin = CGRect(x: 600, y: 29, width: 913, height: 700)
        let target = CGRect(x: 702, y: 29, width: 701, height: 869)
        let placement = placement(for: target)
        XCTAssertEqual(placement.frame(for: origin, actualSize: origin.size, origin: origin, progress: 0), origin)
        let final = placement.frame(for: target, actualSize: CGSize(width: 913, height: 869), origin: origin, progress: 1)
        XCTAssertEqual(final.maxX, screen.maxX)
    }

    func testGapCorrectionMatchesNormalWindowBounds() {
        let result = WindowFrameBounds.constrained(CGRect(x: 1000, y: 0, width: 600, height: 500), to: screen, gap: 10)
        XCTAssertEqual(result.origin, CGPoint(x: 793, y: 39))
        XCTAssertTrue(WindowFrameBounds.constrained(.null, to: screen, gap: 10).isNull)
    }

    func testFinalFrameIsAppliedBeforeCleanupAndOnlyOnce() {
        var events: [String] = []
        let destination = CGRect(x: 700, y: 29, width: 700, height: 869)
        let animation = WindowFrameAnimation(from: .zero, to: destination, startTime: 0, duration: 0.34,
                                             write: { _, _ in events.append("tick"); return true },
                                             finalize: { frame in XCTAssertEqual(frame, destination); events.append("final") },
                                             cleanup: { events.append("cleanup") },
                                             completion: { _ in events.append("completion") })
        animation.tick(at: 0.1)
        animation.tick(at: 0.5)
        animation.finish()
        XCTAssertEqual(events, ["tick", "final", "cleanup", "completion"])
    }

    func testCancellationDoesNotWriteTheDestination() {
        var events: [String] = []
        let animation = WindowFrameAnimation(from: .zero, to: screen, startTime: 0, duration: 0.34,
                                             write: { _, _ in true },
                                             finalize: { _ in events.append("final") },
                                             cleanup: { events.append("cleanup") },
                                             completion: { _ in events.append("completion") })
        animation.cancel()
        animation.finish()
        XCTAssertEqual(events, ["cleanup"])
    }
}

class ClampedWindowAlignerTests: XCTestCase {

    // AX coordinates: minY is the visual top. Edge names follow CGRect.sharedEdges.
    private let screenFrame = CGRect(x: 0, y: 0, width: 2000, height: 1200)

    func testRightHalfClampedBothAxesAnchorsRightCentersVertically() {
        let zone = CGRect(x: 1000, y: 0, width: 1000, height: 1200)
        let window = CGRect(x: 1000, y: 0, width: 600, height: 800) // narrower + shorter than zone
        let result = ClampedWindowAligner.aligned(window: window, inZone: zone, initialRect: zone,
                                                  screenFrame: screenFrame, alignment: .edgesAndCorners)
        XCTAssertEqual(result.origin.x, 1400, accuracy: 0.001) // zone.maxX - width = 2000 - 600
        XCTAssertEqual(result.origin.y, 200, accuracy: 0.001)  // centered: (1200 - 800)/2
        XCTAssertEqual(result.width, 600, accuracy: 0.001)
        XCTAssertEqual(result.height, 800, accuracy: 0.001)
    }

    func testRightHalfFullHeightLeavesVerticalUntouched() {
        let zone = CGRect(x: 1000, y: 0, width: 1000, height: 1200)
        let window = CGRect(x: 1000, y: 0, width: 600, height: 1200) // fills height
        let result = ClampedWindowAligner.aligned(window: window, inZone: zone, initialRect: zone,
                                                  screenFrame: screenFrame, alignment: .edgesAndCorners)
        XCTAssertEqual(result.origin.x, 1400, accuracy: 0.001)
        XCTAssertEqual(result.origin.y, 0, accuracy: 0.001)
    }

    func testLeftHalfClampedAnchorsLeftCentersVertically() {
        let zone = CGRect(x: 0, y: 0, width: 1000, height: 1200)
        let window = CGRect(x: 0, y: 0, width: 600, height: 800)
        let result = ClampedWindowAligner.aligned(window: window, inZone: zone, initialRect: zone,
                                                  screenFrame: screenFrame, alignment: .edgesAndCorners)
        XCTAssertEqual(result.origin.x, 0, accuracy: 0.001)
        XCTAssertEqual(result.origin.y, 200, accuracy: 0.001)
    }

    func testBottomRightQuarterAnchorsToCorner() {
        let zone = CGRect(x: 1000, y: 600, width: 1000, height: 600)
        let window = CGRect(x: 1000, y: 600, width: 600, height: 400)
        let result = ClampedWindowAligner.aligned(window: window, inZone: zone, initialRect: zone,
                                                  screenFrame: screenFrame, alignment: .edgesAndCorners)
        XCTAssertEqual(result.origin.x, 1400, accuracy: 0.001) // maxX - width
        XCTAssertEqual(result.origin.y, 800, accuracy: 0.001)  // maxY - height = 1200 - 400
    }

    func testInteriorZoneCentersBothAxes() {
        let zone = CGRect(x: 600, y: 400, width: 800, height: 400)
        let window = CGRect(x: 600, y: 400, width: 400, height: 200)
        let result = ClampedWindowAligner.aligned(window: window, inZone: zone, initialRect: zone,
                                                  screenFrame: screenFrame, alignment: .edgesAndCorners)
        XCTAssertEqual(result.origin.x, 800, accuracy: 0.001) // (800-400)/2 + 600
        XCTAssertEqual(result.origin.y, 500, accuracy: 0.001) // (400-200)/2 + 400
    }

    func testExactFitReturnsUnchanged() {
        let zone = CGRect(x: 1000, y: 0, width: 1000, height: 1200)
        let window = zone
        let result = ClampedWindowAligner.aligned(window: window, inZone: zone, initialRect: zone,
                                                  screenFrame: screenFrame, alignment: .edgesAndCorners)
        XCTAssertTrue(result.equalTo(window))
    }

    // A maximize against a Dock on the right comes back a point narrow (see #1852). Centering
    // that shortfall would put the window at x=1 and leave a visible gap on the left edge.

    func testMaximizeOnePointNarrowStaysPut() {
        let zone = CGRect(x: 0, y: 0, width: 1679, height: 1079)
        let window = CGRect(x: 0, y: 0, width: 1678, height: 1079)
        let result = ClampedWindowAligner.aligned(window: window, inZone: zone, initialRect: zone,
                                                  screenFrame: zone, alignment: .edgesAndCorners)
        XCTAssertTrue(result.equalTo(window))
    }

    func testRightHalfOnePointNarrowStaysPut() {
        let zone = CGRect(x: 840, y: 0, width: 839, height: 1079)
        let window = CGRect(x: 840, y: 0, width: 838, height: 1079)
        let screen = CGRect(x: 0, y: 0, width: 1679, height: 1079)
        let result = ClampedWindowAligner.aligned(window: window, inZone: zone, initialRect: zone,
                                                  screenFrame: screen, alignment: .edgesAndCorners)
        XCTAssertTrue(result.equalTo(window))
    }

    func testOnePointShortHeightStaysPut() {
        let zone = CGRect(x: 1000, y: 0, width: 1000, height: 1200)
        let window = CGRect(x: 1000, y: 0, width: 1000, height: 1199)
        let result = ClampedWindowAligner.aligned(window: window, inZone: zone, initialRect: zone,
                                                  screenFrame: screenFrame, alignment: .edgesAndCorners)
        XCTAssertTrue(result.equalTo(window))
    }

    func testShortfallJustOverToleranceStillAligns() {
        let zone = CGRect(x: 1000, y: 0, width: 1000, height: 1200)
        let window = CGRect(x: 1000, y: 0, width: 998.5, height: 1200)
        let result = ClampedWindowAligner.aligned(window: window, inZone: zone, initialRect: zone,
                                                  screenFrame: screenFrame, alignment: .edgesAndCorners)
        XCTAssertEqual(result.origin.x, 1001.5, accuracy: 0.001) // zone.maxX - width = 2000 - 998.5
    }

    func testOnePointNarrowLeavesOtherAxisAlignmentIntact() {
        let zone = CGRect(x: 1000, y: 0, width: 1000, height: 1200)
        let window = CGRect(x: 1000, y: 0, width: 999, height: 800) // a point narrow, genuinely short
        let result = ClampedWindowAligner.aligned(window: window, inZone: zone, initialRect: zone,
                                                  screenFrame: screenFrame, alignment: .edgesAndCorners)
        XCTAssertEqual(result.origin.x, 1000, accuracy: 0.001) // width within tolerance, left alone
        XCTAssertEqual(result.origin.y, 200, accuracy: 0.001)  // height still centered: (1200-800)/2
    }

    func testCornersModeCentersHalfButAnchorsQuarter() {
        let window = CGRect(x: 1000, y: 0, width: 600, height: 400)
        let half = CGRect(x: 1000, y: 0, width: 1000, height: 1200)
        let quarter = CGRect(x: 1000, y: 0, width: 1000, height: 600)

        XCTAssertEqual(ClampedWindowAligner.aligned(window: window, inZone: half, initialRect: half,
                                                    screenFrame: screenFrame, alignment: .corners),
                       CGRect(x: 1200, y: 400, width: 600, height: 400))
        XCTAssertEqual(ClampedWindowAligner.aligned(window: window, inZone: quarter, initialRect: quarter,
                                                    screenFrame: screenFrame, alignment: .corners),
                       CGRect(x: 1400, y: 0, width: 600, height: 400))
    }

    func testCenteredModeCentersEvenInCorner() {
        let zone = CGRect(x: 1000, y: 0, width: 1000, height: 600)
        let window = CGRect(x: 1000, y: 0, width: 600, height: 400)
        XCTAssertEqual(ClampedWindowAligner.aligned(window: window, inZone: zone, initialRect: zone,
                                                    screenFrame: screenFrame, alignment: .centered),
                       CGRect(x: 1200, y: 100, width: 600, height: 400))
    }

    func testLeadingCornerKeepsAspectRatioWindowsTopAlignedAcrossSideWidths() {
        // Offset display, including negative coordinates; widths are 1/2, 2/3, 1/3.
        let screen = CGRect(x: -2400, y: -600, width: 2400, height: 1400)
        for width: CGFloat in [1200, 1600, 800] {
            for x in [screen.minX, screen.maxX - width] {
                let zone = CGRect(x: x, y: screen.minY, width: width, height: screen.height)
                let window = CGRect(x: 100, y: 200, width: width, height: width * 9 / 16)
                let result = ClampedWindowAligner.aligned(window: window, inZone: zone, initialRect: zone,
                                                          screenFrame: screen, alignment: .leadingCorner)
                XCTAssertEqual(result, CGRect(x: x, y: -600, width: width, height: width * 9 / 16))
            }
        }
    }

    func testLeadingCornerUsesGappedZoneOriginForWidthConstrainedWindow() {
        let initialRect = CGRect(x: 1000, y: 0, width: 1000, height: 1200)
        let zone = initialRect.insetBy(dx: 12, dy: 12)
        let window = CGRect(x: 1500, y: 200, width: 600, height: zone.height)

        XCTAssertEqual(ClampedWindowAligner.aligned(window: window, inZone: zone, initialRect: initialRect,
                                                    screenFrame: screenFrame, alignment: .leadingCorner),
                       CGRect(x: 1012, y: 12, width: 600, height: 1176))
        // Existing edge alignment must still detect edges before gaps are applied.
        XCTAssertEqual(ClampedWindowAligner.aligned(window: window, inZone: zone, initialRect: initialRect,
                                                    screenFrame: screenFrame, alignment: .edgesAndCorners),
                       CGRect(x: 1388, y: 200, width: 600, height: 1176))
    }

    func testLeadingCornerPreservesFixedSizeLargerThanZone() {
        let zone = CGRect(x: 1000, y: 600, width: 1000, height: 600)
        let window = CGRect(x: 100, y: 200, width: 1100, height: 800)
        XCTAssertEqual(ClampedWindowAligner.aligned(window: window, inZone: zone, initialRect: zone,
                                                    screenFrame: screenFrame, alignment: .leadingCorner),
                       CGRect(x: 1000, y: 600, width: 1100, height: 800))
        // Screen containment is applied separately by BestEffortWindowMover.
    }

    func testLeadingCornerRestoresRequestedOriginWithinSizeTolerance() {
        let zone = CGRect(x: 1000, y: 0, width: 1000, height: 1200)
        let window = CGRect(x: 1004, y: 7, width: 999, height: 1199)
        XCTAssertEqual(ClampedWindowAligner.aligned(window: window, inZone: zone, initialRect: zone,
                                                    screenFrame: screenFrame, alignment: .leadingCorner),
                       CGRect(x: 1000, y: 0, width: 999, height: 1199))
    }
}

class NilWindowIdCalculationTests: XCTestCase {
    
    private let visibleFrame = CGRect(x: 10, y: 20, width: 1200, height: 900)
    private let windowRect = CGRect(x: 100, y: 100, width: 600, height: 400)
    
    /// The window id is bookkeeping only (#640); geometry must not depend on it.
    func testRectCalculationsMatchWithAndWithoutWindowId() {
        for action in WindowAction.active {
            guard let calculation = WindowCalculationFactory.calculationsByAction[action] else { continue }
            
            let withId = calculation.calculateRect(params(windowId: 1, action: action)).rect
            let withoutId = calculation.calculateRect(params(windowId: nil, action: action)).rect
            
            XCTAssertEqual(withId, withoutId, "\(action.name) geometry should not depend on window id")
        }
    }
    
    private func params(windowId: CGWindowID?, action: WindowAction) -> RectCalculationParameters {
        RectCalculationParameters(window: Window(id: windowId, rect: windowRect),
                                  visibleFrameOfScreen: visibleFrame,
                                  action: action,
                                  lastAction: nil)
    }
}

class DerivedWindowIdTests: XCTestCase {
    
    func testDerivedIdHasHighBitSet() {
        XCTAssertEqual(AccessibilityElement.deriveWindowId(fromElementHash: 0) & 0x8000_0000, 0x8000_0000)
        XCTAssertEqual(AccessibilityElement.deriveWindowId(fromElementHash: CFHashCode.max) & 0x8000_0000, 0x8000_0000)
    }
    
    func testDerivedIdIsDeterministic() {
        XCTAssertEqual(AccessibilityElement.deriveWindowId(fromElementHash: 1668292462),
                       AccessibilityElement.deriveWindowId(fromElementHash: 1668292462))
    }
    
    func testDistinctHashesGiveDistinctIds() {
        let ids: [CGWindowID] = [1668318964, 1668318948, 1668321588].map { AccessibilityElement.deriveWindowId(fromElementHash: CFHashCode($0)) }
        XCTAssertEqual(Set(ids).count, ids.count)
    }
}

// Portrait eighth snapping tiles the screen into four rows. On a display whose
// visible-frame height is not divisible by 4, the row origins must be expressed
// as cell-height multiples (floor(height / 4)) so adjacent rows abut exactly
// instead of drifting apart by the raw height fraction's sub-pixel remainder.
class PortraitEighthAbutmentTests: XCTestCase {

    // Portrait frame whose height is NOT divisible by 4 (1002 % 4 == 2): the case
    // that used to leave 1-2px gaps between rows.
    private static let nonDivisibleFrame = CGRect(x: 0, y: 0, width: 800, height: 1002)
    // Portrait frame whose height IS divisible by 4: rows already tile seamlessly.
    private static let divisibleFrame = CGRect(x: 0, y: 0, width: 800, height: 1000)

    private func portraitEighths(_ frame: CGRect) -> [CGRect] {
        return [
            TopLeftEighthCalculation().portraitRect(frame).rect,
            TopCenterLeftEighthCalculation().portraitRect(frame).rect,
            TopCenterRightEighthCalculation().portraitRect(frame).rect,
            TopRightEighthCalculation().portraitRect(frame).rect,
            BottomLeftEighthCalculation().portraitRect(frame).rect,
            BottomCenterLeftEighthCalculation().portraitRect(frame).rect,
            BottomCenterRightEighthCalculation().portraitRect(frame).rect,
            BottomRightEighthCalculation().portraitRect(frame).rect,
        ]
    }

    private func rowOrigins(_ frame: CGRect) -> [CGFloat] {
        return Set(portraitEighths(frame).map { $0.origin.y }).sorted(by: >)
    }

    func testAllPortraitEighthsAreOneCellTall() {
        let cellHeight = floor(Self.nonDivisibleFrame.height / 4.0)
        for rect in portraitEighths(Self.nonDivisibleFrame) {
            XCTAssertEqual(rect.height, cellHeight, accuracy: 0.001)
        }
    }

    func testPortraitEighthRowsAlignToCellHeightGridOnNonDivisibleHeight() {
        let frame = Self.nonDivisibleFrame
        let cellHeight = floor(frame.height / 4.0)
        let origins = rowOrigins(frame)

        XCTAssertEqual(origins.count, 4)
        XCTAssertEqual(origins[0], frame.maxY - cellHeight, accuracy: 0.001)
        XCTAssertEqual(origins[1], frame.maxY - cellHeight * 2.0, accuracy: 0.001)
        XCTAssertEqual(origins[2], frame.maxY - cellHeight * 3.0, accuracy: 0.001)
        XCTAssertEqual(origins[3], frame.minY, accuracy: 0.001)
    }

    func testPortraitEighthRowsAbutExactlyOnNonDivisibleHeight() {
        // Before the fix, rows 2 and 3 used raw height fractions (height / 2 and
        // height * 0.75), so rows 1-2 and 2-3 each drifted ~1px apart. The top
        // three rows must abut exactly now: each row's minY equals the row
        // above's maxY. (The height % 4 residual sits at the row3-row4 boundary
        // and is zero only when height is divisible by 4 — see the divisible test.)
        let frame = Self.nonDivisibleFrame
        let cellHeight = floor(frame.height / 4.0)
        let origins = rowOrigins(frame)

        XCTAssertEqual(origins[0], origins[1] + cellHeight, accuracy: 0.001)
        XCTAssertEqual(origins[1], origins[2] + cellHeight, accuracy: 0.001)
    }

    func testPortraitEighthRowsTileFullyWhenHeightDivisibleByFour() {
        // When height % 4 == 0 the rounding residual is zero, so every row boundary
        // abuts. Guards against regressing the already-seamless divisible case.
        let frame = Self.divisibleFrame
        let cellHeight = frame.height / 4.0
        let origins = rowOrigins(frame)

        XCTAssertEqual(origins[0], origins[1] + cellHeight, accuracy: 0.001)
        XCTAssertEqual(origins[1], origins[2] + cellHeight, accuracy: 0.001)
        XCTAssertEqual(origins[2], origins[3] + cellHeight, accuracy: 0.001)
    }
}
      
final class WindowSizeConstraintTests: XCTestCase {
    private let requested = CGRect(x: 0, y: 0, width: 504, height: 900)

    func testMinimumWidthAndHeightAreDetectedIndependently() {
        XCTAssertTrue(WindowSizeConstraint.isExceeded(requested: requested,
                                                      actual: CGRect(x: 0, y: 0, width: 600, height: 900),
                                                      action: .firstThird))
        XCTAssertTrue(WindowSizeConstraint.isExceeded(requested: requested,
                                                      actual: CGRect(x: 0, y: 0, width: 504, height: 950),
                                                      action: .firstThird))
    }

    func testRoundingUpToOnePointDoesNotWarn() {
        for difference: CGFloat in [0, 0.5, 1] {
            let actual = CGRect(x: 30, y: -20, width: requested.width + difference,
                                height: requested.height + difference)
            XCTAssertFalse(WindowSizeConstraint.isExceeded(requested: requested, actual: actual,
                                                           action: .firstThird))
        }
        XCTAssertTrue(WindowSizeConstraint.isExceeded(requested: requested,
                                                      actual: CGRect(x: 0, y: 0, width: 505.5, height: 900),
                                                      action: .firstThird))
    }

    func testMaximumSizeOrAspectRatioConstraintsDoNotWarn() {
        for size in [CGSize(width: 400, height: 900), CGSize(width: 504, height: 600),
                     CGSize(width: 400, height: 600)] {
            XCTAssertFalse(WindowSizeConstraint.isExceeded(requested: requested,
                                                           actual: CGRect(origin: .zero, size: size),
                                                           action: .maximize))
        }
    }

    func testMoveOnlyActionsDoNotWarn() {
        let actual = CGRect(x: 20, y: 20, width: 600, height: 950)
        for action: WindowAction in [.center, .centerProminently, .nextDisplay] {
            XCTAssertFalse(WindowSizeConstraint.isExceeded(requested: requested, actual: actual,
                                                           action: action))
        }
    }

    func testInvalidRequestedAndActualFramesDoNotWarn() {
        let invalidFrames: [CGRect] = [
            .null, .infinite, .zero,
            CGRect(x: 0, y: 0, width: 0, height: 900),
            CGRect(x: 0, y: 0, width: 504, height: 0),
            CGRect(x: 0, y: 0, width: -504, height: 900),
            CGRect(x: 0, y: 0, width: 504, height: -900),
            CGRect(x: CGFloat.nan, y: 0, width: 504, height: 900),
            CGRect(x: 0, y: CGFloat.infinity, width: 504, height: 900),
            CGRect(x: 0, y: 0, width: CGFloat.infinity, height: 900),
            CGRect(x: 0, y: 0, width: 504, height: CGFloat.nan)
        ]
        let larger = CGRect(x: 0, y: 0, width: 600, height: 950)
        for invalid in invalidFrames {
            XCTAssertFalse(WindowSizeConstraint.isExceeded(requested: invalid, actual: larger,
                                                           action: .firstThird))
            XCTAssertFalse(WindowSizeConstraint.isExceeded(requested: requested, actual: invalid,
                                                           action: .firstThird))
        }
    }
}

final class WindowSizeConstraintExecutionTests: XCTestCase {
    private let windowId: CGWindowID = 522_001
    private var savedDefaults: [(Default, CodableDefault)] = []
    private var savedRestoreRects: [CGWindowID: CGRect] = [:]
    private var savedActions: [CGWindowID: RectangleAction] = [:]
    private var savedLogging = false

    override func setUp() {
        super.setUp()
        let settings: [(Default, CodableDefault)] = [
            (Defaults.subsequentExecutionMode, CodableDefault(int: SubsequentExecutionMode.none.rawValue)),
            (Defaults.cooperativeCornerResize, CodableDefault(bool: false)),
            (Defaults.experimentalWindowAnimations, CodableDefault(bool: false)),
            (Defaults.useCursorScreenDetection, CodableDefault(bool: false)),
            (Defaults.moveFixedSizeToEdge, CodableDefault(int: EdgeAlignment.edgesAndCorners.rawValue)),
            (Defaults.horizontalSplitRatio, CodableDefault(float: 50)),
            (Defaults.verticalSplitRatio, CodableDefault(float: 50)),
            (Defaults.halvesPreserveOtherAxisSize, CodableDefault(bool: false)),
            (Defaults.cycleSizesIsChanged, CodableDefault(bool: false)),
            (Defaults.resizeOnDirectionalMove, CodableDefault(bool: false)),
            (Defaults.centeredDirectionalMove, CodableDefault(int: 2)),
            (Defaults.gapSize, CodableDefault(float: 0)),
            (Defaults.stageSize, CodableDefault(float: 0)),
            (Defaults.screenEdgeGapLeft, CodableDefault(float: 0)),
            (Defaults.screenEdgeGapRight, CodableDefault(float: 0)),
            (Defaults.screenEdgeGapTop, CodableDefault(float: 0)),
            (Defaults.screenEdgeGapBottom, CodableDefault(float: 0)),
            (Defaults.cyclingOverlapOffset, CodableDefault(int: 2)),
            (Defaults.combinedDisplayMode, CodableDefault(int: 2)),
            (Defaults.todo, CodableDefault(int: 2))
        ]
        savedDefaults = settings.map { ($0.0, $0.0.toCodable()) }
        settings.forEach { $0.0.load(from: $0.1) }
        savedRestoreRects = AppDelegate.windowHistory.restoreRects
        savedActions = AppDelegate.windowHistory.lastRectangleActions
        AppDelegate.windowHistory.restoreRects.removeValue(forKey: windowId)
        AppDelegate.windowHistory.lastRectangleActions.removeValue(forKey: windowId)
        savedLogging = Logger.logging
        Logger.logging = false
    }

    override func tearDown() {
        savedDefaults.forEach { $0.0.load(from: $0.1) }
        AppDelegate.windowHistory.restoreRects = savedRestoreRects
        AppDelegate.windowHistory.lastRectangleActions = savedActions
        Logger.logging = savedLogging
        super.tearDown()
    }

    func testLeadingOriginPersistsThroughConstrainedHalfCycles() {
        assertConstrainedHalfCycles(alignment: .leadingCorner, topOffsets: [0, 0, 0, 0])
    }

    func testEdgesAndCornersCentersConstrainedHalfCycles() {
        assertConstrainedHalfCycles(alignment: .edgesAndCorners, topOffsets: [363, 250, 475, 363])
    }

    func testCornersOnlyCentersConstrainedHalfCycles() {
        assertConstrainedHalfCycles(alignment: .corners, topOffsets: [363, 250, 475, 363])
    }

    func testCenteredModeCentersConstrainedHalfCycles() {
        assertConstrainedHalfCycles(alignment: .centered, topOffsets: [363, 250, 475, 363])
    }

    private func assertConstrainedHalfCycles(alignment: EdgeAlignment, topOffsets: [CGFloat],
                                            file: StaticString = #filePath, line: UInt = #line) {
        Defaults.moveFixedSizeToEdge.value = alignment
        Defaults.subsequentExecutionMode.value = .resize
        let screen = TestScreen(frame: CGRect(x: -2400, y: -600, width: 2400, height: 1400))
        let window = ConstrainedWindow(frame: CGRect(x: -2000, y: -200, width: 800, height: 450).screenFlipped) {
            CGRect(origin: $0.origin, size: CGSize(width: $0.width, height: $0.width * 9 / 16))
        }
        let manager = TestWindowManager(screenDetection: TestScreenDetection(source: screen))

        // Each execution consumes the achieved frame and history from the previous one.
        // Changing sides must start the new action's cycle at one half.
        for action: WindowAction in [.leftHalf, .rightHalf] {
            for (index, width) in [CGFloat(1200), 1600, 800, 1200].enumerated() {
                manager.execute(ExecutionParameters(action, screen: screen, windowElement: window,
                                                    windowId: windowId, source: .menuItem))

                let x = action == .leftHalf ? screen.frame.minX : screen.frame.maxX - width
                XCTAssertEqual(window.frame,
                               CGRect(x: x, y: screen.frame.screenFlipped.minY + topOffsets[index],
                                      width: width, height: width * 9 / 16),
                               "\(action), width \(width)", file: file, line: line)
            }
        }
    }

    func testLeadingOriginFixedWindowIsContainedAfterBottomRightPlacement() {
        Defaults.moveFixedSizeToEdge.value = .leadingCorner
        let screen = TestScreen(frame: CGRect(x: -1600, y: 200, width: 1200, height: 900))
        let size = CGSize(width: 800, height: 700)
        let window = ConstrainedWindow(frame: CGRect(x: -1500, y: 300, width: size.width, height: size.height).screenFlipped,
                                       resizable: false) {
            CGRect(origin: $0.origin, size: size)
        }
        let manager = TestWindowManager(screenDetection: TestScreenDetection(source: screen))

        manager.execute(ExecutionParameters(.bottomRight, screen: screen, windowElement: window,
                                            windowId: windowId, source: .menuItem))

        // The 600x450 snap region cannot hold this window. Containment takes precedence
        // over its requested origin without shrinking the app's accepted size.
        let visibleFrame = screen.frame.screenFlipped
        XCTAssertEqual(window.frame,
                       CGRect(x: visibleFrame.maxX - size.width, y: visibleFrame.maxY - size.height,
                              width: size.width, height: size.height))
        XCTAssertTrue(visibleFrame.contains(window.frame))
    }

    func testLeadingOriginDoesNotOverrideAppPositionAfterMovementOnlyAction() {
        Defaults.moveFixedSizeToEdge.value = .leadingCorner
        let screen = TestScreen(frame: CGRect(x: -2400, y: -600, width: 2400, height: 1400))
        let initialFrame = CGRect(x: -1900, y: 0, width: 600, height: 400).screenFlipped
        var initialMove = true
        let window = ConstrainedWindow(frame: initialFrame) { requestedFrame in
            // Simulate the app correcting its position after the initial move.
            // A subsequent alignment write would wrongly undo that correction.
            defer { initialMove = false }
            return initialMove ? requestedFrame.offsetBy(dx: 0, dy: 7) : requestedFrame
        }
        let manager = TestWindowManager(screenDetection: TestScreenDetection(source: screen))

        manager.execute(ExecutionParameters(.moveRight, screen: screen, windowElement: window,
                                            windowId: windowId, source: .menuItem))

        XCTAssertEqual(window.frame,
                       CGRect(x: screen.frame.maxX - initialFrame.width, y: initialFrame.minY + 7,
                              width: initialFrame.width, height: initialFrame.height))
    }

    func testClampedFirstAndLastThirdsWarnAndPreserveAchievedGeometry() {
        let screen = TestScreen(frame: CGRect(x: 0, y: 0, width: 1512, height: 900))
        for action: WindowAction in [.firstThird, .lastThird] {
            let window = ClampingWindow(targetSize: CGSize(width: 504, height: 900))
            let originalFrame = window.frame
            let manager = TestWindowManager(screenDetection: TestScreenDetection(source: screen))

            manager.execute(ExecutionParameters(action, screen: screen, windowElement: window,
                                                windowId: windowId, source: .menuItem))

            XCTAssertEqual(window.resizeAttempts, 1)
            XCTAssertEqual(window.frame.width, 600)
            XCTAssertEqual(window.frame.height, 900)
            XCTAssertEqual(window.frame.minX, action == .firstThird ? 0 : 912)
            XCTAssertEqual(manager.warningScreens.count, 1)
            XCTAssertTrue(manager.warningScreens.first === screen)
            XCTAssertEqual(manager.hideCount, 1)
            XCTAssertEqual(AppDelegate.windowHistory.lastRectangleActions[windowId]?.rect, window.frame)
            XCTAssertEqual(AppDelegate.windowHistory.lastRectangleActions[windowId]?.action, action)
            XCTAssertEqual(AppDelegate.windowHistory.restoreRects[windowId], originalFrame)
        }
    }

    func testSuccessfulTwoThirdsClearEarlierWarning() {
        let screen = TestScreen(frame: CGRect(x: 0, y: 0, width: 1512, height: 900))
        let window = ClampingWindow(targetSize: CGSize(width: 504, height: 900))
        let manager = TestWindowManager(screenDetection: TestScreenDetection(source: screen))
        manager.execute(ExecutionParameters(.firstThird, screen: screen, windowElement: window,
                                            windowId: windowId, source: .menuItem))
        XCTAssertTrue(manager.warningVisible)

        manager.execute(ExecutionParameters(.firstTwoThirds, screen: screen, windowElement: window,
                                            windowId: windowId, source: .menuItem))

        XCTAssertEqual(window.frame.size, CGSize(width: 1008, height: 900))
        XCTAssertEqual(manager.warningScreens.count, 1)
        XCTAssertEqual(manager.hideCount, 2)
        XCTAssertFalse(manager.warningVisible)
        XCTAssertEqual(AppDelegate.windowHistory.lastRectangleActions[windowId]?.rect, window.frame)
    }

    func testSuccessfulFinalCrossDisplayRetryDoesNotWarn() {
        assertCrossDisplayWarning(clampedAttempts: 2, expectsWarning: false)
    }

    func testRestoreFromDisconnectedDisplayKeepsWindowReachable() {
        let screen = TestScreen(frame: CGRect(x: 0, y: 0, width: 1512, height: 900))
        let window = ClampingWindow(targetSize: CGSize(width: 504, height: 900))
        let manager = TestWindowManager(screenDetection: TestScreenDetection(source: screen))
        let saved = CGRect(x: 3000, y: 100, width: 900, height: 500)
        AppDelegate.windowHistory.restoreRects[windowId] = saved
        manager.execute(ExecutionParameters(.restore, windowElement: window, windowId: windowId, source: .menuItem))
        XCTAssertTrue(screen.frame.screenFlipped.contains(window.frame))
        XCTAssertEqual(window.frame.size, saved.size)
        XCTAssertEqual(AppDelegate.windowHistory.restoreRects[windowId], saved)
    }

    func testPersistentlyClampedCrossDisplayRetryWarnsOnceOnDestination() {
        assertCrossDisplayWarning(clampedAttempts: nil, expectsWarning: true)
    }

    func testNewerActionCancelsPendingCrossDisplayRetryAndWarning() {
        let source = TestScreen(frame: CGRect(x: 0, y: 0, width: 1512, height: 900))
        let destination = TestScreen(frame: CGRect(x: 1512, y: 0, width: 1512, height: 900))
        let window = ClampingWindow(targetSize: CGSize(width: 504, height: 900))
        let manager = TestWindowManager(screenDetection: TestScreenDetection(source: source))
        manager.execute(ExecutionParameters(.lastThird, screen: destination, windowElement: window,
                                            windowId: windowId, source: .menuItem))
        XCTAssertEqual(window.resizeAttempts, 2)
        XCTAssertTrue(manager.warningScreens.isEmpty)

        manager.execute(ExecutionParameters(.firstTwoThirds, screen: source, windowElement: window,
                                            windowId: windowId, source: .menuItem))
        let newerFrame = window.frame
        XCTAssertEqual(newerFrame.size, CGSize(width: 1008, height: 900))
        let staleCompletion = expectation(description: "Superseded resize must not complete")
        staleCompletion.isInverted = true
        manager.didFinish = { staleCompletion.fulfill() }

        wait(for: [staleCompletion], timeout: 0.1)

        XCTAssertEqual(window.resizeAttempts, 2)
        XCTAssertEqual(window.frame, newerFrame)
        XCTAssertTrue(manager.warningScreens.isEmpty)
        XCTAssertEqual(AppDelegate.windowHistory.lastRectangleActions[windowId]?.rect, newerFrame)
        XCTAssertEqual(AppDelegate.windowHistory.lastRectangleActions[windowId]?.action, .firstTwoThirds)
    }

    func testSpaceChangeDisconnectAndSleepCancelPendingCrossDisplayRetry() {
        for scenario in 0..<4 {
            let source = TestScreen(frame: CGRect(x: 0, y: 0, width: 1512, height: 900))
            let destination = TestScreen(frame: CGRect(x: 1512, y: 0, width: 1512, height: 900))
            let window = ClampingWindow(targetSize: CGSize(width: 504, height: 900))
            let detection = TestScreenDetection(source: source)
            let workspace = NotificationCenter(), app = NotificationCenter()
            let manager = TestWindowManager(screenDetection: detection,
                coordinator: SpaceOperationCoordinator(environmentIsSafe: { true }, workspaceNotificationCenter: NotificationCenter()),
                notificationCenter: app, workspaceNotificationCenter: workspace)
            manager.execute(ExecutionParameters(.lastThird, screen: destination, windowElement: window,
                                                windowId: windowId, source: .menuItem))
            XCTAssertEqual(window.resizeAttempts, 2)
            let interruptedFrame = window.frame
            switch scenario {
            case 0: workspace.post(name: NSWorkspace.activeSpaceDidChangeNotification, object: nil)
            case 1: app.post(name: NSApplication.didChangeScreenParametersNotification, object: nil)
            case 2: workspace.post(name: NSWorkspace.willSleepNotification, object: nil)
            default: detection.connected = false
            }
            let completion = expectation(description: "Interrupted cross-display retry must not complete")
            completion.isInverted = true
            manager.didFinish = { completion.fulfill() }
            wait(for: [completion], timeout: 0.07)
            XCTAssertEqual(window.resizeAttempts, 2)
            XCTAssertEqual(window.frame, interruptedFrame)
            XCTAssertTrue(manager.warningScreens.isEmpty)
        }
    }

    private func assertCrossDisplayWarning(clampedAttempts: Int?, expectsWarning: Bool) {
        let source = TestScreen(frame: CGRect(x: 0, y: 0, width: 1512, height: 900))
        let destination = TestScreen(frame: CGRect(x: 1512, y: 0, width: 1512, height: 900))
        let window = ClampingWindow(targetSize: CGSize(width: 504, height: 900),
                                    clampedAttempts: clampedAttempts)
        let manager = TestWindowManager(screenDetection: TestScreenDetection(source: source))
        let finished = expectation(description: "Final cross-display resize processed")
        manager.didFinish = { finished.fulfill() }

        manager.execute(ExecutionParameters(.lastThird, screen: destination, windowElement: window,
                                            windowId: windowId, source: .menuItem))

        XCTAssertEqual(window.resizeAttempts, 2)
        XCTAssertTrue(manager.warningScreens.isEmpty)
        XCTAssertNil(AppDelegate.windowHistory.lastRectangleActions[windowId])

        wait(for: [finished], timeout: 1)
        XCTAssertEqual(window.resizeAttempts, 3)
        XCTAssertEqual(window.frame.width, expectsWarning ? 600 : 504)
        XCTAssertEqual(window.frame.maxX, destination.frame.maxX)
        XCTAssertEqual(manager.warningScreens.count, expectsWarning ? 1 : 0)
        if expectsWarning {
            XCTAssertTrue(manager.warningScreens.first === destination)
        }
        XCTAssertEqual(AppDelegate.windowHistory.lastRectangleActions[windowId]?.rect, window.frame)
    }

    private final class TestScreen: NSScreen {
        private let testFrame: CGRect

        init(frame: CGRect) {
            testFrame = frame
            super.init()
        }

        override var frame: NSRect { testFrame }
        override var visibleFrame: NSRect { testFrame }
        override var safeAreaInsets: NSEdgeInsets { NSEdgeInsetsZero }
        override var hash: Int { ObjectIdentifier(self).hashValue }
        override func isEqual(_ object: Any?) -> Bool { (object as AnyObject?) === self }
    }

    private final class TestScreenDetection: ScreenDetection {
        let source: NSScreen

        init(source: NSScreen) { self.source = source }
        var connected = true
        override func isAvailable(_ screen: NSScreen) -> Bool { connected && screen.frame.isFiniteAndNonEmpty }

        override func detectScreens(using frontmostWindowElement: AccessibilityElement?) -> UsableScreens? {
            UsableScreens(currentScreen: source, numScreens: 2)
        }
    }

    private final class ClampingWindow: AccessibilityElement {
        private var currentFrame = CGRect(x: 100, y: 100, width: 900, height: 500).screenFlipped
        private let targetSize: CGSize
        private let clampedAttempts: Int?
        private(set) var resizeAttempts = 0

        init(targetSize: CGSize, clampedAttempts: Int? = nil) {
            self.targetSize = targetSize
            self.clampedAttempts = clampedAttempts
            super.init(AXUIElementCreateSystemWide())
        }

        override var frame: CGRect { currentFrame }
        override var isSheet: Bool? { false }
        override var isSystemDialog: Bool? { false }
        override var minimumSize: CGSize? { nil }
        override func getWindowId() -> CGWindowID? { nil }
        override func isResizable() -> Bool { true }

        override func setFrame(_ frame: CGRect, adjustSizeFirst: Bool = true, adjustPosition: Bool = true) {
            currentFrame = frame
            if frame.size == targetSize {
                resizeAttempts += 1
                if clampedAttempts.map({ resizeAttempts <= $0 }) ?? true {
                    currentFrame.size.width = max(frame.width, 600)
                }
            }
        }
    }

    private final class ConstrainedWindow: AccessibilityElement {
        private var currentFrame: CGRect
        private let resizable: Bool
        private let acceptedFrame: (CGRect) -> CGRect

        init(frame: CGRect, resizable: Bool = true, acceptedFrame: @escaping (CGRect) -> CGRect) {
            currentFrame = frame
            self.resizable = resizable
            self.acceptedFrame = acceptedFrame
            super.init(AXUIElementCreateSystemWide())
        }

        override var frame: CGRect { currentFrame }
        override var isSheet: Bool? { false }
        override var isSystemDialog: Bool? { false }
        override var minimumSize: CGSize? { nil }
        override func getWindowId() -> CGWindowID? { nil }
        override func isResizable() -> Bool { resizable }

        override func setFrame(_ frame: CGRect, adjustSizeFirst: Bool = true, adjustPosition: Bool = true) {
            currentFrame = acceptedFrame(frame)
        }
    }

    private final class TestWindowManager: WindowManager {
        private(set) var warningScreens: [NSScreen] = []
        private(set) var hideCount = 0
        private(set) var warningVisible = false
        var didFinish: (() -> Void)?

        override func showSizeConstraintWarning(on screen: NSScreen) {
            warningScreens.append(screen)
            warningVisible = true
        }

        override func hideSizeConstraintWarning() {
            hideCount += 1
            warningVisible = false
        }

        override func windowMovedAcrossDisplays(windowElement: AccessibilityElement, resultingRect: CGRect) {}

        override func postProcess(result: ResultParameters, resultingRect: CGRect, incrementCount: Bool = true) {
            super.postProcess(result: result, resultingRect: resultingRect, incrementCount: incrementCount)
            didFinish?()
        }
    }
}

final class CrossDisplayResizeTests: XCTestCase {
    func testDisplayCycleRetriesWidthUntilWindowFillsRightHalf() {
        let settings: [(Default, CodableDefault)] = [
            (Defaults.subsequentExecutionMode, CodableDefault(int: SubsequentExecutionMode.cycleMonitor.rawValue)),
            (Defaults.cooperativeCornerResize, CodableDefault(bool: false)),
            (Defaults.horizontalSplitRatio, CodableDefault(float: 50)),
            (Defaults.moveFixedSizeToEdge, CodableDefault(int: EdgeAlignment.edgesAndCorners.rawValue)),
            (Defaults.gapSize, CodableDefault(float: 0)),
            (Defaults.stageSize, CodableDefault(float: 0)),
            (Defaults.screenEdgeGapLeft, CodableDefault(float: 0)),
            (Defaults.screenEdgeGapRight, CodableDefault(float: 0)),
            (Defaults.screenEdgeGapTop, CodableDefault(float: 0)),
            (Defaults.screenEdgeGapBottom, CodableDefault(float: 0)),
            (Defaults.combinedDisplayMode, CodableDefault(int: 2)),
            (Defaults.todo, CodableDefault(int: 2))
        ]
        let savedDefaults = settings.map { ($0.0, $0.0.toCodable()) }
        defer {
            savedDefaults.forEach { $0.0.load(from: $0.1) }
            ActiveSideSplitRatios.shared.resetAll()
        }
        settings.forEach { $0.0.load(from: $0.1) }

        let laptop = TestScreen(frame: CGRect(x: 0, y: 0, width: 2056, height: 1329))
        let monitor = TestScreen(frame: CGRect(x: -702, y: 1329, width: 3440, height: 1440))
        let target = CGRect(x: 1018, y: 1329, width: 1720, height: 1440).screenFlipped
        let window = ClampingWindow(target: target)
        let manager = TestWindowManager(screenDetection: TestScreenDetection(source: laptop))
        let finished = expectation(description: "Display-cycle resize completed")
        var completedFrames: [CGRect] = []
        manager.didFinish = { result, frame in
            XCTAssertTrue(result.usableScreens.currentScreen === laptop)
            completedFrames.append(frame)
            finished.fulfill()
        }

        // Repeated shortcuts pass the destination explicitly. Simulate macOS accepting
        // the height but clamping the width on the initial move and immediate retry.
        manager.execute(ExecutionParameters(.rightHalf, screen: monitor, windowElement: window))

        XCTAssertEqual(window.resizeAttempts, 2)
        XCTAssertEqual(window.frame.maxX, target.maxX)
        XCTAssertEqual(window.frame.minX, target.minX + 400)
        XCTAssertTrue(completedFrames.isEmpty)

        wait(for: [finished], timeout: 1)
        XCTAssertEqual(window.resizeAttempts, 3)
        XCTAssertEqual(window.frame, target)
        XCTAssertEqual(completedFrames, [target])
    }

    private final class TestScreen: NSScreen {
        private let testFrame: CGRect

        init(frame: CGRect) {
            testFrame = frame
            super.init()
        }

        override var frame: NSRect { testFrame }
        override var visibleFrame: NSRect { testFrame }
        override var safeAreaInsets: NSEdgeInsets { NSEdgeInsetsZero }
        override var hash: Int { ObjectIdentifier(self).hashValue }

        // AppKit's equality implementation requires a real display ID.
        override func isEqual(_ object: Any?) -> Bool {
            (object as AnyObject?) === self
        }
    }

    private final class TestScreenDetection: ScreenDetection {
        let source: NSScreen

        init(source: NSScreen) {
            self.source = source
        }
        override func isAvailable(_ screen: NSScreen) -> Bool { screen.frame.isFiniteAndNonEmpty }

        override func detectScreens(using frontmostWindowElement: AccessibilityElement?) -> UsableScreens? {
            UsableScreens(currentScreen: source, numScreens: 2)
        }
    }

    private final class ClampingWindow: AccessibilityElement {
        private var currentFrame = CGRect(x: 1028, y: 0, width: 1028, height: 645).screenFlipped
        private let target: CGRect
        private(set) var resizeAttempts = 0

        init(target: CGRect) {
            self.target = target
            super.init(AXUIElementCreateSystemWide())
        }

        override var frame: CGRect { currentFrame }
        override var isSheet: Bool? { false }
        override var isSystemDialog: Bool? { false }
        override var minimumSize: CGSize? { nil }
        override func getWindowId() -> CGWindowID? { nil }
        override func isResizable() -> Bool { true }

        override func setFrame(_ frame: CGRect, adjustSizeFirst: Bool = true, adjustPosition: Bool = true) {
            currentFrame = CGRect(origin: adjustPosition ? frame.origin : currentFrame.origin, size: frame.size)
            if frame.size == target.size {
                resizeAttempts += 1
                if resizeAttempts <= 2 {
                    currentFrame.size.width -= 400
                }
            }
        }
    }

    private final class TestWindowManager: WindowManager {
        var didFinish: ((ResultParameters, CGRect) -> Void)?

        override func windowMovedAcrossDisplays(windowElement: AccessibilityElement, resultingRect: CGRect) {}

        override func postProcess(result: ResultParameters, resultingRect: CGRect, incrementCount: Bool = true) {
            didFinish?(result, resultingRect)
        }
    }
}

final class SpaceDisplayReliabilityTests: XCTestCase {
    private final class Screen: NSScreen {
        let rect: CGRect
        init(_ rect: CGRect) { self.rect = rect; super.init() }
        override var frame: CGRect { rect }
        override var visibleFrame: CGRect { rect }
        override var safeAreaInsets: NSEdgeInsets { NSEdgeInsetsZero }
        override func isEqual(_ object: Any?) -> Bool { (object as AnyObject?) === self }
        override var hash: Int { ObjectIdentifier(self).hashValue }
    }

    func testStaggeredDisplayOrderingIsDeterministicForEveryEnumeration() {
        let saved = Defaults.screensOrderedByX.value
        defer { Defaults.screensOrderedByX.value = saved }
        Defaults.screensOrderedByX.value = .yThenMinX
        let top = Screen(CGRect(x: 900, y: 600, width: 600, height: 600))
        let middle = Screen(CGRect(x: 300, y: 300, width: 600, height: 600))
        let bottom = Screen(CGRect(x: 0, y: 0, width: 600, height: 600))
        let permutations = [[top, middle, bottom], [top, bottom, middle], [middle, top, bottom],
                            [middle, bottom, top], [bottom, top, middle], [bottom, middle, top]]
        for screens in permutations {
            XCTAssertEqual(ScreenDetection().order(screens: screens).map(\.frame), [middle.frame, top.frame, bottom.frame])
        }
    }

    func testEmptyDisconnectedAndInvalidDisplayGeometryDoesNotSelectAnUnrelatedScreen() throws {
        let left = Screen(CGRect(x: 0, y: 0, width: 600, height: 400))
        let right = Screen(CGRect(x: 600, y: 0, width: 600, height: 400))
        var available: [NSScreen] = [left, right]
        let detection = ScreenDetection(screens: { available })
        XCTAssertNil(detection.screenContaining(CGRect(x: 9000, y: 9000, width: 100, height: 100), screens: available))
        XCTAssertNil(detection.screenContaining(.zero, screens: available))
        XCTAssertTrue(detection.isAvailable(right))
        available = [left]
        XCTAssertFalse(detection.isAvailable(right))
        available = [Screen(CGRect(x: 0, y: 0, width: CGFloat.infinity, height: 100))]
        XCTAssertNil(detection.detectScreens(using: nil))
        available = []
        XCTAssertNil(detection.detectScreensAtCursor())
        XCTAssertEqual(CGRect(x: 1, y: 2, width: 3, height: 4).screenFlipped(primaryScreenMaxY: nil),
                       CGRect(x: 1, y: 2, width: 3, height: 4))
    }

    func testUnmatchedWindowUsesOrderedFallbackWithRealNeighbors() throws {
        let saved = Defaults.screensOrderedByX.value
        defer { Defaults.screensOrderedByX.value = saved }
        Defaults.screensOrderedByX.value = .minX
        let left = Screen(CGRect(x: -600, y: 0, width: 600, height: 400))
        let middle = Screen(CGRect(x: 0, y: 0, width: 600, height: 400))
        let right = Screen(CGRect(x: 600, y: 0, width: 600, height: 400))
        let screens = try XCTUnwrap(ScreenDetection(screens: { [right, middle, left] }).detectScreens(using: nil))
        XCTAssertTrue(screens.currentScreen === left)
        XCTAssertTrue(screens.adjacentScreens?.next === middle)
        XCTAssertTrue(screens.adjacentScreens?.prev === right)
    }

    private func display(current: Any = NSNumber(value: 10), spaces: [[String: Any]]? = nil) -> [String: Any] {
        ["Display Identifier": "A", "Current Space": ["id64": current],
         "Spaces": spaces ?? [["id64": 10, "type": 0], ["id64": 20, "type": 0]]]
    }

    func testMalformedTopologyCannotRedirectNumberedOrAdjacentCommands() {
        let invalid = [
            display(current: NSNumber(value: 10.5)), display(current: NSNumber(value: -1)),
            display(spaces: [["id64": 10, "type": 0], ["type": 0]]),
            display(spaces: [["id64": 10, "type": 0], ["id64": 10, "type": 0]]),
            display(spaces: [["id64": 10, "type": 0], ["id64": -20, "type": 0]]),
            display(spaces: [["id64": 10, "type": 0.5], ["id64": 20, "type": 0]]),
            display(spaces: [["id64": 10, "type": 0], ["id64": Double.infinity, "type": 0]])
        ]
        for raw in invalid {
            XCTAssertFalse(ManagedSpaceTopology.isValid([raw]))
            XCTAssertNil(ManagedSpaceTopology.desktop(number: 1, in: [raw]))
            XCTAssertNil(ManagedSpaceTopology.adjacent(to: [10], direction: .next, on: "A", in: [raw]))
        }
        XCTAssertFalse(ManagedSpaceTopology.isValid([display(), display()]))
    }

    func testDragFallbackRejectsAnInterveningFullScreenSpace() {
        let raw = [display(spaces: [["id64": 10, "type": 0], ["id64": 15, "type": 4], ["id64": 20, "type": 0]])]
        XCTAssertEqual(ManagedSpaceTopology.adjacent(to: [10], direction: .next, on: "A", in: raw)?.destinationID, 20)
        XCTAssertNil(ManagedSpaceTopology.adjacentForGesture(to: [10], direction: .next, on: "A", in: raw))
        XCTAssertEqual(ManagedSpaceTopology.adjacentForGesture(to: [10], direction: .next, on: "A", in: [display()])?.destinationID, 20)
    }

    func testInvalidSavedSpaceShortcutUsesSafeDefaults() throws {
        let name = "Rectangle.SpaceDisplayReliabilityTests.\(UUID().uuidString)"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: name))
        defer { defaults.removePersistentDomain(forName: name) }
        defaults.set(-1, forKey: "nextSpaceSwitchKeyCode")
        defaults.set(100_000, forKey: "previousSpaceSwitchKeyCode")
        defaults.set(-1, forKey: "spaceSwitchModifierFlags")
        XCTAssertEqual(CoreGraphicsSpaceMoveEventPoster.systemShortcut(for: .next, defaults: defaults).0, 124)
        XCTAssertEqual(CoreGraphicsSpaceMoveEventPoster.systemShortcut(for: .previous, defaults: defaults).0, 123)
        XCTAssertEqual(CoreGraphicsSpaceMoveEventPoster.systemShortcut(for: .next, defaults: defaults).1, [.maskControl, .maskSecondaryFn])
    }

    func testSpecificDisplayPreservesAutoMaximizeLikeNextDisplay() {
        let saved = Defaults.autoMaximize.toCodable()
        defer { Defaults.autoMaximize.load(from: saved) }
        Defaults.autoMaximize.enabled = true
        let rect = CGRect(x: 10, y: 20, width: 300, height: 200)
        let bounds = CGRect(x: 600, y: -400, width: 1200, height: 900)
        let params = RectCalculationParameters(window: Window(id: nil, rect: rect), visibleFrameOfScreen: bounds,
                                               action: .displayTwo, lastAction: RectangleAction(action: .maximize, rect: rect))
        XCTAssertEqual(SpecificDisplayCalculation().calculateRect(params).rect, NextPrevDisplayCalculation().calculateRect(params).rect)
        XCTAssertEqual(SpecificDisplayCalculation().calculateRect(params).resultingAction, .maximize)
    }

    func testPreviousDisplayMoveIsNotReplayedAsACenterAction() throws {
        let settings: [(Default, CodableDefault)] = [
            (Defaults.attemptMatchOnNextPrevDisplay, CodableDefault(int: 1)),
            (Defaults.centerAcrossDisplays, CodableDefault(int: 1)),
            (Defaults.combinedDisplayMode, CodableDefault(int: 2)),
            (Defaults.stageSize, CodableDefault(float: 0)), (Defaults.todo, CodableDefault(int: 2)),
            (Defaults.screenEdgeGapLeft, CodableDefault(float: 0)), (Defaults.screenEdgeGapRight, CodableDefault(float: 0)),
            (Defaults.screenEdgeGapTop, CodableDefault(float: 0)), (Defaults.screenEdgeGapBottom, CodableDefault(float: 0))
        ]
        let saved = settings.map { ($0.0, $0.0.toCodable()) }
        defer { saved.forEach { $0.0.load(from: $0.1) } }
        settings.forEach { $0.0.load(from: $0.1) }
        let source = Screen(CGRect(x: 0, y: 0, width: 1000, height: 800))
        let destination = Screen(CGRect(x: 1000, y: 0, width: 1200, height: 900))
        let window = CGRect(x: 100, y: 100, width: 200, height: 200)
        let screens = UsableScreens(currentScreen: source, adjacentScreens: AdjacentScreens(prev: destination, next: destination),
                                    numScreens: 2, screensOrdered: [source, destination])
        for action in [WindowAction.nextDisplay, .displayTwo] {
            let params = WindowCalculationParameters(window: Window(id: nil, rect: window), usableScreens: screens,
                action: action, lastAction: RectangleAction(action: .nextDisplay, rect: window.screenFlipped), ignoreTodo: true)
            let calculation: WindowCalculation = action == .nextDisplay ? NextPrevDisplayCalculation() : SpecificDisplayCalculation()
            let result = try XCTUnwrap(calculation.calculate(params))
            XCTAssertEqual(result.rect, NextPrevDisplayCalculation.relativePositionedRect(window: window,
                source: source.adjustedVisibleFrame(true), destination: destination.adjustedVisibleFrame(true)))
            XCTAssertEqual(result.resultingAction, action)
        }
    }
}

final class NextPrevDisplayMappingTests: XCTestCase {
    // The opt-in is NOT needed to test the pure helper; setUp/tearDown still save & restore it
    // so the wiring tests below are isolated from host state.
    private var savedOptIn: Bool?

    override func setUp() {
        super.setUp()
        savedOptIn = Defaults.attemptMatchOnNextPrevDisplay.enabled
        Defaults.attemptMatchOnNextPrevDisplay.enabled = true
    }

    override func tearDown() {
        Defaults.attemptMatchOnNextPrevDisplay.enabled = savedOptIn
        super.tearDown()
    }

    // --- Helper-level: RED until relativePositionedRect exists, then GREEN ---

    func testRelativePositionedRectMapsRightThirdToRightThird() {
        // Issue #1723 repro geometry: a window pinned to the right third (full height) of a
        // 3000x2000 source must land at the right third of a 1500x1000 destination.
        let source      = CGRect(x: 0,    y: 0,    width: 3000, height: 2000)
        let window      = CGRect(x: 2000, y: 0,    width: 1000, height: 2000)
        let destination = CGRect(x: 0,    y: 0,    width: 1500, height: 1000)

        XCTAssertEqual(
            NextPrevDisplayCalculation.relativePositionedRect(window: window, source: source, destination: destination),
            CGRect(x: 1000, y: 0, width: 500, height: 1000)
        )
    }

    func testRelativePositionedRectPreservesCenteredQuarter() {
        // A centered-quarter window stays a centered quarter after the cross-display map.
        let source      = CGRect(x: 0,   y: 0,   width: 2560, height: 1440)
        let window      = CGRect(x: 960, y: 360, width: 640,  height: 720)   // centered quarter
        let destination = CGRect(x: 0,   y: 0,   width: 1280, height: 720)

        XCTAssertEqual(
            NextPrevDisplayCalculation.relativePositionedRect(window: window, source: source, destination: destination),
            CGRect(x: 480, y: 180, width: 320, height: 360)
        )
    }

    func testRelativePositionedRectClampsOverflowIntoDestination() {
        // Window occupies 60% width starting at the 50% mark on a 1000x1000 source.
        // Mapped onto a 500x500 destination: width 300 @ x 250 -> maxX 550 > 500 -> clamp to x 200.
        let source      = CGRect(x: 0,   y: 0, width: 1000, height: 1000)
        let window      = CGRect(x: 500, y: 0, width: 600,  height: 1000)
        let destination = CGRect(x: 0,   y: 0, width: 500,  height: 500)

        XCTAssertEqual(
            NextPrevDisplayCalculation.relativePositionedRect(window: window, source: source, destination: destination),
            CGRect(x: 200, y: 0, width: 300, height: 500)
        )
    }

    func testRelativePositionedRectIsIdentityWhenSourceEqualsDestination() {
        let frame = CGRect(x: 0,   y: 0,   width: 2000, height: 1000)
        let window = CGRect(x: 300, y: 200, width: 500, height: 600)

        XCTAssertEqual(
            NextPrevDisplayCalculation.relativePositionedRect(window: window, source: frame, destination: frame),
            window
        )
    }

    func testOversizedWindowIsReducedToFitDestination() {
        let source = CGRect(x: -1000, y: -300, width: 1000, height: 600)
        let destination = CGRect(x: 100, y: 50, width: 500, height: 400)
        let window = CGRect(x: -1200, y: -500, width: 1400, height: 1000)
        XCTAssertEqual(NextPrevDisplayCalculation.relativePositionedRect(window: window, source: source, destination: destination), destination)
    }
}

class HalvesPreserveOtherAxisSizeTests: XCTestCase {

    private var savedHalvesPreserveOtherAxisSize = false
    private var savedGapSize: Float = 0
    private var savedSkipGapTopEdge = false
    private var savedHorizontalSplitRatio: Float = 50
    private var savedVerticalSplitRatio: Float = 50
    private var savedSubsequentExecutionMode: SubsequentExecutionMode = .resize
    private var savedCycleSizesIsChanged = false
    private var savedCooperativeCornerResize = false

    private let visibleFrame = CGRect(x: 10, y: 20, width: 1200, height: 900)
    // Ungapped rects that the half and quarter actions produce on `visibleFrame` at the default 50% split.
    private let leftHalf = CGRect(x: 10, y: 20, width: 600, height: 900)
    private let rightHalf = CGRect(x: 610, y: 20, width: 600, height: 900)
    private let topHalf = CGRect(x: 10, y: 470, width: 1200, height: 450)
    private let bottomHalf = CGRect(x: 10, y: 20, width: 1200, height: 450)
    private let topLeftQuarter = CGRect(x: 10, y: 470, width: 600, height: 450)
    private let topRightQuarter = CGRect(x: 610, y: 470, width: 600, height: 450)
    private let bottomLeftQuarter = CGRect(x: 10, y: 20, width: 600, height: 450)
    private let bottomRightQuarter = CGRect(x: 610, y: 20, width: 600, height: 450)

    override func setUp() {
        super.setUp()
        savedHalvesPreserveOtherAxisSize = Defaults.halvesPreserveOtherAxisSize.enabled
        savedGapSize = Defaults.gapSize.value
        savedSkipGapTopEdge = Defaults.skipGapTopEdge.enabled
        savedHorizontalSplitRatio = Defaults.horizontalSplitRatio.value
        savedVerticalSplitRatio = Defaults.verticalSplitRatio.value
        savedSubsequentExecutionMode = Defaults.subsequentExecutionMode.value
        savedCycleSizesIsChanged = Defaults.cycleSizesIsChanged.enabled
        savedCooperativeCornerResize = Defaults.cooperativeCornerResize.enabled
        Defaults.halvesPreserveOtherAxisSize.enabled = true
        Defaults.gapSize.value = 0
        Defaults.skipGapTopEdge.enabled = false
        Defaults.horizontalSplitRatio.value = 50
        Defaults.verticalSplitRatio.value = 50
        Defaults.subsequentExecutionMode.value = .resize
        Defaults.cycleSizesIsChanged.enabled = false
        Defaults.cooperativeCornerResize.enabled = false
        ActiveSideSplitRatios.shared.resetAll()
    }

    override func tearDown() {
        Defaults.halvesPreserveOtherAxisSize.enabled = savedHalvesPreserveOtherAxisSize
        Defaults.gapSize.value = savedGapSize
        Defaults.skipGapTopEdge.enabled = savedSkipGapTopEdge
        Defaults.horizontalSplitRatio.value = savedHorizontalSplitRatio
        Defaults.verticalSplitRatio.value = savedVerticalSplitRatio
        Defaults.subsequentExecutionMode.value = savedSubsequentExecutionMode
        Defaults.cycleSizesIsChanged.enabled = savedCycleSizesIsChanged
        Defaults.cooperativeCornerResize.enabled = savedCooperativeCornerResize
        ActiveSideSplitRatios.shared.resetAll()
        super.tearDown()
    }

    // MARK: A half action keeps the other axis: Left + Top = top left quarter, in either order

    func testTopHalfKeepsLeftHalfColumn() {
        assertTiled(.topHalf, from: leftHalf, gives: topLeftQuarter, as: .topLeft, subAction: .topLeftQuarter)
    }

    func testLeftHalfKeepsTopHalfRow() {
        assertTiled(.leftHalf, from: topHalf, gives: topLeftQuarter, as: .topLeft, subAction: .topLeftQuarter)
    }

    func testBottomHalfKeepsRightHalfColumn() {
        assertTiled(.bottomHalf, from: rightHalf, gives: bottomRightQuarter, as: .bottomRight, subAction: .bottomRightQuarter)
    }

    func testRightHalfKeepsBottomHalfRow() {
        assertTiled(.rightHalf, from: bottomHalf, gives: bottomRightQuarter, as: .bottomRight, subAction: .bottomRightQuarter)
    }

    func testTopHalfKeepsRightHalfColumn() {
        assertTiled(.topHalf, from: rightHalf, gives: topRightQuarter, as: .topRight, subAction: .topRightQuarter)
    }

    func testBottomHalfKeepsLeftHalfColumn() {
        assertTiled(.bottomHalf, from: leftHalf, gives: bottomLeftQuarter, as: .bottomLeft, subAction: .bottomLeftQuarter)
    }

    // MARK: The action for the opposite edge expands the window along that axis

    func testBottomHalfExpandsTopLeftQuarterToLeftHalf() {
        assertTiled(.bottomHalf, from: topLeftQuarter, gives: leftHalf, as: .leftHalf)
    }

    func testTopHalfExpandsBottomLeftQuarterToLeftHalf() {
        assertTiled(.topHalf, from: bottomLeftQuarter, gives: leftHalf, as: .leftHalf)
    }

    func testRightHalfExpandsTopLeftQuarterToTopHalf() {
        assertTiled(.rightHalf, from: topLeftQuarter, gives: topHalf, as: .topHalf)
    }

    func testLeftHalfExpandsBottomRightQuarterToBottomHalf() {
        assertTiled(.leftHalf, from: bottomRightQuarter, gives: bottomHalf, as: .bottomHalf)
    }

    func testLeftHalfExpandsRightHalfToFullScreen() {
        assertTiled(.leftHalf, from: rightHalf, gives: visibleFrame, as: .maximize)
    }

    func testTopHalfExpandsBottomHalfToFullScreen() {
        assertTiled(.topHalf, from: bottomHalf, gives: visibleFrame, as: .maximize)
    }

    // MARK: The action for the edge a quarter is docked to cycles sizes along its own axis

    func testLeftHalfCyclesWidthOfTopLeftQuarter() {
        let twoThirdsWide = CGRect(x: 10, y: 470, width: 800, height: 450)
        let oneThirdWide = CGRect(x: 10, y: 470, width: 400, height: 450)

        assertTiled(.leftHalf, from: topLeftQuarter, gives: twoThirdsWide, as: .topLeft, subAction: .topLeftQuarter)
        assertTiled(.leftHalf, from: twoThirdsWide, gives: oneThirdWide, as: .topLeft, subAction: .topLeftQuarter)
        assertTiled(.leftHalf, from: oneThirdWide, gives: topLeftQuarter, as: .topLeft, subAction: .topLeftQuarter)
    }

    func testRightHalfCyclesWidthOfBottomRightQuarterFromItsEdge() {
        assertTiled(.rightHalf, from: bottomRightQuarter,
                    gives: CGRect(x: 410, y: 20, width: 800, height: 450), as: .bottomRight, subAction: .bottomRightQuarter)
    }

    func testTopHalfCyclesHeightOfTopLeftQuarter() {
        let twoThirdsHigh = CGRect(x: 10, y: 320, width: 600, height: 600)
        let oneThirdHigh = CGRect(x: 10, y: 620, width: 600, height: 300)

        assertTiled(.topHalf, from: topLeftQuarter, gives: twoThirdsHigh, as: .topLeft, subAction: .topLeftQuarter)
        assertTiled(.topHalf, from: twoThirdsHigh, gives: oneThirdHigh, as: .topLeft, subAction: .topLeftQuarter)
        assertTiled(.topHalf, from: oneThirdHigh, gives: topLeftQuarter, as: .topLeft, subAction: .topLeftQuarter)
    }

    func testBottomHalfCyclesHeightOfBottomRightQuarterFromItsEdge() {
        assertTiled(.bottomHalf, from: bottomRightQuarter,
                    gives: CGRect(x: 610, y: 20, width: 600, height: 600), as: .bottomRight, subAction: .bottomRightQuarter)
    }

    func testCyclingInsideQuarterUsesSelectedCycleSizes() {
        let savedSelectedCycleSizes = Defaults.selectedCycleSizes.value
        defer { Defaults.selectedCycleSizes.value = savedSelectedCycleSizes }
        Defaults.cycleSizesIsChanged.enabled = true
        Defaults.selectedCycleSizes.value = [.twoThirds, .oneQuarter]

        let twoThirdsWide = CGRect(x: 10, y: 470, width: 800, height: 450)
        let oneQuarterWide = CGRect(x: 10, y: 470, width: 300, height: 450)

        // One half is not selected: the cycle starts at the first selected size and never returns to one half.
        assertTiled(.leftHalf, from: topLeftQuarter, gives: twoThirdsWide, as: .topLeft, subAction: .topLeftQuarter)
        assertTiled(.leftHalf, from: twoThirdsWide, gives: oneQuarterWide, as: .topLeft, subAction: .topLeftQuarter)
        assertTiled(.leftHalf, from: oneQuarterWide, gives: twoThirdsWide, as: .topLeft, subAction: .topLeftQuarter)
    }

    func testCyclingInsideQuarterStartsOverFromCustomSplitRatio() {
        Defaults.horizontalSplitRatio.value = 60
        let sixtyPercentWide = CGRect(x: 10, y: 470, width: 720, height: 450)

        assertTiled(.leftHalf, from: sixtyPercentWide, gives: topLeftQuarter, as: .topLeft, subAction: .topLeftQuarter)
    }

    func testCyclingInsideQuarterRecognizesGappedWindow() {
        Defaults.gapSize.value = 20
        let gappedTopLeftQuarter = GapCalculation.applyGaps(topLeftQuarter, dimension: .both, sharedEdges: [.right, .bottom], gapSize: 20, skipTopGap: false)

        assertTiled(.leftHalf, from: gappedTopLeftQuarter,
                    gives: CGRect(x: 10, y: 470, width: 800, height: 450), as: .topLeft, subAction: .topLeftQuarter)
    }

    func testQuarterStaysPutWhenRepeatedCommandsDoNotResize() {
        for mode in [SubsequentExecutionMode.none, .acrossMonitor, .cycleMonitor] {
            Defaults.subsequentExecutionMode.value = mode
            assertTiled(.leftHalf, from: topLeftQuarter, gives: topLeftQuarter, as: .topLeft, subAction: .topLeftQuarter)
            assertTiled(.topHalf, from: topLeftQuarter, gives: topLeftQuarter, as: .topLeft, subAction: .topLeftQuarter)
        }
    }

    func testQuarterStaysPutWhenNoCycleSizesAreSelected() {
        let savedSelectedCycleSizes = Defaults.selectedCycleSizes.value
        defer { Defaults.selectedCycleSizes.value = savedSelectedCycleSizes }
        Defaults.cycleSizesIsChanged.enabled = true
        Defaults.selectedCycleSizes.value = []

        assertTiled(.leftHalf, from: topLeftQuarter, gives: topLeftQuarter, as: .topLeft, subAction: .topLeftQuarter)
    }

    func testRepeatedTopHalfInsideQuarterCyclesHeightWithoutHistory() {
        let params = params(for: .topHalf, windowRect: topLeftQuarter,
                            lastAction: RectangleAction(action: .topLeft, subAction: .topLeftQuarter, rect: topLeftQuarter, count: 5))

        let result = WindowCalculationFactory.topHalfCalculation.calculateRect(params)

        XCTAssertEqual(result.rect, CGRect(x: 10, y: 320, width: 600, height: 600))
        XCTAssertEqual(result.resultingAction, .topLeft)
        XCTAssertEqual(result.subAction, .topLeftQuarter)
    }

    // MARK: Plain halves and windows that are not tiled behave as without the feature

    func testPlainHalvesRepeatAsUsual() {
        XCTAssertNil(tiled(.leftHalf, from: leftHalf))
        XCTAssertNil(tiled(.rightHalf, from: rightHalf))
        XCTAssertNil(tiled(.topHalf, from: topHalf))
        XCTAssertNil(tiled(.bottomHalf, from: bottomHalf))
    }

    func testRepeatedPlainTopHalfStillCyclesHeight() {
        let params = params(for: .topHalf, windowRect: topHalf,
                            lastAction: RectangleAction(action: .topHalf, subAction: nil, rect: topHalf, count: 1))

        let result = WindowCalculationFactory.topHalfCalculation.calculateRect(params)

        XCTAssertEqual(result.rect, CGRect(x: 10, y: 320, width: 1200, height: 600))
    }

    func testUntiledWindowsAreNotAffected() {
        let floating = CGRect(x: 300, y: 100, width: 700, height: 500)
        let centeredColumn = CGRect(x: 310, y: 20, width: 600, height: 900)

        for action in [WindowAction.leftHalf, .rightHalf, .topHalf, .bottomHalf] {
            XCTAssertNil(tiled(action, from: floating), "\(action)")
            XCTAssertNil(tiled(action, from: visibleFrame), "\(action)")
        }
        XCTAssertNil(tiled(.topHalf, from: centeredColumn))
    }

    func testTopHalfCalculationFallsBackToDefaultBehaviorForUntiledWindows() {
        let result = WindowCalculationFactory.topHalfCalculation.calculateRect(params(for: .topHalf, windowRect: CGRect(x: 300, y: 100, width: 700, height: 500)))

        XCTAssertEqual(result.rect, topHalf)
        XCTAssertNil(result.resultingAction)
        XCTAssertNil(result.subAction)
    }

    func testTopHalfCalculationTilesWhenEnabled() {
        let result = WindowCalculationFactory.topHalfCalculation.calculateRect(params(for: .topHalf, windowRect: leftHalf))

        XCTAssertEqual(result.rect, topLeftQuarter)
        XCTAssertEqual(result.resultingAction, .topLeft)
        XCTAssertEqual(result.subAction, .topLeftQuarter)
    }

    func testBottomHalfCalculationTilesWhenEnabled() {
        let result = WindowCalculationFactory.bottomHalfCalculation.calculateRect(params(for: .bottomHalf, windowRect: topLeftQuarter))

        XCTAssertEqual(result.rect, leftHalf)
        XCTAssertEqual(result.resultingAction, .leftHalf)
    }

    func testDisabledFeatureKeepsFullWidthTopHalf() {
        Defaults.halvesPreserveOtherAxisSize.enabled = false

        let result = WindowCalculationFactory.topHalfCalculation.calculateRect(params(for: .topHalf, windowRect: leftHalf))

        XCTAssertEqual(result.rect, topHalf)
        XCTAssertNil(result.resultingAction)
        XCTAssertNil(result.subAction)
    }

    // MARK: Columns and rows other than exactly one half

    func testTopHalfKeepsCycledTwoThirdsColumn() {
        assertTiled(.topHalf, from: CGRect(x: 10, y: 20, width: 800, height: 900),
                    gives: CGRect(x: 10, y: 470, width: 800, height: 450), as: .topLeft, subAction: .topLeftQuarter)
    }

    func testBottomHalfExpandsTwoThirdsWideTopLeftQuarterToTwoThirdsColumn() {
        assertTiled(.bottomHalf, from: CGRect(x: 10, y: 470, width: 800, height: 450),
                    gives: CGRect(x: 10, y: 20, width: 800, height: 900), as: .leftHalf)
    }

    func testLeftHalfKeepsCycledTopThirdRow() {
        assertTiled(.leftHalf, from: CGRect(x: 10, y: 620, width: 1200, height: 300),
                    gives: CGRect(x: 10, y: 620, width: 600, height: 300), as: .topLeft, subAction: .topLeftQuarter)
    }

    func testTopHalfKeepsRightThirdColumn() {
        assertTiled(.topHalf, from: CGRect(x: 810, y: 20, width: 400, height: 900),
                    gives: CGRect(x: 810, y: 470, width: 400, height: 450), as: .topRight, subAction: .topRightQuarter)
    }

    func testCustomSplitRatioIsUsedForRecognitionAndResults() {
        Defaults.horizontalSplitRatio.value = 60

        assertTiled(.topHalf, from: CGRect(x: 10, y: 20, width: 720, height: 900),
                    gives: CGRect(x: 10, y: 470, width: 720, height: 450), as: .topLeft, subAction: .topLeftQuarter)
        assertTiled(.topHalf, from: CGRect(x: 730, y: 20, width: 480, height: 900),
                    gives: CGRect(x: 730, y: 470, width: 480, height: 450), as: .topRight, subAction: .topRightQuarter)
        assertTiled(.leftHalf, from: topHalf,
                    gives: CGRect(x: 10, y: 470, width: 720, height: 450), as: .topLeft, subAction: .topLeftQuarter)
    }

    // MARK: Gaps and tolerance

    func testRecognizesGappedColumnAndReturnsUngappedRect() {
        Defaults.gapSize.value = 20
        // Left half with gaps applied by WindowManager: inset 20 on each side, half a gap back on the shared right edge.
        let gappedLeftHalf = CGRect(x: 30, y: 40, width: 570, height: 860)

        assertTiled(.topHalf, from: gappedLeftHalf, gives: topLeftQuarter, as: .topLeft, subAction: .topLeftQuarter)
    }

    func testRecognizesGappedRowWithSkippedTopGap() {
        Defaults.gapSize.value = 20
        Defaults.skipGapTopEdge.enabled = true
        let gappedTopHalf = GapCalculation.applyGaps(topHalf, dimension: .both, sharedEdges: .bottom, gapSize: 20, skipTopGap: true)

        assertTiled(.leftHalf, from: gappedTopHalf, gives: topLeftQuarter, as: .topLeft, subAction: .topLeftQuarter)
    }

    func testToleratesWindowsThatCannotTakeTheExactSize() {
        assertTiled(.topHalf, from: CGRect(x: 10, y: 20, width: 594, height: 900),
                    gives: topLeftQuarter, as: .topLeft, subAction: .topLeftQuarter)
    }

    func testDoesNotMatchWindowsFarFromAnyColumn() {
        XCTAssertNil(tiled(.topHalf, from: CGRect(x: 10, y: 20, width: 560, height: 900)))
    }

    // MARK: Helpers

    private func tiled(_ action: WindowAction, from windowRect: CGRect) -> RectResult? {
        HalvesPreserveOtherAxisSize.rect(for: params(for: action, windowRect: windowRect))
    }

    private func assertTiled(_ action: WindowAction,
                             from windowRect: CGRect,
                             gives expectedRect: CGRect,
                             as expectedAction: WindowAction,
                             subAction expectedSubAction: SubWindowAction? = nil,
                             file: StaticString = #filePath,
                             line: UInt = #line) {
        guard let result = tiled(action, from: windowRect) else {
            XCTFail("\(action) from \(windowRect) fell back to the default behavior", file: file, line: line)
            return
        }
        XCTAssertEqual(result.rect, expectedRect, file: file, line: line)
        XCTAssertEqual(result.resultingAction, expectedAction, file: file, line: line)
        XCTAssertEqual(result.subAction, expectedSubAction, file: file, line: line)
    }

    private func params(for action: WindowAction, windowRect: CGRect, lastAction: RectangleAction? = nil) -> RectCalculationParameters {
        RectCalculationParameters(window: Window(id: 1, rect: windowRect),
                                  visibleFrameOfScreen: visibleFrame,
                                  action: action,
                                  lastAction: lastAction)
    }
}

class RepeatedMaximizeRestoreTests: XCTestCase {

    private var savedRepeatedMaximizeRestoresPrevious = false

    private let windowId = CGWindowID(24_680)
    private let screen = RepeatedMaximizeTestScreen(frame: CGRect(x: 0, y: 0, width: 1440, height: 900))
    private let previousFrame = CGRect(x: 100, y: 100, width: 800, height: 600)
    private let maximizedFrame = CGRect(x: 0, y: 25, width: 1440, height: 875)
    private let almostMaximizedFrame = CGRect(x: 72, y: 69, width: 1296, height: 788)

    override func setUp() {
        super.setUp()
        savedRepeatedMaximizeRestoresPrevious = Defaults.repeatedMaximizeRestoresPrevious.enabled
        Defaults.repeatedMaximizeRestoresPrevious.enabled = true
    }

    override func tearDown() {
        Defaults.repeatedMaximizeRestoresPrevious.enabled = savedRepeatedMaximizeRestoresPrevious
        AppDelegate.windowHistory.preMaximizeRects.removeValue(forKey: windowId)
        AppDelegate.windowHistory.lastRectangleActions.removeValue(forKey: windowId)
        super.tearDown()
    }

    func testAppliesToMaximizeAndAlmostMaximizeOnly() {
        XCTAssertTrue(RepeatedMaximizeRestore.applies(to: .maximize))
        XCTAssertTrue(RepeatedMaximizeRestore.applies(to: .almostMaximize))
        XCTAssertFalse(RepeatedMaximizeRestore.applies(to: .maximizeHeight))
        XCTAssertFalse(RepeatedMaximizeRestore.applies(to: .leftHalf))
        XCTAssertFalse(RepeatedMaximizeRestore.applies(to: .restore))
    }

    func testRepeatedMaximizeRestoresThePreviousFrame() {
        XCTAssertEqual(restoreRect(.maximize, window: maximizedFrame, last: .maximize, lastRect: maximizedFrame), previousFrame)
        XCTAssertEqual(restoreRect(.almostMaximize, window: almostMaximizedFrame, last: .almostMaximize, lastRect: almostMaximizedFrame), previousFrame)
    }

    func testDoesNothingWhenDisabled() {
        Defaults.repeatedMaximizeRestoresPrevious.enabled = false
        XCTAssertNil(restoreRect(.maximize, window: maximizedFrame, last: .maximize, lastRect: maximizedFrame))
    }

    func testDoesNothingWhenTheLastActionWasAnotherOne() {
        XCTAssertNil(restoreRect(.maximize, window: almostMaximizedFrame, last: .almostMaximize, lastRect: almostMaximizedFrame))
        XCTAssertNil(restoreRect(.almostMaximize, window: maximizedFrame, last: .maximize, lastRect: maximizedFrame))
        XCTAssertNil(restoreRect(.maximize, window: maximizedFrame, last: .leftHalf, lastRect: maximizedFrame))
    }

    func testDoesNothingWithoutHistory() {
        XCTAssertNil(restoreRect(.maximize, window: maximizedFrame, last: nil, lastRect: nil))
        XCTAssertNil(restoreRect(.maximize, window: maximizedFrame, last: .maximize, lastRect: maximizedFrame, previous: nil))
    }

    func testDoesNothingWhenTheWindowMovedSinceTheLastAction() {
        let moved = maximizedFrame.offsetBy(dx: 0, dy: 10)
        XCTAssertNil(restoreRect(.maximize, window: moved, last: .maximize, lastRect: maximizedFrame))
    }

    func testIgnoresOtherActions() {
        XCTAssertNil(restoreRect(.maximizeHeight, window: maximizedFrame, last: .maximizeHeight, lastRect: maximizedFrame))
    }

    // MARK: - Calculation entry point

    func testRecordsThePreviousFrameAndFallsThroughWhenMaximizing() {
        let params = calculationParams(.maximize, window: previousFrame, last: nil)

        XCTAssertNil(RepeatedMaximizeRestore.calculate(params))
        XCTAssertEqual(AppDelegate.windowHistory.preMaximizeRects[windowId], previousFrame.screenFlipped)
    }

    func testRestoresAsTheRestoreAction() {
        AppDelegate.windowHistory.preMaximizeRects[windowId] = previousFrame.screenFlipped
        let params = calculationParams(.maximize, window: maximizedFrame, last: .maximize, lastRect: maximizedFrame)

        let result = RepeatedMaximizeRestore.calculate(params)

        XCTAssertEqual(result?.rect, previousFrame.screenFlipped)
        XCTAssertEqual(result?.resultingAction, .restore)
    }

    func testAlmostMaximizeRestoresTheSameWay() {
        AppDelegate.windowHistory.preMaximizeRects[windowId] = previousFrame.screenFlipped
        let params = calculationParams(.almostMaximize, window: almostMaximizedFrame, last: .almostMaximize, lastRect: almostMaximizedFrame)

        let result = RepeatedMaximizeRestore.calculate(params)

        XCTAssertEqual(result?.rect, previousFrame.screenFlipped)
        XCTAssertEqual(result?.resultingAction, .restore)
    }

    func testMaximizesAgainAfterARestore() {
        AppDelegate.windowHistory.preMaximizeRects[windowId] = maximizedFrame.screenFlipped
        // The restore reported .restore, so the window's last action is no longer the maximize.
        let params = calculationParams(.maximize, window: previousFrame, last: .restore, lastRect: previousFrame)

        XCTAssertNil(RepeatedMaximizeRestore.calculate(params))
        XCTAssertEqual(AppDelegate.windowHistory.preMaximizeRects[windowId], previousFrame.screenFlipped)
    }

    func testRecordsNothingWhenDisabled() {
        Defaults.repeatedMaximizeRestoresPrevious.enabled = false
        let params = calculationParams(.maximize, window: previousFrame, last: nil)

        XCTAssertNil(RepeatedMaximizeRestore.calculate(params))
        XCTAssertNil(AppDelegate.windowHistory.preMaximizeRects[windowId])
    }

    func testMaximizeCalculationRestoresThroughTheHelper() {
        AppDelegate.windowHistory.preMaximizeRects[windowId] = previousFrame.screenFlipped
        let params = calculationParams(.maximize, window: maximizedFrame, last: .maximize, lastRect: maximizedFrame)

        let result = WindowCalculationFactory.maximizeCalculation.calculate(params)

        XCTAssertEqual(result?.rect, previousFrame.screenFlipped)
        XCTAssertEqual(result?.resultingAction, .restore)
    }

    // MARK: - Helpers

    private func restoreRect(_ action: WindowAction,
                             window: CGRect,
                             last: WindowAction?,
                             lastRect: CGRect?,
                             previous: CGRect? = CGRect(x: 100, y: 100, width: 800, height: 600)) -> CGRect? {
        RepeatedMaximizeRestore.restoreRect(for: action,
                                            windowRect: window.screenFlipped,
                                            lastAction: rectangleAction(last, lastRect),
                                            preMaximizeRect: previous)
    }

    private func calculationParams(_ action: WindowAction,
                                   window: CGRect,
                                   last: WindowAction?,
                                   lastRect: CGRect? = nil) -> WindowCalculationParameters {
        WindowCalculationParameters(window: Window(id: windowId, rect: window.screenFlipped),
                                    usableScreens: UsableScreens(currentScreen: screen, numScreens: 1),
                                    action: action,
                                    lastAction: rectangleAction(last, lastRect),
                                    ignoreTodo: false)
    }

    private func rectangleAction(_ action: WindowAction?, _ rect: CGRect?) -> RectangleAction? {
        action.map { RectangleAction(action: $0, subAction: nil, rect: rect ?? .null, count: 1) }
    }
}

private final class RepeatedMaximizeTestScreen: NSScreen {
    private let testFrame: CGRect

    init(frame: CGRect) {
        testFrame = frame
        super.init()
    }

    override var frame: NSRect { testFrame }
    override var visibleFrame: NSRect { testFrame }
    override var safeAreaInsets: NSEdgeInsets { NSEdgeInsetsZero }
    override var hash: Int { ObjectIdentifier(self).hashValue }

    override func isEqual(_ object: Any?) -> Bool {
        (object as AnyObject?) === self
    }
}


class NumberedSpaceSwitcherTests: XCTestCase {
    private final class ActivationSpy: ManagedDisplaySpaceActivating {
        var isAvailable = true
        var current: UInt64 = 57
        var visible = true
        var submitted = true
        var hasDesktop = true
        var calls = [ManagedDisplaySpaceSwitch]()
        func desktop(number: Int) -> ManagedDisplaySpaceSwitch? {
            guard hasDesktop else { return nil }
            return ManagedDisplaySpaceSwitch(sourceID: current, destinationID: UInt64(900 + number), displayIdentifier: "B")
        }
        func currentSpace(on displayIdentifier: String) -> UInt64? { current }
        func destinationIsVisible(_ target: ManagedDisplaySpaceSwitch) -> Bool? { visible }
        func activate(_ target: ManagedDisplaySpaceSwitch) -> Bool {
            calls.append(target)
            if submitted { current = target.destinationID }
            return submitted
        }
    }
    private final class Scheduler {
        var actions = [() -> Void]()
        var now: TimeInterval = 0
        func schedule(_ delay: TimeInterval, _ action: @escaping () -> Void) {
            let time = now + delay
            actions.append { self.now = max(self.now, time); action() }
        }
        func next() { if !actions.isEmpty { actions.removeFirst()() } }
        func drain() {
            for _ in 0..<400 {
                if actions.isEmpty { return }
                next()
            }
            XCTFail("Desktop confirmation did not finish")
        }
    }
    private final class Input: SpacePhysicalInputMonitoring {
        var handler: (() -> Void)?
        func start(_ handler: @escaping () -> Void) { self.handler = handler }
        func stop() { handler = nil }
    }
    private func coordinator(_ safe: @escaping () -> Bool = { true }) -> SpaceOperationCoordinator {
        SpaceOperationCoordinator(environmentIsSafe: safe, workspaceNotificationCenter: NotificationCenter())
    }
    private func switcher(_ activation: ActivationSpy, _ scheduler: Scheduler,
                          coordinator: SpaceOperationCoordinator? = nil, input: Input = Input(),
                          authorized: Bool = true, mousePressed: Bool = false) -> NumberedSpaceSwitcher {
        NumberedSpaceSwitcher(activation: activation, coordinator: coordinator ?? self.coordinator(),
                              scheduler: scheduler.schedule, accessibilityAuthorized: { authorized },
                              mousePressed: { mousePressed }, inputMonitor: input, clock: { scheduler.now },
                              workspaceNotificationCenter: NotificationCenter())
    }
    func testNumberedCommandsHaveDistinctStableMetadataAndNoDefaultBindings() {
        for (index, action) in WindowAction.numberedSpaceSwitches.enumerated() {
            XCTAssertEqual(action.rawValue, 136 + index)
            XCTAssertEqual(action.desktopNumber, index + 1)
            XCTAssertEqual(action.displayName, "Switch to Desktop \(index + 1)")
            XCTAssertTrue(WindowAction.active.contains(action))
            XCTAssertFalse(action.resizes)
            XCTAssertFalse(action.isDragSnappable)
            XCTAssertFalse(action.positionCycles)
            XCTAssertEqual(action.gapsApplicable, .none)
            XCTAssertEqual(action.classification, .display)
            XCTAssertNil(action.spectacleDefault)
            XCTAssertNil(action.alternateDefault)
        }
        XCTAssertNil(WindowAction.switchNextSpace.desktopNumber)
        XCTAssertEqual(Set(WindowAction.numberedSpaceSwitches.map(\.name)).count, 9)
    }
    func testDesktopNumbersSpanDisplaysAndExcludeFullscreenSpaces() {
        let displays: [[String: Any]] = [
            ["Display Identifier": "A", "Current Space": ["id64": 99],
             "Spaces": [["id64": 10, "type": 0], ["id64": 99, "type": 4], ["id64": 57, "type": 0]]],
            ["Display Identifier": "B", "Current Space": ["id64": 901],
             "Spaces": [["id64": 900, "type": 0], ["id64": 901, "type": 0]]]
        ]
        XCTAssertEqual(ManagedSpaceTopology.desktop(number: 2, in: displays),
                       ManagedDisplaySpaceSwitch(sourceID: 99, destinationID: 57, displayIdentifier: "A"))
        XCTAssertEqual(ManagedSpaceTopology.desktop(number: 3, in: displays),
                       ManagedDisplaySpaceSwitch(sourceID: 901, destinationID: 900, displayIdentifier: "B"))
        XCTAssertNil(ManagedSpaceTopology.desktop(number: 0, in: displays))
        XCTAssertNil(ManagedSpaceTopology.desktop(number: 5, in: displays))
    }
    func testMalformedTopologyDoesNotRenumberRemainingDesktops() {
        let displays: [[String: Any]] = [
            ["Display Identifier": "A", "Current Space": ["id64": 10],
             "Spaces": [["id64": 10, "type": 0], ["type": 0], ["id64": 57, "type": 0]]]
        ]
        XCTAssertNil(ManagedSpaceTopology.desktop(number: 2, in: displays))
    }
    func testChangingOnlySpaceIDDoesNotReleaseTheOperationLock() {
        let activation = ActivationSpy(), scheduler = Scheduler(), coordinator = coordinator()
        activation.visible = false
        let manager = switcher(activation, scheduler, coordinator: coordinator)
        XCTAssertTrue(manager.execute(parameters: ExecutionParameters(.switchSpaceOne)))
        scheduler.next()
        XCTAssertTrue(manager.isSpaceActionInProgress)
        XCTAssertNil(coordinator.begin())
        activation.visible = true
        scheduler.next()
        scheduler.next()
        XCTAssertTrue(manager.isSpaceActionInProgress)
        scheduler.next()
        XCTAssertFalse(manager.isSpaceActionInProgress)
        XCTAssertNotNil(coordinator.begin())
    }
    func testOverlappingNumberedAndWindowMoveOperationsAreRejected() {
        let activation = ActivationSpy(), scheduler = Scheduler(), coordinator = coordinator()
        let manager = switcher(activation, scheduler, coordinator: coordinator)
        XCTAssertTrue(manager.execute(parameters: ExecutionParameters(.switchSpaceOne)))
        XCTAssertTrue(manager.execute(parameters: ExecutionParameters(.switchSpaceTwo)))
        XCTAssertEqual(activation.calls.count, 1)
        XCTAssertNil(coordinator.begin())
        scheduler.drain()
        XCTAssertNotNil(coordinator.begin())
        let otherOperation = coordinator.begin()
        XCTAssertNotNil(otherOperation)
        XCTAssertTrue(manager.execute(parameters: ExecutionParameters(.switchSpaceTwo)))
        XCTAssertEqual(activation.calls.count, 1)
    }
    func testUnsupportedUntrustedDraggingAndMissionControlDoNotSubmit() {
        for scenario in 0..<4 {
            let activation = ActivationSpy(), scheduler = Scheduler()
            if scenario == 0 { activation.isAvailable = false }
            let manager = switcher(activation, scheduler, coordinator: coordinator { scenario != 3 },
                                   authorized: scenario != 1, mousePressed: scenario == 2)
            XCTAssertTrue(manager.execute(parameters: ExecutionParameters(.switchSpaceOne)))
            XCTAssertTrue(activation.calls.isEmpty)
            XCTAssertFalse(manager.isSpaceActionInProgress)
        }
    }
    func testMissingDesktopAndAlreadyDisplayedDesktopDoNothing() {
        let activation = ActivationSpy(), scheduler = Scheduler()
        let manager = switcher(activation, scheduler)
        activation.hasDesktop = false
        XCTAssertTrue(manager.execute(parameters: ExecutionParameters(.switchSpaceOne)))
        activation.hasDesktop = true
        activation.current = 901
        XCTAssertTrue(manager.execute(parameters: ExecutionParameters(.switchSpaceOne)))
        XCTAssertTrue(activation.calls.isEmpty)
        XCTAssertFalse(manager.isSpaceActionInProgress)
        XCTAssertFalse(manager.execute(parameters: ExecutionParameters(.leftHalf)))
    }
    func testFailedSubmissionReleasesOperationAndInputMonitor() {
        let activation = ActivationSpy(), scheduler = Scheduler(), input = Input(), coordinator = coordinator()
        activation.submitted = false
        let manager = switcher(activation, scheduler, coordinator: coordinator, input: input)
        XCTAssertTrue(manager.execute(parameters: ExecutionParameters(.switchSpaceOne)))
        XCTAssertFalse(manager.isSpaceActionInProgress)
        XCTAssertNil(input.handler)
        XCTAssertNotNil(coordinator.begin())
    }
    func testPartialSwitchRestoresVisibilityAndKeepsLockUntilRecoverySettles() {
        let activation = ActivationSpy(), scheduler = Scheduler(), coordinator = coordinator()
        activation.visible = false
        let manager = switcher(activation, scheduler, coordinator: coordinator)
        XCTAssertTrue(manager.execute(parameters: ExecutionParameters(.switchSpaceOne)))
        while activation.calls.count < 2 && scheduler.now < 1.52 { scheduler.next() }
        XCTAssertEqual(activation.calls.count, 2)
        XCTAssertEqual(activation.calls[1], activation.calls[0].reversed)
        XCTAssertTrue(manager.isSpaceActionInProgress)
        XCTAssertNil(coordinator.begin())
        activation.visible = true
        scheduler.drain()
        XCTAssertFalse(manager.isSpaceActionInProgress)
        XCTAssertNotNil(coordinator.begin())
    }
    func testPhysicalInputPreventsRollbackOfUsersSpaceChoice() {
        let activation = ActivationSpy(), scheduler = Scheduler(), input = Input()
        activation.visible = false
        let manager = switcher(activation, scheduler, input: input)
        XCTAssertTrue(manager.execute(parameters: ExecutionParameters(.switchSpaceOne)))
        input.handler?()
        scheduler.drain()
        XCTAssertEqual(activation.calls.count, 1)
        XCTAssertFalse(manager.isSpaceActionInProgress)
    }
    func testAnExternalSpaceChangeNeverGetsReversed() {
        let activation = ActivationSpy(), scheduler = Scheduler()
        let manager = switcher(activation, scheduler)
        XCTAssertTrue(manager.execute(parameters: ExecutionParameters(.switchSpaceOne)))
        activation.current = 888
        scheduler.drain()
        XCTAssertEqual(activation.calls.count, 1)
        XCTAssertFalse(manager.isSpaceActionInProgress)
    }
    func testStaleCallbackCannotCompleteANewerCommand() {
        let activation = ActivationSpy(), scheduler = Scheduler()
        let manager = switcher(activation, scheduler)
        XCTAssertTrue(manager.execute(parameters: ExecutionParameters(.switchSpaceOne)))
        let stale = scheduler.actions[0]
        scheduler.drain()
        activation.visible = false
        XCTAssertTrue(manager.execute(parameters: ExecutionParameters(.switchSpaceTwo)))
        stale()
        XCTAssertTrue(manager.isSpaceActionInProgress)
        activation.visible = true
        scheduler.drain()
        XCTAssertFalse(manager.isSpaceActionInProgress)
    }
}

class SpaceSwitchManagerTests: XCTestCase {
    private final class Scheduler {
        var now: TimeInterval = 1
        var actions = [(TimeInterval, () -> Void)]()
        func schedule(_ delay: TimeInterval, _ action: @escaping () -> Void) {
            actions.append((now + delay, action))
        }
        func next() {
            guard let index = actions.indices.min(by: { actions[$0].0 < actions[$1].0 }) else { return }
            let (time, action) = actions.remove(at: index)
            now = max(now, time)
            action()
        }
        func drain(file: StaticString = #filePath, line: UInt = #line) {
            for _ in 0..<1000 {
                if actions.isEmpty { return }
                next()
            }
            XCTFail("Space switch burst did not finish", file: file, line: line)
        }
    }
    private final class Input: SpacePhysicalInputMonitoring {
        var handler: (() -> Void)?
        func start(_ handler: @escaping () -> Void) { self.handler = handler }
        func stop() { handler = nil }
    }
    private final class Fixture {
        let scheduler = Scheduler()
        let notifications = NotificationCenter()
        let input = Input(), directInput = Input(), gestureInput = Input()
        var safe = true
        var authorized = true
        var mousePressed = false
        var selectedDisplay = "A"
        var current: [String: UInt64] = ["A": 10, "B": 90]
        var order: [(String, [(UInt64, Int)])] = [("A", [(10, 0), (20, 0), (30, 0)]), ("B", [(90, 0), (100, 0)])]
        var malformed = false
        var available = true
        var visible: Bool? = true
        var accepts = true
        var updateImmediately = true
        var notifyOnActivation = false
        var calls = [ManagedDisplaySpaceSwitch]()
        var phases = [SpaceGesturePhase]()
        var screen: NSScreen? // Direct tests never warp the real pointer.
        lazy var coordinator = SpaceOperationCoordinator(environmentIsSafe: { [unowned self] in self.safe },
                                                          clock: { [unowned self] in self.scheduler.now },
                                                          workspaceNotificationCenter: notifications)
        lazy var activation = Activation(self)
        lazy var poster = Poster(self)
        var raw: [[String: Any]] {
            order.map { identifier, spaces in
                ["Display Identifier": identifier, "Current Space": ["id64": current[identifier] ?? 0],
                 "Spaces": spaces.map { id, type -> [String: Any] in
                     malformed && id == 20 ? ["type": type] : ["id64": id, "type": type]
                 }]
            }
        }
        func makeManager() -> SpaceSwitchManager {
            SpaceSwitchManager(activation: activation, coordinator: coordinator,
                               topologyProvider: { [unowned self] in self.raw },
                               displayProvider: { [unowned self] _ in self.selectedDisplay },
                               screenProvider: { [unowned self] _ in self.screen },
                               scheduler: scheduler.schedule, clock: { [unowned self] in self.scheduler.now },
                               accessibilityAuthorized: { [unowned self] in self.authorized },
                               mousePressed: { [unowned self] in self.mousePressed },
                               inputMonitor: input, directInputMonitor: directInput, gestureInputMonitor: gestureInput,
                               eventPoster: poster, workspaceNotificationCenter: notifications)
        }
        func notify() { notifications.post(name: NSWorkspace.activeSpaceDidChangeNotification, object: nil) }
    }
    private final class Activation: ManagedDisplaySpaceActivating {
        unowned let fixture: Fixture
        init(_ fixture: Fixture) { self.fixture = fixture }
        var isAvailable: Bool { fixture.available }
        func desktop(number: Int) -> ManagedDisplaySpaceSwitch? { ManagedSpaceTopology.desktop(number: number, in: fixture.raw) }
        func currentSpace(on displayIdentifier: String) -> UInt64? { fixture.current[displayIdentifier] }
        func destinationIsVisible(_ target: ManagedDisplaySpaceSwitch) -> Bool? { fixture.visible }
        func activate(_ target: ManagedDisplaySpaceSwitch) -> Bool {
            fixture.calls.append(target)
            if fixture.accepts && fixture.updateImmediately { fixture.current[target.displayIdentifier] = target.destinationID }
            if fixture.notifyOnActivation { fixture.notify() }
            return fixture.accepts
        }
    }
    private final class Poster: DisplaySpaceSwitchEventPosting {
        unowned let fixture: Fixture
        var direction: SpaceDirection = .next
        init(_ fixture: Fixture) { self.fixture = fixture }
        var accessibilityAuthorized: Bool { fixture.authorized }
        let phaseDelay: TimeInterval = 0.01
        func prepare(direction: SpaceDirection) -> Bool { self.direction = direction; return true }
        func post(_ phase: SpaceGesturePhase) -> Bool {
            fixture.phases.append(phase)
            if phase == .ended, let spaces = fixture.order.first(where: { $0.0 == fixture.selectedDisplay })?.1,
               let index = spaces.firstIndex(where: { $0.0 == fixture.current[fixture.selectedDisplay] }) {
                let next = index + (direction == .next ? 1 : -1)
                if spaces.indices.contains(next) { fixture.current[fixture.selectedDisplay] = spaces[next].0 }
            }
            return true
        }
        func discardPreparedEvents() {}
    }
    private func press(_ manager: SpaceSwitchManager, _ action: WindowAction = .switchNextSpace) {
        XCTAssertTrue(manager.execute(parameters: ExecutionParameters(action)))
    }
    private func cursorScreen() throws -> NSScreen {
        let point = try XCTUnwrap(CGEvent(source: nil)?.location)
        return try XCTUnwrap(NSScreen.screens.first(where: { $0.frame.screenFlipped.contains(point) }))
    }

    func testRapidRelativePressesCoalesceToOneBoundedDestination() {
        let f = Fixture(), manager = f.makeManager()
        press(manager)
        for _ in 0..<100 { press(manager) }
        XCTAssertEqual(f.calls.map(\.destinationID), [20])
        XCTAssertNil(f.coordinator.begin())
        f.scheduler.drain()
        XCTAssertEqual(f.calls.map(\.destinationID), [20, 30])
        XCTAssertFalse(manager.isSpaceActionInProgress)
        XCTAssertTrue(f.phases.isEmpty)
        XCTAssertEqual(f.scheduler.now - 1, 0.06, accuracy: 0.000001)
    }

    func testBoundaryIsClampedForEachPressBeforeReversal() {
        let f = Fixture()
        f.current["A"] = 20
        let manager = f.makeManager()
        press(manager) // Commit arrival at the last desktop.
        press(manager) // Clamp here; do not retain an impossible extra step.
        press(manager, .switchPrevSpace)
        f.scheduler.drain()
        XCTAssertEqual(f.calls.map(\.destinationID), [30, 20])
    }

    func testReverseBackToInFlightDestinationDoesNotSubmitExtraSwitch() {
        let f = Fixture(), manager = f.makeManager()
        press(manager)
        press(manager)
        press(manager, .switchPrevSpace)
        f.scheduler.drain()
        XCTAssertEqual(f.calls.map(\.destinationID), [20])
    }

    func testDelayedCurrentIDsDoNotLoseOrOvershootIntent() {
        let f = Fixture()
        f.updateImmediately = false
        let manager = f.makeManager()
        press(manager)
        press(manager)
        press(manager)
        XCTAssertEqual(f.current["A"], 10)
        f.current["A"] = 20
        f.updateImmediately = true
        f.scheduler.drain()
        XCTAssertEqual(f.calls.map(\.sourceID), [10, 20])
        XCTAssertEqual(f.calls.map(\.destinationID), [20, 30])
    }

    func testLatestNumberedRequestReplacesPendingDestination() {
        let f = Fixture(), manager = f.makeManager()
        press(manager, .switchSpaceTwo)
        press(manager, .switchSpaceThree)
        press(manager, .switchSpaceOne)
        f.scheduler.drain()
        XCTAssertEqual(f.calls.map(\.destinationID), [20, 10])
    }

    func testPendingDestinationsAreIndependentAndCaptureTheirDisplays() {
        let f = Fixture(), manager = f.makeManager()
        press(manager)
        f.selectedDisplay = "B"
        press(manager)
        f.selectedDisplay = "A"
        press(manager)
        f.scheduler.drain()
        XCTAssertEqual(f.calls.map(\.displayIdentifier), ["A", "B", "A"])
        XCTAssertEqual(f.calls.map(\.destinationID), [20, 100, 30])
    }

    func testVerifiedSwitchesAndQueuedHandoffsAvoidOwnNotificationCooldown() {
        let f = Fixture()
        f.notifyOnActivation = true
        let manager = f.makeManager()
        press(manager)
        press(manager)
        f.scheduler.drain()
        XCTAssertEqual(f.calls.map(\.destinationID), [20, 30])
        XCTAssertEqual(f.scheduler.now - 1, 0.04, accuracy: 0.000001) // Notification supplies first sample.
        XCTAssertNil(f.coordinator.begin()) // Moves still observe the quiet period.
        press(manager, .switchPrevSpace) // Fresh burst within that same period.
        f.scheduler.drain()
        XCTAssertEqual(f.calls.map(\.destinationID), [20, 30, 20])
    }

    func testNativeSpaceNotificationStillBlocksANewBurst() {
        let f = Fixture(), manager = f.makeManager()
        f.notify()
        press(manager)
        XCTAssertTrue(f.calls.isEmpty)
        f.scheduler.now += 0.16
        press(manager)
        f.scheduler.drain()
        XCTAssertEqual(f.calls.count, 1)
    }

    func testPhysicalInputCancelsPendingIntentWithoutReversingUsersChoice() {
        let f = Fixture(), manager = f.makeManager()
        press(manager)
        press(manager)
        f.input.handler?()
        XCTAssertTrue(manager.isSpaceActionInProgress)
        f.scheduler.drain()
        XCTAssertEqual(f.calls.map(\.destinationID), [20])
        XCTAssertFalse(manager.isSpaceActionInProgress)
    }

    func testPhysicalInputAfterCompletionInvalidatesFastPath() {
        let f = Fixture()
        f.notifyOnActivation = true
        let manager = f.makeManager()
        press(manager)
        f.scheduler.drain()
        f.input.handler?()
        press(manager)
        XCTAssertEqual(f.calls.count, 1)
        f.scheduler.now += 0.16
        press(manager)
        f.scheduler.drain()
        XCTAssertEqual(f.calls.count, 2)
    }

    func testExternalChangeOnAnotherDisplayCancelsPendingSwitchesAndRollback() {
        let f = Fixture()
        f.visible = false
        let manager = f.makeManager()
        press(manager)
        press(manager)
        f.current["B"] = 100
        f.notify()
        f.scheduler.drain()
        XCTAssertEqual(f.calls.count, 1)
        XCTAssertFalse(manager.isSpaceActionInProgress)
    }

    func testExternalNotificationAtDeadlineCannotStartRecoveryBeforeParentObserverRuns() {
        let f = Fixture()
        f.visible = false
        let manager = f.makeManager()
        press(manager)
        press(manager)
        f.scheduler.now += 1.51
        f.current["B"] = 100
        f.notify() // Child observers were registered before the burst controller.
        f.scheduler.drain()
        XCTAssertEqual(f.calls.count, 1)
        XCTAssertFalse(manager.isSpaceActionInProgress)
    }

    func testUnexpectedDestinationNeverAdvancesQueueOrGetsReversed() {
        let f = Fixture(), manager = f.makeManager()
        press(manager)
        press(manager)
        f.current["A"] = 30
        f.scheduler.drain()
        XCTAssertEqual(f.calls.count, 1)
        XCTAssertFalse(manager.isSpaceActionInProgress)
    }

    func testTopologyReorderingAndRemovalCancelTheBurst() {
        for remove in [false, true] {
            let f = Fixture(), manager = f.makeManager()
            press(manager)
            press(manager)
            if remove { f.order[0].1.removeLast() } else { f.order[0].1.swapAt(0, 2) }
            f.notify()
            f.scheduler.drain()
            XCTAssertEqual(f.calls.count, 1)
            XCTAssertFalse(manager.isSpaceActionInProgress)
        }
    }

    func testWindowMoveLeasePreventsStartingOrDeferringSwitches() throws {
        let f = Fixture(), manager = f.makeManager()
        let move = try XCTUnwrap(f.coordinator.begin())
        press(manager)
        XCTAssertTrue(f.calls.isEmpty)
        XCTAssertFalse(manager.isSpaceActionInProgress)
        withExtendedLifetime(move) {}
    }

    func testMissionControlDraggingAndMalformedTopologyDoNotSubmit() {
        for scenario in 0..<4 {
            let f = Fixture()
            f.safe = scenario != 0
            f.mousePressed = scenario == 1
            f.malformed = scenario == 2
            f.authorized = scenario != 3
            let manager = f.makeManager()
            press(manager)
            XCTAssertTrue(f.calls.isEmpty)
            XCTAssertFalse(manager.isSpaceActionInProgress)
        }
    }

    func testMissionControlDuringSwitchDropsPendingIntent() {
        let f = Fixture(), manager = f.makeManager()
        press(manager)
        press(manager)
        f.safe = false
        f.scheduler.drain()
        XCTAssertEqual(f.calls.count, 1)
        XCTAssertFalse(manager.isSpaceActionInProgress)
    }

    func testUnsupportedDirectAPIUsesPacedGesturesWithVerifiedHandoffs() throws {
        let f = Fixture()
        f.available = false
        f.visible = nil // Older systems can lack the visibility reader too.
        f.screen = try cursorScreen()
        let manager = f.makeManager()
        press(manager)
        press(manager)
        f.scheduler.drain()
        XCTAssertTrue(f.calls.isEmpty)
        XCTAssertEqual(f.phases, [.began, .changed, .ended, .began, .changed, .ended])
        XCTAssertEqual(f.current["A"], 30)
        XCTAssertFalse(manager.isSpaceActionInProgress)
    }

    func testFullScreenRelativeTransitionsUseGestureInsteadOfDirectAPI() throws {
        let f = Fixture()
        f.order[0].1[1] = (20, 4)
        f.screen = try cursorScreen()
        let manager = f.makeManager()
        press(manager)
        f.scheduler.drain()
        XCTAssertTrue(f.calls.isEmpty)
        XCTAssertEqual(f.phases, [.began, .changed, .ended])
        XCTAssertEqual(f.current["A"], 20)
    }

    func testNumberedSwitchFromFullScreenUsesVerifiedGestureSteps() throws {
        let f = Fixture()
        f.order[0].1[1] = (20, 4)
        f.current["A"] = 20
        f.screen = try cursorScreen()
        let manager = f.makeManager()
        press(manager, .switchSpaceOne)
        f.scheduler.drain()
        XCTAssertTrue(f.calls.isEmpty)
        XCTAssertEqual(f.phases, [.began, .changed, .ended])
        XCTAssertEqual(f.current["A"], 10)
        XCTAssertFalse(manager.isSpaceActionInProgress)
    }

    func testNumberedUnavailableMissingAndAlreadyCurrentRequestsDoNothing() {
        let f = Fixture(), manager = f.makeManager()
        press(manager, .switchSpaceOne)
        press(manager, .switchSpaceNine)
        f.available = false
        press(manager, .switchSpaceTwo)
        XCTAssertTrue(f.calls.isEmpty)
        XCTAssertTrue(f.phases.isEmpty)
        XCTAssertFalse(manager.execute(parameters: ExecutionParameters(.nextSpace)))
        XCTAssertFalse(manager.execute(parameters: ExecutionParameters(.leftHalf)))
    }

    func testNotificationStormCannotReplaceTimeSeparatedVisibilitySamples() {
        let f = Fixture(), manager = f.makeManager()
        press(manager)
        for _ in 0..<30 { f.notify() }
        XCTAssertTrue(manager.isSpaceActionInProgress)
        f.scheduler.next()
        XCTAssertTrue(manager.isSpaceActionInProgress)
        f.scheduler.next()
        XCTAssertFalse(manager.isSpaceActionInProgress)
        XCTAssertEqual(f.scheduler.now - 1, 0.02, accuracy: 0.000001)
    }

    func testVisibilityFailureRetainsElapsedDeadlineAndRecoveryLock() {
        let f = Fixture()
        f.visible = false
        f.notifyOnActivation = true // Including a notification during recovery submission.
        let manager = f.makeManager()
        press(manager)
        press(manager)
        while f.scheduler.now < 1.4 { f.scheduler.next() }
        XCTAssertEqual(f.calls.count, 1)
        XCTAssertTrue(manager.isSpaceActionInProgress)
        while f.calls.count < 2 { f.scheduler.next() }
        XCTAssertEqual(f.calls[1], f.calls[0].reversed)
        XCTAssertNil(f.coordinator.begin())
        f.visible = true
        f.scheduler.drain()
        XCTAssertEqual(f.calls.count, 2) // Pending intent was dropped after recovery.
        XCTAssertFalse(manager.isSpaceActionInProgress)
    }

    func testStalePollCannotCompleteANewerBurst() {
        let f = Fixture(), manager = f.makeManager()
        press(manager)
        let stale = f.scheduler.actions[0].1
        f.scheduler.drain()
        f.visible = false
        press(manager)
        stale()
        XCTAssertTrue(manager.isSpaceActionInProgress)
        f.visible = true
        f.scheduler.drain()
        XCTAssertFalse(manager.isSpaceActionInProgress)
    }

    func testOnlyMatchingSwitchKeyDownsAreRepeatIntent() throws {
        let policy = SpaceSwitchShortcutPolicy()
        policy.shortcuts = [SpaceSwitchShortcutPolicy.Shortcut(keyCode: 124, modifiers: [.control, .option])]
        func event(_ code: UInt16, _ modifiers: NSEvent.ModifierFlags, _ type: NSEvent.EventType = .keyDown) throws -> NSEvent {
            try XCTUnwrap(NSEvent.keyEvent(with: type, location: .zero, modifierFlags: modifiers, timestamp: 0,
                                          windowNumber: 0, context: nil, characters: "", charactersIgnoringModifiers: "",
                                          isARepeat: true, keyCode: code))
        }
        XCTAssertTrue(policy.matches(try event(124, [.control, .option])))
        XCTAssertTrue(policy.matches(try event(124, [.control, .option, .capsLock, .numericPad, .function])))
        XCTAssertFalse(policy.matches(try event(124, [.control, .option, .shift])))
        XCTAssertFalse(policy.matches(try event(123, [.control, .option])))
        XCTAssertFalse(policy.matches(try event(124, [.control, .option], .keyUp)))
        policy.shortcuts.removeAll()
        XCTAssertFalse(policy.matches(try event(124, [.control, .option])))
    }
}
