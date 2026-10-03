#!/bin/sh
set -eu

repo_root="$(cd "$(dirname "$0")/.." && pwd)"

# 基线是"这个文件已经很大，别再持续涨"的锚点，不是精确行数红线：
# 默认留基线 2%（最少 20 行）的余量，小改动（加个 import、加个参数）只提示不拦，
# 真的持续膨胀才失败。
slack_for() {
  baseline="$1"
  slack=$((baseline / 50))
  if [ "$slack" -lt 20 ]; then
    slack=20
  fi
  echo "$slack"
}

check_limit() {
  relative_file="$1"
  baseline="$2"
  slack="${3:-$(slack_for "$baseline")}"
  limit=$((baseline + slack))
  absolute_file="${repo_root}/${relative_file}"
  if [ ! -f "$absolute_file" ]; then
    echo "大文件守门目标不存在：${relative_file}" >&2
    return 1
  fi

  actual_lines="$(awk 'END { print NR }' "$absolute_file")"
  if [ "$actual_lines" -gt "$limit" ]; then
    echo "${relative_file}: ${actual_lines} 行，超过基线 ${baseline} + 余量 ${slack} 行" >&2
    echo "  按职责拆分并同步下调基线，不要为新增代码提高基线；判定口径见 docs/code-architecture.md" >&2
    return 1
  fi
  if [ "$actual_lines" -gt "$baseline" ]; then
    echo "提示 ${relative_file}: ${actual_lines} 行，已用余量 $((actual_lines - baseline))/${slack} 行（未超限）"
  fi
}

if [ "${1:-}" = "--self-test" ]; then
  temporary_root="$(mktemp -d "${TMPDIR:-/tmp}/packingproof-large-file.XXXXXX")"
  trap 'rm -rf -- "$temporary_root"' EXIT
  repo_root="$temporary_root"
  printf 'one\ntwo\nthree\n' > "${repo_root}/fixture.txt"
  check_limit fixture.txt 3 0 >/dev/null
  if check_limit fixture.txt 2 0 2>/dev/null; then
    echo "大文件超限失败夹具未被拒绝" >&2
    exit 1
  fi
  # 默认余量：只超基线 1 行的小改动不该被拦。
  if ! check_limit fixture.txt 2 >/dev/null; then
    echo "默认余量没有生效，小改动仍被拦" >&2
    exit 1
  fi
  echo "大文件行数守门自测通过"
  exit 0
fi

# 职责拆分后应同步降低对应上限，不得为新增代码提高基线。
check_limit lib/screens/recordings_screen.dart 1482
check_limit ios/Runner/PigeonPlatform.swift 551
check_limit ios/Runner/IosOrderReceiverPlatform.swift 446
check_limit lib/controllers/packing_session_controller.dart 1657
check_limit android/app/src/main/kotlin/app/packingproof/mobile/ContinuousSegmentCamera.kt 2497
