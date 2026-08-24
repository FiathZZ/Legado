import SwiftUI

struct BookInfoEditView: View {
    @EnvironmentObject private var themeManager: ThemeManager
    @Environment(\.dismiss) private var dismiss

    let book: BookEntity
    let onSave: (String, String, String) -> Void
    let onReset: () -> Void

    @State private var customCoverUrl: String
    @State private var customIntro: String
    @State private var customTag: String

    init(
        book: BookEntity,
        onSave: @escaping (String, String, String) -> Void,
        onReset: @escaping () -> Void
    ) {
        self.book = book
        self.onSave = onSave
        self.onReset = onReset
        _customCoverUrl = State(initialValue: book.customCoverUrl ?? "")
        _customIntro = State(initialValue: book.customIntro ?? "")
        _customTag = State(initialValue: book.customTag ?? "")
    }

    var body: some View {
        NavigationStack {
            Form {
                Section("自定义封面") {
                    TextField("输入封面 URL", text: $customCoverUrl)
                        .textInputAutocapitalization(.never)
                        .autocorrectionDisabled()
                        .keyboardType(.URL)

                    Text("仅支持 URL，自定义封面设置后会优先覆盖书源封面。")
                        .font(.caption)
                        .foregroundStyle(themeManager.color(.secondaryText))
                }

                Section("自定义简介") {
                    TextEditor(text: $customIntro)
                        .frame(minHeight: 160)
                }

                Section("自定义标签") {
                    TextField("如：仙侠 / 已购 / 必读", text: $customTag)
                }
            }
            .navigationTitle("编辑书籍信息")
            .toolbar {
                ToolbarItem(placement: .navigationBarLeading) {
                    Button("重置") {
                        onReset()
                        dismiss()
                    }
                }
                ToolbarItem(placement: .navigationBarTrailing) {
                    Button("保存") {
                        onSave(customCoverUrl, customIntro, customTag)
                        dismiss()
                    }
                }
            }
        }
    }
}
