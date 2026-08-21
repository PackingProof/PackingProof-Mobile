#!/bin/sh
set -eu

repo_root="$(cd "$(dirname "$0")/.." && pwd)"

check_limit() {
  relative_file="$1"
  maximum_lines="$2"
  absolute_file="${repo_root}/${relative_file}"
  if [ ! -f "$absolute_file" ]; then
    echo "大文件守门目标不存在：${relative_file}" >&2
    return 1
  fi

  actual_lines="$(awk 'END { print NR }' "$absolute_file")"
  if [ "$actual_lines" -gt "$maximum_lines" ]; then
    echo "${relative_file}: ${actual_lines} 行，超过基线 ${maximum_lines} 行" >&2
    return 1
  fi
}

if [ "${1:-}" = "--self-test" ]; then
  temporary_root="$(mktemp -d "${TMPDIR:-/tmp}/packingproof-large-file.XXXXXX")"
  trap 'rm -rf -- "$temporary_root"' EXIT
  repo_root="$temporary_root"
  printf 'one\ntwo\nthree\n' > "${repo_root}/fixture.txt"
  check_limit fixture.txt 3
  if check_limit fixture.txt 2 2>/dev/null; then
    echo "大文件超限失败夹具未被拒绝" >&2
    exit 1
  fi
  echo "大文件行数守门自测通过"
  exit 0
fi

# 职责拆分后应同步降低对应上限，不得为新增代码提高基线。
check_limit lib/screens/recordings_screen.dart 3806
check_limit ios/Runner/PigeonPlatform.swift 1075
check_limit lib/controllers/packing_session_controller.dart 2806
check_limit android/app/src/main/kotlin/app/packingproof/mobile/ContinuousSegmentCamera.kt 2541
