import 'dart:io';

import 'package:flutter/foundation.dart';

/// 发给保存主机（PackingProof-Desktop）的平台标识。
///
/// 主机的昵称分配按平台加前缀：`android` → 安卓N、`ios` → 苹果N，
/// 识别不出平台时只能落到"从机N"。手机端此前完全没有发送平台，
/// 于是多台手机无论安卓还是苹果都拿到"从机N"，看起来像被主机改过名。
///
/// 只返回主机认识的取值；无法识别时返回空串，让主机按设备类型兜底。
String currentDevicePlatformId() => devicePlatformId(Platform.operatingSystem);

@visibleForTesting
String devicePlatformId(String operatingSystem) => switch (operatingSystem) {
  'android' => 'android',
  'ios' => 'ios',
  _ => '',
};

/// 平台标识的 HTTP 头名，与主机 Services/WebServer.cs 的 DevicePlatformHeader 一致。
/// 原生签名器（Android/iOS）发出的请求也要带同名头。
const String devicePlatformHeaderName = 'X-EPM-Device-Platform';
