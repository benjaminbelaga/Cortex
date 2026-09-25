import SwiftUI
import Domain

/// Visual identity for a model FAMILY (the weights that ran), as opposed to a
/// provider (the subscription). Used by the usage panel's "by model" split so
/// DeepSeek reached through OpenCode Go, Ollama Cloud or Command Code all show
/// the DeepSeek whale — one identity per family (Ben 2026-09-23).
///
/// Keys are the router's `by_family` names (`deepseek`, `qwen`, `glm`, `kimi`,
/// `minimax`, `mimo`, `claude`, `gpt`, plus `muse`, `gemini`, `other`). Unknown
/// families degrade to a neutral identity, never disappear.
enum ModelFamilyVisual {
    /// Asset-catalog icon; the DeepSeek whale for deepseek.
    static func iconAssetName(for family: String) -> String? {
        switch family.lowercased() {
        case "deepseek": return "DeepSeekIcon"
        case "qwen": return "AlibabaIcon"
        case "glm": return "ZaiIcon"
        case "kimi": return "KimiIcon"
        case "minimax": return "MiniMaxIcon"
        case "claude": return "ClaudeIcon"
        case "gpt": return "CodexIcon"
        case "gemini": return "GeminiIcon"
        case "mistral": return "MistralIcon"
        case "grok": return "GrokIcon"
        default: return nil
        }
    }

    /// SF Symbol fallback when no asset icon exists (e.g. muse, other).
    static func symbolIcon(for family: String) -> String {
        switch family.lowercased() {
        case "deepseek": return "d.square.fill"
        case "qwen": return "cloud.fill"
        case "glm": return "z.square.fill"
        case "kimi": return "k.square.fill"
        case "minimax": return "waveform"
        case "mimo": return "m.square.fill"
        case "claude": return "brain.fill"
        case "gpt": return "chevron.left.forwardslash.chevron.right"
        case "gemini": return "sparkles"
        case "muse": return "music.note"
        default: return "circle.dashed"
        }
    }

    /// Human label for a family key.
    static func displayName(for family: String) -> String {
        switch family.lowercased() {
        case "deepseek": return "DeepSeek"
        case "qwen": return "Qwen"
        case "glm": return "GLM"
        case "kimi": return "Kimi"
        case "minimax": return "MiniMax"
        case "mimo": return "MiMo"
        case "claude": return "Claude"
        case "gpt": return "GPT"
        case "gemini": return "Gemini"
        case "muse": return "Muse"
        case "other": return "Autre"
        default: return family.capitalized
        }
    }

    /// Stable colour per family, reused across the split rows and the pie chart.
    static func color(for family: String) -> Color {
        switch family.lowercased() {
        case "deepseek": return Color(red: 0.30, green: 0.42, blue: 0.98)
        case "qwen": return Color(red: 0.98, green: 0.47, blue: 0.10)
        case "glm": return Color(red: 0.35, green: 0.60, blue: 1.0)
        case "kimi": return Color(red: 0.20, green: 0.62, blue: 0.92)
        case "minimax": return Color(red: 0.91, green: 0.27, blue: 0.42)
        case "mimo": return Color(red: 0.60, green: 0.40, blue: 0.95)
        case "claude": return Color(red: 0.95, green: 0.48, blue: 0.38)
        case "gpt": return Color(red: 0.18, green: 0.72, blue: 0.60)
        case "gemini": return Color(red: 0.92, green: 0.72, blue: 0.28)
        case "muse": return Color(red: 0.85, green: 0.45, blue: 0.75)
        case "other": return Color(white: 0.55)
        default: return Color(white: 0.45)
        }
    }
}
