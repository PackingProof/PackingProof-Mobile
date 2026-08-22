# PackingProof Mobile

[中文](README.md) | [English](README_EN.md)

Give every package reviewable packing evidence.

PackingProof Mobile is an Android recording tool for online sellers and packing stations. Mount a phone above the packing area, tap **Start Work** once, and the app continuously records, automatically recognizes shipping-label barcodes, and adds a marker when a tracking number is recognized. When an after-sales dispute occurs, operators can quickly locate the relevant footage by tracking number.

[Download the latest release](https://github.com/PackingProof/PackingProof-Mobile/releases)

<p align="center">
  <img src="docs/screenshots/history.jpg" alt="Recording history and quick search" width="31%">
  <img src="docs/screenshots/home.jpg" alt="Recording and shipping-label recognition" width="31%">
  <img src="docs/screenshots/settings.png" alt="Settings" width="31%">
</p>

## Key Features

- **One-tap work session**: keeps the camera preview active and the screen awake, minimizing touch interaction while packing
- **Automatic label recognition**: recognizes common one-dimensional logistics barcodes, records the tracking number, and marks the moment in the recording
- **Two work modes**: continuous scanning for production-line packing, or stop-on-same-code for one-order-per-clip workflows
- **Fast evidence lookup**: searches order history by tracking number and jumps directly to the matching position in the recording
- **Spoken order alerts**: announces buyer messages, seller notes, product information, and refund status; refunds trigger a prominent industrial alarm
- **Automatic computer backup**: connects by scanning a QR code from the desktop app and backs up recordings over the local network
- **Flexible recording cleanup**: uses separate retention policies for backed-up and unbacked recordings to balance evidence safety and phone storage
- **Local first**: requires no account and does not depend on cloud storage; order and recording data remain under the operator's control

## How to Use

1. Install the app and grant the required camera, microphone, and storage permissions
2. Mount the phone where both the packing area and shipping label are clearly visible
3. Tap **Start Work** and pack orders normally
4. When a label enters the frame, the app recognizes its tracking number and marks the moment in the recording
5. To review evidence, open **Order History**, search for the tracking number, and play the matching recording

For computer backup or spoken order alerts, keep the phone and computer on the same local network and follow the in-app connection instructions.

## Typical Uses

- E-commerce warehouses and small packing teams
- Evidence for after-sales disputes and wrong or missing shipment investigations
- Shipment records for high-value, fragile, or customized products
- Low-cost packing monitoring using a spare Android phone

## Privacy

The app does not require an account and does not upload recordings to the cloud on its own. When computer backup is enabled, recordings are transferred only between paired devices on the local network. Use recording features in accordance with local laws and workplace requirements.

## Local Development

Flutter 3.44 or a compatible stable release is required.

```powershell
flutter pub get
flutter analyze
flutter test
flutter run
```

Build an Android debug APK:

```powershell
flutter build apk --debug
```

Alternatively, double-click `双击构建Debug包.bat` to build a debug-signed APK at `dist/android/PackingProof-Mobile-debug-v<versionName>+<versionCode>.apk` with no signing configuration.

Build a local diagnostic APK with the Android debug certificate:

```powershell
pwsh -NoProfile -File Tools\Build-Android.ps1
```

Build a formally signed APK:

```powershell
git tag v0.5.16+11016
pwsh -NoProfile -File Tools\Publish-Android.ps1 `
  -SigningDirectory <external-signing-directory>
```

The formal release script requires a clean worktree and an exact version tag on the current commit. Use tags in the form `v<versionName>+<increasing-versionCode>`; for example, `v0.5.16+11016` produces version name `0.5.16` and version code `11016`. The external signing directory must contain the keystore and a UTF-8 file named `签名凭据.txt` with the following format:

```text
密钥文件: app-release.jks
别名: <key-alias>
密钥库密码: <keystore-password>
密钥密码: <key-password>
```

The release workflow generates or reuses bundled speech assets, runs static analysis and the full test suite, and then creates one unified `arm64-v8a` APK. A locally built diagnostic APK uses the Android debug certificate: it cannot replace a formally signed installation and must not be distributed as an official release.

To build a Release test APK that can replace an installed build signed with the same certificate, set `PACKING_PROOF_SIGNING_DIRECTORY=<external-signing-directory>` in the untracked root `.env` file and run `双击构建Release调试版.bat`. This helper reads the version from `pubspec.yaml`, outputs `dist/android/PackingProof-Mobile-v<versionName>+<versionCode>.apk`, and does not create a Git tag or release.

Release artifacts are written to `dist/android/` as `PackingProof-Mobile-v<versionName>+<versionCode>.apk`, `SHA256SUMS.txt`, and `build-manifest.json`. No ZIP archive is generated.

## License and Branding

The source code is available under the [AGPL-3.0 License](LICENSE). Distributing a modified version or providing it as a service requires compliance with the corresponding source-sharing obligations.

The `PackingProof`, `PackingProof Mobile`, and `包裹留证` names and official application icons are project brand assets. The AGPL-3.0 source-code license does not grant permission to use them as the product identity of a modified version. Public modifications should use a distinct product name and icon, clearly identify themselves as unofficial, and may use “based on PackingProof” to describe their origin. See the [Brand Policy](BRAND_POLICY.md).
