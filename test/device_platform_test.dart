import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:packing_proof_mobile/platform/device_platform.dart';

void main() {
  test('平台标识只发送主机认识的取值', () {
    expect(devicePlatformId('android'), 'android');
    expect(devicePlatformId('ios'), 'ios');
    // 其它平台返回空串，让主机按设备类型兜底，而不是发一个主机不认识的值。
    expect(devicePlatformId('windows'), '');
    expect(devicePlatformId('linux'), '');
    expect(devicePlatformId(''), '');
  });

  test('当前平台标识与运行平台一致，且头名与主机一致', () {
    expect(currentDevicePlatformId(), devicePlatformId(Platform.operatingSystem));
    expect(devicePlatformHeaderName, 'X-EPM-Device-Platform');
  });
}
