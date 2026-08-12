import 'package:flutter_test/flutter_test.dart';
import 'package:packing_proof_mobile/services/barcode_recognized_beep_policy.dart';

void main() {
  test('新码响一声且同码连续可见不重复', () {
    final BarcodeRecognizedBeepPolicy policy = BarcodeRecognizedBeepPolicy();
    expect(policy.shouldBeep(const <String>['YT123456789012']), isTrue);
    expect(policy.shouldBeep(const <String>['YT123456789012']), isFalse);
    expect(policy.shouldBeep(const <String>['YT123456789012']), isFalse);
  });

  test('空帧重置后再次出现重新响', () {
    final BarcodeRecognizedBeepPolicy policy = BarcodeRecognizedBeepPolicy();
    expect(policy.shouldBeep(const <String>['YT123456789012']), isTrue);
    expect(policy.shouldBeep(const <String>[]), isFalse);
    expect(policy.shouldBeep(const <String>['YT123456789012']), isTrue);
  });

  test('指令码与商品码同样触发', () {
    final BarcodeRecognizedBeepPolicy policy = BarcodeRecognizedBeepPolicy();
    expect(policy.shouldBeep(const <String>['CLEAR']), isTrue);
    expect(policy.shouldBeep(const <String>['SHIP']), isTrue);
    expect(policy.shouldBeep(const <String>['FAHUO']), isTrue);
    expect(policy.shouldBeep(const <String>['BACK']), isTrue);
    expect(policy.shouldBeep(const <String>['TUIHUO']), isTrue);
    expect(policy.shouldBeep(const <String>['START']), isTrue);
    expect(policy.shouldBeep(const <String>['STOP']), isTrue);
    expect(policy.shouldBeep(const <String>['6901234567892']), isTrue);
  });

  test('空白内容视为无码并重置', () {
    final BarcodeRecognizedBeepPolicy policy = BarcodeRecognizedBeepPolicy();
    expect(policy.shouldBeep(const <String>['   ']), isFalse);
    expect(policy.shouldBeep(const <String>['YT123456789012']), isTrue);
    expect(policy.shouldBeep(const <String>['']), isFalse);
    expect(policy.shouldBeep(const <String>['YT123456789012']), isTrue);
  });

  test('规范化后同码大小写与空格视为同一码', () {
    final BarcodeRecognizedBeepPolicy policy = BarcodeRecognizedBeepPolicy();
    expect(policy.shouldBeep(const <String>[' yt123456789012 ']), isTrue);
    expect(policy.shouldBeep(const <String>['YT123456789012']), isFalse);
  });
}
