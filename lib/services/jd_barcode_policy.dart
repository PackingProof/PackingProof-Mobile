/// Same-frame JD waybill/package association; never retains cross-frame state.
class JdBarcodePolicy {
  const JdBarcodePolicy._();

  // Only confirmed JD / JDVA forms. Do not guess other courier prefixes.
  static final RegExp _waybill = RegExp(r'^JD(?:VA)?[0-9]+$');
  static final RegExp _package = RegExp(
    r'^(JD(?:VA)?[0-9]+)-([1-9][0-9]*)-([1-9][0-9]*)-$',
  );

  static bool isBareWaybill(String code) =>
      code.length >= 8 && code.length <= 40 && _waybill.hasMatch(code);

  static JdPackageCode? parse(String code) {
    if (code.length > 40) return null;
    final RegExpMatch? match = _package.firstMatch(code);
    if (match == null || !isBareWaybill(match[1]!)) return null;
    final int? index = int.tryParse(match[2]!);
    final int? count = int.tryParse(match[3]!);
    if (index == null || count == null || index > count || count > 2147483647) {
      return null;
    }
    return JdPackageCode(code, match[1]!, index, count);
  }

  /// Input has already received the caller's whitespace/case normalization.
  static String normalize(String code) {
    final JdPackageCode? package = parse(code);
    return package?.count == 1 ? package!.waybill : code;
  }

  /// Candidates must keep the existing ranking and their original suffixes.
  static String? select(Iterable<String> rankedCodes) {
    final List<String> codes = rankedCodes.toList(growable: false);
    if (codes.isEmpty) return null;
    final String first = codes.first;
    if (isBareWaybill(first)) {
      for (final String code in codes) {
        if (parse(code)?.waybill == first) return normalize(code);
      }
    }
    return normalize(first);
  }
}

class JdPackageCode {
  const JdPackageCode(this.rawCode, this.waybill, this.index, this.count);
  final String rawCode;
  final String waybill;
  final int index;
  final int count;
}
