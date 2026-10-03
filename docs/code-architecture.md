# 代码架构与放置规则

本文档说明代码应该加在现有位置，还是新建文件。它优先回答"这段逻辑属于谁"，
而不是"哪个文件还没超行数"。

## 分层与目录职责

| 目录 | 职责 |
| --- | --- |
| `lib/app/` | 应用外壳：主题、构建配置、更新链接、根组件 |
| `lib/controllers/` | 录制与会话状态机；按职责拆成 `packing_session_*.dart` 若干部分 |
| `lib/services/` | 与界面无关的业务服务与协议实现（备份、识别、语音、存储、诊断） |
| `lib/models/` | 数据模型与纯策略（判定表、筛选、命名规则） |
| `lib/platform/` | 能力声明 `platform_capabilities.dart`、契约 `contracts/`、适配器 `adapters/`、生成物 `generated/` |
| `lib/screens/` | 页面与交互编排：读状态、接回调、排版，不塞业务规则 |
| `lib/widgets/` | 可复用控件与一组控件的组合 |
| `ios/Runner/` | iOS 宿主与平台实现；每个能力一个 `Ios*Platform.swift`（或按职责再拆） |
| `ios/RunnerTests/` | iOS 原生单测 |
| `android/app/src/main/kotlin/app/packingproof/mobile/` | Android 原生实现，每个能力一个类文件 |
| `test/` / `integration_test/` | 单元与 widget 回归 / 设备级流程 |
| `tool/` / `Tools/` | 本地 CI 检查脚本 / 构建与发布脚本 |
| `pigeons/` | Pigeon 接口定义（生成物禁止手改） |

## 加代码前先问三个问题

1. **职责**：这段逻辑属于哪个既有单元？是它的延续，还是新的一类事情？
2. **生命周期与依赖**：它需要独立的队列、会话、任务或原生对象吗？如果和宿主
   文件的生命周期绑在一起，放同一个文件；如果需要自己的一套，独立成文件。
3. **复用**：第二个调用方会不会用到它？会，就放到 `lib/widgets/` 或
   `lib/services/` 这类共享位置。

## 放置决策

| 情况 | 放哪里 |
| --- | --- |
| 页面里的交互编排（读状态、调回调、排版） | 留在对应 `lib/screens/<页面>.dart` |
| 同组控件（搜索+筛选、卡片+操作按钮） | 新建一个文件装整组，不要按控件切碎 |
| 会被两处以上复用的控件 | `lib/widgets/<控件>.dart` |
| 纯策略、判定表、命名与筛选规则 | `lib/models/` 或 `lib/services/` 下的小文件 |
| 状态机的一小段逻辑（同一职责延续） | 追加到对应 `lib/controllers/packing_session_*.dart` |
| 新平台能力 | 三处同时补：`PlatformCapabilities`、`lib/platform/adapters|contracts`、`ios/Runner/Ios*Platform.swift` 与 Android 对应类 |
| 原生侧一类新的服务（有自己的队列/端口/会话） | 新增原生文件，例如订单接收服务 → `ios/Runner/IosOrderReceiverPlatform.swift` |

判断口径：**一组控件整体搬，一类职责整体搬**。只搬一半（比如把搜索框搬走、
筛选留下）会让同一件事散在两个文件里，比行数超标更难维护。

## 大文件守门脚本的定位

`tool/check_large_file_limits.sh` **只提示，不阻断合并**：它是"这些文件已经很大，
留意别再涨"的提醒，不是行数美学，也不是"拆得越碎越好"。

- 基线 + 余量（基线 2%，最少 20 行）是留意线：用掉余量或超过余量都会在 CI 日志里
  打印建议，但**退出码始终为 0**，不会拦住任何提交；
- 提示里出现"已超过基线"时，说明该文件确实在持续膨胀，建议按职责整体拆分，并把
  基线同步下调到拆分后的行数；
- 不要为了消除提示而提高基线，也不要把一组控件硬拆成两个文件凑数；
- 拆分后新文件同样登记基线，避免换个地方继续膨胀。

近期拆分实例：

- `ios/Runner/PigeonPlatform.swift` 992 → 551 行：440 行的订单接收服务（本地 TCP
  收单）整体挪到 `ios/Runner/IosOrderReceiverPlatform.swift`；
- `lib/screens/recordings_screen.dart` 1527 → 1482 行：历史页的搜索框与筛选胶囊
  合成 `lib/widgets/recording_history_filters.dart`，屏幕只传状态与回调；
- 终止纪律：每个会向 Dart 推事件的宿主各自实现 `prepareForTermination()`，由
  `PigeonPlatform.shutdownForTermination()` 统一调用，而不是把逻辑堆到调用方。

## 提交与合并纪律

- 改完先在当前机器跑 `./Tools/test-ci.sh`，再推分支；
- **等 GitHub CI 两个 job 都绿再合并**：本地 CI 只跑当前机器那一半，Windows 的
  Android 原生单测、macOS 的 golden 与 RunnerTests 都要各自跑通；
- 合并走 fast-forward，不 squash；GitHub 与 Gitee 的 `main` 保持同一个提交哈希；
- 一条提交只做一件事：功能、修复、重构、文档、测试不要混在同一个提交里。
