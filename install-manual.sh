#!/usr/bin/env bash
set -Eeuo pipefail

SOURCE_DIR="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)"
DECKY_HOME="${DECKY_HOME:-/var/home/armada/homebrew}"
PLUGIN_DIR="$DECKY_HOME/plugins/OdinGyro"

for required in plugin.json package.json main.py LICENSE dist/index.js scripts/odin3-gyro-recovery.sh; do
    [[ -e "$SOURCE_DIR/$required" ]] || {
        echo "ERROR: missing $required in $SOURCE_DIR" >&2
        exit 1
    }
done

echo "Installing Odin Gyro to: $PLUGIN_DIR"

sudo rm -rf "$PLUGIN_DIR"
sudo install -d -m 0755 "$PLUGIN_DIR"

sudo cp -a \
    "$SOURCE_DIR/plugin.json" \
    "$SOURCE_DIR/package.json" \
    "$SOURCE_DIR/main.py" \
    "$SOURCE_DIR/LICENSE" \
    "$SOURCE_DIR/README.md" \
    "$SOURCE_DIR/dist" \
    "$SOURCE_DIR/scripts" \
    "$PLUGIN_DIR/"

sudo find "$PLUGIN_DIR" -type d -exec chmod 0755 {} +
sudo find "$PLUGIN_DIR" -type f -exec chmod 0644 {} +
sudo chmod 0755 "$PLUGIN_DIR/scripts/odin3-gyro-recovery.sh"

# Root backend plugin. Keep files owned by root and restore Fedora/Armada labels.
sudo chown -R root:root "$PLUGIN_DIR"
sudo restorecon -RF "$PLUGIN_DIR" 2>/dev/null || true

sudo systemctl restart plugin_loader.service

echo
echo "Installed Odin Gyro. Open Decky -> Odin Gyro."
