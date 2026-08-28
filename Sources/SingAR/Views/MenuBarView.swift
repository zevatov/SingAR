import SwiftUI
import AppKit

struct MenuBarView: View {
    @ObservedObject private var settings = AppSettings.shared
    @ObservedObject private var history = DictationHistory.shared
    @State private var isHistoryExpanded = false
    @State private var copiedIndex: Int?
    @State private var allPermissionsGranted = PermissionChecker.shared.allGranted

    // Status Dot Color & Text
    private var statusDotColor: Color {
        if !settings.enabled {
            return Color.red // Paused / Disabled
        } else if !allPermissionsGranted {
            return Color.brandAmber // Missing permissions
        } else {
            return Color.brandGreen // Active & Ready
        }
    }

    private var statusSubtitle: String {
        if !settings.enabled {
            return "На паузе"
        } else if !allPermissionsGranted {
            return "Требуются разрешения"
        } else {
            return "Готов к диктовке"
        }
    }

    var body: some View {
        VStack(spacing: 12) {
            // Header: Status glyph + App name + Play/Pause & Power buttons
            HStack(spacing: 10) {
                // Microphone icon with status dot
                ZStack(alignment: .bottomTrailing) {
                    ZStack {
                        Circle()
                            .fill(settings.enabled ? Color.brandAccent.opacity(0.15) : Color.secondary.opacity(0.1))
                            .frame(width: 32, height: 32)
                        Image(systemName: settings.enabled ? "waveform.badge.mic" : "mic.slash")
                            .font(.system(size: 15, weight: .semibold))
                            .foregroundColor(settings.enabled ? Color.brandAccent : Color.secondary)
                    }

                    // Always-visible status dot
                    Circle()
                        .fill(statusDotColor)
                        .frame(width: 9, height: 9)
                        .overlay(
                            Circle()
                                .stroke(Color(red: 0.12, green: 0.12, blue: 0.15), lineWidth: 1.5)
                        )
                        .offset(x: 1, y: 1)
                }

                VStack(alignment: .leading, spacing: 2) {
                    Text("SingAR")
                        .font(.system(size: 14, weight: .bold))
                    Text(statusSubtitle)
                        .font(.system(size: 10))
                        .foregroundColor(.secondary)
                }

                Spacer()

                // Top-Right Control Buttons (Play/Pause + Power)
                HStack(spacing: 6) {
                    // Play / Pause Button
                    Button {
                        withAnimation(.easeInOut(duration: 0.2)) {
                            settings.enabled.toggle()
                        }
                    } label: {
                        Image(systemName: settings.enabled ? "pause.fill" : "play.fill")
                            .font(.system(size: 11, weight: .bold))
                            .foregroundColor(settings.enabled ? Color.secondary : Color.brandGreen)
                            .frame(width: 26, height: 26)
                            .background(settings.enabled ? Color.brandCard : Color.brandGreen.opacity(0.15))
                            .clipShape(Circle())
                    }
                    .buttonStyle(.plain)
                    .help(settings.enabled ? "Поставить на паузу (не реагировать на хоткей)" : "Возобновить работу")

                    // Power / Quit Button
                    Button {
                        NSApp.terminate(nil)
                    } label: {
                        Image(systemName: "power")
                            .font(.system(size: 11, weight: .semibold))
                            .foregroundColor(Color.secondary)
                            .frame(width: 26, height: 26)
                            .background(Color.brandCard)
                            .clipShape(Circle())
                    }
                    .buttonStyle(.plain)
                    .help("Выйти из SingAR")
                }
            }

            Divider()

            // Interactive Hotkey & Mode Configuration
            VStack(spacing: 8) {
                // Hotkey Switcher
                HStack {
                    Label("Хоткей", systemImage: "keyboard")
                        .font(.system(size: 12))
                        .foregroundColor(.secondary)
                    Spacer()
                    Menu {
                        Button("Правый ⌥ Option (рекоменд.)") { settings.hotkey = .rightOption }
                        Button("Fn / Globe") { settings.hotkey = .fnOrGlobe }
                    } label: {
                        HStack(spacing: 4) {
                            Text(settings.hotkey == .rightOption ? "Правый ⌥ Option" : "Fn / Globe")
                                .font(.system(size: 11, weight: .medium))
                            Image(systemName: "chevron.up.chevron.down")
                                .font(.system(size: 8))
                                .foregroundColor(.secondary)
                        }
                        .padding(.horizontal, 6)
                        .padding(.vertical, 3)
                        .background(Color.primary.opacity(0.06))
                        .cornerRadius(5)
                    }
                    .menuStyle(.borderlessButton)
                }

                // Mode Switcher
                HStack {
                    Label("Режим", systemImage: "hand.tap")
                        .font(.system(size: 12))
                        .foregroundColor(.secondary)
                    Spacer()
                    Menu {
                        Button("Hold (удержание)") { settings.mode = .hold }
                        Button("Toggle (нажал-сказал)") { settings.mode = .toggle }
                    } label: {
                        HStack(spacing: 4) {
                            Text(settings.mode == .toggle ? "Toggle (нажал-сказал)" : "Hold (удержание)")
                                .font(.system(size: 11, weight: .medium))
                            Image(systemName: "chevron.up.chevron.down")
                                .font(.system(size: 8))
                                .foregroundColor(.secondary)
                        }
                        .padding(.horizontal, 6)
                        .padding(.vertical, 3)
                        .background(Color.primary.opacity(0.06))
                        .cornerRadius(5)
                    }
                    .menuStyle(.borderlessButton)
                }
            }
            .padding(10)
            .background(Color.brandCard)
            .cornerRadius(8)

            // Collapsible History View
            if isHistoryExpanded {
                VStack(alignment: .leading, spacing: 6) {
                    HStack {
                        Text("Недавние записи")
                            .font(.system(size: 11, weight: .semibold))
                            .foregroundColor(.secondary)
                        Spacer()
                        Text("Нажмите для копирования")
                            .font(.system(size: 9))
                            .foregroundColor(.secondary.opacity(0.7))
                    }

                    let entries = Array(history.items.reversed().prefix(8))
                    if entries.isEmpty {
                        Text("История пуста")
                            .font(.system(size: 11))
                            .foregroundColor(.secondary)
                            .frame(maxWidth: .infinity, alignment: .center)
                            .padding(.vertical, 12)
                    } else {
                        ScrollView {
                            VStack(spacing: 5) {
                                ForEach(Array(entries.enumerated()), id: \.offset) { index, item in
                                    Button {
                                        copyToClipboard(item.text, at: index)
                                    } label: {
                                        VStack(alignment: .leading, spacing: 2) {
                                            HStack {
                                                Text(formatTime(item.timestamp))
                                                    .font(.system(size: 9))
                                                    .foregroundColor(.secondary)
                                                Spacer()
                                                if copiedIndex == index {
                                                    Text("Скопировано!")
                                                        .font(.system(size: 9, weight: .bold))
                                                        .foregroundColor(Color.brandGreen)
                                                } else {
                                                    Text("\(item.latencyMs)мс")
                                                        .font(.system(size: 9))
                                                        .foregroundColor(.secondary.opacity(0.6))
                                                }
                                            }

                                            Text(item.text)
                                                .font(.system(size: 11))
                                                .foregroundColor(.primary)
                                                .lineLimit(2)
                                                .multilineTextAlignment(.leading)
                                        }
                                        .padding(6)
                                        .frame(maxWidth: .infinity, alignment: .leading)
                                        .background(copiedIndex == index ? Color.brandGreen.opacity(0.12) : Color.brandCard)
                                        .cornerRadius(6)
                                    }
                                    .buttonStyle(.plain)
                                }
                            }
                        }
                        .frame(maxHeight: 140)
                    }
                }
                .transition(.opacity.combined(with: .move(edge: .top)))
            }

            Divider()

            // Footer action buttons (2 buttons 50/50 width)
            HStack(spacing: 8) {
                Button {
                    withAnimation(.spring(response: 0.3, dampingFraction: 0.8)) {
                        isHistoryExpanded.toggle()
                    }
                } label: {
                    Label(isHistoryExpanded ? "Скрыть" : "История", systemImage: "clock.arrow.circlepath")
                        .font(.system(size: 11, weight: .medium))
                        .frame(maxWidth: .infinity)
                }
                .buttonStyle(.plain)
                .padding(6)
                .background(Color.primary.opacity(isHistoryExpanded ? 0.08 : 0.04))
                .cornerRadius(6)

                Button {
                    WindowManager.shared.showSettings()
                } label: {
                    Label("Настройки", systemImage: "gearshape")
                        .font(.system(size: 11, weight: .medium))
                        .frame(maxWidth: .infinity)
                }
                .buttonStyle(.plain)
                .padding(6)
                .background(Color.primary.opacity(0.04))
                .cornerRadius(6)
            }
        }
        .padding(14)
        .frame(width: 290)
        .onAppear {
            allPermissionsGranted = PermissionChecker.shared.allGranted
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
        formatter.timeStyle = .short
        return formatter.string(from: date)
    }
}
