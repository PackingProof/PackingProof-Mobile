#!/bin/sh
set -eu

cd "$(dirname "$0")/.."

base_ref="${1:-}"
case "$base_ref" in
  ""|0000000000000000000000000000000000000000)
    base_ref="$(git rev-list --max-parents=0 HEAD | tail -n 1)"
    ;;
esac

base_commit="$(git rev-parse --verify "${base_ref}^{commit}")"

git diff --check "${base_commit}...HEAD" -- .
