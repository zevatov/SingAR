import SwiftUI
import AppKit

struct SettingsView: View {
    @ObservedObject private var settings = AppSettings.shared
    @ObservedObject private var history = DictationHistory.shared
    @ObservedObject private var modelManager = ModelDownloadManager.shared

    @State private var googleApiKey = ""
    @State private var openrouterKey = ""
    @State private var groqApiKey = ""
    @State private var verifyingAccounts: Set<String> = []
    @State private var keyStatusMap: [String: KeyValidationStatus] = [:]

    /// Этап 3: 500-мс дебаунс авто-верификации (1 запрос на паузу ввода).
    /// Сеть трогает только после 500 мс тишины; каждая правка отменяет
    /// предыдущий запрос. Ручная кнопка «Проверить» идёт мимо дебаунса.
    @State private var verifyDebouncer = KeyVerifyDebouncer()

    @State private var isMicGranted = false
    @State private var isAccessibilityGranted = false
    @State private var isSpeechGranted = false
    @State private var isHistoryExpanded = false
    @State private var copiedIndex: Int?

    private var allPermissionsGranted: Bool {
        isMicGranted && isAccessibilityGranted && isSpeechGranted
    }

    enum KeyValidationStatus: Equatable {
        case untested
        case valid
        case invalid(String)
    }

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 20) {
                // Header
                HStack(spacing: 12) {
                    ZStack {
                        RoundedRectangle(cornerRadius: 10)
                            .fill(Color.brandAccent.opacity(0.15))
                            .frame(width: 44, height: 44)
                        Image(systemName: "waveform.badge.mic")
                            .font(.system(size: 22, weight: .bold))
                            .foregroundColor(Color.brandAccent)
                    }

                    VStack(alignment: .leading, spacing: 2) {
                        Text("SingAR")
                            .font(.system(size: 18, weight: .bold))
                        Text("Голосовой ввод для разработчиков • Версия \(AppVersion.current)")
                            .font(.system(size: 11))
                            .foregroundColor(.secondary)
                    }

                    Spacer()

                    Link(destination: URL(string: "https://github.com/zevatov/SingAR")!) {
                        HStack(spacing: 4) {
                            Image(systemName: "curlybraces")
                                .font(.system(size: 12))
                            Text("GitHub")
                                .font(.system(size: 11, weight: .medium))
                        }
                        .padding(.horizontal, 8)
                        .padding(.vertical, 4)
                        .background(Color.primary.opacity(0.06))
                        .cornerRadius(6)
                    }
                    .buttonStyle(.plain)
                }

                // Section 0: System Permissions Alert (shown only when any permission is missing)
                if !allPermissionsGranted {
                    VStack(alignment: .leading, spacing: 10) {
                        HStack(spacing: 6) {
                            Image(systemName: "exclamationmark.triangle.fill")
                                .foregroundColor(Color.brandAmber)
                            Text("Требуются системные разрешения macOS")
                                .font(.system(size: 13, weight: .semibold))
                                .foregroundColor(.primary)
                        }

                        VStack(spacing: 8) {
                            permissionRow(
                                title: "Микрофон",
                                isGranted: isMicGranted,
                                icon: "mic",
                                onRequest: { PermissionChecker.shared.requestMicrophone() },
                                onOpenSettings: { PermissionChecker.shared.openSettings(for: .microphone) }
                            )

                            Divider()

                            permissionRow(
                                title: "Универсальный доступ (вставка текста)",
                                isGranted: isAccessibilityGranted,
                                icon: "accessibility",
                                onRequest: { PermissionChecker.shared.requestAccessibility() },
                                onOpenSettings: { PermissionChecker.shared.openSettings(for: .accessibility) }
                            )

                            Divider()

                            permissionRow(
                                title: "Распознавание речи",
                                isGranted: isSpeechGranted,
                                icon: "waveform",
                                onRequest: { PermissionChecker.shared.requestSpeechRecognition() },
                                onOpenSettings: { PermissionChecker.shared.openSettings(for: .speechRecognition) }
                            )
                        }
                        .padding(12)
                        .background(Color.brandCard)
                        .cornerRadius(10)
                        .overlay(
                            RoundedRectangle(cornerRadius: 10)
                                .stroke(Color.brandAmber.opacity(0.4), lineWidth: 1)
                        )
                    }
                }

                // Section 1: Speech Recognition Engine (Apple 2x2 Grid)
                VStack(alignment: .leading, spacing: 10) {
                    HStack {
                        Image(systemName: "cpu")
                            .font(.system(size: 13, weight: .semibold))
                            .foregroundColor(Color.brandAccent)
                        Text("Движок распознавания речи")
                            .font(.system(size: 13, weight: .semibold))
                    }

                    LazyVGrid(columns: [GridItem(.flexible(), spacing: 10), GridItem(.flexible(), spacing: 10)], spacing: 10) {
                        engineGridCard(
                            model: .localWhisperTurbo,
                            title: "Whisper Turbo",
                            subtitle: "Metal GPU • Офлайн",
                            icon: "cpu"
                        )

                        engineGridCard(
                            model: .gemini35Transcribe,
                            title: "Gemini 3.5",
                            subtitle: "Google AI • Бесплатно",
                            icon: "sparkles"
                        )

                        engineGridCard(
                            model: .groqWhisper,
                            title: "Groq Whisper",
                            subtitle: "LPUs • Сверхбыстро",
                            icon: "bolt.fill"
                        )

                        engineGridCard(
                            model: .gpt4oTranscribe,
                            title: "GPT-4o Audio",
                            subtitle: "OpenRouter • Точность",
                            icon: "brain.head.profile"
                        )
                    }

                    // Contextual Config Sub-Card for Selected Engine
                    VStack(alignment: .leading, spacing: 10) {
                        switch settings.cloudModel {
                        case .localWhisperTurbo:
                            localWhisperConfigView

                        case .gemini35Transcribe:
                            apiKeyConfigView(
                                serviceName: "Google AI Studio",
                                keyTitle: "Google AI Studio API Key:",
                                placeholder: "Вставьте AI Studio API Key (AIzaSy...)",
                                linkTitle: "Получить бесплатный ключ в AI Studio ↗",
                                linkURL: "https://aistudio.google.com/app/apikey",
                                keyBinding: $googleApiKey,
                                account: SecretStore.Account.googleApiKey
                            )

                        case .groqWhisper:
                            apiKeyConfigView(
                                serviceName: "Groq Cloud",
                                keyTitle: "Groq API Key:",
                                placeholder: "Вставьте Groq API Key (gsk_...)",
                                linkTitle: "console.groq.com/keys ↗",
                                linkURL: "https://console.groq.com/keys",
                                keyBinding: $groqApiKey,
                                account: SecretStore.Account.groqApiKey
                            )

                        case .gpt4oTranscribe:
                            apiKeyConfigView(
                                serviceName: "OpenRouter",
                                keyTitle: "OpenRouter API Key:",
                                placeholder: "Вставьте OpenRouter API Key (sk-or-...)",
                                linkTitle: "openrouter.ai/keys ↗",
                                linkURL: "https://openrouter.ai/keys",
                                keyBinding: $openrouterKey,
                                account: SecretStore.Account.openrouterKey
                            )

                        case .localOnly:
                            Text("Используется встроенный системный распознаватель Apple Speech.")
                                .font(.system(size: 11))
                                .foregroundColor(.secondary)
                        }
                    }
                    .padding(14)
                    .background(Color.brandCard)
                    .cornerRadius(10)
                    .overlay(
                        RoundedRectangle(cornerRadius: 10)
                            .stroke(Color.brandBorder, lineWidth: 1)
                    )
                }

                // Section 2: Hotkey & Activation
                VStack(alignment: .leading, spacing: 10) {
                    HStack {
                        Image(systemName: "keyboard")
                            .font(.system(size: 13, weight: .semibold))
                            .foregroundColor(Color.brandAccent)
                        Text("Горячие клавиши и Активация")
                            .font(.system(size: 13, weight: .semibold))
                    }

                    VStack(alignment: .leading, spacing: 12) {
                        HStack {
                            VStack(alignment: .leading, spacing: 2) {
                                Text("Клавиша диктовки:")
                                    .font(.system(size: 12, weight: .medium))
                                Text("Активация микрофона в любом приложении")
                                    .font(.system(size: 10))
                                    .foregroundColor(.secondary)
                            }
                            Spacer()
                            Picker("", selection: $settings.hotkey) {
                                ForEach(HotkeyChoice.allCases, id: \.self) { choice in
                                    Text(choice.title).tag(choice)
                                }
                            }
                            .labelsHidden()
                            .fixedSize()
                        }

                        Divider()

                        HStack {
                            VStack(alignment: .leading, spacing: 2) {
                                Text("Режим триггера:")
                                    .font(.system(size: 12, weight: .medium))
                                Text("Hold — удерживать клавишу; Toggle — нажал-сказал-нажал")
                                    .font(.system(size: 10))
                                    .foregroundColor(.secondary)
                            }
                            Spacer()
                            Picker("", selection: $settings.mode) {
                                ForEach(DictationMode.allCases, id: \.self) { mode in
                                    Text(mode.title).tag(mode)
                                }
                            }
                            .labelsHidden()
                            .fixedSize()
                        }

                        Divider()

                        Toggle("Запускать SingAR при входе в систему", isOn: Binding(
                            get: { settings.launchAtLogin },
                            set: { LaunchAtLoginManager.apply($0, settings: settings) }
                        ))
                            .toggleStyle(.checkbox)
                            .font(.system(size: 12))

                        Divider()

                        Toggle("Приостанавливать музыку и видео во время речи", isOn: $settings.pauseMedia)
                            .toggleStyle(.checkbox)
                            .font(.system(size: 12))

                        Divider()

                        VStack(alignment: .leading, spacing: 3) {
                            Toggle("Защита ввода: останавливать запись при смене окна", isOn: $settings.stopOnFocusLoss)
                                .toggleStyle(.checkbox)
                                .font(.system(size: 12))
                            Text("Если выключено, можно говорить и свободно переключаться между окнами/сайтами, а текст вставится при завершении записи.")
                                .font(.system(size: 10))
                                .foregroundColor(.secondary)
                                .padding(.leading, 18)
                        }
                    }
                    .padding(14)
                    .background(Color.brandCard)
                    .cornerRadius(10)
                    .overlay(
                        RoundedRectangle(cornerRadius: 10)
                            .stroke(Color.brandBorder, lineWidth: 1)
                    )
                }

                // Section 3: Speech & Formatting Behavior
                VStack(alignment: .leading, spacing: 10) {
                    HStack {
                        Image(systemName: "slider.horizontal.3")
                            .font(.system(size: 13, weight: .semibold))
                            .foregroundColor(Color.brandAccent)
                        Text("Параметры диктовки и форматирования")
                            .font(.system(size: 13, weight: .semibold))
                    }

                    VStack(alignment: .leading, spacing: 12) {
                        HStack {
                            VStack(alignment: .leading, spacing: 2) {
                                Text("Язык распознавания:")
                                    .font(.system(size: 12, weight: .medium))
                                Text("Автоматически переключается между русским и английским")
                                    .font(.system(size: 10))
                                    .foregroundColor(.secondary)
                            }
                            Spacer()
                            Picker("", selection: $settings.language) {
                                ForEach(ASRLanguage.allCases, id: \.self) { lang in
                                    Text(lang.title).tag(lang)
                                }
                            }
                            .labelsHidden()
                            .fixedSize()
                        }

                        Divider()

                        VStack(alignment: .leading, spacing: 3) {
                            Toggle("Постобработка для вайбкодеров (форматирование кода, пути, CLI)", isOn: $settings.cloudCleanup)
                                .toggleStyle(.checkbox)
                                .font(.system(size: 12))
                            Text("Интеллектуальная нормализация названий библиотек, camelCase, snake_case и git-команд.")
                                .font(.system(size: 10))
                                .foregroundColor(.secondary)
                                .padding(.leading, 18)
                        }

                        Divider()

                        VStack(alignment: .leading, spacing: 3) {
                            Toggle("Live-ввод: печатать слова прямо во время речи", isOn: $settings.livePartials)
                                .toggleStyle(.checkbox)
                                .font(.system(size: 12))
                            Text("По умолчанию выключено: готовый чистовик мгновенно вставляется после отпускания клавиши без стираний.")
                                .font(.system(size: 10))
                                .foregroundColor(.secondary)
                                .padding(.leading, 18)
                        }
                    }
                    .padding(14)
                    .background(Color.brandCard)
                    .cornerRadius(10)
                    .overlay(
                        RoundedRectangle(cornerRadius: 10)
                            .stroke(Color.brandBorder, lineWidth: 1)
                    )
                }

                // Section 4: Statistics & Logs
                VStack(alignment: .leading, spacing: 10) {
                    HStack {
                        Image(systemName: "chart.bar")
                            .font(.system(size: 13, weight: .semibold))
                            .foregroundColor(Color.brandAccent)
                        Text("Статистика и Диагностика")
                            .font(.system(size: 13, weight: .semibold))
                    }

                    VStack(alignment: .leading, spacing: 12) {
                        // 3-Metric Tile Row
                        HStack(spacing: 8) {
                            metricTile(title: "Диктовки", value: "\(history.totalDictations)", icon: "mic.fill")
                            metricTile(title: "Символы", value: "\(history.totalCharacters)", icon: "text.alignleft")
                            metricTile(title: "Среднее время", value: "\(history.averageLatencyMs) мс", icon: "clock.fill")
                        }

                        Divider()

                        // Action Buttons: Open Log / Open Folder / Clear History
                        HStack(spacing: 8) {
                            Button(action: {
                                NSWorkspace.shared.open(AppLogger.logFileURL)
                            }) {
                                Label("Лог (singar.log)", systemImage: "doc.text.magnifyingglass")
                                    .font(.system(size: 11))
                            }
                            .buttonStyle(.bordered)

                            Button(action: {
                                let appSupport = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first!
                                let dir = appSupport.appendingPathComponent("SingAR")
                                NSWorkspace.shared.open(dir)
                            }) {
                                Label("Папка данных", systemImage: "folder")
                                    .font(.system(size: 11))
                            }
                            .buttonStyle(.bordered)

                            Spacer()

                            Button(action: {
                                history.clear()
                            }) {
                                Label("Очистить", systemImage: "trash")
                                    .font(.system(size: 11))
                                    .foregroundColor(.secondary)
                            }
                            .buttonStyle(.bordered)
                        }
                    }
                    .padding(14)
                    .background(Color.brandCard)
                    .cornerRadius(10)
                    .overlay(
                        RoundedRectangle(cornerRadius: 10)
                            .stroke(Color.brandBorder, lineWidth: 1)
                    )
                }
            }
            .padding(.horizontal, 24)
            .padding(.vertical, 20)
        }
        .frame(minWidth: 540, minHeight: 640)
        .onAppear {
            LaunchAtLoginManager.syncFromSystem(settings: settings)
            googleApiKey = SecretStore.get(SecretStore.Account.googleApiKey) ?? ""
            openrouterKey = SecretStore.get(SecretStore.Account.openrouterKey) ?? ""
            groqApiKey = SecretStore.get(SecretStore.Account.groqApiKey) ?? ""
            modelManager.refreshStatus()
            history.reload()
            checkPermissions()
            verifyCurrentKey()
        }
        .onReceive(Timer.publish(every: 2.5, on: .main, in: .common).autoconnect()) { _ in
            checkPermissions()
        }
        .onReceive(NotificationCenter.default.publisher(for: NSApplication.didBecomeActiveNotification)) { _ in
            checkPermissions()
        }
    }

    // MARK: - Engine Grid Card

    private func engineGridCard(model: CloudModel, title: String, subtitle: String, icon: String) -> some View {
        let isSelected = (settings.cloudModel == model)
        return Button {
            withAnimation(.easeInOut(duration: 0.18)) {
                settings.cloudModel = model
            }
            verifyCurrentKey()
        } label: {
            HStack(spacing: 10) {
                ZStack {
                    Circle()
                        .fill(isSelected ? Color.brandAccent.opacity(0.2) : Color.primary.opacity(0.06))
                        .frame(width: 32, height: 32)
                    Image(systemName: icon)
                        .font(.system(size: 14, weight: .semibold))
                        .foregroundColor(isSelected ? Color.brandAccent : Color.primary)
                }

                VStack(alignment: .leading, spacing: 2) {
                    Text(title)
                        .font(.system(size: 12, weight: isSelected ? .bold : .medium))
                        .foregroundColor(.primary)
                    Text(subtitle)
                        .font(.system(size: 10))
                        .foregroundColor(.secondary)
                }

                Spacer()

                if isSelected {
                    Image(systemName: "checkmark.circle.fill")
                        .foregroundColor(Color.brandAccent)
                        .font(.system(size: 14))
                }
            }
            .padding(10)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(isSelected ? Color.brandAccent.opacity(0.08) : Color.brandCard)
            .cornerRadius(8)
            .overlay(
                RoundedRectangle(cornerRadius: 8)
                    .stroke(isSelected ? Color.brandAccent : Color.brandBorder, lineWidth: isSelected ? 1.5 : 1)
            )
        }
        .buttonStyle(.plain)
    }

    // MARK: - Local Whisper Sub-Card

    private var localWhisperConfigView: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack {
                VStack(alignment: .leading, spacing: 2) {
                    Text("Модель Whisper Large Turbo")
                        .font(.system(size: 12, weight: .medium))
                    Text("1.6 ГБ • Локальный запуск на Apple Metal GPU (M1/M2/M3/M4)")
                        .font(.system(size: 10))
                        .foregroundColor(.secondary)
                }
                Spacer()

                switch modelManager.status {
                case .installed:
                    HStack(spacing: 4) {
                        Image(systemName: "checkmark.circle.fill")
                            .foregroundColor(Color.brandGreen)
                        Text("Готова к работе")
                            .font(.system(size: 11, weight: .semibold))
                            .foregroundColor(Color.brandGreen)
                    }
                case .downloading(let progress):
                    Text("\(Int(progress * 100))%")
                        .font(.system(size: 11, weight: .bold))
                        .foregroundColor(Color.brandAccent)
                case .error:
                    Text("Ошибка загрузки")
                        .font(.system(size: 11))
                        .foregroundColor(.red)
                case .notDownloaded:
                    Text("Не загружена")
                        .font(.system(size: 11))
                        .foregroundColor(.secondary)
                }
            }

            switch modelManager.status {
            case .downloading(let progress):
                ProgressView(value: progress)
                    .progressViewStyle(.linear)
            case .notDownloaded, .error:
                Button(action: {
                    modelManager.startDownload()
                }) {
                    HStack {
                        Image(systemName: "arrow.down.circle")
                        Text("Скачать модель (1.6 ГБ)")
                    }
                    .font(.system(size: 11, weight: .semibold))
                }
                .buttonStyle(.borderedProminent)
                .controlSize(.small)
            case .installed:
                EmptyView()
            }
        }
    }

    // MARK: - Cloud API Key Sub-Card

    private func apiKeyConfigView(
        serviceName: String,
        keyTitle: String,
        placeholder: String,
        linkTitle: String,
        linkURL: String,
        keyBinding: Binding<String>,
        account: String
    ) -> some View {
        let isVerifying = verifyingAccounts.contains(account)
        let status = keyStatusMap[account] ?? .untested

        return VStack(alignment: .leading, spacing: 8) {
            HStack {
                Text(keyTitle)
                    .font(.system(size: 12, weight: .medium))
                Spacer()
                if let url = URL(string: linkURL) {
                    Link(linkTitle, destination: url)
                        .font(.system(size: 11))
                        .foregroundColor(Color.brandAccent)
                }
            }

            HStack(spacing: 8) {
                SecureField(placeholder, text: keyBinding)
                    .textFieldStyle(.roundedBorder)
                    .font(.system(size: 11))
                    .onChange(of: keyBinding.wrappedValue) { _, newValue in
                        SecretStore.set(newValue, for: account)
                        keyStatusMap[account] = .untested
                        // Этап 3: авто-верификация через дебаунс. Сеть только
                        // после 500 мс тишины; ручная кнопка — без дебаунса.
                        if KeyVerifyDebouncer.shouldScheduleNetworkVerify(rawKey: newValue) {
                            verifyDebouncer.schedule { [account] in
                                self.verifyKey(for: account)
                            }
                        }
                    }

                Button(action: {
                    verifyKey(for: account)
                }) {
                    if isVerifying {
                        ProgressView()
                            .controlSize(.small)
                            .frame(width: 60)
                    } else {
                        Text("Проверить")
                            .font(.system(size: 11, weight: .semibold))
                            .frame(width: 60)
                    }
                }
                .buttonStyle(.bordered)
                .disabled(keyBinding.wrappedValue.isEmpty || isVerifying)
            }

            // Key Validation Status Feedback & Keychain Security
            HStack(spacing: 6) {
                Image(systemName: "lock.fill")
                    .font(.system(size: 10))
                    .foregroundColor(.secondary)
                Text("Keychain macOS")
                    .font(.system(size: 10))
                    .foregroundColor(.secondary)

                Spacer()

                switch status {
                case .untested:
                    EmptyView()
                case .valid:
                    HStack(spacing: 4) {
                        Image(systemName: "checkmark.circle.fill")
                            .foregroundColor(Color.brandGreen)
                            .font(.system(size: 11))
                        Text("Ключ \(serviceName) проверен")
                            .font(.system(size: 10, weight: .medium))
                            .foregroundColor(Color.brandGreen)
                    }
                case .invalid(let err):
                    HStack(spacing: 4) {
                        Image(systemName: "exclamationmark.triangle.fill")
                            .foregroundColor(.red)
                            .font(.system(size: 11))
                        Text("Ошибка: \(err)")
                            .font(.system(size: 10))
                            .foregroundColor(.red)
                            .lineLimit(1)
                    }
                }
            }
        }
    }

    // MARK: - Metric Tile

    private func metricTile(title: String, value: String, icon: String) -> some View {
        VStack(spacing: 4) {
            Image(systemName: icon)
                .font(.system(size: 14))
                .foregroundColor(Color.brandAccent)
            Text(title)
                .font(.system(size: 10))
                .foregroundColor(.secondary)
            Text(value)
                .font(.system(size: 13, weight: .bold))
                .foregroundColor(.primary)
        }
        .padding(.vertical, 8)
        .frame(maxWidth: .infinity)
        .background(Color.primary.opacity(0.03))
        .cornerRadius(8)
    }

    // MARK: - Permission Row

    private func permissionRow(
        title: String,
        isGranted: Bool,
        icon: String,
        onRequest: @escaping () -> Void,
        onOpenSettings: @escaping () -> Void
    ) -> some View {
        HStack(spacing: 10) {
            Image(systemName: icon)
                .font(.system(size: 14))
                .foregroundColor(isGranted ? Color.brandGreen : Color.brandAmber)
                .frame(width: 20)

            Text(title)
                .font(.system(size: 12, weight: .medium))

            Spacer()

            if isGranted {
                HStack(spacing: 4) {
                    Image(systemName: "checkmark.circle.fill")
                        .foregroundColor(Color.brandGreen)
                    Text("Разрешено")
                        .font(.system(size: 11, weight: .semibold))
                        .foregroundColor(Color.brandGreen)
                }
            } else {
                HStack(spacing: 6) {
                    Button(action: onRequest) {
                        Text("Выдать")
                            .font(.system(size: 11, weight: .semibold))
                    }
                    .buttonStyle(.borderedProminent)
                    .controlSize(.small)

                    Button(action: onOpenSettings) {
                        Text("Настройки ↗")
                            .font(.system(size: 11))
                    }
                    .buttonStyle(.bordered)
                    .controlSize(.small)
                }
            }
        }
    }

    // MARK: - Verification Logic

    private func checkPermissions() {
        isMicGranted = (PermissionChecker.shared.status(of: .microphone) == .granted)
        isAccessibilityGranted = (PermissionChecker.shared.status(of: .accessibility) == .granted)
        isSpeechGranted = (PermissionChecker.shared.status(of: .speechRecognition) == .granted)
    }

    private func verifyCurrentKey() {
        switch settings.cloudModel {
        case .gemini35Transcribe:
            verifyGeminiKey()
        case .groqWhisper:
            verifyGroqKey()
        case .gpt4oTranscribe:
            verifyOpenRouterKey()
        default:
            break
        }
    }

    private func verifyKey(for account: String) {
        switch account {
        case SecretStore.Account.googleApiKey:
            verifyGeminiKey()
        case SecretStore.Account.groqApiKey:
            verifyGroqKey()
        case SecretStore.Account.openrouterKey:
            verifyOpenRouterKey()
        default:
            break
        }
    }

    // MARK: - Verification Logic (Этап 3: общий проверяемый путь)

    /// Этап 3: единый путь verify для всех трёх аккаунтов — trim через
    /// `SecretStore.normalizedKey`, таймаут 8 с, typed-статусы.
    /// Вызывается дебаунсером (onChange) и вручную кнопкой «Проверить».
    private func runVerify(account: String, makeRequest: @escaping (String) -> URLRequest) {
        guard let raw = storedRawKey(for: account),
              let trimmedKey = SecretStore.normalizedKey(raw) else { return }
        verifyingAccounts.insert(account)
        keyStatusMap[account] = .untested

        Task {
            var request = makeRequest(trimmedKey)
            request.timeoutInterval = 8

            do {
                let (data, response) = try await URLSession.shared.data(for: request)
                let http = response as? HTTPURLResponse
                let code = http?.statusCode ?? 0
                await MainActor.run {
                    self.verifyingAccounts.remove(account)
                    if code == 200 {
                        self.keyStatusMap[account] = .valid
                    } else {
                        if let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
                           let err = json["error"] as? [String: Any],
                           let msg = err["message"] as? String {
                            self.keyStatusMap[account] = .invalid(msg)
                        } else {
                            self.keyStatusMap[account] = .invalid("HTTP \(code)")
                        }
                    }
                }
            } catch {
                await MainActor.run {
                    self.verifyingAccounts.remove(account)
                    self.keyStatusMap[account] = .invalid(error.localizedDescription)
                }
            }
        }
    }

    private func storedRawKey(for account: String) -> String? {
        switch account {
        case SecretStore.Account.googleApiKey: return googleApiKey
        case SecretStore.Account.groqApiKey:   return groqApiKey
        case SecretStore.Account.openrouterKey: return openrouterKey
        default: return nil
        }
    }

    private func verifyGeminiKey() {
        // Этап 0: ключ только в заголовке x-goog-api-key (аналогия с Bearer),
        // никогда в query URL — URL без секрета безопасно логировать.
        runVerify(account: SecretStore.Account.googleApiKey) {
            SecretStore.geminiRequest(url: URL(string: "https://generativelanguage.googleapis.com/v1beta/models")!, apiKey: $0)
        }
    }

    private func verifyGroqKey() {
        runVerify(account: SecretStore.Account.groqApiKey) { key in
            var req = URLRequest(url: URL(string: "https://api.groq.com/openai/v1/models")!)
            req.setValue("Bearer \(key)", forHTTPHeaderField: "Authorization")
            return req
        }
    }

    private func verifyOpenRouterKey() {
        runVerify(account: SecretStore.Account.openrouterKey) { key in
            var req = URLRequest(url: URL(string: "https://openrouter.ai/api/v1/auth/key")!)
            req.setValue("Bearer \(key)", forHTTPHeaderField: "Authorization")
            return req
        }
    }
}
