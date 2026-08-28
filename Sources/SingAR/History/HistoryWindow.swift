import AppKit

/// Native macOS window displaying up to 50 recent dictation history entries.
final class HistoryWindow: NSWindowController, NSTableViewDataSource, NSTableViewDelegate {

    private var tableView: NSTableView!
    private var entries: [DictationHistoryEntry] = []
    private var dateFormatter: DateFormatter = {
        let df = DateFormatter()
        df.dateStyle = .short
        df.timeStyle = .medium
        return df
    }()

    convenience init() {
        let window = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 620, height: 420),
            styleMask: [.titled, .closable, .resizable, .miniaturizable],
            backing: .buffered, defer: false
        )
        window.title = "История диктовки"
        window.minSize = NSSize(width: 480, height: 300)
        window.isReleasedWhenClosed = false
        window.center()
        self.init(window: window)

        setupUI()
    }

    private func setupUI() {
        guard let window = window, let contentView = window.contentView else { return }

        // Header view
        let headerLabel = NSTextField(labelWithString: "История последних записей (максимум 50):")
        headerLabel.translatesAutoresizingMaskIntoConstraints = false
        headerLabel.font = NSFont.systemFont(ofSize: 13, weight: .medium)
        headerLabel.textColor = .secondaryLabelColor
        contentView.addSubview(headerLabel)

        // ScrollView & TableView
        let scrollView = NSScrollView()
        scrollView.translatesAutoresizingMaskIntoConstraints = false
        scrollView.hasVerticalScroller = true
        scrollView.hasHorizontalScroller = false
        scrollView.autohidesScrollers = true
        scrollView.borderType = .noBorder

        tableView = NSTableView()
        tableView.usesAlternatingRowBackgroundColors = true
        tableView.headerView = NSTableHeaderView()
        tableView.rowHeight = 58
        tableView.columnAutoresizingStyle = .uniformColumnAutoresizingStyle

        // Column 1: Metadata (Time, Provider, Model, Latency)
        let colMeta = NSTableColumn(identifier: NSUserInterfaceItemIdentifier("MetaColumn"))
        colMeta.title = "Детали"
        colMeta.width = 170
        colMeta.minWidth = 140
        tableView.addTableColumn(colMeta)

        // Column 2: Text
        let colText = NSTableColumn(identifier: NSUserInterfaceItemIdentifier("TextColumn"))
        colText.title = "Распознанный текст"
        colText.width = 410
        colText.minWidth = 240
        tableView.addTableColumn(colText)

        tableView.dataSource = self
        tableView.delegate = self
        scrollView.documentView = tableView
        contentView.addSubview(scrollView)

        // Footer view / Close button
        let closeButton = NSButton(title: "Закрыть", target: self, action: #selector(closeWindow))
        closeButton.translatesAutoresizingMaskIntoConstraints = false
        closeButton.bezelStyle = .rounded
        closeButton.keyEquivalent = "\u{1b}" // ESC key
        contentView.addSubview(closeButton)

        NSLayoutConstraint.activate([
            headerLabel.topAnchor.constraint(equalTo: contentView.topAnchor, constant: -16),
            headerLabel.leadingAnchor.constraint(equalTo: contentView.leadingAnchor, constant: 16),
            headerLabel.trailingAnchor.constraint(equalTo: contentView.trailingAnchor, constant: -16),

            scrollView.topAnchor.constraint(equalTo: headerLabel.bottomAnchor, constant: -12),
            scrollView.leadingAnchor.constraint(equalTo: contentView.leadingAnchor, constant: 16),
            scrollView.trailingAnchor.constraint(equalTo: contentView.trailingAnchor, constant: -16),
            scrollView.bottomAnchor.constraint(equalTo: closeButton.topAnchor, constant: 12),

            closeButton.trailingAnchor.constraint(equalTo: contentView.trailingAnchor, constant: -16),
            closeButton.bottomAnchor.constraint(equalTo: contentView.bottomAnchor, constant: 16),
            closeButton.widthAnchor.constraint(equalToConstant: 90)
        ])

        // Accessibility
        window.setAccessibilityLabel("Окно истории диктовки")
        tableView.setAccessibilityLabel("Таблица историй распознавания")
        closeButton.setAccessibilityLabel("Закрыть историю")
    }

    func show() {
        reloadHistory()
        showWindow(nil)
        window?.makeKeyAndOrderFront(nil)
        NSApp.activate(ignoringOtherApps: true)
    }

    @objc private func closeWindow() {
        window?.performClose(nil)
    }

    private func reloadHistory() {
        entries = DictationHistory.shared.entries().reversed() // Newest first
        tableView.reloadData()
    }

    // MARK: - NSTableViewDataSource & Delegate

    func numberOfRows(in tableView: NSTableView) -> Int {
        return entries.count
    }

    func tableView(_ tableView: NSTableView, viewFor tableColumn: NSTableColumn?, row: Int) -> NSView? {
        guard row < entries.count else { return nil }
        let entry = entries[row]

        if tableColumn?.identifier.rawValue == "MetaColumn" {
            let container = NSView()
            let timeLabel = NSTextField(labelWithString: dateFormatter.string(from: entry.timestamp))
            timeLabel.translatesAutoresizingMaskIntoConstraints = false
            timeLabel.font = NSFont.systemFont(ofSize: 11, weight: .bold)
            timeLabel.textColor = .labelColor
            container.addSubview(timeLabel)

            let modelText = "\(entry.provider)/\(entry.model)"
            let modelLabel = NSTextField(labelWithString: modelText)
            modelLabel.translatesAutoresizingMaskIntoConstraints = false
            modelLabel.font = NSFont.systemFont(ofSize: 10, weight: .regular)
            modelLabel.textColor = .secondaryLabelColor
            container.addSubview(modelLabel)

            let latencyLabel = NSTextField(labelWithString: "\(entry.latencyMs) мс")
            latencyLabel.translatesAutoresizingMaskIntoConstraints = false
            latencyLabel.font = NSFont.systemFont(ofSize: 10, weight: .medium)
            latencyLabel.textColor = .systemBlue
            container.addSubview(latencyLabel)

            NSLayoutConstraint.activate([
                timeLabel.topAnchor.constraint(equalTo: container.topAnchor, constant: 6),
                timeLabel.leadingAnchor.constraint(equalTo: container.leadingAnchor, constant: 4),

                modelLabel.topAnchor.constraint(equalTo: timeLabel.bottomAnchor, constant: 2),
                modelLabel.leadingAnchor.constraint(equalTo: container.leadingAnchor, constant: 4),
                modelLabel.trailingAnchor.constraint(equalTo: container.trailingAnchor, constant: -4),

                latencyLabel.topAnchor.constraint(equalTo: modelLabel.bottomAnchor, constant: 2),
                latencyLabel.leadingAnchor.constraint(equalTo: container.leadingAnchor, constant: 4)
            ])

            container.setAccessibilityElement(true)
            container.setAccessibilityLabel("Запись от \(dateFormatter.string(from: entry.timestamp)), модель \(entry.provider), задержка \(entry.latencyMs) мс")
            return container
        } else {
            let textField = NSTextField(wrappingLabelWithString: entry.text)
            textField.font = NSFont.systemFont(ofSize: 12, weight: .regular)
            textField.textColor = .labelColor
            textField.maximumNumberOfLines = 3
            textField.cell?.lineBreakMode = .byTruncatingTail
            textField.setAccessibilityElement(true)
            textField.setAccessibilityLabel("Расшифрованный текст: \(entry.text)")
            return textField
        }
    }
}
