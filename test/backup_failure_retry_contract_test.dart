import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:packing_proof_mobile/models/lan_backup.dart';

/// 上传失败后的自动重传契约。
///
/// Android 由 WorkManager 按 `LanBackupFailurePolicy.shouldAutoRetry` 自动重试，
/// iOS 失败后只会停在暂停态，因此 Dart 侧按同一份失败类型清单在电脑连上后重新排队。
/// 两份清单必须保持一致，否则会出现「一端会自己恢复、另一端永远不再上传」。
///
/// 同一台电脑返回同样的响应时，两端还必须判成同一类失败；否则会出现一端把它当成
/// 暂时性失败自动重排，另一端却停在「等待续传」不动。
void main() {
  const String androidPolicyPath =
      'android/app/src/main/kotlin/app/packingproof/mobile/'
      'LanBackupFailurePolicy.kt';
  const String iosPlatformPath = 'ios/Runner/IosBackupPlatform.swift';

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
    final String source = File(androidPolicyPath).readAsStringSync();
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

  test('整文件重传类失败只允许有限次自动重排', () {
    const Set<LanBackupFailureKind> limitedKinds = <LanBackupFailureKind>{
      LanBackupFailureKind.uploadExpired,
      LanBackupFailureKind.verificationFailed,
      LanBackupFailureKind.unknown,
    };

    for (final LanBackupFailureKind kind in LanBackupFailureKind.values) {
      expect(
        kind.limitedAutoRetryable,
        limitedKinds.contains(kind),
        reason: '${kind.name} 的有限次自动重排属性被改动',
      );
      expect(
        kind.autoRetryable && kind.limitedAutoRetryable,
        isFalse,
        reason: '暂时性失败与有限次重排必须互斥，否则同一失败会有两套重试规则',
      );
    }
    expect(lanBackupAutoRetryAttemptLimit, 3);
  });

  test('两端共用同一张上传失败判定表', () {
    // 共享判定表：这里列的每个响应，手机与电脑端必须判成同一类失败。
    const Map<String, String> shared = <String, String>{
      'status:404': 'incompatible_version',
      'status:408': 'offline_or_timeout',
      'status:409': 'temporary_service',
      'status:422': 'verification_failed',
      'status:425': 'temporary_service',
      'status:426': 'incompatible_version',
      'status:429': 'temporary_service',
      'status:500': 'temporary_service',
      'status:599': 'temporary_service',
      'error:credential_missing': 'credential_invalid',
      'error:enrollment_required': 'credential_invalid',
      'error:device_token_invalid': 'credential_invalid',
      'error:upload_not_found': 'upload_expired',
      'error:sha256_mismatch': 'verification_failed',
      'error:storage_unavailable': 'storage_unavailable',
      'error:backup_protocol_upgrade_required': 'incompatible_version',
      'error:invalid_content_range': 'incompatible_version',
      'error:invalid_request': 'incompatible_version',
      'error:invalid_json': 'incompatible_version',
      'error:offset_mismatch': 'temporary_service',
      'error:mobile_backup_failed': 'temporary_service',
    };

    final Map<String, String> android = _androidClassificationRules(
      File(androidPolicyPath).readAsStringSync(),
    );
    final Map<String, String> ios = _iosClassificationRules(
      File(iosPlatformPath).readAsStringSync(),
    );

    expect(android, isNotEmpty, reason: 'Android 判定表解析失败，请同步本测试');
    expect(ios, isNotEmpty, reason: 'iOS 判定表解析失败，请同步本测试');
    for (final MapEntry<String, String> entry in shared.entries) {
      expect(
        android[entry.key],
        entry.value,
        reason:
            'Android 对 ${entry.key} 的判定与共享表不一致，'
            '请同步 LanBackupFailurePolicy.classifyHttp',
      );
      expect(
        ios[entry.key],
        entry.value,
        reason:
            'iOS 对 ${entry.key} 的判定与共享表不一致，'
            '请同步 IosBackupPlatform.backupFailureKind',
      );
    }
  });
}

/// 解析 Android `classifyHttp` 的判定表，键为 `status:<码>` 或 `error:<错误码>`。
Map<String, String> _androidClassificationRules(String source) {
  final RegExpMatch? block = RegExp(
    r'fun classifyHttp[\s\S]*?\n    \}\n',
  ).firstMatch(source);
  if (block == null) return <String, String>{};
  // 换行处会拆开 setOf(...) 与 when 分支，先压成一行再按分支切分。
  final String flat = block.group(0)!.replaceAll(RegExp(r'\s+'), ' ');
  final Map<String, String> rules = <String, String>{};
  int cursor = 0;
  for (final RegExpMatch kind in RegExp(
    r'LanBackupFailureKind\.([A-Z_]+)',
  ).allMatches(flat)) {
    final String condition = flat.substring(cursor, kind.start);
    cursor = kind.end;
    for (final String key in _androidConditionKeys(condition)) {
      rules[key] = kind.group(1)!.toLowerCase();
    }
  }
  return rules;
}

List<String> _androidConditionKeys(String condition) {
  final List<String> keys = <String>[];
  for (final RegExpMatch match in RegExp(
    r'statusCode == (\d+)',
  ).allMatches(condition)) {
    keys.add('status:${match.group(1)}');
  }
  for (final RegExpMatch match in RegExp(
    r'statusCode in (\d+)\.\.(\d+)',
  ).allMatches(condition)) {
    final int from = int.parse(match.group(1)!);
    final int to = int.parse(match.group(2)!);
    for (int code = from; code <= to; code++) {
      keys.add('status:$code');
    }
  }
  for (final RegExpMatch match in RegExp(
    r'statusCode in setOf\(([^)]*)\)',
  ).allMatches(condition)) {
    for (final String token in match.group(1)!.split(',')) {
      if (token.trim().isEmpty) continue;
      keys.add('status:${token.trim()}');
    }
  }
  for (final RegExpMatch match in RegExp(
    r'errorCode == "([^"]+)"',
  ).allMatches(condition)) {
    keys.add('error:${match.group(1)}');
  }
  for (final RegExpMatch match in RegExp(
    r'errorCode in setOf\(([^)]*)\)',
  ).allMatches(condition)) {
    for (final String token in match.group(1)!.split(',')) {
      final String code = token.trim().replaceAll('"', '');
      if (code.isNotEmpty) keys.add('error:$code');
    }
  }
  return keys;
}

/// 解析 iOS `backupFailureKind` 的判定表，键与 Android 侧一致。
Map<String, String> _iosClassificationRules(String source) {
  final RegExpMatch? block = RegExp(
    r'static func backupFailureKind[\s\S]*?\n  \}\n',
  ).firstMatch(source);
  if (block == null) return <String, String>{};
  final String flat = block.group(0)!.replaceAll(RegExp(r'\s+'), ' ');
  final int errorCodeSwitch = flat.indexOf('switch errorCode');
  final int statusCodeSwitch = flat.indexOf('switch statusCode');
  final Map<String, String> rules = <String, String>{};
  for (final RegExpMatch match in RegExp(
    r'case ([^:]+): return "([a-z_]+)"',
  ).allMatches(flat)) {
    final bool inErrorCodeSwitch =
        errorCodeSwitch >= 0 &&
        match.start > errorCodeSwitch &&
        (statusCodeSwitch < 0 || match.start < statusCodeSwitch);
    for (final String token in match.group(1)!.split(',')) {
      final String value = token.trim();
      final RegExpMatch? range = RegExp(
        r'^(\d+)\.\.\.(\d+)$',
      ).firstMatch(value);
      if (range != null) {
        final int from = int.parse(range.group(1)!);
        final int to = int.parse(range.group(2)!);
        for (int code = from; code <= to; code++) {
          rules['status:$code'] = match.group(2)!;
        }
        continue;
      }
      final String bare = value.replaceAll('"', '');
      if (bare.isEmpty) continue;
      final String key = inErrorCodeSwitch && int.tryParse(bare) == null
          ? 'error:$bare'
          : 'status:$bare';
      rules[key] = match.group(2)!;
    }
  }
  return rules;
}
