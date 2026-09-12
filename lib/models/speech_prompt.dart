enum SpeechPromptPriority { normal, warning }

enum SpeechPromptCue { none, remark, warning, industrial }

enum SpeechPrompt {
  shippingMode(
    text: '发货模式',
    assetName: 'shipping_mode.mp3',
    priority: SpeechPromptPriority.normal,
  ),
  returnMode(
    text: '退货模式',
    assetName: 'return_mode.mp3',
    priority: SpeechPromptPriority.normal,
  ),
  recordingStarted(
    text: '开始录制',
    assetName: 'recording_started.mp3',
    priority: SpeechPromptPriority.normal,
  ),
  recordingStopped(
    text: '停止录制',
    assetName: 'recording_stopped.mp3',
    priority: SpeechPromptPriority.normal,
  ),
  previewEnabled(
    text: '语音提示已开启',
    assetName: 'preview_enabled.mp3',
    priority: SpeechPromptPriority.normal,
  ),
  testOrderReceived(
    text: '已收到测试订单',
    assetName: 'test_order_received.mp3',
    priority: SpeechPromptPriority.normal,
    cue: SpeechPromptCue.remark,
  ),
  duplicateOrderWarning(
    text: '警告，重复单号，请确认',
    assetName: 'duplicate_order_warning.mp3',
    priority: SpeechPromptPriority.warning,
    cue: SpeechPromptCue.warning,
  ),
  invalidTrackingNumber(
    text: '非法单号，已拦截',
    assetName: 'invalid_tracking_number.mp3',
    priority: SpeechPromptPriority.warning,
    cue: SpeechPromptCue.warning,
  ),
  trackingNumberMismatch(
    text: '单号不一致，不会停止录制',
    assetName: 'tracking_number_mismatch.mp3',
    priority: SpeechPromptPriority.warning,
    cue: SpeechPromptCue.warning,
  ),
  cameraNotReady(
    text: '摄像头未就绪',
    assetName: 'camera_not_ready.mp3',
    priority: SpeechPromptPriority.warning,
  ),
  cameraNotFound(
    text: '未检测到摄像头',
    assetName: 'camera_not_found.mp3',
    priority: SpeechPromptPriority.warning,
  ),
  permissionRequired(
    text: '需要摄像头和麦克风权限',
    assetName: 'permission_required.mp3',
    priority: SpeechPromptPriority.warning,
  ),
  recordingFailed(
    text: '录制失败',
    assetName: 'recording_failed.mp3',
    priority: SpeechPromptPriority.warning,
  ),
  audioRecordingFailed(
    text: '声音录制异常',
    assetName: 'audio_recording_failed.mp3',
    priority: SpeechPromptPriority.warning,
  ),
  videoFileCreateFailed(
    text: '录像文件创建失败',
    assetName: 'video_file_create_failed.mp3',
    priority: SpeechPromptPriority.warning,
  ),
  segmentSaveFailed(
    text: '录像分段保存失败',
    assetName: 'segment_save_failed.mp3',
    priority: SpeechPromptPriority.warning,
  ),
  recordingSaveFailed(
    text: '录像保存失败',
    assetName: 'recording_save_failed.mp3',
    priority: SpeechPromptPriority.warning,
  ),
  cameraDisconnected(
    text: '摄像头连接已断开',
    assetName: 'camera_disconnected.mp3',
    priority: SpeechPromptPriority.warning,
  );

  const SpeechPrompt({
    required this.text,
    required this.assetName,
    required this.priority,
    this.cue = SpeechPromptCue.none,
  });

  static const String normalVoice = 'zh-CN-XiaoxiaoNeural';
  static const String warningVoice = 'zh-CN-YunjianNeural';
  static const String assetDirectory = 'assets/audio/tts';

  final String text;
  final String assetName;
  final SpeechPromptPriority priority;
  final SpeechPromptCue cue;

  String get voice =>
      priority == SpeechPromptPriority.warning ? warningVoice : normalVoice;
  String get assetPath => '$assetDirectory/$assetName';
  String get audioPlayerAssetPath => 'audio/tts/$assetName';
}
