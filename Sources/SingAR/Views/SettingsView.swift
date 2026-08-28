import SwiftUI
import AppKit

struct SettingsView: View {
    @ObservedObject private var settings = AppSettings.shared
    @State private var googleApiKey = ""
    @State private var isVerifyingKey = false
    @State private var keyStatus: KeyValidationStatus = .untested

    @State private var isMicGranted = false
    @State private var isAccessibilityGranted = false
    @State private var isSpeechGranted = false

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

                // Section 1: Google Gemini 3.5 Transcribe (BYOK Free Tier)
                VStack(alignment: .leading, spacing: 10) {
                    HStack {
                        Image(systemName: "sparkles")
                            .foregroundColor(Color.brandViolet)
                        Text("Google Gemini 3.5 Transcribe")
                            .font(.headline)
                            .foregroundColor(.primary)
                        Spacer()
                        Text("Бесплатный тариф")
                            .font(.system(size: 10, weight: .semibold))
                            .padding(.horizontal, 6)
                            .padding(.vertical, 2)
                            .background(Color.brandGreen.opacity(0.15))
                            .foregroundColor(Color.brandGreen)
                            .cornerRadius(4)
                    }

                    VStack(spacing: 12) {
                        VStack(alignment: .leading, spacing: 6) {
                            HStack {
                                Text("Google AI Studio API Key:")
                                    .font(.system(size: 12, weight: .medium))
                                Spacer()
                                Link("Получить ключ бесплатно ↗", destination: URL(string: "https://aistudio.google.com/app/apikey")!)
                                    .font(.system(size: 11))
                                    .foregroundColor(Color.brandAccent)
                            }

                            HStack {
                                SecureField("Вставьте AI Studio API Key (AIzaSy...)", text: $googleApiKey)
                                    .textFieldStyle(.roundedBorder)
                                    .onChange(of: googleApiKey) { _, newValue in
                                        SecretStore.set(newValue, for: SecretStore.Account.googleApiKey)
                                        keyStatus = .untested
                                    }

                                Button(action: verifyGoogleKey) {
                                    if isVerifyingKey {
                                        ProgressView()
                                            .controlSize(.small)
                                    } else {
                                        Text("Проверить")
                                    }
                                }
                                .disabled(googleApiKey.isEmpty || isVerifyingKey)
                            }

                            // Key Status Feedback
                            switch keyStatus {
                            case .untested:
                                EmptyView()
                            case .valid:
                                HStack(spacing: 4) {
                                    Image(systemName: "checkmark.circle.fill")
                                        .foregroundColor(Color.brandGreen)
                                    Text("Ключ активен и проверен!")
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

                // Section 4: macOS System Permissions (Shown ONLY when permissions are missing)
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
        .frame(minWidth: 480, minHeight: 520)
        .onAppear {
            googleApiKey = SecretStore.get(SecretStore.Account.googleApiKey) ?? ""
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
