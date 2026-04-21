#!/usr/bin/env bash
# Initialize build environment: setup rime-plugins dir and install double-pinyin

set -e

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"

echo "=== Initializing Squirrel build environment ==="

# Create empty rime-plugins directory to avoid cp error in make
mkdir -p "$SCRIPT_DIR/librime/dist/lib/rime-plugins"

# Initialize plum submodule if needed
if [ ! -d "$SCRIPT_DIR/plum/.git" ]; then
    echo "Initializing plum submodule..."
    git submodule update --init plum
fi

# Install double-pinyin (includes MSPY, ABC, flyPY, etc.)
echo "Installing double-pinyin..."
rime_dir="$SCRIPT_DIR/plum/output" bash "$SCRIPT_DIR/plum/rime-install" double-pinyin

# Also install luna-pinyin dependency
rime_dir="$SCRIPT_DIR/plum/output" bash "$SCRIPT_DIR/plum/rime-install" luna-pinyin

echo "=== Initialization complete ==="
echo "Now run: make"
