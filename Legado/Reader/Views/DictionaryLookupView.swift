import SwiftUI
import UIKit

enum ReaderDictionaryLookupKey {
    static let selectedText = "selectedText"
}

extension Notification.Name {
    static let LegadoDictionaryLookup = Notification.Name("Legado.reader.dictionaryLookup")
}

struct DictionaryLookupView: UIViewControllerRepresentable {
    let term: String

    func makeUIViewController(context: Context) -> UINavigationController {
        let controller = UIReferenceLibraryViewController(term: term)
        return UINavigationController(rootViewController: controller)
    }

    func updateUIViewController(_ uiViewController: UINavigationController, context: Context) {
        guard let controller = uiViewController.viewControllers.first as? UIReferenceLibraryViewController else {
            return
        }
        controller.title = term
    }
}

struct DictionaryLookupInputView: View {
    @Environment(\.dismiss) private var dismiss
    @State private var term: String

    let onConfirm: (String) -> Void

    init(initialTerm: String = "", onConfirm: @escaping (String) -> Void) {
        _term = State(initialValue: initialTerm)
        self.onConfirm = onConfirm
    }

    var body: some View {
        NavigationStack {
            Form {
                TextField("输入要查询的单词或短语", text: $term)
                    .textInputAutocapitalization(.never)
                    .autocorrectionDisabled()
            }
            .navigationTitle("查词")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("取消") {
                        dismiss()
                    }
                }
                ToolbarItem(placement: .confirmationAction) {
                    Button("查询") {
                        let trimmed = term.trimmingCharacters(in: .whitespacesAndNewlines)
                        guard !trimmed.isEmpty else { return }
                        onConfirm(trimmed)
                        dismiss()
                    }
                    .disabled(term.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
                }
            }
        }
    }
}
