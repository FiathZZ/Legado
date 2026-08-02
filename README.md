# Legado

Legado是一个面向iOS的小说阅读器实验项目，目标是将Android开源阅读器[legado（阅读）](https://github.com/gedoor/legado)的书源生态移植到Apple平台，让同一套社区书源规则可以用于搜索、详情、目录、正文阅读与离线缓存。iOS27正常运行

# 本APP只做阅读器

## 功能

- 导入和管理社区书源，支持多书源搜索。
- 浏览书籍详情、目录与正文，并支持阅读时切换可用书源。
- 提供书架、阅读进度、目录及章节离线缓存。
- 支持正文净化规则、主题与字体、本地书、RSS订阅和备份恢复等能力。

## 目录

```text
Legado/
├── Legado/                 # App源码
│   ├── LegadoSwiftParser/  # 书源解析与请求运行时
│   ├── BookSourceManager/  # 书源导入与管理
│   ├── Search/             # 多源搜索
│   ├── Bookshelf/          # 书架与缓存
│   ├── Reader/             # 阅读器
│   └── ReplaceRule/        # 正文净化规则
├── LegadoTests/            # 测试
├── Podfile                 # CocoaPods依赖定义
└── Legado.xcworkspace      # Xcode打开入口
```

## 致谢

本项目在早期实现中参考了[Apolla/swiftLegado](https://github.com/Apolla/swiftLegado)，并以Legado作为独立项目持续维护。

书源规则生态来源于Android开源项目[legado（阅读）](https://github.com/gedoor/legado)。本项目不隶属于Android legado官方；书源由社区维护，使用者应遵守当地法律法规及目标站点规则。
