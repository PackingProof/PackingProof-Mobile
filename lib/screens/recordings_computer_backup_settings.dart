part of 'recordings_screen.dart';

class _ComputerBackupSettings extends StatelessWidget {
  const _ComputerBackupSettings({
    required this.snapshot,
    required this.allBackedUp,
    required this.remainingBackupCount,
    required this.onConnect,
    this.onAutoChanged,
    this.onBackupNow,
    this.onDisconnect,
    this.onRetryConnection,
    this.onRetry,
    required this.unbackedRetention,
    required this.backedRetention,
    required this.onUnbackedRetentionChanged,
    required this.onBackedRetentionChanged,
    this.showRetention = true,
    this.discovery = const LanBackupDiscoverySnapshot(),
    this.onSearchHosts,
    this.onSelectHost,
    this.onRequestApproval,
    this.onCancelApproval,
  });

  final LanBackupSnapshot snapshot;
  final bool allBackedUp;
  final int remainingBackupCount;
  final VoidCallback onConnect;
  final Future<void> Function(bool enabled)? onAutoChanged;
  final Future<void> Function()? onBackupNow;
  final Future<void> Function()? onDisconnect;
  final Future<void> Function()? onRetryConnection;
  final Future<void> Function(String jobId)? onRetry;
  final UnbackedRetentionPolicy unbackedRetention;
  final BackedRetentionPolicy backedRetention;
  final ValueChanged<UnbackedRetentionPolicy> onUnbackedRetentionChanged;
  final ValueChanged<BackedRetentionPolicy> onBackedRetentionChanged;
  final bool showRetention;
  final LanBackupDiscoverySnapshot discovery;
  final Future<void> Function()? onSearchHosts;
  final Future<void> Function(LanBackupDiscoveredHost host)? onSelectHost;
  final Future<void> Function()? onRequestApproval;
  final VoidCallback? onCancelApproval;

  @override
  Widget build(BuildContext context) {
    final ColorScheme colors = Theme.of(context).colorScheme;
    final LanBackupJob? active = snapshot.jobs.cast<LanBackupJob?>().firstWhere(
      (LanBackupJob? job) => job?.state == LanBackupJobState.uploading,
      orElse: () => null,
    );
    final LanBackupJob? failed = snapshot.jobs.cast<LanBackupJob?>().firstWhere(
      (LanBackupJob? job) => job?.state == LanBackupJobState.failed,
      orElse: () => null,
    );
    final LanBackupJob? paused = snapshot.jobs.cast<LanBackupJob?>().firstWhere(
      (LanBackupJob? job) => job?.state == LanBackupJobState.paused,
      orElse: () => null,
    );
    final LanBackupJob? credentialFailure = snapshot.jobs
        .cast<LanBackupJob?>()
        .firstWhere(
          (LanBackupJob? job) =>
              (job?.state == LanBackupJobState.failed ||
                  job?.state == LanBackupJobState.paused) &&
              job?.failureKind == LanBackupFailureKind.credentialInvalid,
          orElse: () => null,
        );
    final LanBackupJob? notBackupHostFailure = snapshot.jobs
        .cast<LanBackupJob?>()
        .firstWhere(
          (LanBackupJob? job) =>
              (job?.state == LanBackupJobState.failed ||
                  job?.state == LanBackupJobState.paused) &&
              job?.failureKind == LanBackupFailureKind.notBackupHost,
          orElse: () => null,
        );
    final LanBackupJob? classifiedFailure = failed?.failureKind != null
        ? failed
        : paused?.failureKind != null
        ? paused
        : null;
    final LanBackupFailureKind? failureKind =
        snapshot.connectionStatus == LanConnectionStatus.notBackupHost ||
            notBackupHostFailure != null
        ? LanBackupFailureKind.notBackupHost
        : snapshot.connectionStatus == LanConnectionStatus.rePair ||
              credentialFailure != null
        ? LanBackupFailureKind.credentialInvalid
        : classifiedFailure?.failureKind;
    final int pending = snapshot.jobs
        .where((LanBackupJob job) => job.state == LanBackupJobState.pending)
        .length;
    final int progress = ((active?.progress ?? 0) * 100).round();
    final bool paired = snapshot.endpoint != null;
    final String remainingLabel = remainingBackupCount == 0
        ? '全部完成'
        : '$remainingBackupCount 个未备份';
    final bool online =
        snapshot.connectionStatus == LanConnectionStatus.connected;
    final bool needsRepair =
        snapshot.connectionStatus == LanConnectionStatus.rePair ||
        snapshot.connectionStatus == LanConnectionStatus.notBackupHost ||
        failureKind == LanBackupFailureKind.credentialInvalid ||
        failureKind == LanBackupFailureKind.notBackupHost;
    final bool connecting =
        snapshot.connectionStatus == LanConnectionStatus.connecting;
    final bool awaitingApproval =
        snapshot.connectionStatus == LanConnectionStatus.awaitingApproval;
    final bool approvalFailed =
        snapshot.connectionStatus == LanConnectionStatus.approvalDenied ||
        snapshot.connectionStatus == LanConnectionStatus.approvalUnavailable;
    final bool approvalDenied =
        snapshot.connectionStatus == LanConnectionStatus.approvalDenied;
    final bool offline =
        snapshot.connectionStatus == LanConnectionStatus.offline;
    final String stateLabel = discovery.searching && !paired
        ? '搜索中'
        : awaitingApproval
        ? '等待允许'
        : approvalFailed
        ? '未允许'
        : connecting
        ? '连接中'
        : online
        ? '在线'
        : needsRepair
        ? '需允许'
        : offline
        ? '离线'
        : paired
        ? '离线'
        : '未连接';
    final Color stateForeground = online
        ? colors.primary
        : needsRepair || approvalFailed
        ? const Color(0xFFA35A16)
        : discovery.searching || awaitingApproval || connecting
        ? colors.primary
        : colors.onSurfaceVariant;
    final String? status = awaitingApproval || approvalFailed
        ? snapshot.message
        : offline
        ? (snapshot.message?.isNotEmpty == true
              ? snapshot.message!
              : paired
              ? '电脑离线，备份已暂停'
              : '电脑离线，请检查 Wi-Fi 后重新搜索')
        : !snapshot.connected
        ? '扫描电脑二维码后自动备份'
        : failureKind == LanBackupFailureKind.notBackupHost
        ? '连接的电脑当前不是录像备份主机，请切换电脑用途或重新搜索'
        : needsRepair
        ? '设备连接已失效，请重新申请并在电脑上允许连接'
        : connecting
        ? '正在重新连接电脑'
        : active != null
        ? '正在备份 · $progress%'
        : failed != null
        ? (failed.errorMessage ?? '备份失败')
        : paused != null
        ? (paused.errorMessage ?? '等待自动续传')
        : allBackedUp && online
        ? '备份完成'
        : pending > 0
        ? '还有 $pending 个录像等待备份'
        : null;

    final String disconnectedMessage = awaitingApproval || approvalFailed
        ? (snapshot.message ?? '请在电脑上处理连接申请')
        : offline
        ? (snapshot.message?.isNotEmpty == true
              ? snapshot.message!
              : '电脑离线，请检查 Wi-Fi 后重新搜索')
        : discovery.searching
        ? (discovery.hosts.isEmpty
              ? discovery.message ?? '正在查找同一 Wi-Fi 下的保存主机'
              : '正在重新搜索，下面保留上次找到的电脑')
        : discovery.hosts.where((host) => host.reachable).length > 1
        ? '找到 ${discovery.hosts.where((host) => host.reachable).length} 台保存主机，请选择一台连接'
        : discovery.hosts.where((host) => host.reachable).length == 1
        ? '已找到保存主机，正在等待电脑上点击允许'
        : discovery.hosts.isNotEmpty
        ? '暂未找到在线主机，已保留上次搜索结果'
        : discovery.message ?? '自动搜索保存主机，连接时需在电脑上允许';

    return Container(
      key: const Key('computer-backup-settings'),
      padding: const EdgeInsets.all(14),
      decoration: BoxDecoration(
        color: colors.surfaceContainer,
        borderRadius: BorderRadius.circular(16),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: <Widget>[
          Row(
            children: <Widget>[
              Expanded(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: <Widget>[
                    const Text(
                      '电脑备份',
                      style: TextStyle(
                        fontSize: 17,
                        fontWeight: FontWeight.w800,
                      ),
                    ),
                    const SizedBox(height: 2),
                    if (paired)
                      Text(
                        snapshot.endpoint!.computerName.isEmpty
                            ? snapshot.endpoint!.baseUri.host
                            : '${snapshot.endpoint!.computerName} · ${snapshot.endpoint!.baseUri.host}',
                        maxLines: 1,
                        overflow: TextOverflow.ellipsis,
                        style: TextStyle(
                          color: colors.onSurfaceVariant,
                          fontSize: 12,
                        ),
                      )
                    else
                      Row(
                        children: <Widget>[
                          Text(
                            remainingLabel,
                            style: TextStyle(
                              color: colors.onSurfaceVariant,
                              fontSize: 12,
                              fontWeight: FontWeight.w700,
                            ),
                          ),
                          Text(
                            ' · 连接后自动备份',
                            style: TextStyle(
                              color: colors.onSurfaceVariant,
                              fontSize: 12,
                            ),
                          ),
                        ],
                      ),
                  ],
                ),
              ),
              const SizedBox(width: 8),
              Text(
                key: const Key('computer-backup-state-text'),
                stateLabel,
                style: TextStyle(
                  color: stateForeground,
                  fontSize: 12,
                  fontWeight: FontWeight.w800,
                ),
              ),
              if (paired && onDisconnect != null) ...<Widget>[
                const SizedBox(width: 8),
                IconButton(
                  key: const Key('delete-computer-button'),
                  tooltip: '删除电脑',
                  visualDensity: VisualDensity.compact,
                  style: IconButton.styleFrom(
                    foregroundColor: colors.error,
                    side: BorderSide(
                      color: colors.error.withValues(alpha: 0.55),
                    ),
                    shape: const CircleBorder(),
                    minimumSize: const Size.square(36),
                    maximumSize: const Size.square(36),
                  ),
                  onPressed: onDisconnect,
                  icon: const Icon(Icons.delete_outline_rounded, size: 20),
                ),
              ],
            ],
          ),
          const SizedBox(height: 12),
          if (!paired) ...<Widget>[
            Column(
              key: (awaitingApproval || approvalFailed)
                  ? const Key('backup-approval-status')
                  : const Key('backup-host-search-status'),
              crossAxisAlignment: CrossAxisAlignment.start,
              children: <Widget>[
                Text(
                  disconnectedMessage,
                  maxLines: 2,
                  overflow: TextOverflow.ellipsis,
                  style: TextStyle(
                    color: colors.onSurfaceVariant,
                    fontSize: 12,
                    height: 1.35,
                    fontWeight: awaitingApproval || approvalFailed
                        ? FontWeight.w700
                        : FontWeight.w500,
                  ),
                ),
                if (discovery.searching) ...<Widget>[
                  const SizedBox(height: 8),
                  LinearProgressIndicator(
                    key: const Key('backup-host-search-progress'),
                    value: discovery.progress,
                    minHeight: 4,
                    borderRadius: BorderRadius.circular(99),
                  ),
                ],
              ],
            ),
            if (discovery.hosts.isNotEmpty &&
                !awaitingApproval &&
                !approvalFailed) ...<Widget>[
              const SizedBox(height: 10),
              Text(
                '找到的电脑',
                style: TextStyle(
                  color: colors.onSurfaceVariant,
                  fontSize: 12,
                  fontWeight: FontWeight.w700,
                ),
              ),
              const SizedBox(height: 7),
              ...discovery.hosts.map(
                (LanBackupDiscoveredHost host) => Padding(
                  padding: const EdgeInsets.only(bottom: 6),
                  child: Material(
                    color: colors.surfaceContainerHighest,
                    borderRadius: BorderRadius.circular(10),
                    child: InkWell(
                      key: ValueKey<String>(
                        'discovered-backup-host-${host.nodeId}',
                      ),
                      onTap:
                          onSelectHost == null ||
                              !host.compatible ||
                              !host.reachable ||
                              offline
                          ? null
                          : () => onSelectHost!(host),
                      borderRadius: BorderRadius.circular(10),
                      child: Padding(
                        padding: const EdgeInsets.symmetric(
                          horizontal: 12,
                          vertical: 8,
                        ),
                        child: Row(
                          children: <Widget>[
                            Expanded(
                              child: Column(
                                crossAxisAlignment: CrossAxisAlignment.start,
                                children: <Widget>[
                                  Text(
                                    host.name,
                                    maxLines: 1,
                                    overflow: TextOverflow.ellipsis,
                                    style: const TextStyle(
                                      fontSize: 14,
                                      fontWeight: FontWeight.w700,
                                    ),
                                  ),
                                  const SizedBox(height: 2),
                                  Text(
                                    host.compatible
                                        ? host.reachable
                                              ? host.address
                                              : '${host.address} · 上次找到'
                                        : '${host.address} · 电脑端需更新',
                                    maxLines: 1,
                                    overflow: TextOverflow.ellipsis,
                                    style: const TextStyle(fontSize: 11),
                                  ),
                                ],
                              ),
                            ),
                            const SizedBox(width: 8),
                            Text(
                              host.compatible && host.reachable && !offline
                                  ? '连接'
                                  : host.compatible && offline
                                  ? '离线'
                                  : host.compatible
                                  ? '未在线'
                                  : '需更新',
                              style: TextStyle(
                                color:
                                    host.compatible &&
                                        host.reachable &&
                                        !offline
                                    ? colors.primary
                                    : colors.onSurfaceVariant,
                                fontSize: 12,
                                fontWeight: FontWeight.w700,
                              ),
                            ),
                          ],
                        ),
                      ),
                    ),
                  ),
                ),
              ),
            ],
            const SizedBox(height: 12),
            if (awaitingApproval)
              SizedBox(
                width: double.infinity,
                child: FilledButton.tonalIcon(
                  key: const Key('cancel-backup-approval-button'),
                  onPressed: onCancelApproval,
                  style: OutlinedButton.styleFrom(
                    minimumSize: const Size.fromHeight(48),
                  ),
                  icon: const Icon(Icons.close_rounded, size: 18),
                  label: const Text('取消等待'),
                ),
              )
            else
              Row(
                children: <Widget>[
                  Expanded(
                    child: FilledButton.tonalIcon(
                      key: const Key('search-backup-host-button'),
                      onPressed: discovery.searching
                          ? null
                          : approvalDenied && onRequestApproval != null
                          ? onRequestApproval
                          : onSearchHosts,
                      icon: Icon(
                        approvalDenied
                            ? Icons.refresh_rounded
                            : Icons.wifi_find_rounded,
                        size: 18,
                      ),
                      label: Text(
                        discovery.searching
                            ? '正在搜索'
                            : approvalDenied
                            ? '再次申请'
                            : '重新搜索',
                      ),
                      style: FilledButton.styleFrom(
                        minimumSize: const Size.fromHeight(48),
                      ),
                    ),
                  ),
                  const SizedBox(width: 8),
                  Expanded(
                    child: FilledButton.tonalIcon(
                      key: const Key('connect-computer-button'),
                      onPressed: discovery.searching ? null : onConnect,
                      icon: const Icon(Icons.qr_code_scanner_rounded, size: 18),
                      label: const Text('扫码连接'),
                      style: FilledButton.styleFrom(
                        minimumSize: const Size.fromHeight(48),
                      ),
                    ),
                  ),
                ],
              ),
          ],
          if (snapshot.endpoint != null) ...<Widget>[
            Text(
              key: const Key('connected-computer-summary'),
              status ?? remainingLabel,
              maxLines: 2,
              overflow: TextOverflow.ellipsis,
              style: TextStyle(
                color: colors.onSurfaceVariant,
                fontSize: 12,
                height: 1.35,
                fontWeight: FontWeight.w600,
              ),
            ),
          ],
          if (active != null && !needsRepair) ...<Widget>[
            const SizedBox(height: 8),
            LinearProgressIndicator(value: active.progress),
          ],
          if (showRetention) ...<Widget>[
            const SizedBox(height: 14),
            _RetentionDropdowns(
              unbackedRetention: unbackedRetention,
              backedRetention: backedRetention,
              onUnbackedRetentionChanged: onUnbackedRetentionChanged,
              onBackedRetentionChanged: onBackedRetentionChanged,
            ),
          ],
          if (paired && awaitingApproval) ...<Widget>[
            const SizedBox(height: 12),
            SizedBox(
              width: double.infinity,
              child: OutlinedButton.icon(
                key: const Key('cancel-backup-approval-button'),
                onPressed: onCancelApproval,
                icon: const Icon(Icons.close_rounded),
                label: const Text('取消等待'),
              ),
            ),
          ] else if (paired && approvalFailed) ...<Widget>[
            const SizedBox(height: 12),
            SizedBox(
              width: double.infinity,
              child: FilledButton.tonalIcon(
                key: const Key('retry-backup-approval-button'),
                onPressed: onRequestApproval,
                icon: const Icon(Icons.refresh_rounded),
                label: const Text('再次申请'),
              ),
            ),
          ] else if (paired && failureKind != null) ...<Widget>[
            const SizedBox(height: 12),
            SizedBox(
              width: double.infinity,
              child: FilledButton.icon(
                key: const Key('backup-failure-action-button'),
                onPressed: switch (failureKind.recoveryAction) {
                  LanBackupRecoveryAction.rescan => onRequestApproval,
                  LanBackupRecoveryAction.retryConnection => onRetryConnection,
                  LanBackupRecoveryAction.updateComputer => null,
                  LanBackupRecoveryAction.retryBackup =>
                    online && onRetry != null
                        ? () => onRetry!(classifiedFailure!.id)
                        : null,
                },
                icon: Icon(
                  failureKind == LanBackupFailureKind.credentialInvalid ||
                          failureKind == LanBackupFailureKind.notBackupHost
                      ? Icons.admin_panel_settings_rounded
                      : failureKind == LanBackupFailureKind.incompatibleVersion
                      ? Icons.system_update_rounded
                      : failureKind == LanBackupFailureKind.offlineOrTimeout
                      ? Icons.wifi_find_rounded
                      : Icons.refresh_rounded,
                ),
                label: Text(failureKind.recoveryLabel),
              ),
            ),
          ] else if (paired) ...<Widget>[
            if (failed != null) ...<Widget>[
              const SizedBox(height: 12),
              SizedBox(
                width: double.infinity,
                child: FilledButton.tonalIcon(
                  key: const Key('backup-now-button'),
                  onPressed: online && onRetry != null
                      ? () => onRetry!(failed.id)
                      : null,
                  icon: const Icon(Icons.refresh_rounded),
                  label: const Text('重试备份'),
                ),
              ),
            ] else if (!online || connecting) ...<Widget>[
              const SizedBox(height: 12),
              SizedBox(
                width: double.infinity,
                child: FilledButton.tonalIcon(
                  key: const Key('backup-now-button'),
                  onPressed: connecting ? null : onRetryConnection,
                  icon: Icon(
                    connecting ? Icons.sync_rounded : Icons.refresh_rounded,
                  ),
                  label: Text(connecting ? '正在连接' : '重新连接'),
                ),
              ),
            ] else ...<Widget>[
              const SizedBox(height: 12),
              Row(
                children: <Widget>[
                  Expanded(
                    child: FilledButton.tonal(
                      key: const Key('backup-now-button'),
                      onPressed: !allBackedUp ? onBackupNow : null,
                      style: FilledButton.styleFrom(
                        minimumSize: const Size.fromHeight(46),
                      ),
                      child: const Text('立即备份'),
                    ),
                  ),
                  const SizedBox(width: 8),
                  Expanded(
                    child: FilledButton.tonal(
                      key: const Key('auto-backup-button'),
                      onPressed: onAutoChanged == null
                          ? null
                          : () => onAutoChanged!(!snapshot.autoEnabled),
                      style: FilledButton.styleFrom(
                        minimumSize: const Size.fromHeight(46),
                      ),
                      child: Text(snapshot.autoEnabled ? '暂停自动备份' : '继续自动备份'),
                    ),
                  ),
                ],
              ),
            ],
          ],
        ],
      ),
    );
  }
}
