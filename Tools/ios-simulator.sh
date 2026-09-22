#!/bin/bash
# 解析并准备好一台可用于 RunnerTests 的 iOS 模拟器。
#
# 模拟器没启动时 xcodebuild 只会抛出难读的启动失败，容易被误判成用例失败；
# 所以发布与 CI 入口都要在跑测试之前先把模拟器启动并等到就绪。
#
# 用法：SIMULATOR_ID="$(prepare_ios_simulator)" || exit 1
# 成功时把 UDID 打印到 stdout，过程说明打印到 stderr。

prepare_ios_simulator() {
  local simulator_id
  simulator_id="$(
    xcrun simctl list devices available -j |
      python3 -c 'import json, sys
data = json.load(sys.stdin)["devices"]
devices = [device for runtime in data.values() for device in runtime]
booted = next((device for device in devices if device.get("state") == "Booted"), None)
selected = booted or (devices[0] if devices else None)
if selected is None:
    raise SystemExit("没有可用的 iOS 模拟器")
print(selected["udid"])' 2>/dev/null
  )"
  if [[ -z "$simulator_id" ]]; then
    echo "没有可用的 iOS 模拟器，请先在 Xcode 里安装一台 iPhone 模拟器" >&2
    return 1
  fi

  echo "准备 iOS 模拟器 ${simulator_id}（未启动时会自动启动并等待就绪）" >&2
  if ! xcrun simctl bootstatus "$simulator_id" -b >/dev/null 2>&1; then
    echo "iOS 模拟器 ${simulator_id} 无法启动，请先在 Xcode 里手动启动一次再重试" >&2
    return 1
  fi
  if ! xcrun simctl list devices booted | grep -q "$simulator_id"; then
    echo "iOS 模拟器 ${simulator_id} 未处于启动状态，无法运行 RunnerTests" >&2
    return 1
  fi

  printf '%s\n' "$simulator_id"
}
