import SwiftUI

struct BookSourceBatchTestView: View {
    @EnvironmentObject private var themeManager: ThemeManager
    @StateObject private var tester = BookSourceBatchTester()
    @State private var sources: [BookSource] = []

    var body: some View {
        VStack {
            if tester.isRunning {
                ProgressView(value: tester.progress) {
                    Text("测试进度: \(Int(tester.progress * 100))%")
                }
                .padding()
            }

            List(tester.results, id: \.source.bookSourceUrl) { result in
                HStack {
                    Image(systemName: result.success ? "checkmark.circle.fill" : "xmark.circle.fill")
                        .foregroundStyle(result.success ? themeManager.color(.success) : themeManager.color(.destructive))
                    VStack(alignment: .leading) {
                        Text(result.source.bookSourceName)
                        Text(result.message).font(.caption).foregroundStyle(themeManager.color(.secondaryText))
                    }
                    Spacer()
                    Text(String(format: "%.1fs", result.duration)).font(.caption)
                }
            }

            Text("成功率: \(successRate)%").font(.headline).padding()
        }
        .background(themeManager.color(.appBackground).ignoresSafeArea())
        .navigationTitle("批量测试")
        .task { await loadAndTest() }
    }

    private var successRate: Int {
        guard !tester.results.isEmpty else { return 0 }
        let count = tester.results.filter { $0.success }.count
        return Int(Double(count) / Double(tester.results.count) * 100)
    }

    private func loadAndTest() async {
        guard let url = URL(string: "file:///Users/songming/Downloads/书源.json"),
              let data = try? Data(contentsOf: url),
              let all = try? JSONDecoder().decode([BookSource].self, from: data) else { return }

        sources = all.filter {
            $0.bookSourceName.contains("笔趣阁") || ($0.bookSourceGroup?.contains("精选") ?? false)
        }

        await tester.testSources(sources)
    }
}
