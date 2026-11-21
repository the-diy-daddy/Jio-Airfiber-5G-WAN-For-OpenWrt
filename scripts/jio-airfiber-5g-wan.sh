#!/bin/sh
# ==============================================================================
# Jio Airfiber 5G WAN For OpenWrt (OpenWrt Official 25.12.x & Snapshot)
# - Designed to be staged in /tmp/5g-wan-jio-airfiber-for-openwrt over external
#   Wi-Fi client (wwan) and executed with CLI flags or interactive prompts
# - Automatically detects Official OpenWrt firmware on aarch64 (mt7986), backs up
#   stock files to /root/odhcp6c-25.12.6-backup/, and applies files/odhcp6c/*
# - Configures IPv6 SLAAC + 464XLAT (kmod-nat46) on untagged wan or VLAN 1015
# - Enforces 1280/1260/1220 split-MTU & fw4 MSS clamping for Jio NAT64 stability
# - Disables odhcpd relay conflict (allmulticast flapping fix) & flow_offloading
# - Sets Cloudflare + Google DNS with ISP DNS leak prevention
# - Installs optional procd WAN LED monitor (does NOT touch Wi-Fi settings)
# - Preserves hooks, LED daemon, and patched binaries in /etc/sysupgrade.conf
# ==============================================================================

set -eu

REPO_RAW_BASE="${REPO_RAW_BASE:-https://raw.githubusercontent.com/the-diy-daddy/Jio-Airfiber-5G-WAN-For-OpenWrt/main}"
SCRIPT_DIR="$(CDPATH= cd -- "$(dirname -- "$0")" && pwd)"
LOCAL_ODHCP_DIR="$SCRIPT_DIR/../files/odhcp6c"
LOCAL_FILES_DIR="$SCRIPT_DIR/../files"
BACKUP_DIR="/root/odhcp6c-25.12.6-backup"

# --- Configurable Defaults (override via CLI flags, env vars, or prompts) ---
WAN_MODE="${WAN_MODE:-}"                   # "untagged" or "vlan1015"
WAN_MAC="${WAN_MAC:-}"                     # e.g., "00:1A:79:b6:56:6c"
ENABLE_WAN_LED="${ENABLE_WAN_LED:-}"       # "1" or "0"
APPLY_ODHCP6C_FIX="${APPLY_ODHCP6C_FIX:-}" # "auto" (default), "1", or "0"
NON_INTERACTIVE="0"
CLAT_DEV_MTU="1280"
CLAT_ROUTE_MTU="1260"
CLAT_TCP_MSS="1220"

log()  { printf '[JIO-5G] %s\n' "$1"; }
warn() { printf '[WARN]   %s\n' "$1"; }
err()  { printf '[ERROR]  %s\n' "$1" >&2; exit 1; }

usage() {
    cat << 'EOF'
Usage: jio-airfiber-5g-wan.sh [OPTIONS]

Options:
  -m, --mac <MAC>        Clone MAC address on WAN (e.g., "00:1A:79:b6:56:6c")
      --mode <MODE>      WAN mode: "untagged" or "vlan1015"
      --untagged         Use untagged wan interface (default / bridge ODU)
      --vlan1015         Use VLAN 1015 (wan.1015 / standard Jio AirFiber ODU)
      --led              Install WAN Status LED monitor daemon (default)
      --no-led           Skip WAN Status LED monitor daemon
      --odhcp6c-fix      Force applying mt7986 (aarch64) odhcp6c bundle
      --no-odhcp6c-fix   Skip applying mt7986 (aarch64) odhcp6c bundle
  -y, --yes              Non-interactive mode (accept defaults for unset options)
  -h, --help             Show this help message

Examples:
  /tmp/5g-wan-jio-airfiber-for-openwrt/scripts/jio-airfiber-5g-wan.sh --mac "00:1A:79:b6:56:6c"
  /tmp/5g-wan-jio-airfiber-for-openwrt/scripts/jio-airfiber-5g-wan.sh --vlan1015 --mac "00:1A:79:b6:56:6c" --led
EOF
    exit 0
}

# --- 0. Parse CLI Arguments ---
while [ $# -gt 0 ]; do
    case "$1" in
        -m|--mac)
            [ $# -ge 2 ] || err "$1 requires a MAC address argument."
            WAN_MAC="$2"
            shift 2
            ;;
        --mac=*)
            WAN_MAC="${1#*=}"
            shift
            ;;
        --mode)
            [ $# -ge 2 ] || err "--mode requires 'untagged' or 'vlan1015'."
            WAN_MODE="$2"
            shift 2
            ;;
        --mode=*)
            WAN_MODE="${1#*=}"
            shift
            ;;
        --untagged)
            WAN_MODE="untagged"
            shift
            ;;
        --vlan1015)
            WAN_MODE="vlan1015"
            shift
            ;;
        --led)
            ENABLE_WAN_LED="1"
            shift
            ;;
        --no-led)
            ENABLE_WAN_LED="0"
            shift
            ;;
        --odhcp6c-fix)
            APPLY_ODHCP6C_FIX="1"
            shift
            ;;
        --no-odhcp6c-fix)
            APPLY_ODHCP6C_FIX="0"
            shift
            ;;
        -y|--yes)
            NON_INTERACTIVE="1"
            shift
            ;;
        -h|--help)
            usage
            ;;
        *)
            err "Unknown option: $1 (use --help for usage)"
            ;;
    esac
done

# --- 1. Pre-flight Checks & Release Detection ---
[ "$(id -u)" -eq 0 ] || err "Run this script as root."

ARCH="$(uname -m)"
OPENWRT_REV="unknown"
OPENWRT_DESC=""
if [ -f /etc/openwrt_release ]; then
    # shellcheck disable=SC1091
    . /etc/openwrt_release
    OPENWRT_REV="${DISTRIB_RELEASE:-unknown}"
    OPENWRT_DESC="${DISTRIB_DESCRIPTION:-}"
fi

IS_OFFICIAL=0
case "$OPENWRT_REV $OPENWRT_DESC" in
    *[Ss][Nn][Aa][Pp][Ss][Hh][Oo][Tt]*)
        IS_OFFICIAL=0
        ;;
    *)
        [ "$OPENWRT_REV" != "unknown" ] && [ -n "$OPENWRT_REV" ] && IS_OFFICIAL=1
        ;;
esac

if [ "$IS_OFFICIAL" -eq 1 ]; then
    log "Detected Official OpenWrt Release: $OPENWRT_REV ($ARCH)"
else
    log "Detected OpenWrt Snapshot Release: $OPENWRT_REV ($ARCH)"
fi

MISSING=""
for pkg in 464xlat kmod-nat46; do
    if ! opkg status "$pkg" 2>/dev/null | grep -q "Status: install" && \
       ! apk info -e "$pkg" >/dev/null 2>&1; then
        MISSING="$MISSING $pkg"
    fi
done
if [ -n "$MISSING" ]; then
    err "Missing required packages:$MISSING. Build with Firmware Selector or install them first."
fi

if ! ip route help 2>&1 | grep -qi "advmss"; then
    warn "ip-tiny / ip-full not detected; BusyBox ip may ignore advmss. Install 'ip-tiny' for full MTU/MSS support."
fi

# --- 2. Interactive Prompts (only for unset options when interactive) ---
if [ -z "$WAN_MODE" ]; then
    if [ "$NON_INTERACTIVE" = "1" ] || [ ! -t 0 ]; then
        WAN_MODE="untagged"
    else
        printf '\nSelect WAN Mode:\n  1) Untagged wan (default / bridge ODU)\n  2) VLAN 1015 (wan.1015 / standard Jio AirFiber ODU)\nChoice [1]: '
        read -r CHOICE || CHOICE="1"
        case "$CHOICE" in
            2) WAN_MODE="vlan1015" ;;
            *) WAN_MODE="untagged" ;;
        esac
    fi
fi

case "$WAN_MODE" in
    untagged|vlan1015) ;;
    *) err "Invalid WAN mode '$WAN_MODE'. Must be 'untagged' or 'vlan1015'." ;;
esac

if [ -z "$WAN_MAC" ] && [ "$NON_INTERACTIVE" = "0" ] && [ -t 0 ]; then
    printf 'Enter WAN MAC address to clone (leave blank to keep default): '
    read -r WAN_MAC || WAN_MAC=""
fi

if [ -z "$ENABLE_WAN_LED" ]; then
    if [ "$NON_INTERACTIVE" = "1" ] || [ ! -t 0 ]; then
        ENABLE_WAN_LED="1"
    else
        printf 'Install WAN Status LED monitor daemon? [Y/n]: '
        read -r LED_ANS || LED_ANS="y"
        case "$LED_ANS" in
            [nN]*) ENABLE_WAN_LED="0" ;;
            *)     ENABLE_WAN_LED="1" ;;
        esac
    fi
fi

# Automatically apply mt7986 (aarch64) odhcp6c fix on Official firmware
if [ -z "$APPLY_ODHCP6C_FIX" ] || [ "$APPLY_ODHCP6C_FIX" = "auto" ]; then
    if [ "$IS_OFFICIAL" -eq 1 ] && [ "$ARCH" = "aarch64" ]; then
        APPLY_ODHCP6C_FIX="1"
    else
        APPLY_ODHCP6C_FIX="0"
    fi
fi

# Validate MAC format if provided
if [ -n "$WAN_MAC" ]; then
    if ! echo "$WAN_MAC" | grep -Eq '^([0-9A-Fa-f]{2}:){5}[0-9A-Fa-f]{2}$'; then
        err "Invalid MAC address format: $WAN_MAC"
    fi
fi

log "Mode: $WAN_MODE | MAC Clone: ${WAN_MAC:-none} | WAN LED: $ENABLE_WAN_LED | Official odhcp6c Fix: $APPLY_ODHCP6C_FIX"

# --- 3. Apply mt7986 odhcp6c Bundle on Official Firmware ---
# Runs BEFORE modifying network/firewall/DNS so external Wi-Fi (wwan) internet stays uninterrupted.
if [ "$APPLY_ODHCP6C_FIX" = "1" ]; then
    if [ "$ARCH" != "aarch64" ]; then
        warn "Skipping odhcp6c bundle: prebuilt binary is for aarch64 (mt7986), detected $ARCH."
    else
        TMP_ODHCP="/tmp/mt7986-odhcp6c-$$"
        mkdir -p "$TMP_ODHCP"
        FETCH_OK=0

        if [ -f "$LOCAL_ODHCP_DIR/odhcp6c" ] && [ -f "$LOCAL_ODHCP_DIR/dhcpv6.sh" ] && [ -f "$LOCAL_ODHCP_DIR/dhcpv6.script" ]; then
            log "Using local mt7986 odhcp6c bundle from $LOCAL_ODHCP_DIR..."
            cp -f "$LOCAL_ODHCP_DIR/odhcp6c" "$TMP_ODHCP/odhcp6c"
            cp -f "$LOCAL_ODHCP_DIR/dhcpv6.sh" "$TMP_ODHCP/dhcpv6.sh"
            cp -f "$LOCAL_ODHCP_DIR/dhcpv6.script" "$TMP_ODHCP/dhcpv6.script"
            FETCH_OK=1
        elif [ -f "$LOCAL_FILES_DIR/odhcp6c" ] && [ -f "$LOCAL_FILES_DIR/dhcpv6.sh" ] && [ -f "$LOCAL_FILES_DIR/dhcpv6.script" ]; then
            log "Using local mt7986 odhcp6c bundle from $LOCAL_FILES_DIR..."
            cp -f "$LOCAL_FILES_DIR/odhcp6c" "$TMP_ODHCP/odhcp6c"
            cp -f "$LOCAL_FILES_DIR/dhcpv6.sh" "$TMP_ODHCP/dhcpv6.sh"
            cp -f "$LOCAL_FILES_DIR/dhcpv6.script" "$TMP_ODHCP/dhcpv6.script"
            FETCH_OK=1
        else
            log "Downloading mt7986 odhcp6c bundle from $REPO_RAW_BASE/files/odhcp6c/..."
            if wget -q -T 20 -O "$TMP_ODHCP/dhcpv6.sh" "$REPO_RAW_BASE/files/odhcp6c/dhcpv6.sh" && \
               wget -q -T 20 -O "$TMP_ODHCP/dhcpv6.script" "$REPO_RAW_BASE/files/odhcp6c/dhcpv6.script" && \
               wget -q -T 20 -O "$TMP_ODHCP/odhcp6c" "$REPO_RAW_BASE/files/odhcp6c/odhcp6c"; then
                FETCH_OK=1
            elif wget -q -T 20 -O "$TMP_ODHCP/dhcpv6.sh" "$REPO_RAW_BASE/files/dhcpv6.sh" && \
                 wget -q -T 20 -O "$TMP_ODHCP/dhcpv6.script" "$REPO_RAW_BASE/files/dhcpv6.script" && \
                 wget -q -T 20 -O "$TMP_ODHCP/odhcp6c" "$REPO_RAW_BASE/files/odhcp6c"; then
                FETCH_OK=1
            fi
        fi

        if [ "$FETCH_OK" -ne 1 ]; then
            rm -rf "$TMP_ODHCP"
            err "Failed to locate or download files/odhcp6c/* from GitHub. Verify internet & ca-bundle, then retry."
        fi

        # Validate downloaded binary and shell scripts before overwriting system files
        if ! [ -s "$TMP_ODHCP/odhcp6c" ] || [ "$(head -c 4 "$TMP_ODHCP/odhcp6c" | tr -dc 'A-Z')" != "ELF" ]; then
            rm -rf "$TMP_ODHCP"
            err "odhcp6c is not a valid ELF binary. Aborting without modifying system files."
        fi

        sed -i 's/\r$//' "$TMP_ODHCP/dhcpv6.sh" "$TMP_ODHCP/dhcpv6.script" 2>/dev/null || true
        if ! head -n 1 "$TMP_ODHCP/dhcpv6.sh" | grep -q '^#!/bin/sh' || \
           ! head -n 1 "$TMP_ODHCP/dhcpv6.script" | grep -q '^#!/bin/sh'; then
            rm -rf "$TMP_ODHCP"
            err "dhcpv6.sh or dhcpv6.script is invalid. Aborting without modifying system files."
        fi

        # Preserve stock Official files once (never overwrite an existing backup)
        if [ ! -d "$BACKUP_DIR" ]; then
            log "Backing up stock Official odhcp6c files to $BACKUP_DIR..."
            mkdir -p "$BACKUP_DIR"
            [ -f /usr/sbin/odhcp6c ] && cp -f /usr/sbin/odhcp6c "$BACKUP_DIR/odhcp6c"
            [ -f /lib/netifd/proto/dhcpv6.sh ] && cp -f /lib/netifd/proto/dhcpv6.sh "$BACKUP_DIR/dhcpv6.sh"
            [ -f /lib/netifd/dhcpv6.script ] && cp -f /lib/netifd/dhcpv6.script "$BACKUP_DIR/dhcpv6.script"
        fi

        log "Applying mt7986 odhcp6c, dhcpv6.sh, and dhcpv6.script..."
        cp -f "$TMP_ODHCP/odhcp6c" /usr/sbin/odhcp6c
        cp -f "$TMP_ODHCP/dhcpv6.sh" /lib/netifd/proto/dhcpv6.sh
        cp -f "$TMP_ODHCP/dhcpv6.script" /lib/netifd/dhcpv6.script
        chmod 0755 /usr/sbin/odhcp6c /lib/netifd/dhcpv6.script
        chmod 0644 /lib/netifd/proto/dhcpv6.sh
        rm -rf "$TMP_ODHCP"

        log "Official firmware odhcp6c fix applied! Stock backup saved in $BACKUP_DIR."
    fi
fi

# --- 4. Configure Network Devices & Interfaces ---
log "Configuring /etc/config/network..."

uci set network.globals.packet_steering='1'

uci set network.wan_dev=device
uci set network.wan_dev.name='wan'
uci set network.wan_dev.promisc='1'
uci -q delete network.wan_dev.mtu || true
if [ -n "$WAN_MAC" ]; then
    uci set network.wan_dev.macaddr="$WAN_MAC"
else
    uci -q delete network.wan_dev.macaddr || true
fi

if [ "$WAN_MODE" = "vlan1015" ]; then
    WAN6_DEV="wan.1015"
    uci set network.wan_1015=device
    uci set network.wan_1015.type='8021q'
    uci set network.wan_1015.ifname='wan'
    uci set network.wan_1015.vid='1015'
    uci set network.wan_1015.name='wan.1015'
    uci set network.wan_1015.promisc='1'
    if [ -n "$WAN_MAC" ]; then
        uci set network.wan_1015.macaddr="$WAN_MAC"
    else
        uci -q delete network.wan_1015.macaddr || true
    fi
else
    WAN6_DEV="wan"
    uci -q delete network.wan_1015 || true
fi

# Silence unused IPv4 DHCP polling on wan (does not touch external Wi-Fi wwan)
if uci -q get network.wan >/dev/null; then
    uci set network.wan.auto='0'
    uci set network.wan.peerdns='0'
fi

# Configure wan6 (SLAAC / DHCPv6)
uci set network.wan6=interface
uci set network.wan6.proto='dhcpv6'
uci set network.wan6.device="$WAN6_DEV"
uci set network.wan6.reqaddress='try'
uci set network.wan6.reqprefix='auto'
uci set network.wan6.peerdns='0'
uci set network.wan6.auto='1'

# Configure 464XLAT (clat)
uci set network.clat=interface
uci set network.clat.proto='464xlat'
uci set network.clat.tunlink='wan6'
uci set network.clat.mtu="$CLAT_DEV_MTU"
uci set network.clat.peerdns='0'
uci set network.clat.zone='wan'
uci -q delete network.clat.ip6addr || true

uci commit network

# --- 5. Firewall: Disable Flow Offloading, Ensure WAN Zone & MSS Clamp ---
log "Configuring /etc/config/firewall and fw4 MSS clamping..."

uci set firewall.@defaults[0].flow_offloading='0'
uci set firewall.@defaults[0].flow_offloading_hw='0'

WAN_ZONE_IDX=""
for idx in 0 1 2 3 4 5; do
    if [ "$(uci -q get firewall.@zone[$idx].name || true)" = "wan" ]; then
        WAN_ZONE_IDX="$idx"
        break
    fi
done

if [ -n "$WAN_ZONE_IDX" ]; then
    uci set firewall.@zone["$WAN_ZONE_IDX"].mtu_fix='1'
    CURRENT_NETS="$(uci -q get firewall.@zone["$WAN_ZONE_IDX"].network || true)"
    for net in wan6 clat; do
        case " $CURRENT_NETS " in
            *" $net "*) ;;
            *) uci add_list firewall.@zone["$WAN_ZONE_IDX"].network="$net" ;;
        esac
    done
fi
uci commit firewall

mkdir -p /etc/nftables.d
cat << EOF > /etc/nftables.d/99-clat-mss.nft
chain clat_mss_clamp {
    type filter hook forward priority mangle; policy accept;
    oifname "464-clat" tcp flags syn / syn,rst tcp option maxseg size $((CLAT_TCP_MSS + 1))-65535 tcp option maxseg size set ${CLAT_TCP_MSS}
    iifname "464-clat" tcp flags syn / syn,rst tcp option maxseg size $((CLAT_TCP_MSS + 1))-65535 tcp option maxseg size set ${CLAT_TCP_MSS}
}
EOF

# --- 6. Hotplug Hook: Split MTU (1280 device / 1260 IPv4 route / 1220 advmss) ---
log "Installing /etc/hotplug.d/iface/99-clat-mtu..."

mkdir -p /etc/hotplug.d/iface
cat << EOF > /etc/hotplug.d/iface/99-clat-mtu
#!/bin/sh
[ "\$INTERFACE" = "clat" ] && [ "\$ACTION" = "ifup" ] || exit 0
sleep 1
ip link set dev 464-clat mtu ${CLAT_DEV_MTU} 2>/dev/null || true
ip route replace default dev 464-clat metric 2048 mtu ${CLAT_ROUTE_MTU} advmss ${CLAT_TCP_MSS} 2>/dev/null || true
EOF
chmod +x /etc/hotplug.d/iface/99-clat-mtu

# --- 7. DHCP & DNS: Prevent odhcpd Relay Conflict + Cloudflare/Google DNS ---
log "Configuring dnsmasq (Cloudflare + Google DNS) and disabling odhcpd NDP relay conflict..."

uci -q delete dhcp.wan6 || true
uci set dhcp.lan.ra='server'
uci set dhcp.lan.dhcpv6='server'
uci set dhcp.lan.ndp='disabled'

uci set dhcp.@dnsmasq[0].noresolv='1'
uci -q delete dhcp.@dnsmasq[0].server || true
for dns in \
    1.1.1.1 8.8.8.8 1.0.0.1 8.8.4.4 \
    2606:4700:4700::1111 2001:4860:4860::8888 \
    2606:4700:4700::1001 2001:4860:4860::8844; do
    uci add_list dhcp.@dnsmasq[0].server="$dns"
done
uci commit dhcp

# --- 8. Optional: Install WAN Status LED Daemon ---
if [ "$ENABLE_WAN_LED" = "1" ]; then
    log "Installing WAN Status LED daemon (/usr/bin/jio-wan-led.sh)..."

    cat << 'EOF' > /usr/bin/jio-wan-led.sh
#!/bin/sh
# Jio Airfiber 5G WAN For OpenWrt — WAN & 464XLAT Status LED Monitor (excludes Wi-Fi LEDs)
# - Solid Green/Blue : Dual-stack IPv6 + 464XLAT IPv4 Online
# - Slow Blink       : IPv6 Online, 464XLAT IPv4 Degraded/Down
# - Solid Red / Fast : WAN Offline

INTERVAL=15

find_led() {
    for pattern in "$@"; do
        for path in /sys/class/leds/*; do
            [ -d "$path" ] || continue
            name="$(basename "$path")"
            case "$name" in
                *$pattern*) echo "$path"; return 0 ;;
            esac
        done
    done
    return 1
}

LED_OK="$(find_led 'green:wan' 'blue:wan' 'green:internet' 'blue:status' 'green:status' || true)"
LED_ERR="$(find_led 'red:wan' 'amber:wan' 'red:internet' 'red:status' 'amber:status' || true)"

set_led_solid() {
    [ -n "$1" ] && [ -d "$1" ] || return 0
    echo none > "$1/trigger" 2>/dev/null || true
    cat "$1/max_brightness" > "$1/brightness" 2>/dev/null || echo 1 > "$1/brightness" 2>/dev/null || true
}

set_led_off() {
    [ -n "$1" ] && [ -d "$1" ] || return 0
    echo none > "$1/trigger" 2>/dev/null || true
    echo 0 > "$1/brightness" 2>/dev/null || true
}

set_led_blink() {
    [ -n "$1" ] && [ -d "$1" ] || return 0
    echo timer > "$1/trigger" 2>/dev/null || true
    echo "${2:-500}" > "$1/delay_on" 2>/dev/null || true
    echo "${3:-500}" > "$1/delay_off" 2>/dev/null || true
}

LAST_STATE=""
while true; do
    V6_OK=0
    V4_OK=0
    ping -6 -c 1 -W 3 2606:4700:4700::1111 >/dev/null 2>&1 && V6_OK=1
    ping -4 -c 1 -W 3 1.1.1.1 >/dev/null 2>&1 && V4_OK=1

    if [ "$V6_OK" -eq 1 ] && [ "$V4_OK" -eq 1 ]; then
        STATE="dual"
    elif [ "$V6_OK" -eq 1 ]; then
        STATE="v6only"
    else
        STATE="down"
    fi

    if [ "$STATE" != "$LAST_STATE" ]; then
        case "$STATE" in
            dual)
                set_led_off "$LED_ERR"
                set_led_solid "$LED_OK"
                ;;
            v6only)
                set_led_off "$LED_ERR"
                set_led_blink "$LED_OK" 800 800
                ;;
            down)
                set_led_off "$LED_OK"
                if [ -n "$LED_ERR" ]; then
                    set_led_solid "$LED_ERR"
                else
                    set_led_blink "$LED_OK" 150 150
                fi
                ;;
        esac
        LAST_STATE="$STATE"
    fi
    sleep "$INTERVAL"
done
EOF
    chmod +x /usr/bin/jio-wan-led.sh

    cat << 'EOF' > /etc/init.d/jio-wan-led
#!/bin/sh /etc/rc.common

START=99
STOP=10
USE_PROCD=1

start_service() {
    procd_open_instance
    procd_set_param command /usr/bin/jio-wan-led.sh
    procd_set_param respawn 3600 5 5
    procd_close_instance
}
EOF
    chmod +x /etc/init.d/jio-wan-led
    /etc/init.d/jio-wan-led enable
    /etc/init.d/jio-wan-led restart
fi

# --- 9. Sysupgrade Persistence ---
log "Updating /etc/sysupgrade.conf..."
for f in \
    /etc/hotplug.d/iface/99-clat-mtu \
    /etc/nftables.d/99-clat-mss.nft \
    /usr/bin/jio-wan-led.sh \
    /etc/init.d/jio-wan-led; do
    [ -e "$f" ] || continue
    grep -qxF "$f" /etc/sysupgrade.conf 2>/dev/null || echo "$f" >> /etc/sysupgrade.conf
done

# Preserve patched odhcp6c files across sysupgrades on Official firmware
if [ -d "$BACKUP_DIR" ]; then
    for f in /usr/sbin/odhcp6c /lib/netifd/proto/dhcpv6.sh /lib/netifd/dhcpv6.script; do
        [ -e "$f" ] && (grep -qxF "$f" /etc/sysupgrade.conf 2>/dev/null || echo "$f" >> /etc/sysupgrade.conf)
    done
fi

# --- 10. Reload Services & Context-Aware Verification ---
log "Reloading odhcpd, dnsmasq, firewall, and network..."
/etc/init.d/odhcpd restart
/etc/init.d/dnsmasq restart
/etc/init.d/firewall restart
/etc/init.d/network reload

WAN_CARRIER="$(cat /sys/class/net/wan/carrier 2>/dev/null || echo 0)"

if [ "$WAN_CARRIER" = "1" ]; then
    log "WAN Ethernet link detected — waiting 20s for Jio 5G RA & 464-clat..."
    sleep 20

    if ip link show dev 464-clat >/dev/null 2>&1; then
        ip link set dev 464-clat mtu "$CLAT_DEV_MTU" 2>/dev/null || true
        ip route replace default dev 464-clat metric 2048 mtu "$CLAT_ROUTE_MTU" advmss "$CLAT_TCP_MSS" 2>/dev/null || true
    fi

    log "=== Verification Summary ==="
    ifstatus wan6 | grep -E '"up"|"address"' || true
    ip link show dev 464-clat 2>/dev/null | grep -o 'mtu [0-9]*' || echo "464-clat: DOWN (wait 15s and re-check)"
    ip route show dev 464-clat 2>/dev/null || true
    ping -6 -c 2 -W 3 2606:4700:4700::1111 >/dev/null 2>&1 && log "IPv6 Reachability: OK" || warn "IPv6 Reachability: FAILED"
    ping -4 -c 2 -W 3 1.1.1.1 >/dev/null 2>&1 && log "IPv4 (464-clat) Reachability: OK" || warn "IPv4 (464-clat) Reachability: FAILED"
else
    log "=== Installation Complete (WAN cable not plugged in yet) ==="
    log "Next steps if you installed over an external Wi-Fi client (wwan):"
    log "  1. Remove/disable your temporary external Wi-Fi client (wwan) in LuCI."
    log "  2. Plug the Jio AirFiber 5G ODU Ethernet cable into the router WAN port."
    log "  3. Reboot the router: reboot"
fi

if [ -d "$BACKUP_DIR" ]; then
    log "Rollback commands for stock Official odhcp6c (if ever needed):"
    log "  cp -f $BACKUP_DIR/odhcp6c /usr/sbin/odhcp6c"
    log "  cp -f $BACKUP_DIR/dhcpv6.sh /lib/netifd/proto/dhcpv6.sh"
    log "  cp -f $BACKUP_DIR/dhcpv6.script /lib/netifd/dhcpv6.script"
fi

log "Done! Your AP Wi-Fi settings were left untouched."
