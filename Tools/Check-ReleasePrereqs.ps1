# 发布前置条件自检：在花时间构建之前，先确认这台机器能走完它负责的那半发布流程。
#
#   pwsh -NoProfile -File Tools\Check-ReleasePrereqs.ps1
#
# 只读检查，不构建、不上传、不修改任何东西，也不打印凭据内容。
# 按当前机器实际具备的工具链分工，不假设 AI 固定在哪一台：
# 签名目录与渠道令牌在 Windows 上是阻断项，iOS 与 TestFlight 那半在 Mac 上（跑 Tools/Check-ReleasePrereqs.sh）；
# 不属于本机的那半只提示，并指出要去哪台机器跑（可走局域网 SSH）。
# 完整发布顺序见 docs/android-release.md。

$ErrorActionPreference = "Continue"

$repoRoot = Split-Path -Parent $PSScriptRoot
Set-Location $repoRoot

. (Join-Path $PSScriptRoot "GiteeAuth.Common.ps1")

$repoSlug = "PackingProof/PackingProof-Mobile"

$blockers = New-Object System.Collections.Generic.List[string]
$warnings = New-Object System.Collections.Generic.List[string]

# $IsMacOS / $IsLinux 只在 PowerShell 7+ 上存在；5.1 只跑在 Windows 上。
$hostKind = if (($PSVersionTable.PSVersion.Major -ge 6) -and $IsMacOS) { "macos" }
elseif (($PSVersionTable.PSVersion.Major -ge 6) -and $IsLinux) { "linux" }
else { "windows" }

function Write-Ok   { param([string]$Message) Write-Host "  [OK]   $Message" }
function Write-Fail { param([string]$Message) Write-Host "  [缺失] $Message"; $blockers.Add($Message) }
function Write-Warn { param([string]$Message) Write-Host "  [提示] $Message"; $warnings.Add($Message) }

# Android 侧工具链只在 Windows 上：本机不是 Windows 时缺这些属正常，只提示去另一台跑。
function Write-AndroidSide {
    param([string]$Message)
    if ($hostKind -eq "windows") { Write-Fail $Message }
    else { Write-Warn "$Message（Android 侧要到有 Android 工具链的 Windows 机器上跑，可走局域网 SSH）" }
}

Write-Host "发布前置条件自检"
Write-Host "仓库：$repoRoot"
Write-Host "机器：$hostKind"

Write-Host ""
Write-Host "== 仓库状态 =="
if (git status --porcelain --untracked-files=all) {
    Write-Fail "工作区不干净，发布脚本会拒绝执行（先提交或 git stash -u）"
}
else {
    Write-Ok "工作区干净"
}

$pubspecVersion = ""
$pubspecPath = Join-Path $repoRoot "pubspec.yaml"
if (Test-Path -LiteralPath $pubspecPath) {
    foreach ($line in Get-Content -LiteralPath $pubspecPath) {
        if ($line -match "^version:\s*(.+)$") { $pubspecVersion = $Matches[1].Trim(); break }
    }
}

if ([string]::IsNullOrWhiteSpace($pubspecVersion)) {
    Write-Fail "读不到 pubspec.yaml 里的 version"
}
else {
    $tag = (git describe --tags --exact-match 2>$null)
    if ([string]::IsNullOrWhiteSpace($tag)) {
        Write-Warn "当前提交没有精确 tag（pubspec.yaml 是 $pubspecVersion，发布前需建 v$pubspecVersion）"
    }
    elseif ($tag.Trim() -eq "v$pubspecVersion") {
        Write-Ok "当前提交的 tag $($tag.Trim()) 与 pubspec.yaml 一致"
    }
    else {
        Write-Fail "tag $($tag.Trim()) 与 pubspec.yaml 的 $pubspecVersion 不一致"
    }
}

Write-Host ""
Write-Host "== 本机配置 .env =="
if (Test-Path -LiteralPath (Join-Path $repoRoot ".env")) {
    Write-Ok ".env 存在"
}
else {
    Write-Fail ".env 不存在，先执行 cp .env.example .env 并填写"
}

Write-Host ""
Write-Host "== Android 发布（需要 Windows 工具链）=="
$signingDir = Read-DotEnvValue -RepoRoot $repoRoot -Key "PACKING_PROOF_SIGNING_DIRECTORY"
if ([string]::IsNullOrWhiteSpace($signingDir)) {
    Write-AndroidSide "缺少 PACKING_PROOF_SIGNING_DIRECTORY，Tools\Publish-Android.ps1 会直接失败"
}
elseif (Test-Path -LiteralPath $signingDir -PathType Container) {
    Write-Ok "签名目录已配置且存在"
}
else {
    Write-AndroidSide "PACKING_PROOF_SIGNING_DIRECTORY 指向的目录不存在"
}

Write-Host ""
Write-Host "== 发布渠道登录态（Release 在 Windows 侧创建）=="
if (Get-Command gh -ErrorAction SilentlyContinue) {
    gh auth status *> $null
    if ($LASTEXITCODE -eq 0) { Write-Ok "gh 已登录" }
    else { Write-AndroidSide "gh 未登录，执行 gh auth login" }
}
else {
    Write-AndroidSide "未安装 gh，GitHub Release 无法创建"
}

# Gitee 令牌固定来自 .env；`gitee auth status` 在令牌失效时仍返回 0，
# 所以这里做一次真实只读调用，避免构建完才发现认证不可用。
if (Get-Command gitee -ErrorAction SilentlyContinue) {
    $giteeTokenSource = Import-GiteeTokenFromEnvFile -RepoRoot $repoRoot
    $giteeTokenLabel = if ($giteeTokenSource) { $giteeTokenSource } else { "gitee CLI 登录态" }
    if (Test-GiteeAuthentication -Repository $repoSlug -RepoRoot $repoRoot) {
        Write-Ok "gitee 令牌可用（来源：$giteeTokenLabel）"
    }
    elseif ($giteeTokenSource) {
        Write-AndroidSide "gitee 令牌不可用（来源：$giteeTokenLabel），请核对 .env 的 GITEE_TOKEN"
    }
    else {
        Write-AndroidSide "gitee 不可用：.env 里没有 GITEE_TOKEN，gitee CLI 登录态也不可用"
    }
}
else {
    Write-AndroidSide "未安装 gitee CLI，Gitee Release 无法创建"
}

Write-Host ""
Write-Host "== 工具链 =="
if (Get-Command flutter -ErrorAction SilentlyContinue) {
    $flutterVersion = (& flutter --version 2>$null | Select-Object -First 1)
    Write-Ok "flutter 可用（$flutterVersion）"
}
else {
    Write-Fail "找不到 flutter"
}

if ($PSVersionTable.PSVersion.Major -ge 7) {
    Write-Ok "PowerShell $($PSVersionTable.PSVersion) 可用"
}
else {
    Write-Warn "当前是 Windows PowerShell $($PSVersionTable.PSVersion)，发布脚本按 PowerShell 7 编写，建议用 pwsh 执行"
}

Write-Host ""
if ($hostKind -eq "macos") {
    Write-Host "== iOS 与 TestFlight（本机具备 iOS 工具链）=="
    Write-Warn "本机是 macOS：iOS 侧直接跑 ./Tools/Check-ReleasePrereqs.sh 自检（TestFlight 凭据在那半边是阻断项）"
}
else {
    Write-Host "== iOS 与 TestFlight（需要 macOS + Xcode）=="
    Write-Warn "本机没有 iOS 工具链：iOS 与 TestFlight 那半要到 Mac 上跑 Tools/Check-ReleasePrereqs.sh，可走局域网 SSH，不要因为本机不是 Mac 就跳过"
}

Write-Host ""
Write-Host "======== 自检汇总 ========"
if ($warnings.Count -gt 0) {
    Write-Host "提示（不阻断）："
    foreach ($item in $warnings) { Write-Host "  - $item" }
}

if ($blockers.Count -gt 0) {
    Write-Host ""
    Write-Host "阻断项 $($blockers.Count) 个，必须先解决："
    foreach ($item in $blockers) { Write-Host "  - $item" }
    Write-Host ""
    Write-Host "凭据类缺失看 .env.example 的说明；流程看 docs/android-release.md"
    exit 1
}

Write-Host ""
Write-Host "本机发布前置条件齐备"
Write-Host "下一步：./Tools/test-ci.sh 跑本地 CI 门禁（Git Bash），或直接执行 Tools\Publish-Android.ps1 构建"
