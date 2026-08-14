import 'dart:math' as math;

/// 摄像头工作能力模式。与 Kotlin 的 CameraCapabilityMode 保持一一对应。
enum CameraCapabilityMode {
  full,
  encoderAnalysis,
  alternating,
  unsupported,
  unverified;

  String get wireValue => switch (this) {
    CameraCapabilityMode.full => 'full',
    CameraCapabilityMode.encoderAnalysis => 'encoder_analysis',
    CameraCapabilityMode.alternating => 'alternating',
    CameraCapabilityMode.unsupported => 'unsupported',
    CameraCapabilityMode.unverified => 'unverified',
  };

  String get label => switch (this) {
    CameraCapabilityMode.full => '完整模式',
    CameraCapabilityMode.encoderAnalysis => '兼容两路',
    CameraCapabilityMode.alternating => '扫码录像轮换',
    CameraCapabilityMode.unsupported => '不支持',
    CameraCapabilityMode.unverified => '未完成检测',
  };

  String get description => switch (this) {
    CameraCapabilityMode.full => '预览、识别与录像同时进行',
    CameraCapabilityMode.encoderAnalysis => '录像时预览画面暂停，识别与录像继续工作',
    CameraCapabilityMode.alternating => '录像时暂停识别，录完一单后点击“完成本单”恢复扫码',
    CameraCapabilityMode.unsupported => '此设备无法同时预览与识别，暂时无法工作',
    CameraCapabilityMode.unverified => '设备能力尚未确定，先按常规模式工作，可到设置中重新检测',
  };

  static CameraCapabilityMode fromWire(Object? value) {
    final String normalized = '$value'.trim().toLowerCase();
    for (final CameraCapabilityMode mode in CameraCapabilityMode.values) {
      if (mode.wireValue == normalized) return mode;
    }
    return CameraCapabilityMode.unverified;
  }
}

/// 单个探针阶段的原始结果（原生上报，不含阈值判断）。
class CameraProbePhase {
  const CameraProbePhase({
    required this.phase,
    required this.outcome,
    this.candidate,
    this.detail,
    this.previewFrames = 0,
    this.analysisFrames = 0,
    this.encoderBuffers = 0,
    this.durationMs = 0,
  });

  final String phase;
  final String? candidate;
  final String outcome;
  final String? detail;
  final int previewFrames;
  final int analysisFrames;
  final int encoderBuffers;
  final int durationMs;

  factory CameraProbePhase.fromMap(Map<Object?, Object?> map) {
    return CameraProbePhase(
      phase: '${map['phase'] ?? ''}',
      candidate: map['candidate'] as String?,
      outcome: '${map['outcome'] ?? 'internal_error'}',
      detail: map['detail'] as String?,
      previewFrames: (map['previewFrames'] as num?)?.toInt() ?? 0,
      analysisFrames: (map['analysisFrames'] as num?)?.toInt() ?? 0,
      encoderBuffers: (map['encoderBuffers'] as num?)?.toInt() ?? 0,
      durationMs: (map['durationMs'] as num?)?.toInt() ?? 0,
    );
  }
}

enum CameraProbePhaseStatus { passed, failedCapability, errorInfra }

enum CameraSequenceVerdict { passed, failedCapability, errorInfra }

/// 轮换模式「完成本单」后的同码抑制判断。
///
/// 同一面单持续停留在画面中时不自动重录；连续 ≥2 秒无有效码
/// （镜头移开）后，重新对准同一码可以再次录制。
bool shouldSuppressAlternatingSameCode({
  required String lastCompletedCode,
  required DateTime? noCodeSince,
  required String code,
  required DateTime now,
}) {
  if (lastCompletedCode.isEmpty || code != lastCompletedCode) return false;
  if (noCodeSince == null) return true;
  return now.difference(noCodeSince) < const Duration(seconds: 2);
}

/// 完整探测后的最终决策。
class CameraCapabilityDecision {
  const CameraCapabilityDecision(this.mode, {this.infraReason});

  const CameraCapabilityDecision.unverified(String reason)
    : this(CameraCapabilityMode.unverified, infraReason: reason);

  final CameraCapabilityMode mode;
  final String? infraReason;
}

/// 纯 Dart 的能力策略：阶段三态分类、按 fps 推导的持续出帧阈值、
/// 每个模式必须通过的阶段集合与模式顺序。
class CameraCapabilityPolicy {
  CameraCapabilityPolicy._();

  static const List<String> sequenceOrder = <String>[
    'full',
    'encoder_analysis',
    'alternating',
  ];

  /// 与 Kotlin 侧保持一致：探测算法变化时递增，旧缓存即失效。
  static const int probeSchemaVersion = 1;

  /// 相机管线变化（会话选择/编码器策略）时递增，App 版本本身不触发重测。
  static const int cameraPipelineVersion = 1;

  static const double phaseWindowSeconds = 1.2;
  static const int minPreviewFrames = 3;
  static const int minAnalysisFrames = 2;
  static const int minEncoderBuffers = 3;
  static const double previewFrameRatio = 0.4;
  static const double encoderBufferRatio = 0.2;

  static int previewFrameThreshold(int fps) => math.max(
    minPreviewFrames,
    (fps * previewFrameRatio * phaseWindowSeconds).ceil(),
  );

  static int encoderBufferThreshold(int fps) => math.max(
    minEncoderBuffers,
    (fps * encoderBufferRatio * phaseWindowSeconds).ceil(),
  );

  /// 序列必须包含 idle → record → idle → record → idle 五个阶段，
  /// 且每个阶段都通过相应阈值。
  static CameraSequenceVerdict evaluateSequence(
    String sequence,
    List<CameraProbePhase> phases, {
    required int fps,
  }) {
    if (sequence == 'full' ||
        sequence == 'encoder_analysis' ||
        sequence == 'alternating') {
      // 有效序列继续判断
    } else {
      return CameraSequenceVerdict.failedCapability;
    }
    if (phases.length != 5) {
      return CameraSequenceVerdict.failedCapability;
    }
    for (int index = 0; index < phases.length; index++) {
      final CameraProbePhase phase = phases[index];
      final bool isIdle = phase.phase == 'idle';
      if (index.isEven != isIdle) {
        return CameraSequenceVerdict.failedCapability;
      }
      final CameraProbePhaseStatus status = _evaluatePhase(
        sequence,
        phase,
        isIdle,
        fps,
      );
      if (status == CameraProbePhaseStatus.errorInfra) {
        return CameraSequenceVerdict.errorInfra;
      }
      if (status != CameraProbePhaseStatus.passed) {
        return CameraSequenceVerdict.failedCapability;
      }
    }
    return CameraSequenceVerdict.passed;
  }

  static CameraProbePhaseStatus _evaluatePhase(
    String sequence,
    CameraProbePhase phase,
    bool isIdle,
    int fps,
  ) {
    switch (phase.outcome) {
      case 'configured':
        break;
      case 'configure_failed':
      case 'unsupported_combination':
      case 'codec_missing':
      case 'codec_config_failed':
        return CameraProbePhaseStatus.failedCapability;
      default:
        return CameraProbePhaseStatus.errorInfra;
    }
    final int previewNeeded = previewFrameThreshold(fps);
    final int encoderNeeded = encoderBufferThreshold(fps);
    final bool passes;
    if (isIdle) {
      passes = phase.previewFrames >= previewNeeded &&
          phase.analysisFrames >= minAnalysisFrames;
    } else {
      passes = switch (sequence) {
        'full' => phase.previewFrames >= previewNeeded &&
            phase.analysisFrames >= minAnalysisFrames &&
            phase.encoderBuffers >= encoderNeeded,
        'encoder_analysis' => phase.analysisFrames >= minAnalysisFrames &&
            phase.encoderBuffers >= encoderNeeded,
        _ => phase.previewFrames >= previewNeeded &&
            phase.encoderBuffers >= encoderNeeded,
      };
    }
    return passes
        ? CameraProbePhaseStatus.passed
        : CameraProbePhaseStatus.failedCapability;
  }

  static CameraCapabilityDecision decide(
    Map<String, List<CameraProbePhase>> results, {
    required int fps,
  }) {
    for (final String sequence in sequenceOrder) {
      final List<CameraProbePhase> phases = results[sequence] ?? const [];
      final CameraSequenceVerdict verdict = evaluateSequence(
        sequence,
        phases,
        fps: fps,
      );
      switch (verdict) {
        case CameraSequenceVerdict.passed:
          return CameraCapabilityDecision(_modeForSequence(sequence));
        case CameraSequenceVerdict.errorInfra:
          return const CameraCapabilityDecision.unverified(
            '探针阶段发生异常',
          );
        case CameraSequenceVerdict.failedCapability:
          continue;
      }
    }
    return const CameraCapabilityDecision(CameraCapabilityMode.unsupported);
  }

  static CameraCapabilityMode _modeForSequence(String sequence) =>
      switch (sequence) {
        'full' => CameraCapabilityMode.full,
        'encoder_analysis' => CameraCapabilityMode.encoderAnalysis,
        'alternating' => CameraCapabilityMode.alternating,
        _ => CameraCapabilityMode.unsupported,
      };
}
