import 'dart:async';
import 'dart:io';

/// 连接电脑第一步（读取电脑身份）失败时的统一判定与操作员提示。
///
/// 扫码配对或从搜索列表连接时，手机先请求电脑的 `/api/node-info` 读取主机
/// 身份。这一步失败以前会把 Dart 的原始异常直接放进「连接电脑失败」弹窗
/// （例如 `TimeoutException after 0:00:05.000000: Future not completed`），
/// 操作员既看不懂，也不知道下一步该动哪里，所以这里统一翻译成"先看哪里、
/// 再做什么"的提示：
///
/// - [TimeoutException]：请求发出后 5 秒内没有任何回应。电脑端没打开、电脑
///   防火墙静默丢弃数据包、手机与电脑不在同一局域网，或 iPhone 还没授予
///   「本地网络」权限，都会表现成这一种；
/// - [SocketException]：对方明确回绝或网络不可达，例如电脑端未运行、二维码
///   里的地址已经失效。
///
/// 文案只说明原因和下一步动作，不带句号结尾（见仓库文案约定）。
abstract final class LanBackupPairingFailurePolicy {
  /// 请求发出后没有任何回应：先查两端是否在同一 Wi-Fi，再查电脑端是否在跑。
  static const String _timeoutNotice =
      '电脑没有响应，请确认电脑端已打开、手机与电脑在同一个 Wi-Fi，'
      '且电脑防火墙没有拦截局域网连接';

  /// iPhone 上还要多查一项：本地网络权限被拒绝时连接同样没有任何回应，
  /// 且系统不会第二次询问。
  static const String _timeoutNoticeIOS =
      '电脑没有响应，请确认电脑端已打开且与手机在同一个 Wi-Fi；'
      '如果刚安装本应用，请在「设置 - 隐私与安全性 - 本地网络」中允许本应用';

  /// 对方明确回绝或网络不可达；与配对后续阶段的同一句提示保持一致。
  static const String socketNotice = '无法通过局域网连接电脑，请确认手机和电脑连接了同一个 Wi-Fi';

  /// 传输异常对应的提示；无法归类的异常一律按"连不上电脑"处理，避免把
  /// Dart 原始异常文案透给操作员。
  static String noticeFor(Object error, {required bool isIOS}) => error
      is TimeoutException
      ? (isIOS ? _timeoutNoticeIOS : _timeoutNotice)
      : socketNotice;
}
