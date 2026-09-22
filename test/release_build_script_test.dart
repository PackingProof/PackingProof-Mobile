import 'dart:io';

import 'package:flutter_test/flutter_test.dart';

void main() {
  test('Android 发布构建刷新 Flutter 产物并保留原生增量缓存', () {
    final script = File('Tools/Build-Android.ps1').readAsStringSync();

    expect(script, contains('Get-ReleaseBuildInputFingerprint'));
    expect(script, contains(r'[switch]$ForceClean'));
    expect(script, contains("build/app/intermediates/flutter/release"));
    expect(script, contains('flutter analyze --no-pub --no-fatal-infos'));
    expect(script, contains('flutter test --no-pub'));
    expect(script, contains('flutter build apk --release'));
    expect(
      script,
      isNot(contains('flutter build apk --release `\n        --no-pub')),
    );
    expect(script, isNot(contains('\n    flutter clean\n')));
    expect(script, contains('Assert-ApkMetadata -ApkPath \$source'));
    expect(
      script,
      contains('Assert-ApkContainsDartBuildIdentity -ApkPath \$source'),
    );
    expect(script, contains('lib/arm64-v8a/libapp.so'));
  });

  test('正式发布和 Release 调试入口均支持强制完整清理', () {
    final publishScript = File('Tools/Publish-Android.ps1').readAsStringSync();
    final diagnosticScript = File(
      'Tools/Build-Release-Diagnostic.ps1',
    ).readAsStringSync();

    expect(publishScript, contains(r'[switch]$ForceClean'));
    expect(publishScript, contains(r'-ForceClean:$ForceClean'));
    expect(diagnosticScript, contains(r'[switch]$ForceClean'));
    expect(diagnosticScript, contains(r'-ForceClean:$ForceClean'));
  });

  test('Android 构建期间使用独立 Java 临时目录并恢复原环境', () {
    final releaseScript = File('Tools/Build-Android.ps1').readAsStringSync();
    final debugScript = File('Tools/Build-Debug-Quick.ps1').readAsStringSync();
    final environmentScript = File(
      'Tools/Java-Build-Environment.ps1',
    ).readAsStringSync();

    for (final script in [releaseScript, debugScript]) {
      expect(script, contains('Java-Build-Environment.ps1'));
      expect(script, contains('Enter-JavaBuildEnvironment'));
      expect(script, contains('Exit-JavaBuildEnvironment'));
    }
    expect(environmentScript, contains('.dart_tool/java-build-temp'));
    expect(environmentScript, contains(r'$env:TEMP = $temporaryDirectory'));
    expect(environmentScript, contains(r'$env:TMP = $temporaryDirectory'));
    expect(environmentScript, contains(r'$env:TEMP = $State.Temp'));
    expect(environmentScript, contains(r'$env:TMP = $State.Tmp'));
  });

  test('iOS profile 和 release 构建把可审计的构建身份注入 App', () {
    final script = File('Tools/Build-iOS.sh').readAsStringSync();

    final revisionIndex = script.indexOf('REVISION="\$(git rev-parse');
    final timestampIndex = script.indexOf('BUILT_AT="\$(date -u');
    final buildIndex = script.indexOf('flutter build ipa "--\$BUILD_MODE"');
    expect(revisionIndex, greaterThanOrEqualTo(0));
    expect(timestampIndex, greaterThan(revisionIndex));
    expect(buildIndex, greaterThan(timestampIndex));
    expect(script, contains('BUILD_MODE="release"'));
    expect(script, contains('--profile)'));
    expect(script, contains('--release)'));
    expect(script, contains('EXPORT_METHOD="development"'));
    expect(script, contains('EXPORT_METHOD="app-store"'));
    expect(script, contains('--dart-define="BUILD_REVISION=\$REVISION"'));
    expect(script, contains('--dart-define="BUILD_TIMESTAMP=\$BUILT_AT"'));
    expect(script, contains('"revision": "\$REVISION"'));
    expect(script, contains('"builtAtUtc": "\$BUILT_AT"'));
    expect(script, contains('"buildMode": "\$BUILD_MODE"'));
    expect(script, contains('PackingProof-Mobile-profile-v'));
    expect(script, isNot(contains('devicectl')));
    expect(script, isNot(contains('uninstall')));
  });

  test('iOS 发布与本地 CI 先在启动前准备好模拟器', () {
    final publishScript = File('Tools/Publish-iOS.sh').readAsStringSync();
    final ciScript = File('Tools/test-ci.sh').readAsStringSync();
    final helper = File('Tools/ios-simulator.sh').readAsStringSync();

    for (final script in [publishScript, ciScript]) {
      expect(script, contains('Tools/ios-simulator.sh'));
      expect(script, contains('prepare_ios_simulator'));
    }
    // 模拟器必须在跑测试之前准备好，否则失败信息会指向用例而不是环境。
    expect(
      publishScript.indexOf('prepare_ios_simulator'),
      lessThan(publishScript.indexOf('flutter analyze')),
    );
    expect(helper, contains('xcrun simctl bootstatus'));
    expect(helper, contains('xcrun simctl list devices booted'));
    // 与 ci.yml、test-ci.sh 保持一致：时序敏感用例不能按并行 clone 跑。
    expect(publishScript, contains('-parallel-testing-enabled NO'));
  });

  test('Android 清单配置系统播放器内容提供者', () {
    final manifest = File(
      'android/app/src/main/AndroidManifest.xml',
    ).readAsStringSync();

    expect(manifest, contains('.SystemVideoPlayerProvider'));
    expect(manifest, contains(r'${applicationId}.system_player_provider'));
    expect(manifest, contains('grantUriPermissions'));
  });
}
