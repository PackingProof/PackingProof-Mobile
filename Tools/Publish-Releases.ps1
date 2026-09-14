# 把当前 tag 的 Android APK 发布到 GitHub 与 Gitee Release（Windows 编译机入口）。
#
#   pwsh -NoProfile -File Tools\Publish-Releases.ps1 <release-notes-file> [-Title "<一句话内容>"] [-Prerelease]
#
# 也可以双击仓库根目录的「双击发布Release.bat」。
#
# 约定：
# - 只上传 Android APK，iOS 走 TestFlight（Mac 上执行 Tools/Upload-TestFlight.sh），不附 IPA
# - APK 必须已经由 Tools/Publish-Android.ps1 生成在 dist/android/ 下，不需要跨机拷贝
# - 标题固定 `v<X.Y.Z+VVVV> <一句话内容>`，两个平台内容保持一致
# - GitHub 用 gh、Gitee 用 gitee CLI；Gitee 令牌固定取 .env 的 GITEE_TOKEN
#   注入环境变量后交给 CLI，脚本不打印也不落盘凭据
# - Tools/Publish-Releases.sh 是 Mac 上的等价实现，改动其一时必须同步另一处

param(
    [Parameter(Mandatory = $true, Position = 0)]
    [string]$NotesFile,
    [string]$Title = "",
    [switch]$Prerelease
)

$ErrorActionPreference = "Stop"

$repoRoot = Split-Path -Parent $PSScriptRoot
Set-Location $repoRoot

. (Join-Path $PSScriptRoot "GiteeAuth.Common.ps1")

$repoSlug = "PackingProof/PackingProof-Mobile"

if (-not (Test-Path -LiteralPath $NotesFile -PathType Leaf)) {
    throw "找不到发布笔记：$NotesFile`n用法：pwsh -NoProfile -File Tools\Publish-Releases.ps1 <release-notes-file> [-Title ""<一句话内容>""] [-Prerelease]"
}
$notesFullPath = (Resolve-Path -LiteralPath $NotesFile).Path

if (git status --porcelain --untracked-files=all) {
    throw "发布前 Git 工作区必须干净"
}

$tag = (git describe --tags --exact-match 2>$null)
if ([string]::IsNullOrWhiteSpace($tag)) {
    throw "当前提交没有精确 tag，请先建 v<versionName>+<versionCode> 标签"
}
$tag = $tag.Trim()

$apkPath = Join-Path $repoRoot "dist\android\PackingProof-Mobile-v$($tag.TrimStart('v')).apk"
if (-not (Test-Path -LiteralPath $apkPath -PathType Leaf)) {
    throw "找不到 APK：$apkPath，请先执行 Tools\Publish-Android.ps1"
}

$releaseTitle = if ([string]::IsNullOrWhiteSpace($Title)) { $tag } else { "$tag $Title" }

# Gitee 令牌固定来自 .env；CLI 的登录态可能停在失效的旧身份上，
# 先做一次真实调用确认可用，避免 GitHub 建好之后才在 Gitee 这一步失败。
$giteeTokenSource = Import-GiteeTokenFromEnvFile -RepoRoot $repoRoot
if (-not (Test-GiteeAuthentication -Repository $repoSlug -RepoRoot $repoRoot)) {
    $sourceHint = if ($giteeTokenSource) {
        "令牌来源：$giteeTokenSource"
    } else {
        ".env 里没有 GITEE_TOKEN，gitee CLI 登录态也不可用"
    }
    throw "Gitee 认证失败（$sourceHint），请核对 .env 的 GITEE_TOKEN"
}

Write-Host "发布 $tag"
Write-Host "  APK    $apkPath"
Write-Host "  笔记   $notesFullPath"
Write-Host "  标题   $releaseTitle"
Write-Host "  Gitee 令牌   $(if ($giteeTokenSource) { $giteeTokenSource } else { 'gitee CLI 登录态' })"

Write-Host ""
Write-Host "==> GitHub Release"
& gh release view $tag --repo $repoSlug *> $null
if ($LASTEXITCODE -eq 0) {
    Write-Host "GitHub 上 $tag 已存在，跳过创建"
}
else {
    $ghArgs = @("release", "create", $tag, $apkPath, "--repo", $repoSlug, "--title", $releaseTitle, "--notes-file", $notesFullPath)
    if ($Prerelease) { $ghArgs += "--prerelease" }

    # 公网到 GitHub 偶发连不上，重试几次再判失败。
    $created = $false
    foreach ($attempt in 1..5) {
        & gh @ghArgs
        if ($LASTEXITCODE -eq 0) { $created = $true; break }
        if ($attempt -lt 5) { Start-Sleep -Seconds 10 }
    }
    if (-not $created) {
        throw "GitHub Release 创建失败"
    }
}

Write-Host ""
Write-Host "==> Gitee Release"
& gitee release view $tag --repo $repoSlug *> $null
if ($LASTEXITCODE -eq 0) {
    Write-Host "Gitee 上 $tag 已存在，跳过创建"
}
else {
    $notesText = Get-Content -LiteralPath $notesFullPath -Raw
    $giteeArgs = @(
        "release", "create",
        "--repo", $repoSlug,
        "--tag", $tag,
        "--target", "main",
        "--name", $releaseTitle,
        "--notes", $notesText)
    if ($Prerelease) { $giteeArgs += "--prerelease" }

    & gitee @giteeArgs *> $null
    if ($LASTEXITCODE -ne 0) {
        throw "Gitee Release 创建失败"
    }
}

& gitee release upload --repo $repoSlug $tag $apkPath *> $null
if ($LASTEXITCODE -ne 0) {
    throw "Gitee 附件上传失败：$(Split-Path -Leaf $apkPath)"
}
Write-Host "Gitee 附件已上传（Gitee 会把文件名里的 + 显示成空格，属正常）"

Write-Host ""
Write-Host "GitHub 与 Gitee Release 均已就绪：$tag"
Write-Host "iOS 仍需在 Mac 上单独执行 Tools/Upload-TestFlight.sh 上传 TestFlight"
