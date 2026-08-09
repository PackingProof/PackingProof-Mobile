# 包裹留证

[中文](README.md) | [English](README_EN.md)

让每一件包裹都有可回看的打包证据。

包裹留证是一款面向电商商家和打包工作台的 Android 录像工具。手机固定在打包台后，点一次“开始工作”，应用便会持续录像、自动识别面单条码，并在识别到单号时打点标记。发生售后争议时，可按快递单号快速找到对应画面。

[下载最新版本](https://github.com/PackingProof/PackingProof-Mobile/releases)

<p align="center">
  <img src="docs/screenshots/history.jpg" alt="录像历史与快速查找" width="31%">
  <img src="docs/screenshots/home.jpg" alt="录制与面单识别" width="31%">
  <img src="docs/screenshots/settings.png" alt="设置" width="31%">
</p>

## 核心能力

- **一键开始工作**：保持摄像头预览和屏幕常亮，减少打包过程中的触屏操作
- **自动识别面单**：支持常见一维物流条码，识别后自动记录单号并打点，可按单号快速回放
- **两种工作模式**：连续扫码适合流水打包，同码停录适合一单一段的操作方式
- **快速查找证据**：在订单历史中按快递单号搜索，并直接跳转到对应录像位置
- **订单语音提醒**：可播报买家留言、卖家备注、商品信息和退款状态；退款触发醒目的工业警报音
- **电脑自动备份**：扫描电脑端二维码完成连接，在局域网内自动备份录像
- **灵活清理录像**：分别设置已备份和未备份录像的保留策略，兼顾证据安全与手机空间
- **本地优先**：无需注册账号，不依赖云端保存录像；订单和录像数据由自己的手机与电脑管理

## 使用方法

1. 安装应用并允许摄像头、麦克风等必要权限
2. 将手机固定在能够看清打包区域和面单的位置
3. 点击“开始工作”并正常打包
4. 面单进入画面后，应用自动识别快递单号并打点记录
5. 需要回看时进入“订单历史”，搜索快递单号并播放对应录像

如需电脑备份或订单语音提醒，请确保手机与电脑处于同一局域网，并按应用内提示完成连接。

## 适用场景

- 电商仓库与小型打包工作室
- 售后争议举证和错漏发核查
- 高价值、易损或定制商品的发货留档
- 希望使用闲置 Android 手机搭建低成本打包监控的商家

## 隐私说明

应用不要求账号登录，也不会主动把录像上传到云端。启用电脑备份时，录像只在已连接的局域网设备之间传输。请根据所在地法律法规和工作场所要求使用录像功能。

## 本地开发

需要 Flutter 3.44 或兼容的稳定版本。

```powershell
flutter pub get
flutter analyze
flutter test
flutter run
```

生成 Android 调试包：

```powershell
flutter build apk --debug
```

也可以双击根目录的 `双击构建Debug包.bat`：使用 Android 调试证书一键构建并输出到 `dist/android/PackingProof-Mobile-debug.apk`，无需任何签名配置。

生成本地诊断 APK（调试签名）：

```powershell
pwsh -NoProfile -File Tools\Build-Android.ps1
```

生成正式签名 APK：

```powershell
git tag v0.5.16+11016
pwsh -NoProfile -File Tools\Publish-Android.ps1 `
  -SigningDirectory <仓库外的签名目录>
```

正式发布脚本要求当前提交已有版本标签且工作区干净。推荐标签使用 `v<版本名>+<递增 versionCode>` 格式；例如 `v0.5.16+11016` 会生成版本 `0.5.16`、版本号 `11016`。签名目录中需包含密钥文件及 UTF-8 编码的 `签名凭据.txt`，目录必须位于仓库外。

`签名凭据.txt` 格式：

```text
密钥文件: app-release.jks
别名: <密钥别名>
密钥库密码: <密钥库密码>
密钥密码: <密钥密码>
```

脚本会生成或复用内置语音，依次运行静态检查和全部测试，再构建仅支持 `arm64-v8a` 的统一安装包。本地诊断包使用 Android 调试证书签名，可以直接安装，但不能覆盖正式签名版本，也不能用于正式发布。

在不提交的根目录 `.env` 中配置 `PACKING_PROOF_SIGNING_DIRECTORY=<仓库外的签名目录>` 后，双击 `双击构建Release包.bat` 可生成能够直接覆盖同一签名已安装版本的 Release 测试 APK。该脚本读取 `pubspec.yaml` 版本并覆盖固定位置的 `dist/android/PackingProof-Mobile.apk`，不创建 Git 标签或发布记录。

产物位于 `dist/android/`，包括 `PackingProof-Mobile.apk`、`SHA256SUMS.txt` 和 `build-manifest.json`，不会生成 ZIP 压缩包。
