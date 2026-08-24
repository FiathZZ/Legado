import SwiftUI

struct ImportReplaceRuleView: View {
    @EnvironmentObject private var themeManager: ThemeManager
    let onImport: ([ReplaceRule]) -> Void

    @State private var jsonText: String = ""
    @State private var urlText: String = ""
    @State private var isLoading: Bool = false
    @State private var errorMessage: String? = nil

    @Environment(\.dismiss) private var dismiss

    var body: some View {
        NavigationStack {
            Form {
                Section("粘贴 JSON") {
                    TextEditor(text: $jsonText)
                        .frame(height: 140)
                    Button("从 JSON 导入") {
                        importFromJSON()
                    }
                }

                Section("从 URL 导入") {
                    TextField("https://...", text: $urlText)
                        .textInputAutocapitalization(.never)
                        .autocorrectionDisabled()

                    Button {
                        Task {
                            await importFromURL()
                        }
                    } label: {
                        if isLoading {
                            ProgressView()
                        } else {
                            Text("下载并导入")
                        }
                    }
                    .disabled(isLoading)
                }

                if let errorMessage {
                    Section {
                        Text(errorMessage)
                            .font(.caption)
                            .foregroundStyle(themeManager.color(.destructive))
                    }
                }
            }
            .navigationTitle("导入替换净化")
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("取消") {
                        dismiss()
                    }
                }
            }
        }
    }

    private func importFromJSON() {
        do {
            let rules = try decodeRules(from: jsonText)
            onImport(rules)
            dismiss()
        } catch {
            errorMessage = "JSON 解析失败：\(error.localizedDescription)"
        }
    }

    private func importFromURL() async {
        let trimmed = urlText.trimmingCharacters(in: .whitespacesAndNewlines)
        guard let url = URL(string: trimmed), let scheme = url.scheme?.lowercased(), ["http", "https"].contains(scheme) else {
            errorMessage = "请输入有效的 http/https URL"
            return
        }

        isLoading = true
        defer { isLoading = false }

        do {
            let (data, _) = try await URLSession.shared.data(from: url)
            let text = String(decoding: data, as: UTF8.self)
            let rules = try decodeRules(from: text)
            onImport(rules)
            dismiss()
        } catch {
            errorMessage = "下载或解析失败：\(error.localizedDescription)"
        }
    }

    private func decodeRules(from text: String) throws -> [ReplaceRule] {
        try ReplaceRule.importRules(from: text)
    }
}
