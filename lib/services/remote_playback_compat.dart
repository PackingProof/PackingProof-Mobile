import 'system_video_player_service.dart';

/// 远程播放地址的 compat 参数工具：决定直传原片还是请求 H.264 转码。
class RemotePlaybackCompat {
  const RemotePlaybackCompat._();

  static const String direct = '0';
  static const String transcode = '1';

  /// 按视频编码与设备解码能力解析播放地址。
  /// H.264 始终直传；H.265/HEVC 或编码缺失时，本机支持 HEVC 就直传，否则转码。
  static Uri resolvePlaybackUri(
    Uri uri, {
    required VideoDecodeSupport? decodeSupport,
    String? videoCodec,
  }) {
    final String codec = (videoCodec ?? '').trim().toLowerCase();
    final bool directPlayback =
        codec == 'h264' || (decodeSupport?.hevcRecommended ?? false);
    return withCompat(uri, directPlayback ? direct : transcode);
  }

  /// 替换/新增 compat 参数，保留 ticket 等其他查询参数。
  static Uri withCompat(Uri uri, String compat) {
    final Map<String, String> query = Map<String, String>.from(
      uri.queryParameters,
    );
    query['compat'] = compat;
    return uri.replace(queryParameters: query);
  }

  static bool isDirect(Uri uri) => uri.queryParameters['compat'] == direct;
}
