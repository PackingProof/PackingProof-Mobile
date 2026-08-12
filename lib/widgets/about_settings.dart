import 'dart:async';
import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:package_info_plus/package_info_plus.dart';
import 'package:share_plus/share_plus.dart';
import 'package:url_launcher/url_launcher.dart';

import '../app/app_build_config.dart';
import '../app/packing_proof_mobile_app.dart';
import '../services/camera_diagnostics_service.dart';
import '../services/continuous_camera_service.dart';
import '../services/diagnostics_log_service.dart';

const String packingProofRepositoryUrl =
    'https://github.com/PackingProof/PackingProof-Mobile';
const String packingProofReleasesUrl =
    'https://gitee.com/PackingProof/PackingProof-Mobile/releases/latest';
const String packingProofSupportEmail = 'PackingProof@outlook.com';

typedef PackageInfoLoader = Future<PackageInfo> Function();
typedef ExternalUriLauncher = Future<bool> Function(Uri uri);
typedef DiagnosticsTextLoader = Future<String?> Function();

class AboutSettings extends StatelessWidget {
  const AboutSettings({
    this.packageInfoLoader,
    this.uriLauncher,
    this.buildConfig = AppBuildConfig.environment,
    this.diagnosticsLoader,
    super.key,
  });

  final PackageInfoLoader? packageInfoLoader;
  final ExternalUriLauncher? uriLauncher;
  final AppBuildConfig buildConfig;
  final DiagnosticsTextLoader? diagnosticsLoader;

  @override
  Widget build(BuildContext context) {
    final ColorScheme colors = Theme.of(context).colorScheme;
    return Material(
      key: const Key('about-settings'),
      color: colors.surfaceContainer,
      shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(20)),
      clipBehavior: Clip.antiAlias,
      child: ListTile(
        key: const Key('about-settings-open'),
        contentPadding: const EdgeInsets.symmetric(horizontal: 16, vertical: 6),
        leading: const Icon(Icons.info_outline_rounded),
        title: const Text(
          '关于',
          style: TextStyle(fontSize: 17, fontWeight: FontWeight.w800),
        ),
        subtitle: const Text('版本、源码和开源项目'),
        trailing: const Icon(Icons.chevron_right_rounded),
        onTap: () => Navigator.of(context).push<void>(
          MaterialPageRoute<void>(
            builder: (_) => AboutScreen(
              packageInfoLoader: packageInfoLoader,
              uriLauncher: uriLauncher,
              buildConfig: buildConfig,
              diagnosticsLoader: diagnosticsLoader,
            ),
          ),
        ),
      ),
    );
  }
}

class AboutScreen extends StatefulWidget {
  const AboutScreen({
    this.packageInfoLoader,
    this.uriLauncher,
    this.buildConfig = AppBuildConfig.environment,
    this.diagnosticsLoader,
    super.key,
  });

  final PackageInfoLoader? packageInfoLoader;
  final ExternalUriLauncher? uriLauncher;
  final AppBuildConfig buildConfig;
  final DiagnosticsTextLoader? diagnosticsLoader;

  @override
  State<AboutScreen> createState() => _AboutScreenState();
}

class _AboutScreenState extends State<AboutScreen> {
  late final Future<PackageInfo> _packageInfo =
      (widget.packageInfoLoader ?? PackageInfo.fromPlatform)();

  static const List<({String name, String url})>
  _credits = <({String name, String url})>[
    (name: 'Flutter', url: 'https://github.com/flutter/flutter'),
    (name: 'camera', url: 'https://pub.dev/packages/camera'),
    (name: 'Google ML Kit', url: 'https://developers.google.com/ml-kit'),
    (name: 'SQLite / sqflite', url: 'https://pub.dev/packages/sqflite'),
    (name: 'video_player', url: 'https://pub.dev/packages/video_player'),
    (
      name: 'AndroidX Media3',
      url: 'https://developer.android.com/media/media3',
    ),
    (
      name: 'WorkManager',
      url:
          'https://developer.android.com/topic/libraries/architecture/workmanager',
    ),
    (name: 'NanoHTTPD', url: 'https://github.com/NanoHttpd/nanohttpd'),
    (name: 'wakelock_plus', url: 'https://pub.dev/packages/wakelock_plus'),
    (name: 'flutter_tts', url: 'https://pub.dev/packages/flutter_tts'),
    (name: 'audioplayers', url: 'https://pub.dev/packages/audioplayers'),
    (name: 'Microsoft Edge TTS', url: 'https://www.microsoft.com/edge'),
  ];

  Future<void> _open(String value) async {
    final ExternalUriLauncher launcher =
        widget.uriLauncher ??
        (Uri uri) => launchUrl(uri, mode: LaunchMode.externalApplication);
    final bool opened = await launcher(Uri.parse(value));
    if (!opened && mounted) {
      ScaffoldMessenger.of(
        context,
      ).showSnackBar(const SnackBar(content: Text('无法打开链接，请稍后重试')));
    }
  }

  Future<void> _exportDiagnostics() async {
    String? text;
    try {
      final DiagnosticsTextLoader loader =
          widget.diagnosticsLoader ?? _loadDefaultDiagnostics;
      text = await loader();
    } on Object {
      text = null;
    }
    if (text == null || text.isEmpty) {
      if (!mounted) return;
      ScaffoldMessenger.of(
        context,
      ).showSnackBar(const SnackBar(content: Text('暂无诊断记录')));
      return;
    }
    final File? file = await _writeDiagnosticsFile(text);
    final bool shared = file != null && await _shareDiagnostics(file);
    if (shared || !mounted) {
      if (shared && mounted) {
        unawaited(
          DiagnosticsLogService().log(
            kind: 'diagnostics_export',
            extra: <String, Object?>{
              'shared': true,
              'copied': false,
              'chars': text.length,
            },
          ),
        );
      }
      return;
    }
    bool copied = false;
    try {
      await Clipboard.setData(ClipboardData(text: text));
      copied = true;
    } on Object {
      copied = false;
    }
    if (!mounted) return;
    unawaited(
      DiagnosticsLogService().log(
        kind: 'diagnostics_export',
        extra: <String, Object?>{
          'shared': false,
          'copied': copied,
          'chars': text.length,
        },
      ),
    );
    ScaffoldMessenger.of(context).showSnackBar(
      SnackBar(content: Text(copied ? '分享不可用，诊断日志已复制到剪贴板' : '无法导出诊断日志，请稍后重试')),
    );
  }

  Future<String?> _loadDefaultDiagnostics() async {
    final String header = await _diagnosticsHeader();
    return CameraDiagnosticsService().exportText(header: header);
  }

  Future<String> _diagnosticsHeader() async {
    final PackageInfo info = await _packageInfo;
    final CameraDiagnosticsSnapshot? snapshot = await CameraDiagnosticsService()
        .loadSnapshot();
    final String build = widget.buildConfig.buildTimestamp.isEmpty
        ? widget.buildConfig.buildRevision
        : '${widget.buildConfig.buildRevision} · ${widget.buildConfig.buildTimestamp}';
    return <String>[
      'PackingProof-Mobile 诊断日志',
      '导出时间: ${DateTime.now().toIso8601String()}',
      '版本: ${info.version}+${info.buildNumber}',
      '构建: ${build.isEmpty ? '未知' : build}',
      '设备: ${snapshot?.deviceSummary ?? '未知设备'}',
    ].join('\n');
  }

  Future<File?> _writeDiagnosticsFile(String text) async {
    try {
      return await CameraDiagnosticsService().writeExportFile(text);
    } on Object {
      return null;
    }
  }

  Future<bool> _shareDiagnostics(File file) async {
    try {
      final ShareResult result = await SharePlus.instance.share(
        ShareParams(
          title: 'PackingProof 诊断日志',
          files: <XFile>[XFile(file.path, mimeType: 'text/plain')],
        ),
      );
      return result.status != ShareResultStatus.unavailable;
    } on Object {
      return false;
    }
  }

  Future<void> _showStartupNotice() => Navigator.of(context).push<void>(
    MaterialPageRoute<void>(
      builder: (_) => StartupNoticeScreen(
        buildConfig: widget.buildConfig,
        confirmLabel: '关闭',
        onConfirm: () async => Navigator.of(context).pop(),
      ),
    ),
  );

  Future<void> _showHeartEasterEgg() => showDialog<void>(
    context: context,
    builder: (BuildContext dialogContext) => const _HeartEasterEggDialog(),
  );

  @override
  Widget build(BuildContext context) {
    final ColorScheme colors = Theme.of(context).colorScheme;
    return Scaffold(
      appBar: AppBar(title: const Text('关于')),
      body: ListView(
        padding: const EdgeInsets.fromLTRB(18, 8, 18, 28),
        children: <Widget>[
          Material(
            color: colors.surfaceContainer,
            shape: RoundedRectangleBorder(
              side: BorderSide(color: colors.outlineVariant),
              borderRadius: BorderRadius.circular(20),
            ),
            child: Padding(
              padding: const EdgeInsets.all(16),
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: <Widget>[
                  FutureBuilder<PackageInfo>(
                    future: _packageInfo,
                    builder:
                        (
                          BuildContext context,
                          AsyncSnapshot<PackageInfo> snapshot,
                        ) {
                          final PackageInfo? info = snapshot.data;
                          final String version = info == null
                              ? '正在读取版本'
                              : '版本 ${info.version}+${info.buildNumber}';
                          final String revision = widget
                              .buildConfig
                              .buildRevision
                              .trim();
                          return _InfoRow(
                            icon: Icons.info_outline_rounded,
                            title: 'PackingProof-Mobile',
                            subtitle: revision.isEmpty
                                ? version
                                : '$version · $revision',
                            onTap: _showStartupNotice,
                            onLongPress: _showHeartEasterEgg,
                          );
                        },
                  ),
                  const SizedBox(height: 8),
                  _LinkRow(
                    icon: Icons.code_rounded,
                    title: '源码仓库',
                    subtitle: packingProofRepositoryUrl,
                    onTap: () => unawaited(_open(packingProofRepositoryUrl)),
                  ),
                  const SizedBox(height: 8),
                  _LinkRow(
                    icon: Icons.system_update_alt_rounded,
                    title: '检查更新',
                    subtitle: packingProofReleasesUrl,
                    onTap: () => unawaited(_open(packingProofReleasesUrl)),
                  ),
                  const SizedBox(height: 8),
                  _InfoRow(
                    icon: Icons.bug_report_outlined,
                    title: '导出诊断日志',
                    subtitle: '分享或复制后发送到 $packingProofSupportEmail',
                    onTap: () => unawaited(_exportDiagnostics()),
                  ),
                  const SizedBox(height: 14),
                  const Text(
                    '感谢以下开源项目',
                    style: TextStyle(fontWeight: FontWeight.w700),
                  ),
                  const SizedBox(height: 8),
                  Wrap(
                    spacing: 8,
                    runSpacing: 8,
                    children: _credits
                        .map(
                          (credit) => ActionChip(
                            label: Text(credit.name),
                            onPressed: () => unawaited(_open(credit.url)),
                          ),
                        )
                        .toList(growable: false),
                  ),
                ],
              ),
            ),
          ),
        ],
      ),
    );
  }
}

class _InfoRow extends StatelessWidget {
  const _InfoRow({
    required this.icon,
    required this.title,
    required this.subtitle,
    this.onTap,
    this.onLongPress,
  });

  final IconData icon;
  final String title;
  final String subtitle;
  final VoidCallback? onTap;
  final VoidCallback? onLongPress;

  @override
  Widget build(BuildContext context) => ListTile(
    contentPadding: EdgeInsets.zero,
    leading: Icon(icon),
    title: Text(title, style: const TextStyle(fontWeight: FontWeight.w700)),
    subtitle: Text(subtitle),
    trailing: onTap == null
        ? null
        : const Icon(Icons.chevron_right_rounded, size: 20),
    onTap: onTap,
    onLongPress: onLongPress,
  );
}

class _HeartEasterEggDialog extends StatefulWidget {
  const _HeartEasterEggDialog();

  @override
  State<_HeartEasterEggDialog> createState() => _HeartEasterEggDialogState();
}

class _HeartEasterEggDialogState extends State<_HeartEasterEggDialog>
    with SingleTickerProviderStateMixin {
  late final AnimationController _controller = AnimationController(
    vsync: this,
    duration: const Duration(seconds: 3),
  )..repeat();

  @override
  void dispose() {
    _controller.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final ColorScheme colors = Theme.of(context).colorScheme;
    return Dialog(
      key: const Key('heart-easter-egg-dialog'),
      child: Padding(
        padding: const EdgeInsets.fromLTRB(20, 28, 20, 18),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: <Widget>[
            SizedBox(
              height: 120,
              child: Stack(
                alignment: Alignment.center,
                children: <Widget>[
                  for (int index = 0; index < 6; index++)
                    AnimatedBuilder(
                      animation: _controller,
                      builder: (BuildContext context, Widget? child) {
                        final double progress =
                            (_controller.value + index / 6) % 1.0;
                        return Transform.translate(
                          offset: Offset(
                            (index % 3 - 1) * 34.0,
                            -progress * 96 + 24,
                          ),
                          child: Opacity(
                            opacity: (1 - progress).clamp(0.0, 1.0),
                            child: const Icon(
                              Icons.favorite_rounded,
                              color: Color(0xFFE5484D),
                              size: 24,
                            ),
                          ),
                        );
                      },
                    ),
                  const Icon(
                    Icons.favorite_rounded,
                    color: Color(0xFFE5484D),
                    size: 56,
                  ),
                ],
              ),
            ),
            const SizedBox(height: 8),
            const Text(
              '感谢你的陪伴',
              style: TextStyle(fontSize: 18, fontWeight: FontWeight.w800),
            ),
            const SizedBox(height: 4),
            Text(
              'PackingProof ♥ 包裹留证',
              style: TextStyle(color: colors.onSurfaceVariant, fontSize: 13),
            ),
            const SizedBox(height: 14),
            FilledButton(
              key: const Key('heart-easter-egg-close'),
              onPressed: () => Navigator.of(context).pop(),
              child: const Text('关闭'),
            ),
          ],
        ),
      ),
    );
  }
}

class _LinkRow extends _InfoRow {
  const _LinkRow({
    required super.icon,
    required super.title,
    required super.subtitle,
    required super.onTap,
  });

  @override
  Widget build(BuildContext context) => ListTile(
    contentPadding: EdgeInsets.zero,
    leading: Icon(icon),
    title: Text(title, style: const TextStyle(fontWeight: FontWeight.w700)),
    subtitle: Text(subtitle, maxLines: 2, overflow: TextOverflow.ellipsis),
    trailing: const Icon(Icons.open_in_new_rounded, size: 20),
    onTap: onTap,
  );
}
