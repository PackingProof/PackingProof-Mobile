enum UnbackedRetentionPolicy {
  days1,
  days3,
  days7,
  days30,
  days90,
  keepForever,
}

enum BackedRetentionPolicy {
  immediately,
  days1,
  days3,
  days7,
  days30,
  keepForever,
}

extension UnbackedRetentionPolicyStorage on UnbackedRetentionPolicy {
  String get storageValue => name;

  int? get days => switch (this) {
    UnbackedRetentionPolicy.days1 => 1,
    UnbackedRetentionPolicy.days3 => 3,
    UnbackedRetentionPolicy.days7 => 7,
    UnbackedRetentionPolicy.days30 => 30,
    UnbackedRetentionPolicy.days90 => 90,
    UnbackedRetentionPolicy.keepForever => null,
  };

  String get label => days == null ? '不清除' : '$days 天';
}

extension BackedRetentionPolicyStorage on BackedRetentionPolicy {
  String get storageValue => name;

  int? get days => switch (this) {
    BackedRetentionPolicy.immediately => 0,
    BackedRetentionPolicy.days1 => 1,
    BackedRetentionPolicy.days3 => 3,
    BackedRetentionPolicy.days7 => 7,
    BackedRetentionPolicy.days30 => 30,
    BackedRetentionPolicy.keepForever => null,
  };

  String get label => switch (this) {
    BackedRetentionPolicy.immediately => '立即清除',
    BackedRetentionPolicy.keepForever => '不清除',
    _ => '$days 天',
  };
}

UnbackedRetentionPolicy unbackedRetentionFromStorage(Object? value) =>
    UnbackedRetentionPolicy.values.firstWhere(
      (UnbackedRetentionPolicy item) => item.name == value,
      orElse: () => UnbackedRetentionPolicy.days30,
    );

BackedRetentionPolicy backedRetentionFromStorage(Object? value) =>
    BackedRetentionPolicy.values.firstWhere(
      (BackedRetentionPolicy item) => item.name == value,
      orElse: () => BackedRetentionPolicy.days7,
    );
