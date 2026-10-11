# fetch-cores.ps1 — download the native pieces the Windows port needs:
#   xray.exe       — Xray-core (the engine; same core the macOS build bundles)
#   tun2socks.exe  — xjasonlyu/tun2socks (owns the wintun adapter for TUN mode)
#   wintun.dll     — loaded by tun2socks at runtime (we never link it ourselves)
#
# Run from the repo root:
#   powershell -ExecutionPolicy Bypass -File Scripts\fetch-cores.ps1
# Layout result:  <root>\Resources\xray.exe etc., mirrored next to the built
# binaries by publish.ps1.
#
# Every artifact is checked twice: the downloaded archive against $Sha256, and
# the file taken out of it against $EntrySha256. A pin is not a formality — the
# engine is the trust boundary of the whole client, so a URL that answers with
# something else must fail loudly and install nothing. The previous version of
# this script printed "record this hash" and kept the download anyway, which
# meant the first run trusted the network completely.
#
# To get both hashes for a new release:
#   powershell -File Scripts\fetch-cores.ps1 -Record xray.exe
# It downloads, prints the hashes, and installs NOTHING. Copy them into $Pins,
# then run without -Record.

param(
    [string]$Record = ""   # name of one artifact: print its hashes and exit
)

$ErrorActionPreference = "Stop"
$Root = Split-Path -Parent $PSScriptRoot
$Out  = Join-Path $Root "Resources"

# Pinned versions + hashes, measured on 2026-09-27 by fetching each asset over
# HTTPS and hashing it — including the payload inside, which is the part that
# runs. Bumping a release means editing both columns deliberately.
$Pins = @(
    @{
        Name  = "xray.exe"
        Url   = "https://github.com/XTLS/Xray-core/releases/download/v25.9.11/Xray-windows-64.zip"
        Entry = "xray.exe"
        Sha256 = "d8db96eb39d7bc8cae484b2e59b651ff3c04f21e26d66e310f6a44e256ed1cc4"
        EntrySha256 = "c478ce1f56ff0b09ad804868e16bf4bbc4020a7f1f09c2ae9df20f5068c8e23a"
        Zip = $true
    },
    @{
        # The 2.5.2 asset spells its payload `tun2socks-windows-amd64.exe`, and
        # this project ships the file under the name AnemiaHelper resolves —
        # tun2socks.exe. The old Entry value here named a file the archive does
        # not contain, so the script could never produce what it promised.
        Name  = "tun2socks.exe"
        Url   = "https://github.com/xjasonlyu/tun2socks/releases/download/v2.5.2/tun2socks-windows-amd64.zip"
        Entry = "tun2socks-windows-amd64.exe"
        Sha256 = "06c71bc30e557ceab6964543bd0d68e1b9dfefa272b51a46f60171af621b5f42"
        EntrySha256 = "90547fe071fe471b02da83dd150b5db7ce02454797e7f288d489b1ff0c4dd67c"
        Zip = $true
    },
    @{
        Name  = "wintun.dll"
        Url   = "https://www.wintun.net/builds/wintun-0.14.1.zip"
        Entry = "wintun/bin/amd64/wintun.dll"
        Sha256 = "07c256185d6ee3652e09fa55c0b673e2624b565e02c4b9091c79ca7d2f24ef51"
        EntrySha256 = "e5da8447dc2c320edc0fc52fa01885c103de8c118481f683643cacc3220dafce"
        Zip = $true
    }
)

function Get-File([string]$Url) {
    $tmp = New-TemporaryFile
    Invoke-WebRequest -Uri $Url -OutFile $tmp -UseBasicParsing
    return $tmp
}

function Get-Hash([string]$Path) { (Get-FileHash $Path -Algorithm SHA256).Hash.ToLowerInvariant() }

function Extract-Entry([string]$Archive, [string]$Entry, [string]$Destination) {
    $scratch = Join-Path ([System.IO.Path]::GetTempPath()) ([Guid]::NewGuid().ToString())
    try {
        Expand-Archive -Path $Archive -DestinationPath $scratch
        $found = Join-Path $scratch $Entry
        if (-not (Test-Path $found)) {
            $seen = (Get-ChildItem -Recurse $scratch | ForEach-Object { $_.Name }) -join ", "
            throw "$Entry is not in this archive (it holds: $seen)"
        }
        Copy-Item $found $Destination -Force
    } finally {
        if (Test-Path $scratch) { Remove-Item $scratch -Recurse -Force }
    }
}

if ($Record -ne "") {
    $pin = @($Pins | Where-Object { $_.Name -eq $Record })
    if ($pin.Count -ne 1) {
        $names = ($Pins | ForEach-Object { $_.Name }) -join ", "
        throw "no artifact called '$Record'; known names: $names"
    }
    $pin = $pin[0]
    Write-Host "[record] $($pin.Url)" -ForegroundColor Yellow
    $archive = Get-File $pin.Url
    $tmp = Join-Path ([System.IO.Path]::GetTempPath()) ([Guid]::NewGuid().ToString())
    try {
        if ($pin.Zip) { Extract-Entry $archive $pin.Entry $tmp } else { Copy-Item $archive $tmp }
        Write-Host "        Sha256      = ""$(Get-Hash $archive)"""
        Write-Host "        EntrySha256 = ""$(Get-Hash $tmp)"""
        Write-Host "[record] nothing installed — copy both hashes into the `$Pins table"
    } finally {
        Remove-Item $tmp -Force -ErrorAction SilentlyContinue
        Remove-Item $archive -Force
    }
    return
}

New-Item -ItemType Directory -Force -Path $Out | Out-Null

foreach ($pin in $Pins) {
    $dest = Join-Path $Out $pin.Name

    if ((Test-Path $dest) -and ((Get-Hash $dest) -eq $pin.EntrySha256)) {
        Write-Host "[ok] $($pin.Name) already present and matching the pin"
        continue
    }

    Write-Host "[get] $($pin.Url)"
    $archive = Get-File $pin.Url
    $ok = $false
    try {
        $archiveHash = Get-Hash $archive
        if ($archiveHash -ne $pin.Sha256) {
            throw ("SHA256 mismatch for $($pin.Name): the pin says $($pin.Sha256), " +
                   "$($pin.Url) answered $archiveHash. Nothing was installed. If the release " +
                   "really moved, edit the pin deliberately: fetch-cores.ps1 -Record " +
                   "$($pin.Name)")
        }
        Extract-Entry $archive $pin.Entry $dest
        $entryHash = Get-Hash $dest
        if ($entryHash -ne $pin.EntrySha256) {
            throw ("$($pin.Name): the archive matched its pin, but $($pin.Entry) inside it " +
                   "hashed to $entryHash, not $($pin.EntrySha256)")
        }
        $ok = $true
        Write-Host "[ok] $($pin.Name) -> $dest"
    } finally {
        Remove-Item $archive -Force
        # A half-written or refused artifact must not sit in Resources looking
        # like a fetched engine — publish.ps1 copies whatever is there.
        if (-not $ok -and (Test-Path $dest)) { Remove-Item $dest -Force }
    }
}

Write-Host "Done. Artifacts in $Out"
