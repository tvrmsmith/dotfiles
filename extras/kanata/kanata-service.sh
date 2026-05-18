#!/usr/bin/env bash
set -euo pipefail

VHID_PLIST="com.karabiner.vhid-daemon"
KANATA_PLIST="com.kanata.daemon"
PLIST_DIR="/Library/LaunchDaemons"
SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
LOG_DIR="/Library/Logs/Kanata"

usage() {
    echo "Usage: kanata-service {install|uninstall|start|stop|restart|status}"
    exit 1
}

require_sudo() {
    if [[ $EUID -ne 0 ]]; then
        echo "Run with sudo"
        exit 1
    fi
}

install() {
    require_sudo
    mkdir -p "$LOG_DIR"

    for plist in "$VHID_PLIST" "$KANATA_PLIST"; do
        cp "$SCRIPT_DIR/${plist}.plist" "$PLIST_DIR/"
        chown root:wheel "$PLIST_DIR/${plist}.plist"
        chmod 644 "$PLIST_DIR/${plist}.plist"
        launchctl enable "system/${plist}"
        launchctl bootstrap system "$PLIST_DIR/${plist}.plist" 2>/dev/null || true
    done

    echo "Installed. Run: sudo kanata-service start"
}

uninstall() {
    require_sudo
    for plist in "$KANATA_PLIST" "$VHID_PLIST"; do
        launchctl bootout "system/${plist}" 2>/dev/null || true
        launchctl disable "system/${plist}" 2>/dev/null || true
        rm -f "$PLIST_DIR/${plist}.plist"
    done
    echo "Uninstalled."
}

start() {
    require_sudo
    launchctl start "$VHID_PLIST"
    sleep 1
    launchctl start "$KANATA_PLIST"
    echo "Started."
}

stop() {
    require_sudo
    launchctl stop "$KANATA_PLIST" 2>/dev/null || true
    launchctl stop "$VHID_PLIST" 2>/dev/null || true
    echo "Stopped."
}

status() {
    echo "=== Karabiner VHIDDaemon ==="
    launchctl list "$VHID_PLIST" 2>/dev/null || echo "Not loaded"
    echo ""
    echo "=== Kanata ==="
    launchctl list "$KANATA_PLIST" 2>/dev/null || echo "Not loaded"
}

case "${1:-}" in
    install)   install ;;
    uninstall) uninstall ;;
    start)     start ;;
    stop)      stop ;;
    restart)   stop; sleep 1; start ;;
    status)    status ;;
    *)         usage ;;
esac
