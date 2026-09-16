import 'package:flutter_test/flutter_test.dart';
import 'package:packing_proof_mobile/services/barcode_recognized_beep_policy.dart';

/// 无码制信息的候选：配对扫码与历史扫码的调用形态。
Iterable<({String value, String? format})> _codes(
  List<String> values,
) => values.map((String value) => (value: value, format: null));

void main() {
  test('新码响一声且同码连续可见不重复', () {
    final BarcodeRecognizedBeepPolicy policy = BarcodeRecognizedBeepPolicy();
    expect(policy.shouldBeep(_codes(const <String>['YT123456789012'])), isTrue);
    expect(policy.shouldBeep(_codes(const <String>['YT123456789012'])), isFalse);
    expect(policy.shouldBeep(_codes(const <String>['YT123456789012'])), isFalse);
  });

  test('空帧重置后再次出现重新响', () {
    final BarcodeRecognizedBeepPolicy policy = BarcodeRecognizedBeepPolicy();
    expect(policy.shouldBeep(_codes(const <String>['YT123456789012'])), isTrue);
    expect(policy.shouldBeep(_codes(const <String>[])), isFalse);
    expect(policy.shouldBeep(_codes(const <String>['YT123456789012'])), isTrue);
  });

  test('指令码同样触发', () {
    final BarcodeRecognizedBeepPolicy policy = BarcodeRecognizedBeepPolicy();
    expect(policy.shouldBeep(_codes(const <String>['CLEAR'])), isTrue);
    expect(policy.shouldBeep(_codes(const <String>['SHIP'])), isTrue);
    expect(policy.shouldBeep(_codes(const <String>['FAHUO'])), isTrue);
    expect(policy.shouldBeep(_codes(const <String>['BACK'])), isTrue);
    expect(policy.shouldBeep(_codes(const <String>['TUIHUO'])), isTrue);
    expect(policy.shouldBeep(_codes(const <String>['START'])), isTrue);
    expect(policy.shouldBeep(_codes(const <String>['STOP'])), isTrue);
  });

  test('空白内容视为无码并重置', () {
    final BarcodeRecognizedBeepPolicy policy = BarcodeRecognizedBeepPolicy();
    expect(policy.shouldBeep(_codes(const <String>['   '])), isFalse);
    expect(policy.shouldBeep(_codes(const <String>['YT123456789012'])), isTrue);
    expect(policy.shouldBeep(_codes(const <String>[''])), isFalse);
    expect(policy.shouldBeep(_codes(const <String>['YT123456789012'])), isTrue);
  });

  test('规范化后同码大小写与空格视为同一码', () {
    final BarcodeRecognizedBeepPolicy policy = BarcodeRecognizedBeepPolicy();
    expect(policy.shouldBeep(_codes(const <String>[' yt123456789012 '])), isTrue);
    expect(policy.shouldBeep(_codes(const <String>['YT123456789012'])), isFalse);
  });

  test('工作识别跳过静默码制且不占用滴声状态', () {
    final BarcodeRecognizedBeepPolicy policy = BarcodeRecognizedBeepPolicy();
    const List<({String value, String? format})> qr =
        <({String value, String? format})>[
          (value: '6901234567892', format: 'ean13'),
          (value: 'JD0123456789012', format: 'qr'),
        ];
    // 只有静默码制时不出声，而且不把状态吃成"已响过"。
    expect(policy.shouldBeep(qr, skipSilentFormats: true), isFalse);
    expect(policy.shouldBeep(qr, skipSilentFormats: true), isFalse);
    // 随后出现真正的一维码，必须立刻响。
    expect(
      policy.shouldBeep(const <({String value, String? format})>[
        (value: 'JD0123456789012', format: 'code128'),
      ], skipSilentFormats: true),
      isTrue,
    );
  });

  test('配对扫码不跳过静默码制，二维码照常响', () {
    final BarcodeRecognizedBeepPolicy policy = BarcodeRecognizedBeepPolicy();
    expect(
      policy.shouldBeep(const <({String value, String? format})>[
        (value: 'HTTP://192.168.31.250:5280/PAIR?K=ABC', format: 'qr'),
      ]),
      isTrue,
    );
  });
}
