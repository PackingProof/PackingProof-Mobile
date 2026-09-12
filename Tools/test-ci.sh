#!/bin/bash
# 本地 CI 门禁：与 .github/workflows/ci.yml 的检查项保持一致。
#
# CI 分成两半：Windows job（含 Android 原生测试）与 macOS job（含 golden、
# RunnerTests 和 iOS 构建）。本脚本按当前机器执行对应的一半，跳过的部分会在
# 汇总里显式列出，不会被算作通过。发布前两半都必须在各自机器上跑通。
#
#   ./Tools/test-ci.sh [diff-base]
#
# diff-base 用于增量检查（空白字符、宽泛 catch），默认与上一个提交比较。

set -uo pipefail

REPO_ROOT="$(cd "$(dirname "$0")/.." && pwd)"
cd "$REPO_ROOT"

DIFF_BASE="${1:-HEAD~1}"

case "$(uname -s)" in
  Darwin) HOST_HALF="macos" ;;
  MINGW* | MSYS* | CYGWIN*) HOST_HALF="windows" ;;
  *) HOST_HALF="other" ;;
esac

PASSED=()
FAILED=()
SKIPPED=()

run_step() {
  local name="$1"
  shift
  echo ""
  echo "==> ${name}"
  if "$@"; then
    PASSED+=("$name")
  else
    echo "!!! 失败：${name}"
    FAILED+=("$name")
  fi
}

skip_step() {
  SKIPPED+=("$1（$2）")
}

echo "本地 CI：仓库 ${REPO_ROOT}"
echo "当前机器承担的 CI 分支：${HOST_HALF}"
echo "增量检查基线：${DIFF_BASE}"

# —— 两半共有的检查 ——
run_step "改动文件空白字符" ./tool/check_diff.sh "$DIFF_BASE"
run_step "新增宽泛 catch" ./tool/check_new_broad_catches.sh "$DIFF_BASE"
run_step "大文件行数上限" ./tool/check_large_file_limits.sh
run_step "flutter pub get" flutter pub get
run_step "flutter analyze" flutter analyze
run_step "Flutter 非视觉测试" flutter test --exclude-tags golden
run_step "Pigeon 生成物漂移" ./tool/check_pigeon.sh

# —— macOS 半：golden、iOS 原生测试与构建 ——
if [ "$HOST_HALF" = "macos" ]; then
  # 与 ci.yml 一致：分叉检查只在 macOS job 跑（依赖 shasum，Git Bash 里没有）。
  run_step "video_player_android 分叉漂移" ./tool/check_video_player_android_fork.sh
  run_step "首页 golden 测试" flutter test test/home_golden_test.dart

  SIMULATOR_ID="$(
    xcrun simctl list devices available -j 2>/dev/null | python3 -c '
import json, sys
data = json.load(sys.stdin)
runtimes = {k: v for k, v in data.get("devices", {}).items() if ".iOS-" in k}
def order(name):
    return [int(part) for part in name.split(".")[-1].split("-")[1:]]
for runtime in sorted(runtimes, key=order, reverse=True):
    for device in runtimes[runtime]:
        if device.get("isAvailable"):
            print(device["udid"])
            sys.exit(0)
' || true
  )"

  if [ -n "$SIMULATOR_ID" ]; then
    run_step "RunnerTests（iOS 模拟器）" xcodebuild test \
      -workspace ios/Runner.xcworkspace \
      -scheme Runner \
      -destination "platform=iOS Simulator,id=${SIMULATOR_ID}" \
      -parallel-testing-enabled NO \
      CODE_SIGNING_ALLOWED=NO
  else
    skip_step "RunnerTests（iOS 模拟器）" "没有可用的 iOS 模拟器"
  fi

  run_step "iOS 免签名构建" flutter build ios --no-codesign
else
  skip_step "video_player_android 分叉漂移" "只在 macOS 上跑，与 ci.yml 一致"
  skip_step "首页 golden 测试" "只在 macOS 上跑，字体渲染有差异"
  skip_step "RunnerTests（iOS 模拟器）" "需要 macOS 与 Xcode"
  skip_step "iOS 免签名构建" "需要 macOS 与 Xcode"
fi

# —— Windows 半：Android 原生测试 ——
if [ "$HOST_HALF" = "windows" ]; then
  run_step "Android 原生单测" bash -c \
    "cd android && ./gradlew.bat :app:testDebugUnitTest :video_player_android:testDebugUnitTest --no-daemon"
else
  skip_step "Android 原生单测" "需要 Windows 编译机的 Java/Gradle 环境"
fi

echo ""
echo "======== 本地 CI 汇总 ========"
for item in "${PASSED[@]:-}"; do
  [ -n "$item" ] && echo "  通过   ${item}"
done
for item in "${SKIPPED[@]:-}"; do
  [ -n "$item" ] && echo "  跳过   ${item}"
done
for item in "${FAILED[@]:-}"; do
  [ -n "$item" ] && echo "  失败   ${item}"
done

if [ "${#FAILED[@]}" -gt 0 ]; then
  echo ""
  echo "本地 CI 未通过：${#FAILED[@]} 项失败"
  exit 1
fi

echo ""
echo "本机这一半的本地 CI 全部通过"
if [ "${#SKIPPED[@]}" -gt 0 ]; then
  echo "注意：上面列出的跳过项必须在另一台机器上补跑，发布门禁要求两半都通过"
fi
