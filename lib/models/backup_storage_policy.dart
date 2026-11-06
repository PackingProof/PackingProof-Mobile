/// 空间不足时的清理策略。
enum StoragePressurePolicy {
  /// 优先保留录像：只清理电脑确认过的备份，腾不出空间就停止录制。
  preserveFootage,

  /// 优先继续录制：电脑可有可无，可能删除未备份录像。
  preserveRecording;

  /// 出厂默认策略：空间不足时优先接着录，必要时删除最老的未备份录像。
  static const StoragePressurePolicy defaultValue =
      StoragePressurePolicy.preserveRecording;

  bool get deletesUnbacked => this == StoragePressurePolicy.preserveRecording;

  String get storageValue => name;

  String get label => switch (this) {
    StoragePressurePolicy.preserveFootage => '优先保留录像',
    StoragePressurePolicy.preserveRecording => '优先继续录制',
  };

  String get description => switch (this) {
    StoragePressurePolicy.preserveFootage => '只清理电脑确认过的备份，腾不出空间就停止录制',
    StoragePressurePolicy.preserveRecording => '电脑可有可无，可能删除未备份录像',
  };
}

StoragePressurePolicy storagePressurePolicyFromStorage(Object? value) =>
    StoragePressurePolicy.values.firstWhere(
      (StoragePressurePolicy item) => item.name == value,
      orElse: () => StoragePressurePolicy.defaultValue,
    );

/// 录像存储与电脑确认规则的唯一来源。
///
/// 阈值、确认时效、单次回收上限都只在这里维护，启动时通过 [toNativeRequest]
/// 下发给 Android（Kotlin）与 iOS（Swift）。两端不再各自定义这些数值，改动这
/// 一处即可同步两端行为；两端在下发前使用的兜底值由契约测试守门。
class BackupStoragePolicy {
  const BackupStoragePolicy._();

  /// 低于该值必须回收空间，回收不出空间就不再开始或继续录像。
  ///
  /// 取 1GB：720p 约 45MB/分钟，够录二十分钟以上；门槛太高会让手机还有一
  /// 两个 G 的老用户被拦下，反而更影响连续打包。
  static const int minimumBytes = 1024 * 1024 * 1024;

  /// 低于该值提醒操作员；空间回收的目标余量也取该值。
  ///
  /// 保留 3GB 缓冲，避免刚好越过 1GB 门槛后很快再次触发清理。
  static const int warningBytes = 4 * 1024 * 1024 * 1024;
  static const int targetBytes = warningBytes;

  static Map<String, Object?> toNativeRequest({
    StoragePressurePolicy pressurePolicy =
        StoragePressurePolicy.defaultValue,
  }) => <String, Object?>{
    'storageMinimumBytes': minimumBytes,
    'storageWarningBytes': warningBytes,
    'storageTargetBytes': targetBytes,
    'storageDeleteUnbackedOnPressure': pressurePolicy.deletesUnbacked,
  };

  static String get minimumLabel => label(minimumBytes);

  static String get warningLabel => label(warningBytes);

  /// 开始录像被空间不足拦住时的提示，数值随策略变化。
  static String get insufficientToStartMessage =>
      '存储空间不足 $minimumLabel，请清理空间或连接电脑完成录像备份';

  /// 老用户默认的「优先保留录像」下空间不足时的横幅提示：只说原因，
  /// 再给一条可执行的设置路径，操作员才知道怎么让打包不中断。
  static const String preserveFootageInsufficientNotice =
      '预留空间不足，录像已停止\n'
      '把「清理策略」改为「优先继续录制」，空间不足时会自动清理最老的录像，让打包不中断';

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
