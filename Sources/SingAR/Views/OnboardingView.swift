import SwiftUI
import AppKit

enum OnboardingMode: String {
    case cloud
    case local
}

struct OnboardingView: View {
    @ObservedObject private var settings = AppSettings.shared
    @ObservedObject private var modelManager = ModelDownloadManager.shared

    @State private var isAccessibilityGranted = PermissionChecker.shared.status(of: .accessibility) == .granted
    @State private var isMicGranted = PermissionChecker.shared.status(of: .microphone) == .granted
    @State private var isSpeechGranted = PermissionChecker.shared.status(of: .speechRecognition) == .granted

    @State private var selectedMode: OnboardingMode = .cloud
    @State private var cloudApiKey: String = SecretStore.get(SecretStore.Account.googleApiKey) ?? ""

    var allGranted: Bool {
        isAccessibilityGranted && isMicGranted && isSpeechGranted
    }

    var body: some View {
        VStack(spacing: 20) {
            // Header
            VStack(spacing: 6) {
                ZStack {
                    Circle()
                        .fill(Color.brandAccent.opacity(0.15))
                        .frame(width: 50, height: 50)
                    Image(systemName: "waveform.badge.mic")
                        .font(.system(size: 24, weight: .bold))
                        .foregroundColor(Color.brandAccent)
                }

                Text("Добро пожаловать в SingAR")
                    .font(.title3)
                    .fontWeight(.bold)

                Text("Для работы голосового ввода требуются 3 системных разрешения:")
                    .font(.caption)
                    .foregroundColor(.secondary)
                    .multilineTextAlignment(.center)
            }

            // Permissions Card
            VStack(spacing: 12) {
                permissionItem(
                    title: "Микрофон",
                    subtitle: "Для записи голоса и live-транскрипции",
                    icon: "mic.fill",
                    isGranted: isMicGranted,
                    onRequest: {
                        PermissionChecker.shared.requestMicrophone()
                    },
                    onOpenSettings: {
                        PermissionChecker.shared.openSettings(for: .microphone)
                    }
                )

                Divider()

                permissionItem(
                    title: "Универсальный доступ",
                    subtitle: "Для автоматического ввода текста в активное окно",
                    icon: "accessibility",
                    isGranted: isAccessibilityGranted,
                    onRequest: {
                        PermissionChecker.shared.requestAccessibility()
                    },
                    onOpenSettings: {
                        PermissionChecker.shared.openSettings(for: .accessibility)
                    }
                )

                Divider()

                permissionItem(
                    title: "Распознавание речи",
                    subtitle: "Для мгновенной локальной on-device диктовки",
                    icon: "waveform",
                    isGranted: isSpeechGranted,
                    onRequest: {
                        PermissionChecker.shared.requestSpeechRecognition()
                    },
                    onOpenSettings: {
                        PermissionChecker.shared.openSettings(for: .speechRecognition)
                    }
                )
            }
            .padding(14)
            .background(Color.brandCard)
            .cornerRadius(12)
            .overlay(
                RoundedRectangle(cornerRadius: 12)
                    .stroke(Color.brandBorder, lineWidth: 1)
            )

            // Section 2: Engine Mode Selection
            VStack(alignment: .leading, spacing: 10) {
                Text("Движок распознавания речи")
                    .font(.system(size: 13, weight: .bold))

                Picker("", selection: $selectedMode) {
                    Text("☁️ Легкое облако (0 МБ)").tag(OnboardingMode.cloud)
                    Text("🚀 Локально Metal (~1.5 ГБ)").tag(OnboardingMode.local)
                }
                .pickerStyle(.segmented)

                if selectedMode == .cloud {
                    VStack(alignment: .leading, spacing: 6) {
                        HStack {
                            Text("Google AI Studio API Key:")
                                .font(.system(size: 11, weight: .medium))
                            Spacer()
                            Link("Получить бесплатно ↗", destination: URL(string: "https://aistudio.google.com/app/apikey")!)
                                .font(.system(size: 10))
                                .foregroundColor(Color.brandAccent)
                        }

                        SecureField("Вставьте API Key (бесплатно, без карты)", text: $cloudApiKey)
                            .textFieldStyle(.roundedBorder)
                            .controlSize(.small)
                            .onChange(of: cloudApiKey) { _, newVal in
                                SecretStore.set(newVal, for: SecretStore.Account.googleApiKey)
                            }

                        Text("⚡️ 0 МБ на диске. Gemini 3.5 Transcribe + вайб-кодерская постобработка.")
                            .font(.system(size: 9))
                            .foregroundColor(.secondary)
                    }
                    .padding(.top, 2)
                } else {
                    VStack(alignment: .leading, spacing: 6) {
                        HStack {
                            VStack(alignment: .leading, spacing: 2) {
                                Text("Whisper Large v3 Turbo")
                                    .font(.system(size: 11, weight: .semibold))
                                Text("100% офлайн, ускорение Metal на Apple Silicon, 0 ключей.")
                                    .font(.system(size: 9))
                                    .foregroundColor(.secondary)
                            }
                            Spacer()

                            if modelManager.isModelInstalled {
                                HStack(spacing: 4) {
                                    Image(systemName: "checkmark.circle.fill")
                                        .foregroundColor(Color.brandGreen)
                                    Text("Готово")
                                        .font(.system(size: 11, weight: .semibold))
                                        .foregroundColor(Color.brandGreen)
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
                                Text("Скачивание модели: \(Int(progress * 100))%")
                                    .font(.system(size: 9))
                                    .foregroundColor(.secondary)
                            }
                            .padding(.top, 2)
                        }
                    }
                    .padding(.top, 2)
                }
            }
            .padding(14)
            .background(Color.brandCard)
            .cornerRadius(12)
            .overlay(
                RoundedRectangle(cornerRadius: 12)
                    .stroke(Color.brandBorder, lineWidth: 1)
            )

            // Done Button
            Button(action: {
                settings.hasCompletedOnboarding = true
                if selectedMode == .local && modelManager.isModelInstalled {
                    settings.cloudModel = .localWhisperTurbo
                } else {
                    settings.cloudModel = .gemini35Transcribe
                }
                WindowManager.shared.closeOnboarding()
            }) {
                Text(allGranted ? "Начать использование" : "Закрыть")
                    .font(.system(size: 13, weight: .semibold))
                    .frame(maxWidth: .infinity)
                    .padding(.vertical, 6)
            }
            .buttonStyle(.borderedProminent)
            .tint(Color.brandAccent)
        }
        .padding(24)
        .frame(minWidth: 440, maxWidth: .infinity, minHeight: 400, maxHeight: .infinity)
        .onAppear {
            refreshPermissions()
        }
        .onReceive(Timer.publish(every: 0.5, on: .main, in: .common).autoconnect()) { _ in
            refreshPermissions()
        }
        .onReceive(NotificationCenter.default.publisher(for: NSApplication.didBecomeActiveNotification)) { _ in
            refreshPermissions()
        }
    }

    private func permissionItem(
        title: String,
        subtitle: String,
        icon: String,
        isGranted: Bool,
        onRequest: @escaping () -> Void,
        onOpenSettings: @escaping () -> Void
    ) -> some View {
        HStack(spacing: 12) {
            Image(systemName: icon)
                .font(.system(size: 18))
                .foregroundColor(isGranted ? Color.brandGreen : Color.brandAccent)
                .frame(width: 24)

            VStack(alignment: .leading, spacing: 2) {
                Text(title)
                    .font(.system(size: 13, weight: .semibold))
                Text(subtitle)
                    .font(.system(size: 10))
                    .foregroundColor(.secondary)
            }

            Spacer()

            if isGranted {
                Image(systemName: "checkmark.circle.fill")
                    .foregroundColor(Color.brandGreen)
                    .font(.system(size: 18))
            } else {
                HStack(spacing: 4) {
                    Button("Выдать", action: onRequest)
                        .buttonStyle(.borderedProminent)
                        .tint(Color.brandAccent)
                        .controlSize(.small)

                    Button("Настройки ↗", action: onOpenSettings)
                        .buttonStyle(.bordered)
                        .controlSize(.small)
                }
            }
        }
    }

    private func refreshPermissions() {
        isAccessibilityGranted = PermissionChecker.shared.status(of: .accessibility) == .granted
        isMicGranted = PermissionChecker.shared.status(of: .microphone) == .granted
        isSpeechGranted = PermissionChecker.shared.status(of: .speechRecognition) == .granted
    }
}
