import 'package:path/path.dart' as p;

import '../models/recording_operation_mode.dart';
import '../models/recording_session.dart';

/// 分享或保存到相册时使用的文件名主干。
///
/// 电脑端已按「单号_日期_时间_模式」命名的录像直接沿用原名，其余按本机
/// 命名规则补一个可读名称，避免分享出去的文件名只是一串内部 ID。
String shareFileNameStem(RecordingSession session) {
  final String sourceStem = p.basenameWithoutExtension(session.filePath);
  final bool hasComputerNaming = RegExp(
    r'^.+_\d{8}_\d{6}_(发货|退货)(_.+)?$',
  ).hasMatch(sourceStem);
  if (hasComputerNaming) return sourceStem;
  final DateTime value = session.startedAt;
  final String date =
      '${value.year.toString().padLeft(4, '0')}${value.month.toString().padLeft(2, '0')}${value.day.toString().padLeft(2, '0')}_'
      '${value.hour.toString().padLeft(2, '0')}${value.minute.toString().padLeft(2, '0')}${value.second.toString().padLeft(2, '0')}';
  return '${session.displayCode}_${date}_${session.operationMode.label}';
}

/// 分享或保存到相册时使用的完整文件名。
String shareFileName(RecordingSession session) =>
    '${shareFileNameStem(session)}.mp4';
