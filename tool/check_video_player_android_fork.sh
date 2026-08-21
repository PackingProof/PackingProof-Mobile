#!/usr/bin/env bash
set -euo pipefail

readonly upstream_version="2.12.0"
readonly upstream_commit="d3de31ab3425f52afbc7c54a681ec3d93632baf6"

script_dir="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
repo_root="$(cd "${script_dir}/.." && pwd)"
fork_dir="${repo_root}/plugins/video_player_android"
temporary_root=""

cleanup() {
  if [[ -n "${temporary_root}" && -d "${temporary_root}" ]]; then
    rm -rf -- "${temporary_root}"
  fi
}
trap cleanup EXIT

upstream_dir="${VIDEO_PLAYER_ANDROID_UPSTREAM_DIR:-}"
if [[ -z "${upstream_dir}" ]]; then
  temporary_root="$(mktemp -d "${TMPDIR:-/tmp}/packingproof-video-player.XXXXXX")"
  archive="${temporary_root}/flutter-packages.tar.gz"
  curl --fail --location --silent --show-error \
    "https://github.com/flutter/packages/archive/${upstream_commit}.tar.gz" \
    --output "${archive}"
  tar -xzf "${archive}" -C "${temporary_root}"
  upstream_dir="${temporary_root}/packages-${upstream_commit}/packages/video_player/video_player_android"
fi

if [[ ! -f "${upstream_dir}/pubspec.yaml" ]]; then
  echo "找不到上游 video_player_android 目录：${upstream_dir}" >&2
  exit 1
fi

if ! grep -qx "version: ${upstream_version}" "${upstream_dir}/pubspec.yaml"; then
  echo "上游目录版本不是 ${upstream_version}" >&2
  exit 1
fi

is_ignored_upstream_path() {
  case "$1" in
    android/src/test/*|example/*|pigeons/*|test/*) return 0 ;;
    *) return 1 ;;
  esac
}

is_local_patch_path() {
  case "$1" in
    pubspec.yaml|\
    android/src/main/java/io/flutter/plugins/videoplayer/HuaweiCompatibility.java|\
    android/src/main/java/io/flutter/plugins/videoplayer/platformview/PlatformViewVideoPlayer.java|\
    android/src/main/java/io/flutter/plugins/videoplayer/texture/TextureVideoPlayer.java|\
    android/src/test/java/io/flutter/plugins/videoplayer/HuaweiCompatibilityTest.java|\
    LOCAL_PATCH.md|LOCAL_PATCH.sha256) return 0 ;;
    *) return 1 ;;
  esac
}

failed=0
while IFS= read -r -d '' upstream_file; do
  relative_path="${upstream_file#"${upstream_dir}/"}"
  if is_ignored_upstream_path "${relative_path}" || is_local_patch_path "${relative_path}"; then
    continue
  fi
  local_file="${fork_dir}/${relative_path}"
  if [[ ! -f "${local_file}" ]]; then
    echo "本地 fork 缺少上游文件：${relative_path}" >&2
    failed=1
  elif ! cmp -s "${upstream_file}" "${local_file}"; then
    echo "检测到未登记的上游漂移：${relative_path}" >&2
    failed=1
  fi
done < <(find "${upstream_dir}" -type f -print0)

while IFS= read -r -d '' local_file; do
  relative_path="${local_file#"${fork_dir}/"}"
  if is_local_patch_path "${relative_path}"; then
    continue
  fi
  if [[ ! -f "${upstream_dir}/${relative_path}" ]]; then
    echo "检测到未登记的本地文件：${relative_path}" >&2
    failed=1
  fi
done < <(find "${fork_dir}" -type f -print0)

if ! (cd "${fork_dir}" && shasum -a 256 -c LOCAL_PATCH.sha256); then
  failed=1
fi

if [[ "${failed}" -ne 0 ]]; then
  echo "video_player_android fork 漂移检查失败" >&2
  exit 1
fi

echo "video_player_android fork 与 ${upstream_version} (${upstream_commit}) 基线一致"
