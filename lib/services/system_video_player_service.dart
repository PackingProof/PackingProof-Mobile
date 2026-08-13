import 'package:flutter/services.dart';

import '../platform/contracts/media_platform.dart';
import '../platform/platform_container.dart';

/// 设备视频解码能力摘要，用于解释播放失败并给出可执行的编码建议。
class VideoDecodeSupport {
  const VideoDecodeSupport({
    required this.manufacturer,
    required this.brand,
    required this.model,
    required this.sdkInt,
    required this.release,
    required this.hasHevcDecoder,
    required this.hasAvcDecoder,
    this.forceSoftwareDecode = false,
  });

  final String manufacturer;
  final String brand;
  final String model;
  final int sdkInt;
  final String release;
  final bool hasHevcDecoder;
  final bool hasAvcDecoder;

  /// 本机 ExoPlayer 是否已配置为优先软件解码（鸿蒙/华为 API 30+）。
  final bool forceSoftwareDecode;

  factory VideoDecodeSupport.fromMap(Map<Object?, Object?> map) {
    return VideoDecodeSupport(
      manufacturer: '${map['manufacturer'] ?? ''}',
      brand: '${map['brand'] ?? ''}',
      model: '${map['model'] ?? ''}',
      sdkInt: (map['sdkInt'] as num?)?.toInt() ?? 0,
      release: '${map['release'] ?? ''}',
      hasHevcDecoder: map['hasHevcDecoder'] == true,
      hasAvcDecoder: map['hasAvcDecoder'] == true,
      forceSoftwareDecode: map['forceSoftwareDecode'] == true,
    );
  }
}

/// 系统播放器兜底与视频轨道信息查询。
class SystemVideoPlayerService {
  SystemVideoPlayerService({
    MethodChannel? channel,
    SystemMediaPresenter? platform,
  }) : _platform =
           platform ??
           (channel != null
               ? _LegacySystemMediaPresenter(channel)
               : AppContainer.forCurrentPlatform().systemMediaPresenter);

  final SystemMediaPresenter _platform;

  /// 读取文件第一条视频轨的 mime（如 video/hevc、video/avc）；失败返回 null。
  Future<String?> getVideoTrackMime(String path) async {
    try {
      return await _platform.getVideoTrackMime(path);
    } on Object {
      return null;
    }
  }

  /// 查询设备解码能力；失败返回 null（不影响播放流程）。
  Future<VideoDecodeSupport?> getVideoDecodeSupport() async {
    try {
      final SystemVideoDecodeSupport? values = await _platform
          .getVideoDecodeSupport();
      if (values == null) return null;
      return VideoDecodeSupport(
        manufacturer: values.manufacturer,
        brand: values.brand,
        model: values.model,
        sdkInt: values.sdkInt,
        release: values.release,
        hasHevcDecoder: values.hasHevcDecoder,
        hasAvcDecoder: values.hasAvcDecoder,
        forceSoftwareDecode: values.forceSoftwareDecode,
      );
    } on Object {
      return null;
    }
  }

  /// 用系统播放器打开本地录像文件。
  Future<void> openWithSystemPlayer(String path) async {
    await _platform.openWithSystemPlayer(path);
  }
}

class _LegacySystemMediaPresenter implements SystemMediaPresenter {
  const _LegacySystemMediaPresenter(this.channel);

  final MethodChannel channel;

  @override
  Future<String?> getVideoTrackMime(String path) async {
    try {
      return await channel.invokeMethod<String>(
        'getVideoTrackMime',
        <String, Object>{'path': path},
      );
    } on Object {
      return null;
    }
  }

  @override
  Future<SystemVideoDecodeSupport?> getVideoDecodeSupport() async {
    final Map<Object?, Object?>? values = await channel
        .invokeMethod<Map<Object?, Object?>>('getVideoDecodeSupport');
    if (values == null) return null;
    return SystemVideoDecodeSupport(
      manufacturer: '${values['manufacturer'] ?? ''}',
      brand: '${values['brand'] ?? ''}',
      model: '${values['model'] ?? ''}',
      sdkInt: (values['sdkInt'] as num?)?.toInt() ?? 0,
      release: '${values['release'] ?? ''}',
      hasHevcDecoder: values['hasHevcDecoder'] == true,
      hasAvcDecoder: values['hasAvcDecoder'] == true,
      forceSoftwareDecode: values['forceSoftwareDecode'] == true,
    );
  }

  @override
  Future<void> openWithSystemPlayer(String path) => channel.invokeMethod<void>(
    'openWithSystemPlayer',
    <String, Object>{'path': path},
  );
}
