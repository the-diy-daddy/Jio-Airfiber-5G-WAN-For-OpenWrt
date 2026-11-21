#!/bin/sh
# ==============================================================================
# Jio Airfiber 5G WAN For OpenWrt — Standalone mt7986 odhcp6c Fix (Official FW)
# Uses local ../files/odhcp6c/ (when staged in /tmp/5g-wan-jio-airfiber-for-openwrt)
# or downloads from GitHub, backs up stock files to /root/odhcp6c-25.12.6-backup/,
# applies them, registers them in /etc/sysupgrade.conf, and restarts wan6.
# ==============================================================================

set -eu

REPO_RAW_BASE="${REPO_RAW_BASE:-https://raw.githubusercontent.com/the-diy-daddy/Jio-Airfiber-5G-WAN-For-OpenWrt/main}"
SCRIPT_DIR="$(CDPATH= cd -- "$(dirname -- "$0")" && pwd)"
LOCAL_ODHCP_DIR="$SCRIPT_DIR/../files/odhcp6c"
LOCAL_FILES_DIR="$SCRIPT_DIR/../files"
BACKUP_DIR="/root/odhcp6c-25.12.6-backup"
TMP_DIR="/tmp/mt7986-odhcp6c-$$"
FORCE="${FORCE_ODHCP6C_FIX:-0}"
ROLLBACK="0"

log() { printf '[ODHCP6C-FIX] %s\n' "$1"; }
err() { printf '[ERROR]       %s\n' "$1" >&2; rm -rf "$TMP_DIR"; exit 1; }

usage() {
    cat << 'EOF'
Usage: apply_mt7986_odhcp6c.sh [OPTIONS]

Options:
      --force      Apply even if Snapshot firmware is detected
      --rollback   Restore stock Official files from /root/odhcp6c-25.12.6-backup/
  -h, --help       Show this help message
EOF
    exit 0
}

while [ $# -gt 0 ]; do
    case "$1" in
        --force)    FORCE="1"; shift ;;
        --rollback) ROLLBACK="1"; shift ;;
        -h|--help)  usage ;;
        *)          err "Unknown option: $1 (use --help for usage)" ;;
    esac
done

[ "$(id -u)" -eq 0 ] || err "Run this script as root."

# --- Rollback Mode ---
if [ "$ROLLBACK" = "1" ]; then
    [ -f "$BACKUP_DIR/odhcp6c" ] && [ -f "$BACKUP_DIR/dhcpv6.sh" ] && [ -f "$BACKUP_DIR/dhcpv6.script" ] \
        || err "Backup files not found in $BACKUP_DIR."
    log "Restoring stock Official odhcp6c files from $BACKUP_DIR..."
    cp -f "$BACKUP_DIR/odhcp6c" /usr/sbin/odhcp6c
    cp -f "$BACKUP_DIR/dhcpv6.sh" /lib/netifd/proto/dhcpv6.sh
    cp -f "$BACKUP_DIR/dhcpv6.script" /lib/netifd/dhcpv6.script
    chmod 0755 /usr/sbin/odhcp6c /lib/netifd/dhcpv6.script
    chmod 0644 /lib/netifd/proto/dhcpv6.sh
    ifdown wan6 2>/dev/null || true
    sleep 2
    ifup wan6 2>/dev/null || true
    log "Rollback complete."
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
        if [ "$FORCE" != "1" ]; then
            log "Snapshot firmware detected ($OPENWRT_REV) — no odhcp6c patch needed. Use --force to override."
            exit 0
        fi
        ;;
esac

mkdir -p "$TMP_DIR"

if [ -f "$LOCAL_ODHCP_DIR/odhcp6c" ] && [ -f "$LOCAL_ODHCP_DIR/dhcpv6.sh" ] && [ -f "$LOCAL_ODHCP_DIR/dhcpv6.script" ]; then
    log "Using local files from $LOCAL_ODHCP_DIR..."
    cp -f "$LOCAL_ODHCP_DIR/odhcp6c" "$TMP_DIR/odhcp6c"
    cp -f "$LOCAL_ODHCP_DIR/dhcpv6.sh" "$TMP_DIR/dhcpv6.sh"
    cp -f "$LOCAL_ODHCP_DIR/dhcpv6.script" "$TMP_DIR/dhcpv6.script"
elif [ -f "$LOCAL_FILES_DIR/odhcp6c" ] && [ -f "$LOCAL_FILES_DIR/dhcpv6.sh" ] && [ -f "$LOCAL_FILES_DIR/dhcpv6.script" ]; then
    log "Using local files from $LOCAL_FILES_DIR..."
    cp -f "$LOCAL_FILES_DIR/odhcp6c" "$TMP_DIR/odhcp6c"
    cp -f "$LOCAL_FILES_DIR/dhcpv6.sh" "$TMP_DIR/dhcpv6.sh"
    cp -f "$LOCAL_FILES_DIR/dhcpv6.script" "$TMP_DIR/dhcpv6.script"
else
    log "Downloading mt7986 odhcp6c bundle from $REPO_RAW_BASE/files/odhcp6c/..."
    if ! (wget -q -T 20 -O "$TMP_DIR/dhcpv6.sh" "$REPO_RAW_BASE/files/odhcp6c/dhcpv6.sh" && \
          wget -q -T 20 -O "$TMP_DIR/dhcpv6.script" "$REPO_RAW_BASE/files/odhcp6c/dhcpv6.script" && \
          wget -q -T 20 -O "$TMP_DIR/odhcp6c" "$REPO_RAW_BASE/files/odhcp6c/odhcp6c"); then
        log "Retrying fallback path $REPO_RAW_BASE/files/..."
        wget -q -T 20 -O "$TMP_DIR/dhcpv6.sh" "$REPO_RAW_BASE/files/dhcpv6.sh" || err "Failed to download dhcpv6.sh"
        wget -q -T 20 -O "$TMP_DIR/dhcpv6.script" "$REPO_RAW_BASE/files/dhcpv6.script" || err "Failed to download dhcpv6.script"
        wget -q -T 20 -O "$TMP_DIR/odhcp6c" "$REPO_RAW_BASE/files/odhcp6c" || err "Failed to download odhcp6c"
    fi
fi

# Validate binary and shell scripts
if ! [ -s "$TMP_DIR/odhcp6c" ] || [ "$(head -c 4 "$TMP_DIR/odhcp6c" | tr -dc 'A-Z')" != "ELF" ]; then
    err "odhcp6c is not a valid ELF binary."
fi

sed -i 's/\r$//' "$TMP_DIR/dhcpv6.sh" "$TMP_DIR/dhcpv6.script" 2>/dev/null || true
head -n 1 "$TMP_DIR/dhcpv6.sh" | grep -q '^#!/bin/sh' || err "dhcpv6.sh is invalid."
head -n 1 "$TMP_DIR/dhcpv6.script" | grep -q '^#!/bin/sh' || err "dhcpv6.script is invalid."

if [ ! -d "$BACKUP_DIR" ]; then
    log "Backing up stock Official files to $BACKUP_DIR..."
    mkdir -p "$BACKUP_DIR"
    [ -f /usr/sbin/odhcp6c ] && cp -f /usr/sbin/odhcp6c "$BACKUP_DIR/odhcp6c"
    [ -f /lib/netifd/proto/dhcpv6.sh ] && cp -f /lib/netifd/proto/dhcpv6.sh "$BACKUP_DIR/dhcpv6.sh"
    [ -f /lib/netifd/dhcpv6.script ] && cp -f /lib/netifd/dhcpv6.script "$BACKUP_DIR/dhcpv6.script"
fi

log "Installing patched odhcp6c, dhcpv6.sh, and dhcpv6.script..."
cp -f "$TMP_DIR/odhcp6c" /usr/sbin/odhcp6c
cp -f "$TMP_DIR/dhcpv6.sh" /lib/netifd/proto/dhcpv6.sh
cp -f "$TMP_DIR/dhcpv6.script" /lib/netifd/dhcpv6.script
chmod 0755 /usr/sbin/odhcp6c /lib/netifd/dhcpv6.script
chmod 0644 /lib/netifd/proto/dhcpv6.sh
rm -rf "$TMP_DIR"

for p in /usr/sbin/odhcp6c /lib/netifd/proto/dhcpv6.sh /lib/netifd/dhcpv6.script; do
    grep -qxF "$p" /etc/sysupgrade.conf 2>/dev/null || echo "$p" >> /etc/sysupgrade.conf
done

WAN_CARRIER="$(cat /sys/class/net/wan/carrier 2>/dev/null || echo 0)"
if [ "$WAN_CARRIER" = "1" ]; then
    log "WAN link detected — restarting wan6..."
    ifdown wan6 2>/dev/null || true
    sleep 2
    ifup wan6
else
    log "WAN cable not plugged in yet — patch will take effect once Jio ODU is connected and router reboots."
fi

log "Done! To restore stock files later, run with --rollback or:"
log "  cp -f $BACKUP_DIR/odhcp6c /usr/sbin/odhcp6c"
log "  cp -f $BACKUP_DIR/dhcpv6.sh /lib/netifd/proto/dhcpv6.sh"
log "  cp -f $BACKUP_DIR/dhcpv6.script /lib/netifd/dhcpv6.script"