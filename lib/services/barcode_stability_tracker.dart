import 'barcode_candidate_policy.dart';

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

  String _lockedCode = '';
  DateTime? _missingLockedSince;
  String _candidateCode = '';
  DateTime? _candidateFirstSeen;
  int _candidateObservations = 0;

  BarcodeObservation observe(String? code, DateTime now) {
    final String normalized = BarcodeCandidatePolicy.normalize(code);

    _rearmLockedCode(normalized, now);

    if (normalized.isEmpty) {
      // 空帧不重置命中计数，只有超过确认窗口才过期候选。
      _expireCandidate(now);
      return _candidateCode.isEmpty
          ? const BarcodeObservation()
          : BarcodeObservation(candidateCode: _candidateCode);
    }

    if (_lockedCode == normalized) {
      return const BarcodeObservation();
    }

    if (_candidateCode != normalized ||
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

    _lockedCode = normalized;
    _missingLockedSince = null;
    _candidateCode = '';
    _candidateFirstSeen = null;
    _candidateObservations = 0;
    return BarcodeObservation(confirmedCode: normalized);
  }

  void _rearmLockedCode(String normalized, DateTime now) {
    if (_lockedCode.isEmpty) {
      return;
    }
    if (_lockedCode == normalized) {
      final DateTime? missingSince = _missingLockedSince;
      if (missingSince == null || now.difference(missingSince) < rearmDelay) {
        _missingLockedSince = null;
        return;
      }
      // 消失超过重新触发延时后再次出现，允许作为新候选重新计数。
      _lockedCode = '';
      _missingLockedSince = null;
      return;
    }
    _missingLockedSince ??= now;
    if (now.difference(_missingLockedSince!) >= rearmDelay) {
      _lockedCode = '';
      _missingLockedSince = null;
    }
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
    _lockedCode = '';
    _missingLockedSince = null;
    _candidateCode = '';
    _candidateFirstSeen = null;
    _candidateObservations = 0;
  }
}
