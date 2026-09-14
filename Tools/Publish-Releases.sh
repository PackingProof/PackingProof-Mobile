#!/bin/bash
# 把当前 tag 的 Android APK 发布到 GitHub 与 Gitee Release。
#
#   ./Tools/Publish-Releases.sh <release-notes-file> [--title "<一句话内容>"] [--prerelease]
#
# 约定：
# - 只上传 Android APK，iOS 走 TestFlight（Tools/Upload-TestFlight.sh），不附 IPA
# - APK 必须已经由 Tools/Publish-Android.ps1 生成在 dist/android/ 下
# - 标题固定 `v<X.Y.Z+VVVV> <一句话内容>`，两个平台内容保持一致
# - GitHub 用 gh、Gitee 用 gitee CLI，各自的登录态由 CLI 自己维护，不读凭据

set -euo pipefail

REPO_ROOT="$(cd "$(dirname "$0")/.." && pwd)"
cd "$REPO_ROOT"

REPO_SLUG="PackingProof/PackingProof-Mobile"

NOTES_FILE=""
TITLE_SUFFIX=""
PRERELEASE=0
while [ "$#" -gt 0 ]; do
  case "$1" in
    --title) TITLE_SUFFIX="${2:-}"; shift 2 ;;
    --prerelease) PRERELEASE=1; shift ;;
    -*) echo "未知参数：$1" >&2; exit 1 ;;
    *) NOTES_FILE="$1"; shift ;;
  esac
done

if [ -z "$NOTES_FILE" ] || [ ! -f "$NOTES_FILE" ]; then
  echo "用法：./Tools/Publish-Releases.sh <release-notes-file> [--title \"<一句话内容>\"] [--prerelease]" >&2
  exit 1
fi

if [ -n "$(git status --porcelain --untracked-files=all)" ]; then
  echo "发布前 Git 工作区必须干净" >&2
  exit 1
fi

TAG="$(git describe --tags --exact-match 2>/dev/null || true)"
if [ -z "$TAG" ]; then
  echo "当前提交没有精确 tag，请先建 v<versionName>+<versionCode> 标签" >&2
  exit 1
fi

APK="dist/android/PackingProof-Mobile-v${TAG#v}.apk"
if [ ! -f "$APK" ]; then
  echo "找不到 APK：${APK}，请先在 Windows 编译机执行 Tools/Publish-Android.ps1 并取回产物" >&2
  exit 1
fi

TITLE="$TAG"
[ -n "$TITLE_SUFFIX" ] && TITLE="${TAG} ${TITLE_SUFFIX}"

echo "发布 ${TAG}"
echo "  APK    ${APK}"
echo "  笔记   ${NOTES_FILE}"
echo "  标题   ${TITLE}"

echo ""
echo "==> GitHub Release"
gh_args=(release create "$TAG" "$APK" --repo "$REPO_SLUG" --title "$TITLE" --notes-file "$NOTES_FILE")
[ "$PRERELEASE" -eq 1 ] && gh_args+=(--prerelease)
if gh release view "$TAG" --repo "$REPO_SLUG" >/dev/null 2>&1; then
  echo "GitHub 上 ${TAG} 已存在，跳过创建"
else
  # 公网到 GitHub 偶发连不上，重试几次再判失败。
  for attempt in 1 2 3 4 5; do
    if gh "${gh_args[@]}"; then break; fi
    [ "$attempt" -eq 5 ] && { echo "GitHub Release 创建失败" >&2; exit 1; }
    sleep 10
  done
fi

echo ""
echo "==> Gitee Release"
gitee_args=(release create --repo "$REPO_SLUG" --tag "$TAG" --target main --name "$TITLE" --notes "$(cat "$NOTES_FILE")")
[ "$PRERELEASE" -eq 1 ] && gitee_args+=(--prerelease)
if gitee release view "$TAG" --repo "$REPO_SLUG" >/dev/null 2>&1; then
  echo "Gitee 上 ${TAG} 已存在，跳过创建"
else
  gitee "${gitee_args[@]}" >/dev/null
fi
gitee release upload --repo "$REPO_SLUG" "$TAG" "$APK" >/dev/null
echo "Gitee 附件已上传（Gitee 会把文件名里的 + 显示成空格，属正常）"

echo ""
echo "GitHub 与 Gitee Release 均已就绪：${TAG}"
echo "iOS 仍需单独执行 ./Tools/Upload-TestFlight.sh 上传 TestFlight"
