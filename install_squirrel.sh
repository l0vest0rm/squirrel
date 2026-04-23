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

TARGET_USER="${SUDO_USER:-$(logname 2>/dev/null || stat -f '%Su' /dev/console)}"
TARGET_HOME="$(dscl . -read "/Users/$TARGET_USER" NFSHomeDirectory | awk '{print $2}')"

echo "Syncing user Rime config for $TARGET_USER..."
sudo -u "$TARGET_USER" HOME="$TARGET_HOME" "$SCRIPT_DIR/sync_rime_config.sh"

#echo "Restarting Squirrel..."
#killall Squirrel 2>/dev/null || true

echo ""
echo "Installation complete!"
echo ""
echo "Next steps:"
echo "1. Log out and log back in to your Mac (or restart)"
echo "2. Go to System Settings → Keyboard → Input Methods"
echo "3. Click '+' to add Squirrel"
echo "4. Select 'Squirrel' from the list"
echo "5. Switch to Squirrel in your input method menu"
