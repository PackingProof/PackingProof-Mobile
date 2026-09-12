# CLAUDE.md

本仓库的工程约定统一维护在 `AGENTS.md`，本文件只做引入与补充，避免两份规则漂移。

@AGENTS.md

## 使用本文件的方式

- 上面的 `@AGENTS.md` 会把仓库规范整篇加载进上下文：项目结构、产品约束、平台能力纪律、必读专项文档、测试与提交纪律。改动前按那份文档执行。
- 只有当某条规则仅对 Claude Code 生效时才写进本文件；属于全体 agent 的规则一律写回 `AGENTS.md`。

## 常用命令

- 静态检查：`flutter analyze`
- 单个测试文件（迭代时用）：`flutter test test/<file>_test.dart`
- 全量单元/控件测试：`flutter test`
- 设备级流程：`flutter test integration_test/`
- iOS 原生改动的快速语法校验：`xcrun swiftc -parse ios/Runner/IosCameraPlatform.swift`（只解析、不做类型检查，真正验证仍需 Xcode 构建）

## 工作方式补充

- 按 `AGENTS.md` 的"必读专项文档"一节，先读对应的 `docs/` 文档再动手；iOS、局域网备份、发布流程都有各自的强制文档。
- 每次行为变更都要补或改对应测试，提交前至少跑 `flutter analyze` 和相关测试文件，并在回复中如实说明哪些验证做了、哪些（例如真机录像、摄像头、权限）没做。
- 仓库根目录的 `flutter_*.log`、`build/`、`dist/` 是本地产物，不要提交，也不要当作参考资料。
- 用户可见文案整段结尾不加句号；代码注释与文档按现有中文风格书写。
