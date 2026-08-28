import SwiftUI
import AppKit

struct OnboardingView: View {
    @State private var isAccessibilityGranted = PermissionChecker.shared.status(of: .accessibility) == .granted
    @State private var isMicGranted = PermissionChecker.shared.status(of: .microphone) == .granted
    @State private var isSpeechGranted = PermissionChecker.shared.status(of: .speechRecognition) == .granted

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

            // Done Button
            Button(action: {
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
        .frame(width: 440)
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
