import SwiftUI

struct ThemedScreenMetric: Identifiable {
    let id = UUID()
    let title: String
    let value: String
    let tint: ThemePaletteToken
}

struct ThemedScreenHeaderCard<Accessory: View>: View {
    @EnvironmentObject private var themeManager: ThemeManager

    let eyebrow: String?
    let title: String
    let summary: String
    let metrics: [ThemedScreenMetric]
    @ViewBuilder let accessory: Accessory

    init(
        eyebrow: String? = nil,
        title: String,
        summary: String,
        metrics: [ThemedScreenMetric] = [],
        @ViewBuilder accessory: () -> Accessory
    ) {
        self.eyebrow = eyebrow
        self.title = title
        self.summary = summary
        self.metrics = metrics
        self.accessory = accessory()
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            if let eyebrow, !eyebrow.isEmpty {
                Text(eyebrow.uppercased())
                    .font(themeManager.font(.monospace, size: 11, weight: .semibold))
                    .foregroundStyle(themeManager.color(.tertiaryText))
            }

            VStack(alignment: .leading, spacing: 6) {
                Text(title)
                    .font(themeManager.font(.title, size: 24, weight: .bold))
                    .foregroundStyle(themeManager.color(.primaryText))

                Text(summary)
                    .font(themeManager.font(.primary, size: 14))
                    .foregroundStyle(themeManager.color(.secondaryText))
                    .lineSpacing(2)
                    .fixedSize(horizontal: false, vertical: true)
            }

            if !metrics.isEmpty {
                LazyVGrid(columns: [GridItem(.adaptive(minimum: 96), spacing: 10)], spacing: 10) {
                    ForEach(metrics) { metric in
                        ThemedMetricCapsule(metric: metric)
                    }
                }
            }

            accessory
        }
        .themedCard()
    }
}

extension ThemedScreenHeaderCard where Accessory == EmptyView {
    init(
        eyebrow: String? = nil,
        title: String,
        summary: String,
        metrics: [ThemedScreenMetric] = []
    ) {
        self.init(eyebrow: eyebrow, title: title, summary: summary, metrics: metrics) {
            EmptyView()
        }
    }
}

private struct ThemedMetricCapsule: View {
    @EnvironmentObject private var themeManager: ThemeManager

    let metric: ThemedScreenMetric

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            Text(metric.value)
                .font(themeManager.font(.title, size: 18, weight: .bold))
                .foregroundStyle(themeManager.color(metric.tint))
            Text(metric.title)
                .font(themeManager.font(.primary, size: 12))
                .foregroundStyle(themeManager.color(.secondaryText))
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(.horizontal, 12)
        .padding(.vertical, 10)
        .background(themeManager.color(.secondarySurfaceBackground), in: RoundedRectangle(cornerRadius: 14, style: .continuous))
    }
}

struct ThemedSectionHeader: View {
    @EnvironmentObject private var themeManager: ThemeManager

    let title: String
    let detail: String?
    let actionTitle: String?
    let action: (() -> Void)?

    init(
        title: String,
        detail: String? = nil,
        actionTitle: String? = nil,
        action: (() -> Void)? = nil
    ) {
        self.title = title
        self.detail = detail
        self.actionTitle = actionTitle
        self.action = action
    }

    var body: some View {
        HStack(alignment: .firstTextBaseline, spacing: 12) {
            VStack(alignment: .leading, spacing: 3) {
                Text(title)
                    .font(themeManager.font(.title, size: 17, weight: .semibold))
                    .foregroundStyle(themeManager.color(.primaryText))

                if let detail, !detail.isEmpty {
                    Text(detail)
                        .font(themeManager.font(.primary, size: 12))
                        .foregroundStyle(themeManager.color(.secondaryText))
                }
            }

            Spacer()

            if let actionTitle, let action {
                Button(actionTitle, action: action)
                    .font(themeManager.font(.primary, size: 13, weight: .medium))
                    .foregroundStyle(themeManager.color(.accent))
            }
        }
    }
}

struct ThemedManagementSummaryRow: View {
    @EnvironmentObject private var themeManager: ThemeManager

    let icon: String
    let title: String
    let detail: String
    let tint: ThemePaletteToken

    var body: some View {
        HStack(spacing: 12) {
            RoundedRectangle(cornerRadius: 12, style: .continuous)
                .fill(themeManager.softColor(tint))
                .frame(width: 40, height: 40)
                .overlay {
                    Image(systemName: icon)
                        .font(.headline)
                        .foregroundStyle(themeManager.color(tint))
                }

            VStack(alignment: .leading, spacing: 4) {
                Text(title)
                    .font(themeManager.font(.title, size: 15, weight: .semibold))
                    .foregroundStyle(themeManager.color(.primaryText))
                Text(detail)
                    .font(themeManager.font(.primary, size: 13))
                    .foregroundStyle(themeManager.color(.secondaryText))
            }

            Spacer()
        }
        .padding(.vertical, 4)
    }
}
