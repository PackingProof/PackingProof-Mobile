import 'package:flutter/foundation.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:packing_proof_mobile/app/app_update_links.dart';

void main() {
  test('按平台选择更新入口', () {
    expect(
      packingProofAppUpdateUrl(platform: TargetPlatform.android),
      packingProofAndroidReleasesUrl,
    );
    expect(
      packingProofAppUpdateUrl(platform: TargetPlatform.iOS),
      packingProofIosTestFlightUrl,
    );
  });
}
