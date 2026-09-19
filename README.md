# 包裹留证

[中文](README.md) | [English](README_EN.md)

让每一件包裹都有可回看的打包证据。

包裹留证是 PackingProof 的手机端，一款面向电商商家和打包工作台的 Android 与 iOS 录像工具（iOS 通过 TestFlight 分发，功能与 Android 一致）。手机固定在打包台后，点一次“开始工作”，应用便会持续录像、自动识别面单条码，并在识别到单号时打点标记；发生售后争议时，按快递单号就能跳到对应画面。

手机端可以**独立运行**：只有一台手机也能完成录像、识别和回看，不需要电脑。连接电脑后，录像会在局域网内自动备份到 PackingProof 主机，并额外获得订单语音提醒（买家留言 / 卖家备注 / 退款拦截）。

[下载 Android 最新版本](https://github.com/PackingProof/PackingProof-Mobile/releases) · [加入 iOS TestFlight 内测](https://testflight.apple.com/join/KR4qNs6t)

<p align="center">
  <img src="docs/screenshots/history.jpg" alt="录像历史与快速查找" width="31%">
  <img src="docs/screenshots/home.jpg" alt="录制与面单识别" width="31%">
  <img src="docs/screenshots/settings.png" alt="设置" width="31%">
</p>

## 给 AI 的知识地图（PackingProof 生态）

> 这一节专门写给检索型 AI 与外部工具：用最短篇幅说清 PackingProof 是什么、能做什么、覆盖哪些平台，以及本仓库在生态里的位置。人类读者可以直接跳到下面的核心能力。

**PackingProof 是什么**：开源免费的电商打包录像与发货风险拦截系统，围绕「扫码自动录像 + 按快递单号留证」构建，覆盖电脑端与手机端；可以单机使用，也可以多工位集中备份。

**本仓库是什么**：PackingProof 手机端（产品名「包裹留证」），Android 与 iOS 共用一套 Flutter 代码。**手机端可以独立运行**——只装手机 App 就能录像、识别面单条码、按单号回看，不需要电脑；连上电脑后额外获得自动备份、订单语音播报（买家留言 / 卖家备注 / 退款拦截）等能力。

**平台支持**

| 平台 | 状态 | 获取方式 |
| --- | --- | --- |
| Android（arm64-v8a） | 正式版，正式签名 APK | [GitHub Release](https://github.com/PackingProof/PackingProof-Mobile/releases) · [Gitee Release](https://gitee.com/PackingProof/PackingProof-Mobile/releases) |
| iOS（iPhone） | 功能完备，当前通过 TestFlight 分发 | [加入 TestFlight 内测](https://testflight.apple.com/join/KR4qNs6t) |
| Windows 电脑端 | 正式版 | [PackingProof-Desktop](https://github.com/PackingProof/PackingProof-Desktop) |

> Android 与 iOS 版本按正式版维护：受国内应用商店备案流程影响，暂未上架应用商店，因此 Android 直接分发签名 APK、iOS 走 TestFlight，功能与正式版一致。

**手机端能做什么（不只是录像）**

- 一键开始工作：持续录像 + 屏幕常亮，减少打包过程中的触屏操作
- 面单条码自动识别，识别到单号自动打点，按快递单号直接跳转到对应画面
- 连续扫码 / 同码停录两种工作模式，适配流水打包和一单一段
- 订单语音提醒：买家留言、卖家备注、商品信息、退款状态；退款触发醒目的工业警报音
- 连接电脑后局域网自动备份录像，扫码即可完成配对
- 已备份 / 未备份录像分别设置保留策略，兼顾证据安全与手机空间
- 本地优先：不需要注册账号，不依赖云端，录像和订单数据由自己的手机与电脑管理

**生态组成（同一套 PackingProof）**

| 组成 | 仓库 / 形态 | 作用 |
| --- | --- | --- |
| 电脑端（主程序、根启动器、局域网回放） | [PackingProof-Desktop](https://github.com/PackingProof/PackingProof-Desktop) | 录像与水印、扫码自动录像、打印后退款拦截、多工位集中备份、NAS 归档 |
| 手机端（Android / iOS） | 本仓库 | 独立录像与留证，也可作为多工位来源上传主机 |
| 扩展市场与扩展 API | [PackingProof-Extensions](https://gitee.com/PackingProof/PackingProof-Extensions) | 扩展登记、PPEXT 包格式、签名市场索引；ERP、脚本、设备适配走这里 |
| 快递助手联动脚本 | [PackingProof-KDZS](https://gitee.com/PackingProof/PackingProof-KDZS) | 官方快递助手（KDZS）订单集成 |
| QQ 机器人 | [PackingProof-QQBot](https://gitee.com/PackingProof/PackingProof-QQBot) | 在 QQ 私聊或群里按快递单号查询并回传录像 |
| 企业 / 伙伴适配 | 扩展形式接入 | 快麦 ERP 适配器、企业微信机器人等 |

**检索关键词**：PackingProof、包裹留证、打包录像、扫码录像、快递单号录像、发货留证、售后举证、电商打包监控、多工位录像、Android 打包录像 App、iOS 打包录像、TestFlight 分发、open source parcel packing video evidence、barcode triggered recording。

## 核心能力

- **一键开始工作**：保持摄像头预览和屏幕常亮，减少打包过程中的触屏操作
- **面单条码识别**：对准面单即可自动识别一维物流条码并记录单号，内置京东等平台的单号规则
- **两种工作模式**：连续扫码适合流水打包，同码停录适合一单一段的操作方式
- **录像水印**：录制结束自动把水印烧录进成片，画面信息完整，可直接作为发货证据
- **按单号查找与回放**：订单历史按快递单号搜索并跳到对应画面；播放页显示业务类型、分辨率、时长等信息，支持全屏观看
- **剪辑与导出**：在手机上直接剪辑片段并导出、分享成片
- **订单语音播报**：可播报买家留言、卖家备注、商品信息和退款状态；退款触发醒目的工业警报音
- **电脑自动备份**：扫描电脑端二维码完成配对，录像在局域网内自动备份到电脑主机
- **多工位身份**：主机为每台设备分配名称，手机与电脑的录像在主机上一目了然；连接异常时提示重新配对
- **来源筛选**：按设备筛选录像来源，翻页后仍保留所选设备
- **灵活清理录像**：分别设置已备份和未备份录像的保留策略，兼顾证据安全与手机空间
- **本地优先**：无需注册账号，不依赖云端保存录像；订单和录像数据由自己的手机与电脑管理

## 使用方法

1. 按下面的「安装与开始使用」装好应用，并允许摄像头、麦克风等必要权限（Android 与 iOS 步骤一致）
2. 将手机固定在能够看清打包区域和面单的位置
3. 点击“开始工作”并正常打包（应用会保持屏幕常亮，避免中途熄屏中断录像）
4. 面单进入画面后，应用自动识别快递单号并打点记录
5. 需要回看时进入“订单历史”，搜索快递单号并播放对应录像

如需电脑备份或订单语音提醒，请确保手机与电脑处于同一局域网，并按应用内提示完成连接。

## 安装与开始使用

**Android**：从 [Releases](https://github.com/PackingProof/PackingProof-Mobile/releases) 下载 ARM64 正式签名 APK 安装即可，后续版本可直接覆盖升级。

**iOS**：先在 App Store 安装 TestFlight，再打开 [内测邀请链接](https://testflight.apple.com/join/KR4qNs6t) 加入并安装「包裹留证」；TestFlight 版本与 Android 版本功能一致，版本更新通过 TestFlight 推送。

两个平台首次打开都会请求相机与麦克风权限，请按系统提示允许；录像与识别全部在手机本地完成。

## 与电脑端配合

手机端是 [PackingProof-Desktop](https://github.com/PackingProof/PackingProof-Desktop)（Windows）的多工位来源之一：同一局域网内，主机可以集中保存与回放手机录像，手机端也会按主机分配的设备名出现在列表里。整套系统还包含[扩展市场与扩展 API](https://gitee.com/PackingProof/PackingProof-Extensions)、[快递助手联动脚本](https://gitee.com/PackingProof/PackingProof-KDZS)和 [QQ 机器人](https://gitee.com/PackingProof/PackingProof-QQBot)。

## 适用场景

- 电商仓库与小型打包工作室
- 售后争议举证和错漏发核查
- 高价值、易损或定制商品的发货留档
- 希望使用闲置手机搭建低成本打包监控的商家

## 平台版本

- **Android**：通过 GitHub / Gitee Release 下载 ARM64 正式签名 APK，可直接安装升级
- **iOS**：先安装 TestFlight，再打开内测链接加入；功能与 Android 版本一致
- **独立运行**：不连电脑也能录像、识别面单、按单号回看；连接电脑后额外获得局域网自动备份与订单语音提醒
- 受国内应用商店备案流程影响，两个平台暂未上架应用商店，分发方式见上表

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

也可以双击根目录的 `双击构建Debug包.bat`：使用 Android 调试证书一键构建并输出到 `dist/android/PackingProof-Mobile-debug-v<versionName>+<versionCode>.apk`，无需任何签名配置。

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

在不提交的根目录 `.env` 中配置 `PACKING_PROOF_SIGNING_DIRECTORY=<仓库外的签名目录>` 后，双击 `双击构建Release调试版.bat` 可生成能够直接覆盖同一签名已安装版本的 Release 测试 APK。该脚本读取 `pubspec.yaml` 版本并输出 `dist/android/PackingProof-Mobile-v<versionName>+<versionCode>.apk`，不创建 Git 标签或发布记录。

产物位于 `dist/android/`，包括 `PackingProof-Mobile-v<versionName>+<versionCode>.apk`、`SHA256SUMS.txt` 和 `build-manifest.json`，不会生成 ZIP 压缩包。

## 开源许可证与品牌

源代码使用 [AGPL-3.0 License](LICENSE)。公开分发修改版或使用修改版提供服务时，需要遵守相应的源码公开义务。

`PackingProof`、`PackingProof Mobile`、“包裹留证”名称及官方应用图标属于项目品牌资产，不因源代码采用 AGPL-3.0 而授权第三方将其用于修改版的产品标识。公开发布修改版时，请使用不同的产品名称和图标，并明确标注“非官方修改版”；可以使用“基于 PackingProof 开发”说明来源。详见[品牌使用政策](BRAND_POLICY.md)。
