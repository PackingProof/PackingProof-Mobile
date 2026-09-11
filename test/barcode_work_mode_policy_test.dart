import 'package:flutter_test/flutter_test.dart';
import 'package:packing_proof_mobile/models/work_mode.dart';
import 'package:packing_proof_mobile/services/barcode_work_mode_policy.dart';

void main() {
  test('京东裸号与包裹码同码停录，不合并两个包裹', () {
    for (final codes in [
      ('JD123456789012', 'JD123456789012-1-1-'),
      ('JD123456789012-1-2-', 'JD123456789012'),
      ('JDX058278770023', 'JDX058278770023-1-1-'),
    ]) {
      expect(
        BarcodeWorkModePolicy.decide(
          mode: WorkMode.sameCodeStop,
          currentCode: codes.$1,
          scannedCode: codes.$2,
        ),
        BarcodeWorkAction.stopVideo,
      );
      expect(
        BarcodeWorkModePolicy.decide(
          mode: WorkMode.continuousScan,
          currentCode: codes.$1,
          scannedCode: codes.$2,
        ),
        BarcodeWorkAction.ignore,
      );
    }
    expect(
      BarcodeWorkModePolicy.decide(
        mode: WorkMode.sameCodeStop,
        currentCode: 'JD123456789012-1-2-',
        scannedCode: 'JD123456789012-2-2-',
      ),
      BarcodeWorkAction.ignore,
    );
  });
  test('连续扫码会将下一次识别切成新视频', () {
    expect(
      BarcodeWorkModePolicy.decide(
        mode: WorkMode.continuousScan,
        currentCode: '',
        scannedCode: 'JT1234567890',
      ),
      BarcodeWorkAction.bindCurrentVideo,
    );
    expect(
      BarcodeWorkModePolicy.decide(
        mode: WorkMode.continuousScan,
        currentCode: 'JT1234567890',
        scannedCode: 'SF1234567890',
      ),
      BarcodeWorkAction.startNextVideo,
    );
    expect(
      BarcodeWorkModePolicy.decide(
        mode: WorkMode.continuousScan,
        currentCode: 'JT1234567890',
        scannedCode: 'JT1234567890',
      ),
      BarcodeWorkAction.ignore,
    );
  });

  test('同码停录只接受当前录像绑定的单号', () {
    expect(
      BarcodeWorkModePolicy.decide(
        mode: WorkMode.sameCodeStop,
        currentCode: 'JT1234567890',
        scannedCode: 'JT1234567890',
      ),
      BarcodeWorkAction.stopVideo,
    );
    expect(
      BarcodeWorkModePolicy.decide(
        mode: WorkMode.sameCodeStop,
        currentCode: 'JT1234567890',
        scannedCode: 'SF1234567890',
      ),
      BarcodeWorkAction.ignore,
    );
  });
}
