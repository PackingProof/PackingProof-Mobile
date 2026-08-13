import 'platform_capabilities.dart';

/// 当前平台不支持该能力。
class CapabilityUnavailableException implements Exception {
  const CapabilityUnavailableException(this.capability, {this.reason});

  final PlatformCapability capability;
  final String? reason;

  @override
  String toString() => reason ?? '当前平台暂不支持该功能';
}

/// 用户未授予必要权限。
class PermissionDeniedException implements Exception {
  const PermissionDeniedException(this.message);

  final String message;

  @override
  String toString() => message;
}

/// 平台具备能力，但当前设备不可用。
class DeviceUnavailableException implements Exception {
  const DeviceUnavailableException(this.message);

  final String message;

  @override
  String toString() => message;
}

/// 平台能力临时不可用，通常可以稍后重试。
class TemporarilyUnavailableException implements Exception {
  const TemporarilyUnavailableException(this.message);

  final String message;

  @override
  String toString() => message;
}
