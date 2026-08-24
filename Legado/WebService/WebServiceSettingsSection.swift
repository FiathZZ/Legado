import SwiftUI
import SwiftData
import UIKit

struct WebServiceSettingsSection: View {
    @Environment(\.modelContext) private var modelContext
    @EnvironmentObject private var themeManager: ThemeManager
    @StateObject private var webServiceManager = WebServiceManager.shared

    @Binding var alertState: SettingsAlertState?
    @State private var portText = ""

    var body: some View {
        Section("Web 服务") {
            VStack(alignment: .leading, spacing: 10) {
                Text("统一处理局域网上传本地书、主题配置、字体文件、书源与替换规则。")
                    .font(themeManager.font(.primary, size: 14))
                    .foregroundStyle(themeManager.color(.secondaryText))

                HStack(spacing: 12) {
                    TextField("端口", text: $portText)
                        .keyboardType(.numberPad)
                        .textInputAutocapitalization(.never)
                        .autocorrectionDisabled()

                    Button(webServiceManager.isRunning ? "停止" : "启动") {
                        toggleService()
                    }
                    .buttonStyle(.borderedProminent)
                    .tint(webServiceManager.isRunning ? themeManager.color(.destructive) : themeManager.color(.accent))
                }

                if let serverURL = webServiceManager.serverURL {
                    HStack(alignment: .top, spacing: 10) {
                        VStack(alignment: .leading, spacing: 4) {
                            Text("访问地址")
                                .font(themeManager.font(.primary, size: 13, weight: .medium))
                                .foregroundStyle(themeManager.color(.primaryText))
                            Text(serverURL.absoluteString)
                                .font(themeManager.font(.monospace, size: 12))
                                .foregroundStyle(themeManager.color(.secondaryText))
                                .textSelection(.enabled)
                        }

                        Spacer()

                        Button("复制") {
                            UIPasteboard.general.string = serverURL.absoluteString
                            alertState = SettingsAlertState(
                                title: "已复制",
                                message: "局域网访问地址已复制到剪贴板。"
                            )
                        }
                        .font(themeManager.font(.primary, size: 13, weight: .medium))
                    }
                }

                Text("支持桌面端上传 TXT / EPUB、本地字体、主题 JSON，并可查看书架、删除书源。")
                    .font(themeManager.font(.primary, size: 12))
                    .foregroundStyle(themeManager.color(.tertiaryText))
            }
            .padding(.vertical, 4)
            .task {
                webServiceManager.configure(modelContext: modelContext, themeManager: themeManager)
                if portText.isEmpty {
                    portText = "\(webServiceManager.port)"
                }
            }
            .onChange(of: webServiceManager.port) { _, newValue in
                portText = "\(newValue)"
            }
            .themedSurfaceListRow()
        }
    }

    private func toggleService() {
        do {
            let port = try resolvedPort()
            if webServiceManager.isRunning {
                webServiceManager.stop()
            } else {
                try webServiceManager.start(port: port)
            }
        } catch {
            alertState = SettingsAlertState(
                title: "Web 服务",
                message: error.localizedDescription
            )
        }
    }

    private func resolvedPort() throws -> Int {
        let trimmed = portText.trimmingCharacters(in: .whitespacesAndNewlines)
        guard let port = Int(trimmed) else {
            throw WebServiceError.invalidPort
        }
        return port
    }
}
