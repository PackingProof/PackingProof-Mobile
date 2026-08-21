#!/bin/sh
set -eu

normalize_kotlin_stream() {
  awk '
    {
      had_carriage_return = sub(/\r$/, "")
      sub(/[ \t]+$/, "")
      printf "%s%s\n", $0, had_carriage_return ? "\r" : ""
    }
  '
}

normalize_kotlin_file() {
  file="$1"
  temporary_file="$(mktemp "${file}.tmp.XXXXXX")"
  normalize_kotlin_stream < "$file" > "$temporary_file"
  if cmp -s "$file" "$temporary_file"; then
    rm "$temporary_file"
  else
    mv "$temporary_file" "$file"
  fi
}

if [ "${1:-}" = "--self-test" ]; then
  actual="$(printf 'internal  spaces\ntrailing \t\n' | normalize_kotlin_stream)"
  expected="$(printf 'internal  spaces\ntrailing\n')"
  if [ "$actual" != "$expected" ]; then
    echo "Pigeon Kotlin 空白规范化失败" >&2
    exit 1
  fi

  actual_hex="$(printf 'windows \t\r\n' | normalize_kotlin_stream | od -An -tx1 | tr -d ' \n')"
  if [ "$actual_hex" != "77696e646f77730d0a" ]; then
    echo "Pigeon Kotlin 空白规范化未保留 CRLF" >&2
    exit 1
  fi
  echo "Pigeon Kotlin 空白规范化自测通过"
  exit 0
fi

cd "$(dirname "$0")/.."
dart run pigeon --input pigeons/platform.dart
normalize_kotlin_file android/app/src/main/kotlin/app/packingproof/mobile/generated/PlatformApi.kt
