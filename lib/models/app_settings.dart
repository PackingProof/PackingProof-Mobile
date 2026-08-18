import 'backup_retention_policy.dart';
import 'work_mode.dart';
import 'storage_notice.dart';
import 'recording_video_codec.dart';
import 'recording_spec.dart';
import 'recording_operation_mode.dart';

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
    this.nativeRecordingFallback = false,
    this.cameraCapabilityState,
    this.preferredVideoCodec = RecordingVideoCodec.hevc,
    this.recordingSpec = RecordingSpecPreset.hd1080p30,
    this.startupNoticeVersion = 0,
    this.lastLoggedAppVersion = '',
    this.lastLoggedAppBuildNumber = 0,
    this.lastLoggedBuildIdentity = '',
    this.mobileUpdatePromptDate = '',
    this.mobileUpdatePromptCount = 0,
    this.lanBackupAutoEnabled = true,
    this.unbackedRetention = UnbackedRetentionPolicy.days30,
    this.backedRetention = BackedRetentionPolicy.days7,
    this.hiddenRemoteRecordingIds = const <int>{},
    this.storageNoticeState = const StorageNoticeState(),
    this.minimumBarcodeLength = defaultMinimumBarcodeLength,
    this.historyPageSize = defaultHistoryPageSize,
    this.extraValues = const <String, Object?>{},
  });

  factory AppSettings.fromJson(Map<String, Object?> json) {
    final Map<String, Object?> extraValues = Map<String, Object?>.of(json)
      ..remove('workMode')
      ..remove('operationMode')
      ..remove('speechEnabled')
      ..remove('orderSpeechEnabled')
      ..remove('maxVolumeEnabled')
      ..remove('nativeRecordingFallback')
      ..remove('cameraCapabilityState')
      ..remove('preferredVideoCodec')
      ..remove('recordingSpec')
      ..remove('startupNoticeVersion')
      ..remove('lastLoggedAppVersion')
      ..remove('lastLoggedAppBuildNumber')
      ..remove('lastLoggedBuildIdentity')
      ..remove('mobileUpdatePromptDate')
      ..remove('mobileUpdatePromptCount')
      ..remove('lanBackupAutoEnabled')
      ..remove('unbackedRetention')
      ..remove('backedRetention');
    extraValues.remove('storageNoticeState');
    extraValues.remove('minimumBarcodeLength');
    extraValues.remove('historyPageSize');
    final Set<int> hiddenRemoteRecordingIds =
        ((json['hiddenRemoteRecordingIds'] as List<Object?>?) ?? const [])
            .whereType<num>()
            .map((value) => value.toInt())
            .where((value) => value > 0)
            .toSet();
    extraValues.remove('hiddenRemoteRecordingIds');
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
      nativeRecordingFallback: json['nativeRecordingFallback'] is bool
          ? json['nativeRecordingFallback']! as bool
          : false,
      cameraCapabilityState: json['cameraCapabilityState'] is Map
          ? Map<String, Object?>.from(
              json['cameraCapabilityState']! as Map<Object?, Object?>,
            )
          : null,
      preferredVideoCodec: recordingVideoCodecFromStorage(
        json['preferredVideoCodec'],
      ),
      recordingSpec: recordingSpecFromStorage(json['recordingSpec']),
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
      unbackedRetention: unbackedRetentionFromStorage(
        json['unbackedRetention'],
      ),
      backedRetention: backedRetentionFromStorage(json['backedRetention']),
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
  final bool nativeRecordingFallback;
  final Map<String, Object?>? cameraCapabilityState;
  final RecordingVideoCodec preferredVideoCodec;
  final RecordingSpecPreset recordingSpec;
  final int startupNoticeVersion;
  final String lastLoggedAppVersion;
  final int lastLoggedAppBuildNumber;
  final String lastLoggedBuildIdentity;
  final String mobileUpdatePromptDate;
  final int mobileUpdatePromptCount;
  final bool lanBackupAutoEnabled;
  final UnbackedRetentionPolicy unbackedRetention;
  final BackedRetentionPolicy backedRetention;
  final Set<int> hiddenRemoteRecordingIds;
  final StorageNoticeState storageNoticeState;
  final int minimumBarcodeLength;
  final int historyPageSize;
  final Map<String, Object?> extraValues;

  AppSettings copyWith({
    WorkMode? workMode,
    RecordingOperationMode? operationMode,
    bool? speechEnabled,
    bool? orderSpeechEnabled,
    bool? maxVolumeEnabled,
    bool? recordAudioEnabled,
    bool? nativeRecordingFallback,
    Map<String, Object?>? cameraCapabilityState,
    RecordingVideoCodec? preferredVideoCodec,
    RecordingSpecPreset? recordingSpec,
    int? startupNoticeVersion,
    String? lastLoggedAppVersion,
    int? lastLoggedAppBuildNumber,
    String? lastLoggedBuildIdentity,
    String? mobileUpdatePromptDate,
    int? mobileUpdatePromptCount,
    bool? lanBackupAutoEnabled,
    UnbackedRetentionPolicy? unbackedRetention,
    BackedRetentionPolicy? backedRetention,
    Set<int>? hiddenRemoteRecordingIds,
    StorageNoticeState? storageNoticeState,
    int? minimumBarcodeLength,
    int? historyPageSize,
  }) {
    return AppSettings(
      workMode: workMode ?? this.workMode,
      operationMode: operationMode ?? this.operationMode,
      speechEnabled: speechEnabled ?? this.speechEnabled,
      orderSpeechEnabled: orderSpeechEnabled ?? this.orderSpeechEnabled,
      maxVolumeEnabled: maxVolumeEnabled ?? this.maxVolumeEnabled,
      recordAudioEnabled: recordAudioEnabled ?? this.recordAudioEnabled,
      nativeRecordingFallback:
          nativeRecordingFallback ?? this.nativeRecordingFallback,
      cameraCapabilityState:
          cameraCapabilityState ?? this.cameraCapabilityState,
      preferredVideoCodec: preferredVideoCodec ?? this.preferredVideoCodec,
      recordingSpec: recordingSpec ?? this.recordingSpec,
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
      unbackedRetention: unbackedRetention ?? this.unbackedRetention,
      backedRetention: backedRetention ?? this.backedRetention,
      hiddenRemoteRecordingIds:
          hiddenRemoteRecordingIds ?? this.hiddenRemoteRecordingIds,
      storageNoticeState: storageNoticeState ?? this.storageNoticeState,
      minimumBarcodeLength: minimumBarcodeLength ?? this.minimumBarcodeLength,
      historyPageSize: historyPageSize ?? this.historyPageSize,
      extraValues: extraValues,
    );
  }

  Map<String, Object?> toJson() => <String, Object?>{
    ...extraValues,
    'workMode': workMode.storageValue,
    'operationMode': operationMode.storageValue,
    'speechEnabled': speechEnabled,
    'orderSpeechEnabled': orderSpeechEnabled,
    'maxVolumeEnabled': maxVolumeEnabled,
    'recordAudioEnabled': recordAudioEnabled,
    'nativeRecordingFallback': nativeRecordingFallback,
    'cameraCapabilityState': cameraCapabilityState,
    'preferredVideoCodec': preferredVideoCodec.storageValue,
    'recordingSpec': recordingSpec.storageValue,
    'startupNoticeVersion': startupNoticeVersion,
    'lastLoggedAppVersion': lastLoggedAppVersion,
    'lastLoggedAppBuildNumber': lastLoggedAppBuildNumber,
    'lastLoggedBuildIdentity': lastLoggedBuildIdentity,
    'mobileUpdatePromptDate': mobileUpdatePromptDate,
    'mobileUpdatePromptCount': mobileUpdatePromptCount,
    'lanBackupAutoEnabled': lanBackupAutoEnabled,
    'unbackedRetention': unbackedRetention.storageValue,
    'backedRetention': backedRetention.storageValue,
    'hiddenRemoteRecordingIds': hiddenRemoteRecordingIds.toList()..sort(),
    'storageNoticeState': storageNoticeState.toJson(),
    'minimumBarcodeLength': minimumBarcodeLength,
    'historyPageSize': historyPageSize,
  };
}
