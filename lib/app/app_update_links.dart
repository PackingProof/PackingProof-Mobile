import 'package:flutter/foundation.dart';

const String packingProofAndroidReleasesUrl =
    'https://gitee.com/PackingProof/PackingProof-Mobile/releases/latest';
const String packingProofIosTestFlightUrl =
    'https://testflight.apple.com/join/KR4qNs6t';

String packingProofAppUpdateUrl({TargetPlatform? platform}) {
  final TargetPlatform current = platform ?? defaultTargetPlatform;
  return current == TargetPlatform.iOS
      ? packingProofIosTestFlightUrl
      : packingProofAndroidReleasesUrl;
}
