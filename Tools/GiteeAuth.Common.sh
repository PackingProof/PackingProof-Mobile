#!/bin/bash
# Gitee 发布令牌的来源：仓库根目录 .env 的 GITEE_TOKEN（见 AGENTS.md）。
#
# 只把它导出到当前进程环境交给 gitee CLI，不打印、不写盘、不提交。
# gitee CLI 优先使用 GITEE_TOKEN，其次才用它自己保存的登录态；登录态按身份字符串
# 各存一份，容易停在失效的旧身份上，而且 `gitee auth status` 在令牌失效时仍然返回 0，
# 所以发布脚本必须先导出 .env 里的令牌，不能只看 CLI 的登录状态。
#
# 被 Tools/Check-ReleasePrereqs.sh 与 Tools/Publish-Releases.sh 引用；
# 两处都会先切到仓库根目录，因此这里直接读当前目录下的 .env。

# 读取 .env 里某个键的值；缺文件或缺键时输出空。
read_dotenv() {
  local key="$1"
  [ -f .env ] || return 0
  sed -n "s/^[[:space:]]*${key}[[:space:]]*=[[:space:]]*//p" .env |
    head -n 1 |
    sed -e 's/[[:space:]]*$//' -e 's/^"\(.*\)"$/\1/' -e "s/^'\(.*\)'$/\1/"
}

# 导出 Gitee 令牌，来源写进全局 GITEE_TOKEN_SOURCE：环境变量 / .env / 空。
# 不要用 $(import_gitee_token) 调用：命令替换在子 shell 里执行，export 会丢失。
import_gitee_token() {
  GITEE_TOKEN_SOURCE=''

  if [ -n "${GITEE_TOKEN:-}" ]; then
    GITEE_TOKEN_SOURCE='环境变量'
    return 0
  fi

  local token
  token="$(read_dotenv GITEE_TOKEN)"
  if [ -n "$token" ]; then
    export GITEE_TOKEN="$token"
    GITEE_TOKEN_SOURCE='.env'
  fi
}

# 真实只读调用，判断令牌是否真的可用；CLI 的登录状态不能代替这一步。
test_gitee_authentication() {
  local repo="$1"
  gitee release list --repo "$repo" >/dev/null 2>&1
}
