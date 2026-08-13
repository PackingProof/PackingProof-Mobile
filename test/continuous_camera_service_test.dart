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
    expect(initialization.cameraId, isNull);
    expect(initialization.zoomRatio, 1.0);
  });

  test('后置镜头解析焦距、变焦倍数并生成标签', () {
    final NativeCameraLens lens = NativeCameraLens.fromMap(<Object?, Object?>{
      'cameraId': '3',
      'focalLength': 2.2,
      'zoomRatio': 0.4,
      'isMain': false,
    });
    expect(lens.cameraId, '3');
    expect(lens.focalLength, 2.2);
    expect(lens.zoomRatio, 0.4);
    expect(lens.isMain, isFalse);
    expect(lens.label, '0.4x');
    expect(
      const NativeCameraLens(
        cameraId: '0',
        focalLength: 5.4,
        zoomRatio: 1.0,
        isMain: true,
      ).label,
      '1x',
    );
    expect(
      const NativeCameraLens(
        cameraId: '2',
        focalLength: 6.8,
        zoomRatio: 1.3,
      ).label,
      '1.3x',
    );
  });

  test('枚举后置镜头与按镜头切换使用独立原生方法', () async {
    const MethodChannel channel = MethodChannel(
      'app.packingproof.mobile/continuous_camera',
    );
    final List<MethodCall> calls = <MethodCall>[];
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
        .setMockMethodCallHandler(channel, (MethodCall call) async {
          calls.add(call);
          if (call.method == 'listCameras') {
            return <Object?>[
              <String, Object?>{
                'cameraId': '1',
                'focalLength': 2.2,
                'zoomRatio': 0.4,
                'isMain': false,
              },
              <String, Object?>{
                'cameraId': '0',
                'focalLength': 5.4,
                'zoomRatio': 1.0,
                'isMain': true,
              },
            ];
          }
          if (call.method == 'switchToCamera') {
            return <String, Object?>{
              'textureId': 7,
              'previewWidth': 1920,
              'previewHeight': 1080,
              'sensorOrientation': 270,
              'fps': 30,
              'videoMime': 'video/hevc',
              'flashAvailable': false,
              'lensDirection': 'back',
              'canSwitchCamera': true,
              'cameraId': '1',
              'zoomRatio': 0.4,
            };
          }
          return null;
        });
    final ContinuousCameraService service = ContinuousCameraService(
      channel: channel,
    );

    final List<NativeCameraLens> lenses = await service.listCameras();
    final ContinuousCameraInitialization initialization = await service
        .switchToCamera('1');

    expect(lenses.map((NativeCameraLens lens) => lens.cameraId), <String>[
      '1',
      '0',
    ]);
    expect(initialization.cameraId, '1');
    expect(initialization.zoomRatio, 0.4);
    expect(calls.map((MethodCall call) => call.method), <String>[
      'listCameras',
      'switchToCamera',
    ]);
    expect(calls.last.arguments, <String, Object>{'cameraId': '1'});
    await service.dispose();
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
        .setMockMethodCallHandler(channel, null);
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
    final ContinuousCameraService service = ContinuousCameraService(
      channel: channel,
    );

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
    final ContinuousCameraService service = ContinuousCameraService(
      channel: channel,
    );
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
              'codecFallbackReason': 'no_hevc_decoder',
              'lastRequestTemplate': 'preview',
              'stallActive': false,
              'sessionConfigStage': '3_1920x1080_960x540',
              'sessionConfigAttempts': 2,
              'initFailureStage': 'session_config',
              'initFailureDetail': '摄像头无法同时提供预览、识别和录像',
              'startFailureStage': null,
              'startFailureDetail': null,
              'recordingFallbackMode': 'encoder_analysis',
              'preferEncoderAnalysisRecording': true,
              'recordAudio': false,
              'probeResults': <Object?>[
                <String, Object?>{
                  'name': 'preview_only',
                  'surfaces': 'preview',
                  'result': 'configured',
                },
              ],
              'probeInProgress': false,
              'probeCached': true,
              'hardwareLevel': 0,
              'capabilities': <Object?>['backward_compatible', 'manual_sensor'],
              'yuvSizes': <Object?>['960x540', '640x480'],
              'videoSizes': <Object?>['1920x1080', '1280x720'],
              'previewSizes': <Object?>['1920x1080'],
              'physicalCameraIds': <Object?>['0'],
              'fpsRanges': <Object?>['15-30'],
            },
          };
        });
    final ContinuousCameraService service = ContinuousCameraService(
      channel: channel,
    );
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
    expect(snapshot.codecFallbackReason, 'no_hevc_decoder');
    expect(snapshot.sessionConfigStage, '3_1920x1080_960x540');
    expect(snapshot.sessionConfigAttempts, 2);
    expect(snapshot.initFailureStage, 'session_config');
    expect(snapshot.initFailureDetail, '摄像头无法同时提供预览、识别和录像');
    expect(snapshot.probeResults, hasLength(1));
    expect(snapshot.probeResults.single['name'], 'preview_only');
    expect(snapshot.recordingFallbackMode, 'encoder_analysis');
    expect(snapshot.preferEncoderAnalysisRecording, isTrue);
    expect(snapshot.recordAudio, isFalse);
    expect(snapshot.probeInProgress, isFalse);
    expect(snapshot.probeCached, isTrue);
    expect(snapshot.hardwareLevel, 0);
    expect(snapshot.capabilities, contains('manual_sensor'));
    expect(snapshot.yuvSizes, contains('640x480'));
    expect(snapshot.videoSizes, contains('1920x1080'));
    expect(snapshot.previewSizes, contains('1920x1080'));
    expect(snapshot.physicalCameraIds, contains('0'));
    expect(snapshot.fpsRanges, contains('15-30'));
    expect(snapshot.deviceSummary, contains('vivo'));
  });

  test('原生探针完成事件回调携带结果', () async {
    const MethodChannel channel = MethodChannel(
      'app.packingproof.mobile/continuous_camera',
    );
    final ContinuousCameraService service = ContinuousCameraService(
      channel: channel,
    );
    addTearDown(() async {
      await service.dispose();
      TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
          .setMockMethodCallHandler(channel, null);
    });
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
        .setMockMethodCallHandler(channel, (MethodCall call) async => null);
    Map<Object?, Object?>? received;
    service.onProbeFinished = (Map<Object?, Object?> results) {
      received = results;
    };

    final ByteData message = const StandardMethodCodec().encodeMethodCall(
      const MethodCall('probeFinished', <String, Object?>{
        'results': <Object?>[
          <String, Object?>{'name': 'preview_only', 'result': 'configured'},
        ],
        'cameraId': '0',
        'hardwareLevel': 0,
      }),
    );
    await TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
        .handlePlatformMessage(
          'app.packingproof.mobile/continuous_camera',
          message,
          (_) {},
        );

    expect(received, isNotNull);
    expect(received!['cameraId'], '0');
    expect(received!['hardwareLevel'], 0);
    final List<Object?> results = received!['results']! as List<Object?>;
    expect(results, hasLength(1));
  });

  test('原生录像降级事件回调携带模式', () async {
    const MethodChannel channel = MethodChannel(
      'app.packingproof.mobile/continuous_camera',
    );
    final ContinuousCameraService service = ContinuousCameraService(
      channel: channel,
    );
    addTearDown(() async {
      await service.dispose();
      TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
          .setMockMethodCallHandler(channel, null);
    });
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
        .setMockMethodCallHandler(channel, (MethodCall call) async => null);
    Map<Object?, Object?>? received;
    service.onRecordingFallback = (Map<Object?, Object?> info) {
      received = info;
    };

    final ByteData message = const StandardMethodCodec().encodeMethodCall(
      const MethodCall('recordingFallback', <String, Object?>{
        'mode': 'encoder_analysis',
      }),
    );
    await TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
        .handlePlatformMessage(
          'app.packingproof.mobile/continuous_camera',
          message,
          (_) {},
        );

    expect(received, isNotNull);
    expect(received!['mode'], 'encoder_analysis');
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
    final ContinuousCameraService service = ContinuousCameraService(
      channel: channel,
    );
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
      'fallbackRecording': false,
    });
  });

  test('初始化时传递已保存的降级录像模式', () async {
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
            'videoMime': 'video/hevc',
            'flashAvailable': false,
            'lensDirection': 'back',
            'canSwitchCamera': false,
          };
        });
    final ContinuousCameraService service = ContinuousCameraService(
      channel: channel,
    );
    addTearDown(() async {
      await service.dispose();
      TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
          .setMockMethodCallHandler(channel, null);
    });

    await service.initialize(fallbackRecording: true);

    expect(calls.single.arguments, <String, Object>{
      'videoCodec': 'hevc',
      'recordingSpec': 'hd1080p30',
      'fallbackRecording': true,
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
    final ContinuousCameraService service = ContinuousCameraService(
      channel: channel,
    );
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
      'fallbackRecording': false,
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
    final ContinuousCameraService service = ContinuousCameraService(
      channel: channel,
    );
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
    final ContinuousCameraService service = ContinuousCameraService(
      channel: channel,
    );
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
