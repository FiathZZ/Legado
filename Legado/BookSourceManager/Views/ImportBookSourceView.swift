import AVFoundation
import SwiftUI
import UIKit

// MARK: - 导入书源视图
struct ImportBookSourceView: View {
    @Environment(\.dismiss) private var dismiss
    @EnvironmentObject private var themeManager: ThemeManager
    @ObservedObject var viewModel: BookSourceManagerViewModel

    @State private var inputText: String = ""
    @State private var isShowingScanner = false
    @FocusState private var isInputFocused: Bool

    var body: some View {
        NavigationStack {
            Form {
                Section {
                    TextEditor(text: $inputText)
                        .frame(minHeight: 100)
                        .focused($isInputFocused)
                        .autocorrectionDisabled()
                        .textInputAutocapitalization(.never)
                        .overlay(
                            Group {
                                if inputText.isEmpty {
                                        Text("粘贴书源链接、订阅地址或 JSON 内容…")
                                        .foregroundStyle(themeManager.color(.secondaryText))
                                        .padding(.top, 8)
                                        .padding(.leading, 4)
                                        .allowsHitTesting(false)
                                }
                            },
                            alignment: .topLeading
                        )

                    Button {
                        isInputFocused = false
                        isShowingScanner = true
                    } label: {
                        Label("扫码导入", systemImage: "qrcode.viewfinder")
                    }
                } header: {
                    Text("书源地址")
                }

                Section {
                    Button {
                        Task { await importSources() }
                    } label: {
                        HStack {
                            Spacer()
                            if viewModel.isLoading {
                                ProgressView()
                                    .progressViewStyle(.circular)
                                    .padding(.trailing, 8)
                            }
                            Text(viewModel.isLoading ? "正在导入…" : "开始导入")
                                .bold()
                            Spacer()
                        }
                    }
                    .disabled(inputText.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty || viewModel.isLoading)
                }
            }
            .scrollContentBackground(.hidden)
            .background(themeManager.color(.appBackground))
            .navigationTitle("导入书源")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("取消") { dismiss() }
                }
            }
            .alert("提示", isPresented: $viewModel.showAlert) {
                Button("确定") {
                    if !viewModel.isLoading { dismiss() }
                }
            } message: {
                Text(viewModel.alertMessage)
            }
            .sheet(isPresented: $isShowingScanner) {
                NavigationStack {
                    QRCodeScannerView(
                        onCodeScanned: { value in
                            isShowingScanner = false
                            inputText = value
                            Task { await importSources() }
                        },
                        onFailure: { message in
                            isShowingScanner = false
                            viewModel.alertMessage = message
                            viewModel.showAlert = true
                        }
                    )
                    .ignoresSafeArea()
                    .navigationTitle("扫码导入")
                    .navigationBarTitleDisplayMode(.inline)
                    .toolbar {
                        ToolbarItem(placement: .cancellationAction) {
                            Button {
                                isShowingScanner = false
                            } label: {
                                Image(systemName: "xmark")
                            }
                            .accessibilityLabel("关闭")
                        }
                    }
                }
            }
            .onAppear { isInputFocused = true }
        }
    }

    private func importSources() async {
        isInputFocused = false
        await viewModel.importFromURL(inputText)
    }
}

private struct QRCodeScannerView: UIViewControllerRepresentable {
    let onCodeScanned: (String) -> Void
    let onFailure: (String) -> Void

    func makeUIViewController(context: Context) -> QRCodeScannerController {
        let controller = QRCodeScannerController()
        controller.onCodeScanned = onCodeScanned
        controller.onFailure = onFailure
        return controller
    }

    func updateUIViewController(_ uiViewController: QRCodeScannerController, context: Context) {}
}

private final class QRCodeScannerController: UIViewController, AVCaptureMetadataOutputObjectsDelegate {
    var onCodeScanned: (String) -> Void = { _ in }
    var onFailure: (String) -> Void = { _ in }

    private let captureSession = AVCaptureSession()
    private var previewLayer: AVCaptureVideoPreviewLayer?
    private var hasReportedResult = false

    override func viewDidLoad() {
        super.viewDidLoad()
        view.backgroundColor = .black
        requestCameraAccess()
    }

    override func viewDidLayoutSubviews() {
        super.viewDidLayoutSubviews()
        previewLayer?.frame = view.bounds
    }

    deinit {
        captureSession.stopRunning()
    }

    private func requestCameraAccess() {
        switch AVCaptureDevice.authorizationStatus(for: .video) {
        case .authorized:
            configureScanner()
        case .notDetermined:
            AVCaptureDevice.requestAccess(for: .video) { [weak self] granted in
                DispatchQueue.main.async {
                    guard let self else { return }
                    granted ? self.configureScanner() : self.reportFailure("未获得相机权限，请在系统设置中允许访问相机")
                }
            }
        case .denied, .restricted:
            reportFailure("未获得相机权限，请在系统设置中允许访问相机")
        @unknown default:
            reportFailure("当前设备无法使用相机扫码")
        }
    }

    private func configureScanner() {
        guard captureSession.inputs.isEmpty else { return }
        guard let camera = AVCaptureDevice.default(for: .video) else {
            reportFailure("当前设备没有可用相机")
            return
        }

        do {
            let input = try AVCaptureDeviceInput(device: camera)
            guard captureSession.canAddInput(input) else {
                reportFailure("无法配置相机输入")
                return
            }
            captureSession.addInput(input)

            let output = AVCaptureMetadataOutput()
            guard captureSession.canAddOutput(output) else {
                reportFailure("无法配置二维码识别")
                return
            }
            captureSession.addOutput(output)
            output.setMetadataObjectsDelegate(self, queue: .main)
            output.metadataObjectTypes = [.qr]

            let preview = AVCaptureVideoPreviewLayer(session: captureSession)
            preview.videoGravity = .resizeAspectFill
            preview.frame = view.bounds
            view.layer.insertSublayer(preview, at: 0)
            previewLayer = preview
            captureSession.startRunning()
        } catch {
            reportFailure("无法打开相机：\(error.localizedDescription)")
        }
    }

    func metadataOutput(
        _ output: AVCaptureMetadataOutput,
        didOutput metadataObjects: [AVMetadataObject],
        from connection: AVCaptureConnection
    ) {
        guard !hasReportedResult,
              let code = metadataObjects.first as? AVMetadataMachineReadableCodeObject,
              let value = code.stringValue,
              !value.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
            return
        }

        hasReportedResult = true
        captureSession.stopRunning()
        onCodeScanned(value)
    }

    private func reportFailure(_ message: String) {
        guard !hasReportedResult else { return }
        hasReportedResult = true
        captureSession.stopRunning()
        onFailure(message)
    }
}
