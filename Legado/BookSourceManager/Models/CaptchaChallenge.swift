import Foundation

// MARK: - CaptchaChallenge
/// 书源验证码挑战描述。
nonisolated struct CaptchaChallenge: Codable, Sendable {
    /// 验证码类型，例如 image / slider / token。
    let type: String
    /// 资源地址。
    let url: String?
    /// 透传元数据。
    let extras: [String: String]
}

// MARK: - CaptchaPayload
/// 验证码提交载荷。
nonisolated struct CaptchaPayload: Codable, Sendable {
    /// 用户输入值或外部令牌。
    let value: String
    /// 扩展字段。
    let extras: [String: String]
}

// MARK: - CaptchaResolver
/// 验证码解析扩展点。
protocol CaptchaResolver {
    /// 解析验证码挑战。
    func resolve(_ challenge: CaptchaChallenge) async throws -> CaptchaPayload
}

// MARK: - UnsupportedCaptchaResolver
/// 默认验证码解析器，当前不提供自动解题能力。
struct UnsupportedCaptchaResolver: CaptchaResolver {
    func resolve(_ challenge: CaptchaChallenge) async throws -> CaptchaPayload {
        throw ParserError.loginRequired("当前书源需要验证码（\(challenge.type)），但尚未提供验证码处理器")
    }
}
