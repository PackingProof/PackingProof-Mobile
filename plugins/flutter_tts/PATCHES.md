# 本地补丁

基于 flutter_tts 4.2.5（MIT），保留上游许可证和其他平台实现

- iOS 蓝牙选项改用同值的新名称 allowBluetoothHFP
- iOS 插件状态用 MainActor 隔离；Flutter 默认平台通道在主线程调用，使用 preconcurrency 协议桥接
- AVSpeechSynthesizerDelegate 入口不隔离，在入口读取进度字符串并仅将可传递值送回主线程，避免跨线程传递合成器和 utterance
- 未添加 unchecked Sendable 或关闭编译警告
- 2026-09-12 上游最新版本仍为 4.2.5；上游 PR #291 引入音频模式接口，但未解决当前 SDK 警告

需要真机复验播报、停止、暂停、完成回调与蓝牙音频路由
