#!/bin/bash
# 发布前置条件自检：在花时间构建之前，先确认这台机器真的能走完发布流程。
#
#   ./Tools/Check-ReleasePrereqs.sh
#
# 只读检查，不构建、不上传、不修改任何东西，也不打印凭据内容。
# 按当前机器（Mac / Windows 编译机）分别检查它负责的那一半：
# 签名与 Release 渠道登录态在 Windows 编译机上是阻断项（Release 在那里创建），
# TestFlight 凭据在 Mac 上是阻断项；另一半的缺失只提示、不算失败。
#
# 完整发布顺序见 docs/android-release.md。

set -uo pipefail

REPO_ROOT="$(cd "$(dirname "$0")/.." && pwd)"
cd "$REPO_ROOT"

# shellcheck source=Tools/GiteeAuth.Common.sh
. "$REPO_ROOT/Tools/GiteeAuth.Common.sh"

GITEE_REPO_SLUG="PackingProof/PackingProof-Mobile"

case "$(uname -s)" in
  Darwin) HOST="mac" ;;
  MINGW* | MSYS* | CYGWIN*) HOST="windows" ;;
  *) HOST="other" ;;
esac

BLOCKERS=()
WARNINGS=()

ok()    { echo "  [OK]   $1"; }
fail()  { echo "  [缺失] $1"; BLOCKERS+=("$1"); }
warn()  { echo "  [提示] $1"; WARNINGS+=("$1"); }


echo "发布前置条件自检"
echo "仓库：${REPO_ROOT}"
echo "机器：${HOST}"

echo ""
echo "== 仓库状态 =="
if [ -z "$(git status --porcelain --untracked-files=all)" ]; then
  ok "工作区干净"
else
  fail "工作区不干净，发布脚本会拒绝执行（先提交或 git stash -u）"
fi

PUBSPEC_VERSION="$(sed -n 's/^version:[[:space:]]*//p' pubspec.yaml | head -n 1)"
TAG="$(git describe --tags --exact-match 2>/dev/null || true)"
if [ -n "$TAG" ]; then
  if [ "$TAG" = "v${PUBSPEC_VERSION}" ]; then
    ok "当前提交的 tag ${TAG} 与 pubspec.yaml 一致"
  else
    fail "tag ${TAG} 与 pubspec.yaml 的 ${PUBSPEC_VERSION} 不一致"
  fi
else
  warn "当前提交没有精确 tag（pubspec.yaml 是 ${PUBSPEC_VERSION}，发布前需建 v${PUBSPEC_VERSION}）"
fi

echo ""
echo "== 本机配置 .env =="
if [ -f .env ]; then
  ok ".env 存在"
else
  fail ".env 不存在，先执行 cp .env.example .env 并填写"
fi

echo ""
echo "== Android 发布（Windows 编译机负责）=="
SIGNING_DIR="$(read_dotenv PACKING_PROOF_SIGNING_DIRECTORY)"
if [ -n "$SIGNING_DIR" ]; then
  if [ -d "$SIGNING_DIR" ]; then
    ok "签名目录已配置且存在"
  else
    if [ "$HOST" = "windows" ]; then
      fail "PACKING_PROOF_SIGNING_DIRECTORY 指向的目录不存在"
    else
      warn "PACKING_PROOF_SIGNING_DIRECTORY 指向的目录在本机不存在（Android 在 Windows 编译机上构建，属正常）"
    fi
  fi
else
  if [ "$HOST" = "windows" ]; then
    fail "缺少 PACKING_PROOF_SIGNING_DIRECTORY，Tools/Publish-Android.ps1 会直接失败"
  else
    warn "本机未配置 PACKING_PROOF_SIGNING_DIRECTORY（Android 由 Windows 编译机负责，属正常）"
  fi
fi

echo ""
echo "== iOS TestFlight 上传（Mac 负责）=="
KEY_ID="$(read_dotenv APP_STORE_CONNECT_KEY_ID)"
ISSUER_ID="$(read_dotenv APP_STORE_CONNECT_ISSUER_ID)"
KEY_PATH="$(read_dotenv APP_STORE_CONNECT_KEY_PATH)"
APPLE_ID_VALUE="$(read_dotenv APPLE_ID)"
APPLE_PASSWORD="$(read_dotenv APPLE_APP_SPECIFIC_PASSWORD)"

ios_auth_ready=0
if [ -n "$KEY_ID" ] && [ -n "$ISSUER_ID" ]; then
  ok "App Store Connect API Key 的 Key ID 与 Issuer ID 已配置"
  [ -z "$KEY_PATH" ] && KEY_PATH="${HOME}/.appstoreconnect/private_keys/AuthKey_${KEY_ID}.p8"
  if [ -f "$KEY_PATH" ]; then
    ok "API 私钥文件存在"
    ios_auth_ready=1
  elif [ "$HOST" = "mac" ]; then
    fail "找不到 API 私钥 .p8（按 APP_STORE_CONNECT_KEY_PATH 或 altool 默认目录查找）"
  else
    warn "本机找不到 API 私钥 .p8（iOS 由 Mac 负责，属正常）"
  fi
elif [ -n "$APPLE_ID_VALUE" ] && [ -n "$APPLE_PASSWORD" ]; then
  ok "Apple ID 与 App 专用密码已配置（API Key 的退路方式）"
  ios_auth_ready=1
else
  if [ "$HOST" = "mac" ]; then
    fail "缺少 TestFlight 上传凭据，Tools/Upload-TestFlight.sh 无法运行（见 .env.example）"
  else
    warn "本机未配置 TestFlight 上传凭据（iOS 由 Mac 负责，属正常）"
  fi
fi

if [ "$HOST" = "mac" ]; then
  if xcrun --find altool >/dev/null 2>&1; then
    ok "altool 可用"
  else
    fail "找不到 altool，需要安装 Xcode 命令行工具"
  fi
fi

echo ""
echo "== 发布渠道登录态（Tools/Publish-Releases.sh 在 Windows 编译机上执行）=="
# Release 在 Windows 编译机创建：APK 与发布笔记就在那台机器上，不需要跨机拷贝。
if [ "$HOST" = "windows" ]; then
  channel_issue() { fail "$1"; }
else
  channel_issue() { warn "$1（Release 由 Windows 编译机创建，属正常）"; }
fi

if command -v gh >/dev/null 2>&1; then
  if gh auth status >/dev/null 2>&1; then
    ok "gh 已登录"
  else
    channel_issue "gh 未登录，执行 gh auth login"
  fi
else
  channel_issue "未安装 gh，GitHub Release 无法创建"
fi

if command -v gitee >/dev/null 2>&1; then
  # 令牌固定来自 .env；`gitee auth status` 在令牌失效时仍返回 0，
  # 所以这里做一次真实只读调用，避免构建完才发现认证不可用。
  import_gitee_token
  GITEE_TOKEN_LABEL="${GITEE_TOKEN_SOURCE:-gitee CLI 登录态}"
  if test_gitee_authentication "$GITEE_REPO_SLUG"; then
    ok "gitee 令牌可用（来源：${GITEE_TOKEN_LABEL}）"
  elif [ -n "$GITEE_TOKEN_SOURCE" ]; then
    channel_issue "gitee 令牌不可用（来源：${GITEE_TOKEN_LABEL}），请核对 .env 的 GITEE_TOKEN"
  else
    channel_issue "gitee 不可用：.env 里没有 GITEE_TOKEN，gitee CLI 登录态也不可用"
  fi
else
  channel_issue "未安装 gitee CLI，Gitee Release 无法创建"
fi

echo ""
echo "== 工具链 =="
if command -v flutter >/dev/null 2>&1; then
  ok "flutter 可用（$(flutter --version 2>/dev/null | head -n 1)）"
else
  fail "找不到 flutter"
fi

echo ""
echo "======== 自检汇总 ========"
if [ "${#WARNINGS[@]}" -gt 0 ]; then
  echo "提示（本机不负责的部分，不阻断）："
  for item in "${WARNINGS[@]}"; do echo "  - ${item}"; done
fi

if [ "${#BLOCKERS[@]}" -gt 0 ]; then
  echo ""
  echo "阻断项 ${#BLOCKERS[@]} 个，必须先解决："
  for item in "${BLOCKERS[@]}"; do echo "  - ${item}"; done
  echo ""
  echo "凭据类缺失看 .env.example 的说明；流程看 docs/android-release.md"
  exit 1
fi

echo ""
echo "本机发布前置条件齐备"
echo "下一步：./Tools/test-ci.sh 跑本地 CI 门禁"
