import SwiftUI

/// Brand palette for SingAR: Dark luxury aesthetic inspired by ReTypeR.
/// Deep carbon graphite tones with glowing electric cyan & violet accents for voice audio.
extension Color {
    /// Gradient background start: carbon obsidian
    static let brandStart = Color(red: 0.07, green: 0.07, blue: 0.09)
    /// Gradient background end: deep graphite
    static let brandEnd = Color(red: 0.14, green: 0.14, blue: 0.18)

    /// Electric Cyan accent (microphones, audio waveforms, listening status)
    static let brandAccent = Color(red: 0.0, green: 0.78, blue: 1.0)
    /// Violet secondary accent (AI processing, Gemini branding)
    static let brandViolet = Color(red: 0.63, green: 0.42, blue: 1.0)
    /// Emerald Green (success / ready / connected)
    static let brandGreen = Color(red: 0.20, green: 0.85, blue: 0.50)
    /// Amber (processing / warning)
    static let brandAmber = Color(red: 1.0, green: 0.68, blue: 0.20)

    /// Subtle card backgrounds
    static let brandCard = Color.primary.opacity(0.04)
    static let brandCardHover = Color.primary.opacity(0.08)
    static let brandBorder = Color.primary.opacity(0.08)
}
