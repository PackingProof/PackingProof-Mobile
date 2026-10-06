import 'package:flutter_test/flutter_test.dart';
import 'package:packing_proof_mobile/models/barcode_marker.dart';
import 'package:packing_proof_mobile/models/recording_operation_mode.dart';
import 'package:packing_proof_mobile/models/recording_session.dart';
import 'package:packing_proof_mobile/services/share_file_naming.dart';

RecordingSession _session({
  required String id,
  required String code,
  required String filePath,
  required DateTime startedAt,
  RecordingOperationMode operationMode = RecordingOperationMode.shipping,
}) {
  return RecordingSession(
    id: id,
    filePath: filePath,
    startedAt: startedAt,
    endedAt: startedAt.add(const Duration(seconds: 8)),
    markers: <BarcodeMarker>[
      BarcodeMarker(code: code, occurredAt: startedAt, offset: Duration.zero),
    ],
    operationMode: operationMode,
  );
}

void main() {
  test('电脑端命名的录像沿用原文件名', () {
    final RecordingSession session = _session(
      id: 'clip-1',
      code: '773419525017866',
      filePath: '/storage/videos/773419525017866_20261007_060623_发货.mp4',
      startedAt: DateTime(2026, 10, 7, 6, 6, 23),
    );

    expect(shareFileNameStem(session), '773419525017866_20261007_060623_发货');
    expect(shareFileName(session), '773419525017866_20261007_060623_发货.mp4');
  });

  test('本机命名按单号、时间与模式生成可读文件名', () {
    final RecordingSession session = _session(
      id: 'clip-2',
      code: '773419525017866',
      filePath: '/data/recordings/clip-2.mp4',
      startedAt: DateTime(2026, 10, 7, 5, 56, 5),
      operationMode: RecordingOperationMode.returnGoods,
    );

    expect(shareFileName(session), '773419525017866_20261007_055605_退货.mp4');
  });

  test('未识别单号也能生成安全文件名', () {
    final RecordingSession session = RecordingSession(
      id: 'clip-3',
      filePath: 'clip-3.mov',
      startedAt: DateTime(2026, 1, 2, 3, 4, 5),
      endedAt: DateTime(2026, 1, 2, 3, 4, 13),
      markers: const <BarcodeMarker>[],
    );

    expect(
      shareFileName(session),
      '${RecordingSession.unrecognizedLabel}_20260102_030405_发货.mp4',
    );
  });
}
