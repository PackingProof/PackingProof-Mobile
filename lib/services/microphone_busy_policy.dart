import 'package:flutter/services.dart';

/// 麦克风被其他应用占用（音频会话优先级不足）时的统一判定与提示。
///
/// iOS 音频会话激活失败返回 `NSOSStatusErrorDomain 561017449（'!pri'，
/// insufficientPriority）`：抢不到音频会话，系统里另有更高优先级的音频
/// 占用（通话、微信语音、录音、导航、Siri 等，不限于打电话）。Android 的
/// `AudioRecord` 初始化或启动失败只给中文错误文本，处理方式相同：关掉占用
/// 麦克风的应用后重试，所以要落到同一句提示，而不是笼统的「录制失败」。
abstract final class MicrophoneBusyPolicy {
  /// 两端原生失败时统一使用的错误码。
  static const String code = 'audio_session_unavailable';

  /// 操作员可见提示：先说原因，再给可执行的动作。
  static const String notice =
      '麦克风被其他应用占用，可能是在通话、语音或录音\n'
      '请关闭占用麦克风的应用，本机正在自动重试';

  /// 语音提示文案，对应 [SpeechPrompt.microphoneBusy]。
  static const String speechText = '麦克风被占用，请关闭占用麦克风的应用后重试';

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
