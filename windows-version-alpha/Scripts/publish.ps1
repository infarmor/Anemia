# publish.ps1 — production publish for the Windows port: both binaries land
# side by side in .\publish\ (the layout AnemiaHelper.ResolveTool expects),
# then native artifacts from Resources\ are copied in.
#
#   powershell -ExecutionPolicy Bypass -File Scripts\publish.ps1 [-Arch win-x64|win-arm64] [-SelfContained]

param(
    [ValidateSet("win-x64", "win-arm64")]
    [string]$Arch = "win-x64",
    [switch]$SelfContained,
    [string]$Dotnet = "dotnet",
    [string]$Go = "go"
)

$ErrorActionPreference = "Stop"
$Root = Split-Path -Parent $PSScriptRoot
$Out  = Join-Path $Root "publish"
$Resources = Join-Path $Root "Resources"
$Native = @("xray.exe", "tun2socks.exe", "wintun.dll")

foreach ($Binary in $Native) {
    $Path = Join-Path $Resources $Binary
    if (-not (Test-Path -LiteralPath $Path)) {
        throw "Missing $Binary. Run Scripts\fetch-cores.ps1 for the win-x64 dependencies."
    }
    $Reader = [IO.BinaryReader]::new([IO.File]::OpenRead($Path))
    try {
        $Reader.BaseStream.Position = 0x3c
        $Offset = $Reader.ReadInt32()
        $Reader.BaseStream.Position = $Offset
        if ($Reader.ReadUInt32() -ne 0x4550) { throw "Invalid Windows binary: $Binary" }
        $Expected = if ($Arch -eq "win-arm64") { 0xaa64 } else { 0x8664 }
        if ($Reader.ReadUInt16() -ne $Expected) { throw "$Binary is not a $Arch binary" }
    } finally { $Reader.Dispose() }
}

New-Item -ItemType Directory -Force -Path $Out | Out-Null
$sc = if ($SelfContained) { "--self-contained", "true" } else { "--self-contained", "false" }

& $Dotnet publish (Join-Path $Root "src\AnemiaApp\AnemiaApp.csproj") `
    -c Release -r $Arch @sc -nologo -o $Out
if ($LASTEXITCODE -ne 0) { throw "AnemiaApp publish failed" }

& $Dotnet publish (Join-Path $Root "src\AnemiaHelper\AnemiaHelper.csproj") `
    -c Release -r $Arch @sc -nologo -o $Out
if ($LASTEXITCODE -ne 0) { throw "AnemiaHelper publish failed" }

Push-Location -LiteralPath (Join-Path $Root "engine")
$PreviousOS = $env:GOOS
$PreviousArch = $env:GOARCH
$PreviousCgo = $env:CGO_ENABLED
try {
    $env:GOOS = "windows"
    $env:GOARCH = if ($Arch -eq "win-arm64") { "arm64" } else { "amd64" }
    $env:CGO_ENABLED = "0"
    & $Go build -mod=readonly -trimpath -buildvcs=false -ldflags "-s -w" -o (Join-Path $Out "anemia-engine.exe") .
    if ($LASTEXITCODE -ne 0) { throw "AmneziaWG and firewall engine build failed" }
} finally {
    $env:GOOS = $PreviousOS
    $env:GOARCH = $PreviousArch
    $env:CGO_ENABLED = $PreviousCgo
    Pop-Location
}
foreach ($Binary in $Native) { Copy-Item -LiteralPath (Join-Path $Resources $Binary) -Destination $Out -Force }

Write-Host "Done -> $Out"
