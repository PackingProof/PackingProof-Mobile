part of 'recordings_screen.dart';

class _RetentionSettings extends StatelessWidget {
  const _RetentionSettings({
    required this.unbackedRetention,
    required this.backedRetention,
    required this.onUnbackedRetentionChanged,
    required this.onBackedRetentionChanged,
    required this.returnUnbackedRetention,
    required this.returnBackedRetention,
    required this.onReturnUnbackedRetentionChanged,
    required this.onReturnBackedRetentionChanged,
  });

  final UnbackedRetentionPolicy unbackedRetention;
  final BackedRetentionPolicy backedRetention;
  final ValueChanged<UnbackedRetentionPolicy> onUnbackedRetentionChanged;
  final ValueChanged<BackedRetentionPolicy> onBackedRetentionChanged;
  final UnbackedRetentionPolicy returnUnbackedRetention;
  final BackedRetentionPolicy returnBackedRetention;
  final ValueChanged<UnbackedRetentionPolicy> onReturnUnbackedRetentionChanged;
  final ValueChanged<BackedRetentionPolicy> onReturnBackedRetentionChanged;

  @override
  Widget build(BuildContext context) {
    return Padding(
      padding: const EdgeInsets.fromLTRB(16, 12, 16, 16),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: <Widget>[
          const Text(
            '发货录像清理',
            style: TextStyle(fontSize: 17, fontWeight: FontWeight.w800),
          ),
          const SizedBox(height: 6),
          _RetentionDropdowns(
            keyPrefix: 'shipping',
            unbackedRetention: unbackedRetention,
            backedRetention: backedRetention,
            onUnbackedRetentionChanged: onUnbackedRetentionChanged,
            onBackedRetentionChanged: onBackedRetentionChanged,
          ),
          const SizedBox(height: 4),
          Divider(
            height: 1,
            thickness: 1,
            color: Theme.of(context).colorScheme.outlineVariant,
          ),
          const SizedBox(height: 12),
          const Text(
            '退货录像清理',
            style: TextStyle(fontSize: 17, fontWeight: FontWeight.w800),
          ),
          const SizedBox(height: 6),
          _RetentionDropdowns(
            keyPrefix: 'return',
            unbackedRetention: returnUnbackedRetention,
            backedRetention: returnBackedRetention,
            onUnbackedRetentionChanged: onReturnUnbackedRetentionChanged,
            onBackedRetentionChanged: onReturnBackedRetentionChanged,
          ),
        ],
      ),
    );
  }
}

/// 清理策略的胶囊选择器：选中项下方显示该策略说明，会删未备份录像的策略用红字。
class _StoragePressureSelector extends StatelessWidget {
  const _StoragePressureSelector({
    required this.policy,
    required this.onChanged,
  });

  final StoragePressurePolicy policy;
  final ValueChanged<StoragePressurePolicy> onChanged;

  @override
  Widget build(BuildContext context) {
    final ColorScheme colors = Theme.of(context).colorScheme;
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: <Widget>[
        SizedBox(
          width: double.infinity,
          child: SegmentedButton<StoragePressurePolicy>(
            showSelectedIcon: false,
            segments: StoragePressurePolicy.values
                .map(
                  (StoragePressurePolicy value) =>
                      ButtonSegment<StoragePressurePolicy>(
                        value: value,
                        label: Text(value.label),
                      ),
                )
                .toList(growable: false),
            selected: <StoragePressurePolicy>{policy},
            onSelectionChanged: (Set<StoragePressurePolicy> values) {
              onChanged(values.single);
            },
          ),
        ),
        const SizedBox(height: 12),
        Text(
          policy.description,
          style: TextStyle(
            // 会删除未备份录像的策略直接用红字说明，不再单列一行警告。
            color: policy.deletesUnbacked
                ? colors.error
                : colors.onSurfaceVariant,
            fontSize: 13,
            height: 1.5,
          ),
        ),
      ],
    );
  }
}

/// 录像清理策略：胶囊选择 + 选中项说明，直接放在「录像清理」二级页里。
class _StoragePressureSettings extends StatelessWidget {
  const _StoragePressureSettings({
    required this.policy,
    required this.onChanged,
  });

  final StoragePressurePolicy policy;
  final ValueChanged<StoragePressurePolicy> onChanged;

  @override
  Widget build(BuildContext context) {
    return Padding(
      key: const Key('storage-pressure-settings'),
      padding: const EdgeInsets.fromLTRB(16, 12, 16, 16),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: <Widget>[
          const Text(
            '录像清理策略',
            style: TextStyle(fontSize: 17, fontWeight: FontWeight.w800),
          ),
          const SizedBox(height: 12),
          _StoragePressureSelector(policy: policy, onChanged: onChanged),
        ],
      ),
    );
  }
}

/// 二级页：扫码与声音。扫码卡片与声音卡片各占一张小卡片。
class _ScanSettingsScreen extends StatefulWidget {
  const _ScanSettingsScreen({
    required this.workMode,
    required this.onWorkModeChanged,
    required this.minimumBarcodeLength,
    required this.speechEnabled,
    required this.onSpeechEnabledChanged,
    required this.onSpeechPreview,
    required this.maxVolumeEnabled,
    required this.maxVolumeSupported,
    required this.onMaxVolumeEnabledChanged,
    this.onMinimumBarcodeLengthChanged,
  });

  final WorkMode workMode;
  final ValueChanged<WorkMode> onWorkModeChanged;
  final int minimumBarcodeLength;
  final ValueChanged<int>? onMinimumBarcodeLengthChanged;
  final bool speechEnabled;
  final ValueChanged<bool> onSpeechEnabledChanged;
  final Future<void> Function() onSpeechPreview;
  final bool maxVolumeEnabled;
  final bool maxVolumeSupported;
  final ValueChanged<bool> onMaxVolumeEnabledChanged;

  @override
  State<_ScanSettingsScreen> createState() => _ScanSettingsScreenState();
}

class _ScanSettingsScreenState extends State<_ScanSettingsScreen> {
  late WorkMode _workMode = widget.workMode;
  late int _minimumBarcodeLength = widget.minimumBarcodeLength;
  late bool _speechEnabled = widget.speechEnabled;
  late bool _maxVolumeEnabled = widget.maxVolumeEnabled;

  @override
  Widget build(BuildContext context) {
    final ColorScheme colors = Theme.of(context).colorScheme;
    return Scaffold(
      appBar: AppBar(title: const Text('扫码与声音')),
      body: ListView(
        padding: const EdgeInsets.fromLTRB(18, 12, 18, 28),
        children: <Widget>[
          // 扫码卡片。
          _SettingsCard(
            key: const Key('scan-settings-card-body'),
            children: <Widget>[
              _WorkModeSettings(
                workMode: _workMode,
                onChanged: (WorkMode value) {
                  setState(() => _workMode = value);
                  widget.onWorkModeChanged(value);
                },
              ),
              if (widget.onMinimumBarcodeLengthChanged != null) ...<Widget>[
                Divider(height: 1, thickness: 1, color: colors.outlineVariant),
                _MinimumBarcodeLengthSettings(
                  value: _minimumBarcodeLength,
                  onChanged: (int value) {
                    setState(() => _minimumBarcodeLength = value);
                    widget.onMinimumBarcodeLengthChanged!(value);
                  },
                ),
              ],
            ],
          ),
          const SizedBox(height: 12),
          // 声音卡片。
          _SettingsCard(
            key: const Key('voice-settings-card'),
            children: <Widget>[
              _SpeechPromptSettings(
                enabled: _speechEnabled,
                onChanged: (bool value) {
                  setState(() => _speechEnabled = value);
                  widget.onSpeechEnabledChanged(value);
                },
                onPreview: widget.onSpeechPreview,
              ),
              if (widget.maxVolumeSupported) ...<Widget>[
                Divider(height: 1, thickness: 1, color: colors.outlineVariant),
                _MaxVolumeSettings(
                  enabled: _maxVolumeEnabled,
                  onChanged: (bool value) {
                    setState(() => _maxVolumeEnabled = value);
                    widget.onMaxVolumeEnabledChanged(value);
                  },
                ),
              ],
            ],
          ),
        ],
      ),
    );
  }
}

/// 一级入口卡片：左侧图标 + 标题 + 副标题 + 右箭头，风格与「关于」一致。
class _SettingsEntryCard extends StatelessWidget {
  const _SettingsEntryCard({
    super.key,
    required this.tileKey,
    required this.icon,
    required this.title,
    required this.subtitle,
    required this.onOpen,
  });

  final Key tileKey;
  final IconData icon;
  final String title;
  final String subtitle;
  final VoidCallback onOpen;

  @override
  Widget build(BuildContext context) {
    final ColorScheme colors = Theme.of(context).colorScheme;
    return Material(
      color: colors.surfaceContainer,
      shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(20)),
      clipBehavior: Clip.antiAlias,
      child: ListTile(
        key: tileKey,
        contentPadding: const EdgeInsets.symmetric(horizontal: 16, vertical: 6),
        leading: Icon(icon),
        title: Text(
          title,
          style: const TextStyle(fontSize: 17, fontWeight: FontWeight.w800),
        ),
        subtitle: Text(subtitle),
        trailing: const Icon(Icons.chevron_right_rounded),
        onTap: onOpen,
      ),
    );
  }
}

/// 二级页：订单接收。接收地址与状态要跟着后台服务刷新。
class _OrderReceiverScreen extends StatefulWidget {
  const _OrderReceiverScreen({
    required this.snapshotProvider,
    required this.speechEnabled,
    required this.speechMasterEnabled,
    required this.onSpeechChanged,
    this.listenable,
    this.onRetry,
  });

  final OrderInfoReceiverSnapshot Function() snapshotProvider;
  final bool speechEnabled;
  final bool speechMasterEnabled;
  final ValueChanged<bool> onSpeechChanged;
  final Listenable? listenable;
  final Future<void> Function()? onRetry;

  @override
  State<_OrderReceiverScreen> createState() => _OrderReceiverScreenState();
}

class _OrderReceiverScreenState extends State<_OrderReceiverScreen> {
  late bool _speechEnabled = widget.speechEnabled;

  @override
  Widget build(BuildContext context) {
    final Listenable? listenable = widget.listenable;
    return Scaffold(
      appBar: AppBar(title: const Text('订单接收')),
      body: ListView(
        padding: const EdgeInsets.fromLTRB(18, 12, 18, 28),
        children: <Widget>[
          // 接收服务在后台启停，这里跟着控制器通知刷新状态。
          if (listenable == null)
            _buildSettings()
          else
            ListenableBuilder(
              listenable: listenable,
              builder: (_, _) => _buildSettings(),
            ),
        ],
      ),
    );
  }

  Widget _buildSettings() {
    return _OrderReceiverSettings(
      snapshot: widget.snapshotProvider(),
      onRetry: widget.onRetry,
      speechEnabled: _speechEnabled,
      speechMasterEnabled: widget.speechMasterEnabled,
      onSpeechChanged: (bool value) {
        setState(() => _speechEnabled = value);
        widget.onSpeechChanged(value);
      },
    );
  }
}

/// 二级页：录像设置。
class _RecordingSettingsScreen extends StatefulWidget {
  const _RecordingSettingsScreen({
    required this.codec,
    required this.hevcEnabled,
    required this.hevcWarning,
    required this.onCodecChanged,
    required this.spec,
    required this.availableSpecs,
    required this.showUhd4kOption,
    required this.onSpecChanged,
    required this.orientation,
    required this.onOrientationChanged,
    required this.recordAudio,
    required this.onRecordAudioChanged,
  });

  final RecordingVideoCodec codec;
  final bool hevcEnabled;
  final String? hevcWarning;
  final ValueChanged<RecordingVideoCodec> onCodecChanged;
  final RecordingSpecPreset spec;
  final List<RecordingSpecPreset> availableSpecs;
  final bool showUhd4kOption;
  final ValueChanged<RecordingSpecPreset> onSpecChanged;
  final RecordingOrientation orientation;
  final ValueChanged<RecordingOrientation> onOrientationChanged;
  final bool recordAudio;
  final ValueChanged<bool> onRecordAudioChanged;

  @override
  State<_RecordingSettingsScreen> createState() =>
      _RecordingSettingsScreenState();
}

/// 页内改动立即在页内生效，同时同步回设置页。
class _RecordingSettingsScreenState extends State<_RecordingSettingsScreen> {
  late RecordingVideoCodec _codec = widget.codec;
  late RecordingSpecPreset _spec = widget.spec;
  late RecordingOrientation _orientation = widget.orientation;
  late bool _recordAudio = widget.recordAudio;

  @override
  Widget build(BuildContext context) {
    final ColorScheme colors = Theme.of(context).colorScheme;
    return Scaffold(
      appBar: AppBar(title: const Text('录像设置')),
      body: ListView(
        padding: const EdgeInsets.fromLTRB(18, 12, 18, 28),
        children: <Widget>[
          _SettingsCard(
            children: <Widget>[
              _VideoCodecSettings(
                codec: _codec,
                hevcEnabled: widget.hevcEnabled,
                hevcWarning: widget.hevcWarning,
                onChanged: (RecordingVideoCodec value) {
                  setState(() => _codec = value);
                  widget.onCodecChanged(value);
                },
              ),
              Divider(height: 1, thickness: 1, color: colors.outlineVariant),
              _RecordingSpecSettings(
                spec: _spec,
                availableSpecs: widget.availableSpecs,
                showUhd4kOption: widget.showUhd4kOption,
                onChanged: (RecordingSpecPreset value) {
                  // 设置页会拒绝当前镜头不支持的分辨率（并给出提示），本地只在被接受时更新。
                  widget.onSpecChanged(value);
                  if (widget.availableSpecs.contains(value)) {
                    setState(() => _spec = value);
                  }
                },
              ),
              Divider(height: 1, thickness: 1, color: colors.outlineVariant),
              _RecordingOrientationSettings(
                orientation: _orientation,
                onChanged: (RecordingOrientation value) {
                  setState(() => _orientation = value);
                  widget.onOrientationChanged(value);
                },
              ),
              Divider(height: 1, thickness: 1, color: colors.outlineVariant),
              _RecordAudioSettings(
                enabled: _recordAudio,
                onChanged: (bool value) {
                  setState(() => _recordAudio = value);
                  widget.onRecordAudioChanged(value);
                },
              ),
            ],
          ),
        ],
      ),
    );
  }
}

/// 二级页：录像清理。保留时间、清理策略与清理说明都收在这里。
class _CleanupSettingsScreen extends StatefulWidget {
  const _CleanupSettingsScreen({
    required this.unbackedRetention,
    required this.backedRetention,
    required this.onUnbackedRetentionChanged,
    required this.onBackedRetentionChanged,
    required this.returnUnbackedRetention,
    required this.returnBackedRetention,
    required this.onReturnUnbackedRetentionChanged,
    required this.onReturnBackedRetentionChanged,
    required this.storagePressurePolicy,
    required this.onStoragePressurePolicyChanged,
  });

  final UnbackedRetentionPolicy unbackedRetention;
  final BackedRetentionPolicy backedRetention;
  final Future<bool> Function(UnbackedRetentionPolicy)
  onUnbackedRetentionChanged;
  final Future<bool> Function(BackedRetentionPolicy) onBackedRetentionChanged;
  final UnbackedRetentionPolicy returnUnbackedRetention;
  final BackedRetentionPolicy returnBackedRetention;
  final Future<bool> Function(UnbackedRetentionPolicy)
  onReturnUnbackedRetentionChanged;
  final Future<bool> Function(BackedRetentionPolicy)
  onReturnBackedRetentionChanged;
  final StoragePressurePolicy storagePressurePolicy;
  final ValueChanged<StoragePressurePolicy> onStoragePressurePolicyChanged;

  @override
  State<_CleanupSettingsScreen> createState() => _CleanupSettingsScreenState();
}

/// 页内改动立即在页内生效，同时同步回设置页；被上层拒绝时不改本地选择。
class _CleanupSettingsScreenState extends State<_CleanupSettingsScreen> {
  late UnbackedRetentionPolicy _unbacked = widget.unbackedRetention;
  late BackedRetentionPolicy _backed = widget.backedRetention;
  late UnbackedRetentionPolicy _returnUnbacked = widget.returnUnbackedRetention;
  late BackedRetentionPolicy _returnBacked = widget.returnBackedRetention;
  late StoragePressurePolicy _policy = widget.storagePressurePolicy;

  @override
  Widget build(BuildContext context) {
    final ColorScheme colors = Theme.of(context).colorScheme;
    return Scaffold(
      appBar: AppBar(title: const Text('录像清理')),
      body: ListView(
        padding: const EdgeInsets.fromLTRB(18, 12, 18, 28),
        children: <Widget>[
          _SettingsCard(
            key: const Key('cleanup-settings-detail-card'),
            children: <Widget>[
              _RetentionSettings(
                unbackedRetention: _unbacked,
                backedRetention: _backed,
                onUnbackedRetentionChanged:
                    (UnbackedRetentionPolicy value) async {
                      if (await widget.onUnbackedRetentionChanged(value)) {
                        setState(() => _unbacked = value);
                      }
                    },
                onBackedRetentionChanged: (BackedRetentionPolicy value) async {
                  if (await widget.onBackedRetentionChanged(value)) {
                    setState(() => _backed = value);
                  }
                },
                returnUnbackedRetention: _returnUnbacked,
                returnBackedRetention: _returnBacked,
                onReturnUnbackedRetentionChanged:
                    (UnbackedRetentionPolicy value) async {
                      if (await widget.onReturnUnbackedRetentionChanged(
                        value,
                      )) {
                        setState(() => _returnUnbacked = value);
                      }
                    },
                onReturnBackedRetentionChanged:
                    (BackedRetentionPolicy value) async {
                      if (await widget.onReturnBackedRetentionChanged(value)) {
                        setState(() => _returnBacked = value);
                      }
                    },
              ),
              Divider(height: 1, thickness: 1, color: colors.outlineVariant),
              _StoragePressureSettings(
                policy: _policy,
                onChanged: (StoragePressurePolicy value) {
                  setState(() => _policy = value);
                  widget.onStoragePressurePolicyChanged(value);
                },
              ),
            ],
          ),
          const SizedBox(height: 12),
          _CleanupNotes(
            unbackedRetention: _unbacked,
            backedRetention: _backed,
            returnUnbackedRetention: _returnUnbacked,
            returnBackedRetention: _returnBacked,
            pressurePolicy: _policy,
          ),
        ],
      ),
    );
  }
}

/// 清理说明单独成卡并带标题，直接展示在卡片里，不再藏进弹窗。
class _CleanupNotes extends StatelessWidget {
  const _CleanupNotes({
    required this.unbackedRetention,
    required this.backedRetention,
    required this.returnUnbackedRetention,
    required this.returnBackedRetention,
    required this.pressurePolicy,
  });

  final UnbackedRetentionPolicy unbackedRetention;
  final BackedRetentionPolicy backedRetention;
  final UnbackedRetentionPolicy returnUnbackedRetention;
  final BackedRetentionPolicy returnBackedRetention;
  final StoragePressurePolicy pressurePolicy;

  /// 说明随当前选择变化：发货/退货分组、保留时间与空间不足策略各给一句。
  List<String> get _lines {
    final bool returnDiffers =
        returnUnbackedRetention != unbackedRetention ||
        returnBackedRetention != backedRetention;
    return <String>[
      if (!returnDiffers) ...<String>[
        _unbackedLine('', unbackedRetention),
        _backedLine('', backedRetention),
      ] else ...<String>[
        _unbackedLine('发货', unbackedRetention),
        _backedLine('发货', backedRetention),
        _unbackedLine('退货', returnUnbackedRetention),
        _backedLine('退货', returnBackedRetention),
      ],
      pressurePolicy.deletesUnbacked
          ? '空间不足时按最老的优先删除（含未备份录像），保证一直录下去；'
                '删掉的未备份录像无法恢复'
          : '空间不足时只清理电脑确认过的备份，腾不出空间就停止录制',
      '正在上传的录像不会清理',
    ];
  }

  String _unbackedLine(String scope, UnbackedRetentionPolicy policy) {
    final int? days = policy.days;
    if (days == null) {
      return scope.isEmpty ? '未备份的录像不会自动清理' : '$scope录像：未备份的不会自动清理';
    }
    return scope.isEmpty
        ? '未备份的录像满 $days 天后从本机删除'
        : '$scope录像：未备份满 $days 天后从本机删除';
  }

  String _backedLine(String scope, BackedRetentionPolicy policy) {
    final int? days = policy.days;
    if (days == null) {
      return scope.isEmpty ? '已备份的录像不会自动清理' : '$scope录像：已备份的不会自动清理';
    }
    if (days == 0) {
      return scope.isEmpty
          ? '电脑校验完成后立即从本机删除，删除前会向电脑确认'
          : '$scope录像：电脑校验完成后立即从本机删除，删除前会向电脑确认';
    }
    return scope.isEmpty
        ? '电脑校验完成的录像满 $days 天后删除，删除前会向电脑确认'
        : '$scope录像：电脑校验完成后满 $days 天删除，删除前会向电脑确认';
  }

  @override
  Widget build(BuildContext context) {
    final ColorScheme colors = Theme.of(context).colorScheme;
    final List<String> lines = _lines;
    return _SettingsCard(
      key: const Key('cleanup-notes-card'),
      children: <Widget>[
        Padding(
          padding: const EdgeInsets.fromLTRB(16, 12, 16, 16),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: <Widget>[
              const Text(
                '清理说明',
                style: TextStyle(fontSize: 17, fontWeight: FontWeight.w800),
              ),
              const SizedBox(height: 6),
              for (int index = 0; index < lines.length; index++)
                Padding(
                  padding: const EdgeInsets.only(bottom: 4),
                  child: Text(
                    '${index + 1}. ${lines[index]}',
                    key: index == 0 ? const Key('cleanup-notes') : null,
                    style: TextStyle(
                      color: colors.onSurfaceVariant,
                      fontSize: 13,
                      height: 1.6,
                    ),
                  ),
                ),
            ],
          ),
        ),
      ],
    );
  }
}

class _RetentionDropdowns extends StatelessWidget {
  const _RetentionDropdowns({
    this.keyPrefix = '',
    required this.unbackedRetention,
    required this.backedRetention,
    required this.onUnbackedRetentionChanged,
    required this.onBackedRetentionChanged,
  });

  final String keyPrefix;
  final UnbackedRetentionPolicy unbackedRetention;
  final BackedRetentionPolicy backedRetention;
  final ValueChanged<UnbackedRetentionPolicy> onUnbackedRetentionChanged;
  final ValueChanged<BackedRetentionPolicy> onBackedRetentionChanged;

  @override
  Widget build(BuildContext context) {
    return Column(
      children: <Widget>[
        Row(
          children: <Widget>[
            Expanded(
              child: DropdownButtonFormField<UnbackedRetentionPolicy>(
                key: Key(
                  keyPrefix == 'shipping'
                      ? 'unbacked-retention-dropdown'
                      : '$keyPrefix-unbacked-retention-dropdown',
                ),
                initialValue: unbackedRetention,
                decoration: const InputDecoration(
                  labelText: '未备份保留',
                  isDense: true,
                ),
                items: UnbackedRetentionPolicy.values
                    .map(
                      (value) => DropdownMenuItem(
                        value: value,
                        child: Text(value.label),
                      ),
                    )
                    .toList(growable: false),
                onChanged: (value) {
                  if (value != null) onUnbackedRetentionChanged(value);
                },
              ),
            ),
            const SizedBox(width: 10),
            Expanded(
              child: DropdownButtonFormField<BackedRetentionPolicy>(
                key: Key(
                  keyPrefix == 'shipping'
                      ? 'backed-retention-dropdown'
                      : '$keyPrefix-backed-retention-dropdown',
                ),
                initialValue: backedRetention,
                decoration: const InputDecoration(
                  labelText: '备份后保留',
                  isDense: true,
                ),
                items: BackedRetentionPolicy.values
                    .map(
                      (value) => DropdownMenuItem(
                        value: value,
                        child: Text(value.label),
                      ),
                    )
                    .toList(growable: false),
                onChanged: (value) {
                  if (value != null) onBackedRetentionChanged(value);
                },
              ),
            ),
          ],
        ),
      ],
    );
  }
}

class _SettingsCard extends StatelessWidget {
  const _SettingsCard({super.key, required this.children});

  final List<Widget> children;

  @override
  Widget build(BuildContext context) {
    final ColorScheme colors = Theme.of(context).colorScheme;
    return Container(
      decoration: BoxDecoration(
        color: colors.surfaceContainer,
        borderRadius: BorderRadius.circular(20),
      ),
      child: Column(children: children),
    );
  }
}

class _CameraCapabilitySettings extends StatelessWidget {
  const _CameraCapabilitySettings({
    required this.mode,
    required this.statusText,
    required this.onRetry,
  });

  final CameraCapabilityMode mode;
  final String statusText;
  final VoidCallback? onRetry;

  @override
  Widget build(BuildContext context) {
    final ColorScheme colors = Theme.of(context).colorScheme;
    return Card(
      margin: EdgeInsets.zero,
      elevation: 0,
      color: colors.surfaceContainerLow,
      shape: RoundedRectangleBorder(
        borderRadius: BorderRadius.circular(16),
        side: BorderSide(color: colors.outlineVariant),
      ),
      child: ListTile(
        contentPadding: const EdgeInsets.symmetric(horizontal: 16, vertical: 8),
        leading: Icon(Icons.videocam_outlined, color: colors.primary),
        title: const Text('摄像头能力'),
        subtitle: Text(statusText),
        trailing: TextButton(
          key: const Key('retry-camera-capability-button'),
          onPressed: onRetry,
          child: const Text('重新检测'),
        ),
      ),
    );
  }
}

class _WorkModeSettings extends StatelessWidget {
  const _WorkModeSettings({required this.workMode, required this.onChanged});

  final WorkMode workMode;
  final ValueChanged<WorkMode> onChanged;

  @override
  Widget build(BuildContext context) {
    final ColorScheme colors = Theme.of(context).colorScheme;
    return Padding(
      key: const Key('work-mode-settings'),
      padding: const EdgeInsets.fromLTRB(16, 16, 16, 16),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: <Widget>[
          const Text(
            '工作模式',
            style: TextStyle(fontSize: 17, fontWeight: FontWeight.w800),
          ),
          const SizedBox(height: 12),
          SizedBox(
            width: double.infinity,
            child: SegmentedButton<WorkMode>(
              showSelectedIcon: false,
              segments: WorkMode.values
                  .map(
                    (WorkMode mode) => ButtonSegment<WorkMode>(
                      value: mode,
                      label: Text(mode.label),
                    ),
                  )
                  .toList(growable: false),
              selected: <WorkMode>{workMode},
              onSelectionChanged: (Set<WorkMode> values) {
                onChanged(values.single);
              },
            ),
          ),
          const SizedBox(height: 12),
          Text(
            workMode.description,
            style: TextStyle(
              color: colors.onSurfaceVariant,
              fontSize: 13,
              height: 1.5,
            ),
          ),
        ],
      ),
    );
  }
}

class _VideoCodecSettings extends StatelessWidget {
  const _VideoCodecSettings({
    required this.codec,
    required this.hevcEnabled,
    this.hevcWarning,
    required this.onChanged,
  });

  final RecordingVideoCodec codec;
  final bool hevcEnabled;
  final String? hevcWarning;
  final ValueChanged<RecordingVideoCodec> onChanged;

  @override
  Widget build(BuildContext context) {
    final ColorScheme colors = Theme.of(context).colorScheme;
    return Padding(
      key: const Key('video-codec-settings'),
      padding: const EdgeInsets.fromLTRB(16, 16, 16, 16),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: <Widget>[
          const Text(
            '录像编码',
            style: TextStyle(fontSize: 17, fontWeight: FontWeight.w800),
          ),
          const SizedBox(height: 12),
          SizedBox(
            width: double.infinity,
            child: SegmentedButton<RecordingVideoCodec>(
              showSelectedIcon: false,
              segments: RecordingVideoCodec.values
                  .map(
                    (RecordingVideoCodec value) =>
                        ButtonSegment<RecordingVideoCodec>(
                          value: value,
                          enabled:
                              value != RecordingVideoCodec.hevc || hevcEnabled,
                          label: Text(value.label),
                        ),
                  )
                  .toList(growable: false),
              selected: <RecordingVideoCodec>{codec},
              onSelectionChanged: (Set<RecordingVideoCodec> values) {
                onChanged(values.single);
              },
            ),
          ),
          const SizedBox(height: 12),
          Text(
            codec.description,
            style: TextStyle(
              color: colors.onSurfaceVariant,
              fontSize: 13,
              height: 1.5,
            ),
          ),
          if (hevcWarning != null) ...<Widget>[
            const SizedBox(height: 10),
            Text(
              hevcWarning!,
              style: TextStyle(color: colors.error, fontSize: 13, height: 1.5),
            ),
          ],
        ],
      ),
    );
  }
}

class _RecordingSpecSettings extends StatelessWidget {
  const _RecordingSpecSettings({
    required this.spec,
    required this.availableSpecs,
    required this.showUhd4kOption,
    required this.onChanged,
  });

  final RecordingSpecPreset spec;
  final List<RecordingSpecPreset> availableSpecs;
  final bool showUhd4kOption;
  final ValueChanged<RecordingSpecPreset> onChanged;

  @override
  Widget build(BuildContext context) {
    final ColorScheme colors = Theme.of(context).colorScheme;
    return Padding(
      key: const Key('recording-spec-settings'),
      padding: const EdgeInsets.fromLTRB(16, 16, 16, 16),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: <Widget>[
          const Text(
            '录像规格',
            style: TextStyle(fontSize: 17, fontWeight: FontWeight.w800),
          ),
          const SizedBox(height: 12),
          SizedBox(
            width: double.infinity,
            child: SegmentedButton<RecordingSpecPreset>(
              showSelectedIcon: false,
              segments:
                  (showUhd4kOption
                          ? RecordingSpecPreset.values
                          : availableSpecs)
                      .map(
                        (RecordingSpecPreset value) =>
                            ButtonSegment<RecordingSpecPreset>(
                              value: value,
                              label: Text(value.label),
                            ),
                      )
                      .toList(growable: false),
              selected: <RecordingSpecPreset>{spec},
              onSelectionChanged: (Set<RecordingSpecPreset> values) {
                onChanged(values.single);
              },
            ),
          ),
          const SizedBox(height: 12),
          Text(
            spec.description,
            style: TextStyle(
              color: colors.onSurfaceVariant,
              fontSize: 13,
              height: 1.5,
            ),
          ),
        ],
      ),
    );
  }
}

class _RecordingOrientationSettings extends StatelessWidget {
  const _RecordingOrientationSettings({
    required this.orientation,
    required this.onChanged,
  });

  static const List<RecordingOrientation> _displayOrder =
      <RecordingOrientation>[
        RecordingOrientation.landscapeRight,
        RecordingOrientation.portrait,
        RecordingOrientation.landscapeLeft,
      ];

  final RecordingOrientation orientation;
  final ValueChanged<RecordingOrientation> onChanged;

  @override
  Widget build(BuildContext context) {
    final ColorScheme colors = Theme.of(context).colorScheme;
    return Padding(
      key: const Key('recording-orientation-settings'),
      padding: const EdgeInsets.fromLTRB(16, 16, 16, 16),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: <Widget>[
          const Text(
            '录像方向',
            style: TextStyle(fontSize: 17, fontWeight: FontWeight.w800),
          ),
          const SizedBox(height: 12),
          SizedBox(
            width: double.infinity,
            child: SegmentedButton<RecordingOrientation>(
              showSelectedIcon: false,
              segments: _displayOrder
                  .map(
                    (value) => ButtonSegment<RecordingOrientation>(
                      value: value,
                      label: Text(value.label),
                    ),
                  )
                  .toList(growable: false),
              selected: <RecordingOrientation>{orientation},
              onSelectionChanged: (values) => onChanged(values.single),
            ),
          ),
          const SizedBox(height: 12),
          Text(
            '水印随录像变换，成片始终位于视觉右上角并保持正向可读',
            style: TextStyle(
              color: colors.onSurfaceVariant,
              fontSize: 13,
              height: 1.5,
            ),
          ),
        ],
      ),
    );
  }
}

class _RecordAudioSettings extends StatelessWidget {
  const _RecordAudioSettings({required this.enabled, required this.onChanged});

  final bool enabled;
  final ValueChanged<bool> onChanged;

  @override
  Widget build(BuildContext context) {
    final ColorScheme colors = Theme.of(context).colorScheme;
    return Padding(
      key: const Key('record-audio-settings'),
      padding: const EdgeInsets.fromLTRB(16, 12, 12, 12),
      child: Row(
        children: <Widget>[
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: <Widget>[
                const Text(
                  '录制声音',
                  style: TextStyle(fontSize: 17, fontWeight: FontWeight.w800),
                ),
                const SizedBox(height: 5),
                Text(
                  '关闭后录像不带声音',
                  style: TextStyle(
                    color: colors.onSurfaceVariant,
                    fontSize: 13,
                    height: 1.4,
                  ),
                ),
              ],
            ),
          ),
          Switch(
            key: const Key('record-audio-enabled-switch'),
            value: enabled,
            onChanged: onChanged,
          ),
        ],
      ),
    );
  }
}

class _MinimumBarcodeLengthSettings extends StatelessWidget {
  const _MinimumBarcodeLengthSettings({
    required this.value,
    required this.onChanged,
  });

  static const List<int> _options = <int>[
    8,
    9,
    10,
    11,
    12,
    13,
    14,
    15,
    16,
    17,
    18,
    19,
    20,
  ];

  final int value;
  final ValueChanged<int> onChanged;

  @override
  Widget build(BuildContext context) {
    final ColorScheme colors = Theme.of(context).colorScheme;
    final int current = _options.contains(value)
        ? value
        : _options.firstWhere(
            (int candidate) => candidate >= value,
            orElse: () => _options.last,
          );
    return Padding(
      key: const Key('minimum-barcode-length-settings'),
      padding: const EdgeInsets.fromLTRB(16, 12, 12, 12),
      child: Row(
        children: <Widget>[
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: <Widget>[
                const Text(
                  '面单条码最短长度',
                  style: TextStyle(fontSize: 17, fontWeight: FontWeight.w800),
                ),
                const SizedBox(height: 5),
                Text(
                  '低于该长度不会触发录制',
                  style: TextStyle(
                    color: colors.onSurfaceVariant,
                    fontSize: 13,
                    height: 1.4,
                  ),
                ),
              ],
            ),
          ),
          const SizedBox(width: 8),
          DropdownButton<int>(
            key: const Key('minimum-barcode-length-dropdown'),
            value: current,
            isDense: true,
            underline: const SizedBox.shrink(),
            items: _options
                .map(
                  (int length) => DropdownMenuItem<int>(
                    value: length,
                    child: Text('$length 位'),
                  ),
                )
                .toList(growable: false),
            onChanged: (int? length) {
              if (length != null) {
                onChanged(length);
              }
            },
          ),
        ],
      ),
    );
  }
}

class _SpeechPromptSettings extends StatelessWidget {
  const _SpeechPromptSettings({
    required this.enabled,
    required this.onChanged,
    required this.onPreview,
  });

  final bool enabled;
  final ValueChanged<bool> onChanged;
  final Future<void> Function() onPreview;

  @override
  Widget build(BuildContext context) {
    final ColorScheme colors = Theme.of(context).colorScheme;
    return Padding(
      key: const Key('speech-prompt-settings'),
      padding: const EdgeInsets.fromLTRB(16, 12, 12, 12),
      child: Row(
        children: <Widget>[
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: <Widget>[
                Text(
                  '语音提示',
                  style: TextStyle(fontSize: 17, fontWeight: FontWeight.w800),
                ),
                SizedBox(height: 5),
                Text(
                  '离线自动使用系统语音',
                  style: TextStyle(
                    color: colors.onSurfaceVariant,
                    fontSize: 13,
                    height: 1.4,
                  ),
                ),
              ],
            ),
          ),
          TextButton(
            key: const Key('speech-preview-button'),
            onPressed: enabled ? onPreview : null,
            child: const Text('试听'),
          ),
          Switch(
            key: const Key('speech-enabled-switch'),
            value: enabled,
            onChanged: onChanged,
          ),
        ],
      ),
    );
  }
}

class _OrderSpeechSettings extends StatelessWidget {
  const _OrderSpeechSettings({
    required this.enabled,
    required this.masterEnabled,
    required this.onChanged,
  });

  final bool enabled;
  final bool masterEnabled;
  final ValueChanged<bool> onChanged;

  @override
  Widget build(BuildContext context) {
    final ColorScheme colors = Theme.of(context).colorScheme;
    return Padding(
      key: const Key('order-speech-settings'),
      padding: const EdgeInsets.fromLTRB(16, 12, 12, 12),
      child: Row(
        children: <Widget>[
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: <Widget>[
                const Text(
                  '订单播报',
                  style: TextStyle(fontSize: 17, fontWeight: FontWeight.w800),
                ),
                const SizedBox(height: 5),
                Text(
                  masterEnabled ? '播报留言、备注和退款提醒' : '请先开启语音提示',
                  style: TextStyle(
                    color: colors.onSurfaceVariant,
                    fontSize: 13,
                    height: 1.4,
                  ),
                ),
              ],
            ),
          ),
          Switch(
            key: const Key('order-speech-enabled-switch'),
            value: enabled,
            onChanged: onChanged,
          ),
        ],
      ),
    );
  }
}

class _MaxVolumeSettings extends StatelessWidget {
  const _MaxVolumeSettings({required this.enabled, required this.onChanged});

  final bool enabled;
  final ValueChanged<bool> onChanged;

  @override
  Widget build(BuildContext context) {
    final ColorScheme colors = Theme.of(context).colorScheme;
    return Padding(
      key: const Key('max-volume-settings'),
      padding: const EdgeInsets.fromLTRB(16, 12, 12, 12),
      child: Row(
        children: <Widget>[
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: <Widget>[
                Text(
                  '最大音量',
                  style: TextStyle(fontSize: 17, fontWeight: FontWeight.w800),
                ),
                SizedBox(height: 5),
                Text(
                  '工作时自动提高媒体音量',
                  style: TextStyle(
                    color: colors.onSurfaceVariant,
                    fontSize: 13,
                    height: 1.4,
                  ),
                ),
              ],
            ),
          ),
          Switch(
            key: const Key('max-volume-enabled-switch'),
            value: enabled,
            onChanged: onChanged,
          ),
        ],
      ),
    );
  }
}

extension _RecordingsSettingsView on _RecordingsScreenState {
  List<Widget> buildRecordingsSettingsChildren(BuildContext context) {
    return <Widget>[
      // 扫码与声音（工作模式、条码长度、语音与音量）收进同名的二级页。
      _SettingsEntryCard(
        key: const Key('scan-settings-card'),
        tileKey: const Key('scan-settings-open'),
        icon: Icons.qr_code_scanner_rounded,
        title: '扫码与声音',
        subtitle: '工作模式、条码长度与提示音',
        onOpen: () => Navigator.of(context).push<void>(
          MaterialPageRoute<void>(
            builder: (_) => _ScanSettingsScreen(
              workMode: _workMode,
              onWorkModeChanged: _setWorkMode,
              minimumBarcodeLength: _minimumBarcodeLength,
              onMinimumBarcodeLengthChanged:
                  widget.onMinimumBarcodeLengthChanged == null
                  ? null
                  : _setMinimumBarcodeLength,
              speechEnabled: _speechEnabled,
              onSpeechEnabledChanged: _setSpeechEnabled,
              onSpeechPreview: widget.onSpeechPreview,
              maxVolumeEnabled: _maxVolumeEnabled,
              maxVolumeSupported: _maxVolumeSupported,
              onMaxVolumeEnabledChanged: _setMaxVolumeEnabled,
            ),
          ),
        ),
      ),
      if (widget.showCameraCapabilityCard &&
          widget.capabilities?.supports(
                PlatformCapability.cameraCapabilityNegotiation,
              ) !=
              false &&
          widget.capabilityMode != null) ...<Widget>[
        const SizedBox(height: 12),
        _SettingsCard(
          key: const Key('camera-capability-settings-card'),
          children: <Widget>[
            _CameraCapabilitySettings(
              mode: widget.capabilityMode!,
              statusText: widget.capabilityStatusText ?? '',
              onRetry: widget.onRetryCapabilityProbe,
            ),
          ],
        ),
      ],
      const SizedBox(height: 12),
      // 清理相关（保留时间、清理策略与说明）收进「录像清理」二级页。
      _SettingsEntryCard(
        key: const Key('cleanup-settings-card'),
        tileKey: const Key('cleanup-settings-open'),
        icon: Icons.cleaning_services_rounded,
        title: '录像清理',
        subtitle: '保留时间、清理策略与说明',
        onOpen: () => Navigator.of(context).push<void>(
          MaterialPageRoute<void>(
            builder: (_) => _CleanupSettingsScreen(
              unbackedRetention: _unbackedRetention,
              backedRetention: _backedRetention,
              onUnbackedRetentionChanged:
                  (UnbackedRetentionPolicy value) async {
                    await _setUnbackedRetention(value);
                    return _unbackedRetention == value;
                  },
              // 「备份后立即清除」需要二次确认，被拒绝时保留原选择。
              onBackedRetentionChanged: (BackedRetentionPolicy value) async {
                await _setBackedRetention(value);
                return _backedRetention == value;
              },
              returnUnbackedRetention: _returnUnbackedRetention,
              returnBackedRetention: _returnBackedRetention,
              onReturnUnbackedRetentionChanged:
                  (UnbackedRetentionPolicy value) async {
                    await _setReturnUnbackedRetention(value);
                    return _returnUnbackedRetention == value;
                  },
              onReturnBackedRetentionChanged:
                  (BackedRetentionPolicy value) async {
                    await _setReturnBackedRetention(value);
                    return _returnBackedRetention == value;
                  },
              storagePressurePolicy: _storagePressurePolicy,
              onStoragePressurePolicyChanged: _setStoragePressurePolicy,
            ),
          ),
        ),
      ),
      const SizedBox(height: 12),
      // 录像相关（编码、规格方向、声音）收进二级页。
      _SettingsEntryCard(
        key: const Key('recording-settings-card'),
        tileKey: const Key('recording-settings-open'),
        icon: Icons.video_settings_rounded,
        title: '录像设置',
        subtitle: '编码、规格、方向与声音',
        onOpen: () => Navigator.of(context).push<void>(
          MaterialPageRoute<void>(
            builder: (_) => _RecordingSettingsScreen(
              codec: _preferredVideoCodec,
              hevcEnabled: _deviceDecodeSupport?.supportsHevcRecording ?? false,
              hevcWarning: _deviceDecodeSupport == null
                  ? null
                  : (!_deviceDecodeSupport!.supportsHevcRecording
                        ? '当前设备不支持完整的 H.265 录制与播放能力，已使用 H.264'
                        : null),
              onCodecChanged: _setPreferredVideoCodec,
              spec: _recordingSpec,
              availableSpecs: widget.availableRecordingSpecs,
              showUhd4kOption: widget.showUhd4kOption,
              onSpecChanged: _setRecordingSpec,
              orientation: _recordingOrientation,
              onOrientationChanged: (value) {
                unawaited(_setRecordingOrientation(value));
              },
              recordAudio: _recordAudioEnabled,
              onRecordAudioChanged: _setRecordAudioEnabled,
            ),
          ),
        ),
      ),
      if (_orderReceiverSupported) ...<Widget>[
        const SizedBox(height: 12),
        // 订单接收与订单播报收进二级页。
        _SettingsEntryCard(
          key: const Key('order-receiver-settings'),
          tileKey: const Key('order-receiver-open'),
          icon: Icons.receipt_long_outlined,
          title: '订单接收',
          subtitle: '接收地址与订单播报',
          onOpen: () => Navigator.of(context).push<void>(
            MaterialPageRoute<void>(
              builder: (_) => _OrderReceiverScreen(
                snapshotProvider: () => widget.orderReceiverSnapshot,
                onRetry: widget.onRetryOrderReceiver,
                speechEnabled: _orderSpeechEnabled,
                speechMasterEnabled: _speechEnabled,
                onSpeechChanged: _setOrderSpeechEnabled,
                listenable: widget.backupListenable,
              ),
            ),
          ),
        ),
      ],
      const SizedBox(height: 12),
      const AboutSettings(),
    ];
  }
}
