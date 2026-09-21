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

  /// 单次空间回收最多向电脑重新确认的录像数量。
  static const int confirmationLimit = 16;

  /// 到期清理可以复用的电脑确认有效期。
  static const Duration confirmationGrace = Duration(hours: 24);

  static Map<String, Object?> toNativeRequest() => <String, Object?>{
    'storageMinimumBytes': minimumBytes,
    'storageWarningBytes': warningBytes,
    'storageTargetBytes': targetBytes,
    'storageAttestationFreshnessMs': attestationFreshness.inMilliseconds,
    'storageConfirmationLimit': confirmationLimit,
    'storageConfirmationGraceMs': confirmationGrace.inMilliseconds,
  };

  static String get minimumLabel => label(minimumBytes);

  static String get warningLabel => label(warningBytes);

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
