import Foundation
import SwiftData
import SwiftUI

// MARK: - 阅读统计汇总模型
struct ReadingStatisticsSummary {
    struct TopBook: Identifiable {
        let bookUrl: String
        let bookName: String
        let durationSeconds: Int
        let chapterCount: Int

        var id: String { bookUrl }
    }

    struct DailyTrend: Identifiable {
        let date: Date
        let label: String
        let durationSeconds: Int

        var id: String { label }
    }

    let todayDuration: Int
    let weekDuration: Int
    let monthDuration: Int
    let topBooks: [TopBook]
    let recentSevenDays: [DailyTrend]
}

// MARK: - 阅读时长追踪器
@MainActor
final class ReadingTimeTracker {
    private struct SessionContext {
        let bookUrl: String
        let bookName: String
        var startedAt: Date
        var lastActiveAt: Date
        var lastChapterIndex: Int?
        var chapterTransitionCount: Int
    }

    private let minimumTrackedDuration: TimeInterval = 5
    private let calendar = Calendar.current
    private let dayFormatter: DateFormatter = {
        let formatter = DateFormatter()
        formatter.calendar = Calendar.current
        formatter.locale = Locale(identifier: "zh_CN")
        formatter.dateFormat = "yyyy-MM-dd"
        return formatter
    }()

    private var session: SessionContext?
    private weak var modelContext: ModelContext?

    func startTracking(bookUrl: String, bookName: String, chapterIndex: Int, modelContext: ModelContext) {
        self.modelContext = modelContext
        session = SessionContext(
            bookUrl: bookUrl,
            bookName: bookName,
            startedAt: .now,
            lastActiveAt: .now,
            lastChapterIndex: chapterIndex,
            chapterTransitionCount: 0
        )
    }

    func updateVisibleChapter(_ chapterIndex: Int) {
        guard var session else { return }
        if let lastChapterIndex = session.lastChapterIndex, lastChapterIndex != chapterIndex {
            session.chapterTransitionCount += 1
        }
        session.lastChapterIndex = chapterIndex
        session.lastActiveAt = .now
        self.session = session
    }

    func handleScenePhase(_ scenePhase: ScenePhase) {
        switch scenePhase {
        case .active:
            resumeSession()
        case .inactive, .background:
            pauseSession()
        @unknown default:
            pauseSession()
        }
    }

    func finishTracking() {
        pauseSession()
        session = nil
        modelContext = nil
    }

    private func resumeSession() {
        guard var session else { return }
        let now = Date()
        session.startedAt = now
        session.lastActiveAt = now
        self.session = session
    }

    private func pauseSession() {
        guard let modelContext, var session else { return }
        let now = Date()
        let duration = max(now.timeIntervalSince(session.startedAt), 0)
        guard duration >= minimumTrackedDuration || session.chapterTransitionCount > 0 else {
            session.startedAt = now
            session.lastActiveAt = now
            session.chapterTransitionCount = 0
            self.session = session
            return
        }

        persistSession(
            bookUrl: session.bookUrl,
            bookName: session.bookName,
            from: session.startedAt,
            to: now,
            chapterCount: session.chapterTransitionCount,
            modelContext: modelContext
        )

        session.startedAt = now
        session.lastActiveAt = now
        session.chapterTransitionCount = 0
        self.session = session
    }

    private func persistSession(
        bookUrl: String,
        bookName: String,
        from startDate: Date,
        to endDate: Date,
        chapterCount: Int,
        modelContext: ModelContext
    ) {
        guard endDate > startDate else { return }

        var segmentStart = startDate
        while segmentStart < endDate {
            let dayStart = calendar.startOfDay(for: segmentStart)
            let nextDayStart = calendar.date(byAdding: .day, value: 1, to: dayStart) ?? endDate
            let segmentEnd = min(endDate, nextDayStart)
            let durationSeconds = max(Int(segmentEnd.timeIntervalSince(segmentStart).rounded()), 0)
            if durationSeconds > 0 {
                let shouldAssignChapters = segmentStart == startDate ? chapterCount : 0
                saveRecord(
                    bookUrl: bookUrl,
                    bookName: bookName,
                    date: dayStart,
                    durationSeconds: durationSeconds,
                    chapterCount: shouldAssignChapters,
                    modelContext: modelContext
                )
            }
            segmentStart = segmentEnd
        }

        try? modelContext.save()
    }

    private func saveRecord(
        bookUrl: String,
        bookName: String,
        date: Date,
        durationSeconds: Int,
        chapterCount: Int,
        modelContext: ModelContext
    ) {
        let dateKey = dayFormatter.string(from: date)
        let recordID = Self.recordID(bookUrl: bookUrl, dateKey: dateKey)
        let descriptor = FetchDescriptor<ReadRecordEntity>(
            predicate: #Predicate { $0.id == recordID }
        )

        if let existing = try? modelContext.fetch(descriptor).first {
            existing.bookName = bookName
            existing.durationSeconds += durationSeconds
            existing.chapterCount += chapterCount
            existing.updatedAt = .now
        } else {
            let record = ReadRecordEntity(
                id: recordID,
                bookUrl: bookUrl,
                bookName: bookName,
                dateKey: dateKey,
                durationSeconds: durationSeconds,
                chapterCount: chapterCount,
                updatedAt: .now
            )
            modelContext.insert(record)
        }
    }

    static func recordID(bookUrl: String, dateKey: String) -> String {
        "\(bookUrl)|\(dateKey)"
    }

    static func buildSummary(modelContext: ModelContext, now: Date = .now) -> ReadingStatisticsSummary {
        let calendar = Calendar.current
        let formatter = DateFormatter()
        formatter.calendar = calendar
        formatter.locale = Locale(identifier: "zh_CN")
        formatter.dateFormat = "yyyy-MM-dd"

        let records = (try? modelContext.fetch(FetchDescriptor<ReadRecordEntity>())) ?? []
        let todayStart = calendar.startOfDay(for: now)
        let weekStart = calendar.dateInterval(of: .weekOfYear, for: now)?.start ?? todayStart
        let monthStart = calendar.dateInterval(of: .month, for: now)?.start ?? todayStart

        let datedRecords: [(record: ReadRecordEntity, date: Date)] = records.compactMap { record in
            guard let date = formatter.date(from: record.dateKey) else { return nil }
            return (record, date)
        }

        let todayDuration = datedRecords
            .filter { calendar.isDate($0.date, inSameDayAs: now) }
            .reduce(0) { $0 + $1.record.durationSeconds }

        let weekDuration = datedRecords
            .filter { $0.date >= weekStart && $0.date <= now }
            .reduce(0) { $0 + $1.record.durationSeconds }

        let monthDuration = datedRecords
            .filter { $0.date >= monthStart && $0.date <= now }
            .reduce(0) { $0 + $1.record.durationSeconds }

        let topBooks = Dictionary(grouping: datedRecords.filter { $0.date >= monthStart && $0.date <= now }, by: \.record.bookUrl)
            .compactMap { bookUrl, items -> ReadingStatisticsSummary.TopBook? in
                guard let latestName = items.max(by: { $0.record.updatedAt < $1.record.updatedAt })?.record.bookName else {
                    return nil
                }
                return ReadingStatisticsSummary.TopBook(
                    bookUrl: bookUrl,
                    bookName: latestName,
                    durationSeconds: items.reduce(0) { $0 + $1.record.durationSeconds },
                    chapterCount: items.reduce(0) { $0 + $1.record.chapterCount }
                )
            }
            .sorted {
                if $0.durationSeconds == $1.durationSeconds {
                    return $0.bookName.localizedCompare($1.bookName) == .orderedAscending
                }
                return $0.durationSeconds > $1.durationSeconds
            }
            .prefix(5)
            .map { $0 }

        let recentSevenDays: [ReadingStatisticsSummary.DailyTrend] = (0..<7).compactMap { offset in
            guard let date = calendar.date(byAdding: .day, value: -6 + offset, to: todayStart) else { return nil }
            let duration = datedRecords
                .filter { calendar.isDate($0.date, inSameDayAs: date) }
                .reduce(0) { $0 + $1.record.durationSeconds }
            let labelFormatter = DateFormatter()
            labelFormatter.calendar = calendar
            labelFormatter.locale = Locale(identifier: "zh_CN")
            labelFormatter.dateFormat = "M/d"
            return ReadingStatisticsSummary.DailyTrend(
                date: date,
                label: labelFormatter.string(from: date),
                durationSeconds: duration
            )
        }

        return ReadingStatisticsSummary(
            todayDuration: todayDuration,
            weekDuration: weekDuration,
            monthDuration: monthDuration,
            topBooks: topBooks,
            recentSevenDays: recentSevenDays
        )
    }
}
