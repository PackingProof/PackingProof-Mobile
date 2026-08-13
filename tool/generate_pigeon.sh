#!/bin/sh
set -eu

cd "$(dirname "$0")/.."
dart run pigeon --input pigeons/platform.dart
