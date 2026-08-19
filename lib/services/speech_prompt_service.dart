import 'dart:async';
import 'dart:collection';
import 'dart:math' as math;

import 'package:audioplayers/audioplayers.dart';
import 'package:flutter/foundation.dart';
import 'package:flutter_tts/flutter_tts.dart';

import '../models/speech_prompt.dart';

bool _isModeAnnouncement(SpeechPrompt? prompt) =>
    prompt == SpeechPrompt.shippingMode || prompt == SpeechPrompt.returnMode;

abstract interface class SpeechPromptSink {
  bool get enabled;

  Future<void> setEnabled(bool value);

  void enqueue(SpeechPrompt prompt, {String? incidentKey});

  Future<void> preview();

  void playShortBeep();

  void resetIncidents();

  void resolveIncident(String incidentKey);

  Future<void> clear();

  Future<void> dispose();
}

abstract interface class DynamicSpeechPromptSink {
  void enqueueText(
    String text, {
    SpeechPromptPriority priority = SpeechPromptPriority.normal,
    String? incidentKey,
    bool playRemarkTone = false,
    bool playWarningTone = false,
    bool playIndustrialAlarm = false,
  });
}

class _QueuedSpeechPrompt {
  _QueuedSpeechPrompt.fixed(SpeechPrompt value)
    : prompt = value,
      text = value.text,
      priority = value.priority,
      playRemarkTone = value.cue == SpeechPromptCue.remark,
      playWarningTone = value.cue == SpeechPromptCue.warning,
      playIndustrialAlarm = value.cue == SpeechPromptCue.industrial;

  _QueuedSpeechPrompt.dynamic({
    required this.text,
    required this.priority,
    required this.playRemarkTone,
    required this.playWarningTone,
    required this.playIndustrialAlarm,
  }) : prompt = null;

  final SpeechPrompt? prompt;
  final String text;
  final SpeechPromptPriority priority;
  final bool playRemarkTone;
  final bool playWarningTone;
  final bool playIndustrialAlarm;
}

abstract interface class SpeechOutput {
  Future<void> playAsset(String assetPath);

  Future<void> playRemarkTone();

  Future<void> playWarningTone();

  Future<void> playIndustrialAlarm();

  Future<void> playShortBeep();

  Future<void> speakSystem(String text, {bool offlineOnly = false});

  Future<void> stop();

  Future<void> dispose();
}

class SpeechPromptService implements SpeechPromptSink, DynamicSpeechPromptSink {
  SpeechPromptService({SpeechOutput? output})
    : _output = output ?? DeviceSpeechOutput();

  final SpeechOutput _output;
  final ListQueue<_QueuedSpeechPrompt> _queue =
      ListQueue<_QueuedSpeechPrompt>();
  final Set<String> _activeIncidents = <String>{};

  bool _enabled = true;
  bool _draining = false;
  bool _disposed = false;
  _QueuedSpeechPrompt? _activePrompt;
  int _generation = 0;
  Future<void>? _clearing;

  @override
  bool get enabled => _enabled;

  @override
  Future<void> setEnabled(bool value) async {
    if (_disposed || _enabled == value) {
      return;
    }
    _enabled = value;
    if (!value) {
      _queue.clear();
      _activeIncidents.clear();
      await _output.stop();
    }
  }

  @override
  void enqueue(SpeechPrompt prompt, {String? incidentKey}) {
    if (_disposed || !_enabled) {
      return;
    }
    if (prompt.priority == SpeechPromptPriority.warning) {
      final String key = incidentKey ?? prompt.name;
      if (!_activeIncidents.add(key)) {
        return;
      }
      _queue.removeWhere(
        (_QueuedSpeechPrompt queued) =>
            queued.priority == SpeechPromptPriority.normal,
      );
      unawaited(_output.stop());
    } else if (prompt == SpeechPrompt.recordingStarted) {
      _queue.removeWhere(
        (_QueuedSpeechPrompt queued) => _isModeAnnouncement(queued.prompt),
      );
      if (_isModeAnnouncement(_activePrompt?.prompt)) {
        unawaited(_output.stop());
      }
    } else if (prompt == SpeechPrompt.recordingStopped) {
      _queue.removeWhere(
        (_QueuedSpeechPrompt queued) =>
            _isModeAnnouncement(queued.prompt) ||
            queued.prompt == SpeechPrompt.recordingStarted,
      );
      if (_isModeAnnouncement(_activePrompt?.prompt) ||
          _activePrompt?.prompt == SpeechPrompt.recordingStarted) {
        unawaited(_output.stop());
      }
    }
    _queue.add(_QueuedSpeechPrompt.fixed(prompt));
    unawaited(_drain());
  }

  @override
  void enqueueText(
    String text, {
    SpeechPromptPriority priority = SpeechPromptPriority.normal,
    String? incidentKey,
    bool playRemarkTone = false,
    bool playWarningTone = false,
    bool playIndustrialAlarm = false,
  }) {
    final String normalized = text.trim();
    if (_disposed || !_enabled || normalized.isEmpty) return;
    if (priority == SpeechPromptPriority.warning) {
      final String key = incidentKey ?? 'dynamic:$normalized';
      if (!_activeIncidents.add(key)) return;
      _queue.removeWhere(
        (_QueuedSpeechPrompt queued) =>
            queued.priority == SpeechPromptPriority.normal,
      );
      unawaited(_output.stop());
    }
    _queue.add(
      _QueuedSpeechPrompt.dynamic(
        text: normalized,
        priority: priority,
        playRemarkTone: playRemarkTone,
        playWarningTone: playWarningTone,
        playIndustrialAlarm: playIndustrialAlarm,
      ),
    );
    unawaited(_drain());
  }

  @override
  Future<void> preview() async {
    if (_disposed || !_enabled) {
      return;
    }
    await _output.stop();
    _queue.addFirst(_QueuedSpeechPrompt.fixed(SpeechPrompt.previewEnabled));
    unawaited(_drain());
    await waitUntilIdle();
  }

  @override
  void playShortBeep() {
    if (_disposed || !_enabled) {
      return;
    }
    unawaited(_output.playShortBeep());
  }

  Future<void> waitUntilIdle() async {
    while (_draining || _queue.isNotEmpty) {
      await Future<void>.delayed(const Duration(milliseconds: 1));
    }
  }

  @override
  void resetIncidents() => _activeIncidents.clear();

  @override
  void resolveIncident(String incidentKey) {
    _activeIncidents.remove(incidentKey);
  }

  @override
  Future<void> clear() {
    if (_disposed) {
      return Future<void>.value();
    }
    final Future<void>? clearing = _clearing;
    if (clearing != null) {
      return clearing;
    }
    final Future<void> future = _clearImpl();
    _clearing = future;
    return future.whenComplete(() {
      if (identical(_clearing, future)) {
        _clearing = null;
      }
    });
  }

  Future<void> _clearImpl() async {
    _generation++;
    _queue.clear();
    _activePrompt = null;
    _activeIncidents.clear();
    await _stopOutputBounded();
  }

  Future<void> _stopOutputBounded() async {
    try {
      await _output.stop().timeout(const Duration(seconds: 2));
    } on Object {
      // Best-effort stop; a hung player must not block the speech workflow.
    }
  }

  Future<void> _drain() async {
    if (_draining || _disposed || !_enabled) {
      return;
    }
    _draining = true;
    final int generation = _generation;
    try {
      while (generation == _generation &&
          _queue.isNotEmpty &&
          !_disposed &&
          _enabled) {
        final _QueuedSpeechPrompt prompt = _queue.removeFirst();
        _activePrompt = prompt;
        try {
          await _playWithFallback(prompt);
        } finally {
          if (_activePrompt == prompt) _activePrompt = null;
        }
      }
    } finally {
      _draining = false;
      if (_queue.isNotEmpty && !_disposed && _enabled) {
        unawaited(_drain());
      }
    }
  }

  Future<void> _playWithFallback(_QueuedSpeechPrompt item) async {
    if (item.playRemarkTone) {
      try {
        await _output.playRemarkTone();
      } on Object {
        // The short cue is optional; speech should still continue.
      }
    }
    if (item.playWarningTone) {
      try {
        await _output.playWarningTone();
      } on Object {
        // The warning cue is optional; speech should still continue.
      }
    }
    if (item.playIndustrialAlarm) {
      try {
        await _output.playIndustrialAlarm();
      } on Object {
        // The industrial alarm is optional; speech should still continue.
      }
    }
    final SpeechPrompt? prompt = item.prompt;
    bool assetFailed = false;
    if (prompt != null) {
      try {
        await _output.playAsset(prompt.audioPlayerAssetPath);
        return;
      } on TimeoutException {
        debugPrint('[speech_prompt] asset_play_timeout: ${prompt.name}');
        assetFailed = true;
      } on Object catch (error) {
        debugPrint(
          '[speech_prompt] asset_play_exception: ${prompt.name}: $error',
        );
        // A missing or damaged bundled prompt falls back to offline system TTS.
        assetFailed = true;
      }
    }
    if (assetFailed) {
      debugPrint('[speech_prompt] tts_fallback: ${item.text}');
    }
    try {
      await _output.speakSystem(item.text, offlineOnly: true);
    } on Object {
      // Speech must never interrupt or fail the recording workflow.
    }
  }

  @override
  Future<void> dispose() async {
    if (_disposed) {
      return;
    }
    _disposed = true;
    _queue.clear();
    _activeIncidents.clear();
    await _output.stop();
    await _output.dispose();
  }
}

class DeviceSpeechOutput implements SpeechOutput {
  static const Duration _sourceStartTimeout = Duration(seconds: 3);

  DeviceSpeechOutput({AudioPlayer? audioPlayer, FlutterTts? systemTts})
    : _audioPlayer = audioPlayer ?? AudioPlayer(),
      _systemTts = systemTts ?? FlutterTts() {
    _systemTts.setCompletionHandler(_completePlayback);
    _systemTts.setCancelHandler(_completePlayback);
    _systemTts.setErrorHandler((_) => _completePlayback());
  }

  final AudioPlayer _audioPlayer;
  final FlutterTts _systemTts;
  AudioPlayer? _beepPlayer;
  Future<void>? _beepInFlight;
  Uint8List? _shortBeepWav;
  Completer<void>? _activePlayback;
  bool _audioContextConfigured = false;
  bool _beepContextConfigured = false;

  /// 录像期间播放提示音时，iOS 也必须保留录音能力。
  ///
  /// `audioplayers` 在 iOS 使用全局 `AVAudioSession`，默认上下文会把
  /// category 设为 `.playback`，从而可能让后续录像分段没有麦克风输入。
  static AudioContext buildSpeechAudioContext(AudioContextAndroid android) {
    return AudioContext(
      android: android,
      iOS: AudioContextIOS(
        category: AVAudioSessionCategory.playAndRecord,
        options: const {AVAudioSessionOptions.defaultToSpeaker},
      ),
    );
  }

  @visibleForTesting
  static BytesSource buildWavBytesSource(Uint8List bytes) =>
      BytesSource(bytes, mimeType: 'audio/wav');

  @visibleForTesting
  static AssetSource buildSpeechAssetSource(String assetPath) =>
      AssetSource(assetPath, mimeType: 'audio/mpeg');

  @override
  Future<void> playAsset(String assetPath) =>
      _play(buildSpeechAssetSource(assetPath));

  @override
  Future<void> playRemarkTone() => _play(buildWavBytesSource(_remarkToneWav()));

  @override
  Future<void> playWarningTone() =>
      _play(buildWavBytesSource(_warningToneWav()));

  @override
  Future<void> playIndustrialAlarm() =>
      _play(buildWavBytesSource(_industrialAlarmWav()));

  @override
  Future<void> playShortBeep() {
    if (_beepInFlight != null) {
      return Future<void>.value();
    }
    final Future<void> future = _playBeepOnce();
    _beepInFlight = future;
    return future.whenComplete(() {
      if (identical(_beepInFlight, future)) {
        _beepInFlight = null;
      }
    });
  }

  Future<void> _playBeepOnce() async {
    final AudioPlayer player = _beepPlayer ??= AudioPlayer();
    try {
      if (!_beepContextConfigured) {
        debugPrint('[speech_prompt] beep_set_audio_context');
        await player
            .setAudioContext(
              buildSpeechAudioContext(
                const AudioContextAndroid(
                  contentType: AndroidContentType.sonification,
                  usageType: AndroidUsageType.media,
                  audioFocus: AndroidAudioFocus.none,
                ),
              ),
            )
            .timeout(const Duration(seconds: 2));
        _beepContextConfigured = true;
      }
      debugPrint('[speech_prompt] beep_play');
      await player
          .play(buildWavBytesSource(_shortBeepWav ??= buildShortBeepWav()))
          .timeout(const Duration(seconds: 3));
    } on Object catch (error) {
      debugPrint('[speech_prompt] beep_failed: $error');
      await _resetBeepPlayer();
    }
  }

  Future<void> _resetBeepPlayer() async {
    final AudioPlayer? player = _beepPlayer;
    _beepPlayer = null;
    _beepContextConfigured = false;
    if (player == null) {
      return;
    }
    try {
      await player.stop().timeout(const Duration(seconds: 2));
    } on Object {
      // Best-effort stop.
    }
    try {
      await player.dispose().timeout(const Duration(seconds: 2));
    } on Object {
      // Best-effort dispose.
    }
  }

  /// 与电脑端一致的识别短滴声：1200Hz、80ms、0.55 音量单音。
  static Uint8List buildShortBeepWav() {
    const int sampleRate = 22050;
    const int toneMs = 80;
    const double volume = 0.55;
    const int frequency = 1200;
    final int toneSamples = sampleRate * toneMs ~/ 1000;
    final int sampleCount = toneSamples;
    final ByteData wav = ByteData(44 + sampleCount * 2);
    void ascii(int offset, String value) {
      for (int index = 0; index < value.length; index++) {
        wav.setUint8(offset + index, value.codeUnitAt(index));
      }
    }

    ascii(0, 'RIFF');
    wav.setUint32(4, 36 + sampleCount * 2, Endian.little);
    ascii(8, 'WAVE');
    ascii(12, 'fmt ');
    wav.setUint32(16, 16, Endian.little);
    wav.setUint16(20, 1, Endian.little);
    wav.setUint16(22, 1, Endian.little);
    wav.setUint32(24, sampleRate, Endian.little);
    wav.setUint32(28, sampleRate * 2, Endian.little);
    wav.setUint16(32, 2, Endian.little);
    wav.setUint16(34, 16, Endian.little);
    ascii(36, 'data');
    wav.setUint32(40, sampleCount * 2, Endian.little);
    for (int index = 0; index < toneSamples; index++) {
      final int edge = math.max(1, toneSamples ~/ 10);
      final double envelope = index < edge
          ? index / edge
          : index >= toneSamples - edge
          ? (toneSamples - index - 1) / edge
          : 1;
      final double value =
          math.sin(2 * math.pi * frequency * index / sampleRate) *
          volume *
          envelope;
      wav.setInt16(44 + index * 2, (value * 32767).round(), Endian.little);
    }
    return wav.buffer.asUint8List();
  }

  static Uint8List _remarkToneWav() {
    const int sampleRate = 22050;
    const int toneMs = 120;
    const int gapMs = 45;
    const double volume = 0.50;
    const List<int> tones = <int>[660, 880];
    final int toneSamples = sampleRate * toneMs ~/ 1000;
    final int gapSamples = sampleRate * gapMs ~/ 1000;
    final int sampleCount = tones.length * toneSamples + gapSamples;
    final ByteData wav = ByteData(44 + sampleCount * 2);
    void ascii(int offset, String value) {
      for (int index = 0; index < value.length; index++) {
        wav.setUint8(offset + index, value.codeUnitAt(index));
      }
    }

    ascii(0, 'RIFF');
    wav.setUint32(4, 36 + sampleCount * 2, Endian.little);
    ascii(8, 'WAVE');
    ascii(12, 'fmt ');
    wav.setUint32(16, 16, Endian.little);
    wav.setUint16(20, 1, Endian.little);
    wav.setUint16(22, 1, Endian.little);
    wav.setUint32(24, sampleRate, Endian.little);
    wav.setUint32(28, sampleRate * 2, Endian.little);
    wav.setUint16(32, 2, Endian.little);
    wav.setUint16(34, 16, Endian.little);
    ascii(36, 'data');
    wav.setUint32(40, sampleCount * 2, Endian.little);
    int output = 0;
    for (final int frequency in tones) {
      for (int index = 0; index < toneSamples; index++) {
        final int edge = math.max(1, toneSamples ~/ 10);
        final double envelope = index < edge
            ? index / edge
            : index >= toneSamples - edge
            ? (toneSamples - index - 1) / edge
            : 1;
        final double value =
            math.sin(2 * math.pi * frequency * index / sampleRate) *
            volume *
            envelope;
        wav.setInt16(44 + output * 2, (value * 32767).round(), Endian.little);
        output++;
      }
      if (frequency != tones.last) output += gapSamples;
    }
    return wav.buffer.asUint8List();
  }

  static Uint8List _warningToneWav() {
    const int sampleRate = 22050;
    const int toneMs = 90;
    const int gapMs = 35;
    const double volume = 0.72;
    const List<int> tones = <int>[880, 660, 880, 660];
    final int toneSamples = sampleRate * toneMs ~/ 1000;
    final int gapSamples = sampleRate * gapMs ~/ 1000;
    final int sampleCount =
        tones.length * toneSamples + (tones.length - 1) * gapSamples;
    final ByteData wav = ByteData(44 + sampleCount * 2);
    void ascii(int offset, String value) {
      for (int index = 0; index < value.length; index++) {
        wav.setUint8(offset + index, value.codeUnitAt(index));
      }
    }

    ascii(0, 'RIFF');
    wav.setUint32(4, 36 + sampleCount * 2, Endian.little);
    ascii(8, 'WAVE');
    ascii(12, 'fmt ');
    wav.setUint32(16, 16, Endian.little);
    wav.setUint16(20, 1, Endian.little);
    wav.setUint16(22, 1, Endian.little);
    wav.setUint32(24, sampleRate, Endian.little);
    wav.setUint32(28, sampleRate * 2, Endian.little);
    wav.setUint16(32, 2, Endian.little);
    wav.setUint16(34, 16, Endian.little);
    ascii(36, 'data');
    wav.setUint32(40, sampleCount * 2, Endian.little);
    int output = 0;
    for (int toneIndex = 0; toneIndex < tones.length; toneIndex++) {
      final int frequency = tones[toneIndex];
      for (int index = 0; index < toneSamples; index++) {
        final int edge = math.max(1, toneSamples ~/ 10);
        final double envelope = index < edge
            ? index / edge
            : index >= toneSamples - edge
            ? (toneSamples - index - 1) / edge
            : 1;
        final double value =
            math.sin(2 * math.pi * frequency * index / sampleRate) *
            volume *
            envelope;
        wav.setInt16(44 + output * 2, (value * 32767).round(), Endian.little);
        output++;
      }
      if (toneIndex < tones.length - 1) output += gapSamples;
    }
    return wav.buffer.asUint8List();
  }

  static Uint8List _industrialAlarmWav() {
    const int sampleRate = 22050;
    const int toneMs = 180;
    const int gapMs = 65;
    const double volume = 0.88;
    const List<int> tones = <int>[1250, 720, 1250, 720, 1250, 720];
    final int toneSamples = sampleRate * toneMs ~/ 1000;
    final int gapSamples = sampleRate * gapMs ~/ 1000;
    final int sampleCount =
        tones.length * toneSamples + (tones.length - 1) * gapSamples;
    final ByteData wav = ByteData(44 + sampleCount * 2);
    void ascii(int offset, String value) {
      for (int index = 0; index < value.length; index++) {
        wav.setUint8(offset + index, value.codeUnitAt(index));
      }
    }

    ascii(0, 'RIFF');
    wav.setUint32(4, 36 + sampleCount * 2, Endian.little);
    ascii(8, 'WAVE');
    ascii(12, 'fmt ');
    wav.setUint32(16, 16, Endian.little);
    wav.setUint16(20, 1, Endian.little);
    wav.setUint16(22, 1, Endian.little);
    wav.setUint32(24, sampleRate, Endian.little);
    wav.setUint32(28, sampleRate * 2, Endian.little);
    wav.setUint16(32, 2, Endian.little);
    wav.setUint16(34, 16, Endian.little);
    ascii(36, 'data');
    wav.setUint32(40, sampleCount * 2, Endian.little);
    int output = 0;
    for (int toneIndex = 0; toneIndex < tones.length; toneIndex++) {
      final int frequency = tones[toneIndex];
      for (int index = 0; index < toneSamples; index++) {
        final int edge = math.max(1, toneSamples ~/ 10);
        final double envelope = index < edge
            ? index / edge
            : index >= toneSamples - edge
            ? (toneSamples - index - 1) / edge
            : 1;
        final double time = index / sampleRate;
        final double fundamental = math.sin(2 * math.pi * frequency * time);
        final double harmonic =
            math.sin(2 * math.pi * frequency * 2 * time) * 0.32;
        final double value =
            (fundamental + harmonic) / 1.32 * volume * envelope;
        wav.setInt16(44 + output * 2, (value * 32767).round(), Endian.little);
        output++;
      }
      if (toneIndex < tones.length - 1) output += gapSamples;
    }
    return wav.buffer.asUint8List();
  }

  Future<void> _play(Source source) async {
    await stop();
    await _configureAudioContext();
    final Completer<void> completion = Completer<void>();
    _activePlayback = completion;
    final StreamSubscription<void> subscription = _audioPlayer.onPlayerComplete
        .listen((_) => _completePlayback());
    try {
      await _audioPlayer.play(source).timeout(_sourceStartTimeout);
      await completion.future.timeout(const Duration(seconds: 30));
    } on Object {
      await _stopAudioPlayerBounded();
      rethrow;
    } finally {
      await subscription.cancel();
      if (identical(_activePlayback, completion)) {
        _activePlayback = null;
      }
    }
  }

  Future<void> _stopAudioPlayerBounded() async {
    try {
      await _audioPlayer.stop().timeout(const Duration(seconds: 2));
    } on Object {
      // Best-effort stop; a hung player must not block the speech workflow.
    }
  }

  Future<void> _configureAudioContext() async {
    if (!_audioContextConfigured) {
      await _audioPlayer.setAudioContext(
        buildSpeechAudioContext(
          const AudioContextAndroid(
            contentType: AndroidContentType.speech,
            usageType: AndroidUsageType.assistanceNavigationGuidance,
            audioFocus: AndroidAudioFocus.gainTransientMayDuck,
          ),
        ),
      );
      _audioContextConfigured = true;
    }
  }

  @override
  Future<void> speakSystem(String text, {bool offlineOnly = false}) async {
    await stop();
    final Completer<void> completion = Completer<void>();
    _activePlayback = completion;
    await _systemTts.setLanguage('zh-CN');
    if (offlineOnly) {
      final Object? available = await _systemTts.getVoices;
      final List<Object?> voices = available is List<Object?>
          ? available
          : const <Object?>[];
      Map<Object?, Object?>? selected;
      for (final Object? value in voices) {
        if (value is! Map<Object?, Object?>) {
          continue;
        }
        final String locale = '${value['locale'] ?? ''}'.toLowerCase();
        final Object? networkValue = value['network_required'];
        final bool requiresNetwork =
            networkValue == true || '$networkValue'.toLowerCase() == 'true';
        if (locale.startsWith('zh') && !requiresNetwork) {
          selected = value;
          break;
        }
      }
      if (selected == null) {
        throw StateError('没有可用的离线系统语音');
      }
      await _systemTts.setVoice(<String, String>{
        'name': '${selected['name']}',
        'locale': '${selected['locale']}',
      });
    }
    await _systemTts.setSpeechRate(0.5);
    await _systemTts.setPitch(1.0);
    await _systemTts.setVolume(1.0);
    await _systemTts.setAudioAttributesForNavigation();
    final Object? result = await _systemTts.speak(text, focus: false);
    if (result != 1) {
      _completePlayback();
    }
    try {
      await completion.future.timeout(const Duration(seconds: 30));
    } finally {
      if (identical(_activePlayback, completion)) {
        _activePlayback = null;
      }
    }
  }

  void _completePlayback() {
    final Completer<void>? completion = _activePlayback;
    if (completion != null && !completion.isCompleted) {
      completion.complete();
    }
  }

  @override
  Future<void> stop() async {
    _completePlayback();
    try {
      await Future.wait<void>(<Future<void>>[
        _audioPlayer.stop(),
        _systemTts.stop().then((_) {}),
      ]).timeout(const Duration(seconds: 2));
    } on Object {
      // Best-effort stop; a hung player must not block the speech workflow.
    }
  }

  @override
  Future<void> dispose() async {
    await stop();
    await _audioPlayer.dispose();
    final AudioPlayer? beepPlayer = _beepPlayer;
    _beepPlayer = null;
    if (beepPlayer != null) {
      await beepPlayer.dispose();
    }
  }
}
