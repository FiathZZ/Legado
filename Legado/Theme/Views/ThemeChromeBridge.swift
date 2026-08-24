import SwiftUI
#if canImport(UIKit)
import UIKit
#endif

#if canImport(UIKit)
private final class ThemeChromeHostController: UIViewController {
    var onChromeUpdate: ((UIViewController) -> Void)?

    override func viewDidAppear(_ animated: Bool) {
        super.viewDidAppear(animated)
        onChromeUpdate?(self)
    }

    override func didMove(toParent parent: UIViewController?) {
        super.didMove(toParent: parent)
        onChromeUpdate?(self)
    }
}

private struct ThemeChromeBridge: UIViewControllerRepresentable {
    @EnvironmentObject private var themeManager: ThemeManager

    let includeTabBar: Bool

    func makeUIViewController(context: Context) -> ThemeChromeHostController {
        ThemeChromeHostController()
    }

    func updateUIViewController(_ uiViewController: ThemeChromeHostController, context: Context) {
        uiViewController.onChromeUpdate = { controller in
            applyChrome(from: controller)
        }
        applyChrome(from: uiViewController)
    }

    private func applyChrome(from controller: UIViewController) {
        if let navigationBar = controller.navigationController?.navigationBar {
            themeManager.applyNavigationAppearance(to: navigationBar)
        }

        if includeTabBar, let tabBar = controller.tabBarController?.tabBar {
            themeManager.applyTabAppearance(to: tabBar)
        }
    }
}
#endif

private struct ThemedNavigationChromeModifier: ViewModifier {
    @EnvironmentObject private var themeManager: ThemeManager

    func body(content: Content) -> some View {
#if canImport(UIKit)
        content
            .toolbarBackground(themeManager.color(.navigationBackground), for: .navigationBar)
            .toolbarBackground(.visible, for: .navigationBar)
            .background(
                ThemeChromeBridge(includeTabBar: false)
                    .id(themeManager.chromeRefreshToken)
                    .frame(width: 0, height: 0)
            )
#else
        content
#endif
    }
}

private struct ThemedTabChromeModifier: ViewModifier {
    @EnvironmentObject private var themeManager: ThemeManager

    func body(content: Content) -> some View {
#if canImport(UIKit)
        content
            .toolbarBackground(themeManager.color(.navigationBackground), for: .tabBar)
            .toolbarBackground(.visible, for: .tabBar)
            .background(
                ThemeChromeBridge(includeTabBar: true)
                    .id(themeManager.chromeRefreshToken)
                    .frame(width: 0, height: 0)
            )
#else
        content
#endif
    }
}

extension View {
    func themedNavigationChrome() -> some View {
        modifier(ThemedNavigationChromeModifier())
    }

    func themedTabChrome() -> some View {
        modifier(ThemedTabChromeModifier())
    }
}
