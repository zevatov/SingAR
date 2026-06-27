import AppKit

/// Owns the menu bar item: a single coloured glyph that reflects dictation
/// state, plus a dropdown menu exposing every feature as a toggle/radio backed
/// by `AppSettings` (and therefore persisted in UserDefaults).
final class StatusBarController: NSObject, NSMenuDelegate {

    private let statusItem: NSStatusItem
    private let settings = AppSettings.shared
    private var status: AppStatus = .idle

    override init() {
        statusItem = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)
        super.init()
        let menu = NSMenu()
        menu.delegate = self
        statusItem.menu = menu
        renderButton()
    }

    // MARK: Public API

    func setStatus(_ status: AppStatus) {
        self.status = status
        renderButton()
    }

    // MARK: Button

    private func renderButton() {
        guard let button = statusItem.button else { return }
        let image = NSImage(systemSymbolName: status.symbol, accessibilityDescription: status.tooltip)
        image?.isTemplate = false
        button.image = image
        button.contentTintColor = status.color
        button.toolTip = status.tooltip
    }

    // MARK: Menu (rebuilt fresh on each open so state always matches settings)

    func menuNeedsUpdate(_ menu: NSMenu) {
        rebuild(menu)
    }

    private func rebuild(_ menu: NSMenu) {
        menu.removeAllItems()

        // — Master switch —
        menu.addItem(check("SingAR активен", on: settings.enabled, action: #selector(toggleEnabled)))

        menu.addItem(.separator())

        // — Режим активации —
        menu.addItem(header("Режим:"))
        radioGroup(DictationMode.allCases, current: settings.mode,
                   indent: 1, action: #selector(selectMode(_:)), into: menu)

        menu.addItem(check("Авто-пунктуация", on: settings.autoPunctuation, action: #selector(toggleAutoPunctuation)))
        menu.addItem(check("Голосовые команды", on: settings.voiceCommands, action: #selector(toggleVoiceCommands)))
        menu.addItem(check("Live-частичные транскрипты", on: settings.livePartials, action: #selector(toggleLivePartials)))

        menu.addItem(.separator())

        // — Фоновое медиа —
        menu.addItem(check("Пауза фонового медиа при записи", on: settings.pauseMedia, action: #selector(togglePauseMedia)))
        radioGroup(MediaPauseMode.allCases, current: settings.mediaMode,
                   indent: 1, action: #selector(selectMediaMode(_:)), into: menu)

        menu.addItem(.separator())

        // — Облачный шаг —
        menu.addItem(header("Облачный шаг:"))
        radioGroup(CloudStep.allCases, current: settings.cloudStep,
                   indent: 1, action: #selector(selectCloudStep(_:)), into: menu)

        menu.addItem(.separator())

        // — Язык / модель —
        menu.addItem(header("Язык:"))
        radioGroup(ASRLanguage.allCases, current: settings.language,
                   indent: 1, action: #selector(selectLanguage(_:)), into: menu)
        menu.addItem(header("Модель:"))
        radioGroup(ASRModel.allCases, current: settings.model,
                   indent: 1, action: #selector(selectModel(_:)), into: menu)

        menu.addItem(.separator())

        // — Прочее —
        menu.addItem(check("Запускать при входе", on: settings.launchAtLogin, action: #selector(toggleLaunchAtLogin)))
        menu.addItem(item("Хоткей…", action: #selector(configureHotkey)))
        menu.addItem(item("Настройки…", action: #selector(openSettings)))
        menu.addItem(.separator())
        menu.addItem(item("Quit SingAR", action: #selector(terminate), key: "q"))
    }

    // MARK: Menu item helpers

    private func check(_ title: String, on: Bool, action: Selector) -> NSMenuItem {
        let i = NSMenuItem(title: title, action: action, keyEquivalent: "")
        i.target = self
        i.state = on ? .on : .off
        return i
    }

    private func item(_ title: String, action: Selector, key: String = "") -> NSMenuItem {
        let i = NSMenuItem(title: title, action: action, keyEquivalent: key)
        i.target = self
        return i
    }

    private func header(_ title: String) -> NSMenuItem {
        let i = NSMenuItem(title: title, action: nil, keyEquivalent: "")
        i.isEnabled = false
        i.indentationLevel = 0
        return i
    }

    private func radioGroup<T: RawRepresentable & CaseIterable & Equatable>(
        _ cases: [T], current: T, indent: Int, action: Selector, into menu: NSMenu
    ) where T.AllCases: RandomAccessCollection, T.RawValue == String {
        for (index, value) in cases.enumerated() {
            let title = (value as? MenuTitled)?.title ?? String(describing: value)
            let i = NSMenuItem(title: title, action: action, keyEquivalent: "")
            i.target = self
            i.tag = index
            i.state = (value == current) ? .on : .off
            i.indentationLevel = indent
            menu.addItem(i)
        }
    }

    // MARK: Actions — bool toggles

    @objc private func toggleEnabled()        { settings.enabled = !settings.enabled }
    @objc private func toggleAutoPunctuation(){ settings.autoPunctuation = !settings.autoPunctuation }
    @objc private func toggleVoiceCommands()  { settings.voiceCommands = !settings.voiceCommands }
    @objc private func toggleLivePartials()   { settings.livePartials = !settings.livePartials }
    @objc private func togglePauseMedia()     { settings.pauseMedia = !settings.pauseMedia }
    @objc private func toggleLaunchAtLogin()  { settings.launchAtLogin = !settings.launchAtLogin }

    // MARK: Actions — radio groups (index → enum case)

    @objc private func selectMode(_ s: NSMenuItem)       { settings.mode = DictationMode.allCases[s.tag] }
    @objc private func selectMediaMode(_ s: NSMenuItem)  { settings.mediaMode = MediaPauseMode.allCases[s.tag] }
    @objc private func selectCloudStep(_ s: NSMenuItem)  { settings.cloudStep = CloudStep.allCases[s.tag] }
    @objc private func selectLanguage(_ s: NSMenuItem)   { settings.language = ASRLanguage.allCases[s.tag] }
    @objc private func selectModel(_ s: NSMenuItem)      { settings.model = ASRModel.allCases[s.tag] }

    // MARK: Actions — misc

    @objc private func configureHotkey() {
        // TODO(M2): open hotkey configuration window.
    }

    @objc private func openSettings() {
        // TODO(M5): open settings window.
    }

    @objc private func terminate() {
        NSApp.terminate(nil)
    }
}

/// Lets the generic radio-group helper reach a human title without forcing every
/// enum to conform to a shared protocol publicly.
private protocol MenuTitled {
    var title: String { get }
}
extension DictationMode: MenuTitled {}
extension MediaPauseMode: MenuTitled {}
extension CloudStep: MenuTitled {}
extension ASRLanguage: MenuTitled {}
extension ASRModel: MenuTitled {}
