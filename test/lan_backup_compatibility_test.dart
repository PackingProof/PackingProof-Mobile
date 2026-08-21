import 'package:flutter_test/flutter_test.dart';
import 'package:packing_proof_mobile/services/lan_backup_compatibility.dart';

void main() {
  test('当前手机接受首个兼容电脑版本及更高兼容版本', () {
    const LanBackupHostCompatibility minimum = LanBackupHostCompatibility(
      hostVersion: '0.0.55',
      protocol: 'mobile-backup-v2',
      enrollmentVersion: 2,
      authVersion: 3,
      minimumMobileVersion: '0.5.23',
      minimumMobileBuildNumber: 11036,
    );
    const LanBackupHostCompatibility newer = LanBackupHostCompatibility(
      hostVersion: '0.0.56',
      protocol: 'mobile-backup-v2',
      enrollmentVersion: 2,
      authVersion: 3,
      minimumMobileVersion: '0.5.23',
      minimumMobileBuildNumber: 11036,
    );

    expect(minimum.supportsCurrentMobile, isTrue);
    expect(newer.supportsCurrentMobile, isTrue);
  });

  test('旧电脑、缺失字段和不匹配协议均不可申请令牌', () {
    expect(parseLanBackupHostCompatibility(null), isNull);
    expect(
      parseLanBackupHostCompatibility(<String, Object?>{
        'hostVersion': '0.0.54',
        'protocol': 'mobile-backup-v2',
        'enrollmentVersion': 2,
        'authVersion': 3,
        'minimumMobileVersion': '0.5.23',
        'minimumMobileBuildNumber': 11036,
      })?.supportsCurrentMobile,
      isFalse,
    );
    expect(
      parseLanBackupHostCompatibility(<String, Object?>{
        'hostVersion': '0.0.55',
        'protocol': 'mobile-backup-v1',
        'enrollmentVersion': 2,
        'authVersion': 3,
        'minimumMobileVersion': '0.5.23',
        'minimumMobileBuildNumber': 11036,
      })?.supportsCurrentMobile,
      isFalse,
    );
  });
}
