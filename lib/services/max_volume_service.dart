import 'package:flutter/services.dart';

import '../platform/contracts/media_platform.dart';
import '../platform/platform_container.dart';

abstract interface class MaxVolumeSink {
  Future<void> beginSession();

  Future<void> endSession();

  Future<void> disable();

  Future<void> boost();

  Future<void> dispose();
}

class MaxVolumeService implements MaxVolumeSink {
  MaxVolumeService({
    MethodChannel? channel,
    AlertAudioSessionPlatform? platform,
  }) : _platform =
           platform ??
           (channel != null
               ? _LegacyAlertAudioSessionPlatform(channel)
               : AppContainer.forCurrentPlatform().alertAudioSession);

  final AlertAudioSessionPlatform _platform;

  @override
  Future<void> beginSession() => _platform.beginSession();

  @override
  Future<void> endSession() => _platform.endSession();

  @override
  Future<void> disable() => _platform.disable();

  @override
  Future<void> boost() => _platform.boost();

  @override
  Future<void> dispose() => endSession();
}

class _LegacyAlertAudioSessionPlatform implements AlertAudioSessionPlatform {
  const _LegacyAlertAudioSessionPlatform(this.channel);

  final MethodChannel channel;

  @override
  Future<void> beginSession() => channel.invokeMethod<void>('beginSession');

  @override
  Future<void> endSession() => channel.invokeMethod<void>('endSession');

  @override
  Future<void> disable() => channel.invokeMethod<void>('disable');

  @override
  Future<void> boost() => channel.invokeMethod<void>('boost');

  @override
  Future<void> dispose() => endSession();
}
