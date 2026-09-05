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

  static const String _retentionDescription =
      '每组录像分别设置未备份和备份后的保留时间，选择“不清除”则一直保留。\n'
      '已备份录像清理前会向电脑确认，电脑离线或校验未完成时会暂时保留。\n'
      '空间不足时优先清理最老的、已完成电脑校验的备份录像，不会删除未备份录像。\n'
      '正在上传或等待备份的录像会延后清理';

  @override
  Widget build(BuildContext context) {
    return Padding(
      padding: const EdgeInsets.fromLTRB(16, 12, 16, 16),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: <Widget>[
          Row(
            children: <Widget>[
              const Text(
                '发货录像清理',
                style: TextStyle(fontSize: 17, fontWeight: FontWeight.w800),
              ),
              const Spacer(),
              IconButton(
                key: const Key('retention-info-button'),
                tooltip: '录像清理说明',
                visualDensity: VisualDensity.compact,
                padding: EdgeInsets.zero,
                constraints: const BoxConstraints(minWidth: 36, minHeight: 36),
                iconSize: 20,
                icon: const Icon(Icons.help_outline_rounded),
                onPressed: () => _showRetentionInfo(context),
              ),
            ],
          ),
          const SizedBox(height: 6),
          _RetentionDropdowns(
            keyPrefix: 'shipping',
            unbackedRetention: unbackedRetention,
            backedRetention: backedRetention,
            onUnbackedRetentionChanged: onUnbackedRetentionChanged,
            onBackedRetentionChanged: onBackedRetentionChanged,
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

  Future<void> _showRetentionInfo(BuildContext context) {
    return showDialog<void>(
      context: context,
      builder: (BuildContext dialogContext) => AlertDialog(
        title: const Text('录像清理说明'),
        content: const Text(_retentionDescription),
        actions: <Widget>[
          TextButton(
            onPressed: () => Navigator.of(dialogContext).pop(),
            child: const Text('知道了'),
          ),
        ],
      ),
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
    final ColorScheme colors = Theme.of(context).colorScheme;
    return <Widget>[
      _SettingsCard(
        key: const Key('work-settings-card'),
        children: <Widget>[
          _WorkModeSettings(workMode: _workMode, onChanged: _setWorkMode),
          if (widget.onMinimumBarcodeLengthChanged != null) ...<Widget>[
            Divider(height: 1, thickness: 1, color: colors.outlineVariant),
            _MinimumBarcodeLengthSettings(
              value: _minimumBarcodeLength,
              onChanged: _setMinimumBarcodeLength,
            ),
          ],
        ],
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
      _SettingsCard(
        key: const Key('recording-settings-card'),
        children: <Widget>[
          _RetentionSettings(
            unbackedRetention: _unbackedRetention,
            backedRetention: _backedRetention,
            onUnbackedRetentionChanged: _setUnbackedRetention,
            onBackedRetentionChanged: _setBackedRetention,
            returnUnbackedRetention: _returnUnbackedRetention,
            returnBackedRetention: _returnBackedRetention,
            onReturnUnbackedRetentionChanged: _setReturnUnbackedRetention,
            onReturnBackedRetentionChanged: _setReturnBackedRetention,
          ),
          Divider(height: 1, thickness: 1, color: colors.outlineVariant),
          _VideoCodecSettings(
            codec: _preferredVideoCodec,
            hevcEnabled: _deviceDecodeSupport?.supportsHevcRecording ?? false,
            hevcWarning: _deviceDecodeSupport == null
                ? null
                : (!_deviceDecodeSupport!.supportsHevcRecording
                      ? '当前设备不支持完整的 H.265 录制与播放能力，已使用 H.264'
                      : null),
            onChanged: _setPreferredVideoCodec,
          ),
          Divider(height: 1, thickness: 1, color: colors.outlineVariant),
          _RecordingSpecSettings(
            spec: _recordingSpec,
            availableSpecs: widget.availableRecordingSpecs,
            showUhd4kOption: widget.showUhd4kOption,
            onChanged: _setRecordingSpec,
          ),
          Divider(height: 1, thickness: 1, color: colors.outlineVariant),
          _RecordingOrientationSettings(
            orientation: _recordingOrientation,
            onChanged: (value) {
              unawaited(_setRecordingOrientation(value));
            },
          ),
          Divider(height: 1, thickness: 1, color: colors.outlineVariant),
          _RecordAudioSettings(
            enabled: _recordAudioEnabled,
            onChanged: _setRecordAudioEnabled,
          ),
        ],
      ),
      const SizedBox(height: 12),
      _SettingsCard(
        key: const Key('voice-settings-card'),
        children: <Widget>[
          _SpeechPromptSettings(
            enabled: _speechEnabled,
            onChanged: _setSpeechEnabled,
            onPreview: widget.onSpeechPreview,
          ),
          if (_maxVolumeSupported) ...<Widget>[
            Divider(height: 1, thickness: 1, color: colors.outlineVariant),
            _MaxVolumeSettings(
              enabled: _maxVolumeEnabled,
              onChanged: _setMaxVolumeEnabled,
            ),
          ],
        ],
      ),
      if (_orderReceiverSupported) ...<Widget>[
        const SizedBox(height: 12),
        _OrderReceiverSettings(
          snapshot: widget.orderReceiverSnapshot,
          onRetry: widget.onRetryOrderReceiver,
          speechEnabled: _orderSpeechEnabled,
          speechMasterEnabled: _speechEnabled,
          onSpeechChanged: _setOrderSpeechEnabled,
        ),
      ],
      const SizedBox(height: 12),
      const AboutSettings(),
    ];
  }
}
