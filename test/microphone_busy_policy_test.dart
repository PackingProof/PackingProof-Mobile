import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:packing_proof_mobile/services/microphone_busy_policy.dart';

void main() {
  test('类型化错误码与两端历史文案都判定为麦克风被占用', () {
    expect(
      MicrophoneBusyPolicy.matches(
        PlatformException(code: MicrophoneBusyPolicy.code),
      ),
      isTrue,
    );
    // iOS 音频会话激活失败的原始错误文本。
    expect(
      MicrophoneBusyPolicy.matches(
        PlatformException(
          code: 'Error Domain=NSOSStatusErrorDomain Code=561017449 '
              '"Session activation failed"',
          message: '麦克风可能被通话或其他应用占用',
        ),
      ),
      isTrue,
    );
    // Android 旧版只给中文文本。
    expect(
      MicrophoneBusyPolicy.matches(
        PlatformException(code: 'audio_init', message: '麦克风或音频编码器启动失败'),
      ),
      isTrue,
    );
  });

  test('与麦克风无关的失败不误判', () {
    expect(
      MicrophoneBusyPolicy.matches(
        PlatformException(code: 'session_config', message: '此设备不支持持续录像'),
      ),
      isFalse,
    );
    expect(
      MicrophoneBusyPolicy.matches(
        PlatformException(code: 'audio_track_creation_failed', message: '无法创建录像声音轨道'),
      ),
      isFalse,
    );
    expect(MicrophoneBusyPolicy.matches(null), isFalse);
  });

  test('提示文案不把原因限定成打电话，并给出可执行动作', () {
    expect(MicrophoneBusyPolicy.notice, contains('麦克风被其他应用占用'));
    expect(MicrophoneBusyPolicy.notice, contains('关闭占用麦克风的应用'));
    // 用户不一定在打电话，文案不能只让人去结束通话。
    expect(MicrophoneBusyPolicy.speechText, contains('关闭占用麦克风的应用'));
    expect(MicrophoneBusyPolicy.notice.endsWith('。'), isFalse);
  });
}
