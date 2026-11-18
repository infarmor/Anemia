# Builds the shared Go engine and JNI library with the Windows Android NDK.
param(
    [ValidateSet('arm64-v8a', 'armeabi-v7a', 'x86_64')]
    [string[]]$Abi = @('arm64-v8a'),
    [string]$Sdk = $env:ANDROID_HOME,
    [string]$Go = 'go'
)

$ErrorActionPreference = 'Stop'
$Android = Split-Path -Parent $PSScriptRoot
$Engine = Join-Path (Split-Path -Parent $Android) 'iOS/Engine'
if (-not $Sdk) { $Sdk = $env:ANDROID_SDK_ROOT }
if (-not $Sdk) { $Sdk = Join-Path $env:LOCALAPPDATA 'Android/Sdk' }
$Toolchain = Join-Path $Sdk 'ndk/28.2.13676358/toolchains/llvm/prebuilt/windows-x86_64'
$Clang = Join-Path $Toolchain 'bin/clang.exe'
if (-not (Test-Path -LiteralPath $Clang)) { throw "Install Android NDK 28.2.13676358 at $Sdk" }

$Targets = @{
    'arm64-v8a' = @('arm64', 'aarch64-linux-android28')
    'armeabi-v7a' = @('arm', 'armv7a-linux-androideabi28')
    'x86_64' = @('amd64', 'x86_64-linux-android28')
}
$Variables = @('CGO_ENABLED', 'GOOS', 'GOARCH', 'GOARM', 'CC', 'CGO_LDFLAGS')
$Previous = @{}
foreach ($Name in $Variables) { $Previous[$Name] = [Environment]::GetEnvironmentVariable($Name) }

Push-Location -LiteralPath $Engine
try {
    foreach ($Name in $Abi) {
        $Arch, $Target = $Targets[$Name]
        $Out = Join-Path $Android "engine/build/$Name"
        New-Item -ItemType Directory -Path $Out -Force | Out-Null
        $EngineLibrary = Join-Path $Out 'libanemia.so'
        $JniLibrary = Join-Path $Out 'libanemia_jni.so'

        $env:CGO_ENABLED = '1'
        $env:GOOS = 'android'
        $env:GOARCH = $Arch
        $env:GOARM = if ($Arch -eq 'arm') { '7' } else { $null }
        $env:CC = '"{0}" --target={1}' -f $Clang, $Target
        $env:CGO_LDFLAGS = '-Wl,-z,max-page-size=16384'
        & $Go build -mod=readonly -buildmode=c-shared -trimpath -buildvcs=false -ldflags '-s -w' -o $EngineLibrary .
        if ($LASTEXITCODE -ne 0) { throw "Go engine build failed for $Name" }

        $JniSource = Join-Path $Android 'engine/jni/anemia_jni.c'
        & $Clang "--target=$Target" -O2 -fPIC -shared -Wall -Werror '-Wl,-z,max-page-size=16384' -o $JniLibrary $JniSource -ldl
        if ($LASTEXITCODE -ne 0) { throw "JNI build failed for $Name" }

        $Destination = Join-Path $Android "app/src/main/jniLibs/$Name"
        New-Item -ItemType Directory -Path $Destination -Force | Out-Null
        Copy-Item -LiteralPath $EngineLibrary, $JniLibrary -Destination $Destination -Force
        Write-Output "Packaged $Name in $Destination"
    }
}
finally {
    foreach ($Name in $Variables) { [Environment]::SetEnvironmentVariable($Name, $Previous[$Name]) }
    Pop-Location
}
