#!/bin/sh
set -eu

repo_root="$(cd "$(dirname "$0")/.." && pwd)"

# 这里只做提示，不阻断合并：基线是"这个文件已经很大，建议别再涨"的锚点，
# 而不是硬红线。默认余量取基线 2%（最少 20 行），用掉余量或超过余量都只打印
# 建议，退出码始终为 0。判定口径见 docs/code-architecture.md。
slack_for() {
  baseline="$1"
  slack=$((baseline / 50))
  if [ "$slack" -lt 20 ]; then
    slack=20
  fi
  echo "$slack"
}

report_limit() {
  relative_file="$1"
  baseline="$2"
  slack="${3:-$(slack_for "$baseline")}"
  limit=$((baseline + slack))
  absolute_file="${repo_root}/${relative_file}"
  if [ ! -f "$absolute_file" ]; then
    echo "提示 清单里的 ${relative_file} 不存在，请核对 tool/check_large_file_limits.sh"
    return 0
  fi

  actual_lines="$(awk 'END { print NR }' "$absolute_file")"
  if [ "$actual_lines" -gt "$limit" ]; then
    echo "提示 ${relative_file}: ${actual_lines} 行，已超过基线 ${baseline} + 余量 ${slack} 行；建议按职责拆分并同步下调基线（不阻断合并，口径见 docs/code-architecture.md）"
    return 0
  fi
  if [ "$actual_lines" -gt "$baseline" ]; then
    echo "提示 ${relative_file}: ${actual_lines} 行，已用余量 $((actual_lines - baseline))/${slack} 行（未超限）"
  fi
  return 0
}

if [ "${1:-}" = "--self-test" ]; then
  temporary_root="$(mktemp -d "${TMPDIR:-/tmp}/packingproof-large-file.XXXXXX")"
  trap 'rm -rf -- "$temporary_root"' EXIT
  repo_root="$temporary_root"
  printf 'one\ntwo\nthree\n' > "${repo_root}/fixture.txt"
  # 超过基线 + 余量：只提示，不再阻断。
  output="$(report_limit fixture.txt 1 0)"
  case "$output" in
    *"已超过基线"*) ;;
    *) echo "大文件超限时应打印拆分建议" >&2; exit 1 ;;
  esac
  # 超基线但在余量内的小改动：提示用掉多少余量。
  output="$(report_limit fixture.txt 2)"
  case "$output" in
    *"已用余量"*) ;;
    *) echo "小改动应提示已用余量" >&2; exit 1 ;;
  esac
  # 未超基线：静默。
  if [ -n "$(report_limit fixture.txt 4 0)" ]; then
    echo "未超基线不应输出提示" >&2
    exit 1
  fi
  echo "大文件行数提示自测通过"
  exit 0
fi

# 职责拆分后应同步降低对应基线，不要为了新增代码抬高基线。
report_limit lib/screens/recordings_screen.dart 1482
report_limit ios/Runner/PigeonPlatform.swift 551
report_limit ios/Runner/IosOrderReceiverPlatform.swift 446
report_limit lib/controllers/packing_session_controller.dart 1657
report_limit android/app/src/main/kotlin/app/packingproof/mobile/ContinuousSegmentCamera.kt 2497
