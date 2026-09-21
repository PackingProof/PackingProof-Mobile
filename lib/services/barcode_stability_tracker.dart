import 'barcode_candidate_policy.dart';
import 'jd_barcode_policy.dart';

class BarcodeObservation {
  const BarcodeObservation({this.candidateCode = '', this.confirmedCode = ''});

  final String candidateCode;
  final String confirmedCode;
}

class BarcodeStabilityTracker {
  /// 与电脑端默认一致：同码在 2 秒确认窗口内出现两次即确认。
  static const Duration confirmationWindow = Duration(milliseconds: 2000);

  /// 与电脑端默认一致：确认后的同码离开画面满 3 秒才允许重新触发。
  static const Duration rearmDelay = Duration(milliseconds: 3000);

  final Set<String> _lockedCodes = <String>{};
  final Map<String, DateTime> _missingLockedSince = <String, DateTime>{};
  String _candidateCode = '';
  DateTime? _candidateFirstSeen;
  int _candidateObservations = 0;

  BarcodeObservation observe(String? code, DateTime now) {
    String normalized = BarcodeCandidatePolicy.normalize(code);

    _rearmLockedCode(normalized, now);

    if (normalized.isEmpty) {
      // 空帧不重置命中计数，只有超过确认窗口才过期候选。
      _expireCandidate(now);
      return _candidateCode.isEmpty
          ? const BarcodeObservation()
          : BarcodeObservation(candidateCode: _candidateCode);
    }

    final String? lockedAlias = _lockedCodes.contains(normalized)
        ? normalized
        : _findLockedAlias(normalized);
    if (lockedAlias != null) {
      final bool aliasChanged = lockedAlias != normalized;
      final String specific = JdBarcodePolicy.preferSpecific(
        lockedAlias,
        normalized,
      );
      if (aliasChanged) {
        _lockedCodes.add(normalized);
        _missingLockedSince.remove(normalized);
      } else {
        _lockedCodes.remove(lockedAlias);
        _missingLockedSince.remove(lockedAlias);
      }
      normalized = specific;
      _lockedCodes.add(normalized);
      _missingLockedSince.remove(normalized);
      if (JdBarcodePolicy.sameRecordingCode(_candidateCode, normalized)) {
        _clearCandidate();
      }
      return const BarcodeObservation();
    }

    if (!JdBarcodePolicy.sameRecordingCode(_candidateCode, normalized) ||
        _candidateFirstSeen == null ||
        now.difference(_candidateFirstSeen!) > confirmationWindow) {
      _candidateCode = normalized;
      _candidateFirstSeen = now;
      _candidateObservations = 1;
      return BarcodeObservation(candidateCode: normalized);
    }

    _candidateObservations++;
    if (_candidateObservations < 2) {
      return BarcodeObservation(candidateCode: normalized);
    }

    final String candidateAlias = _candidateCode;
    normalized = JdBarcodePolicy.preferSpecific(candidateAlias, normalized);
    _lockedCodes.add(normalized);
    if (candidateAlias != normalized) _lockedCodes.add(candidateAlias);
    final String waybill = JdBarcodePolicy.waybill(normalized);
    if (waybill != normalized) _lockedCodes.add(waybill);
    _missingLockedSince.clear();
    _clearCandidate();
    return BarcodeObservation(confirmedCode: normalized);
  }

  /// 直接把一个已经确认过的单号加锁。
  ///
  /// 未开始工作时扫到面单会自动开始录像，而开始录像会重置跟踪器；这里补回锁定，
  /// 避免同一张停在画面里的面单被立刻当成第二段重新确认。
  void lockConfirmed(String code) {
    final String normalized = BarcodeCandidatePolicy.normalize(code);
    if (normalized.isEmpty) return;
    final String? alias = _findLockedAlias(normalized);
    if (alias != null) {
      final String specific = JdBarcodePolicy.preferSpecific(alias, normalized);
      if (specific != normalized) _lockedCodes.add(normalized);
      _lockedCodes.add(specific);
    } else {
      _lockedCodes.add(normalized);
    }
    final String waybill = JdBarcodePolicy.waybill(normalized);
    if (waybill != normalized) _lockedCodes.add(waybill);
    _missingLockedSince.clear();
    _clearCandidate();
  }

  void _rearmLockedCode(String normalized, DateTime now) {
    for (final String code in _lockedCodes.toList(growable: false)) {
      if (JdBarcodePolicy.sameRecordingCode(code, normalized)) {
        final DateTime? missingSince = _missingLockedSince[code];
        if (missingSince == null || now.difference(missingSince) < rearmDelay) {
          _missingLockedSince.remove(code);
          continue;
        }
        _lockedCodes.remove(code);
        _missingLockedSince.remove(code);
        continue;
      }

      final DateTime firstMissingAt = _missingLockedSince.putIfAbsent(
        code,
        () => now,
      );
      if (now.difference(firstMissingAt) >= rearmDelay) {
        _lockedCodes.remove(code);
        _missingLockedSince.remove(code);
      }
    }
  }

  String? _findLockedAlias(String normalized) {
    final JdPackageCode? observedPackage = JdBarcodePolicy.parse(normalized);
    if (observedPackage != null &&
        _lockedCodes.any(
          (String code) =>
              JdBarcodePolicy.parse(code)?.waybill == observedPackage.waybill,
        )) {
      return null;
    }
    for (final String code in _lockedCodes) {
      if (JdBarcodePolicy.sameRecordingCode(code, normalized)) return code;
    }
    return null;
  }

  void _expireCandidate(DateTime now) {
    final DateTime? firstSeen = _candidateFirstSeen;
    if (_candidateCode.isNotEmpty &&
        firstSeen != null &&
        now.difference(firstSeen) > confirmationWindow) {
      _candidateCode = '';
      _candidateFirstSeen = null;
      _candidateObservations = 0;
    }
  }

  void reset() {
    _lockedCodes.clear();
    _missingLockedSince.clear();
    _clearCandidate();
  }

  void _clearCandidate() {
    _candidateCode = '';
    _candidateFirstSeen = null;
    _candidateObservations = 0;
  }
}
