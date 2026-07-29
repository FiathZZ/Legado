import Foundation

struct BookSource: Codable {
    let bookSourceName: String
    let bookSourceUrl: String
    let bookSourceGroup: String?
    let searchUrl: String?
}

func testSource(_ source: BookSource) async -> (Bool, String) {
    guard let url = URL(string: source.bookSourceUrl) else {
        return (false, "URL无效")
    }

    var request = URLRequest(url: url, timeoutInterval: 5)
    request.httpMethod = "HEAD"

    do {
        let (_, response) = try await URLSession.shared.data(for: request)
        if let http = response as? HTTPURLResponse, (200...399).contains(http.statusCode) {
            return (true, "连通")
        }
        return (false, "无响应")
    } catch {
        return (false, "超时/失败")
    }
}

let path = "/Users/songming/Downloads/书源.json"
guard let data = try? Data(contentsOf: URL(fileURLWithPath: path)),
      let sources = try? JSONDecoder().decode([BookSource].self, from: data) else {
    print("无法读取书源文件")
    exit(1)
}

let filtered = sources.filter {
    $0.bookSourceName.contains("笔趣阁") || ($0.bookSourceGroup?.contains("精选") ?? false)
}

print("开始测试 \(filtered.count) 个书源...\n")

var success = 0
for (i, source) in filtered.enumerated() {
    let (ok, msg) = await testSource(source)
    if ok { success += 1 }
    let icon = ok ? "✓" : "✗"
    print("\(i+1). \(icon) \(source.bookSourceName) - \(msg)")
}

let rate = Int(Double(success) / Double(filtered.count) * 100)
print("\n成功率: \(success)/\(filtered.count) = \(rate)%")
