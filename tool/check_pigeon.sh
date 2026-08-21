#!/bin/sh
set -eu

cd "$(dirname "$0")/.."
./tool/generate_pigeon.sh
git -c core.autocrlf=false diff --ignore-cr-at-eol --exit-code -- \
  pigeons/platform.dart \
  lib/platform/generated/platform_api.g.dart \
  android/app/src/main/kotlin/app/packingproof/mobile/generated/PlatformApi.kt \
  ios/Runner/Generated/PlatformApi.swift
