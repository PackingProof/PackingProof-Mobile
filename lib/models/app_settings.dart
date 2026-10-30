import 'dart:convert';

import 'backup_retention_policy.dart';
import 'backup_storage_policy.dart';
import 'camera_capability.dart';
import 'work_mode.dart';
import 'storage_notice.dart';
import 'recording_video_codec.dart';
import 'recording_spec.dart';
import 'recording_operation_mode.dart';
import 'recording_orientation.dart';

class AppSettings {
  static const int defaultMinimumBarcodeLength = 11;
  static const int minimumBarcodeLengthLowerBound = 8;
  static const int minimumBarcodeLengthUpperBound = 40;
  static const int defaultHistoryPageSize = 5;
  static const List<int> historyPageSizeOptions = <int>[5, 10, 20];

  const AppSettings({
    this.workMode = WorkMode.continuousScan,
    this.operationMode = RecordingOperationMode.shipping,
    this.speechEnabled = true,
    this.orderSpeechEnabled = true,
    this.maxVolumeEnabled = true,
    this.recordAudioEnabled = true,
    this.watermarkEnabled = true,
    this.manualTrackingValidationEnabled = true,
    this.shippingCameraCapabilityPreference = CameraCapabilityPreference.full,
    this.returnCameraCapabilityPreference = CameraCapabilityPreference.full,
    this.cameraCapabilityState,
    this.preferredVideoCodec = RecordingVideoCodec.h264,
    this.recordingSpec = RecordingSpecPreset.hd1080p30,
    this.recordingOrientation = RecordingOrientation.portrait,
    this.startupNoticeVersion = 0,
    this.lastLoggedAppVersion = '',
    this.lastLoggedAppBuildNumber = 0,
    this.lastLoggedBuildIdentity = '',
    this.mobileUpdatePromptDate = '',
    this.mobileUpdatePromptCount = 0,
    this.lanBackupAutoEnabled = true,
    this.galleryAutoBackupEnabled = false,
    this.unbackedRetention = UnbackedRetentionPolicy.days30,
    this.backedRetention = BackedRetentionPolicy.days7,
    this.returnUnbackedRetention = UnbackedRetentionPolicy.days3,
    this.returnBackedRetention = BackedRetentionPolicy.days1,
    this.storagePressurePolicy = StoragePressurePolicy.defaultValue,
    this.hiddenRemoteRecordingIds = const <int>{},
    this.storageNoticeState = const StorageNoticeState(),
    this.minimumBarcodeLength = defaultMinimumBarcodeLength,
    this.historyPageSize = defaultHistoryPageSize,
    this.scanBeepEnabled = false,
    this.scanQrCodes = false,
    this.extraValues = const <String, Object?>{},
  });

  factory AppSettings.fromJson(Map<String, Object?> json) {
    final Map<String, Object?> extraValues = Map<String, Object?>.of(json)
      ..remove('workMode')
      ..remove('operationMode')
      ..remove('speechEnabled')
      ..remove('orderSpeechEnabled')
      ..remove('maxVolumeEnabled')
      ..remove('watermarkEnabled')
      ..remove('manualTrackingValidationEnabled')
      // 旧版本把「录像降级为两路」单独记成一个标记键，用户改回完整模式也甩不掉；
      // 现在发货和退货分别保存工作模式，这里顺手丢掉历史键。
      ..remove('nativeRecordingFallback')
      ..remove('cameraCapabilityPreference')
      ..remove('shippingCameraCapabilityPreference')
      ..remove('returnCameraCapabilityPreference')
      ..remove('cameraCapabilityState')
      ..remove('preferredVideoCodec')
      ..remove('recordingSpec')
      ..remove('recordingOrientation')
      ..remove('startupNoticeVersion')
      ..remove('lastLoggedAppVersion')
      ..remove('lastLoggedAppBuildNumber')
      ..remove('lastLoggedBuildIdentity')
      ..remove('mobileUpdatePromptDate')
      ..remove('mobileUpdatePromptCount')
      ..remove('lanBackupAutoEnabled')
      ..remove('galleryAutoBackupEnabled')
      ..remove('unbackedRetention')
      ..remove('backedRetention');
    extraValues.remove('returnUnbackedRetention');
    extraValues.remove('returnBackedRetention');
    extraValues.remove('storagePressurePolicy');
    extraValues.remove('storageNoticeState');
    extraValues.remove('minimumBarcodeLength');
    extraValues.remove('historyPageSize');
    extraValues.remove('scanBeepEnabled');
    extraValues.remove('scanQrCodes');
    final Set<int> hiddenRemoteRecordingIds =
        ((json['hiddenRemoteRecordingIds'] as List<Object?>?) ?? const [])
            .whereType<num>()
            .map((value) => value.toInt())
            .where((value) => value > 0)
            .toSet();
    extraValues.remove('hiddenRemoteRecordingIds');
    final Object? legacyCameraCapabilityPreference =
        json['cameraCapabilityPreference'];
    return AppSettings(
      workMode: workModeFromStorage(json['workMode']),
      operationMode: recordingOperationModeFromStorage(json['operationMode']),
      speechEnabled: json['speechEnabled'] is bool
          ? json['speechEnabled']! as bool
          : true,
      orderSpeechEnabled: json['orderSpeechEnabled'] is bool
          ? json['orderSpeechEnabled']! as bool
          : true,
      maxVolumeEnabled: json['maxVolumeEnabled'] is bool
          ? json['maxVolumeEnabled']! as bool
          : true,
      recordAudioEnabled: json['recordAudioEnabled'] is bool
          ? json['recordAudioEnabled']! as bool
          : true,
      watermarkEnabled: json['watermarkEnabled'] is bool
          ? json['watermarkEnabled']! as bool
          : true,
      manualTrackingValidationEnabled:
          json['manualTrackingValidationEnabled'] is bool
          ? json['manualTrackingValidationEnabled']! as bool
          : true,
      shippingCameraCapabilityPreference: cameraCapabilityPreferenceFromStorage(
        json['shippingCameraCapabilityPreference'] ??
            legacyCameraCapabilityPreference,
      ),
      returnCameraCapabilityPreference: cameraCapabilityPreferenceFromStorage(
        json['returnCameraCapabilityPreference'] ??
            legacyCameraCapabilityPreference,
      ),
      cameraCapabilityState: json['cameraCapabilityState'] is Map
          ? Map<String, Object?>.from(
              json['cameraCapabilityState']! as Map<Object?, Object?>,
            )
          : null,
      preferredVideoCodec: recordingVideoCodecFromStorage(
        json['preferredVideoCodec'],
      ),
      recordingSpec: recordingSpecFromStorage(json['recordingSpec']),
      recordingOrientation: recordingOrientationFromStorage(
        json['recordingOrientation'],
      ),
      startupNoticeVersion: json['startupNoticeVersion'] is num
          ? (json['startupNoticeVersion']! as num).toInt()
          : 0,
      lastLoggedAppVersion: json['lastLoggedAppVersion'] is String
          ? json['lastLoggedAppVersion']! as String
          : '',
      lastLoggedAppBuildNumber: json['lastLoggedAppBuildNumber'] is num
          ? (json['lastLoggedAppBuildNumber']! as num).toInt()
          : 0,
      lastLoggedBuildIdentity: json['lastLoggedBuildIdentity'] is String
          ? json['lastLoggedBuildIdentity']! as String
          : '',
      mobileUpdatePromptDate: json['mobileUpdatePromptDate'] is String
          ? json['mobileUpdatePromptDate']! as String
          : '',
      mobileUpdatePromptCount: json['mobileUpdatePromptCount'] is num
          ? (json['mobileUpdatePromptCount']! as num).toInt()
          : 0,
      lanBackupAutoEnabled: json['lanBackupAutoEnabled'] is bool
          ? json['lanBackupAutoEnabled']! as bool
          : true,
      galleryAutoBackupEnabled: json['galleryAutoBackupEnabled'] is bool
          ? json['galleryAutoBackupEnabled']! as bool
          : false,
      unbackedRetention: unbackedRetentionFromStorage(
        json['unbackedRetention'],
      ),
      backedRetention: backedRetentionFromStorage(json['backedRetention']),
      returnUnbackedRetention: json.containsKey('returnUnbackedRetention')
          ? unbackedRetentionFromStorage(json['returnUnbackedRetention'])
          : UnbackedRetentionPolicy.days3,
      returnBackedRetention: json.containsKey('returnBackedRetention')
          ? backedRetentionFromStorage(json['returnBackedRetention'])
          : BackedRetentionPolicy.days1,
      storagePressurePolicy: storagePressurePolicyFromStorage(
        json['storagePressurePolicy'],
      ),
      hiddenRemoteRecordingIds: hiddenRemoteRecordingIds,
      storageNoticeState: StorageNoticeState.fromJson(
        json['storageNoticeState'],
      ),
      minimumBarcodeLength: normalizeBarcodeLength(
        json['minimumBarcodeLength'] is num
            ? (json['minimumBarcodeLength']! as num).toInt()
            : defaultMinimumBarcodeLength,
      ),
      historyPageSize: normalizeHistoryPageSize(
        json['historyPageSize'] is num
            ? (json['historyPageSize']! as num).toInt()
            : defaultHistoryPageSize,
      ),
      scanBeepEnabled: json['scanBeepEnabled'] is bool
          ? json['scanBeepEnabled']! as bool
          : false,
      scanQrCodes: json['scanQrCodes'] is bool
          ? json['scanQrCodes']! as bool
          : false,
      extraValues: extraValues,
    );
  }

  static int normalizeBarcodeLength(int value) {
    if (value < minimumBarcodeLengthLowerBound) {
      return minimumBarcodeLengthLowerBound;
    }
    if (value > minimumBarcodeLengthUpperBound) {
      return minimumBarcodeLengthUpperBound;
    }
    return value;
  }

  static int normalizeHistoryPageSize(int value) {
    for (final int option in historyPageSizeOptions) {
      if (option == value) {
        return value;
      }
    }
    return defaultHistoryPageSize;
  }

  final WorkMode workMode;
  final RecordingOperationMode operationMode;
  final bool speechEnabled;
  final bool orderSpeechEnabled;
  final bool maxVolumeEnabled;
  final bool recordAudioEnabled;

  /// 是否给录像添加水印，默认开启；关闭后预览和成片都不再绘制水印。
  final bool watermarkEnabled;
  final bool manualTrackingValidationEnabled;
  final CameraCapabilityPreference shippingCameraCapabilityPreference;
  final CameraCapabilityPreference returnCameraCapabilityPreference;
  final Map<String, Object?>? cameraCapabilityState;
  final RecordingVideoCodec preferredVideoCodec;
  final RecordingSpecPreset recordingSpec;
  final RecordingOrientation recordingOrientation;
  final int startupNoticeVersion;
  final String lastLoggedAppVersion;
  final int lastLoggedAppBuildNumber;
  final String lastLoggedBuildIdentity;
  final String mobileUpdatePromptDate;
  final int mobileUpdatePromptCount;
  final bool lanBackupAutoEnabled;
  final bool galleryAutoBackupEnabled;
  final UnbackedRetentionPolicy unbackedRetention;
  final BackedRetentionPolicy backedRetention;
  final UnbackedRetentionPolicy returnUnbackedRetention;
  final BackedRetentionPolicy returnBackedRetention;
  final StoragePressurePolicy storagePressurePolicy;
  final Set<int> hiddenRemoteRecordingIds;
  final StorageNoticeState storageNoticeState;
  final int minimumBarcodeLength;
  final int historyPageSize;

  /// 扫码提示音，默认关闭：现场多数情况不需要出声。
  final bool scanBeepEnabled;

  /// 是否把二维码也当作面单号识别，默认关闭（只认一维条码）。
  final bool scanQrCodes;
  final Map<String, Object?> extraValues;

  CameraCapabilityPreference cameraCapabilityPreferenceFor(
    RecordingOperationMode mode,
  ) => mode == RecordingOperationMode.returnGoods
      ? returnCameraCapabilityPreference
      : shippingCameraCapabilityPreference;

  /// 当前发货/退货模式的兼容读取入口。
  CameraCapabilityPreference get cameraCapabilityPreference =>
      cameraCapabilityPreferenceFor(operationMode);

  AppSettings copyWith({
    WorkMode? workMode,
    RecordingOperationMode? operationMode,
    bool? speechEnabled,
    bool? orderSpeechEnabled,
    bool? maxVolumeEnabled,
    bool? recordAudioEnabled,
    bool? watermarkEnabled,
    bool? manualTrackingValidationEnabled,
    CameraCapabilityPreference? shippingCameraCapabilityPreference,
    CameraCapabilityPreference? returnCameraCapabilityPreference,
    Map<String, Object?>? cameraCapabilityState,
    RecordingVideoCodec? preferredVideoCodec,
    RecordingSpecPreset? recordingSpec,
    RecordingOrientation? recordingOrientation,
    int? startupNoticeVersion,
    String? lastLoggedAppVersion,
    int? lastLoggedAppBuildNumber,
    String? lastLoggedBuildIdentity,
    String? mobileUpdatePromptDate,
    int? mobileUpdatePromptCount,
    bool? lanBackupAutoEnabled,
    bool? galleryAutoBackupEnabled,
    UnbackedRetentionPolicy? unbackedRetention,
    BackedRetentionPolicy? backedRetention,
    UnbackedRetentionPolicy? returnUnbackedRetention,
    BackedRetentionPolicy? returnBackedRetention,
    StoragePressurePolicy? storagePressurePolicy,
    Set<int>? hiddenRemoteRecordingIds,
    StorageNoticeState? storageNoticeState,
    int? minimumBarcodeLength,
    int? historyPageSize,
    bool? scanBeepEnabled,
    bool? scanQrCodes,
  }) {
    return AppSettings(
      workMode: workMode ?? this.workMode,
      operationMode: operationMode ?? this.operationMode,
      speechEnabled: speechEnabled ?? this.speechEnabled,
      orderSpeechEnabled: orderSpeechEnabled ?? this.orderSpeechEnabled,
      maxVolumeEnabled: maxVolumeEnabled ?? this.maxVolumeEnabled,
      recordAudioEnabled: recordAudioEnabled ?? this.recordAudioEnabled,
      watermarkEnabled: watermarkEnabled ?? this.watermarkEnabled,
      manualTrackingValidationEnabled:
          manualTrackingValidationEnabled ??
          this.manualTrackingValidationEnabled,
      shippingCameraCapabilityPreference:
          shippingCameraCapabilityPreference ??
          this.shippingCameraCapabilityPreference,
      returnCameraCapabilityPreference:
          returnCameraCapabilityPreference ??
          this.returnCameraCapabilityPreference,
      cameraCapabilityState:
          cameraCapabilityState ?? this.cameraCapabilityState,
      preferredVideoCodec: preferredVideoCodec ?? this.preferredVideoCodec,
      recordingSpec: recordingSpec ?? this.recordingSpec,
      recordingOrientation: recordingOrientation ?? this.recordingOrientation,
      startupNoticeVersion: startupNoticeVersion ?? this.startupNoticeVersion,
      lastLoggedAppVersion: lastLoggedAppVersion ?? this.lastLoggedAppVersion,
      lastLoggedAppBuildNumber:
          lastLoggedAppBuildNumber ?? this.lastLoggedAppBuildNumber,
      lastLoggedBuildIdentity:
          lastLoggedBuildIdentity ?? this.lastLoggedBuildIdentity,
      mobileUpdatePromptDate:
          mobileUpdatePromptDate ?? this.mobileUpdatePromptDate,
      mobileUpdatePromptCount:
          mobileUpdatePromptCount ?? this.mobileUpdatePromptCount,
      lanBackupAutoEnabled: lanBackupAutoEnabled ?? this.lanBackupAutoEnabled,
      galleryAutoBackupEnabled:
          galleryAutoBackupEnabled ?? this.galleryAutoBackupEnabled,
      unbackedRetention: unbackedRetention ?? this.unbackedRetention,
      backedRetention: backedRetention ?? this.backedRetention,
      returnUnbackedRetention:
          returnUnbackedRetention ?? this.returnUnbackedRetention,
      returnBackedRetention:
          returnBackedRetention ?? this.returnBackedRetention,
      storagePressurePolicy:
          storagePressurePolicy ?? this.storagePressurePolicy,
      hiddenRemoteRecordingIds:
          hiddenRemoteRecordingIds ?? this.hiddenRemoteRecordingIds,
      storageNoticeState: storageNoticeState ?? this.storageNoticeState,
      minimumBarcodeLength: minimumBarcodeLength ?? this.minimumBarcodeLength,
      historyPageSize: historyPageSize ?? this.historyPageSize,
      scanBeepEnabled: scanBeepEnabled ?? this.scanBeepEnabled,
      scanQrCodes: scanQrCodes ?? this.scanQrCodes,
      extraValues: extraValues,
    );
  }

  /// 日志必须跟随设置模型自动扩展；这里只剔除与用户配置无关的运行状态。
  Map<String, Object?> toDiagnosticJson() {
    final Map<String, Object?> config = Map<String, Object?>.of(toJson());
    config.removeWhere(
      (String key, Object? _) => _runtimeOnlySettingKeys.contains(key),
    );
    return config;
  }

  String get diagnosticSignature => jsonEncode(toDiagnosticJson());

  static const Set<String> _runtimeOnlySettingKeys = <String>{
    'startupNoticeVersion',
    'lastLoggedAppVersion',
    'lastLoggedAppBuildNumber',
    'lastLoggedBuildIdentity',
    'mobileUpdatePromptDate',
    'mobileUpdatePromptCount',
    'hiddenRemoteRecordingIds',
    'storageNoticeState',
  };

  Map<String, Object?> toJson() => <String, Object?>{
    ...extraValues,
    'workMode': workMode.storageValue,
    'operationMode': operationMode.storageValue,
    'speechEnabled': speechEnabled,
    'orderSpeechEnabled': orderSpeechEnabled,
    'maxVolumeEnabled': maxVolumeEnabled,
    'recordAudioEnabled': recordAudioEnabled,
    'watermarkEnabled': watermarkEnabled,
    'manualTrackingValidationEnabled': manualTrackingValidationEnabled,
    'shippingCameraCapabilityPreference':
        shippingCameraCapabilityPreference.storageValue,
    'returnCameraCapabilityPreference':
        returnCameraCapabilityPreference.storageValue,
    'cameraCapabilityState': cameraCapabilityState,
    'preferredVideoCodec': preferredVideoCodec.storageValue,
    'recordingSpec': recordingSpec.storageValue,
    'recordingOrientation': recordingOrientation.storageValue,
    'startupNoticeVersion': startupNoticeVersion,
    'lastLoggedAppVersion': lastLoggedAppVersion,
    'lastLoggedAppBuildNumber': lastLoggedAppBuildNumber,
    'lastLoggedBuildIdentity': lastLoggedBuildIdentity,
    'mobileUpdatePromptDate': mobileUpdatePromptDate,
    'mobileUpdatePromptCount': mobileUpdatePromptCount,
    'lanBackupAutoEnabled': lanBackupAutoEnabled,
    'galleryAutoBackupEnabled': galleryAutoBackupEnabled,
    'unbackedRetention': unbackedRetention.storageValue,
    'backedRetention': backedRetention.storageValue,
    'returnUnbackedRetention': returnUnbackedRetention.storageValue,
    'returnBackedRetention': returnBackedRetention.storageValue,
    'storagePressurePolicy': storagePressurePolicy.storageValue,
    'hiddenRemoteRecordingIds': hiddenRemoteRecordingIds.toList()..sort(),
    'storageNoticeState': storageNoticeState.toJson(),
    'minimumBarcodeLength': minimumBarcodeLength,
    'historyPageSize': historyPageSize,
    'scanBeepEnabled': scanBeepEnabled,
    'scanQrCodes': scanQrCodes,
  };
}
