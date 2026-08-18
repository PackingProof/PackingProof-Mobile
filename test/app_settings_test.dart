import 'dart:convert';
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:packing_proof_mobile/models/backup_retention_policy.dart';
import 'package:packing_proof_mobile/models/app_settings.dart';
import 'package:packing_proof_mobile/models/recording_video_codec.dart';
import 'package:packing_proof_mobile/models/recording_spec.dart';
import 'package:packing_proof_mobile/models/recording_operation_mode.dart';
import 'package:packing_proof_mobile/models/work_mode.dart';
import 'package:packing_proof_mobile/services/session_repository.dart';

import 'test_repository.dart';

void main() {
  late Directory root;

  setUp(() async {
    root = await Directory.systemTemp.createTemp('packing-proof-settings-');
  });

  tearDown(() async {
    if (await root.exists()) {
      await root.delete(recursive: true);
    }
  });

  test('旧设置默认开启语音并保留未知字段', () async {
    await File('${root.path}/settings.json').writeAsString(
      jsonEncode(<String, Object>{
        'workMode': 'sameCodeStop',
        'futureOption': <String, Object>{'enabled': true},
      }),
    );
    final SessionRepository repository = testRepository(root);

    final settings = await repository.loadSettings();
    expect(settings.workMode, WorkMode.sameCodeStop);
    expect(settings.speechEnabled, isTrue);
    expect(settings.maxVolumeEnabled, isTrue);
    expect(settings.startupNoticeVersion, 0);
    expect(settings.lanBackupAutoEnabled, isTrue);
    expect(settings.unbackedRetention, UnbackedRetentionPolicy.days30);
    expect(settings.backedRetention, BackedRetentionPolicy.days7);
    expect(settings.minimumBarcodeLength, 11);
    expect(settings.operationMode, RecordingOperationMode.shipping);

    await repository.saveSpeechEnabled(false);
    final Map<String, Object?> persisted = Map<String, Object?>.from(
      jsonDecode(await File('${root.path}/settings.json').readAsString())
          as Map<Object?, Object?>,
    );
    expect(persisted['workMode'], 'sameCodeStop');
    expect(persisted['speechEnabled'], isFalse);
    expect(persisted['maxVolumeEnabled'], isTrue);
    expect(persisted['futureOption'], <String, Object>{'enabled': true});
  });

  test('发货退货模式可持久化并保留未知字段', () async {
    final SessionRepository repository = testRepository(root);

    await repository.saveOperationMode(RecordingOperationMode.returnGoods);
    final AppSettings updated = await repository.loadSettings();
    expect(updated.operationMode, RecordingOperationMode.returnGoods);

    final Map<String, Object?> persisted = Map<String, Object?>.from(
      jsonDecode(await File('${root.path}/settings.json').readAsString())
          as Map<Object?, Object?>,
    );
    expect(persisted['operationMode'], 'return');
  });

  test('双重保留策略相互独立并保留未知字段', () async {
    final SessionRepository repository = testRepository(root);
    await repository.saveBackupRetention(
      unbacked: UnbackedRetentionPolicy.days90,
      backed: BackedRetentionPolicy.immediately,
    );
    await repository.saveSpeechEnabled(false);

    final settings = await repository.loadSettings();
    expect(settings.unbackedRetention, UnbackedRetentionPolicy.days90);
    expect(settings.backedRetention, BackedRetentionPolicy.immediately);
    expect(settings.speechEnabled, isFalse);
  });

  test('录制声音默认开启且可关闭并持久化', () async {
    final SessionRepository repository = testRepository(root);

    final AppSettings defaults = await repository.loadSettings();
    expect(defaults.recordAudioEnabled, isTrue);

    await repository.saveRecordAudioEnabled(false);
    final AppSettings updated = await repository.loadSettings();
    expect(updated.recordAudioEnabled, isFalse);

    final Map<String, Object?> persisted = Map<String, Object?>.from(
      jsonDecode(await File('${root.path}/settings.json').readAsString())
          as Map<Object?, Object?>,
    );
    expect(persisted['recordAudioEnabled'], isFalse);
  });

  test('录像降级模式默认关闭且可持久化', () async {
    final SessionRepository repository = testRepository(root);

    final AppSettings defaults = await repository.loadSettings();
    expect(defaults.nativeRecordingFallback, isFalse);

    await repository.saveNativeRecordingFallback(true);
    final AppSettings updated = await repository.loadSettings();
    expect(updated.nativeRecordingFallback, isTrue);

    final Map<String, Object?> persisted = Map<String, Object?>.from(
      jsonDecode(await File('${root.path}/settings.json').readAsString())
          as Map<Object?, Object?>,
    );
    expect(persisted['nativeRecordingFallback'], isTrue);
  });

  test('录像编码默认 H.265 且可切换持久化', () async {
    final SessionRepository repository = testRepository(root);

    final AppSettings defaults = await repository.loadSettings();
    expect(defaults.preferredVideoCodec, RecordingVideoCodec.hevc);

    await repository.savePreferredVideoCodec(RecordingVideoCodec.h264);
    final AppSettings updated = await repository.loadSettings();
    expect(updated.preferredVideoCodec, RecordingVideoCodec.h264);

    final Map<String, Object?> persisted = Map<String, Object?>.from(
      jsonDecode(await File('${root.path}/settings.json').readAsString())
          as Map<Object?, Object?>,
    );
    expect(persisted['preferredVideoCodec'], 'h264');
  });

  test('录像规格默认高清且可切换持久化', () async {
    final SessionRepository repository = testRepository(root);

    final AppSettings defaults = await repository.loadSettings();
    expect(defaults.recordingSpec, RecordingSpecPreset.hd1080p30);

    await repository.saveRecordingSpec(RecordingSpecPreset.smooth720p30);
    final AppSettings updated = await repository.loadSettings();
    expect(updated.recordingSpec, RecordingSpecPreset.smooth720p30);

    final Map<String, Object?> persisted = Map<String, Object?>.from(
      jsonDecode(await File('${root.path}/settings.json').readAsString())
          as Map<Object?, Object?>,
    );
    expect(persisted['recordingSpec'], 'smooth720p30');
  });

  test('旧设置缺少录像规格时按高清处理', () async {
    await File(
      '${root.path}/settings.json',
    ).writeAsString(jsonEncode(<String, Object>{'speechEnabled': false}));
    final SessionRepository repository = testRepository(root);

    final settings = await repository.loadSettings();

    expect(settings.recordingSpec, RecordingSpecPreset.hd1080p30);
    expect(settings.speechEnabled, isFalse);
  });

  test('面单条码最短长度默认 11 且可持久化', () async {
    final SessionRepository repository = testRepository(root);

    final AppSettings defaults = await repository.loadSettings();
    expect(defaults.minimumBarcodeLength, 11);

    await repository.saveMinimumBarcodeLength(12);
    final AppSettings updated = await repository.loadSettings();
    expect(updated.minimumBarcodeLength, 12);

    final Map<String, Object?> persisted = Map<String, Object?>.from(
      jsonDecode(await File('${root.path}/settings.json').readAsString())
          as Map<Object?, Object?>,
    );
    expect(persisted['minimumBarcodeLength'], 12);

    await repository.saveMinimumBarcodeLength(100);
    expect((await repository.loadSettings()).minimumBarcodeLength, 40);
  });

  test('每页条数默认 5 且可持久化', () async {
    final SessionRepository repository = testRepository(root);

    final AppSettings defaults = await repository.loadSettings();
    expect(defaults.historyPageSize, 5);

    await repository.saveHistoryPageSize(10);
    final AppSettings updated = await repository.loadSettings();
    expect(updated.historyPageSize, 10);

    final Map<String, Object?> persisted = Map<String, Object?>.from(
      jsonDecode(await File('${root.path}/settings.json').readAsString())
          as Map<Object?, Object?>,
    );
    expect(persisted['historyPageSize'], 10);

    await repository.saveHistoryPageSize(7);
    expect((await repository.loadSettings()).historyPageSize, 5);
  });

  test('首次说明版本在两个编译版本间共享且保留其他设置', () async {
    final SessionRepository repository = testRepository(root);
    await repository.saveSpeechEnabled(false);
    await repository.saveStartupNoticeVersion(1);

    final settings = await repository.loadSettings();
    expect(settings.startupNoticeVersion, 1);
    expect(settings.speechEnabled, isFalse);
  });

  test('历史构建身份默认空且可持久化', () async {
    final SessionRepository repository = testRepository(root);

    final AppSettings defaults = await repository.loadSettings();
    expect(defaults.lastLoggedAppVersion, isEmpty);
    expect(defaults.lastLoggedAppBuildNumber, 0);
    expect(defaults.lastLoggedBuildIdentity, isEmpty);

    await repository.saveLastLoggedAppIdentity(
      version: '0.5.23',
      buildNumber: 11030,
      buildIdentity: '0.5.23|11030|def5678',
    );
    final AppSettings updated = await repository.loadSettings();
    expect(updated.lastLoggedAppVersion, '0.5.23');
    expect(updated.lastLoggedAppBuildNumber, 11030);
    expect(updated.lastLoggedBuildIdentity, '0.5.23|11030|def5678');

    final Map<String, Object?> persisted = Map<String, Object?>.from(
      jsonDecode(await File('${root.path}/settings.json').readAsString())
          as Map<Object?, Object?>,
    );
    expect(persisted['lastLoggedAppVersion'], '0.5.23');
    expect(persisted['lastLoggedAppBuildNumber'], 11030);
    expect(persisted['lastLoggedBuildIdentity'], '0.5.23|11030|def5678');
  });

  test('手机更新提示每天最多保留两次且重启后继续计数', () async {
    final SessionRepository repository = testRepository(root);
    final DateTime firstDay = DateTime(2026, 7, 26, 8);

    expect(await repository.tryReserveMobileUpdatePrompt(firstDay), isTrue);
    expect(await repository.tryReserveMobileUpdatePrompt(firstDay), isTrue);
    expect(await repository.tryReserveMobileUpdatePrompt(firstDay), isFalse);

    final SessionRepository reopened = testRepository(root);
    expect(
      await reopened.tryReserveMobileUpdatePrompt(
        firstDay.add(const Duration(hours: 10)),
      ),
      isFalse,
    );
    expect(
      await reopened.tryReserveMobileUpdatePrompt(
        firstDay.add(const Duration(days: 1)),
      ),
      isTrue,
    );
  });

  test('音量设置默认开启并保留其他字段', () async {
    final SessionRepository repository = testRepository(root);

    expect((await repository.loadSettings()).maxVolumeEnabled, isTrue);
    await repository.saveMaxVolumeEnabled(false);
    await repository.saveSpeechEnabled(false);

    final settings = await repository.loadSettings();
    expect(settings.maxVolumeEnabled, isFalse);
    expect(settings.speechEnabled, isFalse);
  });

  test('切换工作模式不会覆盖语音设置', () async {
    final SessionRepository repository = testRepository(root);
    await repository.saveSpeechEnabled(false);
    await repository.saveWorkMode(WorkMode.sameCodeStop);

    final settings = await repository.loadSettings();
    expect(settings.workMode, WorkMode.sameCodeStop);
    expect(settings.speechEnabled, isFalse);
  });

  test('删除本机记录后持久保留隐藏的电脑录像编号', () async {
    final SessionRepository repository = testRepository(root);

    await repository.saveHiddenRemoteRecordingIds(<int>{8, 3});
    await repository.saveSpeechEnabled(false);

    final settings = await repository.loadSettings();
    expect(settings.hiddenRemoteRecordingIds, <int>{3, 8});
    expect(settings.speechEnabled, isFalse);
  });

  test('并发更新设置不会覆盖录像保留策略', () async {
    final SessionRepository repository = testRepository(root);

    await Future.wait(<Future<void>>[
      repository.saveBackupRetention(
        unbacked: UnbackedRetentionPolicy.keepForever,
        backed: BackedRetentionPolicy.keepForever,
      ),
      repository.saveSpeechEnabled(false),
    ]);

    final settings = await repository.loadSettings();
    expect(settings.unbackedRetention, UnbackedRetentionPolicy.keepForever);
    expect(settings.backedRetention, BackedRetentionPolicy.keepForever);
    expect(settings.speechEnabled, isFalse);
  });

  test('设置索引损坏且无法恢复时禁用自动录像清理', () async {
    await File('${root.path}/settings.json').writeAsString('{broken');
    final SessionRepository repository = testRepository(root);

    final settings = await repository.loadSettings();

    expect(settings.unbackedRetention, UnbackedRetentionPolicy.keepForever);
    expect(settings.backedRetention, BackedRetentionPolicy.keepForever);
  });
}
