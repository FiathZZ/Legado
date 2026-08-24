import SwiftUI
import SwiftData
import Combine

struct ReplaceRuleManagerView: View {
    @Environment(\.modelContext) private var modelContext
    @EnvironmentObject private var themeManager: ThemeManager

    @State private var rules: [ReplaceRuleEntity] = []
    @State private var showImport = false

    var body: some View {
        NavigationStack {
            Group {
                if rules.isEmpty {
                    ScrollView {
                        VStack(spacing: 20) {
                            ThemedEmptyState(
                                icon: "wand.and.stars",
                                title: "暂无替换规则",
                                message: "可从右上角导入现有规则，也可后续逐步维护。"
                            )
                            .frame(height: 260)
                        }
                        .padding()
                    }
                } else {
                    List {
                        Section("规则列表") {
                            ForEach(rules, id: \.id) { rule in
                                ReplaceRuleRowView(rule: rule) {
                                    toggleEnabled(rule)
                                }
                                .swipeActions(edge: .trailing) {
                                    Button(role: .destructive) {
                                        delete(rule)
                                    } label: {
                                        Label("删除", systemImage: "trash")
                                    }
                                }
                            }
                            .onMove(perform: moveRules)
                        }
                    }
                    .listStyle(.insetGrouped)
                    .scrollContentBackground(.hidden)
                }
            }
            .navigationTitle("替换净化")
            .toolbar(.hidden, for: .tabBar)
            .toolbar {
                ToolbarItem(placement: .navigationBarLeading) {
                    EditButton()
                }
                ToolbarItem(placement: .navigationBarTrailing) {
                    Button {
                        showImport = true
                    } label: {
                        Image(systemName: "plus")
                    }
                }
            }
            .sheet(isPresented: $showImport) {
                ImportReplaceRuleView { importedRules in
                    importRules(importedRules)
                }
            }
            .onReceive(NotificationCenter.default.publisher(for: .replaceRulesDidChange)) { _ in
                loadRules()
            }
        }
        .background(themeManager.color(.appBackground).ignoresSafeArea())
        .onAppear {
            loadRules()
        }
    }

    private func loadRules() {
        let store = ReplaceRuleStore(modelContext: modelContext)
        rules = store.fetchAll()
    }

    private func toggleEnabled(_ entity: ReplaceRuleEntity) {
        let store = ReplaceRuleStore(modelContext: modelContext)
        store.toggleEnabled(entity)
        notifyRulesChanged()
        loadRules()
    }

    private func delete(_ entity: ReplaceRuleEntity) {
        let store = ReplaceRuleStore(modelContext: modelContext)
        store.delete(entity)
        notifyRulesChanged()
        loadRules()
    }

    private func moveRules(from source: IndexSet, to destination: Int) {
        rules.move(fromOffsets: source, toOffset: destination)
        let store = ReplaceRuleStore(modelContext: modelContext)
        store.updateOrder(rules)
        notifyRulesChanged()
        loadRules()
    }

    private func importRules(_ importedRules: [ReplaceRule]) {
        let orderedRules = importedRules.enumerated().map { index, rule in
            ReplaceRule(
                name: rule.name,
                isEnabled: rule.isEnabled,
                isRegex: rule.isRegex,
                pattern: rule.pattern,
                replacement: rule.replacement,
                scope: rule.scope,
                matchScope: rule.matchScope,
                excludeScope: rule.excludeScope,
                order: rule.order == 0 ? index : rule.order,
                sourceID: rule.sourceID
            )
        }

        let store = ReplaceRuleStore(modelContext: modelContext)
        store.upsertAll(orderedRules)
        notifyRulesChanged()
        loadRules()
    }

    private func notifyRulesChanged() {
        ReaderContentRuleCacheVersion.notifyRulesChanged()
    }
}

private struct ReplaceRuleRowView: View {
    @EnvironmentObject private var themeManager: ThemeManager
    let rule: ReplaceRuleEntity
    let onToggle: () -> Void

    var body: some View {
        HStack(spacing: 12) {
            RoundedRectangle(cornerRadius: 10, style: .continuous)
                .fill(themeManager.softColor(rule.isEnabled ? .success : .warning))
                .frame(width: 36, height: 36)
                .overlay {
                    Image(systemName: rule.isEnabled ? "checkmark.shield" : "line.3.horizontal.decrease.circle")
                        .foregroundStyle(themeManager.color(rule.isEnabled ? .success : .warning))
                }

            VStack(alignment: .leading, spacing: 5) {
                Text(rule.name.isEmpty ? rule.pattern : rule.name)
                    .font(themeManager.font(.title, size: 15, weight: .semibold))
                    .foregroundStyle(themeManager.color(.primaryText))
                    .lineLimit(1)

                Text(rule.pattern)
                    .font(themeManager.font(.primary, size: 12))
                    .foregroundStyle(themeManager.color(.secondaryText))
                    .lineLimit(1)
            }

            Spacer()

            Text(scopeLabel)
                .font(.caption2)
                .padding(.horizontal, 6)
                .padding(.vertical, 3)
                .background(themeManager.softColor(.accent), in: Capsule())
                .foregroundStyle(themeManager.color(.accent))

            Toggle("", isOn: Binding(get: { rule.isEnabled }, set: { _ in onToggle() }))
                .labelsHidden()
        }
        .padding(.vertical, 6)
    }

    private var scopeLabel: String {
        switch rule.scope {
        case ReplaceRule.ReplaceScope.content.rawValue:
            return "正文"
        case ReplaceRule.ReplaceScope.title.rawValue:
            return "标题"
        default:
            return "全部"
        }
    }
}
