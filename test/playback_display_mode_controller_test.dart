import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:packing_proof_mobile/services/playback_display_mode_controller.dart';

class _FakePlaybackDisplayPlatform implements PlaybackDisplayPlatform {
  final List<List<DeviceOrientation>> applied = <List<DeviceOrientation>>[];
  bool failNext = false;

  @override
  Future<void> setPreferredOrientations(
    List<DeviceOrientation> orientations,
  ) async {
    applied.add(List<DeviceOrientation>.of(orientations));
    if (failNext) {
      failNext = false;
      throw PlatformException(code: 'orientation-failed');
    }
  }
}

void main() {
  late _FakePlaybackDisplayPlatform platform;
  late PlaybackDisplayModeController controller;

  setUp(() {
    platform = _FakePlaybackDisplayPlatform();
    controller = PlaybackDisplayModeController(platform: platform);
  });

  test('初始为窗口布局且不下发方向', () {
    expect(controller.mode, PlaybackDisplayMode.windowed);
    expect(controller.isFullscreen, isFalse);
    expect(platform.applied, isEmpty);
  });

  test('进入全屏下发传入方向并切换布局', () async {
    await controller.enter(
      orientations: <DeviceOrientation>[
        DeviceOrientation.landscapeLeft,
        DeviceOrientation.landscapeRight,
      ],
    );

    expect(controller.isFullscreen, isTrue);
    expect(platform.applied, <List<DeviceOrientation>>[
      <DeviceOrientation>[
        DeviceOrientation.landscapeLeft,
        DeviceOrientation.landscapeRight,
      ],
    ]);
  });

  test('退出全屏恢复竖屏', () async {
    await controller.enter(
      orientations: <DeviceOrientation>[DeviceOrientation.landscapeLeft],
    );
    await controller.restore();

    expect(controller.mode, PlaybackDisplayMode.windowed);
    expect(platform.applied.last, <DeviceOrientation>[
      DeviceOrientation.portraitUp,
    ]);
  });

  test('窗口布局下重复恢复不下发方向', () async {
    await controller.restore();
    await controller.restore();

    expect(platform.applied, isEmpty);
  });

  test('重复恢复只下发一次，避免打断已稳定的方向', () async {
    await controller.enter(
      orientations: <DeviceOrientation>[DeviceOrientation.landscapeLeft],
    );
    await controller.restore();
    await controller.restore();
    await controller.restore();

    expect(platform.applied, <List<DeviceOrientation>>[
      <DeviceOrientation>[DeviceOrientation.landscapeLeft],
      <DeviceOrientation>[DeviceOrientation.portraitUp],
    ]);
  });

  test('重复进入全屏按最新方向下发', () async {
    await controller.enter(
      orientations: <DeviceOrientation>[DeviceOrientation.portraitUp],
    );
    await controller.enter(
      orientations: <DeviceOrientation>[DeviceOrientation.landscapeLeft],
    );

    expect(platform.applied, <List<DeviceOrientation>>[
      <DeviceOrientation>[DeviceOrientation.portraitUp],
      <DeviceOrientation>[DeviceOrientation.landscapeLeft],
    ]);
    await controller.restore();
    expect(platform.applied.last, <DeviceOrientation>[
      DeviceOrientation.portraitUp,
    ]);
  });

  test('页面销毁时仍在全屏则恢复竖屏', () async {
    await controller.enter(
      orientations: <DeviceOrientation>[DeviceOrientation.landscapeLeft],
    );
    await controller.dispose();

    expect(controller.mode, PlaybackDisplayMode.windowed);
    expect(platform.applied.last, <DeviceOrientation>[
      DeviceOrientation.portraitUp,
    ]);
  });

  test('页面销毁时不在全屏则不触碰方向', () async {
    await controller.dispose();

    expect(platform.applied, isEmpty);
  });

  test('平台下发失败不抛错，全屏仍生效', () async {
    platform.failNext = true;

    await controller.enter(
      orientations: <DeviceOrientation>[DeviceOrientation.landscapeLeft],
    );

    expect(controller.isFullscreen, isTrue);
    expect(platform.applied.single, <DeviceOrientation>[
      DeviceOrientation.landscapeLeft,
    ]);
  });
}
