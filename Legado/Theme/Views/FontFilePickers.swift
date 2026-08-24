import SwiftUI
import UIKit
import UniformTypeIdentifiers

extension UTType {
    static let LegadoFontPack = UTType(exportedAs: "com.Legado.fontpack", conformingTo: .data)
    static let LegadoTrueTypeFont = UTType(filenameExtension: "ttf") ?? .data
    static let LegadoOpenTypeFont = UTType(filenameExtension: "otf") ?? .data
}

struct FontImportDocumentPicker: UIViewControllerRepresentable {
    let onPick: (URL) -> Void
    let onCancel: () -> Void

    func makeCoordinator() -> Coordinator {
        Coordinator(parent: self)
    }

    func makeUIViewController(context: Context) -> UIDocumentPickerViewController {
        let controller = UIDocumentPickerViewController(
            forOpeningContentTypes: [.font, .LegadoTrueTypeFont, .LegadoOpenTypeFont, .LegadoFontPack],
            asCopy: true
        )
        controller.delegate = context.coordinator
        return controller
    }

    func updateUIViewController(_ uiViewController: UIDocumentPickerViewController, context: Context) {
    }

    final class Coordinator: NSObject, UIDocumentPickerDelegate {
        private let parent: FontImportDocumentPicker

        init(parent: FontImportDocumentPicker) {
            self.parent = parent
        }

        func documentPicker(_ controller: UIDocumentPickerViewController, didPickDocumentsAt urls: [URL]) {
            guard let url = urls.first else {
                parent.onCancel()
                return
            }
            parent.onPick(url)
        }

        func documentPickerWasCancelled(_ controller: UIDocumentPickerViewController) {
            parent.onCancel()
        }
    }
}
