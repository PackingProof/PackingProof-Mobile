import 'package:flutter_test/flutter_test.dart';
import 'package:packing_proof_mobile/services/camera_capability_policy.dart';

CameraProbePhase _phase(
  String phase, {
  String outcome = 'configured',
  int preview = 100,
  int analysis = 100,
  int encoder = 100,
}) {
  return CameraProbePhase(
    phase: phase,
    outcome: outcome,
    previewFrames: preview,
    analysisFrames: analysis,
    encoderBuffers: encoder,
  );
}

List<CameraProbePhase> _fullSequence({
  String recordOutcome = 'configured',
  int recordPreview = 100,
  int recordAnalysis = 100,
  int recordEncoder = 100,
}) {
  return <CameraProbePhase>[
    _phase('idle'),
    _phase(
      'record',
      outcome: recordOutcome,
      preview: recordPreview,
      analysis: recordAnalysis,
      encoder: recordEncoder,
    ),
    _phase('idle'),
    _phase(
      'record',
      outcome: recordOutcome,
      preview: recordPreview,
      analysis: recordAnalysis,
      encoder: recordEncoder,
    ),
    _phase('idle'),
  ];
}

void main() {
  test('阈值按帧率比例推导且不低于绝对值下限', () {
    expect(CameraCapabilityPolicy.previewFrameThreshold(30), 15);
    expect(CameraCapabilityPolicy.previewFrameThreshold(5), 3);
    expect(CameraCapabilityPolicy.encoderBufferThreshold(30), 8);
    expect(CameraCapabilityPolicy.encoderBufferThreshold(5), 3);
  });

  test('FULL 序列五阶段全部通过才判定可用', () {
    expect(
      CameraCapabilityPolicy.evaluateSequence('full', _fullSequence(), fps: 30),
      CameraSequenceVerdict.passed,
    );
    final List<CameraProbePhase> short = _fullSequence().sublist(0, 3);
    expect(
      CameraCapabilityPolicy.evaluateSequence('full', short, fps: 30),
      CameraSequenceVerdict.failedCapability,
    );
  });

  test('配置成功但持续出帧不足视为能力失败', () {
    final List<CameraProbePhase> phases = _fullSequence(recordPreview: 2);
    expect(
      CameraCapabilityPolicy.evaluateSequence('full', phases, fps: 30),
      CameraSequenceVerdict.failedCapability,
    );
  });

  test('alternating 录像阶段不要求识别帧，但要求预览与编码输出', () {
    final List<CameraProbePhase> phases = <CameraProbePhase>[
      _phase('idle'),
      _phase('record', preview: 30, analysis: 0, encoder: 30),
      _phase('idle'),
      _phase('record', preview: 30, analysis: 0, encoder: 30),
      _phase('idle'),
    ];
    expect(
      CameraCapabilityPolicy.evaluateSequence(
        'alternating',
        phases,
        fps: 30,
      ),
      CameraSequenceVerdict.passed,
    );
  });

  test('encoder_analysis 录像阶段不要求预览帧', () {
    final List<CameraProbePhase> phases = <CameraProbePhase>[
      _phase('idle'),
      _phase('record', preview: 0, analysis: 30, encoder: 30),
      _phase('idle'),
      _phase('record', preview: 0, analysis: 30, encoder: 30),
      _phase('idle'),
    ];
    expect(
      CameraCapabilityPolicy.evaluateSequence(
        'encoder_analysis',
        phases,
        fps: 30,
      ),
      CameraSequenceVerdict.passed,
    );
  });

  test('configure_failed 归为能力失败，其余异常归为探针错误', () {
    final List<CameraProbePhase> capabilityFailure = <CameraProbePhase>[
      _phase('idle'),
      _phase('record', outcome: 'configure_failed'),
      _phase('idle'),
      _phase('record', outcome: 'configure_failed'),
      _phase('idle'),
    ];
    expect(
      CameraCapabilityPolicy.evaluateSequence(
        'full',
        capabilityFailure,
        fps: 30,
      ),
      CameraSequenceVerdict.failedCapability,
    );
    final List<CameraProbePhase> infraFailure = <CameraProbePhase>[
      _phase('idle'),
      _phase('record', outcome: 'camera_access_error'),
      _phase('idle'),
      _phase('record'),
      _phase('idle'),
    ];
    expect(
      CameraCapabilityPolicy.evaluateSequence('full', infraFailure, fps: 30),
      CameraSequenceVerdict.errorInfra,
    );
  });

  test('按顺序短路并区分 UNSUPPORTED 与 UNVERIFIED', () {
    expect(
      CameraCapabilityPolicy.decide(
        <String, List<CameraProbePhase>>{'full': _fullSequence()},
        fps: 30,
      ).mode,
      CameraCapabilityMode.full,
    );
    expect(
      CameraCapabilityPolicy.decide(
        <String, List<CameraProbePhase>>{
          'full': _fullSequence(recordOutcome: 'configure_failed'),
          'encoder_analysis': <CameraProbePhase>[
            _phase('idle'),
            _phase('record', preview: 0, analysis: 30, encoder: 30),
            _phase('idle'),
            _phase('record', preview: 0, analysis: 30, encoder: 30),
            _phase('idle'),
          ],
        },
        fps: 30,
      ).mode,
      CameraCapabilityMode.encoderAnalysis,
    );
    expect(
      CameraCapabilityPolicy.decide(
        <String, List<CameraProbePhase>>{
          'full': _fullSequence(recordOutcome: 'configure_failed'),
          'encoder_analysis': _fullSequence(recordOutcome: 'configure_failed'),
          'alternating': _fullSequence(recordOutcome: 'configure_failed'),
        },
        fps: 30,
      ).mode,
      CameraCapabilityMode.unsupported,
    );
    final CameraCapabilityDecision infraDecision = CameraCapabilityPolicy.decide(
      <String, List<CameraProbePhase>>{
        'full': <CameraProbePhase>[
          _phase('idle'),
          _phase('record', outcome: 'configure_timeout'),
          _phase('idle'),
          _phase('record'),
          _phase('idle'),
        ],
      },
      fps: 30,
    );
    expect(infraDecision.mode, CameraCapabilityMode.unverified);
    expect(infraDecision.infraReason, isNotNull);
  });

  test('wireValue 与模式解析往返一致', () {
    for (final CameraCapabilityMode mode in CameraCapabilityMode.values) {
      expect(CameraCapabilityMode.fromWire(mode.wireValue), mode);
    }
  });

  test('轮换同码抑制：持续可见时抑制，移开两秒后放行', () {
    final DateTime now = DateTime(2026, 8, 15, 12, 0, 0);
    expect(
      shouldSuppressAlternatingSameCode(
        lastCompletedCode: 'YT123456789012',
        noCodeSince: null,
        code: 'YT123456789012',
        now: now,
      ),
      isTrue,
    );
    expect(
      shouldSuppressAlternatingSameCode(
        lastCompletedCode: 'YT123456789012',
        noCodeSince: now.subtract(const Duration(seconds: 1)),
        code: 'YT123456789012',
        now: now,
      ),
      isTrue,
    );
    expect(
      shouldSuppressAlternatingSameCode(
        lastCompletedCode: 'YT123456789012',
        noCodeSince: now.subtract(const Duration(seconds: 2)),
        code: 'YT123456789012',
        now: now,
      ),
      isFalse,
    );
    expect(
      shouldSuppressAlternatingSameCode(
        lastCompletedCode: 'YT123456789012',
        noCodeSince: null,
        code: 'SF987654321098',
        now: now,
      ),
      isFalse,
    );
  });
}
