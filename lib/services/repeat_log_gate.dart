import 'dart:convert';

/// 周期性诊断事件的降噪闸门。
///
/// 心跳、存储回收这类事件固定间隔重复，内容一模一样，全部落盘只会把真正有
/// 用的业务事件挤出有界日志窗口。闸门只放行两种记录：
///
/// - 签名变化：状态切换（连接状态、清理动作、工作状态）必须立刻留痕；
/// - 窗口采样：签名不变时每 [window] 留一条，证明事件确实还在发生。
///
/// 被省略的重复次数由 [takeSuppressedCount] 取走，调用方写进下一条日志的
/// `suppressed` 字段，导出后仍能还原出真实频率。
class RepeatLogGate {
  RepeatLogGate({required this.window, DateTime Function()? clock})
    : _clock = clock ?? DateTime.now;

  /// 相同签名两次落盘之间的最短间隔；为零时等同于只做状态变化过滤。
  final Duration window;

  final DateTime Function() _clock;
  String? _signature;
  DateTime? _lastEmittedAt;
  int _suppressed = 0;

  /// 这次是否应该落盘；返回 false 时只在内部累加被省略的次数。
  bool shouldEmit(Map<String, Object?> signature) {
    final String encoded = jsonEncode(signature);
    final DateTime now = _clock();
    final bool sameSignature = encoded == _signature;
    final DateTime? lastEmittedAt = _lastEmittedAt;
    if (sameSignature &&
        lastEmittedAt != null &&
        now.difference(lastEmittedAt) < window) {
      _suppressed++;
      return false;
    }
    // 换到新状态时，上一状态被省略的次数不再有意义：状态切换本身就是那条
    // 日志要表达的信息，混在一起会让人误读成新状态重复了这么多次。
    if (!sameSignature) _suppressed = 0;
    _signature = encoded;
    _lastEmittedAt = now;
    return true;
  }

  /// 取走自上次落盘以来被省略的相同事件数，并归零。
  int takeSuppressedCount() {
    final int suppressed = _suppressed;
    _suppressed = 0;
    return suppressed;
  }
}
