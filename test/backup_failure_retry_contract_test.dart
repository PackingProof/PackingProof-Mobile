import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:packing_proof_mobile/models/lan_backup.dart';

/// 上传失败后的自动重传契约。
///
/// Android 由 WorkManager 按 `LanBackupFailurePolicy.shouldAutoRetry` 自动重试，
/// iOS 失败后只会停在暂停态，因此 Dart 侧按同一份失败类型清单在电脑连上后重新排队。
/// 两份清单必须保持一致，否则会出现「一端会自己恢复、另一端永远不再上传」。
void main() {
  const Set<LanBackupFailureKind> autoRetryKinds = <LanBackupFailureKind>{
    LanBackupFailureKind.offlineOrTimeout,
    LanBackupFailureKind.temporaryService,
    LanBackupFailureKind.storageUnavailable,
  };

  test('只有暂时性失败才允许自动重传', () {
    for (final LanBackupFailureKind kind in LanBackupFailureKind.values) {
      expect(
        kind.autoRetryable,
        autoRetryKinds.contains(kind),
        reason: '${kind.name} 的自动重传属性被改动',
      );
    }
  });

  test('Dart 自动重传清单与 Android 策略一致', () {
    final String source = File(
      'android/app/src/main/kotlin/app/packingproof/mobile/LanBackupFailurePolicy.kt',
    ).readAsStringSync();
    final RegExpMatch? block = RegExp(
      r'shouldAutoRetry[\s\S]*?setOf\(([\s\S]*?)\)',
    ).firstMatch(source);
    expect(block, isNotNull, reason: 'Android 自动重试策略声明格式被修改，请同步本测试');
    final Set<String> androidKinds = RegExp(r'LanBackupFailureKind\.([A-Z_]+)')
        .allMatches(block!.group(1)!)
        .map(
          (RegExpMatch match) =>
              match.group(1)!.replaceAll('_', '').toLowerCase(),
        )
        .toSet();

    expect(
      androidKinds,
      autoRetryKinds
          .map(
            (LanBackupFailureKind kind) =>
                kind.name.replaceAll('_', '').toLowerCase(),
          )
          .toSet(),
      reason: '两端自动重传的失败类型必须一致',
    );
  });
}
