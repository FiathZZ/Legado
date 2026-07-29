# SwiftLegado

SwiftLegado 是一个面向 iOS / macOS 的小说阅读器实验项目，目标是把 Android 开源阅读器 [legado（阅读）](https://github.com/gedoor/legado) 的书源生态移植到 Apple 平台，让同一套社区书源规则可以用于搜索、详情、目录、正文阅读与离线缓存。

> AI 生成声明：本仓库的架构设计、阶段规划、兼容性分析文档、部分源码实现与测试脚本由 AI 辅助生成和整理。代码与文档在开源前仍建议由维护者继续做人工审查、合规检查与实机验证。

## 当前状态

项目历史规划中的 Phase 1 - Phase 13 及其子任务已经完成、验收、关闭或归档。当前主线不再按固定 Phase 推进，而是进入滚动兼容运营阶段：

- 以 Android legado 全链路可通过的纯文字书源集合作为基线。
- 持续对齐 Android 的请求 runtime、规则 runtime、JS bridge、XPath / JSONPath / HTML 解析语义。
- 按“搜索有结果、详情可进、目录有效、正文可读”的全链路口径追赶 iOS 成功率。

当前维护中的基线书源文件：

```text
rss_compare_outputs/书源_miaogongziDY_filtered.json
```

最近一次整理出的滚动兼容重点见：

- `UPGRADE_ROADMAP.md`
- `docs/_working_note.md`
- `codex-prompts/README.md`
- `rss_compare_outputs/`

## 产品边界

SwiftLegado 的产品定位是免费、可换源、纯文字小说阅读器。

- 支持书源导入、搜索、详情、目录、正文阅读。
- 支持书架、阅读记录、目录缓存、章节正文离线缓存。
- 支持替换净化规则、主题、备份恢复、本地书、RSS 订阅源兼容等扩展能力。
- 不规划新的语音 / 音频、视频、漫画能力；仓库中已有相关历史实现仅作为兼容留存。
- 不支持付费内容购买、解锁或付费流程。

## 技术栈

- 语言：Swift 5.9+
- UI：SwiftUI，部分历史阅读能力桥接 UIKit
- 持久化：SwiftData
- 网络：URLSession + Alamofire
- HTML：SwiftSoup，部分 XPath / HTML 场景使用 Kanna
- JavaScript：JavaScriptCore
- 加密：CommonCrypto + SwCrypt
- 本地 Web 服务：GCDWebServer
- 依赖管理：CocoaPods

## 构建方式

本项目使用 CocoaPods workspace 作为默认入口，不建议直接用 `swiftLegado.xcodeproj` 构建。

```bash
cd /path/to/swiftLegado
pod install
open swiftLegado.xcworkspace
```

命令行构建：

```bash
xcodebuild \
  -workspace swiftLegado.xcworkspace \
  -scheme swiftLegado \
  -destination 'platform=iOS Simulator,name=iPhone 16' \
  build
```

运行测试：

```bash
xcodebuild \
  -workspace swiftLegado.xcworkspace \
  -scheme swiftLegado \
  -destination 'platform=iOS Simulator,name=iPhone 16' \
  test
```

如果本机模拟器名称不同，先运行：

```bash
xcrun simctl list devices available
```

## 目录结构

```text
swiftLegado/
├── swiftLegado/                 # App 主源码
│   ├── LegadoSwiftParser/       # 书源解析核心，无 UI / SwiftData 依赖
│   ├── BookSourceManager/       # 书源导入、管理、调试、登录
│   ├── Search/                  # 多源搜索
│   ├── BookDetail/              # 详情页与目录入口
│   ├── Bookshelf/               # 书架、目录缓存、章节缓存
│   ├── Reader/                  # 阅读页业务层
│   ├── ReaderEngine/            # 自研纯文字阅读内核
│   ├── ReplaceRule/             # 替换净化规则
│   ├── RSS/                     # RSS 订阅源兼容
│   ├── Theme/                   # 主题、字体、主题管理
│   ├── Backup/                  # 备份恢复
│   ├── LocalBook/               # 本地书能力
│   ├── WebService/              # 本地 Web 管理服务
│   └── Settings/                # 设置入口
├── swiftLegadoTests/            # 单元测试与兼容性回归测试
├── docs/                        # 架构分析、验收报告、专项方案
├── codex-prompts/               # 历史阶段任务与滚动兼容任务文档
├── scripts/                     # Android / iOS 书源全量对比脚本
├── rss_compare_outputs/         # 书源对比结果、trace、基线数据
├── UPGRADE_ROADMAP.md           # 当前路线图与完成状态
├── AGENTS.md                    # AI Agent 工作规范
├── Podfile                      # CocoaPods 依赖
└── swiftLegado.xcworkspace      # 默认构建入口
```

## 核心解析架构

书源解析核心位于 `swiftLegado/LegadoSwiftParser/`，设计目标是尽量独立于 UI 与持久化层。

主链路：

```text
BookSource JSON
    ↓
WebBook / WebBookV2
    ↓
AnalyzeUrl / RequestRuntime / RequestExecutor
    ↓
HTTPClient / URLSession / Alamofire
    ↓
BookListParser / BookInfoParser / BookChapterParser / ChapterContentParser
    ↓
AnalyzeRule / RuleRuntime
    ↓
CSSParser / XPathParser / JSONPathParser / RegexParser / JavaScriptParser
```

重点能力：

- Android 风格 `AnalyzeUrl` 请求规则解析。
- 书源级 headers、POST form、JSON body、charset、redirect、cookie、rate limit。
- `@js:`、`<js>...</js>` 与 JavaScript bridge。
- CSS、XPath、JSONPath、Regex、组合规则链。
- 搜索、详情、目录、正文四阶段全链路解析。
- 运行级 compare trace，用于定位 Android 可通但 iOS 失败的书源。

## 历史版本与阶段演进

早期项目按阶段推进，当前这些阶段已经成为历史留档。完整任务说明保存在 `codex-prompts/`，验收和分析报告保存在 `docs/`。

| 阶段 | 状态 | 内容 |
|------|------|------|
| Phase 1 | 已完成 | 规则引擎、HTTP hardening、并发限速、ZIP、JS bridge quick wins、目录 formatJs |
| Phase 2 | 已完成 | 加密 bridge、搜索与详情体验优化 |
| Phase 3 | 已完成 | Headless WebView 渲染、TTF / WOFF 字体解密 |
| Phase 4 | 已完成 | 登录框架、高级 JS bridge、JSONPath inline、XPath 升级、历史音频 / 图片兼容 |
| Phase 5 | 已完成 | 书架增强、阅读页换源、目录状态、替换净化、统一设置 |
| Phase 6 | 已完成 | 线上 bugfix、目录 SwiftData 缓存、章节 txt 缓存 |
| Phase 7 | 已完成 | Response bridge、变量作用域、文件 bridge、签名与封面解密 |
| Phase 8 | 已关闭 | Android 深度对齐、发现页、书架分组、书签、备份恢复、批量操作 |
| Phase 9 | 已关闭 | 主题系统、本地书、Web 管理页、书源订阅、书源编辑器 |
| Phase 10 | 已关闭 | TTS、阅读统计、词典查询 |
| Phase 11 | 已归档 | 阅读页旧重构方案，后续被 Phase 12 吸收 |
| Phase 12 | 已完成 | 自研纯文字阅读内核替换与旧引擎迁移 |
| Phase 13 | 已收口 | 逐书源目录 / 正文兼容专项，演进为滚动兼容主线 |
| Phase 13H | 已收口后滚动推进 | Android 对齐式 parser / request / rule runtime 重构 |

当前阶段的核心不是继续增加 UI 功能，而是持续提升 Android 全通书源在 iOS 端的全链路成功率。近期专项包括：

- 搜索 `empty_result` 收口。
- 搜索成功后详情、目录、正文漏斗损耗收口。
- TOC runtime 差距修复。
- compare 模式下 WebView、JS 防爬、请求策略差异治理。

## 书源对比与基线维护

项目使用 `scripts/` 和 `rss_compare_outputs/` 做 Android / iOS 书源全量对比。

常用资料：

- `scripts/README_source_compare.md`：对比脚本说明。
- `rss_compare_outputs/*/parity_summary.json`：阶段对比摘要。
- `rss_compare_outputs/*/failure_clusters.md`：失败聚类。
- `rss_compare_outputs/*/*.trace.jsonl`：逐书源运行 trace。

维护原则：

1. Android 不能全链路通过的书源，不进入当前 iOS 追赶基线。
2. 每次完成新的全量 compare 后，按最新 Android full pass 输出重建 `rss_compare_outputs/书源_miaogongziDY_filtered.json`。
3. iOS 成功率按 Android full pass 分母计算，避免把站点失效误算为 iOS parser 缺陷。

## 文档索引

关键文档：

- `UPGRADE_ROADMAP.md`：项目完成状态、滚动 backlog、最新兼容目标。
- `docs/_working_note.md`：当前工作便签与最新实跑数据。
- `docs/user_bugs.md`：用户反馈与已关闭问题。
- `codex-prompts/README.md`：历史任务索引与当前激活任务。
- `docs/android_legado_source_parser_architecture_analysis_2026-05-09.md`：Android 书源解析架构分析。
- `docs/ios_current_source_parser_architecture_analysis_2026-05-09.md`：iOS 重构前解析架构分析。
- `docs/ios_refactored_source_parser_architecture_2026-05-09.md`：iOS 重构后解析架构。
- `docs/ios_post_search_funnel_loss_repair_plan_2026-05-11.md`：搜索后漏斗损耗修复方案。

## 开源前注意事项

开源前建议维护者至少检查以下事项：

- 补充明确的开源许可证文件，例如 `LICENSE`。
- 检查 `rss_compare_outputs/` 中是否包含不适合公开的站点 trace、cookie、header 或本地路径。
- 检查 `docs/`、`codex-prompts/` 中是否包含个人信息、本地环境路径或不宜公开的调试记录。
- 检查 `.vendor/Alamofire`、`Pods/`、第三方库缓存是否按预期纳入或排除版本控制。
- 确认 App 图标、字体、主题包和示例书源的版权状态。

## 免责声明

SwiftLegado 是 legado 书源生态的 iOS / macOS 移植实验项目，不隶属于 Android legado 官方项目。书源规则由社区维护，站点可用性、内容合法性与地区可访问性不由本项目保证。使用者应遵守当地法律法规和目标站点规则。

