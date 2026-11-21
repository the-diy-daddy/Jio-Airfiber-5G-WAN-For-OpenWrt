#!/bin/sh
# ==============================================================================
# Jio Airfiber 5G WAN For OpenWrt — mt7986 odhcp6c Fix Installer (25.12.6)
# Installs the verified mt7986 (aarch64) odhcp6c, dhcpv6.sh, and dhcpv6.script
# from local ../files/ or directly from the GitHub repository, backs up originals,
# registers them in /etc/sysupgrade.conf, and restarts wan6.
# ==============================================================================

set -eu

REPO_RAW_BASE="${REPO_RAW_BASE:-https://raw.githubusercontent.com/the-diy-daddy/Jio-Airfiber-5G-WAN-For-OpenWrt/main}"
SCRIPT_DIR="$(CDPATH= cd -- "$(dirname -- "$0")" && pwd)"
LOCAL_FILES_DIR="$SCRIPT_DIR/../files"
BACKUP_DIR="/root/odhcp6c-25.12.6-backup"
TMP_DIR="/tmp/mt7986-odhcp6c-$$"

log() { printf '[ODHCP6C-FIX] %s\n' "$1"; }
err() { printf '[ERROR]       %s\n' "$1" >&2; rm -rf "$TMP_DIR"; exit 1; }

[ "$(id -u)" -eq 0 ] || err "Run this script as root."

ARCH="$(uname -m)"
if [ "$ARCH" != "aarch64" ]; then
    err "This bundle is built for aarch64 (MediaTek Filogic mt7986); detected: $ARCH"
fi

mkdir -p "$TMP_DIR"

if [ -f "$LOCAL_FILES_DIR/odhcp6c" ] && [ -f "$LOCAL_FILES_DIR/dhcpv6.sh" ] && [ -f "$LOCAL_FILES_DIR/dhcpv6.script" ]; then
    log "Using local files from $LOCAL_FILES_DIR..."
    cp -f "$LOCAL_FILES_DIR/odhcp6c" "$TMP_DIR/odhcp6c"
    cp -f "$LOCAL_FILES_DIR/dhcpv6.sh" "$TMP_DIR/dhcpv6.sh"
    cp -f "$LOCAL_FILES_DIR/dhcpv6.script" "$TMP_DIR/dhcpv6.script"
else
    log "Fetching mt7986 odhcp6c bundle from GitHub ($REPO_RAW_BASE/files)..."
    for f in odhcp6c dhcpv6.sh dhcpv6.script; do
        wget -q -T 15 -O "$TMP_DIR/$f" "$REPO_RAW_BASE/files/$f" || err "Failed to download files/$f"
        [ -s "$TMP_DIR/$f" ] || err "Downloaded file $f is empty."
    done
fi

chmod 0755 "$TMP_DIR/odhcp6c" "$TMP_DIR/dhcpv6.script"
chmod 0644 "$TMP_DIR/dhcpv6.sh"

# Sanity-check binary execution before replacing system files
RC=0
"$TMP_DIR/odhcp6c" -h >/dev/null 2>&1 || RC=$?
if [ "$RC" -eq 126 ] || [ "$RC" -eq 127 ]; then
    err "odhcp6c binary cannot execute on this system (exit $RC); aborting without changes."
fi

if [ ! -d "$BACKUP_DIR" ]; then
    log "Backing up original 25.12.6 files to $BACKUP_DIR..."
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

log "Restarting wan6..."
ifdown wan6 2>/dev/null || true
sleep 2
ifup wan6
sleep 15

log "=== Verification ==="
ifstatus wan6 | grep -E '"up"|"address"' || true