import 'backup_retention_policy.dart';
import 'work_mode.dart';
import 'storage_notice.dart';
import 'recording_video_codec.dart';
import 'recording_spec.dart';

class AppSettings {
  static const int defaultMinimumBarcodeLength = 11;
  static const int minimumBarcodeLengthLowerBound = 8;
  static const int minimumBarcodeLengthUpperBound = 40;

  const AppSettings({
    this.workMode = WorkMode.continuousScan,
    this.speechEnabled = true,
    this.orderSpeechEnabled = true,
    this.maxVolumeEnabled = true,
    this.recordAudioEnabled = true,
    this.preferredVideoCodec = RecordingVideoCodec.hevc,
    this.recordingSpec = RecordingSpecPreset.hd1080p30,
    this.startupNoticeVersion = 0,
    this.mobileUpdatePromptDate = '',
    this.mobileUpdatePromptCount = 0,
    this.lanBackupAutoEnabled = true,
    this.unbackedRetention = UnbackedRetentionPolicy.days30,
    this.backedRetention = BackedRetentionPolicy.days7,
    this.hiddenRemoteRecordingIds = const <int>{},
    this.storageNoticeState = const StorageNoticeState(),
    this.minimumBarcodeLength = defaultMinimumBarcodeLength,
    this.extraValues = const <String, Object?>{},
  });

  factory AppSettings.fromJson(Map<String, Object?> json) {
    final Map<String, Object?> extraValues = Map<String, Object?>.of(json)
      ..remove('workMode')
      ..remove('speechEnabled')
      ..remove('orderSpeechEnabled')
      ..remove('maxVolumeEnabled')
      ..remove('preferredVideoCodec')
      ..remove('recordingSpec')
      ..remove('startupNoticeVersion')
      ..remove('mobileUpdatePromptDate')
      ..remove('mobileUpdatePromptCount')
      ..remove('lanBackupAutoEnabled')
      ..remove('unbackedRetention')
      ..remove('backedRetention');
    extraValues.remove('storageNoticeState');
    extraValues.remove('minimumBarcodeLength');
    final Set<int> hiddenRemoteRecordingIds =
        ((json['hiddenRemoteRecordingIds'] as List<Object?>?) ?? const [])
            .whereType<num>()
            .map((value) => value.toInt())
            .where((value) => value > 0)
            .toSet();
    extraValues.remove('hiddenRemoteRecordingIds');
    return AppSettings(
      workMode: workModeFromStorage(json['workMode']),
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
      preferredVideoCodec: recordingVideoCodecFromStorage(
        json['preferredVideoCodec'],
      ),
      recordingSpec: recordingSpecFromStorage(json['recordingSpec']),
      startupNoticeVersion: json['startupNoticeVersion'] is num
          ? (json['startupNoticeVersion']! as num).toInt()
          : 0,
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

  final WorkMode workMode;
  final bool speechEnabled;
  final bool orderSpeechEnabled;
  final bool maxVolumeEnabled;
  final bool recordAudioEnabled;
  final RecordingVideoCodec preferredVideoCodec;
  final RecordingSpecPreset recordingSpec;
  final int startupNoticeVersion;
  final String mobileUpdatePromptDate;
  final int mobileUpdatePromptCount;
  final bool lanBackupAutoEnabled;
  final UnbackedRetentionPolicy unbackedRetention;
  final BackedRetentionPolicy backedRetention;
  final Set<int> hiddenRemoteRecordingIds;
  final StorageNoticeState storageNoticeState;
  final int minimumBarcodeLength;
  final Map<String, Object?> extraValues;

  AppSettings copyWith({
    WorkMode? workMode,
    bool? speechEnabled,
    bool? orderSpeechEnabled,
    bool? maxVolumeEnabled,
    bool? recordAudioEnabled,
    RecordingVideoCodec? preferredVideoCodec,
    RecordingSpecPreset? recordingSpec,
    int? startupNoticeVersion,
    String? mobileUpdatePromptDate,
    int? mobileUpdatePromptCount,
    bool? lanBackupAutoEnabled,
    UnbackedRetentionPolicy? unbackedRetention,
    BackedRetentionPolicy? backedRetention,
    Set<int>? hiddenRemoteRecordingIds,
    StorageNoticeState? storageNoticeState,
    int? minimumBarcodeLength,
  }) {
    return AppSettings(
      workMode: workMode ?? this.workMode,
      speechEnabled: speechEnabled ?? this.speechEnabled,
      orderSpeechEnabled: orderSpeechEnabled ?? this.orderSpeechEnabled,
      maxVolumeEnabled: maxVolumeEnabled ?? this.maxVolumeEnabled,
      recordAudioEnabled: recordAudioEnabled ?? this.recordAudioEnabled,
      preferredVideoCodec: preferredVideoCodec ?? this.preferredVideoCodec,
      recordingSpec: recordingSpec ?? this.recordingSpec,
      startupNoticeVersion: startupNoticeVersion ?? this.startupNoticeVersion,
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
      extraValues: extraValues,
    );
  }

  Map<String, Object?> toJson() => <String, Object?>{
    ...extraValues,
    'workMode': workMode.storageValue,
    'speechEnabled': speechEnabled,
    'orderSpeechEnabled': orderSpeechEnabled,
    'maxVolumeEnabled': maxVolumeEnabled,
    'recordAudioEnabled': recordAudioEnabled,
    'preferredVideoCodec': preferredVideoCodec.storageValue,
    'recordingSpec': recordingSpec.storageValue,
    'startupNoticeVersion': startupNoticeVersion,
    'mobileUpdatePromptDate': mobileUpdatePromptDate,
    'mobileUpdatePromptCount': mobileUpdatePromptCount,
    'lanBackupAutoEnabled': lanBackupAutoEnabled,
    'unbackedRetention': unbackedRetention.storageValue,
    'backedRetention': backedRetention.storageValue,
    'hiddenRemoteRecordingIds': hiddenRemoteRecordingIds.toList()..sort(),
    'storageNoticeState': storageNoticeState.toJson(),
    'minimumBarcodeLength': minimumBarcodeLength,
  };
}
