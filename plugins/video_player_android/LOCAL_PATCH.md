# video_player_android 本地补丁基线

## 上游基线

- 包：`video_player_android 2.12.0`
- 上游仓库：`https://github.com/flutter/packages`
- 上游 tag：`video_player_android-v2.12.0`
- tag commit：`d3de31ab3425f52afbc7c54a681ec3d93632baf6`
- 上游目录：`packages/video_player/video_player_android`

本目录来自上游发布包，只保留应用构建需要的文件；发布包中的 `example/`、
`pigeons/`、Dart `test/` 和原有 Android 测试没有复制进来。本地新增的聚焦测试
只覆盖本补丁策略。

## 最小差异

补丁仅允许以下差异：

1. 新增 `HuaweiCompatibility.java`，仅对 `HUAWEI`/`HONOR` 且 API 30+
   返回“优先软件解码”
2. `TextureVideoPlayer.java` 与 `PlatformViewVideoPlayer.java` 使用
   `DefaultRenderersFactory` 开启 decoder fallback，并在上述机型选择
   `MediaCodecSelector.PREFER_SOFTWARE`
3. `pubspec.yaml` 增加 `publish_to: none` 和本地补丁说明
4. 新增 `HuaweiCompatibilityTest.java`，锁定厂商与 API 边界

`LOCAL_PATCH.sha256` 固定这些补丁文件的内容；除上述文件外，本地构建面必须与
精确上游 commit 完全一致。

## 保留补丁的依据

- `flutter/flutter#185674`：开放，华为 P30 Pro/Lite 仍有
  `MediaCodecVideoRenderer` 异常，且缺少维护者可复现设备
- `flutter/flutter#177912`：已关闭，只覆盖特定 Kirin buffer allocation 问题
- `flutter/flutter#166481`：已关闭，结论针对 Android 29 播放问题
- `androidx/media#1668`：已关闭，针对特定 MP4 stream，不能证明目标设备已修复

这些结论不足以证明目标华为/荣耀设备的厂商硬解已普遍修复，因此没有目标真机
验证前不得删除 workaround。

## 漂移检查与升级

在仓库根目录运行：

```bash
./tool/check_video_player_android_fork.sh
```

脚本默认从上述 commit 下载上游源码，也可离线指定已经检出的插件目录：

```bash
VIDEO_PLAYER_ANDROID_UPSTREAM_DIR=/path/to/video_player_android \
  ./tool/check_video_player_android_fork.sh
```

升级上游时必须单独提交，并依次执行：

1. 更新本文的版本、tag 和 commit
2. 用新版上游构建面替换本地副本，再只重放上述最小补丁
3. 更新检查脚本中的基线常量及 `LOCAL_PATCH.sha256`
4. 运行漂移检查、聚焦 Android 单测和应用相关回归测试
5. 在目标华为/荣耀真机验证 AVC、HEVC、本地文件和远程播放
