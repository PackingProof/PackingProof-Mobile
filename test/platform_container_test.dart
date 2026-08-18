import 'package:flutter_test/flutter_test.dart';
import 'package:packing_proof_mobile/platform/platform_container.dart';

void main() {
  test('current platform container is reused for the process lifetime', () {
    final AppContainer first = AppContainer.forCurrentPlatform();
    final AppContainer second = AppContainer.forCurrentPlatform();

    expect(identical(first, second), isTrue);
    expect(identical(first.camera, second.camera), isTrue);
  });
}
