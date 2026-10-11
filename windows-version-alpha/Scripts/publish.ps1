# publish.ps1 — production publish for the Windows port: both binaries land
# side by side in .\publish\ (the layout AnemiaHelper.ResolveTool expects),
# then native artifacts from Resources\ are copied in.
#
#   powershell -ExecutionPolicy Bypass -File Scripts\publish.ps1 [-Arch win-x64|win-arm64] [-SelfContained]

param(
    [ValidateSet("win-x64", "win-arm64")]
    [string]$Arch = "win-x64",
    [switch]$SelfContained
)

$ErrorActionPreference = "Stop"
$Root = Split-Path -Parent $PSScriptRoot
$Out  = Join-Path $Root "publish"
if (Test-Path $Out) { Remove-Item $Out -Recurse -Force }
New-Item -ItemType Directory -Force -Path $Out | Out-Null

# NOTE: tun2socks upstream ships amd64 builds only; on win-arm64 the app runs
# natively but TUN mode needs x64 emulation or an arm64 tun2socks build.
if ($Arch -eq "win-arm64") {
    Write-Warning "win-arm64: tun2socks/wintun artifacts in Resources\ must be arm64 builds"
}

$sc = if ($SelfContained) { "--self-contained", "true" } else { "--self-contained", "false" }

dotnet publish (Join-Path $Root "src\AnemiaApp\AnemiaApp.csproj") `
    -c Release -r $Arch @sc -nologo -o $Out
if ($LASTEXITCODE -ne 0) { throw "AnemiaApp publish failed" }

dotnet publish (Join-Path $Root "src\AnemiaHelper\AnemiaHelper.csproj") `
    -c Release -r $Arch @sc -nologo -o $Out
if ($LASTEXITCODE -ne 0) { throw "AnemiaHelper publish failed" }

# Native cores (from fetch-cores.ps1) ride along next to the binaries.
$resources = Join-Path $Root "Resources"
if (Test-Path $resources) {
    Copy-Item (Join-Path $resources "*") $Out -Force
    Write-Host "[ok] native artifacts copied"
} else {
    Write-Warning "Resources\ not found — run fetch-cores.ps1 first; TUN mode and the engine will be missing"
}

Write-Host "Done -> $Out"