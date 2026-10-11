#!/usr/bin/env bash
#
# Находит закреплённый .NET 8 SDK и настраивает окружение для сборки
# Windows-порта на этой машине. Тот же приём, что у Scripts/go-env.sh: сборка
# описана здесь, а не «возьми dotnet из PATH», потому что версия SDK меняет
# компиляторные предупреждения и результат analysis.
#
#   source windows-version-alpha/Scripts/dotnet-env.sh
#   bash windows-version-alpha/Scripts/test.sh
#
# Если SDK нет, команда ниже ставит его в кэш проекта и сверяет контрольную
# сумму с той, что опубликовал сам Microsoft в release-metadata.

ANEMIA_CACHE="${ANEMIA_CACHE:-$HOME/Library/Caches/Anemia}"

DOTNET_VERSION=8.0.425
# https://builds.dotnet.microsoft.com/dotnet/release-metadata/8.0/releases.json
# → release 8.0.31 → sdk 8.0.425 → dotnet-sdk-8.0.425-osx-arm64.tar.gz
DOTNET_SHA256=d42156be70b489236479a415536013a89a9fd6eaca57d5716a7017612fcc65bdb459068973d7cffd6fe710f2799af8bee95b2046ba032762d47df176f5c4a7d6
DOTNET_URL="https://builds.dotnet.microsoft.com/dotnet/Sdk/$DOTNET_VERSION/dotnet-sdk-$DOTNET_VERSION-osx-arm64.tar.gz"

DOTNET_HOME="$ANEMIA_CACHE/toolchains/dotnet-$DOTNET_VERSION/dotnet"

if [[ ! -x "$DOTNET_HOME/dotnet" ]]; then
    echo "✗ нет .NET SDK $DOTNET_VERSION в $DOTNET_HOME" >&2
    cat >&2 <<EOS
  поставить:
    D=$ANEMIA_CACHE/toolchains/dotnet-$DOTNET_VERSION
    mkdir -p "\$D" && curl -sSL -o "\$D/sdk.tar.gz" "$DOTNET_URL"
    ( cd "\$D" && echo "$DOTNET_SHA256  sdk.tar.gz" | shasum -a 256 -c - )
    mkdir -p "\$D/dotnet" && tar -xzf "\$D/sdk.tar.gz" -C "\$D/dotnet"
EOS
    return 1 2>/dev/null || exit 1
fi

export DOTNET_ROOT="$DOTNET_HOME"
export PATH="$DOTNET_HOME:$PATH"
export DOTNET_CLI_TELEMETRY_OPTOUT=1
export DOTNET_NOLOGO=1
export NUGET_PACKAGES="${NUGET_PACKAGES:-$ANEMIA_CACHE/nuget}"
