import SwiftUI
import UIKit

/// 关于页面。
///
/// 结构参考 Android 版 Legado 的 `ui/about`（`res/xml/about.xml` + `AboutFragment.kt`）：
/// 顶部一张应用信息卡片，下方是可点击的条目。
///
/// 按 iOS 端需要做了取舍，Android 上这几项不在此提供：
/// 崩溃日志、保存日志、创建堆转储、检查更新、更新日志。
struct AboutView: View {
    @EnvironmentObject private var themeManager: ThemeManager
    @Environment(\.openURL) private var openURL

    /// 开发人员名称
    private static let developerName = "ZZ"

    /// 开发人员主页，点击跳转
    private static let developerURL = URL(string: "https://github.com/FiathZZ/Legado")!

    var body: some View {
        List {
            Section {
                header
                    .themedSurfaceListRow()
            }

            Section("应用信息") {
                AboutInfoRow(title: "版本", detail: Self.appVersionText)
                    .themedSurfaceListRow()

                Button {
                    openURL(Self.developerURL)
                } label: {
                    AboutInfoRow(
                        title: "开发人员",
                        detail: Self.developerName,
                        detailTint: .accent,
                        trailingSystemImage: "arrow.up.forward.square"
                    )
                }
                .buttonStyle(.plain)
                .themedSurfaceListRow()
            }

            Section("条款与许可") {
                NavigationLink(destination: AboutTextPage(title: "隐私政策", content: AboutContent.privacyPolicy).toolbar(.hidden, for: .tabBar)) {
                    AboutInfoRow(title: "隐私政策", detail: "数据的存储与使用方式")
                }
                .themedSurfaceListRow()

                NavigationLink(destination: AboutTextPage(title: "开源许可", content: AboutContent.license).toolbar(.hidden, for: .tabBar)) {
                    AboutInfoRow(title: "开源许可", detail: "本项目与所依赖的开源项目")
                }
                .themedSurfaceListRow()

                NavigationLink(destination: AboutTextPage(title: "免责声明", content: AboutContent.disclaimer).toolbar(.hidden, for: .tabBar)) {
                    AboutInfoRow(title: "免责声明", detail: "使用本应用前请阅读")
                }
                .themedSurfaceListRow()
            }
        }
        .scrollContentBackground(.hidden)
        .background(themeManager.color(.appBackground))
        .navigationTitle("关于")
        .navigationBarTitleDisplayMode(.inline)
    }

    /// 顶部应用信息卡片
    private var header: some View {
        VStack(spacing: 12) {
            appIcon

            Text(Self.appName)
                .font(themeManager.font(.title, size: 22, weight: .bold))
                .foregroundStyle(themeManager.color(.primaryText))

            Text(AboutContent.summary)
                .font(themeManager.font(.primary, size: 13))
                .foregroundStyle(themeManager.color(.secondaryText))
                .multilineTextAlignment(.center)
                .lineSpacing(3)
                .fixedSize(horizontal: false, vertical: true)
        }
        .frame(maxWidth: .infinity)
        .padding(.vertical, 14)
    }

    /// 应用图标。`AppIcon` 取不到时回落到一个同色系的占位图形，避免出现空白。
    @ViewBuilder
    private var appIcon: some View {
        if let icon = UIImage(named: "AppIcon") {
            Image(uiImage: icon)
                .resizable()
                .interpolation(.high)
                .frame(width: 84, height: 84)
                .clipShape(RoundedRectangle(cornerRadius: 20, style: .continuous))
                .overlay {
                    RoundedRectangle(cornerRadius: 20, style: .continuous)
                        .stroke(themeManager.color(.divider).opacity(0.6), lineWidth: 1)
                }
        } else {
            RoundedRectangle(cornerRadius: 20, style: .continuous)
                .fill(themeManager.softColor(.accent))
                .frame(width: 84, height: 84)
                .overlay {
                    Image(systemName: "book.closed.fill")
                        .font(.system(size: 34))
                        .foregroundStyle(themeManager.color(.accent))
                }
        }
    }

    private static var appName: String {
        (Bundle.main.infoDictionary?["CFBundleDisplayName"] as? String)
            ?? (Bundle.main.infoDictionary?["CFBundleName"] as? String)
            ?? "Legado"
    }

    /// 形如 `1.0.0 (1)`
    private static var appVersionText: String {
        let version = Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String ?? "—"
        let build = Bundle.main.infoDictionary?["CFBundleVersion"] as? String ?? "—"
        return "\(version) (\(build))"
    }
}

// MARK: - 行

/// 关于页的信息行：左侧标题，右侧可选说明文字。
private struct AboutInfoRow: View {
    @EnvironmentObject private var themeManager: ThemeManager

    let title: String
    var detail: String?
    var detailTint: ThemePaletteToken = .secondaryText
    var trailingSystemImage: String?

    var body: some View {
        HStack(spacing: 12) {
            Text(title)
                .font(themeManager.font(.title, size: 15, weight: .medium))
                .foregroundStyle(themeManager.color(.primaryText))

            Spacer(minLength: 12)

            if let detail {
                Text(detail)
                    .font(themeManager.font(.primary, size: 13))
                    .foregroundStyle(themeManager.color(detailTint))
                    .multilineTextAlignment(.trailing)
            }

            if let trailingSystemImage {
                Image(systemName: trailingSystemImage)
                    .font(.system(size: 13, weight: .semibold))
                    .foregroundStyle(themeManager.color(detailTint))
            }
        }
        .padding(.vertical, 4)
    }
}

// MARK: - 条款文本页

/// 隐私政策 / 开源许可 / 免责声明的通用文本页。
private struct AboutTextPage: View {
    @EnvironmentObject private var themeManager: ThemeManager

    let title: String
    let content: String

    var body: some View {
        ScrollView {
            Text(content)
                .font(themeManager.font(.primary, size: 14))
                .foregroundStyle(themeManager.color(.primaryText))
                .lineSpacing(6)
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding(.horizontal, 18)
                .padding(.vertical, 16)
                .textSelection(.enabled)
        }
        .background(themeManager.color(.appBackground))
        .navigationTitle(title)
        .navigationBarTitleDisplayMode(.inline)
    }
}

// MARK: - 文案

private enum AboutContent {

    static let summary = """
    面向 iOS 的小说阅读器，把社区书源规则用于搜索、书籍详情、目录与正文阅读。
    """

    static let privacyPolicy = """
    本应用重视您的隐私。以下说明与您有关的数据是如何被处理的。

    一、不收集个人信息
    本应用没有账号体系，不要求注册，也不会收集、上传或分享任何可识别您个人身份的信息。应用内不含第三方统计、广告或用户行为追踪组件。

    二、数据保存在您的设备上
    书架、阅读进度、书签、书源、替换规则、RSS 订阅、主题与字体等数据，全部保存在本机应用沙盒内。卸载应用会一并删除这些数据，我们无法为您恢复，建议定期使用备份功能。

    三、网络请求的用途
    应用仅在以下情况发起网络请求：
    · 通过书源搜索书籍，获取书籍详情、目录与正文；
    · 订阅并更新您自行添加的 RSS 源；
    · 导入书源、主题或字体时，访问您指定的网络地址。
    请求内容仅包含完成上述功能所必需的信息，不包含您的个人身份信息。

    四、剪贴板与文件
    仅在您主动触发导入、分享或粘贴操作时读取相应内容，不会在后台读取。

    五、第三方网站
    书源由社区维护，指向第三方网站。这些网站的内容与数据处理方式由其自身负责，不在本政策的覆盖范围内。

    六、联系我们
    如对本政策有疑问，可通过项目主页 https://github.com/FiathZZ/Legado 反馈。
    """

    static let license = """
    本应用是一个开源项目，源码托管于 https://github.com/FiathZZ/Legado 。

    一、书源规则生态
    书源规则来自社区，其生态来源于 Android 开源阅读项目 legado（https://github.com/gedoor/legado），该项目以 GNU General Public License v3.0 发布。

    二、致谢
    本项目在早期实现中参考了 swiftLegado（https://github.com/Apolla/swiftLegado），并以 Legado 作为独立项目持续维护。

    三、第三方组件
    应用内使用了若干开源组件，包括 Alamofire、Kanna、SwiftSoup、SwCrypt、GCDWebServer 等，它们各自遵循其原始许可协议。完整许可文本随各组件源码一并提供。
    """

    static let disclaimer = """
    请在使用本应用前阅读以下内容。

    一、软件性质
    本应用是一款开源的小说阅读器，仅提供阅读工具与书源规则的解析能力，自身不提供、不存储、不分发任何书籍内容。

    二、书源与内容
    书源规则由社区用户维护，指向第三方网站。本应用不对这些网站的内容、可用性与合法性作任何保证。您通过书源获取的一切内容，其版权归原作者及相应权利人所有。

    三、责任限制
    请勿将本应用用于侵犯他人合法权益或违反当地法律法规的用途。因使用本应用或第三方书源所产生的任何后果，由使用者自行承担，开发者不承担任何责任。

    四、支持正版
    如果您喜欢某部作品，请通过正规渠道购买或订阅，以支持作者持续创作。

    五、权利反馈
    如认为本应用或某个书源侵犯了您的权益，请通过 https://github.com/FiathZZ/Legado 联系我们，我们会及时处理。
    """
}
