/// RectangleStatusItem.swift

import Cocoa

extension StatusItemSpaceNumbers {
    static func current(for screens: [(identifier: String, isBuiltIn: Bool)],
                        in displays: [[String: Any]]) -> StatusItemSpaceNumbers {
        let internalIdentifier = screens.first(where: { $0.isBuiltIn })?.identifier
        let externalIdentifier = screens.first(where: { !$0.isBuiltIn })?.identifier
        return StatusItemSpaceNumbers(
            internalDisplay: internalIdentifier.flatMap { ManagedSpaceTopology.currentDesktopNumber(on: $0, in: displays) },
            externalDisplay: externalIdentifier.flatMap { ManagedSpaceTopology.currentDesktopNumber(on: $0, in: displays) })
    }
}

class RectangleStatusItem {
    static let instance = RectangleStatusItem()
    
    private var nsStatusItem: NSStatusItem?
    private var added: Bool = false
    public var statusMenu: NSMenu? {
        didSet {
            nsStatusItem?.menu = statusMenu
        }
    }
    private var isVisibleObserver: NSKeyValueObservation?
    private var spaceObservers: [(NotificationCenter, NSObjectProtocol)] = []
    private var spaceRefreshTimer: Timer?
    private var imageConfiguration: ImageConfiguration?
    private let yabaiLabelReader = YabaiSpaceLabelReader()
    private var yabaiLabel: String?
    private var labelQueryInFlight = false
    private var labelGeneration: UInt64 = 0

    private struct ImageConfiguration: Equatable {
        let numbers: StatusItemSpaceNumbers
        let style: StatusItemSpaceBadgeStyle
        let label: String?
        let labelAlignment: StatusItemSpaceLabelAlignment
    }
    
    private init() {}
    
    public func refreshVisibility() {
        if Defaults.hideMenuBarIcon.enabled {
            remove()
        } else {
            add()
        }
    }
    
    public func openMenu() {
        if !added {
            add()
        }
        nsStatusItem?.button?.performClick(self)
        refreshVisibility()
    }
    
    private func add() {
        guard !added else {
            startUpdatingSpaceBadge()
            refreshImage()
            return
        }
        added = true
        nsStatusItem = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)
        nsStatusItem?.menu = self.statusMenu
        startUpdatingSpaceBadge()
        refreshImage()
        nsStatusItem?.behavior = .removalAllowed
        isVisibleObserver = nsStatusItem?.observe(\.isVisible, options: [.old, .new]) { [weak self] _, change in
            if change.oldValue == true && change.newValue == false {
                Defaults.hideMenuBarIcon.enabled = true
                self?.stopUpdatingSpaceBadge()
                Notification.Name.menuBarIconHidden.post()
                // Cmd-drag removal also needs cleanup when Settings has never been opened.
                DispatchQueue.main.async { [weak self] in self?.refreshVisibility() }
            }
        }
        nsStatusItem?.isVisible = true
    }
    
    private func remove() {
        added = false
        isVisibleObserver = nil
        stopUpdatingSpaceBadge()
        imageConfiguration = nil
        guard let nsStatusItem = nsStatusItem else { return }
        NSStatusBar.system.removeStatusItem(nsStatusItem)
        self.nsStatusItem = nil
    }

    private func stopUpdatingSpaceBadge() {
        labelGeneration &+= 1
        yabaiLabel = nil
        spaceRefreshTimer?.invalidate()
        spaceRefreshTimer = nil
        for (center, observer) in spaceObservers { center.removeObserver(observer) }
        spaceObservers.removeAll()
    }

    private func startUpdatingSpaceBadge() {
        stopUpdatingSpaceBadge()
        guard !Defaults.menuBarSpaceNumber.userDisabled || Defaults.menuBarYabaiLabel.enabled else { return }
        let workspace = NSWorkspace.shared.notificationCenter
        for (center, names) in [
            (workspace, [NSWorkspace.activeSpaceDidChangeNotification, NSWorkspace.didWakeNotification,
                         NSWorkspace.didActivateApplicationNotification]),
            (NotificationCenter.default, [NSApplication.didChangeScreenParametersNotification])
        ] {
            for name in names {
                let observer = center.addObserver(forName: name, object: nil, queue: .main) { [weak self] _ in
                    self?.refreshImage(invalidateLabel: name != NSWorkspace.didActivateApplicationNotification)
                }
                spaceObservers.append((center, observer))
            }
        }
        // Also catch reordered desktops and delayed display topology updates.
        // Hidden icons do no polling.
        let timer = Timer(timeInterval: 1, repeats: true) { [weak self] _ in self?.refreshImage() }
        timer.tolerance = 0.2
        RunLoop.main.add(timer, forMode: .common)
        spaceRefreshTimer = timer
    }

    private func refreshImage(invalidateLabel: Bool = false) {
        if invalidateLabel {
            labelGeneration &+= 1
            yabaiLabel = nil
        }
        renderImage()
        guard added, Defaults.menuBarYabaiLabel.enabled, !labelQueryInFlight else { return }
        labelQueryInFlight = true
        let generation = labelGeneration
        yabaiLabelReader.read { [weak self] label in
            guard let self else { return }
            self.labelQueryInFlight = false
            guard self.added, Defaults.menuBarYabaiLabel.enabled else { return }
            guard generation == self.labelGeneration else {
                self.refreshImage()
                return
            }
            self.yabaiLabel = label
            self.renderImage()
        }
    }

    private func renderImage() {
        guard let button = nsStatusItem?.button, let base = NSImage(named: "StatusTemplate") else { return }
        let numbers = Defaults.menuBarSpaceNumber.userDisabled ? StatusItemSpaceNumbers() : currentDesktopNumbers()
        let style = StatusItemSpaceBadgeStyle(
            fontSize: CGFloat(Defaults.menuBarSpaceNumberFontSize.value),
            borderWidth: CGFloat(Defaults.menuBarSpaceNumberBorderWidth.value),
            rightInset: CGFloat(Defaults.menuBarSpaceNumberRightInset.value),
            leftInset: CGFloat(Defaults.menuBarSpaceNumberLeftInset.value),
            bottomInset: CGFloat(Defaults.menuBarSpaceNumberBottomInset.value))
        let label = Defaults.menuBarYabaiLabel.enabled
            ? YabaiSpaceLabel.abbreviated(yabaiLabel, delimiter: Defaults.menuBarYabaiLabelDelimiter.value ?? StatusItemSpaceLabelStyle.defaultDelimiter) : nil
        let labelAlignment = Defaults.menuBarYabaiLabelAlignment.value
        let configuration = ImageConfiguration(numbers: numbers, style: style, label: label, labelAlignment: labelAlignment)
        guard configuration != imageConfiguration else { return }
        imageConfiguration = configuration
        button.image = StatusItemSpaceBadge.image(base: base, numbers: numbers, style: style, label: label,
                                                labelAlignment: labelAlignment)
        let desktops = [numbers.externalDisplay.map { "External desktop \($0)" },
                        numbers.internalDisplay.map { "Internal desktop \($0)" }].compactMap { $0 }
        let details = desktops + (label.map { ["Space label \($0)"] } ?? [])
        let description = details.isEmpty ? "Rectangle" : "Rectangle — " + details.joined(separator: ", ")
        button.toolTip = description
        button.setAccessibilityLabel(description)
    }

    private func currentDesktopNumbers() -> StatusItemSpaceNumbers {
        let checker = SkyLightSpaceNeighborChecker.shared
        guard let displays = checker.managedDisplaySpaces() else { return StatusItemSpaceNumbers() }
        let screens = NSScreen.screens.compactMap { screen -> (identifier: String, isBuiltIn: Bool)? in
            guard screen.frame.isFiniteAndNonEmpty,
                  let displayID = screen.deviceDescription[NSDeviceDescriptionKey("NSScreenNumber")] as? NSNumber,
                  displayID.uint32Value != 0 else { return nil }
            let frame = screen.frame.screenFlipped
            guard let identifier = checker.displayIdentifier(at: CGPoint(x: frame.midX, y: frame.midY)) else { return nil }
            return (identifier, CGDisplayIsBuiltin(displayID.uint32Value) != 0)
        }
        return StatusItemSpaceNumbers.current(for: screens, in: displays)
    }
}
