#!/bin/bash
set -e

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
CONFIG_SRC="$SCRIPT_DIR/custom"
USER_RIME_DIR="$HOME/Library/Rime"
SQUIRREL_APP="/Library/Input Methods/Squirrel.app"
RIME_DEPLOYER="/Library/Input Methods/Squirrel.app/Contents/MacOS/rime_deployer"
SHARED_SUPPORT="/Library/Input Methods/Squirrel.app/Contents/SharedSupport"
OPENCC_SRC="/Library/Input Methods/Squirrel.app/Contents/SharedSupport/opencc"

die_permission() {
    echo "Error: $1"
    echo 'Fix ownership with:'
    echo '  sudo chown -R "$(id -un)":"$(id -gn)" ~/Library/Rime'
    exit 1
}

echo "Syncing Rime config..."

if [ ! -d "$CONFIG_SRC" ]; then
    echo "Error: custom config directory not found at $CONFIG_SRC"
    exit 1
fi

if [ ! -x "$RIME_DEPLOYER" ] || [ ! -d "$SHARED_SUPPORT" ]; then
    echo "Error: Squirrel.app is not installed at $SQUIRREL_APP"
    echo "Please run ./install_squirrel.sh first."
    exit 1
fi

mkdir -p "$USER_RIME_DIR"

if [ ! -w "$USER_RIME_DIR" ]; then
    die_permission "$USER_RIME_DIR is not writable."
fi

for src in "$CONFIG_SRC"/*.yaml; do
    target="$USER_RIME_DIR/$(basename "$src")"
    if [ -e "$target" ] && [ ! -w "$target" ]; then
        die_permission "$target is not writable."
    fi
done

if [ -e "$USER_RIME_DIR/opencc" ] && [ ! -w "$USER_RIME_DIR/opencc" ]; then
    die_permission "$USER_RIME_DIR/opencc is not writable."
fi

if [ -d "$OPENCC_SRC" ]; then
    echo "Copying opencc data to $USER_RIME_DIR..."
    rm -rf "$USER_RIME_DIR/opencc"
    cp -R "$OPENCC_SRC" "$USER_RIME_DIR/"
fi

echo "Copying YAML files to $USER_RIME_DIR..."
find "$CONFIG_SRC" -maxdepth 1 -type f -name "*.yaml" -exec cp {} "$USER_RIME_DIR/" \;

echo "Deploying Rime data..."
"$RIME_DEPLOYER" --build "$USER_RIME_DIR" "$SHARED_SUPPORT" "$USER_RIME_DIR/build"

if [ ! -f "$USER_RIME_DIR/build/double_pinyin_mspy.schema.yaml" ] || ! grep -q 'dictionary: custom_words' "$USER_RIME_DIR/build/double_pinyin_mspy.schema.yaml"; then
    echo "Error: Rime deploy did not produce the expected double_pinyin_mspy build output."
    exit 1
fi

echo "Restarting Squirrel..."
killall Squirrel 2>/dev/null || true
open "$SQUIRREL_APP"

echo "Rime config sync complete."
