import SwiftUI
import Domain

/// Renders EVERY typed enrolment state — including the hard ones the old `+`
/// flow silently skipped (login in progress with Cancel, quotaPending as a
/// valid state, identityMismatch masked with "keep the read-back identity",
/// cancelled with "nothing was persisted").
struct EnrolmentProgressView: View {
    let state: EnrolmentState
    var onCancel: (() -> Void)?

    @Environment(\.appTheme) private var theme

    private var isCancellable: Bool {
        if case .loginInProgress = state { return true }
        return false
    }

    var body: some View {
        HStack(spacing: 5) {
            Image(systemName: iconName)
                .font(theme.font(size: 9, weight: .semibold))
                .foregroundStyle(iconColor)
            VStack(alignment: .leading, spacing: 1) {
                Text(CatalogStrings.title(for: state))
                    .font(theme.font(size: 10, weight: .semibold))
                    .foregroundStyle(theme.textPrimary)
                if let detail = CatalogStrings.detail(for: state) {
                    Text(detail)
                        .font(theme.font(size: 8, weight: .medium))
                        .foregroundStyle(theme.textTertiary)
                        .lineLimit(2)
                        .truncationMode(.middle)
                }
            }
            Spacer(minLength: 0)
            if isCancellable, let onCancel {
                Button(action: onCancel) {
                    Text("Cancel")
                        .font(theme.font(size: 9, weight: .semibold))
                }
                .buttonStyle(.plain)
                .foregroundStyle(theme.accentPrimary)
            }
        }
        .padding(.horizontal, 7)
        .padding(.vertical, 4)
        .background(RoundedRectangle(cornerRadius: 7).fill(theme.glassBackground))
    }

    private var iconName: String {
        switch state {
        case .profileDetected: return "person.crop.circle.badge.questionmark"
        case .authRequired: return "key.horizontal"
        case .loginInProgress: return "terminal"
        case .identityConfirmed: return "checkmark.seal"
        case .quotaPending: return "hourglass"
        case .quotaReceived: return "checkmark.circle.fill"
        case .failed: return "exclamationmark.triangle.fill"
        case .cancelled: return "xmark.circle"
        }
    }

    private var iconColor: Color {
        switch state {
        case .profileDetected, .authRequired, .loginInProgress: return theme.accentPrimary
        case .identityConfirmed, .quotaPending, .quotaReceived: return theme.statusColor(for: .healthy)
        case .failed: return theme.statusColor(for: .warning)
        case .cancelled: return theme.textTertiary
        }
    }
}
