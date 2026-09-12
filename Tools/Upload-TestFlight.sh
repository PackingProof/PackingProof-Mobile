#!/bin/bash
# 把已构建好的正式 IPA 上传到 App Store Connect（TestFlight）。
#
#   ./Tools/Upload-TestFlight.sh [ipa-path]
#
# 不传路径时按当前精确 Git tag 推出 dist/ios 下的 IPA。
# 凭据从仓库根目录 .env 读取，.env 已被 .gitignore 忽略，禁止提交：
#
#   APP_STORE_CONNECT_KEY_ID=<API Key ID>
#   APP_STORE_CONNECT_ISSUER_ID=<Issuer ID>
#   APP_STORE_CONNECT_KEY_PATH=<AuthKey_<KEY_ID>.p8 的仓库外绝对路径>
#
# KEY_PATH 可省略，此时按 altool 的默认约定在
# ~/.appstoreconnect/private_keys/AuthKey_<KEY_ID>.p8 查找。

set -euo pipefail

REPO_ROOT="$(cd "$(dirname "$0")/.." && pwd)"
cd "$REPO_ROOT"

read_dotenv() {
  local key="$1"
  [ -f .env ] || return 0
  # 只取第一个等号前后的内容，允许值里出现等号和空格；顺带去掉可选的引号。
  sed -n "s/^[[:space:]]*${key}[[:space:]]*=[[:space:]]*//p" .env |
    head -n 1 |
    sed -e 's/[[:space:]]*$//' -e 's/^"\(.*\)"$/\1/' -e "s/^'\(.*\)'$/\1/"
}

KEY_ID="${APP_STORE_CONNECT_KEY_ID:-$(read_dotenv APP_STORE_CONNECT_KEY_ID)}"
ISSUER_ID="${APP_STORE_CONNECT_ISSUER_ID:-$(read_dotenv APP_STORE_CONNECT_ISSUER_ID)}"
KEY_PATH="${APP_STORE_CONNECT_KEY_PATH:-$(read_dotenv APP_STORE_CONNECT_KEY_PATH)}"

if [ -z "$KEY_ID" ] || [ -z "$ISSUER_ID" ]; then
  echo "缺少 App Store Connect 凭据：请在 .env 配置 APP_STORE_CONNECT_KEY_ID 与 APP_STORE_CONNECT_ISSUER_ID" >&2
  exit 1
fi

if [ -z "$KEY_PATH" ]; then
  KEY_PATH="${HOME}/.appstoreconnect/private_keys/AuthKey_${KEY_ID}.p8"
fi

if [ ! -f "$KEY_PATH" ]; then
  echo "找不到 API 私钥文件：${KEY_PATH}" >&2
  echo "请在 .env 配置 APP_STORE_CONNECT_KEY_PATH，或把 AuthKey_${KEY_ID}.p8 放到 ~/.appstoreconnect/private_keys/" >&2
  exit 1
fi

case "$KEY_PATH" in
  "${REPO_ROOT}"/*)
    echo "API 私钥必须放在仓库外：${KEY_PATH}" >&2
    exit 1
    ;;
esac

IPA_PATH="${1:-}"
if [ -z "$IPA_PATH" ]; then
  TAG="$(git describe --tags --exact-match 2>/dev/null || true)"
  if [ -z "$TAG" ]; then
    echo "当前提交没有精确 tag，请显式传入 IPA 路径" >&2
    exit 1
  fi
  IPA_PATH="dist/ios/PackingProof-Mobile-${TAG#v}.ipa"
fi

if [ ! -f "$IPA_PATH" ]; then
  echo "找不到 IPA：${IPA_PATH}，请先执行 Tools/Publish-iOS.sh" >&2
  exit 1
fi

echo "校验 IPA：${IPA_PATH}"
# altool 的私钥查找只认目录约定，这里用临时目录喂给它，避免把私钥复制进仓库。
PRIVATE_KEY_DIR="$(mktemp -d)"
cleanup() { rm -rf -- "$PRIVATE_KEY_DIR"; }
trap cleanup EXIT
cp "$KEY_PATH" "${PRIVATE_KEY_DIR}/AuthKey_${KEY_ID}.p8"
export API_PRIVATE_KEYS_DIR="$PRIVATE_KEY_DIR"

xcrun altool --validate-app --type ios --file "$IPA_PATH" \
  --apiKey "$KEY_ID" --apiIssuer "$ISSUER_ID"

echo "上传到 TestFlight：${IPA_PATH}"
xcrun altool --upload-app --type ios --file "$IPA_PATH" \
  --apiKey "$KEY_ID" --apiIssuer "$ISSUER_ID"

echo "已提交到 App Store Connect，构建包需要等苹果处理完才会出现在 TestFlight"
