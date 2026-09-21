/// 空间不足时的取舍策略。
enum StoragePressurePolicy {
  /// 优先保留录像：只清理电脑确认过的备份，腾不出空间就停止录制。
  preserveFootage,

  /// 优先继续录制：电脑可有可无，空间不足时按最老优先删除，可能删除未备份录像。
  preserveRecording;

  bool get deletesUnbacked => this == StoragePressurePolicy.preserveRecording;

  String get storageValue => name;

  String get label => switch (this) {
    StoragePressurePolicy.preserveFootage => '优先保留录像',
    StoragePressurePolicy.preserveRecording => '优先继续录制',
  };
}

StoragePressurePolicy storagePressurePolicyFromStorage(Object? value) =>
    StoragePressurePolicy.values.firstWhere(
      (StoragePressurePolicy item) => item.name == value,
      orElse: () => StoragePressurePolicy.preserveFootage,
    );

/// 录像存储与电脑确认规则的唯一来源。
///
/// 阈值、确认时效、单次回收上限都只在这里维护，启动时通过 [toNativeRequest]
/// 下发给 Android（Kotlin）与 iOS（Swift）。两端不再各自定义这些数值，改动这
/// 一处即可同步两端行为；两端在下发前使用的兜底值由契约测试守门。
class BackupStoragePolicy {
  const BackupStoragePolicy._();

  /// 低于该值必须回收空间，回收不出空间就不再开始或继续录像。
  static const int minimumBytes = 2 * 1024 * 1024 * 1024;

  /// 低于该值提醒操作员；空间回收的目标余量也取该值。
  static const int warningBytes = 3 * 1024 * 1024 * 1024;
  static const int targetBytes = warningBytes;

  /// “刚向电脑确认过”的有效期，超期必须重新向电脑确认才能删除录像。
  static const Duration attestationFreshness = Duration(minutes: 5);

  /// 单次空间回收最多向电脑重新确认的录像数量。录像普遍只有几十兆，一次回收往往
  /// 需要清掉几十条才能腾出目标余量；局域网确认很快，电脑不可达时会立即停止。
  static const int confirmationLimit = 64;

  /// 到期清理可以复用的电脑确认有效期。
  static const Duration confirmationGrace = Duration(hours: 24);

  static Map<String, Object?> toNativeRequest({
    StoragePressurePolicy pressurePolicy =
        StoragePressurePolicy.preserveFootage,
  }) => <String, Object?>{
    'storageMinimumBytes': minimumBytes,
    'storageWarningBytes': warningBytes,
    'storageTargetBytes': targetBytes,
    'storageAttestationFreshnessMs': attestationFreshness.inMilliseconds,
    'storageConfirmationLimit': confirmationLimit,
    'storageConfirmationGraceMs': confirmationGrace.inMilliseconds,
    'storageDeleteUnbackedOnPressure': pressurePolicy.deletesUnbacked,
  };

  static String get minimumLabel => label(minimumBytes);

  static String get warningLabel => label(warningBytes);

  /// 开始录像被空间不足拦住时的提示，数值随策略变化。
  static String get insufficientToStartMessage =>
      '存储空间不足 $minimumLabel，请清理空间或连接电脑完成录像备份';

  /// 字节数文案：整 GB 不带小数，其余保留一位小数，小于 1GB 用 MB。
  static String label(int bytes) {
    final double gigabytes = bytes / (1024 * 1024 * 1024);
    if (gigabytes >= 1) {
      final String value = gigabytes.toStringAsFixed(
        gigabytes == gigabytes.roundToDouble() ? 0 : 1,
      );
      return '${value}GB';
    }
    return '${(bytes / (1024 * 1024)).round()}MB';
  }
}
