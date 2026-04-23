#!/bin/bash
set -e

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
swift "$SCRIPT_DIR/keycode_monitor.swift"
