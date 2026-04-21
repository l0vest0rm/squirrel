#!/bin/bash
# Install double pinyin (双拼) dependencies via plum

set -e

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"

echo "Installing double-pinyin..."
bash "$SCRIPT_DIR/plum/rime-install" double-pinyin

echo "Done."
