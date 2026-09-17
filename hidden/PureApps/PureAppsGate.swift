import AppKit
import PureAppsLicense
import os

/// PureApps subscription check. One subscription unlocks every PureApps app, so there is
/// nothing app-specific here: read the signed licence the Hub wrote, and act on it.
///
/// This is the only PureApps code in the app. Everything else stays as upstream wrote it,
/// so merges from upstream keep working.
enum PureAppsGate {
    private static let log = Logger(subsystem: "apps.pure.puremenu", category: "license")

    /// Called once at launch. Nothing is blocked here: the app opens, its settings are
    /// browsable, and only hiding menu bar icons asks for a licence.
    static func checkAtLaunch() {
        // Wakes the Hub in the background when the licence is within two days of going
        // stale, so someone who never opens the Hub is not locked out of what they paid for.
        PureAppsLicense.refreshIfNeeded()
        log.info("licence status: \(String(describing: PureAppsLicense.status()), privacy: .public)")
        routeAboutMenuItem()
        // After upstream's launch setup has registered its defaults and loaded Preferences.
        DispatchQueue.main.async { hideToolbarPlaceholderLabel() }
    }

    /// The gate for collapsing the bar. Expanding is never gated: icons already hidden must
    /// always be reachable. False means: leave the bar expanded.
    static func allowHiding() -> Bool {
        let status = PureAppsLicense.status()
        guard !status.unlocksEverything else { return true }
        log.info("blocked collapse: licence \(String(describing: status), privacy: .public)")
        remindAtMostOccasionally()
        return false
    }

    /// One alert, then silence for a while: the auto-collapse timer must not stack alerts.
    static let reminderInterval: TimeInterval = 5 * 60
    private static var lastReminder: Date?
    private static var isReminding = false

    private static func remindAtMostOccasionally() {
        guard !isReminding else { return }
        if let lastReminder, Date().timeIntervalSince(lastReminder) < reminderInterval { return }
        isReminding = true
        lastReminder = Date()
        DispatchQueue.main.async {
            presentSubscriptionNeeded()
            lastReminder = Date()
            isReminding = false
        }
    }

    static let upstreamURL = URL(string: "https://github.com/dwarvesf/hidden")!

    /// PureMenu is a menu-bar app, so its About is the Preferences About tab and all credit
    /// lives there: the main UI carries the PureApps brand only, and MIT asks that the
    /// notice travel with the app. The upstream storyboard is left untouched: its link
    /// block (website, Twitter, GitHub, e-mail, footer) is taken out of the view here and
    /// replaced by a compact, centred credit block; the header box is shortened to fit.
    static func brandAboutPane(_ root: NSView, versionLabel: NSTextField) {
        let small = NSFont.systemFont(ofSize: NSFont.smallSystemFontSize)
        let body: [NSAttributedString.Key: Any] = [.font: small, .foregroundColor: NSColor.secondaryLabelColor]

        let version = Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? ""
        versionLabel.stringValue = "\(NSLocalizedString("Version", comment: "Version")) \(version)"

        guard let header = root.subviews.first(where: { $0 is NSBox }) as? NSBox else { return }
        // The upstream link block is a fixed-frame stack: remove it outright so its
        // hidden rows cannot hold space.
        for view in root.subviews where view is NSStackView {
            view.removeFromSuperview()
        }
        var queue: [NSView] = [header]
        while let view = queue.popLast() {
            queue.append(contentsOf: view.subviews)
            if let imageView = view as? NSImageView {
                // The upstream logo asset is gone; show our own icon.
                imageView.image = NSApp.applicationIconImage
            }
        }
        // The header sits under the 52pt transparent toolbar: 52 + 24 + 120pt icon + 24,
        // with the icon row centred in the part below the toolbar.
        let toolbarHeight: CGFloat = 52
        let headerHeight = toolbarHeight + 168
        for constraint in header.constraints where constraint.firstAttribute == .height {
            constraint.constant = headerHeight
        }
        for constraint in header.contentView?.constraints ?? [] where constraint.firstAttribute == .centerY {
            constraint.constant = toolbarHeight / 2
        }

        let credit = NSTextField(wrappingLabelWithString: String(localized: "Based on Hidden Bar by Dwarves Foundation, used under the MIT licence."))
        credit.font = small
        credit.textColor = .secondaryLabelColor
        credit.alignment = .center
        credit.preferredMaxLayoutWidth = 520

        let link = HyperlinkTextField(labelWithString: upstreamURL.absoluteString)
        link.href = upstreamURL.absoluteString
        link.font = small
        link.textColor = .linkColor

        // "© 2026 PureApps. Based on Hidden Bar, © 2019 Dwarves Foundation, MIT." with the
        // word PureApps alone as the link.
        let footerText = NSMutableAttributedString(string: String(localized: "© 2026 "), attributes: body)
        footerText.append(NSAttributedString(
            string: "PureApps",
            attributes: body.merging([.link: URL(string: "https://pureapps.dev")!]) { _, new in new }
        ))
        footerText.append(NSAttributedString(
            string: String(localized: ". Based on Hidden Bar, © 2019 Dwarves Foundation, MIT."),
            attributes: body
        ))
        let footer = LinkTextView(attributed: footerText)

        let block = NSStackView(views: [credit, link, footer])
        block.orientation = .vertical
        block.alignment = .centerX
        block.spacing = 4
        block.setCustomSpacing(16, after: link)
        block.translatesAutoresizingMaskIntoConstraints = false
        root.addSubview(block)
        NSLayoutConstraint.activate([
            block.topAnchor.constraint(equalTo: header.bottomAnchor, constant: 22),
            block.centerXAnchor.constraint(equalTo: root.centerXAnchor),
            block.leadingAnchor.constraint(greaterThanOrEqualTo: root.leadingAnchor, constant: 40),
            block.bottomAnchor.constraint(equalTo: root.bottomAnchor, constant: -22),
        ])

        // The window takes the view's frame when the tab switches: size it to the content.
        aboutSize = NSSize(width: root.frame.width, height: headerHeight + 22 + block.fittingSize.height + 22)
        root.setFrameSize(aboutSize)
    }

    private static var aboutSize = NSSize(width: 600, height: 325)
    private static var generalSize: NSSize?
    private static let segmentRelay = SegmentRelay()

    /// The General header is drawn under the transparent 52pt toolbar and upstream put the
    /// menu bar illustration 38pt from its top, so the toolbar covered it. Push it down to
    /// 16pt below the toolbar; the header (and the window) grow by the same amount.
    private static func moveGeneralContentBelowToolbar(_ root: NSView) -> CGFloat {
        guard let header = root.subviews.first(where: { $0 is NSBox }) as? NSBox,
              let content = header.contentView,
              let top = content.constraints.first(where: { $0.firstAttribute == .top && $0.secondAttribute == .top && $0.secondItem === content })
        else { return 0 }
        let wanted: CGFloat = 52 + 16
        let added = max(0, wanted - top.constant)
        top.constant += added
        return added
    }

    /// Upstream only swaps the content view controller on a tab switch, so the window
    /// keeps the size of whichever tab came first. Size it to the tab now showing,
    /// keeping the top edge and the centre line where they are.
    fileprivate static func fitPreferencesWindow(centreX: CGFloat? = nil) {
        guard let window = PreferencesWindowController.shared.window,
              let content = window.contentViewController else { return }
        guard let size = content is AboutViewController ? aboutSize : generalSize else { return }
        var frame = window.frameRect(forContentRect: NSRect(origin: .zero, size: size))
        frame.origin.x = ((centreX ?? window.frame.midX) - frame.width / 2).rounded()
        frame.origin.y = window.frame.maxY - frame.height
        window.setFrame(frame, display: true, animate: window.isVisible)
    }

    /// The Preferences toolbar is label-only, so its one custom item printed its
    /// placeholder label "Custom View" under the General/About control.
    static func hideToolbarPlaceholderLabel() {
        guard let window = PreferencesWindowController.shared.window, let toolbar = window.toolbar else { return }
        // The window opens on the General tab: remember its size for the way back.
        generalSize = window.contentView?.frame.size
        if let general = window.contentViewController as? PreferencesViewController, let size = generalSize {
            let added = moveGeneralContentBelowToolbar(general.view)
            generalSize = NSSize(width: size.width, height: size.height + added)
            fitPreferencesWindow()
        }
        toolbar.displayMode = .iconOnly
        for item in toolbar.items where item.view != nil {
            item.label = ""
            item.paletteLabel = ""
            // Centre on the window, not in the space right of the window buttons.
            toolbar.centeredItemIdentifiers = [item.itemIdentifier]
            if let segments = item.view as? NSSegmentedControl, segments.target !== segmentRelay {
                segmentRelay.target = segments.target
                segmentRelay.action = segments.action
                segments.target = segmentRelay
                segments.action = #selector(SegmentRelay.switched(_:))
            }
        }
    }

    /// The app menu (visible while "use the full menu bar" is on) opened the standard
    /// About panel, which carries no credit. Send it to the About tab instead.
    private static func routeAboutMenuItem() {
        guard let items = NSApp.mainMenu?.items.first?.submenu?.items,
              let about = items.first(where: { $0.action == #selector(NSApplication.orderFrontStandardAboutPanel(_:)) })
        else { return }
        about.target = AboutMenuTarget.shared
        about.action = #selector(AboutMenuTarget.showAboutTab)
    }

    static func showAboutTab() {
        Util.showPrefWindow()
        guard let toolbar = PreferencesWindowController.shared.window?.toolbar else { return }
        for item in toolbar.items {
            guard let segments = item.view as? NSSegmentedControl else { continue }
            segments.selectedSegment = 1
            if let action = segments.action {
                NSApp.sendAction(action, to: segments.target, from: segments)
            }
        }
    }

    static func openSubscription() {
        guard PureAppsLicense.isHubInstalled else {
            NSWorkspace.shared.open(URL(string: "https://pureapps.dev/")!)
            return
        }
        NSWorkspace.shared.open(PureAppsLicense.hubURL(action: .subscribe))
    }

    private static func presentSubscriptionNeeded() {
        let alert = NSAlert()
        if hadPaidSubscription {
            alert.messageText = String(localized: "Your PureApps subscription has ended")
            alert.informativeText = String(localized: "Renew it in PureApps Hub to keep hiding menu bar icons. One subscription unlocks every PureApps app.")
        } else {
            alert.messageText = String(localized: "Your PureApps trial has ended")
            alert.informativeText = String(localized: "Subscribe in PureApps Hub to keep hiding menu bar icons. One subscription unlocks every PureApps app.")
        }
        alert.addButton(withTitle: PureAppsLicense.isHubInstalled ? String(localized: "Open PureApps Hub") : String(localized: "Get PureApps Hub"))
        alert.addButton(withTitle: String(localized: "Later"))
        NSApplication.shared.activate(ignoringOtherApps: true)
        if alert.runModal() == .alertFirstButtonReturn {
            openSubscription()
        }
    }

    /// `.expired` covers both a lapsed subscription and a finished trial. A genuine,
    /// non-trial token on disk means someone paid, so the wording says "subscription".
    private static var hadPaidSubscription: Bool {
        guard let data = try? Data(contentsOf: PureAppsLicense.licenseURL),
              let token = try? LicenseVerifier().token(from: data) else { return false }
        return token.plan != LicenseStatus.trialPlanName
    }
}

/// Forwards the General/About switch to upstream's handler, then sizes the window.
private final class SegmentRelay: NSObject {
    weak var target: AnyObject?
    var action: Selector?

    @objc func switched(_ sender: NSSegmentedControl) {
        // Upstream's content swap already resizes from the left edge: take the centre first.
        let centreX = sender.window?.frame.midX
        if let action {
            NSApp.sendAction(action, to: target, from: sender)
        }
        PureAppsGate.fitPreferencesWindow(centreX: centreX)
    }
}

private final class AboutMenuTarget: NSObject {
    static let shared = AboutMenuTarget()

    @objc func showAboutTab() {
        PureAppsGate.showAboutTab()
    }
}

/// Read-only text whose `.link` ranges show the pointing hand and open on click. A plain
/// view drawing through its own layout manager: nothing is selectable, so no I-beam.
private final class LinkTextView: NSView {
    private let storage = NSTextStorage()
    private let layoutManager = NSLayoutManager()
    private let container = NSTextContainer()

    convenience init(attributed: NSAttributedString) {
        self.init(frame: .zero)
        container.lineFragmentPadding = 0
        layoutManager.addTextContainer(container)
        storage.addLayoutManager(layoutManager)
        storage.setAttributedString(attributed)
        storage.enumerateAttribute(.link, in: NSRange(location: 0, length: storage.length)) { value, range, _ in
            guard value != nil else { return }
            storage.addAttributes([.foregroundColor: NSColor.linkColor, .underlineStyle: NSUnderlineStyle.single.rawValue], range: range)
        }
        storage.removeAttribute(.link, range: NSRange(location: 0, length: storage.length))
        attributed.enumerateAttribute(.link, in: NSRange(location: 0, length: attributed.length)) { value, range, _ in
            if let value { links.append((range, value as? URL)) }
        }
        translatesAutoresizingMaskIntoConstraints = false
    }

    private var links: [(NSRange, URL?)] = []

    override var isFlipped: Bool { true }

    override func isAccessibilityElement() -> Bool { true }
    override func accessibilityRole() -> NSAccessibility.Role? { .staticText }
    override func accessibilityValue() -> Any? { storage.string }

    override var intrinsicContentSize: NSSize {
        container.size = NSSize(width: CGFloat.greatestFiniteMagnitude, height: CGFloat.greatestFiniteMagnitude)
        layoutManager.ensureLayout(for: container)
        let used = layoutManager.usedRect(for: container)
        return NSSize(width: ceil(used.width), height: ceil(used.height))
    }

    override func draw(_ dirtyRect: NSRect) {
        container.size = bounds.size
        let glyphs = layoutManager.glyphRange(for: container)
        layoutManager.drawGlyphs(forGlyphRange: glyphs, at: .zero)
    }

    private func linkRects() -> [(NSRect, URL)] {
        container.size = bounds.size
        var result: [(NSRect, URL)] = []
        for case let (range, url?) in links {
            let glyphs = layoutManager.glyphRange(forCharacterRange: range, actualCharacterRange: nil)
            layoutManager.enumerateEnclosingRects(forGlyphRange: glyphs, withinSelectedGlyphRange: NSRange(location: NSNotFound, length: 0), in: container) { rect, _ in
                result.append((rect, url))
            }
        }
        return result
    }

    override func resetCursorRects() {
        for (rect, _) in linkRects() {
            addCursorRect(rect, cursor: .pointingHand)
        }
    }

    override func mouseDown(with event: NSEvent) {
        let point = convert(event.locationInWindow, from: nil)
        if let (_, url) = linkRects().first(where: { $0.0.contains(point) }) {
            NSWorkspace.shared.open(url)
        }
    }
}
