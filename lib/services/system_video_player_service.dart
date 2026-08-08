import 'package:flutter/services.dart';

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
    this.preferH264 = false,
  });

  final String manufacturer;
  final String brand;
  final String model;
  final int sdkInt;
  final String release;
  final bool hasHevcDecoder;
  final bool hasAvcDecoder;

  /// 鸿蒙/华为等机型虽然声明支持 H.265 解码，但应用内播放兼容性较差，
  /// 新录像应自动使用 H.264。
  final bool preferH264;

  /// 应用内 H.265 回放是否可靠（有解码器且厂商未被标记为兼容性风险）。
  bool get hevcRecommended => hasHevcDecoder && !preferH264;

  factory VideoDecodeSupport.fromMap(Map<Object?, Object?> map) {
    return VideoDecodeSupport(
      manufacturer: '${map['manufacturer'] ?? ''}',
      brand: '${map['brand'] ?? ''}',
      model: '${map['model'] ?? ''}',
      sdkInt: (map['sdkInt'] as num?)?.toInt() ?? 0,
      release: '${map['release'] ?? ''}',
      hasHevcDecoder: map['hasHevcDecoder'] == true,
      hasAvcDecoder: map['hasAvcDecoder'] == true,
      preferH264: map['preferH264'] == true,
    );
  }
}

/// 系统播放器兜底与视频轨道信息查询。
class SystemVideoPlayerService {
  static const MethodChannel _channel = MethodChannel(
    'app.packingproof.mobile/system_player',
  );

  /// 读取文件第一条视频轨的 mime（如 video/hevc、video/avc）；失败返回 null。
  Future<String?> getVideoTrackMime(String path) async {
    try {
      return await _channel.invokeMethod<String>(
        'getVideoTrackMime',
        <String, Object>{'path': path},
      );
    } on Object {
      return null;
    }
  }

  /// 查询设备解码能力；失败返回 null（不影响播放流程）。
  Future<VideoDecodeSupport?> getVideoDecodeSupport() async {
    try {
      final Map<Object?, Object?>? values = await _channel
          .invokeMethod<Map<Object?, Object?>>('getVideoDecodeSupport');
      if (values == null) return null;
      return VideoDecodeSupport.fromMap(values);
    } on Object {
      return null;
    }
  }

  /// 用系统播放器打开本地录像文件。
  Future<void> openWithSystemPlayer(String path) async {
    await _channel.invokeMethod<void>('openWithSystemPlayer', <String, Object>{
      'path': path,
    });
  }
}
