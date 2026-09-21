import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:packing_proof_mobile/models/backup_storage_policy.dart';

/// 存储策略只在 Dart 侧定义一次，Android / iOS 只保存下发值。两端在下发前使用的
/// 兜底值必须与这里一致；这个测试防止有人只改一边。
void main() {
  final Map<String, int> expected = <String, int>{
    'minimumBytes': BackupStoragePolicy.minimumBytes,
    'warningBytes': BackupStoragePolicy.warningBytes,
    'targetBytes': BackupStoragePolicy.targetBytes,
    'attestationFreshnessMs':
        BackupStoragePolicy.attestationFreshness.inMilliseconds,
    'confirmationLimit': BackupStoragePolicy.confirmationLimit,
    'confirmationGraceMs': BackupStoragePolicy.confirmationGrace.inMilliseconds,
  };

  test('下发键值与策略一致', () {
    expect(BackupStoragePolicy.toNativeRequest(), <String, Object?>{
      'storageMinimumBytes': expected['minimumBytes'],
      'storageWarningBytes': expected['warningBytes'],
      'storageTargetBytes': expected['targetBytes'],
      'storageAttestationFreshnessMs': expected['attestationFreshnessMs'],
      'storageConfirmationLimit': expected['confirmationLimit'],
      'storageConfirmationGraceMs': expected['confirmationGraceMs'],
    });
    expect(BackupStoragePolicy.targetBytes, BackupStoragePolicy.warningBytes);
  });

  test('字节数文案保持整 GB 不带小数', () {
    expect(BackupStoragePolicy.label(3 * 1024 * 1024 * 1024), '3GB');
    expect(BackupStoragePolicy.label(1536 * 1024 * 1024), '1.5GB');
    expect(BackupStoragePolicy.label(512 * 1024 * 1024), '512MB');
  });

  test('Android 兜底值与 Dart 策略一致', () {
    final String source = File(
      'android/app/src/main/kotlin/app/packingproof/mobile/BackupStoragePolicy.kt',
    ).readAsStringSync();
    final RegExpMatch? block = RegExp(
      r'FALLBACK = BackupStoragePolicy\(([\s\S]*?)\n\s*\)',
    ).firstMatch(source);
    expect(block, isNotNull, reason: 'Kotlin 兜底值声明格式被修改，请同步本测试');

    expect(
      _storedValues(block!.group(1)!, separator: '='),
      expected,
      reason: '请把 BackupStoragePolicy.kt 的兜底值改成与 Dart 策略一致',
    );
  });

  test('iOS 兜底值与 Dart 策略一致', () {
    final String source = File(
      'ios/Runner/IosBackupPlatform.swift',
    ).readAsStringSync();
    final RegExpMatch? block = RegExp(
      r'static let fallback = BackupStoragePolicy\(([\s\S]*?)\n  \)',
    ).firstMatch(source);
    expect(block, isNotNull, reason: 'Swift 兜底值声明格式被修改，请同步本测试');

    expect(
      _storedValues(block!.group(1)!, separator: ':'),
      expected,
      reason: '请把 IosBackupPlatform.swift 的兜底值改成与 Dart 策略一致',
    );
  });
}

/// 解析 `key = 2 * 1024` / `key: 2 * 1024` 形式的常量算式。
Map<String, int> _storedValues(String block, {required String separator}) {
  final Map<String, int> values = <String, int>{};
  for (final String line in block.split('\n')) {
    final int index = line.indexOf(separator);
    if (index < 0) continue;
    final String key = line.substring(0, index).trim();
    final String expression = line
        .substring(index + separator.length)
        .replaceAll(RegExp(r'[L_,\s]'), '');
    if (key.isEmpty || expression.isEmpty) continue;
    final List<String> factors = expression.split('*');
    if (factors.any((String factor) => int.tryParse(factor) == null)) continue;
    values[key] = factors.fold<int>(
      1,
      (int total, String factor) => total * int.parse(factor),
    );
  }
  return values;
}
