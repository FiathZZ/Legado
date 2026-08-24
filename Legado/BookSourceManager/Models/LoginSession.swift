import Foundation

// MARK: - LoginSession
/// 书源登录会话快照。
nonisolated struct LoginSession: Codable, Sendable {
    /// 书源唯一键。
    let sourceURL: String
    /// 登录成功时间。
    let loggedInAt: Date
    /// 最近一次成功校验时间。
    var lastValidatedAt: Date?
    /// 提交时的表单值快照。
    var values: [String: String]
}

// MARK: - LoginFormDefinition
/// 书源登录表单定义。
nonisolated struct LoginFormDefinition: Codable, Sendable {
    /// 表单字段。
    let fields: [LoginFieldDefinition]
    /// 额外扩展字段。
    let extras: [String: String]
}

// MARK: - LoginFieldDefinition
/// 登录字段定义，兼容 Android `RowUi` 的最小子集。
nonisolated struct LoginFieldDefinition: Codable, Identifiable, Sendable {
    enum FieldType: String, Codable {
        case text
        case password
        case hidden
        case captcha
        case button
    }

    let id: String
    let name: String
    let type: FieldType
    let action: String?
    let value: String?
    let extras: [String: String]
}
