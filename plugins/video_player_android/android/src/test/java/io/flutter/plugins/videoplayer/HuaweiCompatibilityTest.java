// Copyright 2026 The PackingProof authors
// Use of this source code is governed by a BSD-style license that can be
// found in the LICENSE file.

package io.flutter.plugins.videoplayer;

import static org.junit.Assert.assertFalse;
import static org.junit.Assert.assertTrue;

import android.os.Build;
import org.junit.After;
import org.junit.Test;
import org.junit.runner.RunWith;
import org.robolectric.RobolectricTestRunner;
import org.robolectric.annotation.Config;
import org.robolectric.util.ReflectionHelpers;

@RunWith(RobolectricTestRunner.class)
public final class HuaweiCompatibilityTest {
  private final String originalManufacturer = Build.MANUFACTURER;

  @After
  public void restoreManufacturer() {
    ReflectionHelpers.setStaticField(Build.class, "MANUFACTURER", originalManufacturer);
  }

  @Test
  @Config(sdk = 30)
  public void api30HuaweiAndHonorPreferSoftwareDecoder() {
    setManufacturer("HUAWEI");
    assertTrue(HuaweiCompatibility.forceSoftwareDecoderPreference());

    setManufacturer(" honor ");
    assertTrue(HuaweiCompatibility.forceSoftwareDecoderPreference());
  }

  @Test
  @Config(sdk = 29)
  public void api29HuaweiKeepsUpstreamDecoderSelection() {
    setManufacturer("HUAWEI");
    assertFalse(HuaweiCompatibility.forceSoftwareDecoderPreference());
  }

  @Test
  @Config(sdk = 35)
  public void otherManufacturersKeepUpstreamDecoderSelection() {
    setManufacturer("SAMSUNG");
    assertFalse(HuaweiCompatibility.forceSoftwareDecoderPreference());
  }

  private static void setManufacturer(String value) {
    ReflectionHelpers.setStaticField(Build.class, "MANUFACTURER", value);
  }
}
