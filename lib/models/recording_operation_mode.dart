enum RecordingOperationMode { shipping, returnGoods }

extension RecordingOperationModeDetails on RecordingOperationMode {
  String get storageValue => switch (this) {
    RecordingOperationMode.shipping => 'shipping',
    RecordingOperationMode.returnGoods => 'return',
  };

  String get label => switch (this) {
    RecordingOperationMode.shipping => '发货',
    RecordingOperationMode.returnGoods => '退货',
  };

  String get fileNameLabel => switch (this) {
    RecordingOperationMode.shipping => 'Ship',
    RecordingOperationMode.returnGoods => 'Return',
  };
}

RecordingOperationMode recordingOperationModeFromStorage(Object? value) {
  final String normalized = '$value'.trim().toLowerCase();
  return switch (normalized) {
    'return' || '退货' => RecordingOperationMode.returnGoods,
    _ => RecordingOperationMode.shipping,
  };
}
