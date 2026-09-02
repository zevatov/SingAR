import SwiftUI
import AppKit

struct SettingsView: View {
    @ObservedObject private var settings = AppSettings.shared
    @ObservedObject private var history = DictationHistory.shared
    @ObservedObject private var modelManager = ModelDownloadManager.shared

    @State private var googleApiKey = ""
    @State private var openrouterKey = ""
    @State private var groqApiKey = ""
    @State private var isVerifyingKey = false
    @State private var keyStatus: KeyValidationStatus = .untested

    @State private var isMicGranted = false
    @State private var isAccessibilityGranted = false
    @State private var isSpeechGranted = false
    @State private var isHistoryExpanded = false
    @State private var copiedIndex: Int?

    private var allPermissionsGranted: Bool {
        isMicGranted && isAccessibilityGranted && isSpeechGranted
    }

    enum KeyValidationStatus {
        case untested
        case valid
        case invalid(String)
    }

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 18) {
                // Header
                HStack {
                    Image(systemName: "waveform.badge.mic")
                        .font(.system(size: 24, weight: .bold))
                        .foregroundColor(Color.brandAccent)
                    VStack(alignment: .leading, spacing: 2) {
                        Text("Настройки SingAR")
                            .font(.title2)
                            .fontWeight(.bold)
                        Text("Версия 2.1 beta")
                            .font(.caption)
                            .foregroundColor(.secondary)
                    }

                    Spacer()

                    // Quick Links (GitHub)
                    Link(destination: URL(string: "https://github.com/your_github_repo")!) {
                        VStack(spacing: 3) {
                            Image(systemName: "curlybraces")
                                .font(.system(size: 14))
                                .foregroundColor(.primary)
                            Text("GitHub")
                                .font(.system(size: 9))
                                .foregroundColor(.secondary)
                        }
                    }
                    .buttonStyle(.plain)
                }
                .padding(.horizontal, 4)

                Divider()

                // Section 1: Speech-to-Text Engine & API Keys
                VStack(alignment: .leading, spacing: 10) {
                    HStack {
                        Image(systemName: "cpu")
                            .foregroundColor(Color.brandAccent)
                        Text("Движок распознавания речи")
                            .font(.headline)
                            .foregroundColor(.primary)
                        Spacer()
                    }

                    VStack(spacing: 12) {
                        // Engine Picker
                        HStack {
                            Text("Провайдер:")
                                .font(.system(size: 12, weight: .medium))
                            Spacer()
                            Picker("", selection: $settings.cloudModel) {
                                ForEach(CloudModel.allCases, id: \.self) { m in
                                    Text(m.title).tag(m)
                                }
                            }
                            .labelsHidden()
                            .fixedSize()
                        }

                        Divider()

                        // Contextual settings per model
                        switch settings.cloudModel {
                        case .localWhisperTurbo:
                            VStack(alignment: .leading, spacing: 8) {
                                HStack {
                                    VStack(alignment: .leading, spacing: 2) {
                                        Text("Модель Whisper Large v3 Turbo")
                                            .font(.system(size: 12, weight: .semibold))
                                        Text("100% автономно на Metal GPU Apple Silicon, 0 ключей.")
                                            .font(.system(size: 10))
                                            .foregroundColor(.secondary)
                                    }
                                    Spacer()

                                    if modelManager.isModelInstalled {
                                        HStack(spacing: 6) {
                                            HStack(spacing: 3) {
                                                Image(systemName: "checkmark.circle.fill")
                                                    .foregroundColor(Color.brandGreen)
                                                Text("Установлена")
                                                    .font(.system(size: 11, weight: .semibold))
                                                    .foregroundColor(Color.brandGreen)
                                            }

                                            Button("Удалить") {
                                                modelManager.deleteModel()
                                            }
                                            .controlSize(.small)
                                        }
                                    } else if case .downloading = modelManager.status {
                                        Button("Отмена") {
                                            modelManager.cancelDownload()
                                        }
                                        .controlSize(.small)
                                    } else {
                                        Button("Скачать (~1.5 ГБ)") {
                                            modelManager.startDownload()
                                        }
                                        .buttonStyle(.borderedProminent)
                                        .tint(Color.brandAccent)
                                        .controlSize(.small)
                                    }
                                }

                                if case .downloading(let progress) = modelManager.status {
                                    VStack(alignment: .leading, spacing: 2) {
                                        ProgressView(value: progress)
                                        Text("Загрузка: \(Int(progress * 100))%")
                                            .font(.system(size: 10))
                                            .foregroundColor(.secondary)
                                    }
                                }
                            }

                        case .gemini35Transcribe:
                            VStack(alignment: .leading, spacing: 6) {
                                HStack {
                                    Text("Google AI Studio API Key:")
                                        .font(.system(size: 12, weight: .medium))
                                    Spacer()
                                    Link("Получить бесплатно ↗", destination: URL(string: "https://aistudio.google.com/app/apikey")!)
                                        .font(.system(size: 11))
                                        .foregroundColor(Color.brandAccent)
                                }

                                HStack {
                                    SecureField("Вставьте Google API Key", text: $googleApiKey)
                                        .textFieldStyle(.roundedBorder)
                                        .onChange(of: googleApiKey) { _, newValue in
                                            SecretStore.set(newValue, for: SecretStore.Account.googleApiKey)
                                            keyStatus = .untested
                                        }

                                    Button(action: verifyGoogleKey) {
                                        if isVerifyingKey {
                                            ProgressView().controlSize(.small)
                                        } else {
                                            Text("Проверить")
                                        }
                                    }
                                    .disabled(googleApiKey.isEmpty || isVerifyingKey)
                                }

                                switch keyStatus {
                                case .untested:
                                    EmptyView()
                                case .valid:
                                    HStack(spacing: 4) {
                                        Image(systemName: "checkmark.circle.fill")
                                            .foregroundColor(Color.brandGreen)
                                        Text("Ключ активен!")
                                            .font(.caption)
                                            .foregroundColor(Color.brandGreen)
                                    }
                                case .invalid(let err):
                                    HStack(spacing: 4) {
                                        Image(systemName: "exclamationmark.triangle.fill")
                                            .foregroundColor(.red)
                                        Text("Ошибка: \(err)")
                                            .font(.caption)
                                            .foregroundColor(.red)
                                    }
                                }
                            }

                        case .gpt4oTranscribe:
                            VStack(alignment: .leading, spacing: 6) {
                                HStack {
                                    Text("OpenRouter API Key:")
                                        .font(.system(size: 12, weight: .medium))
                                    Spacer()
                                    Link("openrouter.ai/keys ↗", destination: URL(string: "https://openrouter.ai/keys")!)
                                        .font(.system(size: 11))
                                        .foregroundColor(Color.brandAccent)
                                }

                                SecureField("Вставьте OpenRouter API Key (sk-or-...)", text: $openrouterKey)
                                    .textFieldStyle(.roundedBorder)
                                    .onChange(of: openrouterKey) { _, newValue in
                                        SecretStore.set(newValue, for: SecretStore.Account.openrouterKey)
                                    }
                            }

                        case .groqWhisper:
                            VStack(alignment: .leading, spacing: 6) {
                                HStack {
                                    Text("Groq API Key:")
                                        .font(.system(size: 12, weight: .medium))
                                    Spacer()
                                    Link("console.groq.com/keys ↗", destination: URL(string: "https://console.groq.com/keys")!)
                                        .font(.system(size: 11))
                                        .foregroundColor(Color.brandAccent)
                                }

                                SecureField("Вставьте Groq API Key (gsk_...)", text: $groqApiKey)
                                    .textFieldStyle(.roundedBorder)
                                    .onChange(of: groqApiKey) { _, newValue in
                                        SecretStore.set(newValue, for: SecretStore.Account.groqApiKey)
                                    }
                            }

                        case .localOnly:
                            Text("Используется встроенный системный распознаватель Apple Speech. Качество для кода ограничено.")
                                .font(.system(size: 11))
                                .foregroundColor(.secondary)
                        }
                    }
                    .padding(12)
                    .background(Color.brandCard)
                    .cornerRadius(10)
                    .overlay(
                        RoundedRectangle(cornerRadius: 10)
                            .stroke(Color.brandBorder, lineWidth: 1)
                    )
                }

                // Section 2: Hotkey & Trigger Mode
                VStack(alignment: .leading, spacing: 10) {
                    Text("Горячие клавиши и Активация")
                        .font(.headline)
                        .foregroundColor(.primary)

                    VStack(spacing: 12) {
                        HStack {
                            VStack(alignment: .leading, spacing: 2) {
                                Text("Клавиша диктовки:")
                                    .font(.system(size: 12, weight: .medium))
                                Text("Удерживайте для голосового ввода")
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
                            Text("Режим триггера:")
                                .font(.system(size: 12, weight: .medium))
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

                        Toggle("Запускать SingAR при входе в систему", isOn: $settings.launchAtLogin)
                            .toggleStyle(.checkbox)
                            .font(.system(size: 12))
                    }
                    .padding(12)
                    .background(Color.brandCard)
                    .cornerRadius(10)
                    .overlay(
                        RoundedRectangle(cornerRadius: 10)
                            .stroke(Color.brandBorder, lineWidth: 1)
                    )
                }

                // Section 3: Speech & Dictation Behavior
                VStack(alignment: .leading, spacing: 10) {
                    Text("Поведение диктовки")
                        .font(.headline)
                        .foregroundColor(.primary)

                    VStack(spacing: 10) {
                        HStack {
                            Text("Язык распознавания:")
                                .font(.system(size: 12))
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

                        Toggle("Облачная постобработка через Gemini (форматирование кода, слэши)", isOn: $settings.cloudCleanup)
                            .toggleStyle(.checkbox)
                            .font(.system(size: 12))

                        Divider()

                        VStack(alignment: .leading, spacing: 4) {
                            Toggle("Live-ввод: печатать текст прямо во время речи", isOn: $settings.livePartials)
                                .toggleStyle(.checkbox)
                                .font(.system(size: 12))
                            Text("Рекомендуется держать выключенным: готовый отполированный текст вставляется целиком после завершения речи без мерцания и стираний.")
                                .font(.system(size: 10))
                                .foregroundColor(.secondary)
                        }

                        Divider()

                        Toggle("Приостанавливать музыку и видео во время речи", isOn: $settings.pauseMedia)
                            .toggleStyle(.checkbox)
                            .font(.system(size: 12))
                    }
                    .padding(12)
                    .background(Color.brandCard)
                    .cornerRadius(10)
                    .overlay(
                        RoundedRectangle(cornerRadius: 10)
                            .stroke(Color.brandBorder, lineWidth: 1)
                    )
                }

                // Section 4: Statistics & History (ReTypeR-style)
                VStack(alignment: .leading, spacing: 10) {
                    Text("Статистика и История")
                        .font(.headline)
                        .foregroundColor(.primary)

                    VStack(alignment: .leading, spacing: 12) {
                        // 2x2 Metric Grid
                        LazyVGrid(columns: [GridItem(.flexible(), spacing: 10), GridItem(.flexible(), spacing: 10)], spacing: 10) {
                            // Cell 1: Dictations count
                            VStack(spacing: 4) {
                                Image(systemName: "mic.fill")
                                    .font(.title3)
                                    .foregroundColor(Color.brandAccent)
                                Text("Диктовки")
                                    .font(.system(size: 12))
                                    .foregroundColor(.secondary)
                                Text("\(history.totalDictations)")
                                    .font(.system(size: 14, weight: .bold))
                            }
                            .padding(.vertical, 10)
                            .frame(maxWidth: .infinity)
                            .background(Color.primary.opacity(0.03))
                            .cornerRadius(8)

                            // Cell 2: Characters count
                            VStack(spacing: 4) {
                                Image(systemName: "character.textbox")
                                    .font(.title3)
                                    .foregroundColor(Color.brandGreen)
                                Text("Символы")
                                    .font(.system(size: 12))
                                    .foregroundColor(.secondary)
                                Text("\(history.totalCharacters)")
                                    .font(.system(size: 14, weight: .bold))
                            }
                            .padding(.vertical, 10)
                            .frame(maxWidth: .infinity)
                            .background(Color.primary.opacity(0.03))
                            .cornerRadius(8)

                            // Cell 3: History Toggle Button
                            Button(action: {
                                withAnimation(.spring(response: 0.3, dampingFraction: 0.8)) {
                                    history.reload()
                                    isHistoryExpanded.toggle()
                                }
                            }) {
                                VStack(spacing: 4) {
                                    Image(systemName: "clock.arrow.circlepath")
                                        .font(.title3)
                                        .foregroundColor(isHistoryExpanded ? Color.brandAccent : .secondary)
                                    Text("История")
                                        .font(.system(size: 12))
                                        .foregroundColor(.primary)
                                    Text(isHistoryExpanded ? "Скрыть" : "Показать (\(history.items.count))")
                                        .font(.system(size: 9))
                                        .foregroundColor(.secondary)
                                }
                                .padding(.vertical, 10)
                                .frame(maxWidth: .infinity)
                                .background(Color.primary.opacity(isHistoryExpanded ? 0.08 : 0.03))
                                .cornerRadius(8)
                            }
                            .buttonStyle(.plain)

                            // Cell 4: Reset Button
                            Button(action: {
                                history.clear()
                            }) {
                                VStack(spacing: 4) {
                                    Image(systemName: "trash")
                                        .font(.title3)
                                        .foregroundColor(.secondary)
                                    Text("Очистить")
                                        .font(.system(size: 12))
                                        .foregroundColor(.primary)
                                    Text("Сбросить историю")
                                        .font(.system(size: 9))
                                        .foregroundColor(.secondary)
                                }
                                .padding(.vertical, 10)
                                .frame(maxWidth: .infinity)
                                .background(Color.primary.opacity(0.03))
                                .cornerRadius(8)
                            }
                            .buttonStyle(.plain)
                        }

                        // Collapsible History List in Settings
                        if isHistoryExpanded {
                            let entries = Array(history.items.reversed())
                            if entries.isEmpty {
                                Text("История записей пуста")
                                    .font(.system(size: 11))
                                    .foregroundColor(.secondary)
                                    .frame(maxWidth: .infinity, alignment: .center)
                                    .padding(.vertical, 12)
                            } else {
                                ScrollView {
                                    VStack(spacing: 6) {
                                        ForEach(Array(entries.enumerated()), id: \.offset) { index, item in
                                            Button {
                                                copyToClipboard(item.text, at: index)
                                            } label: {
                                                VStack(alignment: .leading, spacing: 3) {
                                                    HStack {
                                                        Text(formatTime(item.timestamp))
                                                            .font(.system(size: 10))
                                                            .foregroundColor(.secondary)
                                                        Spacer()
                                                        if copiedIndex == index {
                                                            Text("Скопировано!")
                                                                .font(.system(size: 10, weight: .bold))
                                                                .foregroundColor(Color.brandGreen)
                                                        } else {
                                                            Text("\(item.latencyMs)мс • \(item.provider)")
                                                                .font(.system(size: 9))
                                                                .foregroundColor(.secondary.opacity(0.7))
                                                        }
                                                    }

                                                    Text(item.text)
                                                        .font(.system(size: 12))
                                                        .foregroundColor(.primary)
                                                        .lineLimit(3)
                                                        .multilineTextAlignment(.leading)
                                                }
                                                .padding(8)
                                                .frame(maxWidth: .infinity, alignment: .leading)
                                                .background(copiedIndex == index ? Color.brandGreen.opacity(0.12) : Color.primary.opacity(0.03))
                                                .cornerRadius(8)
                                            }
                                            .buttonStyle(.plain)
                                        }
                                    }
                                }
                                .frame(maxHeight: 220)
                            }
                        }
                    }
                    .padding(12)
                    .background(Color.brandCard)
                    .cornerRadius(10)
                    .overlay(
                        RoundedRectangle(cornerRadius: 10)
                            .stroke(Color.brandBorder, lineWidth: 1)
                    )
                }

                // Section 5: macOS System Permissions (Shown ONLY when permissions are missing)
                if !allPermissionsGranted {
                    VStack(alignment: .leading, spacing: 10) {
                        Text("Требуются системные разрешения macOS")
                            .font(.headline)
                            .foregroundColor(.primary)

                        VStack(spacing: 10) {
                            interactivePermissionRow(
                                title: "Микрофон",
                                isGranted: isMicGranted,
                                icon: "mic",
                                onRequest: {
                                    PermissionChecker.shared.requestMicrophone()
                                },
                                onOpenSettings: {
                                    PermissionChecker.shared.openSettings(for: .microphone)
                                }
                            )

                            Divider()

                            interactivePermissionRow(
                                title: "Универсальный доступ",
                                isGranted: isAccessibilityGranted,
                                icon: "accessibility",
                                onRequest: {
                                    PermissionChecker.shared.requestAccessibility()
                                },
                                onOpenSettings: {
                                    PermissionChecker.shared.openSettings(for: .accessibility)
                                }
                            )

                            Divider()

                            interactivePermissionRow(
                                title: "Распознавание речи",
                                isGranted: isSpeechGranted,
                                icon: "waveform",
                                onRequest: {
                                    PermissionChecker.shared.requestSpeechRecognition()
                                },
                                onOpenSettings: {
                                    PermissionChecker.shared.openSettings(for: .speechRecognition)
                                }
                            )
                        }
                        .padding(12)
                        .background(Color.brandCard)
                        .cornerRadius(10)
                        .overlay(
                            RoundedRectangle(cornerRadius: 10)
                                .stroke(Color.brandBorder, lineWidth: 1)
                        )
                    }
                }
            }
            .padding(20)
        }
        .frame(minWidth: 480, minHeight: 560)
        .onAppear {
            googleApiKey = SecretStore.get(SecretStore.Account.googleApiKey) ?? ""
            openrouterKey = SecretStore.get(SecretStore.Account.openrouterKey) ?? ""
            groqApiKey = SecretStore.get(SecretStore.Account.groqApiKey) ?? ""
            modelManager.refreshStatus()
            history.reload()
            checkPermissions()
            if !googleApiKey.isEmpty {
                verifyGoogleKey()
            }
        }
        .onReceive(Timer.publish(every: 0.5, on: .main, in: .common).autoconnect()) { _ in
            checkPermissions()
        }
        .onReceive(NotificationCenter.default.publisher(for: NSApplication.didBecomeActiveNotification)) { _ in
            checkPermissions()
        }
    }

    private func interactivePermissionRow(
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
                .font(.system(size: 13, weight: .medium))

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

    private func copyToClipboard(_ text: String, at index: Int) {
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(text, forType: .string)
        withAnimation {
            copiedIndex = index
        }
        DispatchQueue.main.asyncAfter(deadline: .now() + 1.5) {
            if copiedIndex == index {
                withAnimation {
                    copiedIndex = nil
                }
            }
        }
    }

    private func formatTime(_ date: Date) -> String {
        let formatter = DateFormatter()
        formatter.dateStyle = .short
        formatter.timeStyle = .short
        return formatter.string(from: date)
    }

    private func checkPermissions() {
        isMicGranted = (PermissionChecker.shared.status(of: .microphone) == .granted)
        isAccessibilityGranted = (PermissionChecker.shared.status(of: .accessibility) == .granted)
        isSpeechGranted = (PermissionChecker.shared.status(of: .speechRecognition) == .granted)
    }

    private func verifyGoogleKey() {
        guard !googleApiKey.isEmpty else { return }
        isVerifyingKey = true
        keyStatus = .untested

        Task {
            let urlString = "https://generativelanguage.googleapis.com/v1beta/models?key=\(googleApiKey)"
            guard let url = URL(string: urlString) else {
                await MainActor.run {
                    isVerifyingKey = false
                    keyStatus = .invalid("Неверный URL")
                }
                return
            }

            var request = URLRequest(url: url)
            request.timeoutInterval = 8

            do {
                let (data, response) = try await URLSession.shared.data(for: request)
                let http = response as? HTTPURLResponse
                let code = http?.statusCode ?? 0

                await MainActor.run {
                    self.isVerifyingKey = false
                    if code == 200 {
                        self.keyStatus = .valid
                    } else {
                        if let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
                           let err = json["error"] as? [String: Any],
                           let msg = err["message"] as? String {
                            self.keyStatus = .invalid(msg)
                        } else {
                            self.keyStatus = .invalid("HTTP \(code)")
                        }
                    }
                }
            } catch {
                await MainActor.run {
                    self.isVerifyingKey = false
                    self.keyStatus = .invalid(error.localizedDescription)
                }
            }
        }
    }
}
