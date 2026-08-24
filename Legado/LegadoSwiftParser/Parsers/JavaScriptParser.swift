import Foundation
import SwiftSoup
import CommonCrypto
import Security
import SwCrypt
#if canImport(WebKit)
import WebKit
#endif
#if canImport(JavaScriptCore)
import JavaScriptCore
#endif

public nonisolated struct ParserVariableStore {
    public enum Scope {
        case source
        case ruleData
        case book
        case chapter
    }

    // Swift 之前把所有变量压平成一个字典，跨阶段重新建 WebBook 时会丢掉。
    // Android legado 使用 chapter -> book -> ruleData -> source 分层关系，这里显式维护四层存储。
    private let sourceStorage: NSMutableDictionary
    private let ruleDataStorage: NSMutableDictionary
    private let bookStorage: NSMutableDictionary
    private let chapterStorage: NSMutableDictionary

    public let writeScope: Scope

    public var values: [String: String] {
        get { mergedRuntimeValues(includeChapter: true) }
        set { replaceScope(writeScope, with: newValue) }
    }

    public init(values: [String: String] = [:], writeScope: Scope = .ruleData) {
        self.init(
            sourceValues: writeScope == .source ? values : [:],
            ruleDataValues: writeScope == .ruleData ? values : [:],
            bookValues: writeScope == .book ? values : [:],
            chapterValues: writeScope == .chapter ? values : [:],
            writeScope: writeScope
        )
    }

    public init(writeScope: Scope) {
        self.init(values: [:], writeScope: writeScope)
    }

    public init(
        sourceValues: [String: String] = [:],
        ruleDataValues: [String: String] = [:],
        bookValues: [String: String] = [:],
        chapterValues: [String: String] = [:],
        writeScope: Scope = .ruleData
    ) {
        self.sourceStorage = NSMutableDictionary(dictionary: sourceValues)
        self.ruleDataStorage = NSMutableDictionary(dictionary: ruleDataValues)
        self.bookStorage = NSMutableDictionary(dictionary: bookValues)
        self.chapterStorage = NSMutableDictionary(dictionary: chapterValues)
        self.writeScope = writeScope
    }

    private init(
        sourceStorage: NSMutableDictionary,
        ruleDataStorage: NSMutableDictionary,
        bookStorage: NSMutableDictionary,
        chapterStorage: NSMutableDictionary,
        writeScope: Scope
    ) {
        self.sourceStorage = sourceStorage
        self.ruleDataStorage = ruleDataStorage
        self.bookStorage = bookStorage
        self.chapterStorage = chapterStorage
        self.writeScope = writeScope
    }

    public func get(_ key: String) -> String {
        if let value = preferredValue(in: chapterStorage, key: key) { return value }
        if let value = preferredValue(in: bookStorage, key: key) { return value }
        if let value = preferredValue(in: ruleDataStorage, key: key) { return value }
        if let value = preferredValue(in: sourceStorage, key: key) { return value }
        return fallbackValue(in: chapterStorage, key: key)
            ?? fallbackValue(in: bookStorage, key: key)
            ?? fallbackValue(in: ruleDataStorage, key: key)
            ?? fallbackValue(in: sourceStorage, key: key)
            ?? ""
    }

    @discardableResult
    public func put(_ key: String, value: String, scope: Scope? = nil) -> String {
        let targetScope = scope ?? writeScope
        storage(for: targetScope)[key] = value
        return value
    }

    public func merge(_ values: [String: String], into scope: Scope? = nil) {
        let targetScope = scope ?? writeScope
        values.forEach { key, value in
            _ = put(key, value: value, scope: targetScope)
        }
    }

    public func replaceScope(_ scope: Scope, with values: [String: String]) {
        let storage = storage(for: scope)
        storage.removeAllObjects()
        storage.addEntries(from: values)
    }

    public func resetRuleData() {
        ruleDataStorage.removeAllObjects()
    }

    public func snapshot(for scope: Scope, includeInherited: Bool) -> [String: String] {
        switch scope {
        case .source:
            return dictionary(from: sourceStorage)
        case .ruleData:
            guard includeInherited else { return dictionary(from: ruleDataStorage) }
            var merged = dictionary(from: sourceStorage)
            merged.merge(dictionary(from: ruleDataStorage)) { _, new in new }
            return merged
        case .book:
            guard includeInherited else { return dictionary(from: bookStorage) }
            return mergedValues(includeChapter: false)
        case .chapter:
            guard includeInherited else { return dictionary(from: chapterStorage) }
            return mergedValues(includeChapter: true)
        }
    }

    public func makeChildStore(
        writeScope: Scope,
        inheritBookScope: Bool = true,
        resetRuleData: Bool = false,
        initialValues: [String: String] = [:]
    ) -> ParserVariableStore {
        let childRuleDataStorage = resetRuleData ? NSMutableDictionary() : ruleDataStorage
        switch writeScope {
        case .source:
            return ParserVariableStore(
                sourceStorage: sourceStorage,
                ruleDataStorage: childRuleDataStorage,
                bookStorage: NSMutableDictionary(),
                chapterStorage: NSMutableDictionary(),
                writeScope: .source
            )
        case .ruleData:
            return ParserVariableStore(
                sourceStorage: sourceStorage,
                ruleDataStorage: resetRuleData ? NSMutableDictionary(dictionary: initialValues) : ruleDataStorage,
                bookStorage: inheritBookScope ? bookStorage : NSMutableDictionary(),
                chapterStorage: NSMutableDictionary(),
                writeScope: .ruleData
            )
        case .book:
            return ParserVariableStore(
                sourceStorage: sourceStorage,
                ruleDataStorage: childRuleDataStorage,
                bookStorage: inheritBookScope ? bookStorage : NSMutableDictionary(dictionary: initialValues),
                chapterStorage: NSMutableDictionary(),
                writeScope: .book
            )
        case .chapter:
            return ParserVariableStore(
                sourceStorage: sourceStorage,
                ruleDataStorage: childRuleDataStorage,
                bookStorage: inheritBookScope ? bookStorage : NSMutableDictionary(),
                chapterStorage: NSMutableDictionary(dictionary: initialValues),
                writeScope: .chapter
            )
        }
    }

    public func cloned(writeScope: Scope? = nil) -> ParserVariableStore {
        ParserVariableStore(
            sourceValues: dictionary(from: sourceStorage),
            ruleDataValues: dictionary(from: ruleDataStorage),
            bookValues: dictionary(from: bookStorage),
            chapterValues: dictionary(from: chapterStorage),
            writeScope: writeScope ?? self.writeScope
        )
    }

    private func mergedValues(includeChapter: Bool) -> [String: String] {
        var merged = dictionary(from: sourceStorage)
        merged.merge(dictionary(from: bookStorage)) { _, new in new }
        if includeChapter {
            merged.merge(dictionary(from: chapterStorage)) { _, new in new }
        }
        return merged
    }

    private func mergedRuntimeValues(includeChapter: Bool) -> [String: String] {
        var merged = dictionary(from: sourceStorage)
        merged.merge(dictionary(from: ruleDataStorage)) { _, new in new }
        merged.merge(dictionary(from: bookStorage)) { _, new in new }
        if includeChapter {
            merged.merge(dictionary(from: chapterStorage)) { _, new in new }
        }
        return merged
    }

    private func preferredValue(in storage: NSMutableDictionary, key: String) -> String? {
        guard let value = fallbackValue(in: storage, key: key), !value.isEmpty else { return nil }
        return value
    }

    private func fallbackValue(in storage: NSMutableDictionary, key: String) -> String? {
        if let value = storage[key] as? String {
            return value
        }
        if let value = storage[key] {
            return "\(value)"
        }
        return nil
    }

    private func storage(for scope: Scope) -> NSMutableDictionary {
        switch scope {
        case .source:
            return sourceStorage
        case .ruleData:
            return ruleDataStorage
        case .book:
            return bookStorage
        case .chapter:
            return chapterStorage
        }
    }

    private func dictionary(from storage: NSMutableDictionary) -> [String: String] {
        var result: [String: String] = [:]
        for case let (key as String, value) in storage {
            result[key] = value as? String ?? "\(value)"
        }
        return result
    }
}

#if canImport(JavaScriptCore)
private nonisolated enum ResponseBridgeFactory {
    static let responseMarkerKey = "__LegadoResponseMarker"
    static let responseMarkerValue = "__LegadoResponse"

    static func makeResponseObject(
        from response: HTTPResponse,
        fallbackRequestURL: String,
        requestURLOverride: String? = nil,
        in context: JSContext
    ) -> JSValue? {
        let bodyText = response.text ?? ""
        let statusCode = response.statusCode
        let finalURL = normalizedBridgeURLString(response.url?.absoluteString ?? fallbackRequestURL)
        let requestURL = normalizedBridgeURLString(requestURLOverride ?? response.requestURL?.absoluteString ?? fallbackRequestURL)
        let headersJSON = makeJSONLiteral(makeResponseHeaders(from: response)) ?? "{}"
        let headerValuesJSON = makeJSONLiteral(response.headerValues) ?? "{}"
        let bodyLiteral = makeJSONStringLiteral(bodyText)
        let finalURLLiteral = makeJSONStringLiteral(finalURL)
        let requestURLLiteral = makeJSONStringLiteral(requestURL)
        let effectiveRequestURLLiteral = makeJSONStringLiteral(finalURL)
        let messageLiteral = makeJSONStringLiteral(response.message)
        let markerKeyLiteral = makeJSONStringLiteral(responseMarkerKey)
        let markerValueLiteral = makeJSONStringLiteral(responseMarkerValue)

        return context.evaluateScript(
            """
            (function() {
                var bodyText = \(bodyLiteral);
                var statusCode = \(statusCode);
                var finalURL = \(finalURLLiteral);
                var requestURL = \(requestURLLiteral);
                var effectiveRequestURL = \(effectiveRequestURLLiteral);
                var message = \(messageLiteral);
                var headersMap = \(headersJSON);
                var headerValues = \(headerValuesJSON);

                function normalizeHeaderName(name) {
                    return String(name || '').toLowerCase();
                }

                function bodyAccessor() { return bodyText; }
                var methods = ['indexOf', 'includes', 'startsWith', 'endsWith', 'match', 'replace', 'trim', 'split', 'substring', 'substr', 'slice', 'toLowerCase', 'toUpperCase', 'charAt'];
                methods.forEach(function(name) {
                    bodyAccessor[name] = function() {
                        return String.prototype[name].apply(bodyText, arguments);
                    };
                });
                bodyAccessor.toString = function() { return bodyText; };
                bodyAccessor.valueOf = function() { return bodyText; };
                if (typeof Symbol !== 'undefined' && Symbol.toPrimitive) {
                    bodyAccessor[Symbol.toPrimitive] = function() { return bodyText; };
                }
                bodyAccessor.text = bodyText;

                function urlAccessor() { return finalURL; }
                methods.forEach(function(name) {
                    urlAccessor[name] = function() {
                        return String.prototype[name].apply(finalURL, arguments);
                    };
                });
                urlAccessor.toString = function() { return finalURL; };
                urlAccessor.valueOf = function() { return finalURL; };
                if (typeof Symbol !== 'undefined' && Symbol.toPrimitive) {
                    urlAccessor[Symbol.toPrimitive] = function() { return finalURL; };
                }
                urlAccessor.text = finalURL;

                var headersObject = Object.assign({}, headersMap);
                headersObject.get = function(name) {
                    var value = headersMap[normalizeHeaderName(name)];
                    return value == null ? '' : value;
                };
                headersObject.getAll = function(name) {
                    var value = headerValues[normalizeHeaderName(name)];
                    return Array.isArray(value) ? value : [];
                };
                headersObject.values = headerValues;

                var responseObject = {
                    body: bodyAccessor,
                    bodyText: bodyText,
                    text: bodyText,
                    url: urlAccessor,
                    finalURL: finalURL,
                    finalUrl: finalURL,
                    requestUrl: requestURL,
                    requestURL: requestURL,
                    status: statusCode,
                    statusValue: statusCode,
                    statusCodeValue: statusCode,
                    codeValue: statusCode,
                    message: message,
                    success: statusCode >= 200 && statusCode < 300,
                    isSuccess: statusCode >= 200 && statusCode < 300,
                    headerMap: headersObject,
                    headersMap: headersObject,
                    code: function() { return statusCode; },
                    statusCode: function() { return statusCode; },
                    headers: function() { return headersObject; },
                    headersValue: function(name) { return headersObject.get(name); },
                    header: function(name) { return headersObject.get(name); },
                    isSuccessful: function() { return statusCode >= 200 && statusCode < 300; },
                    getText: function() { return bodyText; },
                    getUrl: function() { return finalURL; },
                    getRequestUrl: function() { return effectiveRequestURL; }
                };
                responseObject.headers = function(name) {
                    if (arguments.length === 0) {
                        return headersObject;
                    }
                    return headersObject.get(name);
                };
                responseObject.raw = function() { return responseObject; };
                responseObject.request = function() {
                    return {
                        url: function() { return effectiveRequestURL; },
                        urlString: effectiveRequestURL,
                        headers: function() { return headersObject; }
                    };
                };
                responseObject.requestUrl = function() { return effectiveRequestURL; };
                responseObject[\(markerKeyLiteral)] = \(markerValueLiteral);
                return responseObject;
            })()
            """
        )
    }

    static func isResponseObject(_ value: JSValue?) -> Bool {
        guard let value, value.isObject else { return false }
        return value.forProperty(responseMarkerKey)?.toString() == responseMarkerValue
    }

    private static func makeJSONStringLiteral(_ value: String) -> String {
        if let data = try? JSONSerialization.data(withJSONObject: [value], options: []),
           let json = String(data: data, encoding: .utf8),
           json.count >= 2 {
            return String(json.dropFirst().dropLast())
        }
        let escaped = value
            .replacingOccurrences(of: "\\", with: "\\\\")
            .replacingOccurrences(of: "\"", with: "\\\"")
            .replacingOccurrences(of: "\n", with: "\\n")
            .replacingOccurrences(of: "\r", with: "\\r")
        return "\"\(escaped)\""
    }

    private static func makeJSONLiteral(_ object: Any) -> String? {
        guard JSONSerialization.isValidJSONObject(object),
              let data = try? JSONSerialization.data(withJSONObject: object, options: [.sortedKeys]),
              let text = String(data: data, encoding: .utf8) else {
            return nil
        }
        return text
    }

    private static func normalizedBridgeURLString(_ rawValue: String) -> String {
        let trimmed = rawValue.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty,
              var components = URLComponents(string: trimmed),
              let scheme = components.scheme,
              !scheme.isEmpty,
              let host = components.host,
              !host.isEmpty else {
            return trimmed
        }

        if components.path.isEmpty {
            components.path = "/"
        }

        return components.string ?? trimmed
    }

    private static func makeResponseHeaders(from response: HTTPResponse) -> [String: String] {
        var headers: [String: String] = [:]
        for (key, value) in response.headers {
            headers[key] = value
            headers[key.lowercased()] = value
        }
        return headers
    }
}

private nonisolated struct JsoupBridgeStore {
    private static let markerAttributeKey = "data-swift-legado-jsoup-marker"

    struct DocumentState {
        var html: String
        let baseURL: String
    }

    struct ElementState {
        let documentToken: String
        let marker: String
    }

    enum Entry {
        case document(token: String)
        case element(documentToken: String, marker: String)
    }

    private let lock: NSRecursiveLock = {
        let lock = NSRecursiveLock()
        lock.name = "Legado.JavaScriptParser.jsoupStore"
        return lock
    }()

    private var documents: [String: DocumentState] = [:]
    private var elements: [String: ElementState] = [:]

    mutating func clear() {
        lock.lock()
        defer { lock.unlock() }
        documents.removeAll()
        elements.removeAll()
    }

    mutating func registerDocument(html: String, baseURL: String) -> String {
        lock.lock()
        defer { lock.unlock() }
        let token = UUID().uuidString
        documents[token] = DocumentState(html: html, baseURL: baseURL)
        return token
    }

    mutating func entry(for token: String) -> Entry? {
        lock.lock()
        defer { lock.unlock() }

        if documents[token] != nil {
            return .document(token: token)
        }
        if let element = elements[token] {
            return .element(documentToken: element.documentToken, marker: element.marker)
        }
        return nil
    }

    mutating func remove(_ token: String) {
        lock.lock()
        defer { lock.unlock() }
        documents.removeValue(forKey: token)
        elements.removeValue(forKey: token)
    }

    mutating func select(from entry: Entry, selector: String) -> [String] {
        lock.lock()
        defer { lock.unlock() }

        guard let context = selectionContext(for: entry) else { return [] }

        let selected: Elements
        if let root = context.root {
            selected = (try? root.select(selector)) ?? Elements()
        } else {
            selected = (try? context.document.select(selector)) ?? Elements()
        }

        let tokens = selected.array().map { element in
            let marker = ensureMarker(for: element)
            return registerElement(documentToken: context.documentToken, marker: marker)
        }
        persist(document: context.document, for: context.documentToken)
        return tokens
    }

    func sanitizedHTML(for entry: Entry, outer: Bool) -> String {
        lock.lock()
        defer { lock.unlock() }

        let rawHTML: String
        guard let context = selectionContext(for: entry) else { return "" }
        if let root = context.root {
            rawHTML = (try? (outer ? root.outerHtml() : root.html())) ?? ""
        } else {
            rawHTML = (try? (outer ? context.document.outerHtml() : context.document.html())) ?? ""
        }

        return stripMarkerAttribute(from: rawHTML)
    }

    func sanitizedText(for entry: Entry) -> String {
        lock.lock()
        defer { lock.unlock() }
        guard let context = selectionContext(for: entry) else { return "" }
        if let root = context.root {
            return (try? root.text()) ?? ""
        }
        return (try? context.document.text()) ?? ""
    }

    func attributeValue(for entry: Entry, name: String) -> String {
        lock.lock()
        defer { lock.unlock() }
        guard let context = selectionContext(for: entry) else { return "" }
        switch entry {
        case .document:
            if let body = context.document.body(),
               let value = try? body.attr(name),
               !value.isEmpty {
                return value
            }
            if let first = try? context.document.select("*").first(),
               let value = try? first.attr(name),
               !value.isEmpty {
                return value
            }
            return ""
        case .element:
            return (try? context.root?.attr(name)) ?? ""
        }
    }

    func hasClass(for entry: Entry, name: String) -> Bool {
        lock.lock()
        defer { lock.unlock() }
        guard let context = selectionContext(for: entry) else { return false }
        switch entry {
        case .document:
            return (try? context.document.className().split(whereSeparator: \.isWhitespace).contains(Substring(name))) ?? false
        case .element:
            return context.root?.hasClass(name) ?? false
        }
    }

    func data(for entry: Entry) -> String {
        lock.lock()
        defer { lock.unlock() }
        guard let context = selectionContext(for: entry) else { return "" }
        if let root = context.root {
            return root.data()
        }
        return context.document.data()
    }

    mutating func removeElement(for entry: Entry) -> Bool {
        lock.lock()
        defer { lock.unlock() }

        guard case let .element(documentToken, marker) = entry,
              let documentState = documents[documentToken],
              let parsed = try? SwiftSoup.parse(documentState.html, documentState.baseURL),
              let element = findElement(marker: marker, in: parsed) else {
            return false
        }
        try? element.remove()
        persist(document: parsed, for: documentToken)
        return true
    }

    private mutating func registerElement(documentToken: String, marker: String) -> String {
        let token = UUID().uuidString
        elements[token] = ElementState(documentToken: documentToken, marker: marker)
        return token
    }

    private func ensureMarker(for element: Element) -> String {
        if let existing = try? element.attr(Self.markerAttributeKey), !existing.isEmpty {
            return existing
        }
        let marker = UUID().uuidString
        try? element.attr(Self.markerAttributeKey, marker)
        return marker
    }

    private func findElement(marker: String, in document: Document) -> Element? {
        let selector = "[\(Self.markerAttributeKey)=\"\(marker)\"]"
        return try? document.select(selector).first()
    }

    private func selectionContext(for entry: Entry) -> (documentToken: String, document: Document, root: Element?)? {
        switch entry {
        case let .document(token):
            guard let documentState = documents[token],
                  let parsed = try? SwiftSoup.parse(documentState.html, documentState.baseURL) else {
                return nil
            }
            return (token, parsed, nil)
        case let .element(documentToken, marker):
            guard let documentState = documents[documentToken],
                  let parsed = try? SwiftSoup.parse(documentState.html, documentState.baseURL),
                  let element = findElement(marker: marker, in: parsed) else {
                return nil
            }
            return (documentToken, parsed, element)
        }
    }

    private mutating func persist(document: Document, for token: String) {
        guard var state = documents[token] else { return }
        state.html = (try? document.outerHtml()) ?? state.html
        documents[token] = state
    }

    private func stripMarkerAttribute(from html: String) -> String {
        html.replacingOccurrences(
            of: #"\sdata-swift-legado-jsoup-marker="[^"]*""#,
            with: "",
            options: .regularExpression
        )
    }
}
#endif

// MARK: - JavaScriptParser
/// JavaScript 规则执行器
///
/// 支持在 legado 书源规则中内嵌的 JavaScript 代码。
/// 在 iOS/macOS 上使用 JavaScriptCore 框架执行；
/// 在 Linux 上提供基础的结果透传（不执行 JS）。
///
/// JS 上下文中提供以下全局变量：
/// - `result`：前置规则的提取结果（字符串）
/// - `baseUrl`：当前页面的基础 URL
/// - `source`：书源对象（简化版）
public nonisolated class JavaScriptParser {
    fileprivate static let jsResultStoreKey = "__LegadoJSCurrentResult"
    public enum LoginCheckAction {
        case keepOriginal
        case rewriteBody(String)
        case reject
    }

    // MARK: - 属性

    private var baseUrl: String
    private var source: BookSource?
    private var currentContent: String = ""
    private var currentResultContent: String = ""
    private let variableStore: ParserVariableStore
    private let requestURL: String
    private let requestHeaders: [String: String]
    private let initialInfoMap: [String: String]
    private var bookContextPayload: [String: Any] = [:]

#if canImport(JavaScriptCore)
    private let runtimeLock: NSRecursiveLock = {
        let lock = NSRecursiveLock()
        lock.name = "Legado.JavaScriptParser.runtimeLock"
        return lock
    }()

    private var context: JSContext!
    private var javaBridge: JavaBridge!
#endif

    // MARK: - 初始化

    public init(
        baseUrl: String = "",
        source: BookSource? = nil,
        variableStore: ParserVariableStore = ParserVariableStore(),
        requestURL: String? = nil,
        requestHeaders: [String: String] = [:],
        initialInfoMap: [String: String] = [:]
    ) {
        self.baseUrl = baseUrl
        self.source = source
        self.variableStore = variableStore
        self.requestURL = requestURL ?? baseUrl
        self.requestHeaders = requestHeaders
        self.initialInfoMap = initialInfoMap
    }

    // 解析器实例在 compare 批量跑中会被高频创建和释放，而工程又启用了默认 MainActor 隔离。
    // 若析构阶段被系统推回主线程，再叠加 JSContext / ObjC bridge 的释放顺序，就容易出现
    // JavaScriptCore 生命周期抖动甚至释放期 crash。显式 nonisolated 可以保持析构发生在
    // 当前调用线程，和运行时锁、bridge 清理逻辑保持一致。
    nonisolated deinit {}

    // MARK: - 执行 JS

    /// 执行 JavaScript 代码，传入初始结果值
    /// - Parameters:
    ///   - script: JS 代码字符串
    ///   - result: 传入 JS 的 `result` 变量值
    /// - Returns: JS 执行结果字符串
    public func evaluate(script: String, result: String = "") throws -> String {
#if canImport(JavaScriptCore)
        return try withRuntimeLock {
            try Self.withAutoreleasePool {
                rebuildRuntime()
                defer { tearDownRuntime() }
                currentResultContent = result
                _ = variableStore.put(Self.jsResultStoreKey, value: result, scope: .ruleData)
                javaBridge.updateResultContent(result)
                prepareContext()
                context.setObject(result, forKeyedSubscript: "result" as NSString)
                context.exception = nil

                let jsResult = evaluateUserScript(script)

                if let exception = context.exception {
                    throw ParserError.javascriptError(exception.toString() ?? "未知 JS 错误")
                }
                let resolved = resolvedStringResult(
                    primary: jsResult,
                    fallback: context.objectForKeyedSubscript("result")
                )
                let primaryText = jsResult?.toString() ?? "nil"
                let fallbackText = context.objectForKeyedSubscript("result")?.toString() ?? "nil"
                ParserLog.debug(
                    "JavaScriptParser",
                    "evaluate resultString script=\(ParserLog.preview(script, limit: 160)) input=\(ParserLog.preview(result, limit: 120)) primary=\(ParserLog.preview(primaryText, limit: 160)) fallback=\(ParserLog.preview(fallbackText, limit: 160)) resolved=\(ParserLog.preview(resolved, limit: 200))"
                )
                return resolved
            }
        }
#else
        // Linux 上无法执行 JS，直接返回原始 result
        _ = script
        return result
#endif
    }

    /// 执行 JavaScript，允许将 `result` 作为对象/数组注入到 JS 上下文。
    public func evaluate(script: String, resultObject: Any, fallbackResult: String = "") throws -> String {
#if canImport(JavaScriptCore)
        return try withRuntimeLock {
            try Self.withAutoreleasePool {
                rebuildRuntime()
                defer { tearDownRuntime() }
                currentResultContent = fallbackResult
                _ = variableStore.put(Self.jsResultStoreKey, value: fallbackResult, scope: .ruleData)
                javaBridge.updateResultContent(fallbackResult)
                prepareContext()
                if JSONSerialization.isValidJSONObject(resultObject),
                   let data = try? JSONSerialization.data(withJSONObject: resultObject, options: [.sortedKeys]),
                   let json = String(data: data, encoding: .utf8),
                   let objectValue = context.evaluateScript("(\(json))") {
                    context.setObject(objectValue, forKeyedSubscript: "result" as NSString)
                } else {
                    context.setObject(resultObject, forKeyedSubscript: "result" as NSString)
                }
                context.setObject(fallbackResult, forKeyedSubscript: "__LegadoResultText" as NSString)
                context.exception = nil

                let jsResult = evaluateUserScript(script)

                if let exception = context.exception {
                    throw ParserError.javascriptError(exception.toString() ?? "未知 JS 错误")
                }

                return resolvedStringResult(
                    primary: jsResult,
                    fallback: context.objectForKeyedSubscript("result"),
                    fallbackString: fallbackResult
                )
            }
        }
#else
        _ = script
        return fallbackResult
#endif
    }

    /// 对 `loginCheckJs` 执行 Android 风格响应对象桥接，并返回安全的后处理动作。
    public func evaluateLoginCheck(
        script: String,
        response: HTTPResponse,
        fallbackRequestURL: String
    ) throws -> LoginCheckAction {
#if canImport(JavaScriptCore)
        return try withRuntimeLock {
            try Self.withAutoreleasePool {
                rebuildRuntime()
                defer { tearDownRuntime() }
                prepareContext()
                let resultObject = ResponseBridgeFactory.makeResponseObject(
                    from: response,
                    fallbackRequestURL: fallbackRequestURL,
                    in: context
                )
                let responseFactoryKey = "__LegadoLoginCheckResponseFactory"
                let responseFactory: @convention(block) () -> JSValue? = { resultObject }
                context.setObject(responseFactory, forKeyedSubscript: responseFactoryKey as NSString)
                context.evaluateScript("var result = \(responseFactoryKey)();")
                context.exception = nil

                let jsResult = evaluateLoginCheckScript(script)
                if let exception = context.exception {
                    throw ParserError.javascriptError(exception.toString() ?? "未知 JS 错误")
                }

                context.setObject(nil, forKeyedSubscript: responseFactoryKey as NSString)

                return resolveLoginCheckAction(
                    jsResult,
                    originalBody: response.text ?? "",
                    originalResponseObject: resultObject
                )
            }
        }
#else
        _ = script
        _ = response
        _ = fallbackRequestURL
        return .keepOriginal
#endif
    }

    /// 执行 JavaScript 代码，传入初始结果列表
    public func evaluate(script: String, results: [String]) throws -> String {
#if canImport(JavaScriptCore)
        return try withRuntimeLock {
            try Self.withAutoreleasePool {
                rebuildRuntime()
                defer { tearDownRuntime() }
                let firstResult = results.first ?? ""
                currentResultContent = firstResult
                _ = variableStore.put(Self.jsResultStoreKey, value: firstResult, scope: .ruleData)
                javaBridge.updateResultContent(firstResult)
                prepareContext()
                // result 设为第一个元素字符串（与 legado 行为一致），results 保留完整数组
                context.setObject(firstResult, forKeyedSubscript: "result" as NSString)
                let jsArray = context.evaluateScript("(\(toJSONString(results)))")
                context.setObject(jsArray, forKeyedSubscript: "results" as NSString)
                context.exception = nil

                let jsResult = evaluateUserScript(script)
                if let exception = context.exception {
                    throw ParserError.javascriptError(exception.toString() ?? "未知 JS 错误")
                }
                let resolved = resolvedStringResult(
                    primary: jsResult,
                    fallback: context.objectForKeyedSubscript("result"),
                    fallbackString: firstResult
                )
                let primaryText = jsResult?.toString() ?? "nil"
                let fallbackText = context.objectForKeyedSubscript("result")?.toString() ?? "nil"
                ParserLog.debug(
                    "JavaScriptParser",
                    "evaluate resultList script=\(ParserLog.preview(script, limit: 160)) first=\(ParserLog.preview(firstResult, limit: 120)) primary=\(ParserLog.preview(primaryText, limit: 160)) fallback=\(ParserLog.preview(fallbackText, limit: 160)) resolved=\(ParserLog.preview(resolved, limit: 200))"
                )
                return resolved
            }
        }
#else
        _ = script
        return results.joined(separator: "\n")
#endif
    }

    /// 执行 JavaScript 并尽量保留原始 JS 值（数组 / 对象 / 标量）。
    public func evaluateValue(script: String, result: String = "", results: [String] = []) throws -> Any? {
#if canImport(JavaScriptCore)
        return try withRuntimeLock {
            try Self.withAutoreleasePool {
                rebuildRuntime()
                defer { tearDownRuntime() }
                prepareContext()
                context.setObject(result, forKeyedSubscript: "result" as NSString)
                let jsArray = context.evaluateScript("(\(toJSONString(results)))")
                context.setObject(jsArray, forKeyedSubscript: "results" as NSString)
                context.exception = nil
                return try evaluateDetachedValue(script: script)
            }
        }
#else
        _ = script
        return results.isEmpty ? result : results
#endif
    }

    /// 执行 JavaScript 并将 `result` 注入为对象 / 数组等原始值，尽量保留返回值结构。
    public func evaluateValue(script: String, resultObject: Any, fallbackResult: String = "") throws -> Any? {
#if canImport(JavaScriptCore)
        return try withRuntimeLock {
            try Self.withAutoreleasePool {
                rebuildRuntime()
                defer { tearDownRuntime() }
                prepareContext()
                if JSONSerialization.isValidJSONObject(resultObject),
                   let data = try? JSONSerialization.data(withJSONObject: resultObject, options: [.sortedKeys]),
                   let json = String(data: data, encoding: .utf8),
                   let objectValue = context.evaluateScript("(\(json))") {
                    context.setObject(objectValue, forKeyedSubscript: "result" as NSString)
                    context.setObject(objectValue, forKeyedSubscript: "results" as NSString)
                } else {
                    context.setObject(resultObject, forKeyedSubscript: "result" as NSString)
                    context.setObject(resultObject, forKeyedSubscript: "results" as NSString)
                }
                context.setObject(fallbackResult, forKeyedSubscript: "__LegadoResultText" as NSString)
                context.exception = nil
                return try evaluateDetachedValue(script: script, fallbackString: fallbackResult)
            }
        }
#else
        _ = script
        return resultObject
#endif
    }

    /// 执行 JavaScript，并同时返回脚本直接返回值与最终 `result` 变量，
    /// 供 AnalyzeUrl 这类需要贴近 Android `evalJS` 语义的调用方决定优先级。
    public func evaluateWithContext(script: String, result: String = "") throws -> (primary: Any?, result: Any?, url: Any?) {
#if canImport(JavaScriptCore)
        return try withRuntimeLock {
            try Self.withAutoreleasePool {
                rebuildRuntime()
                defer { tearDownRuntime() }
                currentResultContent = result
                _ = variableStore.put(Self.jsResultStoreKey, value: result, scope: .ruleData)
                javaBridge.updateResultContent(result)
                prepareContext()
                context.setObject(result, forKeyedSubscript: "result" as NSString)
                context.exception = nil

                let jsResult = evaluateUserScriptRaw(script)

                if let exception = context.exception {
                    throw ParserError.javascriptError(exception.toString() ?? "未知 JS 错误")
                }

                let detachedPrimary = jsResult.flatMap(detachedObject(from:))
                let detachedResult = context.objectForKeyedSubscript("result").flatMap(detachedObject(from:))
                let detachedURL = context.objectForKeyedSubscript("url").flatMap(detachedObject(from:))
                return (detachedPrimary, detachedResult, detachedURL)
            }
        }
#else
        _ = script
        return (result, result, nil)
#endif
    }

#if canImport(JavaScriptCore)
    private func evaluateDetachedValue(script: String, fallbackString: String = "") throws -> Any? {
        let preparedScript = Self.prepareUserScriptForEvaluation(script)
        let serializationScript = """
        (function() {
            var __LegadoPrimary = \(preparedScript);
            var __LegadoFallback = result;
            var __LegadoResolved = (__LegadoPrimary === undefined || __LegadoPrimary === null)
                ? __LegadoFallback
                : __LegadoPrimary;
            try {
                return JSON.stringify(__LegadoResolved);
            } catch (error) {
                return '';
            }
        })()
        """

        let serializedValue = context.evaluateScript(serializationScript)?.toString() ?? ""
        if let exception = context.exception {
            throw ParserError.javascriptError(exception.toString() ?? "未知 JS 错误")
        }

        if script.contains("var list={'turl':") || script.contains("chapterurl") || script.contains("org.jsoup.Jsoup.parse") {
            ParserLog.debug(
                "JavaScriptParser",
                "evaluateDetachedValue script=\(ParserLog.preview(script, limit: 180)) serialized=\(ParserLog.preview(serializedValue, limit: 220))"
            )
        }

        guard !serializedValue.isEmpty else {
            return fallbackString.isEmpty ? nil : fallbackString
        }
        guard let data = serializedValue.data(using: .utf8) else {
            return serializedValue
        }
        return (try? JSONSerialization.jsonObject(with: data)) ?? serializedValue
    }

    private func detachedJSONObject(from value: JSValue) -> Any? {
        context.setObject(value, forKeyedSubscript: "__LegadoEvaluateValueResult" as NSString)
        defer {
            context.setObject(nil, forKeyedSubscript: "__LegadoEvaluateValueResult" as NSString)
        }

        let serialized = context.evaluateScript(
            """
            (function() {
                try {
                    return JSON.stringify(__LegadoEvaluateValueResult);
                } catch (error) {
                    return '';
                }
            })()
            """
        )?.toString() ?? ""

        guard !serialized.isEmpty,
              let data = serialized.data(using: .utf8) else {
            return nil
        }

        return try? JSONSerialization.jsonObject(with: data)
    }

    private func detachedObject(from value: JSValue) -> Any? {
        if value.isUndefined || value.isNull {
            return nil
        }
        if let object = detachedJSONObject(from: value) {
            return object
        }
        if value.isBoolean {
            return value.toBool()
        }
        if value.isNumber {
            return value.toNumber()
        }
        if let string = value.toString() {
            return string
        }
        return value.toObject()
    }
#endif

    /// 执行 JavaScript 并读取二进制结果。
    ///
    /// - Important: 为了尽量贴近 Android `ImageUtils.decode` 语义，会注入：
    ///   - `result`/`resultBytes`: 原始字节数组（0...255）
    ///   - `resultBase64`: 原始字节 Base64
    ///   - `src`: 当前资源 URL
    /// - Returns: JS 返回值可解析为字节时返回 `Data`，否则返回 `nil`。
    public func evaluateBinary(script: String, resultData: Data, src: String) throws -> Data? {
#if canImport(JavaScriptCore)
        return try withRuntimeLock {
            try Self.withAutoreleasePool {
                rebuildRuntime()
                defer { tearDownRuntime() }
                prepareContext()

                let byteArray = resultData.map { NSNumber(value: UInt8($0)) }
                context.setObject(byteArray, forKeyedSubscript: "result" as NSString)
                context.setObject(byteArray, forKeyedSubscript: "resultBytes" as NSString)
                context.setObject(resultData.base64EncodedString(), forKeyedSubscript: "resultBase64" as NSString)
                context.setObject(src, forKeyedSubscript: "src" as NSString)
                context.exception = nil

                let jsResult = context.evaluateScript(script)
                if let exception = context.exception {
                    throw ParserError.javascriptError(exception.toString() ?? "未知 JS 错误")
                }

                return Self.parseBinaryJSResult(jsResult)
            }
        }
#else
        _ = script
        _ = src
        return nil
#endif
    }

    public func updateContextContent(_ content: String) {
#if canImport(JavaScriptCore)
        withRuntimeLock {
            // 每次规则链切换输入内容时，都要同时清掉上一次 JS `result` 残留。
            // 否则某些书源在 `content -> JS -> 再取 result` 的链路里会误读到上一阶段值，
            // 尤其容易污染 compare 时的搜索/目录/正文连续执行。
            currentContent = content
            currentResultContent = ""
            _ = variableStore.put(Self.jsResultStoreKey, value: "", scope: .ruleData)
            javaBridge?.updateContextContent(content)
            context?.setObject(content, forKeyedSubscript: "content" as NSString)
        }
#endif
    }

    /// Inject a `book` variable into the JS context so JS rules can read detail / toc semantics.
    ///
    /// 这里不是立即执行 JS，而是先把 payload 存在解析器里。原因是大多数调用发生在
    /// JSContext 尚未重建之前；真正执行规则时 `prepareContext()` 会把这份 book payload
    /// 重新安装进 fresh runtime，保证每次 evaluate 都能拿到完整且一致的书籍上下文。
    public func injectBook(
        bookUrl: String,
        name: String = "",
        author: String = "",
        kind: String = "",
        tocUrl: String = "",
        bookVariables: [String: String] = [:]
    ) {
#if canImport(JavaScriptCore)
        var mergedVariables = bookVariables
        mergedVariables["bookUrl"] = bookUrl
        if !name.isEmpty { mergedVariables["name"] = name }
        if !author.isEmpty { mergedVariables["author"] = author }
        if !kind.isEmpty { mergedVariables["kind"] = kind }
        if !tocUrl.isEmpty { mergedVariables["tocUrl"] = tocUrl }

        bookContextPayload = [
            "bookUrl": bookUrl,
            "name": name,
            "author": author,
            "kind": kind,
            "tocUrl": tocUrl,
            "bookVariables": mergedVariables,
            "variables": mergedVariables
        ]

        withRuntimeLock {
            if context != nil {
                installBookContext()
            }
        }
#endif
    }

    // MARK: - 私有方法

#if canImport(JavaScriptCore)
    @discardableResult
    private func withRuntimeLock<T>(_ body: () throws -> T) rethrows -> T {
        runtimeLock.lock()
        defer { runtimeLock.unlock() }
        return try body()
    }

    private static func withAutoreleasePool<T>(_ body: () throws -> T) throws -> T {
        var outcome: Result<T, Error>!
        autoreleasepool {
            outcome = Result(catching: body)
        }
        return try outcome.get()
    }

    static func wrapImmediateInvocation(_ script: String) -> String {
        "(function() {\n\(script)\n})()"
    }

    private func evaluateUserScript(_ script: String) -> JSValue? {
        let preparedScript = Self.prepareUserScriptForEvaluation(script)
        if script.contains("xiaoshuo.uc.cn/#!/ct/cover/bid/")
            || script.contains("var list={'turl':")
            || script.contains("chapterurl")
            || script.contains("comment/getCommentList") {
            ParserLog.debug(
                "JavaScriptParser",
                "prepared script raw=\(ParserLog.preview(script, limit: 200)) prepared=\(ParserLog.preview(preparedScript, limit: 260))"
            )
        }
        let result = context.evaluateScript(preparedScript)
        return result
    }

    private func evaluateLoginCheckScript(_ script: String) -> JSValue? {
        let trimmed = script.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return nil }

        let wrapped = Self.wrapImmediateInvocation(script)
        let wrappedResult = evaluateUserScript(wrapped)
        if let wrappedResult, !wrappedResult.isUndefined, !wrappedResult.isNull {
            return wrappedResult
        }
        if context.exception != nil {
            return wrappedResult
        }
        return evaluateUserScript(script)
    }

    private func evaluateUserScriptRaw(_ script: String) -> JSValue? {
        let preparedScript = Self.prepareDirectScriptForEvaluation(script)
        if script.contains("window.location.href")
            || script.contains("result = kku")
            || script.contains("java.ajax(source.key)") {
            ParserLog.debug(
                "JavaScriptParser",
                "direct script raw=\(ParserLog.preview(script, limit: 200)) prepared=\(ParserLog.preview(preparedScript, limit: 260))"
            )
        }
        return context.evaluateScript(preparedScript)
    }

    private func rebuildRuntime() {
        // compare/规则执行阶段倾向于“一次 evaluate 一个全新 runtime”。
        // 这样虽然比复用上下文略重，但可以最大程度隔离不同书源、不同阶段残留的全局变量、
        // monkey patch、jsoup token 和 response bridge 状态，行为更接近 Android 每次脚本求值的独立性。
        tearDownRuntime()
        context = JSContext()
        javaBridge = JavaBridge(
            baseUrl: baseUrl,
            source: source,
            variableStore: variableStore,
            requestURL: requestURL,
            requestHeaders: requestHeaders
        )
        setupContext()
    }

    private func tearDownRuntime() {
        guard let context else {
            javaBridge = nil
            return
        }

        // 这里故意不再逐个把 JS 全局对象、bridge 函数、辅助对象手动置空。
        // 之前那种“逐项 nil 掉再销毁 context”的做法在 JavaScriptCore 的 ObjC 导出桥上会放大
        // 生命周期顺序问题，批量 compare 下很容易在同一轮销毁里触发重复释放或悬空引用。
        // 直接整体丢弃 JSContext，反而更稳定，也更符合“单次规则执行结束就废弃 runtime”的策略。
        context.exception = nil
        context.exceptionHandler = nil
        javaBridge?.updateContextContent("")
        self.context = nil
        javaBridge = nil
    }

    private static func prepareUserScriptForEvaluation(_ script: String) -> String {
        preprocessModernJavaScriptSyntax(captureTrailingExpressionIfNeeded(in: script))
    }

    private static func prepareDirectScriptForEvaluation(_ script: String) -> String {
        preprocessModernJavaScriptSyntax(script)
    }

    private static func captureTrailingExpressionIfNeeded(in script: String) -> String {
        let trimmedScript = script.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmedScript.isEmpty,
              let trailingSplit = trailingStatementSplit(in: script),
              let candidateExpression = trailingExpressionCandidate(from: trailingSplit.candidate) else {
            return script
        }
        let prefix = trailingSplit.prefix.trimmingCharacters(in: .whitespacesAndNewlines)
        let body = prefix.isEmpty
            ? "var __LegadoTailValue = (\(candidateExpression));"
            : "\(prefix)\nvar __LegadoTailValue = (\(candidateExpression));"
        return """
        (function() {
        \(body)
        return __LegadoTailValue;
        })()
        """
    }

    private static func trailingExpressionCandidate(from line: String) -> String? {
        guard !line.isEmpty else { return nil }

        let candidateSource = trailingStatementCandidate(in: line)
        let candidate = candidateSource.hasSuffix(";") ? String(candidateSource.dropLast()) : candidateSource
        guard !candidate.isEmpty else { return nil }
        guard !candidate.hasSuffix("{"), !candidate.hasSuffix("}") else { return nil }

        let disallowedPrefixes = [
            "if ", "if(",
            "for ", "for(",
            "while ", "while(",
            "switch ", "switch(",
            "try ", "try{",
            "catch ", "catch(",
            "function ", "class ",
            "return ", "throw ",
            "var ", "let ", "const ",
            "break", "continue", "else"
        ]
        guard !disallowedPrefixes.contains(where: { candidate.hasPrefix($0) }) else {
            return nil
        }

        return candidate
    }

    private static func trailingStatementSplit(in script: String) -> (prefix: String, candidate: String)? {
        var quote: Character?
        var escaped = false
        var parenthesisDepth = 0
        var bracketDepth = 0
        var braceDepth = 0
        var segmentStart = script.startIndex
        var lastNonEmptyRange: Range<String.Index>?

        for index in script.indices {
            let character = script[index]

            if let activeQuote = quote {
                if escaped {
                    escaped = false
                } else if character == "\\" {
                    escaped = true
                } else if character == activeQuote {
                    quote = nil
                }
                continue
            }

            switch character {
            case "\"", "'", "`":
                quote = character
            case "(":
                parenthesisDepth += 1
            case ")":
                parenthesisDepth = max(0, parenthesisDepth - 1)
            case "[":
                bracketDepth += 1
            case "]":
                bracketDepth = max(0, bracketDepth - 1)
            case "{":
                braceDepth += 1
            case "}":
                braceDepth = max(0, braceDepth - 1)
            case ";", "\n", "\r":
                if parenthesisDepth == 0, bracketDepth == 0, braceDepth == 0 {
                    let segment = String(script[segmentStart..<index]).trimmingCharacters(in: .whitespacesAndNewlines)
                    if !segment.isEmpty {
                        lastNonEmptyRange = segmentStart..<index
                    }
                    segmentStart = script.index(after: index)
                }
            default:
                break
            }
        }

        let tailSegment = String(script[segmentStart...]).trimmingCharacters(in: .whitespacesAndNewlines)
        if !tailSegment.isEmpty {
            lastNonEmptyRange = segmentStart..<script.endIndex
        }

        guard let candidateRange = lastNonEmptyRange else { return nil }
        let candidate = String(script[candidateRange]).trimmingCharacters(in: .whitespacesAndNewlines)
        guard !candidate.isEmpty else { return nil }

        let prefix = String(script[..<candidateRange.lowerBound])
        return (prefix, candidate)
    }

    private static func trailingStatementCandidate(in line: String) -> String {
        trailingStatementSplit(in: line)?.candidate ?? line.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    private static func preprocessModernJavaScriptSyntax(_ script: String) -> String {
        var transformed = script
        for _ in 0..<8 {
            let optionalRewritten = rewriteOptionalChains(in: transformed)
            let nullishRewritten = rewriteNullishCoalescing(in: optionalRewritten)
            if nullishRewritten == transformed {
                return nullishRewritten
            }
            transformed = nullishRewritten
        }
        return transformed
    }

    private static func rewriteOptionalChains(in script: String) -> String {
        var transformed = script
        transformed = rewriteOptionalIndexChains(in: transformed)
        transformed = rewriteOptionalPropertyChains(in: transformed)
        return transformed
    }

    private static func rewriteOptionalIndexChains(in script: String) -> String {
        var text = script
        while let tokenRange = text.range(of: "?.["),
              let lhsRange = expressionRangeEnding(before: tokenRange.lowerBound, in: text),
              let openingBracket = text.index(tokenRange.lowerBound, offsetBy: 2, limitedBy: text.index(before: text.endIndex)),
              let closingBracket = matchingBracket(in: text, openingBracket: openingBracket) {
            let indexStart = text.index(after: openingBracket)
            let lhs = text[lhsRange].trimmingCharacters(in: .whitespacesAndNewlines)
            let indexExpression = text[indexStart..<closingBracket].trimmingCharacters(in: .whitespacesAndNewlines)
            guard !lhs.isEmpty else { break }
            let replacement = "__LegadoOptionalIndex((\(lhs)), (\(indexExpression)))"
            text.replaceSubrange(lhsRange.lowerBound...closingBracket, with: replacement)
        }
        return text
    }

    private static func rewriteOptionalPropertyChains(in script: String) -> String {
        var text = script
        while let tokenRange = text.range(of: "?."),
              tokenRange.upperBound < text.endIndex,
              text[tokenRange.upperBound] != "[",
              let lhsRange = expressionRangeEnding(before: tokenRange.lowerBound, in: text),
              let propertyRange = propertyNameRange(startingAt: tokenRange.upperBound, in: text) {
            let lhs = text[lhsRange].trimmingCharacters(in: .whitespacesAndNewlines)
            let propertyName = String(text[propertyRange])
            guard !lhs.isEmpty, !propertyName.isEmpty else { break }
            let replacement = "__LegadoOptionalProp((\(lhs)), \"\(propertyName)\")"
            text.replaceSubrange(lhsRange.lowerBound..<propertyRange.upperBound, with: replacement)
        }
        return text
    }

    private static func rewriteNullishCoalescing(in script: String) -> String {
        var text = script
        while let operatorRange = topLevelOperatorRange("??", in: text),
              let lhsRange = expressionRangeEnding(before: operatorRange.lowerBound, in: text),
              let rhsRange = expressionRangeStarting(after: operatorRange.upperBound, in: text) {
            let lhs = text[lhsRange].trimmingCharacters(in: .whitespacesAndNewlines)
            let rhs = text[rhsRange].trimmingCharacters(in: .whitespacesAndNewlines)
            guard !lhs.isEmpty, !rhs.isEmpty else { break }
            let replacement = "__LegadoNullish((\(lhs)), (\(rhs)))"
            text.replaceSubrange(lhsRange.lowerBound..<rhsRange.upperBound, with: replacement)
        }
        return text
    }

    private static func topLevelOperatorRange(_ token: String, in text: String) -> Range<String.Index>? {
        var index = text.startIndex
        var quote: Character?
        var escaped = false
        var parenthesisDepth = 0
        var bracketDepth = 0
        var braceDepth = 0

        while index < text.endIndex {
            let character = text[index]
            if let activeQuote = quote {
                if escaped {
                    escaped = false
                } else if character == "\\" {
                    escaped = true
                } else if character == activeQuote {
                    quote = nil
                }
                index = text.index(after: index)
                continue
            }

            switch character {
            case "\"", "'", "`":
                quote = character
            case "(":
                parenthesisDepth += 1
            case ")":
                parenthesisDepth = max(0, parenthesisDepth - 1)
            case "[":
                bracketDepth += 1
            case "]":
                bracketDepth = max(0, bracketDepth - 1)
            case "{":
                braceDepth += 1
            case "}":
                braceDepth = max(0, braceDepth - 1)
            default:
                break
            }

            if parenthesisDepth == 0,
               bracketDepth == 0,
               braceDepth == 0,
               text[index...].hasPrefix(token) {
                return index..<text.index(index, offsetBy: token.count)
            }
            index = text.index(after: index)
        }
        return nil
    }

    private static func expressionRangeEnding(before boundary: String.Index, in text: String) -> Range<String.Index>? {
        var end = boundary
        while end > text.startIndex {
            let previous = text.index(before: end)
            if !text[previous].isWhitespace {
                break
            }
            end = previous
        }
        guard end > text.startIndex else { return nil }

        var start = end
        var quote: Character?
        var escaped = false
        var parenthesisDepth = 0
        var bracketDepth = 0
        var braceDepth = 0

        while start > text.startIndex {
            let previous = text.index(before: start)
            let character = text[previous]

            if let activeQuote = quote {
                if escaped {
                    escaped = false
                } else if character == "\\" {
                    escaped = true
                } else if character == activeQuote {
                    quote = nil
                }
                start = previous
                continue
            }

            switch character {
            case "\"", "'", "`":
                quote = character
            case ")":
                parenthesisDepth += 1
            case "(":
                if parenthesisDepth > 0 {
                    parenthesisDepth -= 1
                } else {
                    return text.index(after: previous)..<end
                }
            case "]":
                bracketDepth += 1
            case "[":
                if bracketDepth > 0 {
                    bracketDepth -= 1
                }
            case "}":
                braceDepth += 1
            case "{":
                if braceDepth > 0 {
                    braceDepth -= 1
                }
            default:
                if parenthesisDepth == 0, bracketDepth == 0, braceDepth == 0,
                   isExpressionBoundary(character) {
                    return start..<end
                }
            }
            start = previous
        }

        return start..<end
    }

    private static func expressionRangeStarting(after boundary: String.Index, in text: String) -> Range<String.Index>? {
        var start = boundary
        while start < text.endIndex, text[start].isWhitespace {
            start = text.index(after: start)
        }
        guard start < text.endIndex else { return nil }

        var end = start
        var quote: Character?
        var escaped = false
        var parenthesisDepth = 0
        var bracketDepth = 0
        var braceDepth = 0

        while end < text.endIndex {
            let character = text[end]

            if let activeQuote = quote {
                if escaped {
                    escaped = false
                } else if character == "\\" {
                    escaped = true
                } else if character == activeQuote {
                    quote = nil
                }
                end = text.index(after: end)
                continue
            }

            switch character {
            case "\"", "'", "`":
                quote = character
            case "(":
                parenthesisDepth += 1
            case ")":
                if parenthesisDepth == 0, bracketDepth == 0, braceDepth == 0 {
                    return start..<end
                }
                parenthesisDepth = max(0, parenthesisDepth - 1)
            case "[":
                bracketDepth += 1
            case "]":
                bracketDepth = max(0, bracketDepth - 1)
            case "{":
                braceDepth += 1
            case "}":
                braceDepth = max(0, braceDepth - 1)
            case ";", ",":
                if parenthesisDepth == 0, bracketDepth == 0, braceDepth == 0 {
                    return start..<end
                }
            default:
                if parenthesisDepth == 0, bracketDepth == 0, braceDepth == 0,
                   character.isNewline {
                    return start..<end
                }
            }
            end = text.index(after: end)
        }

        return start..<end
    }

    private static func matchingBracket(in text: String, openingBracket: String.Index) -> String.Index? {
        guard openingBracket < text.endIndex, text[openingBracket] == "[" else { return nil }
        var index = text.index(after: openingBracket)
        var depth = 1
        var quote: Character?
        var escaped = false

        while index < text.endIndex {
            let character = text[index]
            if let activeQuote = quote {
                if escaped {
                    escaped = false
                } else if character == "\\" {
                    escaped = true
                } else if character == activeQuote {
                    quote = nil
                }
                index = text.index(after: index)
                continue
            }

            switch character {
            case "\"", "'", "`":
                quote = character
            case "[":
                depth += 1
            case "]":
                depth -= 1
                if depth == 0 {
                    return index
                }
            default:
                break
            }
            index = text.index(after: index)
        }
        return nil
    }

    private static func propertyNameRange(startingAt start: String.Index, in text: String) -> Range<String.Index>? {
        guard start < text.endIndex else { return nil }
        let first = text[start]
        guard first.isLetter || first == "_" || first == "$" else { return nil }
        var end = text.index(after: start)
        while end < text.endIndex {
            let character = text[end]
            guard character.isLetter || character.isNumber || character == "_" || character == "$" else {
                break
            }
            end = text.index(after: end)
        }
        return start..<end
    }

    private static func isExpressionBoundary(_ character: Character) -> Bool {
        character.isWhitespace ||
            ["=", ",", ":", ";", "?", "+", "-", "*", "/", "%", "&", "|", "^", "!", "<", ">", "\n", "\r"].contains(character)
    }

    private func resolvedStringResult(
        primary: JSValue?,
        fallback: JSValue?,
        fallbackString: String = ""
    ) -> String {
        if let primaryValue = resolvedValueResult(primary: primary, fallback: fallback),
           let stringValue = normalizedString(from: primaryValue) {
            return stringValue
        }
        return fallbackString
    }

    private func resolvedValueResult(primary: JSValue?, fallback: JSValue?) -> JSValue? {
        if let primary, !primary.isUndefined, !primary.isNull {
            return primary
        }
        if let fallback, !fallback.isUndefined, !fallback.isNull {
            return fallback
        }
        return nil
    }

    private func normalizedString(from value: JSValue) -> String? {
        if value.isObject,
           let detachedObject = detachedJSONObject(from: value),
           JSONSerialization.isValidJSONObject(detachedObject),
           let data = try? JSONSerialization.data(withJSONObject: detachedObject, options: [.sortedKeys]),
           let json = String(data: data, encoding: .utf8),
           !json.isEmpty {
            return json
        }
        let stringValue = value.toString() ?? ""
        if stringValue == "undefined" || stringValue == "null" {
            return nil
        }
        return stringValue
    }

    private func setupContext() {
        prepareContext()
        installBridgeCompatibilityShims()

        // 注入基础工具函数
        let consoleLog: @convention(block) (String) -> Void = { message in
            ParserLog.debug("JavaScript", message)
        }
        context.setObject(consoleLog, forKeyedSubscript: "log" as NSString)

        // 保留系统原生 JSON；只有缺失时才注入兼容实现，避免破坏 JSON.stringify 行为。
        context.evaluateScript("""
            if (typeof JSON === 'undefined') {
                var JSON = {
                    parse: function(str) { return eval('(' + str + ')'); },
                    stringify: function(obj) {
                        if (typeof obj === 'string') return obj;
                        return String(obj);
                    }
                };
            }
        """)
        context.evaluateScript("""
            function __LegadoOptionalIndex(base, index) {
                return base == null ? undefined : base[index];
            }
            function __LegadoOptionalProp(base, key) {
                return base == null ? undefined : base[key];
            }
            function __LegadoNullish(value, fallback) {
                return value === null || value === undefined ? fallback : value;
            }
        """)

        // 注入 jsLib（书源共享 JS 库）
        if let jsLib = source?.jsLib, !jsLib.isEmpty {
            installSharedJSLibrary(jsLib)
        }

        // 错误处理
        context.exceptionHandler = { [weak self] _, exception in
            _ = self
            if let message = exception?.toString(), !message.isEmpty {
                ParserLog.debug("JavaScriptParser", "exception=\(message)")
            }
        }
    }

    /// Android accepts a `jsLib` object whose values are remote script URLs. Its bridge caches
    /// those scripts before evaluating them; direct JavaScript text remains supported as-is.
    private func installSharedJSLibrary(_ jsLib: String) {
        let trimmed = jsLib.trimmingCharacters(in: .whitespacesAndNewlines)
        guard let data = trimmed.data(using: .utf8),
              let libraries = try? JSONSerialization.jsonObject(with: data) as? [String: String] else {
            _ = evaluateUserScript(jsLib)
            return
        }

        for url in libraries.values {
            guard let scheme = URL(string: url)?.scheme?.lowercased(),
                  scheme == "http" || scheme == "https" else { continue }
            let script = javaBridge.importScript(url)
            if script.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                ParserLog.debug("JavaScriptParser", "jsLib download failed: \(url)")
                continue
            }
            _ = evaluateUserScript(script)
        }
    }

    private func prepareContext() {
        // 每次 evaluate 前都重新把当前运行时需要的几个核心对象灌回 JS：
        // 1. baseUrl/url/content/src：对齐 legado 规则中最常读取的全局变量
        // 2. java bridge：承接 connect/ajax/jsoup/cookie/@put 等 Android 兼容能力
        // 3. source/book/cookie：提供跨阶段可读取的语义对象，避免只在某个入口临时存在
        javaBridge.updateContextContent(currentContent)
        context.setObject(baseUrl, forKeyedSubscript: "baseUrl" as NSString)
        context.setObject(requestURL, forKeyedSubscript: "url" as NSString)
        context.setObject(currentContent, forKeyedSubscript: "content" as NSString)
        context.setObject(currentContent, forKeyedSubscript: "src" as NSString)
        context.setObject(javaBridge, forKeyedSubscript: "java" as NSString)

        let sourceUrl = source?.bookSourceUrl ?? ""
        let sourceName = source?.bookSourceName ?? ""
        // Inject source object with getKey() method (legado compat)
        context.evaluateScript("""
            var source = {
                key: '\(sourceUrl.replacingOccurrences(of: "'", with: "\\'"))',
                bookSourceUrl: '\(sourceUrl.replacingOccurrences(of: "'", with: "\\'"))',
                bookSourceName: '\(sourceName.replacingOccurrences(of: "'", with: "\\'"))',
                getKey: function() { return this.bookSourceUrl; },
                getVariable: function(key) {
                    if (!key) {
                        return java.getSourceVariable();
                    }
                    var value = (sourceVariables || {})[key];
                    return value === undefined || value === null ? '' : String(value);
                },
                setVariable: function(value) {
                    var normalized = value === null || value === undefined ? '' : String(value);
                    var saved = java.setSourceVariable(normalized);
                    sourceVariables = {};
                    if (normalized) {
                        try {
                            var parsed = JSON.parse(normalized);
                            if (parsed && typeof parsed === 'object' && !Array.isArray(parsed)) {
                                sourceVariables = parsed;
                            }
                        } catch (e) {}
                    }
                    return saved;
                },
                getLoginHeader: function() {
                    return java.getLoginHeader();
                },
                getLoginHeaderMap: function() {
                    var raw = this.getLoginHeader();
                    if (!raw) return {};
                    try {
                        var parsed = JSON.parse(String(raw));
                        return parsed && typeof parsed === 'object' ? parsed : {};
                    } catch (e) {
                        return {};
                    }
                },
                bookSourceComment: '\((source?.bookSourceComment ?? "").replacingOccurrences(of: "'", with: "\\'").replacingOccurrences(of: "\n", with: "\\n"))'
            };
        """)

        // Inject cookie object (legado compat: cookie.getCookie / cookie.setCookie / cookie.removeCookie)
        context.evaluateScript("""
            var cookie = {
                getCookie: function(domain) { return java.getCookie(domain); },
                getKey: function(domain, key) {
                    return java.getCookie(domain, key);
                },
                setCookie: function(domain, cookieString) {
                    return java.setCookie(domain, cookieString);
                },
                replaceCookie: function(domain, cookieString) {
                    return java.replaceCookie(domain, cookieString);
                },
                removeCookie: function(domain) {
                    return java.removeCookie(domain);
                }
            };
        """)

        // Inject base_url alias
        context.evaluateScript("var base_url = '\(sourceUrl.replacingOccurrences(of: "'", with: "\\'"))';")

        let headersJSON = toJSONStringDictionary(requestHeaders)
        context.evaluateScript("var headerMap = \(headersJSON);")
        context.evaluateScript("var headers = headerMap;")

        let variablesJSON = toJSONStringDictionary(
            variableStore.snapshot(for: .source, includeInherited: false)
        )
        context.evaluateScript("var sourceVariables = \(variablesJSON);")
        context.evaluateScript("var bookVariables = \(toJSONStringDictionary(variableStore.snapshot(for: .book, includeInherited: true)));")
        context.evaluateScript("""
            var infoMap = typeof infoMap === 'object' && infoMap ? infoMap : {};
            var __LegadoInitialInfoMap = \(toJSONStringDictionary(initialInfoMap));
            Object.keys(__LegadoInitialInfoMap).forEach(function(key) {
                infoMap[key] = __LegadoInitialInfoMap[key];
            });
            if (typeof infoMap.save !== 'function') {
                infoMap.save = function() { return true; };
            }
        """)
        installBookContext()
    }

    private func installBookContext() {
        let currentBookVariables = variableStore.snapshot(for: .book, includeInherited: true)
        var payload = (bookContextPayload["bookUrl"] as? String)?.isEmpty == false
            ? bookContextPayload
            : [
                "bookUrl": currentBookVariables["bookUrl"] ?? "",
                "name": currentBookVariables["name"] ?? "",
                "author": currentBookVariables["author"] ?? "",
                "kind": currentBookVariables["kind"] ?? "",
                "tocUrl": currentBookVariables["tocUrl"] ?? ""
            ]
        var mergedBookVariables = currentBookVariables
        if let payloadVariables = payload["bookVariables"] as? [String: String] {
            mergedBookVariables.merge(payloadVariables) { current, new in
                current.isEmpty ? new : current
            }
        }
        if let payloadVariables = payload["variables"] as? [String: String] {
            mergedBookVariables.merge(payloadVariables) { current, new in
                current.isEmpty ? new : current
            }
        }
        if let bookUrl = payload["bookUrl"] as? String, !bookUrl.isEmpty {
            mergedBookVariables["bookUrl"] = bookUrl
        }
        if let name = payload["name"] as? String, !name.isEmpty {
            mergedBookVariables["name"] = name
        }
        if let author = payload["author"] as? String, !author.isEmpty {
            mergedBookVariables["author"] = author
        }
        if let kind = payload["kind"] as? String, !kind.isEmpty {
            mergedBookVariables["kind"] = kind
        }
        if let tocUrl = payload["tocUrl"] as? String, !tocUrl.isEmpty {
            mergedBookVariables["tocUrl"] = tocUrl
        }

        payload["bookVariables"] = mergedBookVariables
        payload["variables"] = mergedBookVariables
        let payloadJSON = toJSONStringValue(payload)
        context.evaluateScript(
            """
            var __LegadoBookPayload = \(payloadJSON);
            var __LegadoBookVars = __LegadoBookPayload.bookVariables || __LegadoBookPayload.variables || {};
            var book = Object.assign({}, __LegadoBookVars, __LegadoBookPayload);
            book.bookVariables = __LegadoBookVars;
            book.variables = __LegadoBookPayload.variables || __LegadoBookVars;
            book.getKey = function() { return this.bookUrl || ''; };
            book.getVariable = function(key) {
                if (!key) return '';
                var vars = this.variables || {};
                var value = vars[key];
                if (value === undefined || value === null || value === 'undefined' || value === 'null') {
                    value = this[key];
                }
                return value === undefined || value === null ? '' : String(value);
            };
            """
        )
    }

    private func installBridgeCompatibilityShims() {
        guard let javaBridge else { return }
        let getCookie1: @convention(block) (String) -> String = { [javaBridge] tag in
            javaBridge.getCookie(tag)
        }
        let getCookie2: @convention(block) (String, String) -> String = { [javaBridge] tag, key in
            javaBridge.getCookie(tag, key)
        }
        let setCookie2: @convention(block) (String, String) -> String = { [javaBridge] tag, cookieString in
            javaBridge.setCookie(tag, cookieString)
        }
        let replaceCookie2: @convention(block) (String, String) -> String = { [javaBridge] tag, cookieString in
            javaBridge.replaceCookie(tag, cookieString)
        }
        let removeCookie1: @convention(block) (String) -> String = { [javaBridge] tag in
            javaBridge.removeCookie(tag)
        }
        let get1: @convention(block) (String) -> String = { [javaBridge] key in
            javaBridge.get(key)
        }
        let get2: @convention(block) (String, JSValue?) -> JSValue? = { [javaBridge] url, headerValue in
            javaBridge.get(url, headerValue)
        }
        let connect1: @convention(block) (String) -> JSValue? = { [javaBridge] url in
            javaBridge.connect(url)
        }
        let connect2: @convention(block) (String, JSValue?) -> JSValue? = { [javaBridge] url, headerValue in
            javaBridge.connect(url, headerValue)
        }
        let getString1: @convention(block) (String) -> String = { [javaBridge] rule in
            javaBridge.getString(rule)
        }
        let getSourceVariable0: @convention(block) () -> String = { [javaBridge] in
            javaBridge.getSourceVariable()
        }
        let setSourceVariable1: @convention(block) (String) -> String = { [javaBridge] value in
            javaBridge.setSourceVariable(value)
        }
        let refreshExplore0: @convention(block) () -> String = {
            ""
        }
        let androidId0: @convention(block) () -> String = { [javaBridge] in
            javaBridge.androidId()
        }
        let getLoginHeader0: @convention(block) () -> String = { [javaBridge] in
            javaBridge.getLoginHeader()
        }
        let ajax1: @convention(block) (String) -> String = { [javaBridge] url in
            javaBridge.ajax(url)
        }
        let ajaxAll1: @convention(block) (NSArray) -> String = { [javaBridge] values in
            let urls = values.compactMap { item -> String? in
                if let string = item as? String {
                    return string
                }
                if let number = item as? NSNumber {
                    return number.stringValue
                }
                return nil
            }
            return javaBridge.ajaxAll(urls)
        }
        let setContent1: @convention(block) (String) -> String = { [javaBridge] content in
            javaBridge.setContent(content)
            return content
        }
        let getElement1: @convention(block) (String) -> String = { [javaBridge] rule in
            javaBridge.getElement(rule)
        }
        let getElements1: @convention(block) (String) -> String = { [javaBridge] rule in
            javaBridge.getElements(rule)
        }
        let log1: @convention(block) (String) -> String = { [javaBridge] message in
            javaBridge.log(message)
            return message
        }
        let toast1: @convention(block) (String) -> String = { [javaBridge] message in
            javaBridge.toast(message)
            return message
        }
        let longToast1: @convention(block) (String) -> String = { [javaBridge] message in
            javaBridge.longToast(message)
            return message
        }
        let md5Encode1: @convention(block) (String) -> String = { [javaBridge] value in
            javaBridge.md5Encode(value)
        }
        let md5Encode161: @convention(block) (String) -> String = { [javaBridge] value in
            javaBridge.md5Encode16(value)
        }
        let sha11: @convention(block) (String) -> String = { [javaBridge] value in
            javaBridge.sha1(value)
        }
        let sha2561: @convention(block) (String) -> String = { [javaBridge] value in
            javaBridge.sha256(value)
        }
        let base64Encode1: @convention(block) (String) -> String = { [javaBridge] value in
            javaBridge.base64Encode(value)
        }
        let base64Encode2: @convention(block) (String, Int) -> String = { [javaBridge] value, flags in
            javaBridge.base64Encode(value, flags)
        }
        let urlEncode1: @convention(block) (String) -> String = { [javaBridge] value in
            javaBridge.urlEncode(value)
        }
        let urlDecode1: @convention(block) (String) -> String = { [javaBridge] value in
            javaBridge.urlDecode(value)
        }
        let encodeURI1: @convention(block) (String) -> String = { [javaBridge] value in
            javaBridge.encodeURI(value)
        }
        let encodeURI2: @convention(block) (String, String) -> String = { [javaBridge] value, enc in
            javaBridge.encodeURI(value, enc)
        }
        let timeFormat1: @convention(block) (Double) -> String = { [javaBridge] timestamp in
            javaBridge.timeFormat(timestamp)
        }
        let timeFormatUTC3: @convention(block) (Double, String, Int) -> String = { [javaBridge] time, format, sh in
            javaBridge.timeFormatUTC(time, format, sh)
        }
        let timeStamp1: @convention(block) (Bool) -> String = { [javaBridge] ms in
            javaBridge.timeStamp(ms)
        }
        let base64Decode1: @convention(block) (String) -> String = { [javaBridge] value in
            javaBridge.base64Decode(value)
        }
        let base64Decode2: @convention(block) (String, String) -> String = { [javaBridge] value, charset in
            javaBridge.base64Decode(value, charset)
        }
        let base64DecodeWithFlags2: @convention(block) (String, Int) -> String = { [javaBridge] value, flags in
            javaBridge.base64DecodeWithFlags(value, flags)
        }
        let base64DecodeToByteArray1: @convention(block) (String) -> NSArray = { [javaBridge] value in
            javaBridge.base64DecodeToByteArray(value)
        }
        let base64DecodeToByteArray2: @convention(block) (String, Int) -> NSArray = { [javaBridge] value, flags in
            javaBridge.base64DecodeToByteArray(value, flags)
        }
        let hexDecodeToByteArray1: @convention(block) (String) -> NSArray = { [javaBridge] value in
            javaBridge.hexDecodeToByteArray(value)
        }
        let createSymmetricCrypto3: @convention(block) (String, String, String) -> JSValue? = { [javaBridge] transformation, key, iv in
            javaBridge.createSymmetricCrypto(transformation, key, iv)
        }
        let desDecodeToString4: @convention(block) (String, String, String, String) -> String = { [javaBridge] data, key, transformation, iv in
            javaBridge.desDecodeToString(data, key, transformation, iv)
        }
        let desBase64DecodeToString4: @convention(block) (String, String, String, String) -> String = { [javaBridge] data, key, transformation, iv in
            javaBridge.desBase64DecodeToString(data, key, transformation, iv)
        }
        let desEncodeToString4: @convention(block) (String, String, String, String) -> String = { [javaBridge] data, key, transformation, iv in
            javaBridge.desEncodeToString(data, key, transformation, iv)
        }
        let desEncodeToBase64String4: @convention(block) (String, String, String, String) -> String = { [javaBridge] data, key, transformation, iv in
            javaBridge.desEncodeToBase64String(data, key, transformation, iv)
        }
        let createAsymmetricCrypto1: @convention(block) (String) -> JSValue? = { [javaBridge] transformation in
            javaBridge.createAsymmetricCrypto(transformation)
        }
        let strToBytes1: @convention(block) (String) -> NSArray = { [javaBridge] value in
            javaBridge.strToBytes(value)
        }
        let strToBytes2: @convention(block) (String, String) -> NSArray = { [javaBridge] value, charset in
            javaBridge.strToBytes(value, charset)
        }
        let bytesToStr1: @convention(block) (NSArray) -> String = { [javaBridge] values in
            javaBridge.bytesToStr(values)
        }
        let bytesToStr2: @convention(block) (NSArray, String) -> String = { [javaBridge] values, charset in
            javaBridge.bytesToStr(values, charset)
        }
        let toURL1: @convention(block) (String) -> NSDictionary = { [javaBridge] value in
            javaBridge.toURL(value)
        }
        let toURL2: @convention(block) (String, String) -> NSDictionary = { [javaBridge] value, baseURL in
            javaBridge.toURL(value, baseURL)
        }
        let getRequestURL0: @convention(block) () -> String = { [javaBridge] in
            javaBridge.getRequestURL()
        }
        let getRequestHeaders0: @convention(block) () -> String = { [javaBridge] in
            javaBridge.getRequestHeaders()
        }
        let jsoupParse2: @convention(block) (String, String) -> String = { [javaBridge] html, baseURL in
            javaBridge.jsoupParse(html, baseURL)
        }
        let jsoupSelect2: @convention(block) (String, String) -> String = { [javaBridge] token, selector in
            javaBridge.jsoupSelect(token, selector)
        }
        let jsoupSelectFirst2: @convention(block) (String, String) -> String = { [javaBridge] token, selector in
            javaBridge.jsoupSelectFirst(token, selector)
        }
        let jsoupText1: @convention(block) (String) -> String = { [javaBridge] token in
            javaBridge.jsoupText(token)
        }
        let jsoupHTML1: @convention(block) (String) -> String = { [javaBridge] token in
            javaBridge.jsoupHTML(token)
        }
        let jsoupOuterHTML1: @convention(block) (String) -> String = { [javaBridge] token in
            javaBridge.jsoupOuterHTML(token)
        }
        let jsoupAttr2: @convention(block) (String, String) -> String = { [javaBridge] token, name in
            javaBridge.jsoupAttr(token, name)
        }
        let jsoupHasClass2: @convention(block) (String, String) -> Bool = { [javaBridge] token, name in
            javaBridge.jsoupHasClass(token, name)
        }
        let jsoupData1: @convention(block) (String) -> String = { [javaBridge] token in
            javaBridge.jsoupData(token)
        }
        let jsoupRemove1: @convention(block) (String) -> Bool = { [javaBridge] token in
            javaBridge.jsoupRemove(token)
        }
        let post2: @convention(block) (String, String) -> JSValue? = { [javaBridge] url, body in
            javaBridge.post(url, body, nil)
        }
        let post3: @convention(block) (String, String, JSValue?) -> JSValue? = { [javaBridge] url, body, headerValue in
            javaBridge.post(url, body, headerValue)
        }
        let head2: @convention(block) (String, JSValue?) -> JSValue? = { [javaBridge] url, headerValue in
            javaBridge.head(url, headerValue)
        }
        let webView3: @convention(block) (String, String, String) -> String = { [javaBridge] html, url, js in
            javaBridge.webView(html, url, js)
        }
        let webViewGetSource4: @convention(block) (String, String, String, String) -> String = { [javaBridge] html, url, js, sourceRegex in
            javaBridge.webViewGetSource(html, url, js, sourceRegex)
        }
        let webViewGetOverrideUrl4: @convention(block) (String, String, String, String) -> String = { [javaBridge] html, url, js, overrideUrlRegex in
            javaBridge.webViewGetOverrideUrl(html, url, js, overrideUrlRegex)
        }
        let startBrowser2: @convention(block) (String, String) -> String = { [javaBridge] url, title in
            javaBridge.startBrowser(url, title)
            return ""
        }
        let getVerificationCode1: @convention(block) (String) -> String = { [javaBridge] imageUrl in
            javaBridge.getVerificationCode(imageUrl)
        }
        let getWebViewUA0: @convention(block) () -> String = { [javaBridge] in
            javaBridge.getWebViewUA()
        }
        let logType1: @convention(block) (JSValue?) -> String = { [javaBridge] value in
            javaBridge.logType(value?.toObject() ?? value?.toString() ?? "")
        }
        let openUrl1: @convention(block) (String) -> String = { [javaBridge] url in
            javaBridge.openUrl(url)
        }
        let openUrl2: @convention(block) (String, String) -> String = { [javaBridge] url, mimeType in
            javaBridge.openUrl(url, mimeType)
        }
        let getFile1: @convention(block) (String) -> String = { [javaBridge] path in
            javaBridge.getFile(path)
        }
        let queryTTF1: @convention(block) (String) -> String = { [javaBridge] data in
            javaBridge.queryTTF(data)
        }
        let queryTTF2: @convention(block) (String, Bool) -> String = { [javaBridge] data, useCache in
            javaBridge.queryTTF(data, useCache)
        }
        let queryBase64TTF1: @convention(block) (String) -> String = { [javaBridge] data in
            javaBridge.queryBase64TTF(data)
        }
        let replaceFont3: @convention(block) (String, String, String) -> String = { [javaBridge] text, errorTTF, correctTTF in
            javaBridge.replaceFont(text, errorTTF, correctTTF)
        }
        let replaceFont4: @convention(block) (String, String, String, Bool) -> String = { [javaBridge] text, errorTTF, correctTTF, filter in
            javaBridge.replaceFont(text, errorTTF, correctTTF, filter)
        }
        let cacheFile1: @convention(block) (String) -> String = { [javaBridge] urlStr in
            javaBridge.cacheFile(urlStr)
        }
        let cacheFile2: @convention(block) (String, Int) -> String = { [javaBridge] urlStr, saveTime in
            javaBridge.cacheFile(urlStr, saveTime)
        }
        let downloadFile1: @convention(block) (String) -> String = { [javaBridge] url in
            javaBridge.downloadFile(url)
        }
        let downloadFile2: @convention(block) (String, String) -> String = { [javaBridge] content, url in
            javaBridge.downloadFile(content, url)
        }
        let importScript1: @convention(block) (String) -> String = { [javaBridge] path in
            javaBridge.importScript(path)
        }
        let readTxtFile1: @convention(block) (String) -> String = { [javaBridge] path in
            javaBridge.readTxtFile(path)
        }
        let readTxtFile2: @convention(block) (String, String) -> String = { [javaBridge] path, charsetName in
            javaBridge.readTxtFile(path, charsetName)
        }
        let readFile1: @convention(block) (String) -> NSArray = { [javaBridge] path in
            javaBridge.readFile(path)
        }
        let deleteFile1: @convention(block) (String) -> Bool = { [javaBridge] path in
            javaBridge.deleteFile(path)
        }
        let getTxtInFolder1: @convention(block) (String) -> String = { [javaBridge] path in
            javaBridge.getTxtInFolder(path)
        }
        let unzipFile1: @convention(block) (String) -> String = { [javaBridge] path in
            javaBridge.unzipFile(path)
        }
        let un7zFile1: @convention(block) (String) -> String = { [javaBridge] path in
            javaBridge.un7zFile(path)
        }
        let unrarFile1: @convention(block) (String) -> String = { [javaBridge] path in
            javaBridge.unrarFile(path)
        }
        let unArchiveFile1: @convention(block) (String) -> String = { [javaBridge] path in
            javaBridge.unArchiveFile(path)
        }
        let getZipByteArrayContent2: @convention(block) (String, String) -> NSArray = { [javaBridge] url, path in
            javaBridge.getZipByteArrayContent(url, path)
        }
        let getRarByteArrayContent2: @convention(block) (String, String) -> NSArray = { [javaBridge] url, path in
            javaBridge.getRarByteArrayContent(url, path)
        }
        let getRarStringContent2: @convention(block) (String, String) -> String = { [javaBridge] url, path in
            javaBridge.getRarStringContent(url, path)
        }
        let getRarStringContent3: @convention(block) (String, String, String) -> String = { [javaBridge] url, path, charsetName in
            javaBridge.getRarStringContent(url, path, charsetName)
        }
        let get7zByteArrayContent2: @convention(block) (String, String) -> NSArray = { [javaBridge] url, path in
            javaBridge.get7zByteArrayContent(url, path)
        }
        let get7zStringContent2: @convention(block) (String, String) -> String = { [javaBridge] url, path in
            javaBridge.get7zStringContent(url, path)
        }
        let get7zStringContent3: @convention(block) (String, String, String) -> String = { [javaBridge] url, path, charsetName in
            javaBridge.get7zStringContent(url, path, charsetName)
        }
        let getZipStringContent2: @convention(block) (String, String) -> String = { [javaBridge] url, path in
            javaBridge.getZipStringContent(url, path)
        }
        let getZipStringContent3: @convention(block) (String, String, String) -> String = { [javaBridge] url, path, charsetName in
            javaBridge.getZipStringContent(url, path, charsetName)
        }
        let createSign1: @convention(block) (String) -> JSValue? = { [javaBridge] algorithm in
            javaBridge.createSign(algorithm)
        }
        let hMacHex2: @convention(block) (String, String) -> String = { [javaBridge] data, key in
            javaBridge.HMacHex(data, key)
        }
        let hMacHex3: @convention(block) (String, String, String) -> String = { [javaBridge] data, algorithm, key in
            javaBridge.HMacHex(data, algorithm, key)
        }
        let hMacBase643: @convention(block) (String, String, String) -> String = { [javaBridge] data, algorithm, key in
            javaBridge.HMacBase64(data, algorithm, key)
        }
        let digestHex2: @convention(block) (String, String) -> String = { [javaBridge] data, algorithm in
            javaBridge.digestHex(data, algorithm)
        }
        let digestBase64Str2: @convention(block) (String, String) -> String = { [javaBridge] data, algorithm in
            javaBridge.digestBase64Str(data, algorithm)
        }
        let hexEncodeToString1: @convention(block) (String) -> String = { [javaBridge] value in
            javaBridge.hexEncodeToString(value)
        }
        let hexDecodeToString1: @convention(block) (String) -> String = { [javaBridge] value in
            javaBridge.hexDecodeToString(value)
        }
        let htmlFormat1: @convention(block) (String) -> String = { [javaBridge] value in
            javaBridge.htmlFormat(value)
        }
        let randomUUID0: @convention(block) () -> String = { [javaBridge] in
            javaBridge.randomUUID()
        }
        let t2s1: @convention(block) (String) -> String = { [javaBridge] value in
            javaBridge.t2s(value)
        }
        let s2t1: @convention(block) (String) -> String = { [javaBridge] value in
            javaBridge.s2t(value)
        }
        let toNumChapter1: @convention(block) (String) -> String = { [javaBridge] value in
            javaBridge.toNumChapter(value)
        }
        let put2: @convention(block) (String, String) -> String = { [javaBridge] key, value in
            javaBridge.put(key, value)
        }
        let startBrowserAwait2: @convention(block) (String, String) -> String = { [javaBridge] url, title in
            javaBridge.startBrowserAwait(url, title)
        }
        let startBrowserAwait3: @convention(block) (String, String, Bool) -> String = { [javaBridge] url, title, refetchAfterSuccess in
            javaBridge.startBrowserAwait(url, title, NSNumber(value: refetchAfterSuccess))
        }

        context.setObject(getCookie1, forKeyedSubscript: "__LegadoGetCookie1" as NSString)
        context.setObject(getCookie2, forKeyedSubscript: "__LegadoGetCookie2" as NSString)
        context.setObject(setCookie2, forKeyedSubscript: "__LegadoSetCookie2" as NSString)
        context.setObject(replaceCookie2, forKeyedSubscript: "__LegadoReplaceCookie2" as NSString)
        context.setObject(removeCookie1, forKeyedSubscript: "__LegadoRemoveCookie1" as NSString)
        context.setObject(get1, forKeyedSubscript: "__LegadoGet1" as NSString)
        context.setObject(get2, forKeyedSubscript: "__LegadoGet2" as NSString)
        context.setObject(connect1, forKeyedSubscript: "__LegadoConnect1" as NSString)
        context.setObject(connect2, forKeyedSubscript: "__LegadoConnect2" as NSString)
        context.setObject(getString1, forKeyedSubscript: "__LegadoGetString1" as NSString)
        context.setObject(getSourceVariable0, forKeyedSubscript: "__LegadoGetSourceVariable0" as NSString)
        context.setObject(setSourceVariable1, forKeyedSubscript: "__LegadoSetSourceVariable1" as NSString)
        context.setObject(refreshExplore0, forKeyedSubscript: "__LegadoRefreshExplore0" as NSString)
        context.setObject(androidId0, forKeyedSubscript: "__LegadoAndroidId0" as NSString)
        context.setObject(getLoginHeader0, forKeyedSubscript: "__LegadoGetLoginHeader0" as NSString)
        context.setObject(ajax1, forKeyedSubscript: "__LegadoAjax1" as NSString)
        context.setObject(ajaxAll1, forKeyedSubscript: "__LegadoAjaxAll1" as NSString)
        context.setObject(setContent1, forKeyedSubscript: "__LegadoSetContent1" as NSString)
        context.setObject(getElement1, forKeyedSubscript: "__LegadoGetElement1" as NSString)
        context.setObject(getElements1, forKeyedSubscript: "__LegadoGetElements1" as NSString)
        context.setObject(log1, forKeyedSubscript: "__LegadoLog1" as NSString)
        context.setObject(toast1, forKeyedSubscript: "__LegadoToast1" as NSString)
        context.setObject(longToast1, forKeyedSubscript: "__LegadoLongToast1" as NSString)
        context.setObject(md5Encode1, forKeyedSubscript: "__LegadoMd5Encode1" as NSString)
        context.setObject(md5Encode161, forKeyedSubscript: "__LegadoMd5Encode161" as NSString)
        context.setObject(sha11, forKeyedSubscript: "__LegadoSha11" as NSString)
        context.setObject(sha2561, forKeyedSubscript: "__LegadoSha2561" as NSString)
        context.setObject(base64Encode1, forKeyedSubscript: "__LegadoBase64Encode1" as NSString)
        context.setObject(base64Encode2, forKeyedSubscript: "__LegadoBase64Encode2" as NSString)
        context.setObject(urlEncode1, forKeyedSubscript: "__LegadoUrlEncode1" as NSString)
        context.setObject(urlDecode1, forKeyedSubscript: "__LegadoUrlDecode1" as NSString)
        context.setObject(encodeURI1, forKeyedSubscript: "__LegadoEncodeURI1" as NSString)
        context.setObject(encodeURI2, forKeyedSubscript: "__LegadoEncodeURI2" as NSString)
        context.setObject(timeFormat1, forKeyedSubscript: "__LegadoTimeFormat1" as NSString)
        context.setObject(timeFormatUTC3, forKeyedSubscript: "__LegadoTimeFormatUTC3" as NSString)
        context.setObject(timeStamp1, forKeyedSubscript: "__LegadoTimeStamp1" as NSString)
        context.setObject(base64Decode1, forKeyedSubscript: "__LegadoBase64Decode1" as NSString)
        context.setObject(base64Decode2, forKeyedSubscript: "__LegadoBase64Decode2" as NSString)
        context.setObject(base64DecodeWithFlags2, forKeyedSubscript: "__LegadoBase64DecodeWithFlags2" as NSString)
        context.setObject(base64DecodeToByteArray1, forKeyedSubscript: "__LegadoBase64DecodeToByteArray1" as NSString)
        context.setObject(base64DecodeToByteArray2, forKeyedSubscript: "__LegadoBase64DecodeToByteArray2" as NSString)
        context.setObject(hexDecodeToByteArray1, forKeyedSubscript: "__LegadoHexDecodeToByteArray1" as NSString)
        context.setObject(createSymmetricCrypto3, forKeyedSubscript: "__LegadoCreateSymmetricCrypto3" as NSString)
        context.setObject(desDecodeToString4, forKeyedSubscript: "__LegadoDesDecodeToString4" as NSString)
        context.setObject(desBase64DecodeToString4, forKeyedSubscript: "__LegadoDesBase64DecodeToString4" as NSString)
        context.setObject(desEncodeToString4, forKeyedSubscript: "__LegadoDesEncodeToString4" as NSString)
        context.setObject(desEncodeToBase64String4, forKeyedSubscript: "__LegadoDesEncodeToBase64String4" as NSString)
        context.setObject(createAsymmetricCrypto1, forKeyedSubscript: "__LegadoCreateAsymmetricCrypto1" as NSString)
        context.setObject(strToBytes1, forKeyedSubscript: "__LegadoStrToBytes1" as NSString)
        context.setObject(strToBytes2, forKeyedSubscript: "__LegadoStrToBytes2" as NSString)
        context.setObject(bytesToStr1, forKeyedSubscript: "__LegadoBytesToStr1" as NSString)
        context.setObject(bytesToStr2, forKeyedSubscript: "__LegadoBytesToStr2" as NSString)
        context.setObject(toURL1, forKeyedSubscript: "__LegadoToURL1" as NSString)
        context.setObject(toURL2, forKeyedSubscript: "__LegadoToURL2" as NSString)
        context.setObject(getRequestURL0, forKeyedSubscript: "__LegadoGetRequestURL0" as NSString)
        context.setObject(getRequestHeaders0, forKeyedSubscript: "__LegadoGetRequestHeaders0" as NSString)
        context.setObject(jsoupParse2, forKeyedSubscript: "__LegadoJsoupParse2" as NSString)
        context.setObject(jsoupSelect2, forKeyedSubscript: "__LegadoJsoupSelect2" as NSString)
        context.setObject(jsoupSelectFirst2, forKeyedSubscript: "__LegadoJsoupSelectFirst2" as NSString)
        context.setObject(jsoupText1, forKeyedSubscript: "__LegadoJsoupText1" as NSString)
        context.setObject(jsoupHTML1, forKeyedSubscript: "__LegadoJsoupHTML1" as NSString)
        context.setObject(jsoupOuterHTML1, forKeyedSubscript: "__LegadoJsoupOuterHTML1" as NSString)
        context.setObject(jsoupAttr2, forKeyedSubscript: "__LegadoJsoupAttr2" as NSString)
        context.setObject(jsoupHasClass2, forKeyedSubscript: "__LegadoJsoupHasClass2" as NSString)
        context.setObject(jsoupData1, forKeyedSubscript: "__LegadoJsoupData1" as NSString)
        context.setObject(jsoupRemove1, forKeyedSubscript: "__LegadoJsoupRemove1" as NSString)
        context.setObject(post2, forKeyedSubscript: "__LegadoPost2" as NSString)
        context.setObject(post3, forKeyedSubscript: "__LegadoPost3" as NSString)
        context.setObject(head2, forKeyedSubscript: "__LegadoHead2" as NSString)
        context.setObject(webView3, forKeyedSubscript: "__LegadoWebView3" as NSString)
        context.setObject(webViewGetSource4, forKeyedSubscript: "__LegadoWebViewGetSource4" as NSString)
        context.setObject(webViewGetOverrideUrl4, forKeyedSubscript: "__LegadoWebViewGetOverrideUrl4" as NSString)
        context.setObject(startBrowser2, forKeyedSubscript: "__LegadoStartBrowser2" as NSString)
        context.setObject(getVerificationCode1, forKeyedSubscript: "__LegadoGetVerificationCode1" as NSString)
        context.setObject(getWebViewUA0, forKeyedSubscript: "__LegadoGetWebViewUA0" as NSString)
        context.setObject(logType1, forKeyedSubscript: "__LegadoLogType1" as NSString)
        context.setObject(openUrl1, forKeyedSubscript: "__LegadoOpenUrl1" as NSString)
        context.setObject(openUrl2, forKeyedSubscript: "__LegadoOpenUrl2" as NSString)
        context.setObject(getFile1, forKeyedSubscript: "__LegadoGetFile1" as NSString)
        context.setObject(queryTTF1, forKeyedSubscript: "__LegadoQueryTTF1" as NSString)
        context.setObject(queryTTF2, forKeyedSubscript: "__LegadoQueryTTF2" as NSString)
        context.setObject(queryBase64TTF1, forKeyedSubscript: "__LegadoQueryBase64TTF1" as NSString)
        context.setObject(replaceFont3, forKeyedSubscript: "__LegadoReplaceFont3" as NSString)
        context.setObject(replaceFont4, forKeyedSubscript: "__LegadoReplaceFont4" as NSString)
        context.setObject(cacheFile1, forKeyedSubscript: "__LegadoCacheFile1" as NSString)
        context.setObject(cacheFile2, forKeyedSubscript: "__LegadoCacheFile2" as NSString)
        context.setObject(downloadFile1, forKeyedSubscript: "__LegadoDownloadFile1" as NSString)
        context.setObject(downloadFile2, forKeyedSubscript: "__LegadoDownloadFile2" as NSString)
        context.setObject(importScript1, forKeyedSubscript: "__LegadoImportScript1" as NSString)
        context.setObject(readTxtFile1, forKeyedSubscript: "__LegadoReadTxtFile1" as NSString)
        context.setObject(readTxtFile2, forKeyedSubscript: "__LegadoReadTxtFile2" as NSString)
        context.setObject(readFile1, forKeyedSubscript: "__LegadoReadFile1" as NSString)
        context.setObject(deleteFile1, forKeyedSubscript: "__LegadoDeleteFile1" as NSString)
        context.setObject(getTxtInFolder1, forKeyedSubscript: "__LegadoGetTxtInFolder1" as NSString)
        context.setObject(unzipFile1, forKeyedSubscript: "__LegadoUnzipFile1" as NSString)
        context.setObject(un7zFile1, forKeyedSubscript: "__LegadoUn7zFile1" as NSString)
        context.setObject(unrarFile1, forKeyedSubscript: "__LegadoUnrarFile1" as NSString)
        context.setObject(unArchiveFile1, forKeyedSubscript: "__LegadoUnArchiveFile1" as NSString)
        context.setObject(getZipByteArrayContent2, forKeyedSubscript: "__LegadoGetZipByteArrayContent2" as NSString)
        context.setObject(getRarByteArrayContent2, forKeyedSubscript: "__LegadoGetRarByteArrayContent2" as NSString)
        context.setObject(getRarStringContent2, forKeyedSubscript: "__LegadoGetRarStringContent2" as NSString)
        context.setObject(getRarStringContent3, forKeyedSubscript: "__LegadoGetRarStringContent3" as NSString)
        context.setObject(get7zByteArrayContent2, forKeyedSubscript: "__LegadoGet7zByteArrayContent2" as NSString)
        context.setObject(get7zStringContent2, forKeyedSubscript: "__LegadoGet7zStringContent2" as NSString)
        context.setObject(get7zStringContent3, forKeyedSubscript: "__LegadoGet7zStringContent3" as NSString)
        context.setObject(getZipStringContent2, forKeyedSubscript: "__LegadoGetZipStringContent2" as NSString)
        context.setObject(getZipStringContent3, forKeyedSubscript: "__LegadoGetZipStringContent3" as NSString)
        context.setObject(createSign1, forKeyedSubscript: "__LegadoCreateSign1" as NSString)
        context.setObject(hMacHex2, forKeyedSubscript: "__LegadoHMacHex2" as NSString)
        context.setObject(hMacHex3, forKeyedSubscript: "__LegadoHMacHex3" as NSString)
        context.setObject(hMacBase643, forKeyedSubscript: "__LegadoHMacBase643" as NSString)
        context.setObject(digestHex2, forKeyedSubscript: "__LegadoDigestHex2" as NSString)
        context.setObject(digestBase64Str2, forKeyedSubscript: "__LegadoDigestBase64Str2" as NSString)
        context.setObject(hexEncodeToString1, forKeyedSubscript: "__LegadoHexEncodeToString1" as NSString)
        context.setObject(hexDecodeToString1, forKeyedSubscript: "__LegadoHexDecodeToString1" as NSString)
        context.setObject(htmlFormat1, forKeyedSubscript: "__LegadoHtmlFormat1" as NSString)
        context.setObject(randomUUID0, forKeyedSubscript: "__LegadoRandomUUID0" as NSString)
        context.setObject(t2s1, forKeyedSubscript: "__LegadoT2S1" as NSString)
        context.setObject(s2t1, forKeyedSubscript: "__LegadoS2T1" as NSString)
        context.setObject(toNumChapter1, forKeyedSubscript: "__LegadoToNumChapter1" as NSString)
        context.setObject(put2, forKeyedSubscript: "__LegadoPut2" as NSString)
        context.setObject(startBrowserAwait2, forKeyedSubscript: "__LegadoStartBrowserAwait2" as NSString)
        context.setObject(startBrowserAwait3, forKeyedSubscript: "__LegadoStartBrowserAwait3" as NSString)

        context.evaluateScript(
            """
            function __LegadoMakeBrowserResponse(payload, fallbackUrl) {
                var parsed;
                try {
                    parsed = JSON.parse(payload || '{}');
                } catch (e) {
                    parsed = { url: fallbackUrl || '', body: payload || '' };
                }

                var bodyText = String(parsed.body || '');
                var finalURL = String(parsed.url || fallbackUrl || '');

                function bodyAccessor() { return bodyText; }
                ['indexOf', 'includes', 'startsWith', 'endsWith', 'match', 'replace', 'trim', 'split', 'substring', 'substr', 'slice', 'toLowerCase', 'toUpperCase', 'charAt'].forEach(function(name) {
                    bodyAccessor[name] = function() {
                        return String.prototype[name].apply(bodyText, arguments);
                    };
                });
                bodyAccessor.toString = function() { return bodyText; };
                bodyAccessor.valueOf = function() { return bodyText; };
                if (typeof Symbol !== 'undefined' && Symbol.toPrimitive) {
                    bodyAccessor[Symbol.toPrimitive] = function() { return bodyText; };
                }
                bodyAccessor.text = bodyText;

                return {
                    body: bodyAccessor,
                    bodyText: bodyText,
                    text: bodyText,
                    url: finalURL,
                    finalURL: finalURL,
                    finalUrl: finalURL,
                    requestUrl: fallbackUrl || finalURL,
                    requestURL: fallbackUrl || finalURL,
                    status: 200,
                    statusValue: 200,
                    statusCodeValue: 200,
                    codeValue: 200,
                    message: 'ok',
                    success: true,
                    isSuccess: true,
                    headerMap: {},
                    headersMap: {},
                    code: function() { return 200; },
                    statusCode: function() { return 200; },
                    headers: function() { return {}; },
                    header: function() { return ''; },
                    isSuccessful: function() { return true; },
                    getText: function() { return bodyText; },
                    getUrl: function() { return finalURL; },
                    getRequestUrl: function() { return fallbackUrl || finalURL; }
                };
            }

            java.getCookie = function(tag, key) {
                return arguments.length > 1 ? __LegadoGetCookie2(tag, key) : __LegadoGetCookie1(tag);
            };
            java.setCookie = function(tag, cookieString) {
                return __LegadoSetCookie2(String(tag || ''), String(cookieString || ''));
            };
            java.replaceCookie = function(tag, cookieString) {
                return __LegadoReplaceCookie2(String(tag || ''), String(cookieString || ''));
            };
            java.removeCookie = function(tag) {
                return __LegadoRemoveCookie1(tag || '');
            };
            java.get = function(value, headerValue) {
                return arguments.length > 1 ? __LegadoGet2(String(value), headerValue) : __LegadoGet1(String(value));
            };
            java.connect = function(value, headerValue) {
                return arguments.length > 1 ? __LegadoConnect2(String(value), headerValue) : __LegadoConnect1(String(value));
            };
            java.getString = function(rule) {
                return __LegadoGetString1(String(rule));
            };
            java.getSourceVariable = function() {
                return __LegadoGetSourceVariable0();
            };
            java.setSourceVariable = function(value) {
                return __LegadoSetSourceVariable1(String(value == null ? '' : value));
            };
            java.refreshExplore = function() {
                return __LegadoRefreshExplore0();
            };
            java.getSource = function() {
                return source;
            };
            java.androidId = function() {
                return __LegadoAndroidId0();
            };
            java.getLoginHeader = function() {
                return __LegadoGetLoginHeader0();
            };
            java.ajax = function(url) {
                return __LegadoAjax1(String(url));
            };
            java.ajaxAll = function(urls) {
                return __LegadoAjaxAll1(urls || []);
            };
            java.setContent = function(content) {
                return __LegadoSetContent1(String(content));
            };
            java.getElement = function(rule) {
                return __LegadoGetElement1(String(rule));
            };
            java.getElements = function(rule) {
                try {
                    return JSON.parse(__LegadoGetElements1(String(rule)));
                } catch (error) {
                    return [];
                }
            };
            java.log = function(message) {
                return __LegadoLog1(String(message));
            };
            java.toast = function(message) {
                return __LegadoToast1(String(message));
            };
            java.longToast = function(message) {
                return __LegadoLongToast1(String(message));
            };
            java.md5Encode = function(value) {
                return __LegadoMd5Encode1(String(value));
            };
            java.md5Encode16 = function(value) {
                return __LegadoMd5Encode161(String(value));
            };
            java.sha1 = function(value) {
                return __LegadoSha11(String(value));
            };
            java.sha256 = function(value) {
                return __LegadoSha2561(String(value));
            };
            java.base64Encode = function(value) {
                return arguments.length > 1 ? __LegadoBase64Encode2(String(value), Number(arguments[1])) : __LegadoBase64Encode1(String(value));
            };
            java.urlEncode = function(value) {
                return __LegadoUrlEncode1(String(value));
            };
            java.urlDecode = function(value) {
                return __LegadoUrlDecode1(String(value));
            };
            java.encodeURI = function(value) {
                return arguments.length > 1 ? __LegadoEncodeURI2(String(value), String(arguments[1])) : __LegadoEncodeURI1(String(value));
            };
            java.timeFormat = function(timestamp) {
                return __LegadoTimeFormat1(Number(timestamp));
            };
            java.timeFormatUTC = function(time, format, sh) {
                return __LegadoTimeFormatUTC3(Number(time), String(format), Number(sh));
            };
            java.timeStamp = function(ms) {
                return __LegadoTimeStamp1(!!ms);
            };
            java.base64Decode = function(value, charset) {
                if (arguments.length > 1 && typeof charset === 'number') {
                    return __LegadoBase64DecodeWithFlags2(String(value), Number(charset));
                }
                return arguments.length > 1 ? __LegadoBase64Decode2(value, String(charset)) : __LegadoBase64Decode1(String(value));
            };
            java.base64DecodeToByteArray = function(value) {
                return arguments.length > 1 ? __LegadoBase64DecodeToByteArray2(String(value), Number(arguments[1])) : __LegadoBase64DecodeToByteArray1(String(value));
            };
            java.hexDecodeToByteArray = function(value) {
                return __LegadoHexDecodeToByteArray1(String(value));
            };
            java.createSymmetricCrypto = function(transformation, key, iv) {
                return __LegadoCreateSymmetricCrypto3(String(transformation), String(key), String(iv || ''));
            };
            java.desDecodeToString = function(data, key, transformation, iv) {
                return __LegadoDesDecodeToString4(String(data || ''), String(key || ''), String(transformation || ''), String(iv || ''));
            };
            java.desBase64DecodeToString = function(data, key, transformation, iv) {
                return __LegadoDesBase64DecodeToString4(String(data || ''), String(key || ''), String(transformation || ''), String(iv || ''));
            };
            java.desEncodeToString = function(data, key, transformation, iv) {
                return __LegadoDesEncodeToString4(String(data || ''), String(key || ''), String(transformation || ''), String(iv || ''));
            };
            java.desEncodeToBase64String = function(data, key, transformation, iv) {
                return __LegadoDesEncodeToBase64String4(String(data || ''), String(key || ''), String(transformation || ''), String(iv || ''));
            };
            java.createAsymmetricCrypto = function(transformation) {
                return __LegadoCreateAsymmetricCrypto1(String(transformation));
            };
            java.strToBytes = function(value, charset) {
                return arguments.length > 1 ? __LegadoStrToBytes2(value, charset) : __LegadoStrToBytes1(value);
            };
            java.bytesToStr = function(values, charset) {
                return arguments.length > 1 ? __LegadoBytesToStr2(values, charset) : __LegadoBytesToStr1(values);
            };
            java.toURL = function(value, baseURL) {
                return arguments.length > 1 ? __LegadoToURL2(value, baseURL) : __LegadoToURL1(value);
            };
            java.getRequestURL = function() {
                return __LegadoGetRequestURL0();
            };
            java.getRequestHeaders = function() {
                return __LegadoGetRequestHeaders0();
            };
            java.post = function(url, body) {
                return arguments.length > 2
                    ? __LegadoPost3(String(url), String(body || ''), arguments[2])
                    : __LegadoPost2(String(url), String(body || ''));
            };
            java.head = function(value, headerValue) {
                return __LegadoHead2(String(value), headerValue);
            };
            java.webView = function(html, url, js) {
                return __LegadoWebView3(String(html || ''), String(url || ''), String(js || ''));
            };
            java.webViewGetSource = function(html, url, js, sourceRegex) {
                return __LegadoWebViewGetSource4(String(html || ''), String(url || ''), String(js || ''), String(sourceRegex || ''));
            };
            java.webViewGetOverrideUrl = function(html, url, js, overrideUrlRegex) {
                return __LegadoWebViewGetOverrideUrl4(String(html || ''), String(url || ''), String(js || ''), String(overrideUrlRegex || ''));
            };
            java.startBrowser = function(url, title) {
                return __LegadoStartBrowser2(String(url), String(title || ''));
            };
            java.put = function(key, value) {
                // Android 侧 `put` 可以接收远不止字符串；这里统一把对象/数组序列化后落到变量层，
                // 这样后续 `java.get(...)`、模板替换和调试输出不会因为 JSValue 桥接差异直接丢失信息。
                var normalized;
                if (value === null || value === undefined) {
                    normalized = '';
                } else if (typeof value === 'string') {
                    normalized = value;
                } else if (Array.isArray(value)) {
                    // Android/Rhino stores JS arrays through Array.toString(), which comma-joins
                    // elements. Several signing sources read that variable back as a plain string.
                    normalized = value.map(function(item) {
                        return item === null || item === undefined ? '' : String(item);
                    }).join(',');
                } else if (typeof value === 'object') {
                    try {
                        normalized = JSON.stringify(value);
                    } catch (error) {
                        normalized = String(value);
                    }
                } else {
                    normalized = String(value);
                }
                return __LegadoPut2(String(key), normalized);
            };
            java.startBrowserAwait = function(url, title, refetchAfterSuccess) {
                var payload = arguments.length > 2
                    ? __LegadoStartBrowserAwait3(url, title, !!refetchAfterSuccess)
                    : __LegadoStartBrowserAwait2(url, title);
                return __LegadoMakeBrowserResponse(payload, url);
            };
            java.getVerificationCode = function(imageUrl) {
                return __LegadoGetVerificationCode1(String(imageUrl));
            };
            java.getWebViewUA = function() {
                return __LegadoGetWebViewUA0();
            };
            java.logType = function(value) {
                return __LegadoLogType1(value);
            };
            java.openUrl = function(url, mimeType) {
                return arguments.length > 1 ? __LegadoOpenUrl2(String(url), String(mimeType || '')) : __LegadoOpenUrl1(String(url));
            };
            java.getFile = function(path) {
                return __LegadoGetFile1(String(path));
            };
            java.queryTTF = function(data, useCache) {
                return arguments.length > 1 ? __LegadoQueryTTF2(String(data), !!useCache) : __LegadoQueryTTF1(String(data));
            };
            java.queryBase64TTF = function(data) {
                return __LegadoQueryBase64TTF1(String(data || ''));
            };
            java.replaceFont = function(text, errorTTF, correctTTF) {
                return arguments.length > 3
                    ? __LegadoReplaceFont4(String(text || ''), String(errorTTF || ''), String(correctTTF || ''), !!arguments[3])
                    : __LegadoReplaceFont3(String(text || ''), String(errorTTF || ''), String(correctTTF || ''));
            };
            java.cacheFile = function(urlStr, saveTime) {
                return arguments.length > 1 ? __LegadoCacheFile2(String(urlStr), Number(saveTime)) : __LegadoCacheFile1(String(urlStr));
            };
            java.downloadFile = function(url) {
                return arguments.length > 1 ? __LegadoDownloadFile2(String(url || ''), String(arguments[1] || '')) : __LegadoDownloadFile1(String(url));
            };
            java.importScript = function(path) {
                return __LegadoImportScript1(String(path));
            };
            java.readTxtFile = function(path, charsetName) {
                return arguments.length > 1 ? __LegadoReadTxtFile2(String(path), String(charsetName)) : __LegadoReadTxtFile1(String(path));
            };
            java.readFile = function(path) {
                return __LegadoReadFile1(String(path));
            };
            java.deleteFile = function(path) {
                return __LegadoDeleteFile1(String(path));
            };
            java.getTxtInFolder = function(path) {
                return __LegadoGetTxtInFolder1(String(path));
            };
            java.unzipFile = function(path) {
                return __LegadoUnzipFile1(String(path));
            };
            java.un7zFile = function(path) {
                return __LegadoUn7zFile1(String(path));
            };
            java.unrarFile = function(path) {
                return __LegadoUnrarFile1(String(path));
            };
            java.unArchiveFile = function(path) {
                return __LegadoUnArchiveFile1(String(path));
            };
            java.getZipByteArrayContent = function(url, path) {
                return __LegadoGetZipByteArrayContent2(String(url), String(path));
            };
            java.getRarByteArrayContent = function(url, path) {
                return __LegadoGetRarByteArrayContent2(String(url), String(path));
            };
            java.getRarStringContent = function(url, path, charsetName) {
                return arguments.length > 2 ? __LegadoGetRarStringContent3(String(url), String(path), String(charsetName)) : __LegadoGetRarStringContent2(String(url), String(path));
            };
            java.get7zByteArrayContent = function(url, path) {
                return __LegadoGet7zByteArrayContent2(String(url), String(path));
            };
            java.get7zStringContent = function(url, path, charsetName) {
                return arguments.length > 2 ? __LegadoGet7zStringContent3(String(url), String(path), String(charsetName)) : __LegadoGet7zStringContent2(String(url), String(path));
            };
            java.getZipStringContent = function(url, path, charsetName) {
                return arguments.length > 2 ? __LegadoGetZipStringContent3(String(url), String(path), String(charsetName)) : __LegadoGetZipStringContent2(String(url), String(path));
            };
            java.createSign = function(algorithm) {
                return __LegadoCreateSign1(String(algorithm));
            };
            java.HMacHex = function(data, algorithm, key) {
                return arguments.length > 2 ? __LegadoHMacHex3(String(data), String(algorithm), String(key)) : __LegadoHMacHex2(String(data), String(algorithm));
            };
            java.HMacBase64 = function(data, algorithm, key) {
                return __LegadoHMacBase643(String(data), String(algorithm), String(key));
            };
            java.digestHex = function(data, algorithm) {
                return __LegadoDigestHex2(String(data), String(algorithm));
            };
            java.digestBase64Str = function(data, algorithm) {
                return __LegadoDigestBase64Str2(String(data), String(algorithm));
            };
            java.hexEncodeToString = function(value) {
                return __LegadoHexEncodeToString1(String(value));
            };
            java.hexDecodeToString = function(value) {
                return __LegadoHexDecodeToString1(String(value));
            };
            java.htmlFormat = function(value) {
                return __LegadoHtmlFormat1(String(value));
            };
            java.randomUUID = function() {
                return __LegadoRandomUUID0();
            };
            java.t2s = function(value) {
                return __LegadoT2S1(String(value));
            };
            java.s2t = function(value) {
                return __LegadoS2T1(String(value));
            };
            java.toNumChapter = function(value) {
                return __LegadoToNumChapter1(String(value));
            };

            function __LegadoNativeArray(value) {
                if (!value) return [];
                try {
                    return Array.prototype.slice.call(value);
                } catch (error) {
                    var list = [];
                    if (typeof value.length === 'number') {
                        for (var i = 0; i < value.length; i++) list.push(value[i]);
                    }
                    return list;
                }
            }

            function __LegadoJsoupWrapCollection(items) {
                var list = items || [];
                list.toArray = function() { return Array.prototype.slice.call(this); };
                list.size = function() { return this.length; };
                list.isEmpty = function() { return this.length === 0; };
                list.get = function(index) { return this[index] || null; };
                list.first = function() { return this.length > 0 ? this[0] : null; };
                list.last = function() { return this.length > 0 ? this[this.length - 1] : null; };
                list.text = function() { return this.map(function(item) { return item ? item.text() : ''; }).join(' ').trim(); };
                list.html = function() { return this.map(function(item) { return item ? item.html() : ''; }).join(''); };
                list.outerHtml = function() { return this.map(function(item) { return item ? item.outerHtml() : ''; }).join(''); };
                list.attr = function(name) { return this.length > 0 && this[0] ? this[0].attr(name) : ''; };
                list.hasClass = function(name) { return this.some(function(item) { return item && item.hasClass(name); }); };
                list.data = function() { return this.length > 0 && this[0] ? this[0].data() : ''; };
                list.select = function(selector) {
                    var merged = [];
                    this.forEach(function(item) {
                        if (!item) return;
                        merged = merged.concat(item.select(selector).toArray());
                    });
                    return __LegadoJsoupWrapCollection(merged);
                };
                list.selectFirst = function(selector) {
                    var selected = this.select(selector);
                    return selected.first();
                };
                list.remove = function() {
                    this.forEach(function(item) {
                        if (item) item.remove();
                    });
                    return this;
                };
                list.eachText = function() { return this.map(function(item) { return item ? item.text() : ''; }); };
                list.eachAttr = function(name) { return this.map(function(item) { return item ? item.attr(name) : ''; }); };
                list.toString = function() { return this.outerHtml(); };
                list.valueOf = function() { return this.outerHtml(); };
                if (typeof Symbol !== 'undefined' && Symbol.toPrimitive) {
                    list[Symbol.toPrimitive] = function() { return this.outerHtml(); };
                }
                return list;
            }

            function __LegadoJsoupWrapToken(token) {
                if (!token) return null;
                var node = {
                    __token: String(token),
                    select: function(selector) {
                        var payload = __LegadoJsoupSelect2(this.__token, String(selector || ''));
                        var tokens = [];
                        if (payload) {
                            try {
                                tokens = JSON.parse(String(payload));
                            } catch (error) {
                                tokens = [];
                            }
                        }
                        return __LegadoJsoupWrapCollection(tokens.map(__LegadoJsoupWrapToken).filter(Boolean));
                    },
                    selectFirst: function(selector) {
                        return __LegadoJsoupWrapToken(__LegadoJsoupSelectFirst2(this.__token, String(selector || '')));
                    },
                    text: function() { return __LegadoJsoupText1(this.__token); },
                    html: function() { return __LegadoJsoupHTML1(this.__token); },
                    outerHtml: function() { return __LegadoJsoupOuterHTML1(this.__token); },
                    attr: function(name) { return __LegadoJsoupAttr2(this.__token, String(name || '')); },
                    hasClass: function(name) { return !!__LegadoJsoupHasClass2(this.__token, String(name || '')); },
                    data: function() { return __LegadoJsoupData1(this.__token); },
                    remove: function() {
                        __LegadoJsoupRemove1(this.__token);
                        return this;
                    },
                    size: function() { return 1; },
                    isEmpty: function() { return false; },
                    get: function(index) { return Number(index) === 0 ? this : null; },
                    first: function() { return this; },
                    toArray: function() { return __LegadoJsoupWrapCollection([this]); },
                    eachText: function() { return [this.text()]; },
                    eachAttr: function(name) { return [this.attr(name)]; },
                    toString: function() { return this.outerHtml(); },
                    valueOf: function() { return this.outerHtml(); }
                };
                if (typeof Symbol !== 'undefined' && Symbol.toPrimitive) {
                    node[Symbol.toPrimitive] = function() { return this.outerHtml(); };
                }
                return node;
            }

            function __LegadoJsoupParse(html, baseUrlValue) {
                var normalizedHTML = html == null ? '' : String(html);
                var normalizedBaseUrl = baseUrlValue == null ? '' : String(baseUrlValue);
                return __LegadoJsoupWrapToken(__LegadoJsoupParse2(normalizedHTML, normalizedBaseUrl));
            }

            var __LegadoJsoupDocumentType = function() {};
            var __LegadoJsoupElementType = function() {};
            var __LegadoOrgRoot = typeof org === 'object' && org ? org : {};
            var __LegadoOrgJsoup = __LegadoOrgRoot.jsoup || {};
            var __LegadoOrgNodes = __LegadoOrgJsoup.nodes || {};

            __LegadoOrgJsoup.Jsoup = Object.assign(__LegadoOrgJsoup.Jsoup || {}, {
                parse: function(html, baseUrlValue) {
                    return __LegadoJsoupParse(html, arguments.length > 1 ? baseUrlValue : baseUrl);
                }
            });
            __LegadoOrgNodes.Document = __LegadoOrgNodes.Document || __LegadoJsoupDocumentType;
            __LegadoOrgNodes.Element = __LegadoOrgNodes.Element || __LegadoJsoupElementType;
            __LegadoOrgJsoup.nodes = __LegadoOrgNodes;
            __LegadoOrgRoot.jsoup = __LegadoOrgJsoup;
            org = __LegadoOrgRoot;

            var __LegadoPackages = typeof Packages === 'object' && Packages ? Packages : {};
            __LegadoPackages.org = org;
            Packages = __LegadoPackages;

            if (typeof importClass !== 'function') {
                importClass = function(clazz) { return clazz; };
            }
            if (typeof Jsoup === 'undefined') {
                Jsoup = org.jsoup.Jsoup;
            }
            """
        )
    }

    private func toJSONString(_ array: [String]) -> String {
        let escaped = array.map { str -> String in
            let escaped = str
                .replacingOccurrences(of: "\\", with: "\\\\")
                .replacingOccurrences(of: "\"", with: "\\\"")
                .replacingOccurrences(of: "\n", with: "\\n")
                .replacingOccurrences(of: "\r", with: "\\r")
            return "\"\(escaped)\""
        }
        return "[\(escaped.joined(separator: ","))]"
    }

    private func toJSONStringDictionary(_ dictionary: [String: String]) -> String {
        let entries = dictionary.map { key, value in
            let safeKey = key
                .replacingOccurrences(of: "\\", with: "\\\\")
                .replacingOccurrences(of: "\"", with: "\\\"")
            let safeValue = value
                .replacingOccurrences(of: "\\", with: "\\\\")
                .replacingOccurrences(of: "\"", with: "\\\"")
                .replacingOccurrences(of: "\n", with: "\\n")
                .replacingOccurrences(of: "\r", with: "\\r")
            return "\"\(safeKey)\":\"\(safeValue)\""
        }
        return "{\(entries.joined(separator: ","))}"
    }

    private func toJSONStringValue(_ value: Any) -> String {
        guard JSONSerialization.isValidJSONObject(value),
              let data = try? JSONSerialization.data(withJSONObject: value, options: [.sortedKeys]),
              let string = String(data: data, encoding: .utf8) else {
            return "null"
        }
        return string
    }

    private static func parseBinaryJSResult(_ value: JSValue?) -> Data? {
        guard let value, !value.isUndefined, !value.isNull else {
            return nil
        }

        if let numbers = value.toArray() as? [NSNumber], !numbers.isEmpty {
            return Data(numbers.map { UInt8(truncating: $0) })
        }

        if let array = value.toArray(), !array.isEmpty {
            let bytes = array.compactMap { item -> UInt8? in
                if let number = item as? NSNumber {
                    return UInt8(truncating: number)
                }
                if let intValue = item as? Int {
                    return UInt8(truncatingIfNeeded: intValue)
                }
                if let string = item as? String, let intValue = Int(string.trimmingCharacters(in: .whitespacesAndNewlines)) {
                    return UInt8(truncatingIfNeeded: intValue)
                }
                return nil
            }
            if bytes.count == array.count {
                return Data(bytes)
            }
        }

        if let stringValue = value.toString()?.trimmingCharacters(in: .whitespacesAndNewlines),
           !stringValue.isEmpty {
            if let data = parseDataURL(stringValue) {
                return data
            }
            if isHex(stringValue), stringValue.count.isMultiple(of: 2), let hexData = decodeHexString(stringValue) {
                return hexData
            }
            if let base64Data = Data(base64Encoded: normalizedBase64(stringValue), options: .ignoreUnknownCharacters),
               !base64Data.isEmpty {
                return base64Data
            }
            return Data(stringValue.utf8)
        }

        return nil
    }

    private static func parseDataURL(_ value: String) -> Data? {
        guard value.lowercased().hasPrefix("data:"),
              let commaIndex = value.firstIndex(of: ",") else {
            return nil
        }
        let metadata = value[value.startIndex..<commaIndex].lowercased()
        let payload = String(value[value.index(after: commaIndex)...])

        if metadata.contains(";base64") {
            return Data(base64Encoded: normalizedBase64(payload), options: .ignoreUnknownCharacters)
        }

        return payload.removingPercentEncoding?.data(using: .utf8)
    }

    private static func decodeHexString(_ value: String) -> Data? {
        var bytes: [UInt8] = []
        var index = value.startIndex
        while index < value.endIndex {
            let next = value.index(index, offsetBy: 2)
            guard let byte = UInt8(value[index..<next], radix: 16) else {
                return nil
            }
            bytes.append(byte)
            index = next
        }
        return Data(bytes)
    }

    private static func normalizedBase64(_ value: String) -> String {
        var normalized = value.replacingOccurrences(of: "-", with: "+").replacingOccurrences(of: "_", with: "/")
        let remainder = normalized.count % 4
        if remainder > 0 {
            normalized += String(repeating: "=", count: 4 - remainder)
        }
        return normalized
    }

    private static func isHex(_ value: String) -> Bool {
        !value.isEmpty && value.allSatisfy { $0.isHexDigit }
    }

    private func resolveLoginCheckAction(
        _ value: JSValue?,
        originalBody: String,
        originalResponseObject: JSValue?
    ) -> LoginCheckAction {
        guard let value, !value.isUndefined, !value.isNull else {
            return .reject
        }

        if ResponseBridgeFactory.isResponseObject(value) ||
            (value.isObject && originalResponseObject != nil && value.isEqual(to: originalResponseObject)) {
            return .keepOriginal
        }

        if value.isBoolean {
            return value.toBool() ? .keepOriginal : .reject
        }

        if value.isNumber {
            return value.toDouble() == 0 ? .reject : .keepOriginal
        }

        // loginCheckJs 常见返回值是 true/1 作为“校验通过”的哨兵，不应误写回正文。
        // 只有明确返回非哨兵字符串时，才将其视为重写后的响应体。
        if let stringValue = value.toString() {
            let normalized = stringValue.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
            if normalized.isEmpty || ["false", "0", "null", "undefined"].contains(normalized) {
                return .reject
            }
            if ["true", "1"].contains(normalized) || stringValue == originalBody {
                return .keepOriginal
            }
            return .rewriteBody(stringValue)
        }

        if value.isObject {
            return .keepOriginal
        }

        return .reject
    }
#endif
}

// MARK: - JavaBridge
/// 模拟 legado 中 JavaScript 可调用的 `java` 对象（仅在支持 JavaScriptCore 的平台上可用）
#if canImport(JavaScriptCore)
@objc nonisolated class JavaBridge: NSObject {
    private enum BridgeFileStore {
        static let rootDirectoryName = "JSBridgeCache"
        static let fileDirectoryName = "files"
    }

    private enum WebViewUACache {
        static let lock = NSLock()
        static var value: String?
        static let fallback =
            "Mozilla/5.0 (iPhone; CPU iPhone OS 17_0 like Mac OS X) AppleWebKit/605.1.15 (KHTML, like Gecko) Version/17.0 Mobile/15E148 Safari/604.1"
    }

    private let baseUrl: String
    private let source: BookSource?
    private var variableStore: ParserVariableStore?
    private let requestURL: String
    private let requestHeaders: [String: String]
    private let httpClient: HTTPClient
    private let rateLimiter: ConcurrentRateLimiter
    private let defaultBridgeHeaders: [String: String]
    private var currentContent: String = ""
    private var currentResultContent: String = ""
    private var jsoupStore = JsoupBridgeStore()
    private(set) var didUseJsoupBridge: Bool = false

    init(baseUrl: String, source: BookSource?, variableStore: ParserVariableStore, requestURL: String, requestHeaders: [String: String]) {
        self.baseUrl = baseUrl
        self.source = source
        self.variableStore = variableStore
        self.requestURL = requestURL
        self.requestHeaders = requestHeaders
        self.defaultBridgeHeaders = Self.resolveDefaultBridgeHeaders(source: source, requestHeaders: requestHeaders)
        self.httpClient = HTTPClient()
        self.rateLimiter = ConcurrentRateLimiter(
            sourceKey: source?.bookSourceUrl ?? (URL(string: requestURL)?.host ?? requestURL),
            concurrentRate: source?.concurrentRate
        )
        for (key, value) in defaultBridgeHeaders {
            self.httpClient.defaultHeaders[key] = value
        }
        if let cookieString = source?.cookieJar,
           let cookieURL = URL(string: source?.bookSourceUrl ?? baseUrl) {
            self.httpClient.cookieManager.parseCookieString(cookieString, domain: cookieURL.host ?? "")
        }
    }

    deinit {
        httpClient.shutdown()
    }

    func updateContextContent(_ content: String) {
        currentContent = content
        currentResultContent = ""
        jsoupStore.clear()
    }

    func updateResultContent(_ content: String) {
        currentResultContent = content
    }

    @objc func jsoupParse(_ html: String, _ baseURL: String) -> String {
        didUseJsoupBridge = true
        let resolvedBaseURL = baseURL.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty ? self.baseUrl : baseURL
        guard let parsedHTML = try? SwiftSoup.parse(html, resolvedBaseURL).outerHtml() else {
            return ""
        }
        return jsoupStore.registerDocument(html: parsedHTML, baseURL: resolvedBaseURL)
    }

    @objc func jsoupSelect(_ token: String, _ selector: String) -> String {
        didUseJsoupBridge = true
        guard let entry = jsoupStore.entry(for: token) else { return "[]" }
        let tokens = jsoupStore.select(from: entry, selector: selector)
        return jsonString(from: tokens)
    }

    @objc func jsoupSelectFirst(_ token: String, _ selector: String) -> String {
        didUseJsoupBridge = true
        guard let entry = jsoupStore.entry(for: token) else { return "" }
        return jsoupStore.select(from: entry, selector: selector).first ?? ""
    }

    @objc func jsoupText(_ token: String) -> String {
        guard let entry = jsoupStore.entry(for: token) else { return "" }
        return jsoupStore.sanitizedText(for: entry)
    }

    @objc func jsoupHTML(_ token: String) -> String {
        guard let entry = jsoupStore.entry(for: token) else { return "" }
        return jsoupStore.sanitizedHTML(for: entry, outer: false)
    }

    @objc func jsoupOuterHTML(_ token: String) -> String {
        guard let entry = jsoupStore.entry(for: token) else { return "" }
        return jsoupStore.sanitizedHTML(for: entry, outer: true)
    }

    @objc func jsoupAttr(_ token: String, _ name: String) -> String {
        guard let entry = jsoupStore.entry(for: token) else { return "" }
        return jsoupStore.attributeValue(for: entry, name: name)
    }

    @objc func jsoupHasClass(_ token: String, _ name: String) -> Bool {
        guard let entry = jsoupStore.entry(for: token) else { return false }
        return jsoupStore.hasClass(for: entry, name: name)
    }

    @objc func jsoupData(_ token: String) -> String {
        guard let entry = jsoupStore.entry(for: token) else { return "" }
        return jsoupStore.data(for: entry)
    }

    @objc func jsoupRemove(_ token: String) -> Bool {
        guard let entry = jsoupStore.entry(for: token) else { return false }
        _ = jsoupStore.removeElement(for: entry)
        jsoupStore.remove(token)
        return true
    }

    private func jsonString(from strings: [String]) -> String {
        guard let data = try? JSONSerialization.data(withJSONObject: strings, options: []),
              let json = String(data: data, encoding: .utf8) else {
            return "[]"
        }
        return json
    }

    /// 获取 Cookie（从 CookieManager 中读取）
    @objc func getCookie(_ domain: String) -> String {
        guard let url = URL(string: domain.hasPrefix("http") ? domain : "https://\(domain)") else { return "" }
        return CookieManager.shared.getCookieString(for: url)
    }

    /// 获取 Cookie 中指定 key 的值。
    @objc func getCookie(_ tag: String, _ key: String) -> String {
        let cookieString = getCookie(tag)
        guard !cookieString.isEmpty else { return "" }

        for segment in cookieString.split(separator: ";") {
            let pair = segment.trimmingCharacters(in: .whitespaces)
            let components = pair.split(separator: "=", maxSplits: 1, omittingEmptySubsequences: false)
            guard components.count == 2 else { continue }
            if components[0].trimmingCharacters(in: .whitespaces) == key {
                return String(components[1]).trimmingCharacters(in: .whitespaces)
            }
        }
        return ""
    }

    @objc func removeCookie(_ domain: String) -> String {
        let trimmed = domain.trimmingCharacters(in: .whitespacesAndNewlines)
        let candidates = [
            trimmed,
            source?.bookSourceUrl ?? "",
            baseUrl,
            requestURL
        ]

        for candidate in candidates {
            guard let host = resolvedCookieHost(from: candidate) else { continue }
            CookieManager.shared.clearCookies(domain: host)
        }
        return ""
    }

    @objc func setCookie(_ domain: String, _ cookieString: String) -> String {
        let trimmedDomain = domain.trimmingCharacters(in: .whitespacesAndNewlines)
        let trimmedCookie = cookieString.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmedDomain.isEmpty, !trimmedCookie.isEmpty else { return "" }

        let explicitHost = resolvedCookieHost(from: trimmedDomain)
        if let explicitHost {
            CookieManager.shared.parseCookieString(trimmedCookie, domain: explicitHost)
        } else {
            let fallbackCandidates = [
                source?.bookSourceUrl ?? "",
                baseUrl,
                requestURL
            ]
            for candidate in fallbackCandidates {
                guard let host = resolvedCookieHost(from: candidate) else { continue }
                CookieManager.shared.parseCookieString(trimmedCookie, domain: host)
            }
        }
        return trimmedCookie
    }

    @objc func replaceCookie(_ domain: String, _ cookieString: String) -> String {
        let trimmedDomain = domain.trimmingCharacters(in: .whitespacesAndNewlines)
        let trimmedCookie = cookieString.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmedDomain.isEmpty, !trimmedCookie.isEmpty else { return "" }

        let explicitHost = resolvedCookieHost(from: trimmedDomain)
        if let explicitHost {
            CookieManager.shared.replaceCookieString(trimmedCookie, domain: explicitHost)
        } else {
            let fallbackCandidates = [
                source?.bookSourceUrl ?? "",
                baseUrl,
                requestURL
            ]
            for candidate in fallbackCandidates {
                guard let host = resolvedCookieHost(from: candidate) else { continue }
                CookieManager.shared.replaceCookieString(trimmedCookie, domain: host)
            }
        }
        return trimmedCookie
    }

    @objc func getString(_ rule: String) -> String {
        guard let variableStore else { return "" }
        let trimmedRule = rule.trimmingCharacters(in: .whitespacesAndNewlines)
        let looksLikeJSONPath =
            trimmedRule.hasPrefix("$.") ||
            trimmedRule.hasPrefix("$[") ||
            trimmedRule == "$" ||
            trimmedRule.hasPrefix("@.") ||
            trimmedRule == "@"
        if looksLikeJSONPath {
            if let value = try? JSONPathParser.getString(from: currentContent, rule: rule),
               !value.isEmpty {
                return value
            }
            let fallbackResult = currentResultContent.isEmpty
                ? (variableStore.get(JavaScriptParser.jsResultStoreKey) ?? "")
                : currentResultContent
            guard !fallbackResult.isEmpty, fallbackResult != currentContent else {
                return ""
            }
            return (try? JSONPathParser.getString(from: fallbackResult, rule: rule)) ?? ""
        }

        let analyzer = AnalyzeRule(baseUrl: baseUrl, source: source, variableStore: variableStore)
        if let value = try? analyzer.getString(content: currentContent, rule: rule),
           !value.isEmpty {
            return value
        }
        let fallbackResult = currentResultContent.isEmpty
            ? (variableStore.get(JavaScriptParser.jsResultStoreKey) ?? "")
            : currentResultContent
        guard !fallbackResult.isEmpty, fallbackResult != currentContent else {
            return ""
        }
        return (try? analyzer.getString(content: fallbackResult, rule: rule)) ?? ""
    }

    @objc func put(_ key: String, _ value: Any) -> String {
        let stringValue = stringify(value)
        return variableStore?.put(key, value: stringValue) ?? stringValue
    }

    @objc func get(_ key: String) -> String {
        variableStore?.get(key) ?? ""
    }

    /// Android legado 兼容：返回书源级“原始变量串”，而不是当前变量字典的 JSON。
    @objc func getSourceVariable() -> String {
        let candidates = [
            "__sourceVariableRaw",
            "sourceVariable",
            "sourceVariableRaw",
            "custom"
        ]
        for key in candidates {
            let value = variableStore?.get(key) ?? ""
            if !value.isEmpty {
                return value
            }
        }
        return ""
    }

    /// Android `BaseSource.setVariable` compatibility for source-level JS state.
    @objc func setSourceVariable(_ value: String) -> String {
        variableStore?.put("__sourceVariableRaw", value: value, scope: .source) ?? value
    }

    /// Android 兼容：返回稳定设备标识。
    @objc func androidId() -> String {
        let key = "Legado.jsbridge.androidId"
        if let existing = UserDefaults.standard.string(forKey: key), !existing.isEmpty {
            return existing
        }
        let generated = UUID().uuidString.replacingOccurrences(of: "-", with: "").lowercased()
        UserDefaults.standard.set(generated, forKey: key)
        return generated
    }

    /// Android legado 兼容：返回登录头的原始串；未持久化时应为空串而不是当前请求头 JSON。
    @objc func getLoginHeader() -> String {
        let candidates = [
            "__loginHeaderRaw",
            "loginHeader",
            "loginHeaderRaw"
        ]
        for key in candidates {
            let value = variableStore?.get(key) ?? ""
            if !value.isEmpty {
                return value
            }
        }
        return ""
    }

    /// 获取当前请求 URL。
    @objc func getRequestURL() -> String {
        Self.normalizedBridgeURLString(requestURL)
    }

    /// 获取当前请求头 JSON。
    @objc func getRequestHeaders() -> String {
        guard let data = try? JSONSerialization.data(withJSONObject: requestHeaders, options: [.sortedKeys]),
              let text = String(data: data, encoding: .utf8) else {
            return "{}"
        }
        return text
    }

    /// 下载远程文本/脚本文件到应用私有缓存目录，返回相对缓存路径。
    @objc func downloadFile(_ url: String) -> String {
        guard !Thread.isMainThread else {
            ParserLog.debug("JavaBridge", "downloadFile must not block the main thread")
            return ""
        }

        do {
            let localURL = try resolveDownloadedFileURL(from: url)
            return bridgeRelativePath(for: localURL)
        } catch {
            ParserLog.debug("JavaBridge", "downloadFile failed url=\(url) error=\(error.localizedDescription)")
            return ""
        }
    }

    /// Android 兼容：将十六进制内容保存为文件。
    @objc func downloadFile(_ content: String, _ url: String) -> String {
        guard !Thread.isMainThread else {
            ParserLog.debug("JavaBridge", "downloadFile(content,url) must not block the main thread")
            return ""
        }

        do {
            let typeHint = URL(string: resolvedRequestURL(from: url))?.pathExtension
            let destinationURL = bridgeCachedFileURL(for: url, fallbackExtension: typeHint)
            let data = (try? decodeHexData(from: content)) ?? Data()
            guard !data.isEmpty else { return "" }
            try persistBridgeFile(data: data, to: destinationURL)
            return bridgeRelativePath(for: destinationURL)
        } catch {
            ParserLog.debug("JavaBridge", "downloadFile(content,url) failed url=\(url) error=\(error.localizedDescription)")
            return ""
        }
    }

    /// 读取文本文件。相对路径默认解析到 JS Bridge 私有缓存目录。
    @objc func readTxtFile(_ path: String) -> String {
        readTxtFile(path, "")
    }

    /// 读取文本文件，支持显式指定字符集。
    @objc func readTxtFile(_ path: String, _ charsetName: String) -> String {
        guard let fileURL = resolveReadableFileURL(from: path),
              FileManager.default.fileExists(atPath: fileURL.path),
              let data = try? Data(contentsOf: fileURL) else {
            return ""
        }

        return HTTPClient.decodeTextData(
            data,
            preferredCharset: charsetName.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty ? nil : charsetName
        ) ?? ""
    }

    /// 读取原始文件字节。
    @objc func readFile(_ path: String) -> NSArray {
        guard let fileURL = resolveReadableFileURL(from: path),
              FileManager.default.fileExists(atPath: fileURL.path),
              let data = try? Data(contentsOf: fileURL) else {
            return []
        }
        return data.map { NSNumber(value: $0) } as NSArray
    }

    /// 删除本地文件或目录。
    @objc func deleteFile(_ path: String) -> Bool {
        guard let fileURL = resolveReadableFileURL(from: path),
              FileManager.default.fileExists(atPath: fileURL.path) else {
            return false
        }
        do {
            try FileManager.default.removeItem(at: fileURL)
            return true
        } catch {
            ParserLog.debug("JavaBridge", "deleteFile failed path=\(path) error=\(error.localizedDescription)")
            return false
        }
    }

    /// 缓存远程文本文件，默认永久复用本地副本，直到缓存目录被系统清理。
    @objc func cacheFile(_ urlStr: String) -> String {
        cacheFile(urlStr, 0)
    }

    /// 缓存远程文本文件。`saveTime` 单位为秒，`0` 表示不过期。
    @objc func cacheFile(_ urlStr: String, _ saveTime: Int) -> String {
        do {
            let fileURL = try cachedFileURL(for: urlStr, saveTime: saveTime)
            return HTTPClient.decodeTextData(try Data(contentsOf: fileURL)) ?? ""
        } catch {
            ParserLog.debug("JavaBridge", "cacheFile failed url=\(urlStr) error=\(error.localizedDescription)")
            return ""
        }
    }

    /// 导入脚本：HTTP 地址走缓存复用，本地路径直接读文本。
    @objc func importScript(_ path: String) -> String {
        let result: String
        if isHTTPURL(path) {
            result = cacheFile(path)
        } else {
            result = readTxtFile(path)
        }

        if result.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            let message = "\(path) 内容获取失败或者为空"
            ParserLog.debug("JavaBridge", message)
            if let context = JSContext.current() {
                context.exception = JSValue(newErrorFromMessage: message, in: context)
            }
        }
        return result
    }

    /// 读取目录下所有文本文件并换行拼接，随后删除该目录。
    @objc func getTxtInFolder(_ path: String) -> String {
        guard let folderURL = resolveReadableFileURL(from: path) else { return "" }
        var isDirectory: ObjCBool = false
        guard FileManager.default.fileExists(atPath: folderURL.path, isDirectory: &isDirectory), isDirectory.boolValue else {
            return ""
        }

        do {
            let children = try FileManager.default.contentsOfDirectory(
                at: folderURL,
                includingPropertiesForKeys: [.isRegularFileKey],
                options: [.skipsHiddenFiles]
            )
            let texts = children.compactMap { child -> String? in
                guard (try? child.resourceValues(forKeys: [.isRegularFileKey]).isRegularFile) == true else { return nil }
                let data = try? Data(contentsOf: child)
                guard let data else { return nil }
                return HTTPClient.decodeTextData(data) ?? String(data: data, encoding: .utf8) ?? String(data: data, encoding: .isoLatin1)
            }
            try? FileManager.default.removeItem(at: folderURL)
            return texts.joined(separator: "\n")
        } catch {
            ParserLog.debug("JavaBridge", "getTxtInFolder failed path=\(path) error=\(error.localizedDescription)")
            return ""
        }
    }

    /// Base64 编码
    @objc func base64Encode(_ str: String) -> String {
        return Data(str.utf8).base64EncodedString()
    }

    /// Base64 编码（flags 兼容签名，当前忽略 Android flags，默认输出无换行 Base64）。
    @objc func base64Encode(_ str: String, _ flags: Int) -> String {
        _ = flags
        return base64Encode(str)
    }

    /// Base64 解码
    @objc func base64Decode(_ str: String) -> String {
        decodeBase64String(str, charsetName: "utf-8")
    }

    /// Base64 解码并按指定字符集转为字符串。
    @objc func base64Decode(_ str: String, _ charsetName: String) -> String {
        decodeBase64String(str, charsetName: charsetName)
    }

    /// Base64 解码（flags 兼容签名，当前忽略 Android flags）。
    func base64DecodeWithFlags(_ str: String, _ flags: Int) -> String {
        _ = flags
        return base64Decode(str)
    }

    /// 真实 MD5 实现（CommonCrypto）
    @objc func md5Encode(_ str: String) -> String {
        let data = Data(str.utf8)
        var digest = [UInt8](repeating: 0, count: Int(CC_MD5_DIGEST_LENGTH))
        data.withUnsafeBytes { _ = CC_MD5($0.baseAddress, CC_LONG(data.count), &digest) }
        return digest.map { String(format: "%02hhx", $0) }.joined()
    }

    /// 兼容 Android `md5Encode16`，返回中间 16 位。
    @objc func md5Encode16(_ str: String) -> String {
        let full = md5Encode(str)
        guard full.count >= 24 else { return full }
        let start = full.index(full.startIndex, offsetBy: 8)
        let end = full.index(start, offsetBy: 16)
        return String(full[start..<end])
    }

    /// SHA1
    @objc func sha1(_ str: String) -> String {
        let data = Data(str.utf8)
        var digest = [UInt8](repeating: 0, count: Int(CC_SHA1_DIGEST_LENGTH))
        data.withUnsafeBytes { _ = CC_SHA1($0.baseAddress, CC_LONG(data.count), &digest) }
        return digest.map { String(format: "%02hhx", $0) }.joined()
    }

    /// SHA256
    @objc func sha256(_ str: String) -> String {
        let data = Data(str.utf8)
        var digest = [UInt8](repeating: 0, count: Int(CC_SHA256_DIGEST_LENGTH))
        data.withUnsafeBytes { _ = CC_SHA256($0.baseAddress, CC_LONG(data.count), &digest) }
        return digest.map { String(format: "%02hhx", $0) }.joined()
    }

    /// URL 编码
    @objc func urlEncode(_ str: String) -> String {
        return str.addingPercentEncoding(withAllowedCharacters: .urlQueryAllowed) ?? str
    }

    /// URL 解码
    @objc func urlDecode(_ str: String) -> String {
        return str.removingPercentEncoding ?? str
    }

    @objc func timeFormat(_ timestamp: Double) -> String {
        let seconds = timestamp > 10_000_000_000 ? timestamp / 1000 : timestamp
        let date = Date(timeIntervalSince1970: seconds)
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "zh_CN")
        formatter.timeZone = TimeZone.current
        formatter.dateFormat = "yyyy-MM-dd HH:mm"
        return formatter.string(from: date)
    }

    /// 按 UTC 偏移格式化时间戳（输入为毫秒）。
    @objc func timeFormatUTC(_ time: Double, _ format: String, _ sh: Int) -> String {
        let formatter = DateFormatter()
        formatter.locale = Locale.current
        formatter.timeZone = TimeZone(secondsFromGMT: sh / 1000) ?? TimeZone(secondsFromGMT: 0)
        formatter.dateFormat = format
        return formatter.string(from: Date(timeIntervalSince1970: time / 1000))
    }

    /// 格式化时间戳（ms: true 返回毫秒，false 返回秒）
    @objc func timeStamp(_ ms: Bool) -> String {
        let timestamp = ms ? Date().timeIntervalSince1970 * 1000 : Date().timeIntervalSince1970
        return String(Int64(timestamp))
    }

    /// encodeURI（与 JS encodeURI 等价）
    @objc func encodeURI(_ str: String) -> String {
        return formURLEncode(str, charsetName: "utf-8")
    }

    /// encodeURI（兼容 Android `URLEncoder.encode(str, enc)` 语义）。
    @objc func encodeURI(_ str: String, _ charsetName: String) -> String {
        return formURLEncode(str, charsetName: charsetName)
    }

    /// 字符串转字节数组，默认 UTF-8。
    @objc func strToBytes(_ str: String) -> NSArray {
        strToBytes(str, "utf-8")
    }

    /// 字符串按指定字符集转字节数组。
    @objc func strToBytes(_ str: String, _ charsetName: String) -> NSArray {
        let encoding = stringEncoding(for: charsetName) ?? .utf8
        guard let data = str.data(using: encoding) else { return [] }
        return data.map { NSNumber(value: $0) } as NSArray
    }

    /// 字节数组转字符串，默认 UTF-8。
    @objc func bytesToStr(_ bytes: NSArray) -> String {
        bytesToStr(bytes, "utf-8")
    }

    /// 字节数组按指定字符集转字符串。
    @objc func bytesToStr(_ bytes: NSArray, _ charsetName: String) -> String {
        let encoding = stringEncoding(for: charsetName) ?? .utf8
        return String(data: data(from: bytes), encoding: encoding) ?? ""
    }

    /// Base64 解码为字节数组。
    @objc func base64DecodeToByteArray(_ str: String) -> NSArray {
        guard let data = decodeBase64Data(str) else { return [] }
        return data.map { NSNumber(value: $0) } as NSArray
    }

    /// Base64 解码为字节数组（flags 兼容签名，当前忽略 Android flags）。
    @objc func base64DecodeToByteArray(_ str: String, _ flags: Int) -> NSArray {
        _ = flags
        return base64DecodeToByteArray(str)
    }

    /// 十六进制字符串解码为字节数组。
    @objc func hexDecodeToByteArray(_ hex: String) -> NSArray {
        guard let data = try? decodeHexData(from: hex) else { return [] }
        return data.map { NSNumber(value: $0) } as NSArray
    }

    /// 同步 HTTP GET（供 JS 规则调用，阻塞当前线程）
    @objc func ajax(_ url: String) -> String {
        return analyzeAjax(url)
    }

    /// 同步并发访问多个 URL，返回响应文本 JSON 数组。
    @objc func ajaxAll(_ urls: [String]) -> String {
        ParserLog.debug("JavaBridge", "ajaxAll start count=\(urls.count)")

        let group = DispatchGroup()
        let lock = NSLock()
        var results = [String](repeating: "", count: urls.count)

        for (index, url) in urls.enumerated() {
            group.enter()
            DispatchQueue.global(qos: .utility).async {
                let response = self.syncGet(url: url)
                lock.lock()
                results[index] = response
                lock.unlock()
                group.leave()
            }
        }

        group.wait()

        let jsonText: String
        if let data = try? JSONSerialization.data(withJSONObject: results),
           let text = String(data: data, encoding: .utf8) {
            jsonText = text
        } else {
            jsonText = "[]"
        }

        ParserLog.debug("JavaBridge", "ajaxAll finish count=\(urls.count)")
        return jsonText
    }

    @objc func ajaxGet(_ url: String) -> String {
        return analyzeAjax(url)
    }

    private func analyzeAjax(_ rule: String) -> String {
        return runBlockingBridgeCall(fallback: "") { [self] in
            do {
                let analyzeUrl = AnalyzeUrl(
                    rule: rule,
                    baseUrl: self.baseUrl,
                    headerString: self.serializedHeaders(self.defaultBridgeHeaders),
                    source: self.source,
                    variableStore: self.variableStore
                )
                let response = try self.executeAnalyzeRequest(analyzeUrl, followRedirects: true, forceDirectTransport: true)
                return response.text
                    ?? HTTPClient.decodeResponse(data: response.data, contentTypeHeader: response.headerValue(for: "Content-Type"))
                    ?? String(data: response.data, encoding: .utf8)
                    ?? String(data: response.data, encoding: .isoLatin1)
                    ?? ""
            } catch {
                ParserLog.debug("JavaBridge", "ajax failed rule=\(ParserLog.preview(rule)) error=\(error.localizedDescription)")
                return String(describing: error)
            }
        }
    }

    /// Android legado 兼容：返回包含 `body()/code()/headers()/url()` 的响应对象。
    @objc func connect(_ urlStr: String) -> JSValue? {
        bridgeConnect(urlStr, headerValue: nil)
    }

    /// Android legado 兼容：支持附加请求头的 `connect(url, headers)`。
    @objc func connect(_ urlStr: String, _ headerValue: JSValue?) -> JSValue? {
        bridgeConnect(urlStr, headerValue: headerValue)
    }

    /// Android legado 兼容：`get(url, headers)` 默认不跟随重定向，便于 JS 读取 `Location`。
    @objc func get(_ urlStr: String, _ headerValue: JSValue?) -> JSValue? {
        bridgeSimpleRequest(urlStr, method: .get, followRedirects: false, headerValue: headerValue)
    }

    /// Android legado 兼容：`head(url, headers)` 默认不跟随重定向且不读取响应体。
    @objc func head(_ urlStr: String, _ headerValue: JSValue?) -> JSValue? {
        bridgeSimpleRequest(urlStr, method: .head, followRedirects: false, headerValue: headerValue)
    }

    /// 使用 WebView 加载 URL 或 HTML，并返回执行 JS 后的结果。
    @objc func webView(_ html: String, _ url: String, _ js: String) -> String {
        guard !Thread.isMainThread else {
            ParserLog.debug("JavaBridge", "webView skipped because the parser is running on the main thread")
            return ""
        }

        let semaphore = DispatchSemaphore(value: 0)
        var result = ""
        let resolvedURL = url.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty ? "about:blank" : url
        let headers = source?.header.flatMap { AnalyzeUrl.parseHeaderJSONPublic($0) } ?? [:]

        Task { @MainActor in
            defer { semaphore.signal() }
            result = (try? await HeadlessWebView.shared.fetchHTML(
                html: html.isEmpty ? nil : html,
                url: resolvedURL,
                headers: headers,
                webJs: js.isEmpty ? nil : js,
                delayMs: 0,
                timeoutMs: 30_000
            )) ?? ""
        }

        semaphore.wait()
        return result
    }

    /// 使用 WebView 嗅探资源 URL。
    @objc func webViewGetSource(_ html: String, _ url: String, _ js: String, _ sourceRegex: String) -> String {
        guard !Thread.isMainThread else {
            ParserLog.debug("JavaBridge", "webViewGetSource skipped because the parser is running on the main thread")
            return ""
        }

        let semaphore = DispatchSemaphore(value: 0)
        var result = ""
        let resolvedURL = url.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty ? "about:blank" : url
        let headers = source?.header.flatMap { AnalyzeUrl.parseHeaderJSONPublic($0) } ?? [:]

        Task { @MainActor in
            defer { semaphore.signal() }
            result = (try? await HeadlessWebView.shared.sniffSourceURL(
                html: html.isEmpty ? nil : html,
                url: resolvedURL,
                headers: headers,
                sourceRegex: sourceRegex,
                webJs: js.isEmpty ? nil : js,
                delayMs: 0,
                timeoutMs: 30_000
            )) ?? ""
        }

        semaphore.wait()
        return result
    }

    /// 使用 WebView 拦截跳转到匹配 overrideUrlRegex 的 URL。
    @objc func webViewGetOverrideUrl(_ html: String, _ url: String, _ js: String, _ overrideUrlRegex: String) -> String {
        guard !Thread.isMainThread else {
            ParserLog.debug("JavaBridge", "webViewGetOverrideUrl skipped because the parser is running on the main thread")
            return ""
        }

        let semaphore = DispatchSemaphore(value: 0)
        var result = ""
        let resolvedURL = url.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty ? "about:blank" : resolvedRequestURL(from: url)
        let headers = defaultBridgeHeaders

        Task { @MainActor in
            defer { semaphore.signal() }
            result = (try? await HeadlessWebView.shared.interceptOverrideURL(
                html: html.isEmpty ? nil : html,
                url: resolvedURL,
                headers: headers,
                js: js.isEmpty ? nil : js,
                overrideUrlRegex: overrideUrlRegex,
                delayMs: 0,
                timeoutMs: 30_000
            )) ?? ""
        }

        semaphore.wait()
        return result
    }

    /// 打开内置浏览器用于手动完成源站验证，不等待返回结果。
    @objc func startBrowser(_ url: String, _ title: String) {
        guard Self.interactiveVerificationEnabled else {
            ParserLog.debug("JavaBridge", "startBrowser skipped in non-interactive mode url=\(url)")
            return
        }

        let resolvedURL = resolvedRequestURL(from: url)
        let headers = defaultBridgeHeaders

        Task { @MainActor [source] in
#if canImport(UIKit) && canImport(WebKit)
            do {
                try await SourceVerificationHelper.shared.startBrowser(
                    source: source,
                    url: resolvedURL,
                    title: title,
                    headers: headers
                )
            } catch {
                ParserLog.debug("JavaBridge", "startBrowser failed url=\(resolvedURL) error=\(error.localizedDescription)")
            }
#endif
        }
    }

    /// 打开内置浏览器并等待用户确认，默认在成功后重新发起 HTTP 请求获取最终 HTML。
    @objc func startBrowserAwait(_ url: String, _ title: String) -> String {
        startBrowserAwait(url, title, NSNumber(value: true))
    }

    /// Android legado 兼容：支持 `startBrowserAwait(url, title, refetchAfterSuccess)`。
    @objc func startBrowserAwait(_ url: String, _ title: String, _ refetchAfterSuccess: NSNumber) -> String {
        guard Self.interactiveVerificationEnabled else {
            ParserLog.debug("JavaBridge", "startBrowserAwait skipped in non-interactive mode url=\(url)")
            return ""
        }

        guard !Thread.isMainThread else {
            ParserLog.debug("JavaBridge", "startBrowserAwait skipped because the parser is running on the main thread")
            return ""
        }

        let semaphore = DispatchSemaphore(value: 0)
        var result = ""
        let resolvedURL = resolvedRequestURL(from: url)
        let headers = defaultBridgeHeaders

        Task { @MainActor [source] in
            defer { semaphore.signal() }
#if canImport(UIKit) && canImport(WebKit)
            do {
                let browserResult = try await SourceVerificationHelper.shared.startBrowserAwait(
                    source: source,
                    url: resolvedURL,
                    title: title,
                    headers: headers,
                    refetchAfterSuccess: refetchAfterSuccess.boolValue
                )
                result = Self.serializedBrowserVerificationResult(browserResult)
            } catch {
                ParserLog.debug("JavaBridge", "startBrowserAwait failed url=\(resolvedURL) error=\(error.localizedDescription)")
            }
#endif
        }

        semaphore.wait()
        return result
    }

    /// 显示验证码图片并等待用户输入。
    @objc func getVerificationCode(_ imageUrl: String) -> String {
        guard Self.interactiveVerificationEnabled else {
            ParserLog.debug("JavaBridge", "getVerificationCode skipped in non-interactive mode url=\(imageUrl)")
            return ""
        }

        guard !Thread.isMainThread else {
            ParserLog.debug("JavaBridge", "getVerificationCode skipped because the parser is running on the main thread")
            return ""
        }

        let semaphore = DispatchSemaphore(value: 0)
        var result = ""
        let resolvedURL = resolvedRequestURL(from: imageUrl)

        Task { @MainActor [source] in
            defer { semaphore.signal() }
#if canImport(UIKit) && canImport(WebKit)
            result = await SourceVerificationHelper.shared.getVerificationCode(source: source, imageURL: resolvedURL)
#endif
        }

        semaphore.wait()
        return result
    }

    /// 返回默认 WKWebView User-Agent，首次读取后缓存。
    @objc func getWebViewUA() -> String {
        WebViewUACache.lock.lock()
        if let cached = WebViewUACache.value {
            WebViewUACache.lock.unlock()
            return cached
        }
        WebViewUACache.lock.unlock()

        guard !Thread.isMainThread else {
            return WebViewUACache.fallback
        }

        let semaphore = DispatchSemaphore(value: 0)
        var userAgent = WebViewUACache.fallback

        Task { @MainActor in
            defer { semaphore.signal() }
#if canImport(WebKit)
            let webView = WKWebView(frame: .zero)
            let result = try? await webView.evaluateJavaScript("navigator.userAgent")
            if let value = result as? String,
               !value.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                userAgent = value
            }
#endif
        }

        semaphore.wait()

        WebViewUACache.lock.lock()
        if WebViewUACache.value == nil {
            WebViewUACache.value = userAgent
        }
        let resolved = WebViewUACache.value ?? userAgent
        WebViewUACache.lock.unlock()
        return resolved
    }

    /// 调试辅助：返回 JS 值的动态类型描述。
    @objc func logType(_ any: Any) -> String {
        let description = String(describing: type(of: any))
        ParserLog.debug("JS:java.logType", description)
        return description
    }

    /// 打开 URL，mimeType 当前仅保留签名兼容。
    @objc func openUrl(_ url: String) -> String {
        openUrl(url, "")
    }

    /// 打开 URL，mimeType 当前仅保留签名兼容。
    @objc func openUrl(_ url: String, _ mimeType: String) -> String {
        _ = mimeType
        startBrowser(url, "")
        return ""
    }

    /// 返回当前 JSBridge 可访问的规范化文件路径。
    @objc func getFile(_ path: String) -> String {
        resolveReadableFileURL(from: path)?.path ?? ""
    }

    /// 解析并缓存 TTF/WOFF 字体，返回缓存 token。
    @objc func queryTTF(_ data: String) -> String {
        do {
            guard let fontData = try resolveFontData(from: data) else {
                return ""
            }
            _ = try TTFParser.cached(data: fontData)
            return TTFParser.cacheKey(for: fontData)
        } catch {
            ParserLog.debug("JavaBridge", "queryTTF failed: \(error.localizedDescription)")
            return ""
        }
    }

    /// 兼容 Android 签名，useCache 参数当前忽略，始终启用缓存。
    @objc func queryTTF(_ data: String, _ useCache: Bool) -> String {
        _ = useCache
        return queryTTF(data)
    }

    /// Android 兼容：base64 字体查询。
    @objc func queryBase64TTF(_ data: String) -> String {
        queryTTF(data)
    }

    /// 使用字形匹配替换字体混淆文本。
    @objc func replaceFont(_ text: String, _ errorTTF: String, _ correctTTF: String) -> String {
        guard let errorParser = TTFParser.fontCache[errorTTF],
              let correctParser = TTFParser.fontCache[correctTTF] else {
            ParserLog.debug("JavaBridge", "replaceFont: font not found for token")
            return text
        }
        return TTFParser.replaceFont(text: text, errorFont: errorParser, correctFont: correctParser)
    }

    /// Android 兼容：filter 参数当前保留签名，行为与三参数版本一致。
    @objc func replaceFont(_ text: String, _ errorTTF: String, _ correctTTF: String, _ filter: Bool) -> String {
        _ = filter
        return replaceFont(text, errorTTF, correctTTF)
    }

    @objc func post(_ url: String, _ body: String) -> String {
        guard let reqUrl = URL(string: url) else { return "" }
        var result = ""
        let sem = DispatchSemaphore(value: 0)
        var req = URLRequest(url: reqUrl, timeoutInterval: Self.bridgeRequestTimeout)
        req.httpMethod = "POST"
        req.httpBody = body.data(using: .utf8)
        req.setValue("application/x-www-form-urlencoded", forHTTPHeaderField: "Content-Type")
        URLSession.shared.dataTask(with: req) { data, _, _ in
            if let data = data { result = String(data: data, encoding: .utf8) ?? "" }
            sem.signal()
        }.resume()
        sem.wait(timeout: .now() + Self.bridgeRequestTimeout + 0.5)
        return result
    }

    /// Android legado 兼容：`post(url, body, headers)` 返回响应对象。
    @objc func post(_ urlStr: String, _ body: String, _ headerValue: JSValue?) -> JSValue? {
        let requestURL = resolvedRequestURL(from: urlStr)
        var headers = mergedBridgeHeaders(with: parseHeaderMap(from: headerValue))
        if headers.keys.contains(where: { $0.caseInsensitiveCompare("Content-Type") == .orderedSame }) == false {
            headers["Content-Type"] = "application/x-www-form-urlencoded"
        }

        let result: Result<HTTPResponse, Error> = runBlockingBridgeResult { [self] in
            var request = HTTPRequest(
                url: requestURL,
                method: .post,
                headers: headers,
                body: body.data(using: .utf8) ?? Data(),
                timeout: Self.bridgeRequestTimeout,
                followRedirects: false
            )
            request.body = body.data(using: .utf8) ?? Data()
            return try self.executeRequest(request, forceDirectTransport: true)
        }

        switch result {
        case .success(let response):
            return makeResponseObject(from: response, fallbackRequestURL: requestURL)
        case .failure(let error):
            ParserLog.debug("JavaBridge", "POST failed url=\(urlStr) error=\(error.localizedDescription)")
            return makeErrorResponseObject(urlString: urlStr, message: error.localizedDescription)
        }
    }

    /// 创建对称加密对象，供 JS 通过 `encrypt/decrypt/decryptStr/encryptBase64` 调用。
    @objc func createSymmetricCrypto(_ transformation: String, _ key: String, _ iv: String) -> JSValue? {
        guard let context = JSContext.current() else { return nil }

        let descriptor = SymmetricTransformation.parse(transformation)
        let object = JSValue(newObjectIn: context)

        let decryptBlock: @convention(block) (String) -> String = { [weak self] data in
            self?.symmetricDecrypt(
                data: data,
                transformation: descriptor,
                keyString: key,
                ivString: iv,
                inputFormat: .base64
            ) ?? ""
        }

        let encryptBlock: @convention(block) (String) -> String = { [weak self] data in
            self?.symmetricEncrypt(
                data: data,
                transformation: descriptor,
                keyString: key,
                ivString: iv,
                outputFormat: .base64
            ) ?? ""
        }

        object?.setObject(decryptBlock, forKeyedSubscript: "decryptStr" as NSString)
        object?.setObject(decryptBlock, forKeyedSubscript: "decrypt" as NSString)
        object?.setObject(encryptBlock, forKeyedSubscript: "encryptBase64" as NSString)
        object?.setObject(encryptBlock, forKeyedSubscript: "encrypt" as NSString)
        return object
    }

    /// Android 兼容：DES 解密到字符串。
    @objc func desDecodeToString(_ data: String, _ key: String, _ transformation: String, _ iv: String) -> String {
        symmetricDecrypt(
            data: data,
            transformation: SymmetricTransformation.parse(transformation),
            keyString: key,
            ivString: iv,
            inputFormat: .base64
        )
    }

    /// Android 兼容：DES Base64 解密到字符串。
    @objc func desBase64DecodeToString(_ data: String, _ key: String, _ transformation: String, _ iv: String) -> String {
        desDecodeToString(data, key, transformation, iv)
    }

    /// Android 兼容：DES 加密后返回字符串。
    @objc func desEncodeToString(_ data: String, _ key: String, _ transformation: String, _ iv: String) -> String {
        symmetricEncrypt(
            data: data,
            transformation: SymmetricTransformation.parse(transformation),
            keyString: key,
            ivString: iv,
            outputFormat: .hex
        )
    }

    /// Android 兼容：DES 加密后返回 Base64。
    @objc func desEncodeToBase64String(_ data: String, _ key: String, _ transformation: String, _ iv: String) -> String {
        symmetricEncrypt(
            data: data,
            transformation: SymmetricTransformation.parse(transformation),
            keyString: key,
            ivString: iv,
            outputFormat: .base64
        )
    }

    /// 创建非对称加密对象（Phase 2 stub）。
    @objc func createAsymmetricCrypto(_ transformation: String) -> JSValue? {
        guard let context = JSContext.current() else { return nil }

        let descriptor = AsymmetricTransformation.parse(transformation)
        let bridge = AsymmetricCryptoBridge(transformation: descriptor)
        let object = JSValue(newObjectIn: context)

        let setPublicKey: @convention(block) (JSValue?) -> JSValue? = { value in
            bridge.setPublicKey(value?.toObject() ?? value?.toString() ?? "")
            return object
        }

        let setPrivateKey: @convention(block) (JSValue?) -> JSValue? = { value in
            bridge.setPrivateKey(value?.toObject() ?? value?.toString() ?? "")
            return object
        }

        let decryptBlock: @convention(block) (JSValue?) -> String = { value in
            // Android legado defaults decryptStr(data) to usePublicKey=true.
            bridge.decryptString(value?.toObject() ?? value?.toString() ?? "", usePublicKey: true)
        }

        let decryptWithKeyTypeBlock: @convention(block) (JSValue?, Bool) -> String = { value, usePublicKey in
            bridge.decryptString(value?.toObject() ?? value?.toString() ?? "", usePublicKey: usePublicKey)
        }

        let encryptBase64Block: @convention(block) (JSValue?) -> String = { value in
            bridge.encryptString(value?.toObject() ?? value?.toString() ?? "", usePublicKey: true, outputFormat: .base64)
        }

        let encryptHexBlock: @convention(block) (JSValue?) -> String = { value in
            bridge.encryptString(value?.toObject() ?? value?.toString() ?? "", usePublicKey: true, outputFormat: .hex)
        }

        let encryptBase64WithKeyTypeBlock: @convention(block) (String, Bool) -> String = { data, usePublicKey in
            bridge.encryptString(data, usePublicKey: usePublicKey, outputFormat: .base64)
        }

        let encryptHexWithKeyTypeBlock: @convention(block) (String, Bool) -> String = { data, usePublicKey in
            bridge.encryptString(data, usePublicKey: usePublicKey, outputFormat: .hex)
        }

        object?.setObject(setPublicKey, forKeyedSubscript: "setPublicKey" as NSString)
        object?.setObject(setPrivateKey, forKeyedSubscript: "setPrivateKey" as NSString)
        object?.setObject(decryptBlock, forKeyedSubscript: "decryptStr" as NSString)
        object?.setObject(decryptWithKeyTypeBlock, forKeyedSubscript: "decrypt" as NSString)
        object?.setObject(encryptBase64Block, forKeyedSubscript: "encryptBase64" as NSString)
        object?.setObject(encryptBase64WithKeyTypeBlock, forKeyedSubscript: "encrypt" as NSString)
        object?.setObject(encryptHexBlock, forKeyedSubscript: "encryptHex" as NSString)
        object?.setObject(encryptHexWithKeyTypeBlock, forKeyedSubscript: "encryptHexWithKeyType" as NSString)
        return object
    }

    /// 创建签名对象（Android legado `createSign` 兼容）。
    ///
    /// 支持子集：
    /// - RSA: `SHA1/SHA224/SHA256/SHA384/SHA512 with RSA`
    /// - ECDSA: `SHA1/SHA224/SHA256/SHA384/SHA512 with ECDSA`
    ///
    /// 其他算法名会做常见归一化；无法映射到 Security.framework 的算法将回退为 `SHA256withRSA`。
    @objc func createSign(_ algorithm: String) -> JSValue? {
        guard let context = JSContext.current() else { return nil }

        let descriptor = SignatureAlgorithm.parse(algorithm)
        if descriptor.isFallback {
            ParserLog.debug("JavaBridge", "createSign fallback algorithm=\(algorithm) -> SHA256withRSA")
        }
        let bridge = SignatureBridge(descriptor: descriptor)
        let object = JSValue(newObjectIn: context)

        let setPublicKey: @convention(block) (String) -> JSValue? = { key in
            bridge.setPublicKey(key)
            return object
        }

        let setPrivateKey: @convention(block) (String) -> JSValue? = { key in
            bridge.setPrivateKey(key)
            return object
        }

        let signBase64: @convention(block) (String) -> String = { data in
            bridge.signString(data, outputHex: false)
        }

        let signHex: @convention(block) (String) -> String = { data in
            bridge.signString(data, outputHex: true)
        }

        let verify: @convention(block) (String, String) -> Bool = { data, signature in
            bridge.verifyString(data, signature: signature)
        }

        let verifyHex: @convention(block) (String, String) -> Bool = { data, signature in
            bridge.verifyString(data, signature: signature, signatureIsHex: true)
        }

        object?.setObject(setPublicKey, forKeyedSubscript: "setPublicKey" as NSString)
        object?.setObject(setPrivateKey, forKeyedSubscript: "setPrivateKey" as NSString)
        object?.setObject(signBase64, forKeyedSubscript: "sign" as NSString)
        object?.setObject(signBase64, forKeyedSubscript: "signBase64" as NSString)
        object?.setObject(signHex, forKeyedSubscript: "signHex" as NSString)
        object?.setObject(verify, forKeyedSubscript: "verify" as NSString)
        object?.setObject(verifyHex, forKeyedSubscript: "verifyHex" as NSString)
        return object
    }

    /// 从远程 ZIP 里读取指定路径文本。
    @objc func getZipStringContent(_ url: String, _ path: String) -> String {
        getZipStringContent(url, path, "")
    }

    /// 从远程 ZIP 里读取指定路径原始字节。
    @objc func getZipByteArrayContent(_ url: String, _ path: String) -> NSArray {
        let zipData: Data
        if isHexString(url), let decoded = try? decodeHexData(from: url) {
            zipData = decoded
        } else if let base64 = Data(base64Encoded: normalizedBase64(url), options: .ignoreUnknownCharacters), !base64.isEmpty {
            zipData = base64
        } else {
            let requestStore = variableStore?.cloned() ?? ParserVariableStore(writeScope: .source)
            let analyzeUrl = AnalyzeUrl(
                rule: url,
                baseUrl: baseUrl,
                headerString: source?.header,
                source: source,
                variableStore: requestStore
            )
            let request = HTTPClient.makeRequest(from: analyzeUrl)
            let client = HTTPClient()
            if let headerString = source?.header,
               let headers = AnalyzeUrl.parseHeaderJSONPublic(headerString) {
                for (key, value) in headers {
                    client.defaultHeaders[key] = "\(value)"
                }
            }
            let response = try? blockingSend(request: request, client: client)
            zipData = response?.data ?? Data()
        }

        guard let entryData = HTTPClient.unzipEntry(from: zipData, path: path) else { return [] }
        return entryData.map { NSNumber(value: $0) } as NSArray
    }

    /// RAR 字节读取占位实现，当前 Apple 平台未补齐 RAR 解包。
    @objc func getRarByteArrayContent(_ url: String, _ path: String) -> NSArray {
        _ = url
        _ = path
        ParserLog.debug("JavaBridge", "getRarByteArrayContent is not implemented yet on Apple platforms")
        return []
    }

    /// RAR 文本读取占位实现。
    @objc func getRarStringContent(_ url: String, _ path: String) -> String {
        _ = url
        _ = path
        ParserLog.debug("JavaBridge", "getRarStringContent is not implemented yet on Apple platforms")
        return ""
    }

    /// RAR 文本读取占位实现。
    @objc func getRarStringContent(_ url: String, _ path: String, _ charsetName: String) -> String {
        _ = charsetName
        return getRarStringContent(url, path)
    }

    /// 7z 字节读取占位实现。
    @objc func get7zByteArrayContent(_ url: String, _ path: String) -> NSArray {
        _ = url
        _ = path
        ParserLog.debug("JavaBridge", "get7zByteArrayContent is not implemented yet on Apple platforms")
        return []
    }

    /// 7z 文本读取占位实现。
    @objc func get7zStringContent(_ url: String, _ path: String) -> String {
        _ = url
        _ = path
        ParserLog.debug("JavaBridge", "get7zStringContent is not implemented yet on Apple platforms")
        return ""
    }

    /// 7z 文本读取占位实现。
    @objc func get7zStringContent(_ url: String, _ path: String, _ charsetName: String) -> String {
        _ = charsetName
        return get7zStringContent(url, path)
    }

    /// 从远程 ZIP 里读取指定路径文本，支持显式字符集。
    @objc func getZipStringContent(_ url: String, _ path: String, _ charsetName: String) -> String {
        let zipData: Data
        if isHexString(url), let decoded = try? decodeHexData(from: url) {
            zipData = decoded
        } else if let base64 = Data(base64Encoded: normalizedBase64(url), options: .ignoreUnknownCharacters), !base64.isEmpty {
            zipData = base64
        } else {
            let requestStore = variableStore?.cloned() ?? ParserVariableStore(writeScope: .source)
            let analyzeUrl = AnalyzeUrl(
                rule: url,
                baseUrl: baseUrl,
                headerString: source?.header,
                source: source,
                variableStore: requestStore
            )
            let request = HTTPClient.makeRequest(from: analyzeUrl)
            let client = HTTPClient()
            if let headerString = source?.header,
               let headers = AnalyzeUrl.parseHeaderJSONPublic(headerString) {
                for (key, value) in headers {
                    client.defaultHeaders[key] = "\(value)"
                }
            }
            let response = try? blockingSend(request: request, client: client)
            zipData = response?.data ?? Data()
        }

        guard !zipData.isEmpty else { return "" }
        return HTTPClient.unzipEntryText(
            from: zipData,
            path: path,
            preferredCharset: charsetName.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty ? nil : charsetName
        ) ?? ""
    }

    /// ZIP 解压到 JSBridge 私有目录下的临时文件夹。
    @objc func unzipFile(_ zipPath: String) -> String {
        unArchiveFile(zipPath)
    }

    /// 7z 解压当前先复用统一解压入口；不支持格式时返回空串。
    @objc func un7zFile(_ zipPath: String) -> String {
        unArchiveFile(zipPath)
    }

    /// RAR 解压当前先复用统一解压入口；不支持格式时返回空串。
    @objc func unrarFile(_ zipPath: String) -> String {
        unArchiveFile(zipPath)
    }

    /// 统一解压入口，当前支持 ZIP。
    @objc func unArchiveFile(_ zipPath: String) -> String {
        guard let archiveURL = resolveReadableFileURL(from: zipPath),
              FileManager.default.fileExists(atPath: archiveURL.path) else {
            return ""
        }

        let outputURL = bridgeFileDirectoryURL()
            .appendingPathComponent("archive", isDirectory: true)
            .appendingPathComponent(md5Encode16(archiveURL.lastPathComponent), isDirectory: true)

        do {
            if FileManager.default.fileExists(atPath: outputURL.path) {
                try FileManager.default.removeItem(at: outputURL)
            }
            try FileManager.default.createDirectory(at: outputURL.deletingLastPathComponent(), withIntermediateDirectories: true)
            try BackupZipArchive.extractArchive(at: archiveURL, to: outputURL)
            return bridgeRelativePath(for: outputURL)
        } catch {
            ParserLog.debug("JavaBridge", "unArchiveFile failed path=\(zipPath) error=\(error.localizedDescription)")
            return ""
        }
    }

    @objc func aesBase64DecodeToString(_ data: String, _ key: String, _ transformation: String, _ iv: String) -> String {
        guard let cipherData = Data(base64Encoded: data, options: .ignoreUnknownCharacters),
              let keyData = key.data(using: .utf8) else { return "" }

        let ivData = iv.data(using: .utf8) ?? Data(repeating: 0, count: 16)
        let keyBytes = keyData.prefix(16)
        let ivBytes = ivData.prefix(16)

        var outLength = 0
        // 1. 提前确定缓冲区大小
        let bufferSize = cipherData.count + kCCBlockSizeAES128
        var outData = Data(count: bufferSize)

        let status = outData.withUnsafeMutableBytes { outPtr in
            cipherData.withUnsafeBytes { dataPtr in
                keyBytes.withUnsafeBytes { keyPtr in
                    ivBytes.withUnsafeBytes { ivPtr in
                        CCCrypt(
                            CCOperation(kCCDecrypt),
                            CCAlgorithm(kCCAlgorithmAES),
                            CCOptions(kCCOptionPKCS7Padding),
                            keyPtr.baseAddress, keyBytes.count,
                            ivPtr.baseAddress,
                            dataPtr.baseAddress, cipherData.count,
                            outPtr.baseAddress, bufferSize, // 2. 使用局部变量 bufferSize 而非 outData.count
                            &outLength
                        )
                    }
                }
            }
        }

        guard status == kCCSuccess else {
            // ParserLog.debug("JS:java.aesBase64DecodeToString", "decrypt failed status=\(status)")
            return ""
        }
        
        // 3. 截断多余的填充位
        outData.removeSubrange(outLength...)
        return String(data: outData, encoding: .utf8) ?? ""
    }

    /// 日志（no-op in production）
    @objc func log(_ msg: String) { ParserLog.debug("JS:java.log", msg) }
    @objc func toast(_ msg: String) { ParserLog.debug("JS:java.toast", msg) }
    @objc func longToast(_ msg: String) { ParserLog.debug("JS:java.longToast", msg) }

    /// 繁体转简体。
    @objc func t2s(_ str: String) -> String {
        let mutable = NSMutableString(string: str)
        CFStringTransform(mutable, nil, "Traditional-Simplified" as CFString, false)
        return mutable as String
    }

    /// 简体转繁体。
    @objc func s2t(_ str: String) -> String {
        let mutable = NSMutableString(string: str)
        CFStringTransform(mutable, nil, "Traditional-Simplified" as CFString, true)
        return mutable as String
    }

    /// setContent（存储内容到变量，供后续规则使用）
    @objc func setContent(_ content: String) { _ = variableStore?.put("__content__", value: content) }

    /// getElement（从当前内容中按规则提取单个字符串，兼容 Android JS bridge）
    @objc func getElement(_ rule: String) -> String {
        guard let variableStore else { return "" }
        let analyzer = AnalyzeRule(baseUrl: baseUrl, source: source, variableStore: variableStore)
        return (try? analyzer.getString(content: currentContent, rule: rule, isUrl: false)) ?? ""
    }

    /// getElements（从当前内容中按规则提取元素文本列表，返回 JSON 数组字符串）
    @objc func getElements(_ rule: String) -> String {
        guard let variableStore else { return "[]" }
        let analyzer = AnalyzeRule(baseUrl: baseUrl, source: source, variableStore: variableStore)
        let elements = (try? analyzer.getElements(content: currentContent, rule: rule)) ?? []
        let texts = elements.compactMap { try? $0.text() }
        if let data = try? JSONSerialization.data(withJSONObject: texts),
           let str = String(data: data, encoding: .utf8) { return str }
        return "[]"
    }

    /// HMacHex（兼容旧版 2 参数调用，默认使用 SHA256）。
    @objc func HMacHex(_ data: String, _ key: String) -> String {
        return HMacHex(data, "SHA256", key)
    }

    /// HMacHex（支持多种算法，返回十六进制字符串）。
    @objc func HMacHex(_ data: String, _ algorithm: String, _ key: String) -> String {
        guard let digest = hmacData(for: data, algorithm: algorithm, key: key) else { return "" }
        return digest.map { String(format: "%02hhx", $0) }.joined()
    }

    /// HMacBase64（支持多种算法，返回 Base64 字符串）。
    @objc func HMacBase64(_ data: String, _ algorithm: String, _ key: String) -> String {
        guard let digest = hmacData(for: data, algorithm: algorithm, key: key) else { return "" }
        return digest.base64EncodedString()
    }

    /// 生成摘要，并返回十六进制字符串。
    @objc func digestHex(_ data: String, _ algorithm: String) -> String {
        guard let digest = digestData(for: data, algorithm: algorithm) else { return "" }
        return digest.map { String(format: "%02hhx", $0) }.joined()
    }

    /// 生成摘要，并返回 Base64 字符串。
    @objc func digestBase64Str(_ data: String, _ algorithm: String) -> String {
        guard let digest = digestData(for: data, algorithm: algorithm) else { return "" }
        return digest.base64EncodedString()
    }

    /// UTF-8 字符串转十六进制字符串。
    @objc func hexEncodeToString(_ str: String) -> String {
        return str.utf8.map { String(format: "%02x", $0) }.joined()
    }

    /// 十六进制字符串转 UTF-8 字符串。
    @objc func hexDecodeToString(_ hex: String) -> String {
        guard let data = try? decodeHexData(from: hex) else { return "" }
        return String(data: data, encoding: .utf8) ?? ""
    }

    /// HTML 格式化，保留 `<img>` 标签并清理其它标签。
    @objc func htmlFormat(_ str: String) -> String {
        guard str.contains("<") || str.contains("&") else { return str }

        let pattern = #"<img\b[^>]*>"#
        guard let regex = try? NSRegularExpression(pattern: pattern, options: [.caseInsensitive]) else {
            return HtmlFormatter.format(str)
        }

        var placeholders: [String: String] = [:]
        var working = str
        let matches = regex.matches(in: working, range: NSRange(working.startIndex..., in: working))
        for (index, match) in matches.reversed().enumerated() {
            guard let range = Range(match.range, in: working) else { continue }
            let original = String(working[range])
            let token = "__Legado_IMG_\(index)__"
            placeholders[token] = original
            working.replaceSubrange(range, with: token)
        }

        var formatted = HtmlFormatter.format(working)
        for (token, original) in placeholders {
            formatted = formatted.replacingOccurrences(of: token, with: original)
        }
        return formatted
    }

    /// URL 解析对象。
    @objc func toURL(_ url: String) -> NSDictionary {
        toURL(url, baseUrl)
    }

    /// 相对 URL 按给定 baseUrl 解析为对象。
    @objc func toURL(_ url: String, _ baseURL: String) -> NSDictionary {
        let resolved = resolvedURL(from: url, baseURL: baseURL)
        guard let components = URLComponents(url: resolved, resolvingAgainstBaseURL: true) else {
            return [:]
        }
        return [
            "protocol": components.scheme ?? "",
            "host": components.host ?? "",
            "path": components.path,
            "query": components.query ?? "",
            "ref": components.fragment ?? ""
        ]
    }

    /// 生成 UUID 字符串。
    @objc func randomUUID() -> String {
        return UUID().uuidString
    }

    /// 将中文章节数字转为阿拉伯数字。
    @objc func toNumChapter(_ str: String) -> String {
        guard let regex = try? NSRegularExpression(pattern: #"(第)([零〇一二两三四五六七八九十百千万]+)([章节卷回部篇集])"#) else {
            return str
        }

        let nsRange = NSRange(str.startIndex..., in: str)
        let matches = regex.matches(in: str, range: nsRange)
        guard !matches.isEmpty else { return str }

        var result = str
        for match in matches.reversed() {
            guard let fullRange = Range(match.range(at: 0), in: result),
                  let prefixRange = Range(match.range(at: 1), in: result),
                  let numeralRange = Range(match.range(at: 2), in: result),
                  let suffixRange = Range(match.range(at: 3), in: result) else {
                continue
            }

            let arabicValue = chineseToArabic(String(result[numeralRange]))
            let replacement = "\(result[prefixRange])\(arabicValue)\(result[suffixRange])"
            result.replaceSubrange(fullRange, with: replacement)
        }
        return result
    }

    private func cachedFileURL(for urlString: String, saveTime: Int) throws -> URL {
        let cacheURL = bridgeCachedFileURL(for: urlString)
        if FileManager.default.fileExists(atPath: cacheURL.path),
           isBridgeCacheValid(fileURL: cacheURL, saveTime: saveTime) {
            return cacheURL
        }
        return try resolveDownloadedFileURL(from: urlString, preferredURL: cacheURL)
    }

    private func resolveDownloadedFileURL(from urlString: String, preferredURL: URL? = nil) throws -> URL {
        if let localFileURL = resolveLocalSourceFileURL(from: urlString) {
            let destinationURL = preferredURL ?? bridgeCachedFileURL(for: urlString, fallbackExtension: localFileURL.pathExtension)
            try persistBridgeFile(data: Data(contentsOf: localFileURL), to: destinationURL)
            ParserLog.debug("JavaBridge", "downloadFile local \(urlString) -> \(destinationURL.lastPathComponent)")
            return destinationURL
        }

        let analyzeUrl = AnalyzeUrl(
            rule: urlString,
            baseUrl: baseUrl,
            headerString: serializedHeaders(defaultBridgeHeaders),
            source: source,
            variableStore: variableStore
        )
        let response = try executeAnalyzeRequest(analyzeUrl, followRedirects: true)
        let destinationURL = preferredURL ?? bridgeCachedFileURL(
            for: analyzeUrl.urlString,
            fallbackExtension: fileExtensionHint(
                for: analyzeUrl.urlString,
                responseURL: response.url,
                contentTypeHeader: response.headerValue(for: "Content-Type")
            )
        )
        try persistBridgeFile(data: response.data, to: destinationURL)
        ParserLog.debug("JavaBridge", "downloadFile remote \(urlString) -> \(destinationURL.lastPathComponent)")
        return destinationURL
    }

    private func persistBridgeFile(data: Data, to destinationURL: URL) throws {
        let directoryURL = destinationURL.deletingLastPathComponent()
        try FileManager.default.createDirectory(at: directoryURL, withIntermediateDirectories: true)

        let temporaryURL = directoryURL.appendingPathComponent(UUID().uuidString).appendingPathExtension("tmp")
        do {
            try data.write(to: temporaryURL, options: .atomic)
            if FileManager.default.fileExists(atPath: destinationURL.path) {
                try FileManager.default.removeItem(at: destinationURL)
            }
            try FileManager.default.moveItem(at: temporaryURL, to: destinationURL)
        } catch {
            try? FileManager.default.removeItem(at: temporaryURL)
            throw error
        }
    }

    private func bridgeCachedFileURL(for urlString: String, fallbackExtension: String? = nil) -> URL {
        let fileExtension = normalizedFileExtension(fallbackExtension ?? "")
        return bridgeFileDirectoryURL().appendingPathComponent(md5Encode(urlString)).appendingPathExtension(fileExtension)
    }

    private func bridgeFileDirectoryURL() -> URL {
        // 文件桥接仅使用应用私有缓存目录。系统在存储压力下可清理，脚本与文本会按 URL 哈希自动重建。
        let baseURL = FileManager.default.urls(for: .cachesDirectory, in: .userDomainMask).first
            ?? FileManager.default.temporaryDirectory
        return baseURL
            .appendingPathComponent(BridgeFileStore.rootDirectoryName, isDirectory: true)
            .appendingPathComponent(BridgeFileStore.fileDirectoryName, isDirectory: true)
    }

    private func bridgeRelativePath(for fileURL: URL) -> String {
        let rootPath = bridgeRootDirectoryURL().standardizedFileURL.path
        let standardizedPath = fileURL.standardizedFileURL.path
        if standardizedPath.hasPrefix(rootPath) {
            let relative = String(standardizedPath.dropFirst(rootPath.count)).trimmingCharacters(in: CharacterSet(charactersIn: "/"))
            return relative.isEmpty ? fileURL.lastPathComponent : relative
        }
        return standardizedPath
    }

    private func bridgeRootDirectoryURL() -> URL {
        bridgeFileDirectoryURL().deletingLastPathComponent()
    }

    private func isBridgeCacheValid(fileURL: URL, saveTime: Int) -> Bool {
        guard saveTime > 0 else { return true }
        guard let attributes = try? FileManager.default.attributesOfItem(atPath: fileURL.path),
              let modifiedAt = attributes[.modificationDate] as? Date else {
            return false
        }
        return modifiedAt.addingTimeInterval(TimeInterval(saveTime)) > Date()
    }

    private func resolveReadableFileURL(from path: String) -> URL? {
        let trimmedPath = path.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmedPath.isEmpty else { return nil }

        if let fileURL = resolveLocalSourceFileURL(from: trimmedPath) {
            return fileURL
        }

        if trimmedPath.hasPrefix("/") {
            return validateReadableFileURL(URL(fileURLWithPath: trimmedPath))
        }

        return bridgeRootDirectoryURL()
            .appendingPathComponent(trimmedPath, isDirectory: false)
            .standardizedFileURL
    }

    private func resolveLocalSourceFileURL(from path: String) -> URL? {
        let trimmedPath = path.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmedPath.isEmpty else { return nil }

        if let url = URL(string: trimmedPath), url.isFileURL {
            return validateReadableFileURL(url)
        }

        if trimmedPath.hasPrefix("/") {
            return validateReadableFileURL(URL(fileURLWithPath: trimmedPath))
        }

        return nil
    }

    private func validateReadableFileURL(_ fileURL: URL) -> URL? {
        let standardizedURL = fileURL.standardizedFileURL
        let allowedRoots = [
            bridgeRootDirectoryURL(),
            FileManager.default.urls(for: .cachesDirectory, in: .userDomainMask).first,
            FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first,
            FileManager.default.temporaryDirectory
        ].compactMap { $0?.standardizedFileURL.path }

        let path = standardizedURL.path
        guard allowedRoots.contains(where: { path.hasPrefix($0) }) else {
            return nil
        }
        return standardizedURL
    }

    private func resolvedCookieHost(from value: String) -> String? {
        let trimmed = value.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return nil }

        if let url = URL(string: trimmed), let host = url.host, !host.isEmpty {
            return host
        }

        if let url = URL(string: "https://\(trimmed)"), let host = url.host, !host.isEmpty {
            return host
        }

        return nil
    }

    private func fileExtensionHint(for originalURL: String, responseURL: URL?, contentTypeHeader: String?) -> String {
        if let responseURL,
           !responseURL.pathExtension.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            return responseURL.pathExtension
        }

        if let url = URL(string: originalURL),
           !url.pathExtension.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            return url.pathExtension
        }

        let contentType = contentTypeHeader?.lowercased().split(separator: ";").first?.trimmingCharacters(in: .whitespacesAndNewlines)
        switch contentType {
        case "application/javascript", "text/javascript":
            return "js"
        case "application/json", "text/json":
            return "json"
        case "text/html":
            return "html"
        case "text/css":
            return "css"
        default:
            return "txt"
        }
    }

    private func normalizedFileExtension(_ fileExtension: String) -> String {
        let trimmed = fileExtension.trimmingCharacters(in: CharacterSet(charactersIn: ". ").union(.whitespacesAndNewlines))
        return trimmed.isEmpty ? "txt" : trimmed
    }

    private func isHTTPURL(_ value: String) -> Bool {
        guard let scheme = URL(string: value.trimmingCharacters(in: .whitespacesAndNewlines))?.scheme?.lowercased() else {
            return false
        }
        return scheme == "http" || scheme == "https"
    }

    /// 同步 GET 请求，供 JS 同步桥接调用。
    private func syncGet(url: String) -> String {
        guard let reqUrl = URL(string: url) else { return "" }
        var result = ""
        let sem = DispatchSemaphore(value: 0)
        var req = URLRequest(url: reqUrl, timeoutInterval: Self.bridgeRequestTimeout)
        req.setValue(
            "Mozilla/5.0 (iPhone; CPU iPhone OS 16_0 like Mac OS X) AppleWebKit/605.1.15 (KHTML, like Gecko) Mobile/15E148",
            forHTTPHeaderField: "User-Agent"
        )
        URLSession.shared.dataTask(with: req) { data, _, _ in
            if let data {
                result = HTTPClient.decodeResponse(data: data, contentTypeHeader: nil)
                    ?? String(data: data, encoding: .utf8)
                    ?? String(data: data, encoding: .isoLatin1)
                    ?? ""
            }
            sem.signal()
        }.resume()
        sem.wait(timeout: .now() + Self.bridgeRequestTimeout + 0.5)
        return result
    }

    private func bridgeConnect(_ urlStr: String, headerValue: JSValue?) -> JSValue? {
        let mergedHeaders = mergedBridgeHeaders(with: parseHeaderMap(from: headerValue))
        let result: Result<(HTTPResponse, String), Error> = runBlockingBridgeResult { [self] in
            let analyzeUrl = AnalyzeUrl(
                rule: urlStr,
                baseUrl: self.baseUrl,
                headerString: self.serializedHeaders(mergedHeaders),
                source: self.source,
                variableStore: self.variableStore
            )
            let response = try self.executeAnalyzeRequest(analyzeUrl, followRedirects: true, forceDirectTransport: true)
            return (response, analyzeUrl.urlString)
        }

        switch result {
        case .success(let (response, fallbackRequestURL)):
            return makeResponseObject(
                from: response,
                fallbackRequestURL: fallbackRequestURL,
                requestURLOverride: urlStr
            )
        case .failure(let error):
            ParserLog.debug("JavaBridge", "connect failed url=\(urlStr) error=\(error.localizedDescription)")
            return makeErrorResponseObject(urlString: urlStr, message: error.localizedDescription)
        }
    }

    private func bridgeSimpleRequest(
        _ urlStr: String,
        method: HTTPMethod,
        followRedirects: Bool,
        headerValue: JSValue?
    ) -> JSValue? {
        let requestURL = resolvedRequestURL(from: urlStr)
        let headers = mergedBridgeHeaders(with: parseHeaderMap(from: headerValue))
        let result: Result<HTTPResponse, Error> = runBlockingBridgeResult { [self] in
            var request = HTTPRequest(
                url: requestURL,
                method: method,
                headers: headers,
                timeout: Self.bridgeRequestTimeout,
                followRedirects: followRedirects
            )
            request.body = nil
            return try self.executeRequest(request, forceDirectTransport: true)
        }

        switch result {
        case .success(let response):
            return makeResponseObject(from: response, fallbackRequestURL: requestURL)
        case .failure(let error):
            ParserLog.debug("JavaBridge", "\(method.rawValue) failed url=\(urlStr) error=\(error.localizedDescription)")
            return makeErrorResponseObject(urlString: urlStr, message: error.localizedDescription)
        }
    }

    private func runBlockingBridgeCall<T>(fallback: T, operation: @escaping () -> T) -> T {
        guard Thread.isMainThread else {
            return operation()
        }

        ParserLog.debug("JavaBridge", "bridge call entered on main thread, executing on background queue")
        let lock = NSLock()
        let completion = DispatchSemaphore(value: 0)
        var result = fallback
        var finished = false
        let startedAt = Date()

        DispatchQueue.global(qos: .userInitiated).async {
            let value = operation()
            lock.lock()
            result = value
            finished = true
            lock.unlock()
            completion.signal()
        }

        while true {
            lock.lock()
            let isFinished = finished
            lock.unlock()

            if isFinished {
                break
            }

            if Date().timeIntervalSince(startedAt) >= Self.bridgeRequestTimeout + 0.5 {
                ParserLog.debug("JavaBridge", "bridge call timed out on main thread")
                break
            }

            RunLoop.current.run(mode: .default, before: Date(timeIntervalSinceNow: 0.01))
        }

        lock.lock()
        defer { lock.unlock() }
        return result
    }

    private func runBlockingBridgeResult<T>(_ operation: @escaping () throws -> T) -> Result<T, Error> {
        guard Thread.isMainThread else {
            return Result { try operation() }
        }

        ParserLog.debug("JavaBridge", "bridge result entered on main thread, executing on background queue")
        let lock = NSLock()
        var result: Result<T, Error>?

        DispatchQueue.global(qos: .userInitiated).async {
            let value = Result { try operation() }
            lock.lock()
            result = value
            lock.unlock()
        }

        let startedAt = Date()
        while true {
            lock.lock()
            let current = result
            lock.unlock()

            if let current {
                return current
            }

            if Date().timeIntervalSince(startedAt) >= Self.bridgeRequestTimeout + 0.5 {
                ParserLog.debug("JavaBridge", "bridge result timed out on main thread")
                return .failure(ParserError.networkError("JS Bridge request timed out"))
            }

            RunLoop.current.run(mode: .default, before: Date(timeIntervalSinceNow: 0.01))
        }
    }

    private static var bridgeRequestTimeout: TimeInterval {
        let env = ProcessInfo.processInfo.environment
        if let raw = env["BOOK_SOURCE_COMPARE_TIMEOUT_SECONDS"], let value = TimeInterval(raw) {
            return max(1, min(value, 15))
        }
        if let raw = try? String(contentsOfFile: "/tmp/ios_book_source_compare_config.json", encoding: .utf8),
           let data = raw.data(using: .utf8),
           let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
           let value = json["timeoutSeconds"] as? TimeInterval {
            return max(1, min(value, 15))
        }
        if env["XCTestConfigurationFilePath"] != nil {
            return 5
        }
        return 15
    }

    private static var interactiveVerificationEnabled: Bool {
        let env = ProcessInfo.processInfo.environment
        if env["Legado_INTERACTIVE_VERIFICATION"] == "1" || env["Legado_INTERACTIVE_VERIFICATION"] == "true" {
            return true
        }
        if env["XCTestConfigurationFilePath"] != nil {
            return false
        }
        if env["BOOK_SOURCE_COMPARE_OUTPUT_PATH"] != nil {
            return false
        }
        return true
    }

    private func executeAnalyzeRequest(
        _ analyzeUrl: AnalyzeUrl,
        followRedirects: Bool,
        forceDirectTransport: Bool = false
    ) throws -> HTTPResponse {
        var preparedRequest = HTTPClient.makeRequest(from: analyzeUrl)
        preparedRequest.timeout = min(preparedRequest.timeout, Self.bridgeRequestTimeout)
        preparedRequest.followRedirects = followRedirects
        let request = preparedRequest
        let requiresHexResponse = analyzeUrl.responseType?.caseInsensitiveCompare("hex") == .orderedSame

        if forceDirectTransport || canUseDirectBridgeTransport(webView: analyzeUrl.webView) {
            let response = try self.httpClient.sendSync(request: request)
            return requiresHexResponse ? Self.hexEncodedResponse(from: response) : response
        }

        return try blockingResponse { [self, analyzeUrl, request, requiresHexResponse] in
            try await self.rateLimiter.withLimit {
                if requiresHexResponse {
                    let response = try await self.httpClient.send(request: request)
                    return Self.hexEncodedResponse(from: response)
                }

                if analyzeUrl.webView {
                    return try await self.sendWebViewRequest(analyzeUrl: analyzeUrl, request: request)
                }

                return try await self.httpClient.send(request: request)
            }
        }
    }

    private func executeRequest(_ request: HTTPRequest, forceDirectTransport: Bool = false) throws -> HTTPResponse {
        if forceDirectTransport || canUseDirectBridgeTransport(webView: false) {
            return try httpClient.sendSync(request: request)
        }

        return try blockingResponse { [self, request] in
            try await self.rateLimiter.withLimit {
                try await self.httpClient.send(request: request)
            }
        }
    }

    private func blockingResponse(_ operation: @escaping () async throws -> HTTPResponse) throws -> HTTPResponse {
        guard !Thread.isMainThread else {
            throw ParserError.networkError("JS Bridge request cannot block the main thread")
        }
        let semaphore = DispatchSemaphore(value: 0)
        var output: Result<HTTPResponse, Error> = .failure(ParserError.networkError("请求未开始"))

        Task.detached(priority: .userInitiated) {
            do {
                output = .success(try await operation())
            } catch {
                output = .failure(error)
            }
            semaphore.signal()
        }

        let waitTimeout = DispatchTime.now() + max(Self.bridgeRequestTimeout + 1, 2)
        if semaphore.wait(timeout: waitTimeout) == .timedOut {
            return try Result<HTTPResponse, Error>.failure(
                ParserError.networkError("JS Bridge async request timed out")
            ).get()
        }
        return try output.get()
    }

    private func canUseDirectBridgeTransport(webView: Bool) -> Bool {
        guard !webView else { return false }
        let rawRate = source?.concurrentRate?.trimmingCharacters(in: .whitespacesAndNewlines).lowercased() ?? ""
        return rawRate.isEmpty || rawRate == "0" || rawRate == "none" || rawRate == "null"
    }

    private func sendWebViewRequest(analyzeUrl: AnalyzeUrl, request: HTTPRequest) async throws -> HTTPResponse {
        let renderer = await MainActor.run { HeadlessWebView.shared }
        let requestHeaders = request.headers

        if analyzeUrl.method == .post || analyzeUrl.method == .put || analyzeUrl.method == .delete {
            let response = try await httpClient.send(request: request)
            guard let html = response.text else {
                throw ParserError.parsingFailed("无法解析 WebView 预加载响应")
            }

            let rendered = try await renderWithWebView(
                renderer: renderer,
                html: html,
                url: response.url?.absoluteString ?? analyzeUrl.urlString,
                headers: requestHeaders,
                webJs: analyzeUrl.webJs,
                sourceRegex: analyzeUrl.sourceRegex,
                delayMs: analyzeUrl.webViewDelayTime
            )
            let finalURL = await renderer.lastLoadedURL ?? response.url ?? URL(string: analyzeUrl.urlString)
            return HTTPResponse(
                data: Data(rendered.utf8),
                statusCode: response.statusCode,
                headers: response.headers,
                url: finalURL,
                requestURL: response.requestURL,
                message: response.message,
                headerValues: response.headerValues
            )
        }

        let rendered = try await renderWithWebView(
            renderer: renderer,
            html: nil,
            url: analyzeUrl.urlString,
            headers: requestHeaders,
            webJs: analyzeUrl.webJs,
            sourceRegex: analyzeUrl.sourceRegex,
            delayMs: analyzeUrl.webViewDelayTime
        )
        let finalURL = await renderer.lastLoadedURL ?? URL(string: analyzeUrl.urlString)
        return HTTPResponse(
            data: Data(rendered.utf8),
            statusCode: 200,
            headers: [:],
            url: finalURL,
            requestURL: URL(string: analyzeUrl.urlString),
            message: "ok"
        )
    }

    private func renderWithWebView(
        renderer: HeadlessWebView,
        html: String?,
        url: String,
        headers: [String: String],
        webJs: String?,
        sourceRegex: String?,
        delayMs: Int
    ) async throws -> String {
        if let sourceRegex, !sourceRegex.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            return try await renderer.sniffSourceURL(
                html: html,
                url: url,
                headers: headers,
                sourceRegex: sourceRegex,
                webJs: webJs,
                delayMs: delayMs,
                timeoutMs: 30_000
            )
        }

        return try await renderer.fetchHTML(
            html: html,
            url: url,
            headers: headers,
            webJs: webJs,
            delayMs: delayMs,
            timeoutMs: 30_000
        )
    }

    private nonisolated static func hexEncodedResponse(from response: HTTPResponse) -> HTTPResponse {
        let hexBody = response.data.map { String(format: "%02x", $0) }.joined()
        return HTTPResponse(
            data: response.data,
            statusCode: response.statusCode,
            headers: response.headers,
            url: response.url,
            requestURL: response.requestURL,
            message: response.message,
            headerValues: response.headerValues,
            textOverride: hexBody
        )
    }

    private func makeResponseObject(
        from response: HTTPResponse,
        fallbackRequestURL: String,
        requestURLOverride: String? = nil
    ) -> JSValue? {
        guard let context = JSContext.current() else { return nil }
        return ResponseBridgeFactory.makeResponseObject(
            from: response,
            fallbackRequestURL: fallbackRequestURL,
            requestURLOverride: requestURLOverride,
            in: context
        )
    }

    private func makeErrorResponseObject(urlString: String, message: String) -> JSValue? {
        let requestURL = resolvedRequestURL(from: urlString)
        let response = HTTPResponse(
            data: Data(message.utf8),
            statusCode: 200,
            headers: [:],
            url: URL(string: requestURL),
            requestURL: URL(string: requestURL),
            message: "OK",
            textOverride: message
        )
        return makeResponseObject(from: response, fallbackRequestURL: requestURL)
    }

    private func mergedBridgeHeaders(with explicitHeaders: [String: String]) -> [String: String] {
        var mergedHeaders = defaultBridgeHeaders
        for (key, value) in explicitHeaders {
            mergedHeaders[key] = value
        }
        return mergedHeaders
    }

    private func parseHeaderMap(from value: JSValue?) -> [String: String] {
        guard let value, !value.isUndefined, !value.isNull else {
            return [:]
        }

        if value.isString {
            return AnalyzeUrl.parseHeaderJSONPublic(value.toString()) ?? [:]
        }

        if let dictionary = value.toDictionary() as? [String: Any] {
            return dictionary.reduce(into: [:]) { partialResult, entry in
                partialResult[entry.key] = stringify(entry.value)
            }
        }

        return [:]
    }

    private func resolvedRequestURL(from rawURL: String) -> String {
        let trimmedURL = rawURL.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmedURL.isEmpty else { return trimmedURL }
        if URL(string: trimmedURL)?.scheme != nil {
            return trimmedURL
        }
        guard let base = URL(string: baseUrl),
              let resolvedURL = URL(string: trimmedURL, relativeTo: base) else {
            return trimmedURL
        }
        return resolvedURL.absoluteString
    }

    private func serializedHeaders(_ headers: [String: String]) -> String? {
        guard !headers.isEmpty,
              let data = try? JSONSerialization.data(withJSONObject: headers, options: [.sortedKeys]),
              let text = String(data: data, encoding: .utf8) else {
            return nil
        }
        return text
    }

    private static func serializedBrowserVerificationResult(_ result: SourceVerificationBrowserResult) -> String {
        guard let data = try? JSONEncoder().encode(result),
              let text = String(data: data, encoding: .utf8) else {
            return result.body
        }
        return text
    }

    private static func normalizedBridgeURLString(_ rawValue: String) -> String {
        let trimmed = rawValue.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty,
              var components = URLComponents(string: trimmed),
              let scheme = components.scheme,
              !scheme.isEmpty,
              let host = components.host,
              !host.isEmpty else {
            return trimmed
        }

        if components.path.isEmpty {
            components.path = "/"
        }

        return components.string ?? trimmed
    }

    private static func resolveDefaultBridgeHeaders(source: BookSource?, requestHeaders: [String: String]) -> [String: String] {
        if !requestHeaders.isEmpty {
            return requestHeaders
        }

        guard let source,
              let rawHeaderString = source.header?.trimmingCharacters(in: .whitespacesAndNewlines),
              !rawHeaderString.isEmpty else {
            return [:]
        }

        if rawHeaderString.hasPrefix("@js:") {
            ParserLog.debug(
                "JavaBridge",
                "skip recursive source header resolution source=\(source.bookSourceName) header=\(ParserLog.preview(rawHeaderString))"
            )
            return [:]
        }

        return AnalyzeUrl.parseHeaderJSONPublic(rawHeaderString) ?? [:]
    }

    private func resolveFontData(from input: String) throws -> Data? {
        let trimmed = input.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return nil }

        if let url = URL(string: trimmed), let scheme = url.scheme?.lowercased(), ["http", "https"].contains(scheme) {
            let response = syncGetData(url: trimmed)
            return response.isEmpty ? nil : response
        }

        if isHexString(trimmed), let data = try? decodeHexData(from: trimmed), !data.isEmpty {
            return data
        }

        if let data = Data(base64Encoded: normalizedBase64(trimmed), options: .ignoreUnknownCharacters), !data.isEmpty {
            return data
        }

        return nil
    }

    private func syncGetData(url: String) -> Data {
        guard let reqUrl = URL(string: url) else { return Data() }
        var result = Data()
        let sem = DispatchSemaphore(value: 0)
        var req = URLRequest(url: reqUrl, timeoutInterval: 15)
        req.setValue(
            "Mozilla/5.0 (iPhone; CPU iPhone OS 16_0 like Mac OS X) AppleWebKit/605.1.15 (KHTML, like Gecko) Mobile/15E148",
            forHTTPHeaderField: "User-Agent"
        )
        URLSession.shared.dataTask(with: req) { data, _, _ in
            if let data { result = data }
            sem.signal()
        }.resume()
        sem.wait()
        return result
    }

    private func blockingSend(request: HTTPRequest, client: HTTPClient) throws -> HTTPResponse {
        guard !Thread.isMainThread else {
            throw ParserError.networkError("JS Bridge request cannot block the main thread")
        }
        let semaphore = DispatchSemaphore(value: 0)
        var output: Result<HTTPResponse, Error> = .failure(ParserError.networkError("请求未开始"))

        Task {
            do {
                let response = try await client.send(request: request)
                output = .success(response)
            } catch {
                output = .failure(error)
            }
            semaphore.signal()
        }

        semaphore.wait()
        return try output.get()
    }

    private func decodeBase64Data(_ value: String) -> Data? {
        Data(base64Encoded: normalizedBase64(value), options: .ignoreUnknownCharacters)
    }

    private func decodeBase64String(_ value: String, charsetName: String) -> String {
        guard let data = decodeBase64Data(value) else { return value }
        let encoding = stringEncoding(for: charsetName) ?? .utf8
        return String(data: data, encoding: encoding) ?? ""
    }

    private func stringEncoding(for charsetName: String) -> String.Encoding? {
        switch charsetName.trimmingCharacters(in: .whitespacesAndNewlines).lowercased() {
        case "", "utf-8", "utf8":
            return .utf8
        case "gbk", "gb2312", "gb18030", "gb_2312-80", "chinese", "csgb2312":
            let value = CFStringConvertEncodingToNSStringEncoding(CFStringEncoding(CFStringEncodings.GB_18030_2000.rawValue))
            return String.Encoding(rawValue: value)
        case "big5":
            let value = CFStringConvertEncodingToNSStringEncoding(CFStringEncoding(CFStringEncodings.big5.rawValue))
            return String.Encoding(rawValue: value)
        case "iso-8859-1", "latin1", "latin-1":
            return .isoLatin1
        default:
            return .utf8
        }
    }

    private func formURLEncode(_ value: String, charsetName: String) -> String {
        let encoding = stringEncoding(for: charsetName) ?? .utf8
        guard let data = value.data(using: encoding) else { return "" }

        let allowed = Set("abcdefghijklmnopqrstuvwxyzABCDEFGHIJKLMNOPQRSTUVWXYZ0123456789-_.!*".utf8)
        var encoded = ""
        encoded.reserveCapacity(data.count * 3)

        for byte in data {
            if allowed.contains(byte) {
                encoded.append(Character(UnicodeScalar(byte)))
            } else if byte == 0x20 {
                encoded.append("+")
            } else {
                encoded.append(String(format: "%%%02X", byte))
            }
        }

        return encoded
    }

    private func data(from values: NSArray) -> Data {
        let bytes: [UInt8] = values.compactMap { item in
            if let number = item as? NSNumber {
                return UInt8(truncating: number)
            }
            if let value = item as? Int {
                return UInt8(truncatingIfNeeded: value)
            }
            if let text = item as? String,
               let value = Int(text.trimmingCharacters(in: .whitespacesAndNewlines)) {
                return UInt8(truncatingIfNeeded: value)
            }
            return nil
        }
        return Data(bytes)
    }

    private func digestData(for data: String, algorithm: String) -> Data? {
        guard let inputData = data.data(using: .utf8) else { return nil }

        switch normalizedAlgorithm(algorithm) {
        case "MD5":
            var digest = [UInt8](repeating: 0, count: Int(CC_MD5_DIGEST_LENGTH))
            inputData.withUnsafeBytes { _ = CC_MD5($0.baseAddress, CC_LONG(inputData.count), &digest) }
            return Data(digest)
        case "SHA1":
            var digest = [UInt8](repeating: 0, count: Int(CC_SHA1_DIGEST_LENGTH))
            inputData.withUnsafeBytes { _ = CC_SHA1($0.baseAddress, CC_LONG(inputData.count), &digest) }
            return Data(digest)
        case "SHA256":
            var digest = [UInt8](repeating: 0, count: Int(CC_SHA256_DIGEST_LENGTH))
            inputData.withUnsafeBytes { _ = CC_SHA256($0.baseAddress, CC_LONG(inputData.count), &digest) }
            return Data(digest)
        case "SHA512":
            var digest = [UInt8](repeating: 0, count: Int(CC_SHA512_DIGEST_LENGTH))
            inputData.withUnsafeBytes { _ = CC_SHA512($0.baseAddress, CC_LONG(inputData.count), &digest) }
            return Data(digest)
        default:
            return nil
        }
    }

    private func hmacData(for data: String, algorithm: String, key: String) -> Data? {
        guard let keyData = key.data(using: .utf8),
              let msgData = data.data(using: .utf8),
              let hmacInfo = hmacInfo(for: algorithm) else { return nil }
        var digest = [UInt8](repeating: 0, count: hmacInfo.length)
        keyData.withUnsafeBytes { keyBytes in
            msgData.withUnsafeBytes { msgBytes in
                CCHmac(
                    hmacInfo.algorithm,
                    keyBytes.baseAddress,
                    keyData.count,
                    msgBytes.baseAddress,
                    msgData.count,
                    &digest
                )
            }
        }
        return Data(digest)
    }

    private func resolvedURL(from value: String, baseURL: String) -> URL {
        let trimmed = value.trimmingCharacters(in: .whitespacesAndNewlines)
        if let absolute = URL(string: trimmed), absolute.scheme != nil {
            return absolute
        }
        if let base = URL(string: baseURL),
           let resolved = URL(string: trimmed, relativeTo: base)?.absoluteURL {
            return resolved
        }
        return URL(string: trimmed) ?? URL(string: baseURL) ?? URL(string: "about:blank")!
    }

    private func normalizedBase64(_ value: String) -> String {
        var normalized = value.replacingOccurrences(of: "-", with: "+").replacingOccurrences(of: "_", with: "/")
        let remainder = normalized.count % 4
        if remainder > 0 {
            normalized += String(repeating: "=", count: 4 - remainder)
        }
        return normalized
    }

    /// 归一化算法名，兼容 `SHA-256` / `SHA256` 等写法。
    private func normalizedAlgorithm(_ algorithm: String) -> String {
        algorithm.uppercased().replacingOccurrences(of: "-", with: "")
    }

    /// 执行对称加密并返回指定格式结果。
    private func symmetricEncrypt(
        data: String,
        transformation: SymmetricTransformation,
        keyString: String,
        ivString: String,
        outputFormat: CryptoOutputFormat
    ) -> String {
        do {
            let plaintext = applyInputPaddingIfNeeded(Data(data.utf8), transformation: transformation)
            let keyData = try normalizedKeyData(for: transformation.algorithm, rawValue: keyString)
            let ivData = normalizedIVData(for: transformation, rawValue: ivString)
            let encrypted = try crypt(
                input: plaintext,
                operation: CCOperation(kCCEncrypt),
                transformation: transformation,
                keyData: keyData,
                ivData: ivData
            )
            return encodedString(from: encrypted, format: outputFormat)
        } catch {
            ParserLog.debug("JavaBridge", "crypto error: \(error.localizedDescription)")
            return ""
        }
    }

    /// 执行对称解密并返回 UTF-8 字符串。
    private func symmetricDecrypt(
        data: String,
        transformation: SymmetricTransformation,
        keyString: String,
        ivString: String,
        inputFormat: CryptoInputFormat
    ) -> String {
        do {
            let cipherData = try decodedData(from: data, format: inputFormat)
            let keyData = try normalizedKeyData(for: transformation.algorithm, rawValue: keyString)
            let ivData = normalizedIVData(for: transformation, rawValue: ivString)
            let decrypted = try crypt(
                input: cipherData,
                operation: CCOperation(kCCDecrypt),
                transformation: transformation,
                keyData: keyData,
                ivData: ivData
            )
            let normalized = stripZeroPaddingIfNeeded(decrypted, transformation: transformation)
            return String(data: normalized, encoding: .utf8) ?? ""
        } catch {
            ParserLog.debug("JavaBridge", "crypto error: \(error.localizedDescription)")
            return ""
        }
    }

    private func crypt(
        input: Data,
        operation: CCOperation,
        transformation: SymmetricTransformation,
        keyData: Data,
        ivData: Data?
    ) throws -> Data {
        let outputCapacity = input.count + transformation.blockSize + kCCBlockSize3DES
        var output = Data(count: outputCapacity)
        var outLength = 0

        let modeOptions: CCModeOptions = transformation.mode == .ctr ? CCModeOptions(kCCModeOptionCTR_BE) : CCModeOptions()

        let status = output.withUnsafeMutableBytes { (outputBuffer: UnsafeMutableRawBufferPointer) -> CCCryptorStatus in
            input.withUnsafeBytes { (inputBuffer: UnsafeRawBufferPointer) -> CCCryptorStatus in
                keyData.withUnsafeBytes { (keyBuffer: UnsafeRawBufferPointer) -> CCCryptorStatus in
                    if transformation.mode == .ecb {
                        return CCCrypt(
                            operation,
                            transformation.algorithm.ccAlgorithm,
                            transformation.padding == .pkcs7 ? CCOptions(kCCOptionPKCS7Padding | kCCOptionECBMode) : CCOptions(kCCOptionECBMode),
                            keyBuffer.baseAddress,
                            keyData.count,
                            nil,
                            inputBuffer.baseAddress,
                            input.count,
                            outputBuffer.baseAddress,
                            outputCapacity,
                            &outLength
                        )
                    }

                    var cryptor: CCCryptorRef?
                    let createStatus = (ivData ?? Data()).withUnsafeBytes { (ivBuffer: UnsafeRawBufferPointer) -> CCCryptorStatus in
                        CCCryptorCreateWithMode(
                            operation,
                            transformation.mode.ccMode,
                            transformation.algorithm.ccAlgorithm,
                            transformation.padding.ccPadding,
                            ivBuffer.baseAddress,
                            keyBuffer.baseAddress,
                            keyData.count,
                            nil,
                            0,
                            0,
                            modeOptions,
                            &cryptor
                        )
                    }

                    guard createStatus == kCCSuccess, let cryptor else { return createStatus }
                    defer { CCCryptorRelease(cryptor) }

                    var moved = 0
                    let updateStatus = CCCryptorUpdate(
                        cryptor,
                        inputBuffer.baseAddress,
                        input.count,
                        outputBuffer.baseAddress,
                        outputCapacity,
                        &moved
                    )
                    guard updateStatus == kCCSuccess else { return updateStatus }

                    var finalMoved = 0
                    let finalStatus = CCCryptorFinal(
                        cryptor,
                        outputBuffer.baseAddress.map { $0.advanced(by: moved) },
                        outputCapacity - moved,
                        &finalMoved
                    )
                    outLength = moved + finalMoved
                    return finalStatus
                }
            }
        }

        guard status == kCCSuccess else {
            throw SymmetricCryptoError.cryptFailure(status)
        }

        output.removeSubrange(outLength...)
        return output
    }

    private func decodedData(from value: String, format: CryptoInputFormat) throws -> Data {
        switch format {
        case .base64:
            var normalized = value.replacingOccurrences(of: "-", with: "+").replacingOccurrences(of: "_", with: "/")
            let remainder = normalized.count % 4
            if remainder > 0 {
                normalized += String(repeating: "=", count: 4 - remainder)
            }
            guard let data = Data(base64Encoded: normalized, options: .ignoreUnknownCharacters) else {
                throw SymmetricCryptoError.invalidInput
            }
            return data
        case .hex:
            return try decodeHexData(from: value)
        }
    }

    private func encodedString(from data: Data, format: CryptoOutputFormat) -> String {
        switch format {
        case .base64:
            return data.base64EncodedString()
        case .hex:
            return data.map { String(format: "%02hhx", $0) }.joined()
        }
    }

    private func normalizedKeyData(for algorithm: SymmetricAlgorithm, rawValue: String) throws -> Data {
        let source = decodedFlexibleData(from: rawValue)
        let keySize = algorithm.requiredKeyLength(for: source.count)
        guard keySize > 0 else {
            throw SymmetricCryptoError.invalidKeySize
        }

        var key = source
        if key.count > keySize {
            key = key.prefix(keySize)
        } else if key.count < keySize {
            key.append(Data(repeating: 0, count: keySize - key.count))
        }
        return key
    }

    private func normalizedIVData(for transformation: SymmetricTransformation, rawValue: String) -> Data? {
        guard transformation.mode.usesIV else { return nil }
        let source = decodedFlexibleData(from: rawValue)
        let size = transformation.blockSize
        var iv = source
        if iv.count > size {
            iv = iv.prefix(size)
        } else if iv.count < size {
            iv.append(Data(repeating: 0, count: size - iv.count))
        }
        return iv
    }

    private func decodedFlexibleData(from value: String) -> Data {
        if isHexString(value), let data = try? decodeHexData(from: value) {
            return data
        }
        if let data = Data(base64Encoded: value, options: .ignoreUnknownCharacters), !data.isEmpty {
            return data
        }
        return Data(value.utf8)
    }

    private func decodeHexData(from value: String) throws -> Data {
        let normalized = value.trimmingCharacters(in: .whitespacesAndNewlines)
        guard normalized.count.isMultiple(of: 2), isHexString(normalized) else {
            throw SymmetricCryptoError.invalidInput
        }

        var bytes: [UInt8] = []
        var index = normalized.startIndex
        while index < normalized.endIndex {
            let next = normalized.index(index, offsetBy: 2)
            guard let byte = UInt8(normalized[index..<next], radix: 16) else {
                throw SymmetricCryptoError.invalidInput
            }
            bytes.append(byte)
            index = next
        }
        return Data(bytes)
    }

    private func isHexString(_ value: String) -> Bool {
        !value.isEmpty && value.allSatisfy { $0.isHexDigit }
    }

    private func applyInputPaddingIfNeeded(_ data: Data, transformation: SymmetricTransformation) -> Data {
        guard transformation.padding == .zero, transformation.blockSize > 0 else {
            return data
        }
        let remainder = data.count % transformation.blockSize
        guard remainder != 0 else { return data }

        var padded = data
        padded.append(Data(repeating: 0, count: transformation.blockSize - remainder))
        return padded
    }

    private func stripZeroPaddingIfNeeded(_ data: Data, transformation: SymmetricTransformation) -> Data {
        guard transformation.padding == .zero else {
            return data
        }
        return Data(data.reversed().drop(while: { $0 == 0 }).reversed())
    }

    /// 解析 HMAC 算法配置。
    private func hmacInfo(for algorithm: String) -> (algorithm: CCHmacAlgorithm, length: Int)? {
        let normalized = normalizedAlgorithm(algorithm)
            .replacingOccurrences(of: "HMAC", with: "")
        switch normalized {
        case "MD5":
            return (CCHmacAlgorithm(kCCHmacAlgMD5), Int(CC_MD5_DIGEST_LENGTH))
        case "SHA1":
            return (CCHmacAlgorithm(kCCHmacAlgSHA1), Int(CC_SHA1_DIGEST_LENGTH))
        case "SHA256":
            return (CCHmacAlgorithm(kCCHmacAlgSHA256), Int(CC_SHA256_DIGEST_LENGTH))
        case "SHA512":
            return (CCHmacAlgorithm(kCCHmacAlgSHA512), Int(CC_SHA512_DIGEST_LENGTH))
        default:
            return nil
        }
    }

    /// 将中文数字字符串转换为阿拉伯数字。
    private func chineseToArabic(_ text: String) -> Int {
        let digits: [Character: Int] = [
            "零": 0, "〇": 0, "一": 1, "二": 2, "两": 2, "三": 3, "四": 4,
            "五": 5, "六": 6, "七": 7, "八": 8, "九": 9
        ]
        let units: [Character: Int] = ["十": 10, "百": 100, "千": 1000, "万": 10_000]

        var result = 0
        var section = 0
        var number = 0

        for character in text {
            if let digit = digits[character] {
                number = digit
                continue
            }

            guard let unit = units[character] else { continue }

            if unit == 10_000 {
                section += number
                result += max(section, 1) * unit
                section = 0
                number = 0
            } else {
                let value = number == 0 ? 1 : number
                section += value * unit
                number = 0
            }
        }

        return result + section + number
    }

    private func stringify(_ value: Any) -> String {
        switch value {
        case let string as String:
            return string
        case let number as NSNumber:
            return number.stringValue
        case let array as [Any]:
            // Android JS array `.toString()` 语义是逗号拼接，而不是 NSArray 的 `(a, b)` 描述串。
            return array.map { stringify($0) }.joined(separator: ",")
        case let array as NSArray:
            return array.compactMap { $0 }.map { stringify($0) }.joined(separator: ",")
        case let dictionary as [String: Any]:
            if JSONSerialization.isValidJSONObject(dictionary),
               let data = try? JSONSerialization.data(withJSONObject: dictionary, options: [.sortedKeys]),
               let json = String(data: data, encoding: .utf8) {
                return json
            }
            return dictionary.map { key, value in "\(key)=\(stringify(value))" }.sorted().joined(separator: ",")
        case let dictionary as NSDictionary:
            let normalized = dictionary.reduce(into: [String: Any]()) { partialResult, entry in
                guard let key = entry.key as? String else { return }
                partialResult[key] = entry.value
            }
            if JSONSerialization.isValidJSONObject(normalized),
               let data = try? JSONSerialization.data(withJSONObject: normalized, options: [.sortedKeys]),
               let json = String(data: data, encoding: .utf8) {
                return json
            }
            return normalized.map { key, value in "\(key)=\(stringify(value))" }.sorted().joined(separator: ",")
        default:
            return "\(value)"
        }
    }
}

private nonisolated enum CryptoInputFormat {
    case base64
    case hex
}

private nonisolated enum CryptoOutputFormat {
    case base64
    case hex
}

private nonisolated enum SignatureKeyType {
    case rsa
    case ec
}

private nonisolated struct SignatureAlgorithm {
    enum Digest: String {
        case md5 = "MD5"
        case sha1 = "SHA1"
        case sha224 = "SHA224"
        case sha256 = "SHA256"
        case sha384 = "SHA384"
        case sha512 = "SHA512"
        case none = "NONE"
    }

    let rawValue: String
    let keyType: SignatureKeyType
    let digest: Digest
    let isFallback: Bool

    static func parse(_ value: String) -> SignatureAlgorithm {
        let trimmed = value.trimmingCharacters(in: .whitespacesAndNewlines)
        let upper = trimmed.uppercased()
        let compact = upper
            .replacingOccurrences(of: "-", with: "")
            .replacingOccurrences(of: "_", with: "")
            .replacingOccurrences(of: " ", with: "")
            .replacingOccurrences(of: "/", with: "")

        let keyType: SignatureKeyType
        if compact.contains("ECDSA") || compact.contains("EC") {
            keyType = .ec
        } else {
            keyType = .rsa
        }

        let digest: Digest
        if compact.contains("SHA512") {
            digest = .sha512
        } else if compact.contains("SHA384") {
            digest = .sha384
        } else if compact.contains("SHA256") {
            digest = .sha256
        } else if compact.contains("SHA224") {
            digest = .sha224
        } else if compact.contains("SHA1") || compact.contains("SHA") {
            digest = .sha1
        } else if compact.contains("MD5") {
            digest = .md5
        } else if compact.contains("NONE") || compact.contains("RAW") {
            digest = .none
        } else {
            digest = .sha256
        }

        let supported = isSupported(keyType: keyType, digest: digest)
        let fallback = !supported
        return SignatureAlgorithm(
            rawValue: trimmed.isEmpty ? "SHA256withRSA" : trimmed,
            keyType: fallback ? .rsa : keyType,
            digest: fallback ? .sha256 : digest,
            isFallback: fallback
        )
    }

    private static func isSupported(keyType: SignatureKeyType, digest: Digest) -> Bool {
        switch keyType {
        case .rsa:
            switch digest {
            case .md5:
                return false
            default:
                return true
            }
        case .ec:
            switch digest {
            case .md5, .none:
                return false
            default:
                return true
            }
        }
    }

    var secAlgorithm: SecKeyAlgorithm {
        switch (keyType, digest) {
        case (.rsa, .md5):
            return .rsaSignatureMessagePKCS1v15SHA256
        case (.rsa, .sha1):
            return .rsaSignatureMessagePKCS1v15SHA1
        case (.rsa, .sha224):
            return .rsaSignatureMessagePKCS1v15SHA224
        case (.rsa, .sha256):
            return .rsaSignatureMessagePKCS1v15SHA256
        case (.rsa, .sha384):
            return .rsaSignatureMessagePKCS1v15SHA384
        case (.rsa, .sha512):
            return .rsaSignatureMessagePKCS1v15SHA512
        case (.rsa, .none):
            return .rsaSignatureRaw
        case (.ec, .sha1):
            return .ecdsaSignatureMessageX962SHA1
        case (.ec, .sha224):
            return .ecdsaSignatureMessageX962SHA224
        case (.ec, .sha256):
            return .ecdsaSignatureMessageX962SHA256
        case (.ec, .sha384):
            return .ecdsaSignatureMessageX962SHA384
        case (.ec, .sha512):
            return .ecdsaSignatureMessageX962SHA512
        default:
            return .rsaSignatureMessagePKCS1v15SHA256
        }
    }
}

private nonisolated final class SignatureBridge {
    private let descriptor: SignatureAlgorithm
    private var publicKey: SecKey?
    private var privateKey: SecKey?

    init(descriptor: SignatureAlgorithm) {
        self.descriptor = descriptor
    }

    func setPublicKey(_ key: String) {
        publicKey = createKey(from: key, isPublic: true)
    }

    func setPrivateKey(_ key: String) {
        privateKey = createKey(from: key, isPublic: false)
    }

    func signString(_ data: String, outputHex: Bool) -> String {
        guard let privateKey else { return "" }
        let payload = Data(data.utf8)
        guard SecKeyIsAlgorithmSupported(privateKey, .sign, descriptor.secAlgorithm) else {
            ParserLog.debug("JavaBridge", "createSign unsupported algorithm for sign: \(descriptor.rawValue)")
            return ""
        }

        var error: Unmanaged<CFError>?
        guard let signature = SecKeyCreateSignature(
            privateKey,
            descriptor.secAlgorithm,
            payload as CFData,
            &error
        ) as Data? else {
            if let error {
                ParserLog.debug("JavaBridge", "createSign sign failed: \(error.takeRetainedValue())")
            }
            return ""
        }

        if outputHex {
            return signature.map { String(format: "%02hhx", $0) }.joined()
        }
        return signature.base64EncodedString()
    }

    func verifyString(_ data: String, signature: String, signatureIsHex: Bool = false) -> Bool {
        guard let publicKey else { return false }
        let payload = Data(data.utf8)

        let signatureData: Data
        if signatureIsHex {
            guard let decoded = decodeHex(signature) else {
                return false
            }
            signatureData = decoded
        } else if let decoded = Data(base64Encoded: normalizedBase64(signature), options: .ignoreUnknownCharacters), !decoded.isEmpty {
            signatureData = decoded
        } else if let decoded = decodeHex(signature) {
            signatureData = decoded
        } else {
            signatureData = Data(signature.utf8)
        }

        guard SecKeyIsAlgorithmSupported(publicKey, .verify, descriptor.secAlgorithm) else {
            ParserLog.debug("JavaBridge", "createSign unsupported algorithm for verify: \(descriptor.rawValue)")
            return false
        }

        var error: Unmanaged<CFError>?
        let verified = SecKeyVerifySignature(
            publicKey,
            descriptor.secAlgorithm,
            payload as CFData,
            signatureData as CFData,
            &error
        )
        if !verified, let error {
            ParserLog.debug("JavaBridge", "createSign verify failed: \(error.takeRetainedValue())")
        }
        return verified
    }

    private func createKey(from rawValue: String, isPublic: Bool) -> SecKey? {
        let normalized = normalizePEM(rawValue)
        guard !normalized.isEmpty else { return nil }

        let keyData = Data(base64Encoded: normalized, options: .ignoreUnknownCharacters) ?? Data(rawValue.utf8)
        let keyTypeValue: CFString = descriptor.keyType == .ec ? kSecAttrKeyTypeECSECPrimeRandom : kSecAttrKeyTypeRSA
        let attributes: [String: Any] = [
            kSecAttrKeyType as String: keyTypeValue,
            kSecAttrKeyClass as String: isPublic ? kSecAttrKeyClassPublic : kSecAttrKeyClassPrivate,
            kSecAttrKeySizeInBits as String: max(256, keyData.count * 8)
        ]

        var error: Unmanaged<CFError>?
        if let key = SecKeyCreateWithData(keyData as CFData, attributes as CFDictionary, &error) {
            return key
        }

        if descriptor.keyType == .rsa && !normalized.contains("BEGIN") {
            let wrapped = isPublic ? wrapPublicKey(keyData) : wrapPrivateKey(keyData)
            if let wrapped {
                error = nil
                return SecKeyCreateWithData(wrapped as CFData, attributes as CFDictionary, &error)
            }
        }

        if let error {
            ParserLog.debug("JavaBridge", "createSign key parse failed: \(error.takeRetainedValue())")
        }
        return nil
    }

    private func normalizePEM(_ value: String) -> String {
        value
            .replacingOccurrences(of: "-----BEGIN PUBLIC KEY-----", with: "")
            .replacingOccurrences(of: "-----END PUBLIC KEY-----", with: "")
            .replacingOccurrences(of: "-----BEGIN PRIVATE KEY-----", with: "")
            .replacingOccurrences(of: "-----END PRIVATE KEY-----", with: "")
            .replacingOccurrences(of: "-----BEGIN RSA PRIVATE KEY-----", with: "")
            .replacingOccurrences(of: "-----END RSA PRIVATE KEY-----", with: "")
            .replacingOccurrences(of: "-----BEGIN EC PRIVATE KEY-----", with: "")
            .replacingOccurrences(of: "-----END EC PRIVATE KEY-----", with: "")
            .components(separatedBy: .whitespacesAndNewlines)
            .joined()
    }

    private func wrapPublicKey(_ data: Data) -> Data? {
        let header: [UInt8] = [
            0x30, 0x82, 0x01, 0x22,
            0x30, 0x0d,
            0x06, 0x09, 0x2a, 0x86, 0x48, 0x86, 0xf7, 0x0d, 0x01, 0x01, 0x01,
            0x05, 0x00,
            0x03, 0x82, 0x01, 0x0f, 0x00
        ]

        guard data.count >= 128 else { return nil }
        return Data(header) + data
    }

    private func wrapPrivateKey(_ data: Data) -> Data? {
        data
    }

    private func decodeHex(_ value: String) -> Data? {
        let normalized = value.trimmingCharacters(in: .whitespacesAndNewlines)
        guard normalized.count.isMultiple(of: 2), normalized.allSatisfy(\.isHexDigit) else {
            return nil
        }

        var bytes: [UInt8] = []
        var index = normalized.startIndex
        while index < normalized.endIndex {
            let next = normalized.index(index, offsetBy: 2)
            guard let byte = UInt8(normalized[index..<next], radix: 16) else {
                return nil
            }
            bytes.append(byte)
            index = next
        }
        return Data(bytes)
    }

    private func normalizedBase64(_ value: String) -> String {
        var normalized = value.replacingOccurrences(of: "-", with: "+").replacingOccurrences(of: "_", with: "/")
        let remainder = normalized.count % 4
        if remainder > 0 {
            normalized += String(repeating: "=", count: 4 - remainder)
        }
        return normalized
    }
}

private nonisolated final class AsymmetricCryptoBridge {
    private let transformation: AsymmetricTransformation
    private var publicKey: SecKey?
    private var privateKey: SecKey?
    private var publicKeyDERForSwCrypt: Data?
    private var privateKeyDERForSwCrypt: Data?

    init(transformation: AsymmetricTransformation) {
        self.transformation = transformation
    }

    func setPublicKey(_ key: Any) {
        let material = createKeyMaterial(from: key, isPublic: true)
        publicKey = material.secKey
        publicKeyDERForSwCrypt = material.derKeyForSwCrypt
    }

    func setPrivateKey(_ key: Any) {
        let material = createKeyMaterial(from: key, isPublic: false)
        privateKey = material.secKey
        privateKeyDERForSwCrypt = material.derKeyForSwCrypt
    }

    func encryptString(_ value: Any, usePublicKey: Bool, outputFormat: CryptoOutputFormat) -> String {
        guard let key = usePublicKey ? publicKey : privateKey else { return "" }
        guard let algorithm = transformation.encryptionAlgorithm else { return "" }
        let plainData = normalizeInputData(value) ?? Data(String(describing: value).utf8)

        do {
            let encrypted = try transform(
                key: key,
                data: plainData,
                algorithm: algorithm,
                operation: .encrypt
            )
            switch outputFormat {
            case .base64:
                return encrypted.base64EncodedString()
            case .hex:
                return encrypted.map { String(format: "%02hhx", $0) }.joined()
            }
        } catch {
            ParserLog.debug("JavaBridge", "RSA encrypt failed: \(error.localizedDescription)")
            return ""
        }
    }

    func decryptString(_ value: Any, usePublicKey: Bool) -> String {
        guard let algorithm = transformation.decryptionAlgorithm else { return "" }
        let key = usePublicKey ? publicKey : privateKey
        let swCryptKey = usePublicKey ? publicKeyDERForSwCrypt : privateKeyDERForSwCrypt
        let inputData = decodeCipherInput(value)

        if usePublicKey,
           let swCryptKey {
            do {
                let decrypted = try transformRawWithPublicKey(secKey: key, derKey: swCryptKey, data: inputData)
                let string = decodeDecryptedText(decrypted)
                if !string.isEmpty {
                    ParserLog.debug("JavaBridge", "RSA decrypt succeeded via raw public-key transform fallback")
                    return string
                }
                let hexPreview = decrypted.prefix(32).map { String(format: "%02x", $0) }.joined()
                ParserLog.debug("JavaBridge", "RSA raw public-key transform produced empty output bytes=\(decrypted.count) preview=\(hexPreview)")
            } catch {
                ParserLog.debug("JavaBridge", "RSA raw public-key transform failed: \(error.localizedDescription)")
            }
        }

        if usePublicKey,
           let swCryptKey,
           let decrypted = try? decryptWithSwCrypt(
            data: inputData,
            derKey: swCryptKey,
            secKey: key
           ) {
            let string = decodeDecryptedText(decrypted)
            if !string.isEmpty {
                ParserLog.debug("JavaBridge", "RSA decrypt succeeded via SwCrypt public-key fallback")
                return string
            }
        }

        if let key {
            do {
                let decrypted = try transform(
                    key: key,
                    data: inputData,
                    algorithm: algorithm,
                    operation: .decrypt
                )
                return decodeDecryptedText(decrypted)
            } catch {
                ParserLog.debug("JavaBridge", "RSA decrypt failed: \(error.localizedDescription)")
            }
        }

        guard let swCryptKey else { return "" }
        do {
            let decrypted = try decryptWithSwCrypt(data: inputData, derKey: swCryptKey, secKey: key)
            return decodeDecryptedText(decrypted)
        } catch {
            ParserLog.debug("JavaBridge", "RSA decrypt fallback failed: \(error.localizedDescription)")
            return ""
        }
    }

    private func decodeDecryptedText(_ data: Data) -> String {
        if let string = String(data: data, encoding: .utf8), !string.isEmpty {
            return string
        }

        let tolerantUTF8 = String(decoding: data, as: UTF8.self)
        return tolerantUTF8 == "\u{FFFD}" ? "" : tolerantUTF8
    }

    private struct KeyMaterial {
        let secKey: SecKey?
        let derKeyForSwCrypt: Data?
    }

    private func createKeyMaterial(from rawValue: Any, isPublic: Bool) -> KeyMaterial {
        let derKeyForSwCrypt = createSwCryptKey(from: rawValue, isPublic: isPublic)
        let secKey = createSecKeyMaterial(from: rawValue, isPublic: isPublic)
        return KeyMaterial(secKey: secKey, derKeyForSwCrypt: derKeyForSwCrypt)
    }

    private func createSecKeyMaterial(from rawValue: Any, isPublic: Bool) -> SecKey? {
        if let directData = normalizeInputData(rawValue), !directData.isEmpty {
            if let key = createSecKey(from: directData, isPublic: isPublic) {
                return key
            }
            let wrapped = isPublic ? wrapPublicKey(directData) : wrapPrivateKey(directData)
            if let wrapped,
               let key = createSecKey(from: wrapped, isPublic: isPublic) {
                return key
            }
        }

        let stringValue = String(describing: rawValue)
        let normalized = normalizePEM(stringValue)
        guard !normalized.isEmpty else { return nil }

        let keyData = Data(base64Encoded: normalized, options: .ignoreUnknownCharacters) ?? Data(stringValue.utf8)
        if let key = createSecKey(from: keyData, isPublic: isPublic) {
            return key
        }

        if !normalized.contains("BEGIN") {
            let wrapped = isPublic ? wrapPublicKey(keyData) : wrapPrivateKey(keyData)
            if let wrapped,
               let key = createSecKey(from: wrapped, isPublic: isPublic) {
                return key
            }
        }

        ParserLog.debug("JavaBridge", "RSA key parse failed after fallback attempts")
        return nil
    }

    private func createSwCryptKey(from rawValue: Any, isPublic: Bool) -> Data? {
        if let directData = normalizeInputData(rawValue), !directData.isEmpty,
           let normalized = normalizeSwCryptDER(directData, isPublic: isPublic) {
            return normalized
        }

        let stringValue = String(describing: rawValue).trimmingCharacters(in: .whitespacesAndNewlines)
        guard !stringValue.isEmpty else { return nil }

        if stringValue.contains("BEGIN") {
            do {
                return try isPublic
                    ? SwKeyConvert.PublicKey.pemToPKCS1DER(stringValue)
                    : SwKeyConvert.PrivateKey.pemToPKCS1DER(stringValue)
            } catch {
                ParserLog.debug("JavaBridge", "SwCrypt PEM parse failed: \(error.localizedDescription)")
            }
        }

        let normalized = normalizePEM(stringValue)
        guard !normalized.isEmpty,
              let keyData = Data(base64Encoded: normalized, options: .ignoreUnknownCharacters),
              !keyData.isEmpty else {
            return nil
        }

        return normalizeSwCryptDER(keyData, isPublic: isPublic)
    }

    private func normalizeSwCryptDER(_ keyData: Data, isPublic: Bool) -> Data? {
        if isPublic {
            if let pkcs1 = PKCS8.PublicKey.stripHeaderIfAny(keyData) {
                return pkcs1
            }
            return PKCS8.PublicKey.getPKCS1DEROffset(keyData) == 0 ? keyData : nil
        } else {
            return PKCS8.PrivateKey.stripHeaderIfAny(keyData)
        }
    }

    private func decodeCipherInput(_ value: Any) -> Data {
        if let normalizedData = normalizeInputData(value) {
            return normalizedData
        }

        let stringValue = String(describing: value)
        if let base64 = Data(base64Encoded: stringValue, options: .ignoreUnknownCharacters), !base64.isEmpty {
            return base64
        }
        if stringValue.count.isMultiple(of: 2), stringValue.allSatisfy(\.isHexDigit) {
            var bytes: [UInt8] = []
            var index = stringValue.startIndex
            while index < stringValue.endIndex {
                let next = stringValue.index(index, offsetBy: 2)
                guard let byte = UInt8(stringValue[index..<next], radix: 16) else { break }
                bytes.append(byte)
                index = next
            }
            if !bytes.isEmpty {
                return Data(bytes)
            }
        }
        return Data(stringValue.utf8)
    }

    private func transformRawWithPublicKey(secKey: SecKey?, derKey: Data, data: Data) throws -> Data {
        let blockSize: Int
        if let secKey {
            let size = SecKeyGetBlockSize(secKey)
            blockSize = size > 0 ? size : (try CC.RSA.rawCrypt(data.prefix(256), derKey: derKey).1)
        } else {
            blockSize = try CC.RSA.rawCrypt(data.prefix(256), derKey: derKey).1
        }
        guard blockSize > 0, data.count >= blockSize, data.count.isMultiple(of: blockSize) else {
            throw ParserError.javascriptError("Invalid RSA raw public-key input size")
        }

        var output = Data()
        var index = 0
        while index < data.count {
            let endIndex = index + blockSize
            let chunk = data.subdata(in: index..<endIndex)
            let transformed: Data
            if let secKey,
               SecKeyIsAlgorithmSupported(secKey, .encrypt, .rsaEncryptionRaw),
               let rawData = SecKeyCreateEncryptedData(secKey, .rsaEncryptionRaw, chunk as CFData, nil) as Data? {
                transformed = rawData
            } else {
                transformed = try CC.RSA.rawCrypt(chunk, derKey: derKey).0
            }
            output.append(trimLeadingZeroBytes(from: transformed))
            index = endIndex
        }
        return output
    }

    private func trimLeadingZeroBytes(from data: Data) -> Data {
        guard let firstNonZeroIndex = data.firstIndex(where: { $0 != 0 }) else {
            return Data()
        }
        return data.subdata(in: firstNonZeroIndex..<data.endIndex)
    }

    private func decryptWithSwCrypt(data: Data, derKey: Data, secKey: SecKey?) throws -> Data {
        guard transformation.algorithm.uppercased() == "RSA" else {
            throw ParserError.javascriptError("SwCrypt only supports RSA fallback")
        }
        guard CC.RSA.available() else {
            throw ParserError.javascriptError("SwCrypt RSA is unavailable")
        }

        let blockSize = rsaBlockSize(for: data, secKey: secKey)
        guard blockSize > 0 else {
            throw ParserError.javascriptError("Invalid RSA block size for SwCrypt")
        }

        var output = Data()
        var index = 0
        while index < data.count {
            let endIndex = min(index + blockSize, data.count)
            let chunk = data.subdata(in: index..<endIndex)
            let decrypted = try CC.RSA.decrypt(
                chunk,
                derKey: derKey,
                tag: Data(),
                padding: transformation.swCryptPadding,
                digest: transformation.swCryptDigest
            ).0
            output.append(decrypted)
            index = endIndex
        }
        return output
    }

    private func rsaBlockSize(for data: Data, secKey: SecKey?) -> Int {
        if let secKey {
            let size = SecKeyGetBlockSize(secKey)
            if size > 0 {
                return size
            }
        }

        for candidate in [512, 384, 256, 128] where data.count >= candidate && data.count.isMultiple(of: candidate) {
            return candidate
        }

        if let inferredKeySize = inferredRSAKeySize(from: data) {
            return inferredKeySize / 8
        }

        return data.count
    }

    private func normalizeInputData(_ value: Any) -> Data? {
        switch value {
        case let data as Data:
            return data
        case let bytes as [UInt8]:
            return Data(bytes)
        case let numbers as [NSNumber]:
            return Data(numbers.map { UInt8(truncating: $0) })
        case let array as NSArray:
            let numbers = array.compactMap { element -> NSNumber? in
                if let number = element as? NSNumber {
                    return number
                }
                if let intValue = element as? Int {
                    return NSNumber(value: intValue)
                }
                return nil
            }
            guard numbers.count == array.count else { return nil }
            return Data(numbers.map { UInt8(truncating: $0) })
        case let string as String:
            if let base64 = Data(base64Encoded: string, options: .ignoreUnknownCharacters), !base64.isEmpty {
                return base64
            }
            return nil
        default:
            return nil
        }
    }

    private func createSecKey(from keyData: Data, isPublic: Bool) -> SecKey? {
        let keyClass = isPublic ? kSecAttrKeyClassPublic : kSecAttrKeyClassPrivate
        let candidateAttributes: [[String: Any]] = [
            [
                kSecAttrKeyType as String: kSecAttrKeyTypeRSA,
                kSecAttrKeyClass as String: keyClass
            ],
            [
                kSecAttrKeyType as String: kSecAttrKeyTypeRSA,
                kSecAttrKeyClass as String: keyClass,
                kSecAttrKeySizeInBits as String: inferredRSAKeySize(from: keyData) ?? max(1024, keyData.count * 8)
            ],
            [
                kSecAttrKeyType as String: kSecAttrKeyTypeRSA,
                kSecAttrKeyClass as String: keyClass,
                kSecAttrKeySizeInBits as String: 2048
            ],
            [
                kSecAttrKeyType as String: kSecAttrKeyTypeRSA,
                kSecAttrKeyClass as String: keyClass,
                kSecAttrKeySizeInBits as String: 1024
            ],
            [
                kSecAttrKeyType as String: kSecAttrKeyTypeRSA,
                kSecAttrKeyClass as String: keyClass,
                kSecAttrKeySizeInBits as String: 4096
            ]
        ]

        for attributes in candidateAttributes {
            var error: Unmanaged<CFError>?
            if let key = SecKeyCreateWithData(keyData as CFData, attributes as CFDictionary, &error) {
                return key
            }
        }
        return nil
    }

    private func inferredRSAKeySize(from keyData: Data) -> Int? {
        if let first = keyData.first {
            switch first {
            case 0x30 where keyData.count >= 256:
                return [1024, 2048, 3072, 4096].first { abs(keyData.count - ($0 / 8)) <= 38 }
            case 0x02 where keyData.count >= 128:
                return [1024, 2048, 3072, 4096].first { abs(keyData.count - ($0 / 8)) <= 8 }
            default:
                break
            }
        }

        return [1024, 2048, 3072, 4096].first { abs(keyData.count - ($0 / 8)) <= 8 }
    }

    private func normalizePEM(_ value: String) -> String {
        value
            .replacingOccurrences(of: "-----BEGIN PUBLIC KEY-----", with: "")
            .replacingOccurrences(of: "-----END PUBLIC KEY-----", with: "")
            .replacingOccurrences(of: "-----BEGIN PRIVATE KEY-----", with: "")
            .replacingOccurrences(of: "-----END PRIVATE KEY-----", with: "")
            .replacingOccurrences(of: "-----BEGIN RSA PRIVATE KEY-----", with: "")
            .replacingOccurrences(of: "-----END RSA PRIVATE KEY-----", with: "")
            .components(separatedBy: .whitespacesAndNewlines)
            .joined()
    }

    private func wrapPublicKey(_ data: Data) -> Data? {
        let header: [UInt8] = [
            0x30, 0x82, 0x01, 0x22,
            0x30, 0x0d,
            0x06, 0x09, 0x2a, 0x86, 0x48, 0x86, 0xf7, 0x0d, 0x01, 0x01, 0x01,
            0x05, 0x00,
            0x03, 0x82, 0x01, 0x0f, 0x00
        ]

        guard data.count >= 128 else { return nil }
        return Data(header) + data
    }

    private func wrapPrivateKey(_ data: Data) -> Data? {
        // Security.framework accepts PKCS#8 directly. For bare PKCS#1 we keep current bytes.
        data
    }

    private enum Operation {
        case encrypt
        case decrypt
    }

    private func transform(key: SecKey, data: Data, algorithm: SecKeyAlgorithm, operation: Operation) throws -> Data {
        let secOperation: SecKeyOperationType = operation == .encrypt ? .encrypt : .decrypt
        guard SecKeyIsAlgorithmSupported(key, secOperation, algorithm) else {
            throw ParserError.javascriptError("RSA algorithm not supported: \(transformation.rawValue)")
        }

        if let result = try transformSingleBlock(key: key, data: data, algorithm: algorithm, operation: operation) {
            return result
        }

        let blockSize = SecKeyGetBlockSize(key)
        guard blockSize > 0, data.count > blockSize else {
            throw ParserError.javascriptError("RSA operation failed")
        }

        let chunkSize: Int
        switch operation {
        case .decrypt:
            chunkSize = blockSize
        case .encrypt:
            chunkSize = maxInputBlockSize(for: algorithm, blockSize: blockSize)
        }
        guard chunkSize > 0 else {
            throw ParserError.javascriptError("RSA invalid chunk size")
        }

        ParserLog.debug(
            "JavaBridge",
            "RSA chunked \(operation == .encrypt ? "encrypt" : "decrypt") blockSize=\(blockSize) chunkSize=\(chunkSize) input=\(data.count)"
        )

        var output = Data()
        var index = 0
        while index < data.count {
            let endIndex = min(index + chunkSize, data.count)
            let chunk = data.subdata(in: index..<endIndex)
            if let transformed = try transformSingleBlock(key: key, data: chunk, algorithm: algorithm, operation: operation) {
                output.append(transformed)
            } else {
                throw ParserError.javascriptError("RSA chunk transform failed")
            }
            index = endIndex
        }
        return output
    }

    private func transformSingleBlock(
        key: SecKey,
        data: Data,
        algorithm: SecKeyAlgorithm,
        operation: Operation
    ) throws -> Data? {
        var error: Unmanaged<CFError>?
        let result: CFData?
        switch operation {
        case .encrypt:
            result = SecKeyCreateEncryptedData(key, algorithm, data as CFData, &error)
        case .decrypt:
            result = SecKeyCreateDecryptedData(key, algorithm, data as CFData, &error)
        }

        if let result {
            return result as Data
        }

        if let error {
            let nsError = error.takeRetainedValue() as Error
            switch operation {
            case .decrypt where data.count > SecKeyGetBlockSize(key):
                return nil
            case .encrypt where data.count > maxInputBlockSize(for: algorithm, blockSize: SecKeyGetBlockSize(key)):
                return nil
            default:
                throw nsError
            }
        }

        return nil
    }

    private func maxInputBlockSize(for algorithm: SecKeyAlgorithm, blockSize: Int) -> Int {
        switch algorithm {
        case .rsaEncryptionRaw:
            return blockSize
        case .rsaEncryptionPKCS1:
            return max(1, blockSize - 11)
        case .rsaEncryptionOAEPSHA1:
            return max(1, blockSize - 42)
        case .rsaEncryptionOAEPSHA224:
            return max(1, blockSize - 58)
        case .rsaEncryptionOAEPSHA256:
            return max(1, blockSize - 66)
        case .rsaEncryptionOAEPSHA384:
            return max(1, blockSize - 98)
        case .rsaEncryptionOAEPSHA512:
            return max(1, blockSize - 130)
        default:
            return max(1, blockSize - 11)
        }
    }
}

private nonisolated struct AsymmetricTransformation {
    let rawValue: String
    let algorithm: String
    let padding: String

    static func parse(_ transformation: String) -> AsymmetricTransformation {
        let normalized = transformation.trimmingCharacters(in: .whitespacesAndNewlines)
        let upper = normalized.uppercased().replacingOccurrences(of: "RSA/ECB/", with: "RSA/")
        let parts = upper.split(separator: "/", omittingEmptySubsequences: false).map(String.init)
        let algorithm = parts.first ?? "RSA"
        let padding = parts.count > 1 ? parts.dropFirst().joined(separator: "/") : "PKCS1"
        return AsymmetricTransformation(rawValue: normalized, algorithm: algorithm, padding: padding)
    }

    var encryptionAlgorithm: SecKeyAlgorithm? {
        switch normalizedPadding {
        case "PKCS1", "PKCS1PADDING":
            return .rsaEncryptionPKCS1
        case "OAEP", "OAEPWITHSHA1ANDMGF1PADDING":
            return .rsaEncryptionOAEPSHA1
        case "OAEPWITHSHA224ANDMGF1PADDING":
            if #available(iOS 14.0, macOS 11.0, *) {
                return .rsaEncryptionOAEPSHA224
            }
            return .rsaEncryptionOAEPSHA1
        case "OAEPWITHSHA256ANDMGF1PADDING", "OAEPWITHSHA256":
            return .rsaEncryptionOAEPSHA256
        case "OAEPWITHSHA384ANDMGF1PADDING":
            return .rsaEncryptionOAEPSHA384
        case "OAEPWITHSHA512ANDMGF1PADDING":
            return .rsaEncryptionOAEPSHA512
        default:
            return .rsaEncryptionPKCS1
        }
    }

    var decryptionAlgorithm: SecKeyAlgorithm? {
        encryptionAlgorithm
    }

    var swCryptPadding: CC.RSA.AsymmetricPadding {
        switch normalizedPadding {
        case "OAEP", "OAEPWITHSHA1ANDMGF1PADDING", "OAEPWITHSHA224ANDMGF1PADDING", "OAEPWITHSHA256ANDMGF1PADDING",
             "OAEPWITHSHA256", "OAEPWITHSHA384ANDMGF1PADDING", "OAEPWITHSHA512ANDMGF1PADDING":
            return .oaep
        default:
            return .pkcs1
        }
    }

    var swCryptDigest: CC.DigestAlgorithm {
        switch normalizedPadding {
        case "OAEPWITHSHA224ANDMGF1PADDING":
            return .sha224
        case "OAEPWITHSHA256ANDMGF1PADDING", "OAEPWITHSHA256":
            return .sha256
        case "OAEPWITHSHA384ANDMGF1PADDING":
            return .sha384
        case "OAEPWITHSHA512ANDMGF1PADDING":
            return .sha512
        case "OAEP", "OAEPWITHSHA1ANDMGF1PADDING":
            return .sha1
        default:
            return .none
        }
    }

    private var normalizedPadding: String {
        padding.uppercased().replacingOccurrences(of: "-", with: "")
    }
}

private nonisolated enum SymmetricCryptoError: LocalizedError {
    case invalidInput
    case invalidKeySize
    case cryptFailure(CCCryptorStatus)

    var errorDescription: String? {
        switch self {
        case .invalidInput:
            return "invalid crypto input"
        case .invalidKeySize:
            return "invalid key size"
        case .cryptFailure(let status):
            return "CommonCrypto failure status=\(status)"
        }
    }
}

private nonisolated struct SymmetricTransformation {
    let algorithm: SymmetricAlgorithm
    let mode: SymmetricMode
    let padding: SymmetricPadding

    var blockSize: Int {
        algorithm.blockSize
    }

    static func parse(_ transformation: String) -> SymmetricTransformation {
        let parts = transformation.uppercased().split(separator: "/", omittingEmptySubsequences: false).map(String.init)
        let algorithm = SymmetricAlgorithm(rawValue: parts.indices.contains(0) ? parts[0] : "AES") ?? .aes
        let mode = SymmetricMode(rawValue: parts.indices.contains(1) ? parts[1] : "CBC") ?? .cbc
        let padding = SymmetricPadding(rawValue: parts.indices.contains(2) ? parts[2] : "PKCS5PADDING") ?? .pkcs7
        return SymmetricTransformation(algorithm: algorithm, mode: mode, padding: padding)
    }
}

private nonisolated enum SymmetricAlgorithm: String {
    case aes = "AES"
    case aes128 = "AES128"
    case aes192 = "AES192"
    case aes256 = "AES256"
    case des = "DES"
    case desEde = "DESEDE"
    case tripleDES = "3DES"
    case tripleDESAlt = "TRIPLEDES"
    case blowfish = "BLOWFISH"

    var ccAlgorithm: CCAlgorithm {
        switch self {
        case .aes, .aes128, .aes192, .aes256:
            return CCAlgorithm(kCCAlgorithmAES)
        case .des:
            return CCAlgorithm(kCCAlgorithmDES)
        case .desEde, .tripleDES, .tripleDESAlt:
            return CCAlgorithm(kCCAlgorithm3DES)
        case .blowfish:
            return CCAlgorithm(kCCAlgorithmBlowfish)
        }
    }

    var blockSize: Int {
        switch self {
        case .aes, .aes128, .aes192, .aes256:
            return kCCBlockSizeAES128
        case .des:
            return kCCBlockSizeDES
        case .desEde, .tripleDES, .tripleDESAlt:
            return kCCBlockSize3DES
        case .blowfish:
            return kCCBlockSizeBlowfish
        }
    }

    func requiredKeyLength(for currentLength: Int) -> Int {
        switch self {
        case .aes:
            if currentLength >= kCCKeySizeAES256 { return kCCKeySizeAES256 }
            if currentLength >= kCCKeySizeAES192 { return kCCKeySizeAES192 }
            return kCCKeySizeAES128
        case .aes128:
            return kCCKeySizeAES128
        case .aes192:
            return kCCKeySizeAES192
        case .aes256:
            return kCCKeySizeAES256
        case .des:
            return kCCKeySizeDES
        case .desEde, .tripleDES, .tripleDESAlt:
            return kCCKeySize3DES
        case .blowfish:
            let clamped = max(kCCKeySizeMinBlowfish, min(currentLength, kCCKeySizeMaxBlowfish))
            return clamped
        }
    }
}

private nonisolated enum SymmetricMode: String {
    case ecb = "ECB"
    case cbc = "CBC"
    case cfb = "CFB"
    case ofb = "OFB"
    case ctr = "CTR"

    var ccMode: CCMode {
        switch self {
        case .ecb:
            return CCMode(kCCModeECB)
        case .cbc:
            return CCMode(kCCModeCBC)
        case .cfb:
            return CCMode(kCCModeCFB)
        case .ofb:
            return CCMode(kCCModeOFB)
        case .ctr:
            return CCMode(kCCModeCTR)
        }
    }

    var usesIV: Bool {
        self != .ecb
    }
}

private nonisolated enum SymmetricPadding: String {
    case pkcs5 = "PKCS5PADDING"
    case pkcs7 = "PKCS7PADDING"
    case none = "NOPADDING"
    case noneAlt = "NONE"
    case zero = "ZEROPADDING"

    var ccPadding: CCPadding {
        switch self {
        case .pkcs5, .pkcs7:
            return CCPadding(ccPKCS7Padding)
        case .none, .noneAlt, .zero:
            return CCPadding(ccNoPadding)
        }
    }
}
#endif
