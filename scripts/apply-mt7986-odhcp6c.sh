#!/bin/sh
# ==============================================================================
# Jio Airfiber 5G WAN For OpenWrt — Standalone mt7986 odhcp6c Fix (Official FW)
# Author: The DIY Daddy (https://github.com/the-diy-daddy)
#
# Note: scripts/jio-airfiber-5g-wan.sh already runs this patch automatically on
# Official OpenWrt 25.12.x (aarch64). Use this standalone script only if you
# want to apply the odhcp6c patch by itself or roll back to stock files.
#
# Usage:
#   /tmp/jio-airfiber-5g-wan/scripts/apply-mt7986-odhcp6c.sh
#   /tmp/jio-airfiber-5g-wan/scripts/apply-mt7986-odhcp6c.sh --force
#   /tmp/jio-airfiber-5g-wan/scripts/apply-mt7986-odhcp6c.sh --no-restart
#   /tmp/jio-airfiber-5g-wan/scripts/apply-mt7986-odhcp6c.sh --rollback
# ==============================================================================

set -eu
trap '' HUP

REPO_RAW_BASE="${REPO_RAW_BASE:-https://raw.githubusercontent.com/the-diy-daddy/Jio-Airfiber-5G-WAN-For-OpenWrt/main}"
SCRIPT_DIR="$(CDPATH= cd -- "$(dirname -- "$0")" && pwd)"
BACKUP_DIR="/root/odhcp6c-25.12.6-backup"
TMP_DIR="/tmp/mt7986-odhcp6c-$$"
RESTART_LOG="/tmp/jio-network-restart.log"
FORCE_FIX="${FORCE_ODHCP6C_FIX:-0}"
NO_RESTART="${NO_RESTART:-0}"
DO_ROLLBACK=0

log()  { printf '[ODHCP6C-FIX] %s\n' "$1"; }
err()  { printf '[ERROR]       %s\n' "$1" >&2; rm -rf "$TMP_DIR"; exit 1; }

fetch_url() {
    local dst="$1"
    local url="$2"
    wget -4 -q -T 20 -O "$dst" "$url" 2>/dev/null || wget -q -T 20 -O "$dst" "$url" 2>/dev/null
}

atomic_install() {
    local src="$1"
    local dst="$2"
    local mode="$3"
    local tmp_dst="${dst}.jio-new.$$"
    cp -f "$src" "$tmp_dst"
    chmod "$mode" "$tmp_dst"
    mv -f "$tmp_dst" "$dst"
}

schedule_network_restart() {
    if [ "$NO_RESTART" = "1" ]; then
        log "Skipped network restart (--no-restart). Run 'reboot' or '/etc/init.d/network restart' to activate."
        return 0
    fi
    log "Scheduling detached /etc/init.d/network restart in 3 seconds (SSH may briefly drop ~10s)..."
    log "After reconnecting, check: cat $RESTART_LOG"
    (
        trap '' HUP
        sleep 3
        {
            echo "[$(date)] Running /etc/init.d/network restart..."
            /etc/init.d/network restart
            sleep 4
            if ubus call network get_proto_handlers 2>/dev/null | grep -q '"dhcpv6"'; then
                echo "[$(date)] netifd protocol 'dhcpv6': REGISTERED"
            else
                echo "[$(date)] WARN: netifd protocol 'dhcpv6' not found!"
            fi
        } > "$RESTART_LOG" 2>&1
    ) </dev/null >/dev/null 2>&1 &
}

while [ "$#" -gt 0 ]; do
    case "$1" in
        -f|--force)     FORCE_FIX="1"; shift ;;
        --no-restart)   NO_RESTART="1"; shift ;;
        -r|--rollback)  DO_ROLLBACK=1; shift ;;
        -h|--help)
            echo "Usage: apply-mt7986-odhcp6c.sh [--force] [--no-restart] [--rollback]"
            exit 0
            ;;
        *) err "Unknown argument: $1" ;;
    esac
done

if [ "$(id -u)" -ne 0 ]; then
    err "Run this script as root."
fi

if [ "$DO_ROLLBACK" -eq 1 ]; then
    [ -d "$BACKUP_DIR" ] || err "No backup directory found at $BACKUP_DIR."
    log "Restoring stock Official odhcp6c files from $BACKUP_DIR..."
    if [ -f "$BACKUP_DIR/odhcp6c" ]; then atomic_install "$BACKUP_DIR/odhcp6c" /usr/sbin/odhcp6c 0755; fi
    if [ -f "$BACKUP_DIR/dhcpv6.sh" ]; then atomic_install "$BACKUP_DIR/dhcpv6.sh" /lib/netifd/proto/dhcpv6.sh 0755; fi
    if [ -f "$BACKUP_DIR/dhcpv6.script" ]; then atomic_install "$BACKUP_DIR/dhcpv6.script" /lib/netifd/dhcpv6.script 0755; fi
    sync
    schedule_network_restart
    log "Rollback saved to flash."
    exit 0
fi

ARCH="$(uname -m)"
if [ "$ARCH" != "aarch64" ]; then
    err "This bundle is built for aarch64 (MediaTek Filogic mt7986); detected: $ARCH"
fi

OPENWRT_REV="unknown"
OPENWRT_DESC=""
if [ -f /etc/openwrt_release ]; then
    # shellcheck disable=SC1091
    . /etc/openwrt_release
    OPENWRT_REV="${DISTRIB_RELEASE:-unknown}"
    OPENWRT_DESC="${DISTRIB_DESCRIPTION:-}"
fi

case "$OPENWRT_REV $OPENWRT_DESC" in
    *[Ss][Nn][Aa][Pp][Ss][Hh][Oo][Tt]*)
        if [ "$FORCE_FIX" != "1" ]; then
            log "Snapshot firmware detected ($OPENWRT_REV) — no odhcp6c patch needed. Use --force to override."
            exit 0
        fi
        ;;
esac

mkdir -p "$TMP_DIR"

LOCAL_FOUND=""
for candidate in "$SCRIPT_DIR/../files/odhcp6c" "$SCRIPT_DIR/../files"; do
    if [ -f "$candidate/odhcp6c" ] && [ -f "$candidate/dhcpv6.sh" ] && [ -f "$candidate/dhcpv6.script" ]; then
        LOCAL_FOUND="$candidate"
        break
    fi
done

if [ -n "$LOCAL_FOUND" ]; then
    log "Using local mt7986 odhcp6c bundle from $LOCAL_FOUND..."
    cp -f "$LOCAL_FOUND/odhcp6c" "$TMP_DIR/odhcp6c"
    cp -f "$LOCAL_FOUND/dhcpv6.sh" "$TMP_DIR/dhcpv6.sh"
    cp -f "$LOCAL_FOUND/dhcpv6.script" "$TMP_DIR/dhcpv6.script"
else
    log "Downloading mt7986 odhcp6c bundle from $REPO_RAW_BASE..."
    if ! (fetch_url "$TMP_DIR/dhcpv6.sh" "$REPO_RAW_BASE/files/odhcp6c/dhcpv6.sh" && \
          fetch_url "$TMP_DIR/dhcpv6.script" "$REPO_RAW_BASE/files/odhcp6c/dhcpv6.script" && \
          fetch_url "$TMP_DIR/odhcp6c" "$REPO_RAW_BASE/files/odhcp6c/odhcp6c"); then
        log "Retrying fallback path $REPO_RAW_BASE/files/..."
        fetch_url "$TMP_DIR/dhcpv6.sh" "$REPO_RAW_BASE/files/dhcpv6.sh" || err "Failed to download dhcpv6.sh"
        fetch_url "$TMP_DIR/dhcpv6.script" "$REPO_RAW_BASE/files/dhcpv6.script" || err "Failed to download dhcpv6.script"
        fetch_url "$TMP_DIR/odhcp6c" "$REPO_RAW_BASE/files/odhcp6c" || err "Failed to download odhcp6c"
    fi
fi

if ! [ -s "$TMP_DIR/odhcp6c" ] || [ "$(head -c 4 "$TMP_DIR/odhcp6c" | tr -dc 'A-Z')" != "ELF" ]; then
    err "odhcp6c is not a valid ELF binary."
fi

sed -i 's/\r$//' "$TMP_DIR/dhcpv6.sh" "$TMP_DIR/dhcpv6.script" 2>/dev/null || true
head -n 1 "$TMP_DIR/dhcpv6.sh" | grep -q '^#!/bin/sh' || err "dhcpv6.sh is invalid."
head -n 1 "$TMP_DIR/dhcpv6.script" | grep -q '^#!/bin/sh' || err "dhcpv6.script is invalid."

if [ ! -d "$BACKUP_DIR" ]; then
    log "Backing up stock Official files to $BACKUP_DIR..."
    mkdir -p "$BACKUP_DIR"
    if [ -f /usr/sbin/odhcp6c ]; then cp -f /usr/sbin/odhcp6c "$BACKUP_DIR/odhcp6c"; fi
    if [ -f /lib/netifd/proto/dhcpv6.sh ]; then cp -f /lib/netifd/proto/dhcpv6.sh "$BACKUP_DIR/dhcpv6.sh"; fi
    if [ -f /lib/netifd/dhcpv6.script ]; then cp -f /lib/netifd/dhcpv6.script "$BACKUP_DIR/dhcpv6.script"; fi
fi

log "Atomically installing patched odhcp6c, dhcpv6.sh, and dhcpv6.script (chmod 0755)..."
atomic_install "$TMP_DIR/odhcp6c" /usr/sbin/odhcp6c 0755
atomic_install "$TMP_DIR/dhcpv6.sh" /lib/netifd/proto/dhcpv6.sh 0755
atomic_install "$TMP_DIR/dhcpv6.script" /lib/netifd/dhcpv6.script 0755
rm -rf "$TMP_DIR"

if ! (cd /lib/netifd/proto && ./dhcpv6.sh "" dump 2>/dev/null | grep -q '"dhcpv6"'); then
    err "dhcpv6.sh protocol dump failed after installation!"
fi

for p in /usr/sbin/odhcp6c /lib/netifd/proto/dhcpv6.sh /lib/netifd/dhcpv6.script; do
    grep -qxF "$p" /etc/sysupgrade.conf 2>/dev/null || echo "$p" >> /etc/sysupgrade.conf
done

sync
schedule_network_restart
log "Done! To restore stock Official files later: $0 --rollback"
