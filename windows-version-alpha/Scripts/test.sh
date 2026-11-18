#!/usr/bin/env bash
#
# Полный прогон Windows-порта на этой машине: сборка всего решения, xunit-набор
# (он реально исполняется на macOS, потому что AnemiaCore цельится в net8.0), и
# второй контур — каждый собранный конфиг через настоящий xray.
#
#   bash windows-version-alpha/Scripts/test.sh
#
# Что этот прогон НЕ проверяет, сказано вслух: WPF-окно, tray и именованный канал
# хелпера живут в net8.0-windows и на macOS не запускаются — их видно только на
# Windows-машине. И что data-плоскость AWG/hysteria здесь не поднимается:
# проверяются байты конфига, а не туннель.
set -euo pipefail

HERE="$(cd "$(dirname "$0")" && pwd)"
ROOT="$(cd "$HERE/../.." && pwd)"
# shellcheck source=/dev/null
source "$HERE/dotnet-env.sh"

echo "→ сборка решения"
"$DOTNET_ROOT/dotnet" build "$ROOT/windows-version-alpha/Anemia.sln" -v q --nologo

echo "→ xunit"
"$DOTNET_ROOT/dotnet" test "$ROOT/windows-version-alpha/tests/AnemiaCoreTests/AnemiaCoreTests.csproj" \
    --nologo -v q

echo "→ xray принимает конфиги C#"
bash "$HERE/verify-configs.sh" 2>&1 | tail -2

echo "→ hysteria принимает YAML C#"
bash "$HERE/verify-hysteria.sh" 2>&1 | tail -2

echo "→ Swift перечитывает traffic.json глазами C#"
bash "$HERE/verify-traffic.sh" 2>&1 | tail -2

echo "→ Swift перечитывает бандл переноса глазами C#"
bash "$HERE/verify-sync.sh" 2>&1 | tail -2
