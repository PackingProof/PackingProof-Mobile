#!/bin/sh
set -eu

cd "$(dirname "$0")/.."
dart run pigeon --input pigeons/platform.dart
git diff --exit-code -- \
  pigeons/platform.dart \
  lib/platform/generated/platform_api.g.dart \
  android/app/src/main/kotlin/app/packingproof/mobile/generated/PlatformApi.kt \
  ios/Runner/Generated/PlatformApi.swift
