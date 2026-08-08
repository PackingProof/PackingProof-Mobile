import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:packing_proof_mobile/models/recording_spec.dart';
import 'package:packing_proof_mobile/models/recording_video_codec.dart';
import 'package:packing_proof_mobile/services/continuous_camera_service.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  test('原生初始化结果包含镜头方向和切换能力', () {
    final ContinuousCameraInitialization initialization =
        ContinuousCameraInitialization.fromMap(<Object?, Object?>{
          'textureId': 7,
          'previewWidth': 1920,
          'previewHeight': 1080,
          'sensorOrientation': 270,
          'fps': 30,
          'videoMime': 'video/hevc',
          'flashAvailable': false,
          'lensDirection': 'front',
          'canSwitchCamera': true,
        });

    expect(initialization.isFrontCamera, isTrue);
    expect(initialization.canSwitchCamera, isTrue);
    expect(initialization.flashAvailable, isFalse);
    expect(initialization.portraitPreviewSize, const Size(1080, 1920));
  });

  test('工作扫码和预览活跃状态使用独立的原生开关', () async {
    const MethodChannel channel = MethodChannel(
      'app.packingproof.mobile/continuous_camera',
    );
    final List<MethodCall> calls = <MethodCall>[];
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
        .setMockMethodCallHandler(channel, (MethodCall call) async {
          calls.add(call);
          return null;
        });
    final ContinuousCameraService service = ContinuousCameraService();

    await service.setWorkScanEnabled(true);
    await service.setPreviewActive(false);

    expect(calls, hasLength(2));
    expect(calls.first.method, 'setWorkScanEnabled');
    expect(calls.first.arguments, <String, Object>{'enabled': true});
    expect(calls.last.method, 'setPreviewActive');
    expect(calls.last.arguments, <String, Object>{'active': false});
    await service.dispose();
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
        .setMockMethodCallHandler(channel, null);
  });

  test('开始录像时传递录制声音开关', () async {
    const MethodChannel channel = MethodChannel(
      'app.packingproof.mobile/continuous_camera',
    );
    final List<MethodCall> calls = <MethodCall>[];
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
        .setMockMethodCallHandler(channel, (MethodCall call) async {
          calls.add(call);
          return <Object?, Object?>{
            'path': call.arguments is Map
                ? (call.arguments! as Map)['path']
                : '',
            'startedAtMs': 0,
          };
        });
    final ContinuousCameraService service = ContinuousCameraService();
    addTearDown(() async {
      await service.dispose();
      TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
          .setMockMethodCallHandler(channel, null);
    });

    await service.startWork('/tmp/video.mp4', recordAudio: false);

    expect(calls.single.method, 'startWork');
    expect(calls.single.arguments, <String, Object>{
      'path': '/tmp/video.mp4',
      'recordAudio': false,
    });
  });

  test('原生条码候选解析码制名称', () {
    final NativeBarcodeCandidate candidate = NativeBarcodeCandidate.fromMap(
      <Object?, Object?>{
        'value': '6901234567890',
        'area': 1200,
        'format': 'ean13',
      },
    );
    expect(candidate.value, '6901234567890');
    expect(candidate.area, 1200);
    expect(candidate.format, 'ean13');

    final NativeBarcodeCandidate legacy = NativeBarcodeCandidate.fromMap(
      <Object?, Object?>{'value': 'JT1234567890', 'area': 1},
    );
    expect(legacy.format, isNull);
  });

  test('诊断快照解析设备与相机心跳', () async {
    const MethodChannel channel = MethodChannel(
      'app.packingproof.mobile/continuous_camera',
    );
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
        .setMockMethodCallHandler(channel, (MethodCall call) async {
          if (call.method != 'getDiagnostics') return null;
          return <Object?, Object?>{
            'device': <Object?, Object?>{
              'manufacturer': 'vivo',
              'model': 'V2241A',
              'sdkInt': 34,
              'release': '14',
            },
            'camera': <Object?, Object?>{
              'initialized': true,
              'previewFrameCount': 123,
              'previewFrameAgeMs': 25,
              'storageAvailableBytes': 123456789,
              'storageTotalBytes': 999999999,
              'muxWriteMaxMs': 140,
              'muxWriteStallCount': 3,
              'codecFallbackReason': 'vendor_hevc_playback_risk',
              'lastRequestTemplate': 'preview',
              'stallActive': false,
            },
          };
        });
    final ContinuousCameraService service = ContinuousCameraService();
    addTearDown(() async {
      await service.dispose();
      TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
          .setMockMethodCallHandler(channel, null);
    });

    final CameraDiagnosticsSnapshot? snapshot = await service.getDiagnostics();

    expect(snapshot, isNotNull);
    expect(snapshot!.initialized, isTrue);
    expect(snapshot.previewFrameCount, 123);
    expect(snapshot.previewFrameAgeMs, 25);
    expect(snapshot.storageAvailableBytes, 123456789);
    expect(snapshot.storageTotalBytes, 999999999);
    expect(snapshot.muxWriteMaxMs, 140);
    expect(snapshot.muxWriteStallCount, 3);
    expect(snapshot.codecFallbackReason, 'vendor_hevc_playback_risk');
    expect(snapshot.deviceSummary, contains('vivo'));
  });

  test('初始化时传递录像编码偏好', () async {
    const MethodChannel channel = MethodChannel(
      'app.packingproof.mobile/continuous_camera',
    );
    final List<MethodCall> calls = <MethodCall>[];
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
        .setMockMethodCallHandler(channel, (MethodCall call) async {
          calls.add(call);
          return <Object?, Object?>{
            'textureId': 1,
            'previewWidth': 1920,
            'previewHeight': 1080,
            'sensorOrientation': 90,
            'fps': 30,
            'videoMime': 'video/avc',
            'flashAvailable': false,
            'lensDirection': 'back',
            'canSwitchCamera': false,
          };
        });
    final ContinuousCameraService service = ContinuousCameraService();
    addTearDown(() async {
      await service.dispose();
      TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
          .setMockMethodCallHandler(channel, null);
    });

    await service.initialize(
      videoCodec: RecordingVideoCodec.h264,
      recordingSpec: RecordingSpecPreset.smooth720p30,
    );

    expect(calls.single.method, 'initialize');
    expect(calls.single.arguments, <String, Object>{
      'videoCodec': 'h264',
      'recordingSpec': 'smooth720p30',
    });
  });

  test('初始化未指定规格时默认高清 1080p', () async {
    const MethodChannel channel = MethodChannel(
      'app.packingproof.mobile/continuous_camera',
    );
    final List<MethodCall> calls = <MethodCall>[];
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
        .setMockMethodCallHandler(channel, (MethodCall call) async {
          calls.add(call);
          return <Object?, Object?>{
            'textureId': 1,
            'previewWidth': 1920,
            'previewHeight': 1080,
            'sensorOrientation': 90,
            'fps': 30,
            'videoMime': 'video/avc',
            'flashAvailable': false,
            'lensDirection': 'back',
            'canSwitchCamera': false,
          };
        });
    final ContinuousCameraService service = ContinuousCameraService();
    addTearDown(() async {
      await service.dispose();
      TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
          .setMockMethodCallHandler(channel, null);
    });

    await service.initialize();

    expect(calls.single.method, 'initialize');
    expect(calls.single.arguments, <String, Object>{
      'videoCodec': 'hevc',
      'recordingSpec': 'hd1080p30',
    });
  });

  test('关闭录制声音时只申请摄像头权限', () async {
    const MethodChannel channel = MethodChannel(
      'app.packingproof.mobile/continuous_camera',
    );
    final List<MethodCall> calls = <MethodCall>[];
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
        .setMockMethodCallHandler(channel, (MethodCall call) async {
          calls.add(call);
          return true;
        });
    final ContinuousCameraService service = ContinuousCameraService();
    addTearDown(() async {
      await service.dispose();
      TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
          .setMockMethodCallHandler(channel, null);
    });

    final bool granted = await service.ensurePermissions(recordAudio: false);

    expect(granted, isTrue);
    expect(calls.single.method, 'ensurePermissions');
    expect(calls.single.arguments, <String, Object>{'recordAudio': false});
  });

  test('开启录制声音时申请摄像头和麦克风权限', () async {
    const MethodChannel channel = MethodChannel(
      'app.packingproof.mobile/continuous_camera',
    );
    final List<MethodCall> calls = <MethodCall>[];
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
        .setMockMethodCallHandler(channel, (MethodCall call) async {
          calls.add(call);
          return true;
        });
    final ContinuousCameraService service = ContinuousCameraService();
    addTearDown(() async {
      await service.dispose();
      TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
          .setMockMethodCallHandler(channel, null);
    });

    final bool granted = await service.ensurePermissions(recordAudio: true);

    expect(granted, isTrue);
    expect(calls.single.method, 'ensurePermissions');
    expect(calls.single.arguments, <String, Object>{'recordAudio': true});
  });
}
