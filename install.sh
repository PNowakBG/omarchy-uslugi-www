#!/bin/bash
# install.sh — dowiązuje helper skanujący do ~/.local/bin (idempotentnie).
# Panel.qml woła helper po ścieżce ~/.local/bin/uslugi-www-stan.
set -euo pipefail

DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
TARGET="$HOME/.local/bin/uslugi-www-stan"

mkdir -p "$HOME/.local/bin"
ln -sfn "$DIR/bin/uslugi-www-stan" "$TARGET"
chmod +x "$DIR/bin/uslugi-www-stan"
echo "helper: $TARGET -> $DIR/bin/uslugi-www-stan"
"$TARGET" status | head -c 120; echo " …"
echo "OK. Przyjazne nazwy portów: ~/.config/local-www.map (port nazwa | port !)"
