#!/bin/bash
set -euo pipefail

REPO_ROOT="$(cd "$(dirname "$0")/.." && pwd)"
BUILDER="$REPO_ROOT/Tools/Build-iOS.sh"
cd "$REPO_ROOT"

usage() {
  cat <<'EOF'
用法：Tools/Publish-iOS.sh [clean]
EOF
}

FORCE_CLEAN=""
if [[ $# -gt 1 ]]; then
  usage >&2
  exit 2
fi
if [[ $# -eq 1 ]]; then
  if [[ "$1" != "clean" ]]; then
    echo "未知参数：$1" >&2
    usage >&2
    exit 2
  fi
  FORCE_CLEAN="clean"
fi

if [[ ! -x "$BUILDER" ]]; then
  echo "找不到可执行的 iOS 构建脚本：$BUILDER" >&2
  exit 1
fi

if [[ -n "$(git status --porcelain --untracked-files=all)" ]]; then
  echo "正式发布前 Git 工作区必须干净，请先提交或移除未跟踪文件" >&2
  exit 1
fi

VERSION_LINE="$(awk '/^version:/{print $2; exit}' pubspec.yaml)"
if [[ ! "$VERSION_LINE" =~ ^([0-9]+\.[0-9]+\.[0-9]+)\+([1-9][0-9]*)$ ]]; then
  echo "pubspec.yaml 缺少有效的 version: x.y.z+buildNumber" >&2
  exit 1
fi
VERSION_NAME="${BASH_REMATCH[1]}"
VERSION_CODE="${BASH_REMATCH[2]}"

RELEASE_TAGS=()
while IFS= read -r tag; do
  RELEASE_TAGS+=("$tag")
done < <(
  git tag --points-at HEAD |
    awk '/^v?[0-9]+\.[0-9]+\.[0-9]+(\+[1-9][0-9]*)?$/'
)
if [[ ${#RELEASE_TAGS[@]} -eq 0 ]]; then
  echo "当前提交没有版本标签。请先创建类似 v0.5.25+11040 的标签" >&2
  exit 1
fi
if [[ ${#RELEASE_TAGS[@]} -gt 1 ]]; then
  echo "当前提交存在多个版本标签：${RELEASE_TAGS[*]}" >&2
  exit 1
fi

RELEASE_TAG="${RELEASE_TAGS[0]}"
TAG_VERSION="${RELEASE_TAG#v}"
if [[ "$TAG_VERSION" == *+* ]]; then
  if [[ "$TAG_VERSION" != "$VERSION_LINE" ]]; then
    echo "版本标签 $RELEASE_TAG 与 pubspec.yaml 版本 $VERSION_LINE 不一致" >&2
    exit 1
  fi
elif [[ "$TAG_VERSION" != "$VERSION_NAME" ]]; then
  echo "版本标签 $RELEASE_TAG 与 pubspec.yaml 版本 $VERSION_LINE 不一致" >&2
  exit 1
fi

echo "准备验证并构建 $RELEASE_TAG"
# 启动前检查：模拟器没起来时 xcodebuild 只会报启动失败，先把设备准备好。
source "$REPO_ROOT/Tools/ios-simulator.sh"
SIMULATOR_ID="$(prepare_ios_simulator)" || exit 1
flutter pub get
flutter analyze --no-pub --no-fatal-infos
flutter test --no-pub --concurrency=1
(cd ios && pod install --deployment)
git restore -- ios/Runner.xcodeproj/project.pbxproj
if ! git diff --quiet --exit-code || ! git diff --cached --quiet --exit-code; then
  echo "pod install 改写了受跟踪文件，请先提交匹配的 iOS 依赖锁文件" >&2
  exit 1
fi

xcodebuild test \
  -workspace ios/Runner.xcworkspace \
  -scheme Runner \
  -destination "platform=iOS Simulator,id=$SIMULATOR_ID" \
  -parallel-testing-enabled NO \
  CODE_SIGNING_ALLOWED=NO

BUILD_ARGS=(--release app-store)
if [[ "$FORCE_CLEAN" == "clean" ]]; then
  BUILD_ARGS+=(clean)
fi
"$BUILDER" "${BUILD_ARGS[@]}"

OUTPUT_DIR="$REPO_ROOT/dist/ios"
OUTPUT_NAME="PackingProof-Mobile-v${VERSION_NAME}+${VERSION_CODE}.ipa"
OUTPUT_IPA="$OUTPUT_DIR/$OUTPUT_NAME"
MANIFEST="$OUTPUT_DIR/build-manifest.json"
CHECKSUMS="$OUTPUT_DIR/SHA256SUMS.txt"

if [[ ! -s "$OUTPUT_IPA" || ! -s "$MANIFEST" || ! -s "$CHECKSUMS" ]]; then
  echo "iOS 正式发布产物不完整" >&2
  exit 1
fi

python3 - "$OUTPUT_IPA" "$MANIFEST" "$CHECKSUMS" "$VERSION_NAME" "$VERSION_CODE" <<'PY'
import hashlib
import json
import plistlib
import sys
import zipfile
from pathlib import Path

ipa_path = Path(sys.argv[1])
manifest_path = Path(sys.argv[2])
checksums_path = Path(sys.argv[3])
version_name = sys.argv[4]
version_code = sys.argv[5]

digest = hashlib.sha256(ipa_path.read_bytes()).hexdigest()
expected_checksum = checksums_path.read_text(encoding="utf-8").split()[0]
if digest != expected_checksum:
    raise SystemExit("IPA SHA256 与 SHA256SUMS.txt 不一致")

manifest = json.loads(manifest_path.read_text(encoding="utf-8"))
expected_manifest = {
    "versionName": version_name,
    "versionCode": version_code,
    "bundleId": "app.packingproof.mobile",
    "buildMode": "release",
    "exportMethod": "app-store",
}
for key, expected in expected_manifest.items():
    if str(manifest.get(key)) != expected:
        raise SystemExit(f"构建清单字段错误：{key}")
if not manifest.get("revision") or not manifest.get("builtAtUtc"):
    raise SystemExit("构建清单缺少 Git revision 或构建时间")
artifacts = manifest.get("artifacts") or []
if len(artifacts) != 1 or artifacts[0].get("file") != ipa_path.name or artifacts[0].get("sha256") != digest:
    raise SystemExit("构建清单中的 IPA 信息不匹配")

with zipfile.ZipFile(ipa_path) as archive:
    plist_names = [name for name in archive.namelist() if name.startswith("Payload/") and name.endswith(".app/Info.plist")]
    if len(plist_names) != 1:
        raise SystemExit("IPA 中未找到唯一的 App Info.plist")
    info = plistlib.loads(archive.read(plist_names[0]))
if info.get("CFBundleIdentifier") != "app.packingproof.mobile":
    raise SystemExit("IPA Bundle ID 错误")
if str(info.get("CFBundleShortVersionString")) != version_name:
    raise SystemExit("IPA 版本名错误")
if str(info.get("CFBundleVersion")) != version_code:
    raise SystemExit("IPA 构建号错误")
PY

echo "iOS 正式发布 IPA 已通过验证：$OUTPUT_IPA"
