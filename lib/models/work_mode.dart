enum WorkMode { continuousScan, sameCodeStop }

extension WorkModeDetails on WorkMode {
  String get storageValue => switch (this) {
    WorkMode.continuousScan => 'continuousScan',
    WorkMode.sameCodeStop => 'sameCodeStop',
  };

  String get label => switch (this) {
    WorkMode.continuousScan => '连续扫码',
    WorkMode.sameCodeStop => '同码停录',
  };

  String get description => switch (this) {
    WorkMode.continuousScan => '识别下一张面单时，自动结束上一段并开始新录像',
    WorkMode.sameCodeStop => '再次识别当前面单才停止录像，其他单号不会切换',
  };
}

WorkMode workModeFromStorage(Object? value) {
  return WorkMode.values.firstWhere(
    (WorkMode mode) => mode.storageValue == value,
    orElse: () => WorkMode.continuousScan,
  );
}
