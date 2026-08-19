#!/bin/bash
set -euo pipefail

REPO_ROOT="$(cd "$(dirname "$0")/.." && pwd)"
cd "$REPO_ROOT"

EXPORT_METHOD="${1:-app-store}"
FORCE_CLEAN="${2:-}"

VERSION_LINE="$(awk '/^version:/{print $2; exit}' pubspec.yaml)"
if [[ ! "$VERSION_LINE" =~ ^([0-9]+\.[0-9]+\.[0-9]+)\+([0-9]+)$ ]]; then
  echo "pubspec.yaml 缺少有效的 version: x.y.z+buildNumber" >&2
  exit 1
fi
VERSION_NAME="${BASH_REMATCH[1]}"
VERSION_CODE="${BASH_REMATCH[2]}"

if [[ "$FORCE_CLEAN" == "clean" ]]; then
  flutter clean
fi

flutter pub get
flutter build ipa --release \
  --build-name "$VERSION_NAME" \
  --build-number "$VERSION_CODE" \
  --export-method "$EXPORT_METHOD"

IPA_DIR="$REPO_ROOT/build/ios/ipa"
SOURCE_IPA="$(find "$IPA_DIR" -maxdepth 1 -name '*.ipa' -print -quit)"
if [[ -z "$SOURCE_IPA" ]]; then
  echo "未找到 IPA 产物：$IPA_DIR" >&2
  exit 1
fi

OUTPUT_DIR="$REPO_ROOT/dist/ios"
mkdir -p "$OUTPUT_DIR"
OUTPUT_NAME="PackingProof-Mobile-v${VERSION_NAME}+${VERSION_CODE}.ipa"
OUTPUT_IPA="$OUTPUT_DIR/$OUTPUT_NAME"
cp "$SOURCE_IPA" "$OUTPUT_IPA"

REVISION="$(git rev-parse --short=8 HEAD)"
BUILT_AT="$(date -u +%Y-%m-%dT%H:%M:%SZ)"
SHA256="$(shasum -a 256 "$OUTPUT_IPA" | awk '{print $1}')"
BYTES="$(stat -f%z "$OUTPUT_IPA")"

printf '%s  %s\n' "$SHA256" "$OUTPUT_NAME" > "$OUTPUT_DIR/SHA256SUMS.txt"

cat > "$OUTPUT_DIR/build-manifest.json" <<EOF
{
  "versionName": "$VERSION_NAME",
  "versionCode": "$VERSION_CODE",
  "bundleId": "app.packingproof.mobile",
  "revision": "$REVISION",
  "builtAtUtc": "$BUILT_AT",
  "exportMethod": "$EXPORT_METHOD",
  "artifacts": [
    {
      "file": "$OUTPUT_NAME",
      "sha256": "$SHA256",
      "bytes": $BYTES
    }
  ]
}
EOF

echo "iOS IPA 已输出到 $OUTPUT_IPA"
echo "版本：$VERSION_NAME+$VERSION_CODE"
echo "SHA256：$SHA256"
