import SwiftUI

struct ThemedEmptyState: View {
    @EnvironmentObject private var themeManager: ThemeManager

    let icon: String
    let title: String
    let message: String?
    let actionTitle: String?
    let action: (() -> Void)?

    init(
        icon: String,
        title: String,
        message: String? = nil,
        actionTitle: String? = nil,
        action: (() -> Void)? = nil
    ) {
        self.icon = icon
        self.title = title
        self.message = message
        self.actionTitle = actionTitle
        self.action = action
    }

    var body: some View {
        VStack(spacing: 14) {
            Image(systemName: icon)
                .font(.system(size: 50))
                .foregroundStyle(themeManager.color(.emptyStateIcon))

            Text(title)
                .font(themeManager.font(.title, size: 20, weight: .semibold))
                .foregroundStyle(themeManager.color(.secondaryText))

            if let message, !message.isEmpty {
                Text(message)
                    .font(themeManager.font(.primary, size: 14))
                    .foregroundStyle(themeManager.color(.tertiaryText))
                    .multilineTextAlignment(.center)
                    .padding(.horizontal)
            }

            if let actionTitle, let action {
                Button(actionTitle, action: action)
                    .buttonStyle(ThemedPrimaryButtonStyle())
                    .padding(.top, 4)
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .padding()
    }
}

struct ThemedBadge: View {
    @EnvironmentObject private var themeManager: ThemeManager

    let title: String
    let tint: ThemePaletteToken

    var body: some View {
        Text(title)
            .font(themeManager.font(.primary, size: 12, weight: .medium))
            .padding(.horizontal, 8)
            .padding(.vertical, 4)
            .background(themeManager.softColor(tint), in: Capsule())
            .foregroundStyle(themeManager.color(tint))
    }
}

struct ThemedStatusDot: View {
    @EnvironmentObject private var themeManager: ThemeManager

    let tint: ThemePaletteToken

    var body: some View {
        Circle()
            .fill(themeManager.color(tint))
            .frame(width: 10, height: 10)
    }
}

struct ThemedPrimaryButtonStyle: ButtonStyle {
    @EnvironmentObject private var themeManager: ThemeManager

    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .font(themeManager.font(.primary, size: 15, weight: .semibold))
            .foregroundStyle(themeManager.color(.selectionText))
            .padding(.horizontal, 14)
            .padding(.vertical, 10)
            .background(themeManager.color(.selectionFill).opacity(configuration.isPressed ? 0.88 : 1.0))
            .clipShape(RoundedRectangle(cornerRadius: 12, style: .continuous))
    }
}

struct ThemedSecondaryButtonStyle: ButtonStyle {
    @EnvironmentObject private var themeManager: ThemeManager

    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .font(themeManager.font(.primary, size: 15, weight: .medium))
            .foregroundStyle(themeManager.color(.primaryText))
            .padding(.horizontal, 14)
            .padding(.vertical, 10)
            .background(themeManager.color(.secondarySurfaceBackground).opacity(configuration.isPressed ? 0.88 : 1.0))
            .clipShape(RoundedRectangle(cornerRadius: 12, style: .continuous))
    }
}

struct ThemeCardModifier: ViewModifier {
    @EnvironmentObject private var themeManager: ThemeManager

    func body(content: Content) -> some View {
        content
            .padding()
            .background(themeManager.color(.cardBackground), in: RoundedRectangle(cornerRadius: 18, style: .continuous))
            .overlay(
                RoundedRectangle(cornerRadius: 18, style: .continuous)
                    .stroke(themeManager.color(.divider).opacity(0.6), lineWidth: 1)
            )
    }
}

extension View {
    func themedCard() -> some View {
        modifier(ThemeCardModifier())
    }

    func themedSurfaceListRow() -> some View {
        modifier(ThemedSurfaceListRowModifier())
    }
}

private struct ThemedSurfaceListRowModifier: ViewModifier {
    @EnvironmentObject private var themeManager: ThemeManager

    func body(content: Content) -> some View {
        content
            .listRowBackground(themeManager.color(.surfaceBackground))
            .listRowSeparatorTint(themeManager.color(.divider))
    }
}
