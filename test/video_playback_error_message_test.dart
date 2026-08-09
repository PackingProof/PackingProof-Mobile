import 'package:flutter_test/flutter_test.dart';
import 'package:packing_proof_mobile/screens/video_playback_screen.dart';
import 'package:packing_proof_mobile/services/system_video_player_service.dart';

void main() {
  test('本地播放失败文案区分文件缺失、损坏与已备份离线', () {
    expect(
      localPlaybackErrorMessage(fileExists: false, backedUpOffline: false),
      '录像文件不在本机，可能已被清理，无法播放',
    );
    expect(
      localPlaybackErrorMessage(fileExists: true, backedUpOffline: false),
      '录像文件不完整或已损坏，无法播放（可能是异常退出导致）',
    );
    expect(
      localPlaybackErrorMessage(fileExists: false, backedUpOffline: true),
      '录像已备份到电脑，电脑离线时暂时无法播放，请连接电脑后重试',
    );
    expect(
      localPlaybackErrorMessage(fileExists: true, backedUpOffline: true),
      '录像已备份到电脑，电脑离线时暂时无法播放，请连接电脑后重试',
    );
  });

  test('设备缺少 H.265 解码器时给出编码兼容提示', () {
    const VideoDecodeSupport noHevc = VideoDecodeSupport(
      manufacturer: 'HUAWEI',
      brand: 'HUAWEI',
      model: 'test',
      sdkInt: 31,
      release: '12',
      hasHevcDecoder: false,
      hasAvcDecoder: true,
    );
    expect(
      localPlaybackErrorMessage(
        fileExists: true,
        backedUpOffline: false,
        videoMime: 'video/hevc',
        decodeSupport: noHevc,
      ),
      '该录像为 H.265 编码，当前设备不支持解码播放。请改用 H.264 重新录制，或分享原文件到电脑/其他设备查看',
    );
    expect(
      localPlaybackErrorMessage(
        fileExists: true,
        backedUpOffline: false,
        videoMime: 'video/avc',
        decodeSupport: noHevc,
      ),
      '录像文件不完整或已损坏，无法播放（可能是异常退出导致）',
    );
  });

  test('设备缺少 H.264 解码器时给出对应提示', () {
    const VideoDecodeSupport noAvc = VideoDecodeSupport(
      manufacturer: 'HUAWEI',
      brand: 'HUAWEI',
      model: 'test',
      sdkInt: 31,
      release: '12',
      hasHevcDecoder: true,
      hasAvcDecoder: false,
    );
    expect(
      localPlaybackErrorMessage(
        fileExists: true,
        backedUpOffline: false,
        videoMime: 'video/avc',
        decodeSupport: noAvc,
      ),
      '该录像为 H.264 编码，当前设备不支持解码播放，请分享原文件到电脑/其他设备查看',
    );
  });

  test('设备支持解码或编码未知时保持通用文案', () {
    const VideoDecodeSupport fullSupport = VideoDecodeSupport(
      manufacturer: 'HUAWEI',
      brand: 'HUAWEI',
      model: 'test',
      sdkInt: 31,
      release: '12',
      hasHevcDecoder: true,
      hasAvcDecoder: true,
    );
    expect(
      localPlaybackErrorMessage(
        fileExists: true,
        backedUpOffline: false,
        videoMime: 'video/hevc',
        decodeSupport: fullSupport,
      ),
      '录像文件不完整或已损坏，无法播放（可能是异常退出导致）',
    );
    expect(
      localPlaybackErrorMessage(
        fileExists: true,
        backedUpOffline: false,
        videoMime: 'video/hevc',
      ),
      '录像文件不完整或已损坏，无法播放（可能是异常退出导致）',
    );
  });
}
