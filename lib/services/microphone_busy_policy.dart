import 'package:flutter/services.dart';

/// 麦克风被通话或其他应用占用时的统一判定与提示。
///
/// iOS 音频会话激活失败会抛 `audio_session_unavailable`；Android 的
/// `AudioRecord` 初始化或启动失败只给中文错误文本。两种情况对操作员的处理
/// 方式相同：结束通话或关掉占用麦克风的应用后重试，所以要落到同一句提示，
/// 而不是笼统的「录制失败」。
abstract final class MicrophoneBusyPolicy {
  /// 两端原生失败时统一使用的错误码。
  static const String code = 'audio_session_unavailable';

  /// 操作员可见提示：先说原因，再给可执行的动作。
  static const String notice =
      '麦克风被占用，可能正在通话\n请结束通话或关闭占用麦克风的应用后重试';

  /// 语音提示文案，对应 [SpeechPrompt.microphoneBusy]。
  static const String speechText = '麦克风被占用，请结束通话后重试';

  /// 错误是否属于「麦克风被占用」。
  ///
  /// 优先看类型化错误码；旧版本或平台插件只给文本时，退化为关键词匹配。
  static bool matches(Object? error) {
    if (error is PlatformException) {
      if (error.code == code) return true;
      return _textMatches('${error.code} ${error.message ?? ''}');
    }
    return _textMatches('$error');
  }

  static bool _textMatches(String value) {
    final String text = value.toLowerCase();
    return text.contains(code) ||
        text.contains('麦克风') ||
        text.contains('microphone');
  }
}
