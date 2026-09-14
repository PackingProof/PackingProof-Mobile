# Gitee 发布令牌的来源：仓库根目录 .env 的 GITEE_TOKEN（见 AGENTS.md）。
#
# 只把它注入当前进程环境交给 gitee CLI，不打印、不写盘、不提交。
# gitee CLI 优先使用 GITEE_TOKEN，其次才用它自己保存的登录态；登录态按身份字符串
# 各存一份，容易停在失效的旧身份上，而且 `gitee auth status` 在令牌失效时仍然返回 0，
# 所以发布脚本必须先注入 .env 里的令牌，不能只看 CLI 的登录状态。
#
# 被 Tools/Check-ReleasePrereqs.ps1 与 Tools/Publish-Releases.ps1 引用。

function Read-DotEnvValue {
    param(
        [Parameter(Mandatory = $true)] [string]$RepoRoot,
        [Parameter(Mandatory = $true)] [string]$Key
    )

    $envPath = Join-Path $RepoRoot ".env"
    if (-not (Test-Path -LiteralPath $envPath)) { return "" }

    foreach ($line in Get-Content -LiteralPath $envPath) {
        if ($line -match "^\s*$([regex]::Escape($Key))\s*=\s*(.*)$") {
            return $Matches[1].Trim().Trim('"').Trim("'")
        }
    }

    return ""
}

# 注入 Gitee 令牌，返回来源说明：环境变量 / .env / 空（空表示只能退回 CLI 登录态）。
function Import-GiteeTokenFromEnvFile {
    param([Parameter(Mandatory = $true)] [string]$RepoRoot)

    if (-not [string]::IsNullOrWhiteSpace($env:GITEE_TOKEN)) {
        return "环境变量"
    }

    $token = Read-DotEnvValue -RepoRoot $RepoRoot -Key "GITEE_TOKEN"
    if (-not [string]::IsNullOrWhiteSpace($token)) {
        $env:GITEE_TOKEN = $token
        return ".env"
    }

    return ""
}

# 真实只读调用，判断令牌是否真的可用；CLI 的登录状态不能代替这一步。
function Test-GiteeAuthentication {
    param(
        [Parameter(Mandatory = $true)] [string]$Repository,
        [Parameter(Mandatory = $true)] [string]$RepoRoot
    )

    # 自己负责注入 .env 的令牌，避免调用方忘记导入而回退到失效的 CLI 登录态。
    $null = Import-GiteeTokenFromEnvFile -RepoRoot $RepoRoot

    & gitee release list --repo $Repository *> $null
    return $LASTEXITCODE -eq 0
}
