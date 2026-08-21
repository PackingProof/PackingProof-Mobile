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

    function language_for(path) {
      if (path ~ /\.dart$/) return "dart"
      if (path ~ /\.swift$/) return "swift"
      if (path ~ /\.kt$/) return "kotlin"
      return ""
    }

    function is_generated(path, normalized) {
      normalized = tolower(path)
      return normalized ~ /(^|\/)generated\// ||
        normalized ~ /\.(g|freezed|mocks)\.dart$/
    }

    function strip_comments(line, block_start, block_end, line_comment, prefix) {
      result = ""
      while (1) {
        if (in_block_comment) {
          block_end = index(line, "*/")
          if (!block_end) return result
          line = substr(line, block_end + 2)
          in_block_comment = 0
        }

        block_start = index(line, "/*")
        line_comment = index(line, "//")
        if (line_comment && (!block_start || line_comment < block_start)) {
          return result substr(line, 1, line_comment - 1)
        }
        if (!block_start) return result line

        prefix = substr(line, 1, block_start - 1)
        result = result prefix
        line = substr(line, block_start + 2)
        in_block_comment = 1
      }
    }

    function is_broad_catch(line, tail, typed) {
      if (language == "dart") {
        if (line ~ /on[[:space:]]+(Object|Exception|dynamic)[[:space:]]*(catch|\{)/) {
          return 1
        }
        typed = line ~ /on[[:space:]]+[A-Za-z0-9_.<>]+[[:space:]]+catch/
        return line ~ /catch[[:space:]]*\(/ && !typed
      }
      if (language == "kotlin") {
        return line ~ /catch[[:space:]]*\([^)]*:[[:space:]]*((kotlin|java\.lang)\.)?(Throwable|Exception)[?[:space:]]*\)/
      }
      if (language == "swift" && match(line, /(^|[^A-Za-z0-9_])catch([^A-Za-z0-9_]|$)/)) {
        tail = substr(line, RSTART + RLENGTH - 1)
        sub(/^[[:space:]]*/, "", tail)
        return tail == "" || tail ~ /^\{/ || tail ~ /^_[[:space:]]*(\{|$)/ ||
          tail ~ /^(let|var)[[:space:]]+[A-Za-z_][A-Za-z0-9_]*[[:space:]]*(\{|$|where)/ ||
          tail ~ /^(let|var)[[:space:]]+[A-Za-z_][A-Za-z0-9_]*[[:space:]]+as[[:space:]]+(any[[:space:]]+)?Error[[:space:]]*(\{|$|where)/
      }
      return 0
    }

    function explains_handling(line) {
      return line ~ /\/\/[[:space:]]*broad-catch:[[:space:]]*[^[:space:]]/ ||
        line ~ /(^|[^A-Za-z0-9_])([A-Za-z0-9_]*[Ll]ogger|[A-Za-z0-9_]*[Ll]og)\.[A-Za-z0-9_]+[[:space:]]*\(/ ||
        line ~ /(^|[^A-Za-z0-9_])(developer\.log|os_log|NSLog)[[:space:]]*\(/ ||
        line ~ /debugPrint[[:space:]]*\(/ ||
        line ~ /(completeError|addError|resumeWithException)[[:space:]]*\(/ ||
        line ~ /Result\.failure[[:space:]]*\(/ ||
        (language == "swift" &&
          line ~ /(^|[^A-Za-z0-9_])completion[[:space:]]*\([[:space:]]*\.failure[[:space:]]*\(/) ||
        line ~ /(^|[^A-Za-z])(throw|rethrow)([^A-Za-z]|$)/
    }

    /^diff --git / {
      flush_pending()
      file = ""
      language = ""
      skip_file = 1
      previous_source = ""
      in_block_comment = 0
      next
    }
    /^\+\+\+ b\// {
      file = substr($0, 7)
      language = language_for(file)
      skip_file = language == "" || is_generated(file)
      next
    }
    /^@@ / {
      flush_pending()
      header = $0
      sub(/^.*\+/, "", header)
      sub(/[, ].*$/, "", header)
      next_line = header + 0
      previous_source = ""
      in_block_comment = 0
      next
    }
    /^-/ { next }
    /^[ +]/ {
      source = substr($0, 2)
      source_line = next_line++
      code = strip_comments(source)

      if (skip_file) {
        previous_source = source
        next
      }

      if (pending) {
        if (explains_handling(source)) {
          handled = 1
        }
        remaining--
        if (remaining <= 0) {
          flush_pending()
        }
      }

      if (substr($0, 1, 1) == "+" && is_broad_catch(code)) {
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
diff --git a/android/app/src/main/kotlin/app/packingproof/mobile/Good.kt b/android/app/src/main/kotlin/app/packingproof/mobile/Good.kt
--- a/android/app/src/main/kotlin/app/packingproof/mobile/Good.kt
+++ b/android/app/src/main/kotlin/app/packingproof/mobile/Good.kt
@@ -1,0 +1,3 @@
+try {
+} catch (error: Throwable) {
+  Log.e("Good", "failed", error)
diff --git a/android/app/src/main/kotlin/app/packingproof/mobile/SafeFallback.kt b/android/app/src/main/kotlin/app/packingproof/mobile/SafeFallback.kt
--- a/android/app/src/main/kotlin/app/packingproof/mobile/SafeFallback.kt
+++ b/android/app/src/main/kotlin/app/packingproof/mobile/SafeFallback.kt
@@ -1,0 +1,3 @@
+try {
+} catch (_: Exception) {
+  // broad-catch: The optional cache may safely remain empty.
diff --git a/ios/Runner/Good.swift b/ios/Runner/Good.swift
--- a/ios/Runner/Good.swift
+++ b/ios/Runner/Good.swift
@@ -1,0 +1,3 @@
+do {
+} catch {
+  logger.error("failed: \(error)")
diff --git a/ios/Runner/Propagated.swift b/ios/Runner/Propagated.swift
--- a/ios/Runner/Propagated.swift
+++ b/ios/Runner/Propagated.swift
@@ -1,0 +1,3 @@
+do {
+} catch {
+  throw error
diff --git a/ios/Runner/CompletionPropagated.swift b/ios/Runner/CompletionPropagated.swift
--- a/ios/Runner/CompletionPropagated.swift
+++ b/ios/Runner/CompletionPropagated.swift
@@ -1,0 +1,4 @@
+do {
+} catch {
+  completion(.failure(error))
+  return
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
  if check_diff_stream 2>/dev/null <<'EOF'
diff --git a/android/app/src/main/kotlin/app/packingproof/mobile/Bad.kt b/android/app/src/main/kotlin/app/packingproof/mobile/Bad.kt
--- a/android/app/src/main/kotlin/app/packingproof/mobile/Bad.kt
+++ b/android/app/src/main/kotlin/app/packingproof/mobile/Bad.kt
@@ -1,0 +1,3 @@
+try {
+} catch (error: Exception) {
+  return
EOF
  then
    echo "Kotlin 宽泛 catch 失败夹具未被拒绝" >&2
    exit 1
  fi
  if check_diff_stream 2>/dev/null <<'EOF'
diff --git a/ios/Runner/Bad.swift b/ios/Runner/Bad.swift
--- a/ios/Runner/Bad.swift
+++ b/ios/Runner/Bad.swift
@@ -1,0 +1,3 @@
+do {
+} catch let error {
+  return
EOF
  then
    echo "Swift 宽泛 catch 失败夹具未被拒绝" >&2
    exit 1
  fi
  if check_diff_stream 2>/dev/null <<'EOF'
diff --git a/ios/Runner/BadSuccess.swift b/ios/Runner/BadSuccess.swift
--- a/ios/Runner/BadSuccess.swift
+++ b/ios/Runner/BadSuccess.swift
@@ -1,0 +1,4 @@
+do {
+} catch {
+  completion(.success(()))
+  return
EOF
  then
    echo "Swift completion 成功值不应被视为错误传播" >&2
    exit 1
  fi
  if check_diff_stream 2>/dev/null <<'EOF'
diff --git a/lib/bad_without_variable.dart b/lib/bad_without_variable.dart
--- a/lib/bad_without_variable.dart
+++ b/lib/bad_without_variable.dart
@@ -1,0 +1,3 @@
+try {
+} on Object {
+  return null;
EOF
  then
    echo "无变量宽泛 catch 失败夹具未被拒绝" >&2
    exit 1
  fi
  check_diff_stream <<'EOF'
diff --git a/lib/comment.dart b/lib/comment.dart
--- a/lib/comment.dart
+++ b/lib/comment.dart
@@ -1,0 +1,2 @@
+// } catch (error) {
+/* } on Object catch (error) { */
+/*
+} catch (error) {
+*/
diff --git a/lib/narrow.dart b/lib/narrow.dart
--- a/lib/narrow.dart
+++ b/lib/narrow.dart
@@ -1,0 +1,2 @@
+try {
+} on FormatException catch (error) {
diff --git a/android/app/src/main/kotlin/app/packingproof/mobile/Comment.kt b/android/app/src/main/kotlin/app/packingproof/mobile/Comment.kt
--- a/android/app/src/main/kotlin/app/packingproof/mobile/Comment.kt
+++ b/android/app/src/main/kotlin/app/packingproof/mobile/Comment.kt
@@ -1,0 +1,2 @@
+// } catch (error: Throwable) {
+/* } catch (error: Exception) { */
diff --git a/android/app/src/main/kotlin/app/packingproof/mobile/Narrow.kt b/android/app/src/main/kotlin/app/packingproof/mobile/Narrow.kt
--- a/android/app/src/main/kotlin/app/packingproof/mobile/Narrow.kt
+++ b/android/app/src/main/kotlin/app/packingproof/mobile/Narrow.kt
@@ -1,0 +1,2 @@
+try {
+} catch (error: IOException) {
diff --git a/ios/Runner/Comment.swift b/ios/Runner/Comment.swift
--- a/ios/Runner/Comment.swift
+++ b/ios/Runner/Comment.swift
@@ -1,0 +1,2 @@
+// } catch {
+/* } catch let error { */
diff --git a/ios/Runner/Narrow.swift b/ios/Runner/Narrow.swift
--- a/ios/Runner/Narrow.swift
+++ b/ios/Runner/Narrow.swift
@@ -1,0 +1,2 @@
+do {
+} catch NetworkError.offline {
diff --git a/android/app/src/main/kotlin/app/packingproof/mobile/generated/PlatformApi.kt b/android/app/src/main/kotlin/app/packingproof/mobile/generated/PlatformApi.kt
--- a/android/app/src/main/kotlin/app/packingproof/mobile/generated/PlatformApi.kt
+++ b/android/app/src/main/kotlin/app/packingproof/mobile/generated/PlatformApi.kt
@@ -1,0 +1,2 @@
+try {
+} catch (exception: Throwable) {
diff --git a/ios/Runner/Generated/PlatformApi.swift b/ios/Runner/Generated/PlatformApi.swift
--- a/ios/Runner/Generated/PlatformApi.swift
+++ b/ios/Runner/Generated/PlatformApi.swift
@@ -1,0 +1,2 @@
+do {
+} catch {
diff --git a/lib/platform/generated/platform_api.g.dart b/lib/platform/generated/platform_api.g.dart
--- a/lib/platform/generated/platform_api.g.dart
+++ b/lib/platform/generated/platform_api.g.dart
@@ -1,0 +1,2 @@
+try {
+} catch (error) {
EOF
  echo "宽泛 catch 守门自测通过"
  exit 0
fi

cd "$(dirname "$0")/.."

readonly broad_catch_baseline="1f8966c8cc8f6b8dc3220d272d89dfd39aaee37a"
readonly native_broad_catch_baseline="bc884cbe7e37d5512732c14021e403c1677dbe5a"
base_ref="${1:-}"
case "$base_ref" in
  ""|0000000000000000000000000000000000000000)
    base_ref="$(git rev-list --max-parents=0 HEAD | tail -n 1)"
    ;;
esac
requested_base_commit="$(git rev-parse --verify "${base_ref}^{commit}")"
dart_base_commit="$requested_base_commit"
if git merge-base --is-ancestor "$dart_base_commit" "$broad_catch_baseline"; then
  dart_base_commit="$broad_catch_baseline"
fi
native_base_commit="$requested_base_commit"
if git merge-base --is-ancestor "$native_base_commit" "$native_broad_catch_baseline"; then
  native_base_commit="$native_broad_catch_baseline"
fi

{
  git diff --no-ext-diff --unified=12 "${dart_base_commit}...HEAD" -- '*.dart'
  git diff --no-ext-diff --unified=12 "${native_base_commit}...HEAD" -- '*.swift' '*.kt'
} |
  check_diff_stream
