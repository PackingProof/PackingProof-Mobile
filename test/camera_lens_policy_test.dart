import 'package:flutter_test/flutter_test.dart';
import 'package:packing_proof_mobile/services/camera_lens_policy.dart';
import 'package:packing_proof_mobile/services/continuous_camera_service.dart';

void main() {
  const List<NativeCameraLens> lenses = <NativeCameraLens>[
    NativeCameraLens(cameraId: 'ultrawide', focalLength: 1.5, zoomRatio: 0.5),
    NativeCameraLens(
      cameraId: 'main',
      focalLength: 4.5,
      zoomRatio: 1.0,
      isMain: true,
    ),
    NativeCameraLens(cameraId: 'tele', focalLength: 7.0, zoomRatio: 2.0),
  ];

  test('只保留 1 倍与大于 1 倍的后置镜头', () {
    final List<NativeCameraLens> result = scannableBackLenses(lenses);

    expect(result.map((NativeCameraLens lens) => lens.cameraId), <String>[
      'main',
      'tele',
    ]);
  });

  test('小于 1 倍的其他变焦档位同样隐藏', () {
    final List<NativeCameraLens> result =
        scannableBackLenses(const <NativeCameraLens>[
          NativeCameraLens(cameraId: 'wide', focalLength: 2.8, zoomRatio: 0.7),
          NativeCameraLens(
            cameraId: 'main',
            focalLength: 4.5,
            zoomRatio: 1.0,
            isMain: true,
          ),
        ]);

    expect(result.single.cameraId, 'main');
  });
}
