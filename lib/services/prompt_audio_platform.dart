import 'package:flutter/services.dart';

abstract interface class PromptAudioPlatform {
  Future<void> prepare({
    required String key,
    required Uint8List bytes,
    required String mimeType,
  });

  Future<void> play(String key);

  Future<void> stop();

  Future<void> dispose();
}

class IosPromptAudioPlatform implements PromptAudioPlatform {
  IosPromptAudioPlatform({MethodChannel? channel})
    : _channel =
          channel ??
          const MethodChannel('app.packingproof.mobile/prompt_audio');

  final MethodChannel _channel;

  @override
  Future<void> prepare({
    required String key,
    required Uint8List bytes,
    required String mimeType,
  }) => _channel.invokeMethod<void>('prepare', <String, Object?>{
    'key': key,
    'bytes': bytes,
    'mimeType': mimeType,
  });

  @override
  Future<void> play(String key) =>
      _channel.invokeMethod<void>('play', <String, Object?>{'key': key});

  @override
  Future<void> stop() => _channel.invokeMethod<void>('stop');

  @override
  Future<void> dispose() => _channel.invokeMethod<void>('dispose');
}
