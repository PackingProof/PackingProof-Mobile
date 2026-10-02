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
      CameraCapabilityPolicy.evaluateSequence('alternating', phases, fps: 30),
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
      CameraCapabilityPolicy.decide(<String, List<CameraProbePhase>>{
        'full': _fullSequence(),
      }, fps: 30).mode,
      CameraCapabilityMode.full,
    );
    expect(
      CameraCapabilityPolicy.decide(<String, List<CameraProbePhase>>{
        'full': _fullSequence(recordOutcome: 'configure_failed'),
        'encoder_analysis': <CameraProbePhase>[
          _phase('idle'),
          _phase('record', preview: 0, analysis: 30, encoder: 30),
          _phase('idle'),
          _phase('record', preview: 0, analysis: 30, encoder: 30),
          _phase('idle'),
        ],
      }, fps: 30).mode,
      CameraCapabilityMode.encoderAnalysis,
    );
    expect(
      CameraCapabilityPolicy.decide(<String, List<CameraProbePhase>>{
        'full': _fullSequence(recordOutcome: 'configure_failed'),
        'encoder_analysis': _fullSequence(recordOutcome: 'configure_failed'),
        'alternating': _fullSequence(recordOutcome: 'configure_failed'),
      }, fps: 30).mode,
      CameraCapabilityMode.unsupported,
    );
    final CameraCapabilityDecision infraDecision =
        CameraCapabilityPolicy.decide(<String, List<CameraProbePhase>>{
          'full': <CameraProbePhase>[
            _phase('idle'),
            _phase('record', outcome: 'configure_timeout'),
            _phase('idle'),
            _phase('record'),
            _phase('idle'),
          ],
        }, fps: 30);
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

  group('摄像头工作模式偏好', () {
    test('存取值与能力模式一一对应', () {
      expect(CameraCapabilityPreference.full.storageValue, 'full');
      expect(
        CameraCapabilityPreference.encoderAnalysis.storageValue,
        'encoder_analysis',
      );
      expect(
        CameraCapabilityPreference.alternating.storageValue,
        'alternating',
      );

      expect(
        CameraCapabilityPreference.full.lockedMode,
        CameraCapabilityMode.full,
      );
      expect(
        CameraCapabilityPreference.encoderAnalysis.lockedMode,
        CameraCapabilityMode.encoderAnalysis,
      );
      expect(
        CameraCapabilityPreference.alternating.lockedMode,
        CameraCapabilityMode.alternating,
      );
    });

    test('手动模式的文案与能力模式一致，且不以句号结尾', () {
      for (final CameraCapabilityPreference preference
          in CameraCapabilityPreference.values) {
        expect(preference.label, isNotEmpty);
        expect(preference.description, isNotEmpty);
        expect(preference.description.endsWith('。'), isFalse);
      }
      expect(
        CameraCapabilityPreference.alternating.label,
        CameraCapabilityMode.alternating.label,
      );
      expect(
        CameraCapabilityPreference.encoderAnalysis.description,
        CameraCapabilityMode.encoderAnalysis.description,
      );
      // 文案面向小白：直接写“同时能做什么”
      expect(CameraCapabilityPreference.full.label, '扫码预览');
      expect(CameraCapabilityPreference.encoderAnalysis.label, '仅扫码');
      expect(CameraCapabilityPreference.alternating.label, '仅预览');
      // 默认就是「扫码预览」，不再提供会记住历史降级的「自动」选项
      expect(CameraCapabilityPreference.values.first, CameraCapabilityPreference.full);
      // 录制是必然发生的，标签里不再重复写“录像”，只说清预览和扫码能不能用
      for (final CameraCapabilityPreference preference
          in CameraCapabilityPreference.values) {
        expect(
          preference.label,
          isNot(contains('录像')),
          reason: preference.label,
        );
      }
    });

    test('能力文案不出现三路、两路这类黑话', () {
      final List<String> texts = <String>[
        for (final CameraCapabilityMode mode
            in CameraCapabilityMode.values) ...<String>[
          mode.label,
          mode.description,
        ],
        for (final CameraCapabilityPreference preference
            in CameraCapabilityPreference.values) ...<String>[
          preference.label,
          preference.description,
        ],
      ];
      for (final String text in texts) {
        expect(text, isNot(contains('三路')), reason: text);
        expect(text, isNot(contains('两路')), reason: text);
      }
    });
  });
}
