import SwiftUI

// MARK: - 书源行视图
struct BookSourceRowView: View {
    @EnvironmentObject private var themeManager: ThemeManager
    let source: BookSource
    let isEditing: Bool
    let isSelected: Bool
    let onToggleEnabled: () -> Void
    let onToggleSelected: () -> Void

    var body: some View {
        HStack(spacing: 12) {
            if isEditing {
                Image(systemName: isSelected ? "checkmark.circle.fill" : "circle")
                    .foregroundStyle(isSelected ? themeManager.color(.selectionFill) : themeManager.color(.secondaryText))
                    .font(.title3)
                    .onTapGesture { onToggleSelected() }
            }

            HStack(spacing: 8) {
                    VStack(alignment: .leading, spacing: 4) {
                        HStack {
                            Text(source.bookSourceName)
                                .font(.headline)
                                .lineLimit(1)

                            if let group = source.bookSourceGroup, !group.isEmpty {
                                Text(group)
                                    .font(.caption)
                                    .padding(.horizontal, 6)
                                    .padding(.vertical, 2)
                                    .background(themeManager.softColor(.accent))
                                    .foregroundStyle(themeManager.color(.accent))
                                    .clipShape(Capsule())
                            }

                            Spacer()

                            sourceTypeBadge
                        }

                        Text(source.bookSourceUrl)
                            .font(.caption)
                            .foregroundStyle(themeManager.color(.secondaryText))
                            .lineLimit(1)

                        if let comment = source.bookSourceComment, !comment.isEmpty {
                            Text(comment)
                                .font(.caption2)
                                .foregroundStyle(themeManager.color(.secondaryText))
                                .lineLimit(1)
                        }
                    }

                }
            .frame(maxWidth: .infinity, alignment: .leading)

            // 启用开关
            Toggle("", isOn: Binding(
                get: { source.enabled },
                set: { _ in onToggleEnabled() }
            ))
            .labelsHidden()
            .toggleStyle(SwitchToggleStyle(tint: themeManager.color(.success)))
        }
        .padding(.vertical, 4)
        .opacity(source.enabled ? 1.0 : 0.5)
    }

    @ViewBuilder
    private var sourceTypeBadge: some View {
        let (label, color): (String, Color) = {
            switch source.bookSourceType {
            case 1:  return ("音频", themeManager.color(.warning))
            case 2:  return ("图片", themeManager.color(.badgeText))
            default: return ("文本", themeManager.color(.accent))
            }
        }()
        Text(label)
            .font(.caption2)
            .padding(.horizontal, 5)
            .padding(.vertical, 2)
            .background(color.opacity(0.15))
            .foregroundStyle(color)
            .clipShape(Capsule())
    }
}
