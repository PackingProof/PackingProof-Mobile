// Copyright 2026 The PackingProof authors
// Use of this source code is governed by a BSD-style license that can be
// found in the LICENSE file.

package io.flutter.plugins.videoplayer;

import android.os.Build;

/**
 * 鸿蒙/华为机型播放兼容策略。
 *
 * <p>部分华为/荣耀机型（HarmonyOS 3/4，API 30+）上，厂商硬件视频解码器在
 * ExoPlayer 中播放 AVC/HEVC 都会报 {@code MediaCodecVideoRenderer error}，
 * 即使 {@code MediaCodecList} 报告存在解码器（参考 flutter/flutter#185674、
 * #177912、#166481 与 androidx/media#1668）。对这些机型优先使用软件解码，
 * 可绕开有问题的厂商硬解；API 29 及以下的华为机型由 Flutter 引擎改用
 * SurfaceTexture 输出解决，不需要这里干预。
 */
public final class HuaweiCompatibility {
  private HuaweiCompatibility() {}

  public static boolean forceSoftwareDecoderPreference() {
    String manufacturer = Build.MANUFACTURER == null
        ? ""
        : Build.MANUFACTURER.trim().toUpperCase();
    boolean huaweiLike = manufacturer.equals("HUAWEI") || manufacturer.equals("HONOR");
    return huaweiLike && Build.VERSION.SDK_INT >= 30;
  }
}
