import SwiftData
import SwiftUI

struct RuleSubManagerView: View {
    @Environment(\.modelContext) private var modelContext
    @EnvironmentObject private var themeManager: ThemeManager
    @Query(
        sort: [
            SortDescriptor(\RuleSubEntity.order, order: .forward),
            SortDescriptor(\RuleSubEntity.name, order: .forward)
        ]
    ) private var subscriptions: [RuleSubEntity]

    @State private var isShowingAddSheet = false
    @State private var isUpdatingAll = false
    @State private var updatingIDs: Set<String> = []
    @State private var alertMessage: String?

    var body: some View {
        List {
            Section {
                if subscriptions.isEmpty {
                    ThemedEmptyState(
                        icon: "rectangle.stack.badge.plus",
                        title: "还没有书源订阅",
                        message: "添加订阅后，应用会在启动时按 24 小时周期自动检查更新。"
                    )
                    .frame(minHeight: 220)
                    .listRowInsets(EdgeInsets())
                } else {
                    ForEach(subscriptions, id: \.id) { sub in
                        subscriptionRow(sub)
                            .swipeActions(edge: .trailing) {
                                Button(role: .destructive) {
                                    delete(sub)
                                } label: {
                                    Label("删除", systemImage: "trash")
                                }
                            }
                    }
                }
            } header: {
                Text("订阅列表")
            } footer: {
                Text("自动更新只在应用启动时触发，不会在后台常驻运行。")
            }
        }
        .listStyle(.insetGrouped)
        .scrollContentBackground(.hidden)
        .background(themeManager.color(.appBackground))
        .navigationTitle("书源订阅")
        .toolbar {
            ToolbarItemGroup(placement: .navigationBarTrailing) {
                Button {
                    Task { await updateAll() }
                } label: {
                    if isUpdatingAll {
                        ProgressView()
                    } else {
                        Text("全部更新")
                    }
                }
                .disabled(isUpdatingAll || subscriptions.isEmpty)

                Button {
                    isShowingAddSheet = true
                } label: {
                    Image(systemName: "plus")
                }
            }
        }
        .sheet(isPresented: $isShowingAddSheet) {
            RuleSubAddView { draft in
                await addSubscription(draft: draft)
            }
        }
        .alert(
            "提示",
            isPresented: Binding(
                get: { alertMessage != nil },
                set: { isPresented in
                    if !isPresented {
                        alertMessage = nil
                    }
                }
            )
        ) {
            Button("确定", role: .cancel) {
                alertMessage = nil
            }
        } message: {
            Text(alertMessage ?? "")
        }
    }

    @ViewBuilder
    private func subscriptionRow(_ sub: RuleSubEntity) -> some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack(alignment: .top, spacing: 12) {
                VStack(alignment: .leading, spacing: 6) {
                    Text(sub.name)
                        .font(themeManager.font(.primary, size: 16, weight: .semibold))
                        .foregroundStyle(themeManager.color(.primaryText))

                    Text(sub.url)
                        .font(themeManager.font(.primary, size: 13))
                        .foregroundStyle(themeManager.color(.secondaryText))
                        .textSelection(.enabled)
                        .lineLimit(2)

                    Text(lastUpdateText(for: sub))
                        .font(themeManager.font(.primary, size: 12))
                        .foregroundStyle(themeManager.color(.tertiaryText))
                }

                Spacer(minLength: 12)

                if updatingIDs.contains(sub.id) {
                    ProgressView()
                        .controlSize(.small)
                }
            }

            HStack {
                Toggle(
                    "自动更新",
                    isOn: Binding(
                        get: { sub.autoUpdate },
                        set: { newValue in
                            sub.autoUpdate = newValue
                            try? modelContext.save()
                        }
                    )
                )
                .tint(themeManager.color(.accent))

                Spacer()

                Button("立即更新") {
                    Task { await updateSingle(sub) }
                }
                .buttonStyle(.bordered)
                .disabled(updatingIDs.contains(sub.id) || isUpdatingAll)
            }
            .font(themeManager.font(.primary, size: 13))
        }
        .padding(.vertical, 6)
        .listRowBackground(themeManager.color(.surfaceBackground))
        .listRowSeparatorTint(themeManager.color(.divider))
    }

    private func lastUpdateText(for sub: RuleSubEntity) -> String {
        guard let lastUpdateTime = sub.lastUpdateTime else {
            return "最近更新：从未更新"
        }
        return "最近更新：\(lastUpdateTime.formatted(date: .abbreviated, time: .shortened))"
    }

    private func addSubscription(draft: RuleSubDraft) async -> String? {
        do {
            let normalizedURL = try RuleSubService.normalizedSubscriptionURL(from: draft.url)
            let trimmedName = draft.name.trimmingCharacters(in: .whitespacesAndNewlines)
            let nextOrder = (subscriptions.map(\.order).max() ?? -1) + 1
            let entity = RuleSubEntity(
                name: trimmedName.isEmpty ? RuleSubService.suggestedName(for: normalizedURL) : trimmedName,
                url: normalizedURL,
                autoUpdate: draft.autoUpdate,
                order: nextOrder
            )
            modelContext.insert(entity)
            try modelContext.save()

            updatingIDs.insert(entity.id)
            defer { updatingIDs.remove(entity.id) }

            let summary = try await RuleSubService.updateSubscription(entity, in: modelContext)
            alertMessage = subscriptionMessage(for: summary, prefix: "订阅已添加")
            isShowingAddSheet = false
            return nil
        } catch {
            let message = error.localizedDescription
            alertMessage = message
            return message
        }
    }

    private func updateSingle(_ sub: RuleSubEntity) async {
        updatingIDs.insert(sub.id)
        defer { updatingIDs.remove(sub.id) }

        do {
            let summary = try await RuleSubService.updateSubscription(sub, in: modelContext)
            alertMessage = subscriptionMessage(for: summary, prefix: "已更新订阅")
        } catch {
            alertMessage = error.localizedDescription
        }
    }

    private func updateAll() async {
        isUpdatingAll = true
        defer { isUpdatingAll = false }

        let summary = await RuleSubService.updateAllSubscriptions(
            subs: subscriptions,
            in: modelContext,
            onlyAutoUpdate: false
        )

        if summary.updatedSubscriptionCount == 0 && summary.failedSubscriptionNames.isEmpty {
            alertMessage = "没有可更新的订阅。"
            return
        }

        var message = "已更新 \(summary.updatedSubscriptionCount) 个订阅，导入 \(summary.importedCount) 项内容"
        if summary.addedCount > 0 {
            message += "，新增 \(summary.addedCount) 个"
        }
        if !summary.failedSubscriptionNames.isEmpty {
            message += "。\n失败：\(summary.failedSubscriptionNames.joined(separator: "、"))"
        } else {
            message += "。"
        }
        alertMessage = message
    }

    private func subscriptionMessage(for summary: RuleSubUpdateSummary, prefix: String) -> String {
        var parts = ["\(prefix)，导入 \(summary.importedCount) 个\(summary.contentKind.displayName)"]
        if summary.addedCount > 0 {
            parts.append("新增 \(summary.addedCount) 个")
        }
        if summary.linkedBookSourceImportedCount > 0 {
            var linkedPart = "自动导入 \(summary.linkedBookSourceImportedCount) 个书源"
            if summary.linkedBookSourceAddedCount > 0 {
                linkedPart += "，其中新增 \(summary.linkedBookSourceAddedCount) 个"
            }
            parts.append(linkedPart)
        }
        return parts.joined(separator: "，") + "。"
    }

    private func delete(_ sub: RuleSubEntity) {
        modelContext.delete(sub)
        try? modelContext.save()
    }
}

private struct RuleSubDraft {
    var name: String = ""
    var url: String = ""
    var autoUpdate: Bool = true
}

private struct RuleSubAddView: View {
    @Environment(\.dismiss) private var dismiss
    @EnvironmentObject private var themeManager: ThemeManager

    @State private var draft = RuleSubDraft()
    @State private var isSaving = false
    @State private var localError: String?

    let onConfirm: (RuleSubDraft) async -> String?

    var body: some View {
        NavigationStack {
            Form {
                Section("订阅信息") {
                    TextField("订阅名称（可选）", text: $draft.name)
                    TextField("https:// 或 yuedu:// 地址", text: $draft.url, axis: .vertical)
                        .textInputAutocapitalization(.never)
                        .autocorrectionDisabled()
                    Toggle("启动时自动更新", isOn: $draft.autoUpdate)
                        .tint(themeManager.color(.accent))
                }

                if let localError {
                    Section("错误") {
                        Text(localError)
                            .foregroundStyle(themeManager.color(.destructive))
                    }
                }
            }
            .scrollContentBackground(.hidden)
            .background(themeManager.color(.appBackground))
            .navigationTitle("添加订阅")
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("取消") {
                        dismiss()
                    }
                }
                ToolbarItem(placement: .confirmationAction) {
                    Button {
                        Task {
                            isSaving = true
                            localError = await onConfirm(draft)
                            isSaving = false
                            if localError == nil {
                                dismiss()
                            }
                        }
                    } label: {
                        if isSaving {
                            ProgressView()
                        } else {
                            Text("保存")
                        }
                    }
                    .disabled(isSaving || draft.url.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
                }
            }
        }
    }
}
