import 'dart:async';
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:packing_proof_mobile/services/lan_backup_pairing_failure_policy.dart';

void main() {
  test('5 秒内没有回应时 iPhone 额外提示本地网络权限', () {
    final String notice = LanBackupPairingFailurePolicy.noticeFor(
      TimeoutException('Future not completed', const Duration(seconds: 5)),
      isIOS: true,
    );

    expect(notice, contains('电脑没有响应'));
    expect(notice, contains('本地网络'));
    // 操作员不该看到 Dart 原始异常文案，也不该看到超时时长这类内部细节。
    expect(notice, isNot(contains('Exception')));
    expect(notice, isNot(contains('Future not completed')));
    expect(notice, isNot(contains('0:00:05')));
    expect(notice, isNot(endsWith('。')));
  });

  test('安卓端超时提示不引导去 iOS 设置页', () {
    final String notice = LanBackupPairingFailurePolicy.noticeFor(
      TimeoutException('Future not completed', const Duration(seconds: 5)),
      isIOS: false,
    );

    expect(notice, contains('电脑没有响应'));
    expect(notice, contains('防火墙'));
    expect(notice, isNot(contains('本地网络')));
    expect(notice, isNot(contains('Exception')));
  });

  test('对方明确回绝时使用统一的局域网提示', () {
    expect(
      LanBackupPairingFailurePolicy.noticeFor(
        const SocketException('目标计算机积极拒绝'),
        isIOS: true,
      ),
      LanBackupPairingFailurePolicy.socketNotice,
    );
  });
}
