import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:packing_proof_mobile/models/recording_orientation.dart';
import 'package:packing_proof_mobile/services/playback_fullscreen_policy.dart';

void main() {
  test('竖版视频全屏铺满竖屏', () {
    expect(
      PlaybackFullscreenPolicy.layoutFor(
        videoAspectRatio: 9 / 16,
        videoInitialized: true,
        recordedOrientation: RecordingOrientation.portrait,
      ),
      PlaybackFullscreenLayout.portrait,
    );
    expect(
      PlaybackFullscreenPolicy.orientationsFor(
        PlaybackFullscreenLayout.portrait,
      ),
      <DeviceOrientation>[DeviceOrientation.portraitUp],
    );
  });

  test('横版视频全屏铺满横屏，允许左右两个方向', () {
    expect(
      PlaybackFullscreenPolicy.layoutFor(
        videoAspectRatio: 16 / 9,
        videoInitialized: true,
        recordedOrientation: RecordingOrientation.portrait,
      ),
      PlaybackFullscreenLayout.landscape,
    );
    expect(
      PlaybackFullscreenPolicy.orientationsFor(
        PlaybackFullscreenLayout.landscape,
      ),
      <DeviceOrientation>[
        DeviceOrientation.landscapeLeft,
        DeviceOrientation.landscapeRight,
      ],
    );
  });

  test('视频宽高比优先于录像元数据', () {
    // 元数据说横屏，但视频本身是竖版，按视频实际方向铺满。
    expect(
      PlaybackFullscreenPolicy.layoutFor(
        videoAspectRatio: 0.75,
        videoInitialized: true,
        recordedOrientation: RecordingOrientation.landscapeLeft,
      ),
      PlaybackFullscreenLayout.portrait,
    );
  });

  test('正方形视频按横屏铺满', () {
    expect(
      PlaybackFullscreenPolicy.layoutFor(
        videoAspectRatio: 1,
        videoInitialized: true,
        recordedOrientation: RecordingOrientation.landscapeRight,
      ),
      PlaybackFullscreenLayout.landscape,
    );
    expect(
      PlaybackFullscreenPolicy.layoutFor(
        videoAspectRatio: 1,
        videoInitialized: true,
        recordedOrientation: RecordingOrientation.portrait,
      ),
      PlaybackFullscreenLayout.landscape,
    );
    expect(
      PlaybackFullscreenPolicy.orientationsFor(
        PlaybackFullscreenPolicy.layoutFor(
          videoAspectRatio: 1,
          videoInitialized: true,
          recordedOrientation: RecordingOrientation.portrait,
        ),
      ),
      <DeviceOrientation>[
        DeviceOrientation.landscapeLeft,
        DeviceOrientation.landscapeRight,
      ],
    );
  });

  test('像素取整造成的近似正方形同样按横屏处理', () {
    expect(
      PlaybackFullscreenPolicy.layoutFor(
        videoAspectRatio: 0.996,
        videoInitialized: true,
        recordedOrientation: RecordingOrientation.portrait,
      ),
      PlaybackFullscreenLayout.landscape,
    );
    expect(
      PlaybackFullscreenPolicy.layoutFor(
        videoAspectRatio: 1.004,
        videoInitialized: true,
        recordedOrientation: RecordingOrientation.portrait,
      ),
      PlaybackFullscreenLayout.landscape,
    );
  });

  test('常见的竖版比例不会被容差误判成横屏', () {
    for (final double ratio in <double>[4 / 5, 9 / 16, 3 / 4, 0.9]) {
      expect(
        PlaybackFullscreenPolicy.layoutFor(
          videoAspectRatio: ratio,
          videoInitialized: true,
          recordedOrientation: RecordingOrientation.landscapeLeft,
        ),
        PlaybackFullscreenLayout.portrait,
        reason: '宽高比 $ratio 应判为竖版',
      );
    }
  });

  test('未初始化时不把兜底宽高比 1.0 当成视频方向', () {
    expect(
      PlaybackFullscreenPolicy.layoutFor(
        videoAspectRatio: 1,
        videoInitialized: false,
        recordedOrientation: RecordingOrientation.landscapeLeft,
      ),
      PlaybackFullscreenLayout.landscape,
    );
    expect(
      PlaybackFullscreenPolicy.layoutFor(
        videoAspectRatio: 1,
        videoInitialized: false,
        recordedOrientation: RecordingOrientation.portrait,
      ),
      PlaybackFullscreenLayout.portrait,
    );
  });

  test('三个录像方向元数据都映射到横屏或竖屏', () {
    for (final RecordingOrientation orientation
        in RecordingOrientation.values) {
      final PlaybackFullscreenLayout layout =
          PlaybackFullscreenPolicy.layoutFor(
            videoAspectRatio: 1,
            videoInitialized: false,
            recordedOrientation: orientation,
          );
      expect(
        layout,
        orientation == RecordingOrientation.portrait
            ? PlaybackFullscreenLayout.portrait
            : PlaybackFullscreenLayout.landscape,
        reason: '方向元数据 $orientation 映射错误',
      );
    }
  });
}
