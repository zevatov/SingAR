import AppKit

/// First-run onboarding: a guided window that walks the user through the three
/// required permissions, shows live status, and only dismisses once everything
/// is granted. Auto-shown on first launch; re-openable from the menu.
final class OnboardingWindow: NSObject, NSWindowDelegate {

    private let window: NSWindow
    private let rows: [PermissionKind: PermissionRow] = PermissionKind.allCases.reduce(into: [:]) { $0[$1] = PermissionRow($1) }
    private var watchTimer: Timer?

    override init() {
        window = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 540, height: 420),
            styleMask: [.titled, .closable],
            backing: .buffered, defer: false
        )
        window.title = "Добро пожаловать в SingAR"
        window.center()
        window.isReleasedWhenClosed = false
        super.init()
        window.delegate = self
        buildUI()
    }

    func show() {
        NSApp.activate(ignoringOtherApps: true)
        // Trigger all three prompts so the user sees them up front.
        PermissionChecker.shared.requestMicrophone()
        PermissionChecker.shared.requestAccessibility()
        PermissionChecker.shared.requestInputMonitoring()
        refresh()
        window.makeKeyAndOrderFront(nil)
        startWatching()
    }

    private func buildUI() {
        let view = NSView(frame: window.contentView!.bounds)
        view.autoresizingMask = [.width, .height]
        window.contentView = view

        let title = NSTextField(labelWithString: "SingAR — настройка за 30 секунд")
        title.font = .systemFont(ofSize: 19, weight: .bold)
        title.frame = NSRect(x: 24, y: 372, width: 492, height: 26)
        view.addSubview(title)

        let subtitle = NSTextField(wrappingLabelWithString: "Выдайте три разрешения, чтобы диктовка заработала. Нажмите «Открыть» для каждого и включите SingAR в System Settings.")
        subtitle.font = .systemFont(ofSize: 12)
        subtitle.textColor = .secondaryLabelColor
        subtitle.frame = NSRect(x: 24, y: 332, width: 492, height: 34)
        view.addSubview(subtitle)

        // Permission rows.
        var y: CGFloat = 300
        for kind in PermissionKind.allCases {
            let row = rows[kind]!
            row.frame = NSRect(x: 24, y: y, width: 492, height: 64)
            view.addSubview(row)
            y -= 72
        }

        let doneBtn = NSButton(title: "Готово", target: self, action: #selector(close))
        doneBtn.bezelStyle = .rounded
        doneBtn.keyEquivalent = "\r"
        doneBtn.frame = NSRect(x: 436, y: 20, width: 90, height: 30)
        view.addSubview(doneBtn)
        doneButton = doneBtn

        let hint = NSTextField(wrappingLabelWithString: "После разрешений зажмите Fn/Globe — и говорите. Ключи OpenRouter/ZenMux (опц.) — в «Настройки…».")
        hint.font = .systemFont(ofSize: 10)
        hint.textColor = .secondaryLabelColor
        hint.frame = NSRect(x: 24, y: 24, width: 400, height: 30)
        view.addSubview(hint)
    }

    private weak var doneButton: NSButton?

    // MARK: Live status

    private func refresh() {
        var allOK = true
        for (kind, row) in rows {
            let s = PermissionChecker.shared.status(of: kind)
            row.setStatus(s)
            if s != .granted { allOK = false }
        }
        doneButton?.title = allOK ? "Готово ✓" : "Я выдал — перепроверить"
    }

    private func startWatching() {
        watchTimer?.invalidate()
        watchTimer = Timer.scheduledTimer(withTimeInterval: 1.5, repeats: true) { [weak self] _ in
            self?.refresh()
        }
    }

    @objc private func close() {
        watchTimer?.invalidate()
        watchTimer = nil
        window.close()
        UserDefaults.standard.set(true, forKey: "onboardingCompleted")
    }

    func windowWillClose(_ notification: Notification) {
        watchTimer?.invalidate()
        watchTimer = nil
    }

    /// True if the user has finished onboarding at least once.
    static var completed: Bool {
        UserDefaults.standard.bool(forKey: "onboardingCompleted")
    }
}

// MARK: Permission row view

private final class PermissionRow: NSView {

    private let kind: PermissionKind
    private let titleLabel = NSTextField(labelWithString: "")
    private let whyLabel = NSTextField(labelWithString: "")
    private let statusDot = NSView()
    private let statusLabel = NSTextField(labelWithString: "")
    private let openButton = NSButton(title: "Открыть", target: nil, action: nil)

    init(_ kind: PermissionKind) {
        self.kind = kind
        super.init(frame: .zero)
        self.wantsLayer = true
        self.layer?.cornerRadius = 10
        self.layer?.backgroundColor = NSColor.windowBackgroundColor.withAlphaComponent(0.5).cgColor

        titleLabel.stringValue = kind.title
        titleLabel.font = .systemFont(ofSize: 14, weight: .semibold)
        titleLabel.isBezeled = false
        titleLabel.drawsBackground = false
        titleLabel.frame = NSRect(x: 16, y: 36, width: 380, height: 20)
        addSubview(titleLabel)

        whyLabel.stringValue = kind.why
        whyLabel.font = .systemFont(ofSize: 11)
        whyLabel.textColor = .secondaryLabelColor
        whyLabel.isBezeled = false
        whyLabel.drawsBackground = false
        whyLabel.frame = NSRect(x: 16, y: 18, width: 380, height: 16)
        addSubview(whyLabel)

        statusDot.wantsLayer = true
        statusDot.layer?.cornerRadius = 6
        statusDot.frame = NSRect(x: 16, y: 6, width: 12, height: 12)
        addSubview(statusDot)

        statusLabel.font = .systemFont(ofSize: 11, weight: .medium)
        statusLabel.isBezeled = false
        statusLabel.drawsBackground = false
        statusLabel.frame = NSRect(x: 34, y: 6, width: 200, height: 14)
        addSubview(statusLabel)

        openButton.bezelStyle = .rounded
        openButton.frame = NSRect(x: 392, y: 18, width: 84, height: 28)
        openButton.target = self
        openButton.action = #selector(openSettings)
        addSubview(openButton)
    }

    required init?(coder: NSCoder) { fatalError() }

    func setStatus(_ s: PermissionStatus) {
        let (color, text, textColor, btnEnabled, btnTitle): (NSColor, String, NSColor, Bool, String)
        switch s {
        case .granted:
            (color, text, textColor, btnEnabled, btnTitle) =
                (.systemGreen, "разрешено", .systemGreen, false, "✓")
        case .denied:
            (color, text, textColor, btnEnabled, btnTitle) =
                (.systemRed, "запрещено — включите вручную", .systemRed, true, "Открыть")
        case .unknown:
            (color, text, textColor, btnEnabled, btnTitle) =
                (.systemOrange, "ожидает разрешения", .systemOrange, true, "Открыть")
        }
        statusDot.layer?.backgroundColor = color.cgColor
        statusDot.needsDisplay = true
        statusLabel.stringValue = text
        statusLabel.textColor = textColor
        openButton.isEnabled = btnEnabled
        openButton.title = btnTitle
    }

    @objc private func openSettings() {
        PermissionChecker.shared.openSettings(for: kind)
    }
}
