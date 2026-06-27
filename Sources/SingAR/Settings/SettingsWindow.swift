import AppKit

/// Settings window: enter OpenRouter / ZenMux API keys (stored in Keychain),
/// and a subscription token. Also shows permission status. This is where BYOK
/// keys are entered — they never touch UserDefaults or the app binary.
final class SettingsWindow: NSObject, NSWindowDelegate, NSTextFieldDelegate {

    private let window: NSWindow
    private let openrouterField = NSTextField(frame: .zero)
    private let zenmuxField = NSTextField(frame: .zero)
    private let subTokenField = NSTextField(frame: .zero)

    override init() {
        window = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 480, height: 360),
            styleMask: [.titled, .closable],
            backing: .buffered, defer: false
        )
        window.title = "SingAR — Настройки"
        window.center()
        window.isReleasedWhenClosed = false
        super.init()
        window.delegate = self
        buildUI()
    }

    func show() {
        loadKeys()
        NSApp.activate(ignoringOtherApps: true)
        window.makeKeyAndOrderFront(nil)
    }

    // MARK: UI

    private func buildUI() {
        let view = NSView(frame: window.contentView!.bounds)
        view.autoresizingMask = [.width, .height]
        window.contentView = view

        var y: CGFloat = 320
        let labelW: CGFloat = 130, fieldX: CGFloat = 150, fieldW: CGFloat = 310

        func addSection(_ title: String) {
            let l = NSTextField(labelWithString: title)
            l.font = .systemFont(ofSize: 13, weight: .semibold)
            l.frame = NSRect(x: 20, y: y, width: 440, height: 20)
            view.addSubview(l)
            y -= 28
        }

        func addField(_ label: String, _ field: NSTextField, placeholder: String) {
            let l = NSTextField(labelWithString: label)
            l.alignment = .right
            l.frame = NSRect(x: 20, y: y, width: labelW, height: 22)
            view.addSubview(l)
            field.frame = NSRect(x: fieldX, y: y, width: fieldW, height: 22)
            field.placeholderString = placeholder
            field.delegate = self
            view.addSubview(field)
            y -= 30
        }

        addSection("Облачные шаги (ключи хранятся в Keychain)")
        addField("OpenRouter:", openrouterField, placeholder: "sk-or-v1-…  (для re-ASR)")
        addField("ZenMux:", zenmuxField, placeholder: "sk-…  (для LLM-polish)")

        y -= 8
        addSection("Подписка (токен прокси SingAR)")
        addField("Токен:", subTokenField, placeholder: "токен подписки…")

        y -= 12
        let saveBtn = NSButton(title: "Сохранить ключи", target: self, action: #selector(save))
        saveBtn.bezelStyle = .rounded
        saveBtn.keyEquivalent = "\r"
        saveBtn.frame = NSRect(x: 20, y: y, width: 160, height: 28)
        view.addSubview(saveBtn)

        let hint = NSTextField(labelWithString: "re-ASR ≈ $0.00012/диктовка · LLM-polish ≈ $0.0001")
        hint.font = .systemFont(ofSize: 10)
        hint.textColor = .secondaryLabelColor
        hint.frame = NSRect(x: 20, y: y - 34, width: 440, height: 16)
        view.addSubview(hint)
    }

    // MARK: Load / Save

    private func loadKeys() {
        openrouterField.stringValue = KeychainStore.get(KeychainStore.Account.openrouterKey) ?? ""
        zenmuxField.stringValue = KeychainStore.get(KeychainStore.Account.zenmuxKey) ?? ""
        subTokenField.stringValue = KeychainStore.get(KeychainStore.Account.subscriptionToken) ?? ""
    }

    @objc private func save() {
        let or = openrouterField.stringValue.trimmingCharacters(in: .whitespaces)
        let zm = zenmuxField.stringValue.trimmingCharacters(in: .whitespaces)
        let st = subTokenField.stringValue.trimmingCharacters(in: .whitespaces)

        or.isEmpty ? KeychainStore.remove(KeychainStore.Account.openrouterKey)
                   : KeychainStore.set(or, for: KeychainStore.Account.openrouterKey)
        zm.isEmpty ? KeychainStore.remove(KeychainStore.Account.zenmuxKey)
                   : KeychainStore.set(zm, for: KeychainStore.Account.zenmuxKey)
        st.isEmpty ? KeychainStore.remove(KeychainStore.Account.subscriptionToken)
                   : KeychainStore.set(st, for: KeychainStore.Account.subscriptionToken)

        window.close()
    }
}
