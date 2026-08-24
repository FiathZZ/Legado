import Foundation
#if canImport(FoundationNetworking)
import FoundationNetworking
#endif

// MARK: - CookieManager
/// Cookie 管理器：持久化存储和管理各书源的 Cookie
public nonisolated final class CookieManager {

    // MARK: - 单例

    public static let shared = CookieManager()

    // MARK: - 属性

    /// 内存中的 Cookie 存储：[域名: [名称: 值]]
    private var cookieStore: [String: [String: String]] = [:]
    /// 搜索会同时执行多个书源请求，Cookie 回写可能来自不同网络回调线程。
    private let cookieStoreLock = NSRecursiveLock()
    /// 使用 UserDefaults 持久化
    private let userDefaults = UserDefaults.standard
    private let storageKey = "LegadoCookieManager"

    // MARK: - 初始化

    private init() {
        loadFromStorage()
    }

    // MARK: - 公开接口

    /// 从 HTTP 响应头中解析并保存 Cookie
    /// - Parameters:
    ///   - response: HTTP 响应对象
    ///   - url: 响应 URL
    public func saveCookies(from response: HTTPURLResponse, url: URL) {
        let headerFields = response.allHeaderFields as? [String: String] ?? [:]
        let cookies = HTTPCookie.cookies(withResponseHeaderFields: headerFields, for: url)
        for cookie in cookies {
            saveCookie(cookie, domain: url.host ?? "")
        }
    }

    /// 保存单个 Cookie
    public func saveCookie(_ cookie: HTTPCookie, domain: String) {
        withCookieStoreLock {
            // HTTP responses often arrive from a subdomain while declaring a parent-domain
            // cookie (for example, `.qidian.com` from `m.qidian.com`). Preserve the declared
            // domain so `cookie.getKey("https://qidian.com", ...)` sees the same cookie as
            // Android's base-domain CookieStore.
            let declaredDomain = normalizedDomain(cookie.domain)
            let host = declaredDomain.isEmpty ? normalizedDomain(domain) : declaredDomain
            guard !host.isEmpty else { return }
            if cookieStore[host] == nil {
                cookieStore[host] = [:]
            }
            cookieStore[host]?[cookie.name] = cookie.value
            saveToStorage()
        }
    }

    /// 将内存中的 cookie 注入到系统 CookieStorage，供 URLSession/Alamofire 自动跟随跳转时使用。
    public func applyCookies(to storage: HTTPCookieStorage, for url: URL) {
        guard let host = url.host else { return }
        let mergedCookies = cookieMap(for: host)
        guard !mergedCookies.isEmpty else { return }

        for (name, value) in mergedCookies {
            var properties: [HTTPCookiePropertyKey: Any] = [
                .name: name,
                .value: value,
                .domain: host,
                .path: "/"
            ]
            properties[.secure] = (url.scheme?.lowercased() == "https")
            if let cookie = HTTPCookie(properties: properties) {
                storage.setCookie(cookie)
            }
        }
    }

    /// 从系统 CookieStorage 中回收指定 URL 对应的 cookie，持久化回 Legado 的 CookieManager。
    public func absorbCookies(from storage: HTTPCookieStorage, for url: URL) {
        guard let host = url.host else { return }
        let cookies = storage.cookies(for: url) ?? []
        for cookie in cookies {
            saveCookie(cookie, domain: host)
        }
    }

    /// 手动设置 Cookie
    /// - Parameters:
    ///   - name: Cookie 名称
    ///   - value: Cookie 值
    ///   - domain: 域名
    public func setCookie(name: String, value: String, domain: String) {
        withCookieStoreLock {
            let normalizedDomain = normalizedDomain(domain)
            guard !normalizedDomain.isEmpty else { return }
            if cookieStore[normalizedDomain] == nil {
                cookieStore[normalizedDomain] = [:]
            }
            cookieStore[normalizedDomain]?[name] = value
            saveToStorage()
        }
    }

    /// 获取指定域名的所有 Cookie 字符串（适用于 HTTP 请求头）
    /// - Parameter url: 请求 URL
    /// - Returns: Cookie 字符串，格式为 `name1=value1; name2=value2`
    public func getCookieString(for url: URL) -> String {
        guard let host = url.host else { return "" }
        return getCookieString(domain: host)
    }

    /// 获取指定域名的 Cookie 字符串
    public func getCookieString(domain: String) -> String {
        let cookies = cookieMap(for: domain)
        guard !cookies.isEmpty else { return "" }
        return cookies
            .keys
            .sorted()
            .compactMap { name in
                cookies[name].map { "\(name)=\($0)" }
            }
            .joined(separator: "; ")
    }

    /// 获取单个 Cookie 值
    public func getCookieValue(name: String, domain: String) -> String? {
        return cookieMap(for: domain)[name]
    }

    /// 解析 Cookie 字符串并保存
    /// - Parameters:
    ///   - cookieString: Cookie 字符串（格式：`name1=value1; name2=value2`）
    ///   - domain: 域名
    public func parseCookieString(_ cookieString: String, domain: String) {
        let parsedCookies = cookieDictionary(from: cookieString)
        guard !parsedCookies.isEmpty else { return }
        mergeCookies(parsedCookies, into: domain, replaceExisting: true)
    }

    /// Android CookieStore.replaceCookie 对齐：将新 cookie 对覆盖合并到原有 domain cookie 上。
    public func replaceCookieString(_ cookieString: String, domain: String) {
        let parsedCookies = cookieDictionary(from: cookieString)
        guard !parsedCookies.isEmpty else { return }
        mergeCookies(parsedCookies, into: domain, replaceExisting: true)
    }

    /// Android CookieStore.getKey 对齐：按 domain 继承链读取单个 cookie 键值。
    public func getCookieKey(_ key: String, domain: String) -> String {
        getCookieValue(name: key, domain: domain) ?? ""
    }

    /// Android CookieStore.removeCookie 对齐：清除精确域名及其子域别名。
    public func removeCookie(domain: String) {
        withCookieStoreLock {
            let normalizedDomain = domain.lowercased()
            let targets = cookieStore.keys.filter { storedDomain in
                let candidate = storedDomain.lowercased()
                return candidate == normalizedDomain || candidate.hasSuffix(".\(normalizedDomain)")
            }
            if targets.isEmpty {
                cookieStore.removeValue(forKey: domain)
            } else {
                targets.forEach { cookieStore.removeValue(forKey: $0) }
            }
            saveToStorage()
        }
    }

    /// 清除指定域名的所有 Cookie
    public func clearCookies(domain: String) {
        removeCookie(domain: domain)
    }

    /// 清除所有 Cookie
    public func clearAllCookies() {
        withCookieStoreLock {
            cookieStore.removeAll()
            saveToStorage()
        }
    }

    // MARK: - 持久化

    private func saveToStorage() {
        userDefaults.set(cookieStore, forKey: storageKey)
    }

    private func loadFromStorage() {
        withCookieStoreLock {
            if let stored = userDefaults.dictionary(forKey: storageKey) as? [String: [String: String]] {
                cookieStore = stored
            }
        }
    }

    private func mergeCookies(
        _ cookies: [String: String],
        into domain: String,
        replaceExisting: Bool
    ) {
        withCookieStoreLock {
            let normalizedDomain = normalizedDomain(domain)
            guard !normalizedDomain.isEmpty else { return }

            var merged = cookieStore[normalizedDomain] ?? [:]
            for (name, value) in cookies where !name.isEmpty {
                if replaceExisting || merged[name] == nil {
                    merged[name] = value
                }
            }
            cookieStore[normalizedDomain] = merged
            saveToStorage()
        }
    }

    private func cookieDictionary(from cookieString: String) -> [String: String] {
        var result: [String: String] = [:]
        for pair in cookieString.components(separatedBy: ";") {
            let parts = pair.trimmingCharacters(in: .whitespaces).components(separatedBy: "=")
            guard parts.count >= 2 else { continue }
            let name = parts[0].trimmingCharacters(in: .whitespaces)
            let value = parts.dropFirst().joined(separator: "=").trimmingCharacters(in: .whitespaces)
            guard !name.isEmpty else { continue }
            result[name] = value
        }
        return result
    }

    private func cookieMap(for domain: String) -> [String: String] {
        withCookieStoreLock {
            var merged: [String: String] = [:]
            let requestedDomain = normalizedDomain(domain)

            for (storedDomain, cookies) in cookieStore {
                let candidate = normalizedDomain(storedDomain)
                if requestedDomain == candidate || requestedDomain.hasSuffix(".\(candidate)") {
                    merged.merge(cookies) { _, new in new }
                }
            }

            return merged
        }
    }

    private func normalizedDomain(_ domain: String) -> String {
        domain
            .trimmingCharacters(in: .whitespacesAndNewlines)
            .trimmingCharacters(in: CharacterSet(charactersIn: "."))
            .lowercased()
    }

    private func withCookieStoreLock<Value>(_ body: () -> Value) -> Value {
        cookieStoreLock.lock()
        defer { cookieStoreLock.unlock() }
        return body()
    }
}
