#!/bin/sh
set -eu

check_diff_stream() {
  awk '
    function flush_pending() {
      if (pending && !handled) {
        printf "%s:%d: 新增宽泛 catch 缺少日志、错误传播或 // broad-catch: 原因说明\n", file, catch_line > "/dev/stderr"
        failed = 1
      }
      pending = 0
      handled = 0
      remaining = 0
    }

    function is_broad_catch(line, typed) {
      if (line ~ /on[[:space:]]+(Object|Exception|dynamic)[[:space:]]+catch/) {
        return 1
      }
      typed = line ~ /on[[:space:]]+[A-Za-z0-9_.<>]+[[:space:]]+catch/
      return line ~ /catch[[:space:]]*\(/ && !typed
    }

    function explains_handling(line) {
      return line ~ /\/\/[[:space:]]*broad-catch:[[:space:]]*[^[:space:]]/ ||
        line ~ /[A-Za-z0-9_.]*[Ll]og[A-Za-z0-9_]*[[:space:]]*\(/ ||
        line ~ /debugPrint[[:space:]]*\(/ ||
        line ~ /completeError[[:space:]]*\(/ ||
        line ~ /(^|[^A-Za-z])(throw|rethrow)([^A-Za-z]|$)/
    }

    /^diff --git / {
      flush_pending()
      file = ""
      previous_source = ""
      next
    }
    /^\+\+\+ b\// {
      file = substr($0, 7)
      next
    }
    /^@@ / {
      flush_pending()
      header = $0
      sub(/^.*\+/, "", header)
      sub(/[, ].*$/, "", header)
      next_line = header + 0
      previous_source = ""
      next
    }
    /^-/ { next }
    /^[ +]/ {
      source = substr($0, 2)
      source_line = next_line++

      if (pending) {
        if (explains_handling(source)) {
          handled = 1
        }
        remaining--
        if (remaining <= 0) {
          flush_pending()
        }
      }

      if (substr($0, 1, 1) == "+" && is_broad_catch(source)) {
        flush_pending()
        pending = 1
        catch_line = source_line
        remaining = 12
        handled = explains_handling(previous_source) || explains_handling(source)
      }
      previous_source = source
    }
    END {
      flush_pending()
      exit failed
    }
  '
}

if [ "${1:-}" = "--self-test" ]; then
  check_diff_stream <<'EOF'
diff --git a/lib/good.dart b/lib/good.dart
--- a/lib/good.dart
+++ b/lib/good.dart
@@ -1,0 +1,3 @@
+try {
+} on Object catch (error) {
+  developer.log('failed', error: error);
EOF

  if check_diff_stream 2>/dev/null <<'EOF'
diff --git a/lib/bad.dart b/lib/bad.dart
--- a/lib/bad.dart
+++ b/lib/bad.dart
@@ -1,0 +1,3 @@
+try {
+} catch (error) {
+  return null;
EOF
  then
    echo "宽泛 catch 失败夹具未被拒绝" >&2
    exit 1
  fi
  echo "宽泛 catch 守门自测通过"
  exit 0
fi

cd "$(dirname "$0")/.."

readonly broad_catch_baseline="1f8966c8cc8f6b8dc3220d272d89dfd39aaee37a"
base_ref="${1:-}"
case "$base_ref" in
  ""|0000000000000000000000000000000000000000)
    base_ref="$(git rev-list --max-parents=0 HEAD | tail -n 1)"
    ;;
esac
base_commit="$(git rev-parse --verify "${base_ref}^{commit}")"
if git merge-base --is-ancestor "$base_commit" "$broad_catch_baseline"; then
  base_commit="$broad_catch_baseline"
fi

git diff --no-ext-diff --unified=12 "${base_commit}...HEAD" -- \
  '*.dart' \
  ':(exclude)lib/platform/generated/**' |
  check_diff_stream
