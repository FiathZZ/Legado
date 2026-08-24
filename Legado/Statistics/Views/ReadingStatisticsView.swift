import SwiftData
import SwiftUI

struct ReadingStatisticsView: View {
    @Environment(\.modelContext) private var modelContext
    @EnvironmentObject private var themeManager: ThemeManager
    @State private var summary = ReadingStatisticsSummary(
        todayDuration: 0,
        weekDuration: 0,
        monthDuration: 0,
        topBooks: [],
        recentSevenDays: []
    )

    var body: some View {
        List {
            Section("概览") {
                ReadingStatMetricRow(title: "今日阅读", value: summary.todayDuration.formattedAsReadDuration)
                    .themedSurfaceListRow()
                ReadingStatMetricRow(title: "本周阅读", value: summary.weekDuration.formattedAsReadDuration)
                    .themedSurfaceListRow()
                ReadingStatMetricRow(title: "本月阅读", value: summary.monthDuration.formattedAsReadDuration)
                    .themedSurfaceListRow()
            }

            Section("近 7 天") {
                if summary.recentSevenDays.allSatisfy({ $0.durationSeconds == 0 }) {
                    Text("最近 7 天还没有有效阅读记录")
                        .font(themeManager.font(.primary, size: 14))
                        .foregroundStyle(themeManager.color(.secondaryText))
                        .themedSurfaceListRow()
                } else {
                    ForEach(summary.recentSevenDays) { item in
                        HStack {
                            Text(item.label)
                                .font(themeManager.font(.primary, size: 14, weight: .medium))
                                .foregroundStyle(themeManager.color(.primaryText))
                            Spacer()
                            Text(item.durationSeconds.formattedAsReadDuration)
                                .font(themeManager.font(.primary, size: 14))
                                .foregroundStyle(themeManager.color(.secondaryText))
                        }
                        .themedSurfaceListRow()
                    }
                }
            }

            Section("阅读最多的书") {
                if summary.topBooks.isEmpty {
                    Text("还没有可展示的阅读统计")
                        .font(themeManager.font(.primary, size: 14))
                        .foregroundStyle(themeManager.color(.secondaryText))
                        .themedSurfaceListRow()
                } else {
                    ForEach(summary.topBooks) { item in
                        VStack(alignment: .leading, spacing: 6) {
                            Text(item.bookName)
                                .font(themeManager.font(.title, size: 15, weight: .semibold))
                                .foregroundStyle(themeManager.color(.primaryText))
                                .lineLimit(1)
                            HStack {
                                Text(item.durationSeconds.formattedAsReadDuration)
                                Spacer()
                                Text("切章 \(item.chapterCount) 次")
                            }
                            .font(themeManager.font(.primary, size: 13))
                            .foregroundStyle(themeManager.color(.secondaryText))
                        }
                        .padding(.vertical, 4)
                        .themedSurfaceListRow()
                    }
                }
            }
        }
        .scrollContentBackground(.hidden)
        .background(themeManager.color(.appBackground))
        .navigationTitle("阅读统计")
        .navigationBarTitleDisplayMode(.inline)
        .task {
            reloadSummary()
        }
        .onAppear {
            reloadSummary()
        }
        .themedNavigationChrome()
    }

    private func reloadSummary() {
        summary = ReadingTimeTracker.buildSummary(modelContext: modelContext)
    }
}

private struct ReadingStatMetricRow: View {
    @EnvironmentObject private var themeManager: ThemeManager

    let title: String
    let value: String

    var body: some View {
        HStack {
            Text(title)
                .font(themeManager.font(.title, size: 15, weight: .semibold))
                .foregroundStyle(themeManager.color(.primaryText))
            Spacer()
            Text(value)
                .font(themeManager.font(.primary, size: 14))
                .foregroundStyle(themeManager.color(.secondaryText))
        }
        .padding(.vertical, 4)
    }
}

private extension Int {
    var formattedAsReadDuration: String {
        guard self > 0 else { return "0 分钟" }
        let hours = self / 3600
        let minutes = Swift.max((self % 3600) / 60, hours > 0 ? 0 : 1)
        if hours > 0 {
            return "\(hours) 小时 \(minutes) 分钟"
        }
        return "\(minutes) 分钟"
    }
}
