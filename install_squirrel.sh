#!/bin/bash
set -e

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
APP_PATH="$SCRIPT_DIR/build/Build/Products/Release/Squirrel.app"
DSTROOT="/Library/Input Methods"

echo "Installing Squirrel..."

if [ ! -d "$APP_PATH" ]; then
    echo "Error: Squirrel.app not found at $APP_PATH"
    echo "Please run 'make' first to build the app."
    exit 1
fi

# Check if running as root or with sudo
if [ "$(id -u)" -ne 0 ]; then
    echo "This script requires root privileges. Trying with sudo..."
    exec sudo bash "$0" "$@"
fi

# Remove existing installation
if [ -d "$DSTROOT/Squirrel.app" ]; then
    echo "Removing existing Squirrel.app..."
    rm -rf "$DSTROOT/Squirrel.app"
fi

# Copy the app
echo "Copying Squirrel.app to $DSTROOT..."
cp -R "$APP_PATH" "$DSTROOT/"

# Set proper permissions
chmod -R 755 "$DSTROOT/Squirrel.app"

# Copy opencc data files to user's Rime directory for繁简转换
USER_RIME_DIR="$HOME/Library/Rime"
OPENCC_SRC="$SCRIPT_DIR/build/Build/Products/Release/Squirrel.app/Contents/SharedSupport/opencc"
if [ -d "$OPENCC_SRC" ]; then
    echo "Copying opencc data files to $USER_RIME_DIR..."
    mkdir -p "$USER_RIME_DIR"
    cp -R "$OPENCC_SRC" "$USER_RIME_DIR/"
fi

# Copy custom Rime config files (微软双拼 + 默认简体 + 界面样式)
CONFIG_SRC="$SCRIPT_DIR/custom"
if [ -d "$CONFIG_SRC" ]; then
    echo "Copying custom config files to $USER_RIME_DIR..."
    mkdir -p "$USER_RIME_DIR"
    find "$CONFIG_SRC" -maxdepth 1 -type f -name "*.yaml" -exec cp {} "$USER_RIME_DIR/" \;
fi

echo ""
echo "Installation complete!"
echo ""
echo "Next steps:"
echo "1. Log out and log back in to your Mac (or restart)"
echo "2. Go to System Settings → Keyboard → Input Methods"
echo "3. Click '+' to add Squirrel"
echo "4. Select 'Squirrel' from the list"
echo "5. Switch to Squirrel in your input method menu"
