[CmdletBinding()]
param(
    [string]$SigningDirectory = '',
    [switch]$ForceClean
)

$ErrorActionPreference = 'Stop'
$repo = Split-Path -Parent $PSScriptRoot
$builder = Join-Path $PSScriptRoot 'Build-Android.ps1'
$pubspecPath = Join-Path $repo 'pubspec.yaml'
$envPath = Join-Path $repo '.env'

if (-not (Test-Path -LiteralPath $builder -PathType Leaf)) {
    throw "找不到 Android 构建脚本：$builder"
}
if ([string]::IsNullOrWhiteSpace($SigningDirectory)) {
    $SigningDirectory = $env:PACKING_PROOF_SIGNING_DIRECTORY
}
if ([string]::IsNullOrWhiteSpace($SigningDirectory) -and
    (Test-Path -LiteralPath $envPath -PathType Leaf)) {
    $setting = [IO.File]::ReadAllLines($envPath, [Text.Encoding]::UTF8) |
        Where-Object { $_ -match '^\s*PACKING_PROOF_SIGNING_DIRECTORY\s*=' } |
        Select-Object -First 1
    if ($setting) {
        $SigningDirectory = ($setting -split '=', 2)[1].Trim().Trim('"', "'")
    }
}
if ([string]::IsNullOrWhiteSpace($SigningDirectory)) {
    throw '请在仓库根目录 .env 中配置 PACKING_PROOF_SIGNING_DIRECTORY'
}
$resolvedSigningDirectory = (Resolve-Path -LiteralPath $SigningDirectory -ErrorAction Stop).Path
$repoPrefix = $repo.TrimEnd('\') + '\'
if ($resolvedSigningDirectory.Equals($repo, [StringComparison]::OrdinalIgnoreCase) -or
    $resolvedSigningDirectory.StartsWith($repoPrefix, [StringComparison]::OrdinalIgnoreCase)) {
    throw '正式签名目录必须位于仓库外'
}

$pattern = '^version:\s*([^+\s]+)\+([1-9]\d*)\s*$'
$versionLine = [IO.File]::ReadAllLines($pubspecPath, [Text.Encoding]::UTF8) |
    Where-Object { [regex]::IsMatch($_, $pattern) } |
    Select-Object -First 1
if (-not $versionLine) {
    throw 'pubspec.yaml 缺少有效的 version: x.y.z+versionCode'
}
$match = [regex]::Match($versionLine, $pattern)
$versionName = $match.Groups[1].Value
$versionCode = [int]$match.Groups[2].Value

Write-Host "正在构建正式签名 Release 测试安装包：$versionName+$versionCode"
Write-Host '安装包将覆盖固定输出位置，可直接覆盖同一签名的已安装版本'

& $builder `
    -VersionName $versionName `
    -VersionCode $versionCode `
    -SigningDirectory $resolvedSigningDirectory `
    -ForceClean:$ForceClean
if ($LASTEXITCODE -ne 0) {
    throw "正式签名 Release 测试安装包构建失败，退出代码：$LASTEXITCODE"
}

$apkPath = Join-Path $repo "dist/android/PackingProof-Mobile-v${versionName}+${versionCode}.apk"
if (-not (Test-Path -LiteralPath $apkPath -PathType Leaf)) {
    throw "构建完成但找不到安装包：$apkPath"
}
Write-Host "构建成功：$apkPath" -ForegroundColor Green
