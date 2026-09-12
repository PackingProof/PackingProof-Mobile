#!/bin/bash
# 把已构建好的正式 IPA 上传到 App Store Connect（TestFlight）。
#
#   ./Tools/Upload-TestFlight.sh [ipa-path]
#
# 不传路径时按当前精确 Git tag 推出 dist/ios 下的 IPA。
# 凭据从仓库根目录 .env 读取，.env 已被 .gitignore 忽略，禁止提交。
# 两种方式二选一，优先 API Key：
#
# 一、App Store Connect API Key（推荐，可无人值守）
#   APP_STORE_CONNECT_KEY_ID=<API Key ID>
#   APP_STORE_CONNECT_ISSUER_ID=<Issuer ID>
#   APP_STORE_CONNECT_KEY_PATH=<AuthKey_<KEY_ID>.p8 的仓库外绝对路径>
#
# KEY_PATH 可省略，此时按 altool 的默认约定在
# ~/.appstoreconnect/private_keys/AuthKey_<KEY_ID>.p8 查找。
#
# 二、Apple ID + App 专用密码（没有 API Key 时的退路）
#   APPLE_ID=<Apple ID 邮箱>
#   APPLE_APP_SPECIFIC_PASSWORD=<appleid.apple.com 生成的 App 专用密码>
#
# 专用密码也可以存进钥匙串后写成 @keychain:<item-name>，避免明文落盘。

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
APPLE_ID_VALUE="${APPLE_ID:-$(read_dotenv APPLE_ID)}"
APPLE_PASSWORD="${APPLE_APP_SPECIFIC_PASSWORD:-$(read_dotenv APPLE_APP_SPECIFIC_PASSWORD)}"

AUTH_MODE=""
if [ -n "$KEY_ID" ] && [ -n "$ISSUER_ID" ]; then
  AUTH_MODE="apikey"
elif [ -n "$APPLE_ID_VALUE" ] && [ -n "$APPLE_PASSWORD" ]; then
  AUTH_MODE="appleid"
else
  echo "缺少上传凭据，请在 .env 配置以下任一组：" >&2
  echo "  APP_STORE_CONNECT_KEY_ID + APP_STORE_CONNECT_ISSUER_ID（推荐）" >&2
  echo "  APPLE_ID + APPLE_APP_SPECIFIC_PASSWORD" >&2
  echo "模板见 .env.example，流程见 docs/ios-development.md 的「上传 TestFlight」" >&2
  echo "先跑 ./Tools/Check-ReleasePrereqs.sh 可以一次看清还缺什么" >&2
  exit 1
fi

if [ "$AUTH_MODE" = "apikey" ]; then
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
fi

IPA_PATH="${1:-}"
if [ -z "$IPA_PATH" ]; then
  TAG="$(git describe --tags --exact-match 2>/dev/null || true)"
  if [ -z "$TAG" ]; then
    echo "当前提交没有精确 tag，无法推断 IPA 路径，请显式传入" >&2
    echo "dist/ios 下现有的 IPA：" >&2
    ls -1 dist/ios/*.ipa 2>/dev/null | sed 's/^/  /' >&2 || echo "  （没有）" >&2
    exit 1
  fi
  IPA_PATH="dist/ios/PackingProof-Mobile-${TAG#v}.ipa"
fi

if [ ! -f "$IPA_PATH" ]; then
  echo "找不到 IPA：${IPA_PATH}，请先执行 Tools/Publish-iOS.sh" >&2
  exit 1
fi

AUTH_ARGS=()
if [ "$AUTH_MODE" = "apikey" ]; then
  # altool 的私钥查找只认目录约定，这里用临时目录喂给它，避免把私钥复制进仓库。
  PRIVATE_KEY_DIR="$(mktemp -d)"
  cleanup() { rm -rf -- "$PRIVATE_KEY_DIR"; }
  trap cleanup EXIT
  cp "$KEY_PATH" "${PRIVATE_KEY_DIR}/AuthKey_${KEY_ID}.p8"
  export API_PRIVATE_KEYS_DIR="$PRIVATE_KEY_DIR"
  AUTH_ARGS=(--apiKey "$KEY_ID" --apiIssuer "$ISSUER_ID")
  echo "认证方式：App Store Connect API Key"
else
  AUTH_ARGS=(--username "$APPLE_ID_VALUE" --password "$APPLE_PASSWORD")
  echo "认证方式：Apple ID 与 App 专用密码"
fi

echo "校验 IPA：${IPA_PATH}"
xcrun altool --validate-app --type ios --file "$IPA_PATH" "${AUTH_ARGS[@]}"

echo "上传到 TestFlight：${IPA_PATH}"
xcrun altool --upload-app --type ios --file "$IPA_PATH" "${AUTH_ARGS[@]}"

echo "已提交到 App Store Connect，构建包需要等苹果处理完才会出现在 TestFlight"
