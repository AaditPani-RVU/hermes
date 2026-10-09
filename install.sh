#!/bin/sh
# Build and install Hermes into ~/.local (no sudo needed).
#   ./install.sh            build + install + enable daemon
#   ./install.sh --no-niri  skip adding the Mod+Ctrl+W keybind
set -eu
REPO="$(cd "$(dirname "$0")" && pwd)"
export PATH="$HOME/.local/go/bin:$HOME/go/bin:$PATH"

echo "→ building daemon"
cd "$REPO/daemon"
go build -o bin/hermesd ./cmd/hermesd
go build -o bin/hermes ./cmd/hermes

echo "→ installing to ~/.local"
mkdir -p "$HOME/.local/bin" "$HOME/.local/share/hermes" "$HOME/.local/share/applications" \
         "$HOME/.local/share/icons/hicolor/scalable/apps" "$HOME/.config/systemd/user"
install -m 755 bin/hermesd bin/hermes "$REPO/packaging/hermes-ui" "$REPO/packaging/hermes-update" "$REPO/packaging/hermes-whisper-setup" "$REPO/packaging/hermes-ocr-setup" "$HOME/.local/bin/"
# UI is symlinked so edits in the repo apply on next launch.
ln -sfn "$REPO/ui" "$HOME/.local/share/hermes/ui"
install -m 644 "$REPO/packaging/hermes.desktop" "$HOME/.local/share/applications/hermes.desktop"
install -m 644 "$REPO/packaging/hermes.svg" "$HOME/.local/share/icons/hicolor/scalable/apps/hermes.svg"
install -m 644 "$REPO/packaging/hermes-notify.svg" "$HOME/.local/share/icons/hicolor/scalable/apps/hermes-notify.svg"
install -m 644 "$REPO/packaging/hermesd.service" "$HOME/.config/systemd/user/hermesd.service"

if [ "${1:-}" != "--no-niri" ] && [ -f "$HOME/.config/niri/config.kdl" ]; then
    install -m 644 "$REPO/packaging/niri-hermes.kdl" "$HOME/.config/niri/hermes.kdl"
    grep -q 'include "hermes.kdl"' "$HOME/.config/niri/config.kdl" || \
        printf '\n// Hermes WhatsApp client\ninclude "hermes.kdl";\n' >> "$HOME/.config/niri/config.kdl"
    niri validate >/dev/null 2>&1 && echo "→ niri keybind: Mod+Ctrl+W" || echo "! niri config didn't validate; check ~/.config/niri/hermes.kdl"
fi

systemctl --user daemon-reload
systemctl --user enable --now hermesd.service
echo "✓ installed. Run 'hermes-ui' (or Mod+Ctrl+W) and scan the QR code, or 'hermes pair' in a terminal."
