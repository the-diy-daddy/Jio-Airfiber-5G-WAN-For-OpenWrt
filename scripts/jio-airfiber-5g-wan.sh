#!/bin/sh
# ==============================================================================
# Jio Airfiber 5G WAN For OpenWrt (Official 25.12.x & Snapshot)
# Author: The DIY Daddy (https://github.com/the-diy-daddy)
#
# Direct zero-touch one-liner (no /tmp extraction required):
#   wget -4 -qO- https://raw.githubusercontent.com/the-diy-daddy/Jio-Airfiber-5G-WAN-For-OpenWrt/main/scripts/jio-airfiber-5g-wan.sh | sh -s -- --mac "AC:10:07:27:C0:D2" -y
#
# Fully automatic end-to-end checklist:
# - Runs directly via `wget -4 -qO- ... | sh -s -- ...` OR from a local clone.
# - Automatically installs missing packages via apk/opkg (464xlat, kmod-nat46,
#   ip-tiny, luci-proto-ipv6, plus tcpdump-mini when --auto VLAN detection runs).
# - Automatically patches Official 25.12.x mt7986 (aarch64) odhcp6c atomically
#   (0755, backup in /root/odhcp6c-25.12.6-backup, rollback supported).
# - Automatically detects untagged SLAAC vs 802.1Q VLAN (1015, custom VLANs)
#   while filtering out Jio management-only VLANs (e.g. VLAN 960 2405:200:.../118).
# - VLAN ODUs (stateful DHCPv6 IA_NA + IA_PD): configures clean 802.1Q wan.<ID>
#   (mtu 1500, no promisc), reqaddress='force', MAC-based DUID-LL clientid
#   (00030001<mac>) to prevent BNG UnspecFail, lan.ip6assign='64', odhcpd server
#   mode, and installs /etc/hotplug.d/iface/98-clat-iapd so network.clat.ip6addr
#   dynamically tracks Jio's live IA_PD /64 prefix across reboots & rotations.
# - Untagged ODUs (SLAAC-only /64): configures wan_dev (promisc='1') and odhcpd
#   IPv6 relay (wan6 master -> lan) so LAN devices receive global 2409:: IPs.
# - Both modes: installs 1280/1260/1220 split-MTU hotplug (99-clat-mtu), fw4
#   MSS clamping (99-clat-mss.nft), Allow-464XLAT firewall rule, disables
#   flow_offloading, enables packet_steering, sets Google + Cloudflare IPv4/IPv6
#   DNS across WAN, dnsmasq, and LAN, registers everything in /etc/sysupgrade.conf,
#   and runs an SSH-safe detached netifd restart + live self-check.
# ==============================================================================

set -eu
trap '' HUP

REPO_RAW_BASE="${REPO_RAW_BASE:-https://raw.githubusercontent.com/the-diy-daddy/Jio-Airfiber-5G-WAN-For-OpenWrt/main}"
SCRIPT_DIR=""
case "$0" in
    */*)
        if [ -d "$(dirname -- "$0")" ]; then
            SCRIPT_DIR="$(CDPATH= cd -- "$(dirname -- "$0")" && pwd)"
        fi
        ;;
esac

BACKUP_DIR="/root/odhcp6c-25.12.6-backup"
LOG_FILE="/tmp/jio-5g-setup.log"
RESTART_LOG="/tmp/jio-network-restart.log"

# --- Configurable Defaults (override via CLI flags, env vars, or prompts) ---
WAN_MODE="${WAN_MODE:-}"                   # "auto" (default), "untagged", or "vlan"
WAN_VLAN_ID="${WAN_VLAN_ID:-}"             # e.g., "1015", "960", or any 1..4094
WAN_MAC="${WAN_MAC:-}"                     # e.g., "AC:10:07:27:C0:D2"
WAN_CLIENTID="${WAN_CLIENTID:-}"           # optional custom DHCPv6 DUID hex
NAT64_PREFIX="${NAT64_PREFIX:-64:ff9b::/96}"
IPV6_MODE="${IPV6_MODE:-auto}"             # "auto" (relay for untagged, server for VLAN IA_PD), "relay", or "server"
ENABLE_WAN_LED="${ENABLE_WAN_LED:-}"       # "1" or "0"
APPLY_ODHCP6C_FIX="${APPLY_ODHCP6C_FIX:-}" # "auto" (default), "1", or "0"
AUTO_PKG_INSTALL="${AUTO_PKG_INSTALL:-1}"  # "1" (auto apk/opkg add) or "0"
NO_RESTART="${NO_RESTART:-0}"
NON_INTERACTIVE=0
PKG_UPDATED=0
CLAT_DEV_MTU="1280"
CLAT_ROUTE_MTU="1260"
CLAT_TCP_MSS="1220"
DNS_V4_LIST="8.8.8.8 1.1.1.1 8.8.4.4 1.0.0.1"
DNS_V4_CSV="8.8.8.8,1.1.1.1,8.8.4.4,1.0.0.1"
DNS_V6_LIST="2001:4860:4860::8888 2606:4700:4700::1111 2001:4860:4860::8844 2606:4700:4700::1001"

: > "$LOG_FILE" 2>/dev/null || true

log()  { printf '[JIO-5G] %s\n' "$1" | tee -a "$LOG_FILE"; }
warn() { printf '[WARN]   %s\n' "$1" | tee -a "$LOG_FILE"; }
err()  { printf '[ERROR]  %s\n' "$1" | tee -a "$LOG_FILE" >&2; exit 1; }

can_prompt() {
    [ "$NON_INTERACTIVE" -eq 0 ] && { [ -t 0 ] || [ -r /dev/tty ]; }
}

read_prompt() {
    local varname="$1"
    if [ -t 0 ]; then
        read -r "$varname" || eval "$varname=''"
    elif [ -r /dev/tty ]; then
        read -r "$varname" </dev/tty || eval "$varname=''"
    else
        eval "$varname=''"
    fi
}

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

pkg_installed() {
    local pkg="$1"
    if command -v apk >/dev/null 2>&1; then
        apk info -e "$pkg" >/dev/null 2>&1
    else
        opkg status "$pkg" 2>/dev/null | grep -q "Status: install"
    fi
}

install_packages() {
    local missing=""
    local p
    for p in "$@"; do
        if ! pkg_installed "$p"; then
            missing="$missing $p"
        fi
    done

    [ -n "$missing" ] || return 0

    if [ "$AUTO_PKG_INSTALL" != "1" ]; then
        warn "Skipping auto-install (--no-pkg-install). Missing:$missing"
        return 1
    fi

    log "Installing missing packages:$missing..."
    if command -v apk >/dev/null 2>&1; then
        if [ "$PKG_UPDATED" -eq 0 ]; then
            apk update >>"$LOG_FILE" 2>&1 || return 1
            PKG_UPDATED=1
        fi
        # shellcheck disable=SC2086
        apk add $missing >>"$LOG_FILE" 2>&1 || return 1
    elif command -v opkg >/dev/null 2>&1; then
        if [ "$PKG_UPDATED" -eq 0 ]; then
            opkg update >>"$LOG_FILE" 2>&1 || return 1
            PKG_UPDATED=1
        fi
        # shellcheck disable=SC2086
        opkg install $missing >>"$LOG_FILE" 2>&1 || return 1
    else
        warn "Neither apk nor opkg found; cannot auto-install:$missing"
        return 1
    fi
    return 0
}

mac_to_duid_ll() {
    local hex
    hex="$(printf '%s' "$1" | tr -d ':' | tr 'A-F' 'a-f')"
    if [ "${#hex}" -eq 12 ]; then
        printf '00030001%s' "$hex"
    fi
}

validate_vlan_id() {
    case "$1" in
        ''|*[!0-9]*) err "Invalid VLAN ID '$1'. Must be an integer between 1 and 4094." ;;
    esac
    if [ "$1" -lt 1 ] || [ "$1" -gt 4094 ]; then
        err "Invalid VLAN ID '$1'. Must be between 1 and 4094."
    fi
}

# --- VLAN Auto-Detection (untagged vs VLAN 1015 / custom VLAN) ---
probe_vlan_id() {
    local vid="$1"
    local probe_mac="$2"
    local probe_duid="$3"
    local dev="wan.${vid}"
    local created=0
    local cap="/tmp/jio-probe-v${vid}-$$.log"
    local ping_out="/tmp/jio-ping-v${vid}-$$.log"
    local score=0
    local own_ll=""
    local tpid=""
    local opid=""

    if ip link show dev "$dev" >/dev/null 2>&1 && ip -6 addr show dev "$dev" 2>/dev/null | grep -qi '2409:'; then
        echo 3
        return 0
    fi
    if ! ip link show dev "$dev" >/dev/null 2>&1; then
        if ! ip link add link wan name "$dev" type vlan id "$vid" 2>/dev/null; then
            echo 0
            return 0
        fi
        created=1
    fi
    if [ -n "$probe_mac" ]; then
        ip link set dev "$dev" address "$probe_mac" 2>/dev/null || true
    fi
    ip link set dev "$dev" mtu 1500 up 2>/dev/null || true
    sleep 2

    own_ll="$(ip -6 addr show dev "$dev" scope link 2>/dev/null | awk '/inet6 fe80/{sub(/\/.*/,"",$2); print tolower($2); exit}' || true)"

    if command -v tcpdump >/dev/null 2>&1; then
        tcpdump -i wan -e -nn -vv -l "vlan ${vid} and (icmp6 or port 546 or port 547)" >"$cap" 2>/dev/null &
        tpid=$!
        sleep 1
    fi

    ping -6 -I "$dev" -c 2 -W 2 ff02::2 >"$ping_out" 2>&1 || true

    if command -v odhcp6c >/dev/null 2>&1; then
        if [ -n "$probe_duid" ]; then
            odhcp6c -s /bin/true -Nforce -P0 -c"$probe_duid" -t12 "$dev" >/dev/null 2>&1 &
        else
            odhcp6c -s /bin/true -Nforce -P0 -t12 "$dev" >/dev/null 2>&1 &
        fi
        opid=$!
        local w=0
        while [ "$w" -lt 12 ]; do
            if [ -f "$cap" ] && grep -qiE '2409:[0-9a-f:]+' "$cap" 2>/dev/null; then
                break
            fi
            sleep 1
            w=$((w + 1))
        done
        kill "$opid" 2>/dev/null || true
        wait "$opid" 2>/dev/null || true
    else
        sleep 6
    fi

    if [ -n "$tpid" ]; then
        kill "$tpid" 2>/dev/null || true
        wait "$tpid" 2>/dev/null || true
    fi

    # Classify captured traffic on this VLAN:
    # 3 = Confirmed Jio 5G global 2409: prefix in RA or DHCPv6
    # 2 = Confirmed foreign IPv6 router / DHCPv6 server (excluding 2405:200:.../118 management-only)
    # 1 = Management/ACS VLAN only (e.g., VLAN 960 advertising 2405:200:... /118)
    # 0 = No foreign IPv6 response
    if [ -f "$cap" ] && grep -qiE '2409:[0-9a-f:]+' "$cap" 2>/dev/null; then
        score=3
    elif [ -f "$cap" ] && grep -qiE '2405:200:[0-9a-f:]+/118' "$cap" 2>/dev/null; then
        score=1
    else
        local foreign_ping=0
        if [ -n "$own_ll" ]; then
            if grep -i 'bytes from fe80::' "$ping_out" 2>/dev/null | grep -viF "$own_ll" >/dev/null 2>&1; then
                foreign_ping=1
            fi
        elif grep -qi 'bytes from fe80::' "$ping_out" 2>/dev/null; then
            foreign_ping=1
        fi

        if [ "$foreign_ping" -eq 1 ] || { [ -f "$cap" ] && grep -qiE 'dhcp6 (advertise|reply)|router advertisement' "$cap" 2>/dev/null; }; then
            score=2
        fi
    fi

    rm -f "$cap" "$ping_out"
    if [ "$created" -eq 1 ]; then
        ip link del "$dev" 2>/dev/null || true
    fi
    echo "$score"
}

probe_untagged_wan() {
    local probe_mac="$1"
    local cap="/tmp/jio-probe-untagged-$$.log"
    local ping_out="/tmp/jio-ping-untagged-$$.log"
    local own_ll=""
    local tpid=""
    local opid=""
    local score=0

    if ip -6 addr show dev wan 2>/dev/null | grep -qi '2409:'; then
        echo 3
        return 0
    fi

    if [ -n "$probe_mac" ]; then
        local cur_mac
        cur_mac="$(cat /sys/class/net/wan/address 2>/dev/null | tr 'A-F' 'a-f' || true)"
        if [ "$cur_mac" != "$(printf '%s' "$probe_mac" | tr 'A-F' 'a-f')" ]; then
            ip link set dev wan down 2>/dev/null || true
            ip link set dev wan address "$probe_mac" 2>/dev/null || true
            ip link set dev wan promisc on up 2>/dev/null || true
            sleep 3
        fi
    fi

    own_ll="$(ip -6 addr show dev wan scope link 2>/dev/null | awk '/inet6 fe80/{sub(/\/.*/,"",$2); print tolower($2); exit}' || true)"

    if command -v tcpdump >/dev/null 2>&1; then
        tcpdump -i wan -e -nn -vv -l 'not vlan and (icmp6 or port 546 or port 547)' >"$cap" 2>/dev/null &
        tpid=$!
        sleep 1
    fi

    ping -6 -I wan -c 2 -W 2 ff02::2 >"$ping_out" 2>&1 || true

    if command -v odhcp6c >/dev/null 2>&1; then
        odhcp6c -s /bin/true -Ntry -P0 -t12 wan >/dev/null 2>&1 &
        opid=$!
        local w=0
        while [ "$w" -lt 12 ]; do
            if [ -f "$cap" ] && grep -qiE '2409:[0-9a-f:]+' "$cap" 2>/dev/null; then
                break
            fi
            sleep 1
            w=$((w + 1))
        done
        kill "$opid" 2>/dev/null || true
        wait "$opid" 2>/dev/null || true
    else
        sleep 6
    fi

    if [ -n "$tpid" ]; then
        kill "$tpid" 2>/dev/null || true
        wait "$tpid" 2>/dev/null || true
    fi

    if [ -f "$cap" ] && grep -qiE '2409:[0-9a-f:]+' "$cap" 2>/dev/null; then
        score=3
    else
        local foreign_ping=0
        if [ -n "$own_ll" ]; then
            if grep -i 'bytes from fe80::' "$ping_out" 2>/dev/null | grep -viF "$own_ll" >/dev/null 2>&1; then
                foreign_ping=1
            fi
        elif grep -qi 'bytes from fe80::' "$ping_out" 2>/dev/null; then
            foreign_ping=1
        fi
        if [ "$foreign_ping" -eq 1 ] || { [ -f "$cap" ] && grep -qiE 'router advertisement|dhcp6 (advertise|reply)' "$cap" 2>/dev/null; }; then
            score=2
        fi
    fi

    rm -f "$cap" "$ping_out"
    echo "$score"
}

detect_jio_wan_mode() {
    log "Running automatic Jio ODU WAN / VLAN detection on 'wan'..."

    ip link set dev wan promisc on up 2>/dev/null || true
    sleep 2
    local carrier
    carrier="$(cat /sys/class/net/wan/carrier 2>/dev/null || echo 0)"
    if [ "$carrier" != "1" ]; then
        warn "No Ethernet link detected on 'wan' port (ODU not plugged in yet)."
        warn "Defaulting to 'untagged'. Plug in the Jio ODU and re-run with --auto, or specify --vlan 1015 / --untagged."
        WAN_MODE="untagged"
        WAN_VLAN_ID=""
        return 0
    fi

    if ! command -v tcpdump >/dev/null 2>&1; then
        install_packages tcpdump-mini || install_packages tcpdump || warn "tcpdump unavailable; detection will rely on active IPv6 probing."
    fi

    local probe_mac="$WAN_MAC"
    if [ -z "$probe_mac" ] && [ -r /sys/class/net/wan/address ]; then
        probe_mac="$(cat /sys/class/net/wan/address)"
    fi
    local probe_duid="$WAN_CLIENTID"
    if [ -z "$probe_duid" ] && [ -n "$probe_mac" ]; then
        probe_duid="$(mac_to_duid_ll "$probe_mac")"
    fi

    # Passively discover any 802.1Q VLAN IDs announced by the ODU (10 seconds)
    local discovered_vlans=""
    if command -v tcpdump >/dev/null 2>&1; then
        local sniff_file="/tmp/jio-vlan-sniff-$$.log"
        log "Listening for 802.1Q VLAN tags on 'wan' (10s)..."
        tcpdump -i wan -e -nn -l vlan >"$sniff_file" 2>/dev/null &
        local spid=$!
        sleep 10
        kill "$spid" 2>/dev/null || true
        wait "$spid" 2>/dev/null || true
        discovered_vlans="$(grep -o 'vlan [0-9][0-9]*' "$sniff_file" 2>/dev/null | awk '{print $2}' | sort -nu | tr '\n' ' ' || true)"
        rm -f "$sniff_file"
    fi

    # Always include 1015 as a standard Jio AirFiber probe candidate alongside passively discovered VLANs
    local candidates="$discovered_vlans"
    case " $candidates " in
        *" 1015 "*) ;;
        *) candidates="${candidates}1015 " ;;
    esac
    log "Probe candidates: untagged + VLANs [$(printf '%s' "$candidates" | sed 's/ $//')]"

    local untagged_score=0
    untagged_score="$(probe_untagged_wan "$probe_mac" || echo 0)"
    untagged_score="${untagged_score:-0}"
    log "  Probe untagged wan -> score=$untagged_score"

    local best_vlan=""
    local best_vlan_score=0
    local vid vscore
    for vid in $candidates; do
        vscore="$(probe_vlan_id "$vid" "$probe_mac" "$probe_duid" || echo 0)"
        vscore="${vscore:-0}"
        log "  Probe VLAN $vid (wan.$vid) -> score=$vscore"
        if [ "$vscore" -gt "$best_vlan_score" ]; then
            best_vlan_score="$vscore"
            best_vlan="$vid"
        fi
    done

    # Decision: prefer confirmed 2409: internet (score 3), then active BNG/router (score 2).
    # Never auto-pick management-only VLANs (score 1, e.g. 2405:200:.../118 on VLAN 960).
    if [ "$best_vlan_score" -ge 3 ]; then
        WAN_MODE="vlan"
        WAN_VLAN_ID="$best_vlan"
        log "Auto-detected Jio 5G Internet on VLAN $WAN_VLAN_ID (confirmed 2409: prefix)!"
    elif [ "$untagged_score" -ge 3 ]; then
        WAN_MODE="untagged"
        WAN_VLAN_ID=""
        log "Auto-detected Jio 5G Internet on untagged 'wan' (confirmed 2409: prefix)!"
    elif [ "$best_vlan_score" -ge 2 ] && [ "$untagged_score" -lt 2 ]; then
        WAN_MODE="vlan"
        WAN_VLAN_ID="$best_vlan"
        log "Auto-detected Jio 5G WAN on VLAN $WAN_VLAN_ID (active BNG response)."
    elif [ "$untagged_score" -ge 2 ]; then
        WAN_MODE="untagged"
        WAN_VLAN_ID=""
        log "Auto-detected Jio 5G WAN on untagged 'wan' (active IPv6 router response)."
    else
        warn "Could not confirm an active 2409: prefix on untagged or VLANs (ODU may still be booting or MAC-locked)."
        warn "Defaulting to 'untagged'. You can override anytime with --vlan 1015, --vlan 960, or --untagged."
        WAN_MODE="untagged"
        WAN_VLAN_ID=""
    fi
}

usage() {
    cat << 'EOF'
Usage: jio-airfiber-5g-wan.sh [OPTIONS]

WAN Mode Options:
  --auto                   Auto-detect untagged vs VLAN ID on 'wan' (default with -y)
  --untagged               Untagged 'wan' mode (SLAAC /64 + IPv6 relay)
  --vlan <ID>              802.1Q VLAN mode for any VLAN ID (e.g. --vlan 1015 or --vlan 960)
  --vlan1015               Shorthand for --vlan 1015 (stateful DHCPv6 IA_NA + IA_PD)
  --vlan960                Shorthand for --vlan 960
  --mode <mode>            "auto", "untagged", "vlan1015", or "vlan960"

Network & DNS Options:
  --mac <MAC>              WAN MAC address to clone (e.g. "AC:10:07:27:C0:D2")
  --clientid <HEX>         Custom DHCPv6 Client-ID / DUID hex (default in VLAN mode: 00030001<mac>)
  --nat64-prefix <PREFIX>  NAT64 IPv6 prefix (default: 64:ff9b::/96)
  --ipv6-mode <mode>       LAN IPv6 mode: "auto" (default), "relay", or "server"
                           ("auto" uses relay for untagged SLAAC, server for VLAN IA_PD)

System & Execution Options:
  --led / --no-led         Install (default) or skip WAN status LED daemon
  --odhcp6c-fix            Force applying mt7986 (aarch64) odhcp6c bundle
  --no-odhcp6c-fix         Skip applying odhcp6c bundle
  --no-pkg-install         Skip automatic apk/opkg package installation
  --no-restart             Do not trigger network restart (apply via reboot later)
  -y, --yes                Non-interactive mode (accept defaults for unspecified options)
  -h, --help               Show this help message
EOF
    exit 0
}

# --- Parse CLI Arguments ---
while [ "$#" -gt 0 ]; do
    case "$1" in
        --mac|-m)
            [ "$#" -ge 2 ] || err "Option $1 requires a MAC address."
            WAN_MAC="$2"
            shift 2
            ;;
        --mac=*)
            WAN_MAC="${1#*=}"
            shift
            ;;
        --clientid)
            [ "$#" -ge 2 ] || err "Option --clientid requires a hex DUID."
            WAN_CLIENTID="$2"
            shift 2
            ;;
        --clientid=*)
            WAN_CLIENTID="${1#*=}"
            shift
            ;;
        --mode)
            [ "$#" -ge 2 ] || err "Option --mode requires 'auto', 'untagged', 'vlan1015', or 'vlan960'."
            case "$2" in
                auto)     WAN_MODE="auto"; WAN_VLAN_ID="" ;;
                untagged) WAN_MODE="untagged"; WAN_VLAN_ID="" ;;
                vlan1015) WAN_MODE="vlan"; WAN_VLAN_ID="1015" ;;
                vlan960)  WAN_MODE="vlan"; WAN_VLAN_ID="960" ;;
                *) err "Invalid --mode '$2'. Use auto, untagged, vlan1015, vlan960, or --vlan <ID>." ;;
            esac
            shift 2
            ;;
        --mode=*)
            val="${1#*=}"
            case "$val" in
                auto)     WAN_MODE="auto"; WAN_VLAN_ID="" ;;
                untagged) WAN_MODE="untagged"; WAN_VLAN_ID="" ;;
                vlan1015) WAN_MODE="vlan"; WAN_VLAN_ID="1015" ;;
                vlan960)  WAN_MODE="vlan"; WAN_VLAN_ID="960" ;;
                *) err "Invalid --mode='$val'. Use auto, untagged, vlan1015, vlan960, or --vlan <ID>." ;;
            esac
            shift
            ;;
        --auto)
            WAN_MODE="auto"
            WAN_VLAN_ID=""
            shift
            ;;
        --untagged)
            WAN_MODE="untagged"
            WAN_VLAN_ID=""
            shift
            ;;
        --vlan)
            [ "$#" -ge 2 ] || err "Option --vlan requires a VLAN ID (1-4094)."
            validate_vlan_id "$2"
            WAN_MODE="vlan"
            WAN_VLAN_ID="$2"
            shift 2
            ;;
        --vlan=*)
            val="${1#*=}"
            validate_vlan_id "$val"
            WAN_MODE="vlan"
            WAN_VLAN_ID="$val"
            shift
            ;;
        --vlan1015)
            WAN_MODE="vlan"
            WAN_VLAN_ID="1015"
            shift
            ;;
        --vlan960)
            WAN_MODE="vlan"
            WAN_VLAN_ID="960"
            shift
            ;;
        --nat64-prefix)
            [ "$#" -ge 2 ] || err "Option --nat64-prefix requires an IPv6 prefix."
            NAT64_PREFIX="$2"
            shift 2
            ;;
        --nat64-prefix=*)
            NAT64_PREFIX="${1#*=}"
            shift
            ;;
        --ipv6-mode)
            [ "$#" -ge 2 ] || err "Option --ipv6-mode requires 'auto', 'relay', or 'server'."
            IPV6_MODE="$2"
            shift 2
            ;;
        --ipv6-mode=*)
            IPV6_MODE="${1#*=}"
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
        --no-pkg-install)
            AUTO_PKG_INSTALL="0"
            shift
            ;;
        --no-restart)
            NO_RESTART="1"
            shift
            ;;
        -y|--yes)
            NON_INTERACTIVE=1
            shift
            ;;
        -h|--help)
            usage
            ;;
        *)
            err "Unknown argument: $1 (use --help for usage)"
            ;;
    esac
done

# --- 1. Pre-flight Checks, Release Detection & Auto Package Install ---
if [ "$(id -u)" -ne 0 ]; then
    err "Run this script as root."
fi

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
        if [ "$OPENWRT_REV" != "unknown" ] && [ -n "$OPENWRT_REV" ]; then
            IS_OFFICIAL=1
        fi
        ;;
esac

if [ "$IS_OFFICIAL" -eq 1 ]; then
    log "Detected Official OpenWrt Release: $OPENWRT_REV ($ARCH)"
else
    log "Detected OpenWrt Snapshot Release: $OPENWRT_REV ($ARCH)"
fi

# Automatically download & install any missing required packages over temporary wwan/WAN
if ! install_packages 464xlat kmod-nat46 ip-tiny luci-proto-ipv6; then
    warn "Automatic package installation failed (check internet/wwan connectivity)."
fi

MISSING=""
for pkg in 464xlat kmod-nat46; do
    if ! pkg_installed "$pkg"; then
        MISSING="$MISSING $pkg"
    fi
done
if [ -n "$MISSING" ]; then
    err "Missing required packages:$MISSING. Connect temporary wwan internet or build with Firmware Selector."
fi

if ! ip route help 2>&1 | grep -qi "advmss"; then
    warn "ip-tiny / ip-full not detected; BusyBox ip may ignore advmss. Install 'ip-tiny' for full MTU/MSS support."
fi

# --- 2. Interactive Prompts (only for options not supplied via CLI/env) ---
if [ -z "$WAN_MODE" ]; then
    if can_prompt; then
        printf '\nSelect Jio 5G WAN Mode:\n'
        printf '  1) Auto-Detect VLAN / Untagged (Recommended when ODU is plugged into WAN)\n'
        printf '  2) Untagged wan (SLAAC /64 + IPv6 relay)\n'
        printf '  3) VLAN 1015 / wan.1015 (Stateful DHCPv6 IA_NA + IA_PD)\n'
        printf '  4) VLAN 960  / wan.960\n'
        printf '  5) Custom VLAN ID\n'
        printf 'Choice [1]: '
        read_prompt CHOICE
        case "${CHOICE:-1}" in
            2) WAN_MODE="untagged"; WAN_VLAN_ID="" ;;
            3) WAN_MODE="vlan"; WAN_VLAN_ID="1015" ;;
            4) WAN_MODE="vlan"; WAN_VLAN_ID="960" ;;
            5)
                printf 'Enter custom VLAN ID (1-4094): '
                read_prompt WAN_VLAN_ID
                validate_vlan_id "$WAN_VLAN_ID"
                WAN_MODE="vlan"
                ;;
            *) WAN_MODE="auto"; WAN_VLAN_ID="" ;;
        esac
    else
        WAN_MODE="auto"
    fi
fi

if [ -z "$WAN_MAC" ] && can_prompt; then
    printf 'Enter Jio WAN MAC address to clone (leave blank to keep default): '
    read_prompt WAN_MAC
fi

if [ -n "$WAN_MAC" ]; then
    if ! echo "$WAN_MAC" | grep -Eq '^([0-9A-Fa-f]{2}:){5}[0-9A-Fa-f]{2}$'; then
        err "Invalid MAC address format: $WAN_MAC"
    fi
fi

if [ -z "$ENABLE_WAN_LED" ]; then
    if can_prompt; then
        printf 'Install WAN Status LED monitor daemon? [Y/n]: '
        read_prompt LED_ANS
        case "${LED_ANS:-y}" in
            [nN]*) ENABLE_WAN_LED="0" ;;
            *)     ENABLE_WAN_LED="1" ;;
        esac
    else
        ENABLE_WAN_LED="1"
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

case "$IPV6_MODE" in
    auto|relay|server) ;;
    *) err "Invalid IPv6 mode '$IPV6_MODE'. Must be 'auto', 'relay', or 'server'." ;;
esac

# --- 3. Atomically Apply mt7986 odhcp6c Bundle on Official Firmware ---
# (Installed before --auto probing so probing uses the working odhcp6c binary)
if [ "$APPLY_ODHCP6C_FIX" = "1" ]; then
    if [ "$ARCH" != "aarch64" ]; then
        warn "Skipping odhcp6c bundle: prebuilt binary is for aarch64 (mt7986), detected $ARCH."
    else
        TMP_ODHCP="/tmp/mt7986-odhcp6c-$$"
        mkdir -p "$TMP_ODHCP"
        FETCH_OK=0

        LOCAL_FOUND=""
        if [ -n "$SCRIPT_DIR" ]; then
            for candidate in "$SCRIPT_DIR/../files/odhcp6c" "$SCRIPT_DIR/../files"; do
                if [ -f "$candidate/odhcp6c" ] && [ -f "$candidate/dhcpv6.sh" ] && [ -f "$candidate/dhcpv6.script" ]; then
                    LOCAL_FOUND="$candidate"
                    break
                fi
            done
        fi

        if [ -n "$LOCAL_FOUND" ]; then
            log "Using local mt7986 odhcp6c bundle from $LOCAL_FOUND..."
            cp -f "$LOCAL_FOUND/odhcp6c" "$TMP_ODHCP/odhcp6c"
            cp -f "$LOCAL_FOUND/dhcpv6.sh" "$TMP_ODHCP/dhcpv6.sh"
            cp -f "$LOCAL_FOUND/dhcpv6.script" "$TMP_ODHCP/dhcpv6.script"
            FETCH_OK=1
        else
            log "Downloading mt7986 odhcp6c bundle from GitHub ($REPO_RAW_BASE)..."
            if fetch_url "$TMP_ODHCP/dhcpv6.sh" "$REPO_RAW_BASE/files/odhcp6c/dhcpv6.sh" && \
               fetch_url "$TMP_ODHCP/dhcpv6.script" "$REPO_RAW_BASE/files/odhcp6c/dhcpv6.script" && \
               fetch_url "$TMP_ODHCP/odhcp6c" "$REPO_RAW_BASE/files/odhcp6c/odhcp6c"; then
                FETCH_OK=1
            elif fetch_url "$TMP_ODHCP/dhcpv6.sh" "$REPO_RAW_BASE/files/dhcpv6.sh" && \
                 fetch_url "$TMP_ODHCP/dhcpv6.script" "$REPO_RAW_BASE/files/dhcpv6.script" && \
                 fetch_url "$TMP_ODHCP/odhcp6c" "$REPO_RAW_BASE/files/odhcp6c"; then
                FETCH_OK=1
            fi
        fi

        if [ "$FETCH_OK" -ne 1 ]; then
            rm -rf "$TMP_ODHCP"
            err "Could not locate local files/ or download odhcp6c bundle from GitHub."
        fi

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

        if [ ! -d "$BACKUP_DIR" ]; then
            log "Backing up stock Official odhcp6c files to $BACKUP_DIR..."
            mkdir -p "$BACKUP_DIR"
            if [ -f /usr/sbin/odhcp6c ]; then cp -f /usr/sbin/odhcp6c "$BACKUP_DIR/odhcp6c"; fi
            if [ -f /lib/netifd/proto/dhcpv6.sh ]; then cp -f /lib/netifd/proto/dhcpv6.sh "$BACKUP_DIR/dhcpv6.sh"; fi
            if [ -f /lib/netifd/dhcpv6.script ]; then cp -f /lib/netifd/dhcpv6.script "$BACKUP_DIR/dhcpv6.script"; fi
        fi

        log "Atomically installing odhcp6c, dhcpv6.sh, and dhcpv6.script (chmod 0755)..."
        atomic_install "$TMP_ODHCP/odhcp6c" /usr/sbin/odhcp6c 0755
        atomic_install "$TMP_ODHCP/dhcpv6.sh" /lib/netifd/proto/dhcpv6.sh 0755
        atomic_install "$TMP_ODHCP/dhcpv6.script" /lib/netifd/dhcpv6.script 0755
        rm -rf "$TMP_ODHCP"

        if ! (cd /lib/netifd/proto && ./dhcpv6.sh "" dump 2>/dev/null | grep -q '"dhcpv6"'); then
            err "dhcpv6.sh protocol dump test failed after installation!"
        fi

        log "Official firmware odhcp6c fix installed & verified (backup in $BACKUP_DIR)."
    fi
fi

# --- 3b. Run Auto-Detection if Requested ---
if [ "$WAN_MODE" = "auto" ]; then
    detect_jio_wan_mode
fi

case "$WAN_MODE" in
    untagged)
        EFFECTIVE_IPV6_MODE="$IPV6_MODE"
        if [ "$EFFECTIVE_IPV6_MODE" = "auto" ]; then
            EFFECTIVE_IPV6_MODE="relay"
        fi
        ;;
    vlan)
        validate_vlan_id "$WAN_VLAN_ID"
        EFFECTIVE_IPV6_MODE="$IPV6_MODE"
        if [ "$EFFECTIVE_IPV6_MODE" = "auto" ]; then
            EFFECTIVE_IPV6_MODE="server"
        fi
        ;;
    *)
        err "Invalid WAN mode '$WAN_MODE'."
        ;;
esac

log "Final Config -> Mode: $WAN_MODE${WAN_VLAN_ID:+ (VLAN $WAN_VLAN_ID)} | IPv6 LAN: $EFFECTIVE_IPV6_MODE | MAC: ${WAN_MAC:-default} | NAT64: $NAT64_PREFIX | LED: $ENABLE_WAN_LED"

# --- 4. Configure Network Devices & Interfaces ---
log "Configuring /etc/config/network..."

uci set network.globals.packet_steering='1'

# Clean up any prior script-managed VLAN / wan device entries to avoid duplicates
for oldsec in wan_dev wan_vlan wan_1015 wan_vlan1015 wan_960 wan_vlan960; do
    uci -q delete "network.$oldsec" || true
done

STOCK_WAN_MAC=""
WAN_SECS="$(uci show network 2>/dev/null | sed -n "s/^network\.\(@device\[[0-9]*\]\)\.name='wan'$/\1/p" | awk '{a[NR]=$0} END {for(i=NR;i>=1;i--) print a[i]}' || true)"
for sec in $WAN_SECS; do
    if [ -z "$STOCK_WAN_MAC" ]; then
        STOCK_WAN_MAC="$(uci -q get "network.$sec.macaddr" || true)"
    fi
    uci -q delete "network.$sec" || true
done

EFFECTIVE_MAC="$WAN_MAC"
if [ -z "$EFFECTIVE_MAC" ]; then
    EFFECTIVE_MAC="$STOCK_WAN_MAC"
fi
if [ -z "$EFFECTIVE_MAC" ] && [ -r /sys/class/net/wan/address ]; then
    EFFECTIVE_MAC="$(cat /sys/class/net/wan/address)"
fi

if [ "$WAN_MODE" = "vlan" ]; then
    WAN6_DEV="wan.${WAN_VLAN_ID}"

    # VLAN-tagged Jio ODU (e.g. VLAN 1015): keep physical 'wan' clean (no promisc)
    # and bind MAC + MTU 1500 directly on the 802.1Q VLAN device.
    uci set network.wan_vlan=device
    uci set network.wan_vlan.type='8021q'
    uci set network.wan_vlan.ifname='wan'
    uci set network.wan_vlan.vid="$WAN_VLAN_ID"
    uci set network.wan_vlan.name="$WAN6_DEV"
    uci set network.wan_vlan.mtu='1500'
    if [ -n "$WAN_MAC" ]; then
        uci set network.wan_vlan.macaddr="$WAN_MAC"
    elif [ -n "$STOCK_WAN_MAC" ]; then
        uci set network.wan_vlan.macaddr="$STOCK_WAN_MAC"
    fi

    if uci -q get network.wan >/dev/null; then
        uci set network.wan.auto='1'
        uci set network.wan.peerdns='0'
        uci -q delete network.wan.dns || true
        for dns in $DNS_V4_LIST; do
            uci add_list network.wan.dns="$dns"
        done
    fi

    # Deterministic MAC-based DUID-LL prevents Jio BNG DHCPv6 UnspecFail
    EFFECTIVE_CLIENTID="$WAN_CLIENTID"
    if [ -z "$EFFECTIVE_CLIENTID" ] && [ -n "$EFFECTIVE_MAC" ]; then
        EFFECTIVE_CLIENTID="$(mac_to_duid_ll "$EFFECTIVE_MAC")"
    fi

    uci set network.wan6=interface
    uci set network.wan6.proto='dhcpv6'
    uci set network.wan6.device="$WAN6_DEV"
    uci set network.wan6.reqaddress='force'
    uci set network.wan6.reqprefix='auto'
    uci set network.wan6.delegate='1'
    uci set network.wan6.metric='10'
    uci set network.wan6.peerdns='0'
    uci set network.wan6.auto='1'
    uci set network.wan6.iface_464xlat='0'
    if [ -n "$EFFECTIVE_CLIENTID" ]; then
        uci set network.wan6.clientid="$EFFECTIVE_CLIENTID"
    else
        uci -q delete network.wan6.clientid || true
    fi
    uci -q delete network.wan6.dns || true
    for dns6 in $DNS_V6_LIST; do
        uci add_list network.wan6.dns="$dns6"
    done

    # Delegate IA_PD /64 directly to LAN
    uci set network.lan.ip6assign='64'
else
    WAN6_DEV="wan"

    # Untagged Jio ODU (SLAAC /64): promisc='1' prevents mt7530 Proxy NDP drops
    uci set network.wan_dev=device
    uci set network.wan_dev.name='wan'
    uci set network.wan_dev.promisc='1'
    uci -q delete network.wan_dev.mtu || true
    if [ -n "$WAN_MAC" ]; then
        uci set network.wan_dev.macaddr="$WAN_MAC"
    elif [ -n "$STOCK_WAN_MAC" ]; then
        uci set network.wan_dev.macaddr="$STOCK_WAN_MAC"
    else
        uci -q delete network.wan_dev.macaddr || true
    fi

    if uci -q get network.wan >/dev/null; then
        uci set network.wan.auto='0'
        uci set network.wan.peerdns='0'
        uci -q delete network.wan.dns || true
        for dns in $DNS_V4_LIST; do
            uci add_list network.wan.dns="$dns"
        done
    fi

    uci set network.wan6=interface
    uci set network.wan6.proto='dhcpv6'
    uci set network.wan6.device="$WAN6_DEV"
    uci set network.wan6.reqaddress='try'
    uci set network.wan6.reqprefix='auto'
    uci set network.wan6.peerdns='0'
    uci set network.wan6.auto='1'
    uci set network.wan6.iface_464xlat='0'
    uci -q delete network.wan6.delegate || true
    uci -q delete network.wan6.metric || true
    if [ -n "$WAN_CLIENTID" ]; then
        uci set network.wan6.clientid="$WAN_CLIENTID"
    else
        uci -q delete network.wan6.clientid || true
    fi
    uci -q delete network.wan6.dns || true
    for dns6 in $DNS_V6_LIST; do
        uci add_list network.wan6.dns="$dns6"
    done
fi

uci set network.clat=interface
uci set network.clat.proto='464xlat'
uci set network.clat.tunlink='wan6'
uci set network.clat.ip6prefix="$NAT64_PREFIX"
uci set network.clat.mtu="$CLAT_DEV_MTU"
uci set network.clat.metric='10'
uci set network.clat.peerdns='0'
uci set network.clat.zone='wan'
uci set network.clat.auto='1'
# Start clean; 98-clat-iapd automatically pins ip6addr inside Jio's live IA_PD /64 when present
uci -q delete network.clat.ip6addr || true
uci -q delete network.clat.dns || true
for dns in $DNS_V4_LIST; do
    uci add_list network.clat.dns="$dns"
done

uci commit network

# --- 5. Firewall: Disable Flow Offloading, Allow-464XLAT & fw4 MSS Clamp ---
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

uci set firewall.allow_clat=rule
uci set firewall.allow_clat.name='Allow-464XLAT'
uci set firewall.allow_clat.src='wan'
uci set firewall.allow_clat.dest='wan'
uci set firewall.allow_clat.family='ipv6'
uci set firewall.allow_clat.proto='all'
uci set firewall.allow_clat.target='ACCEPT'

uci commit firewall

mkdir -p /etc/nftables.d
cat << EOF > /etc/nftables.d/99-clat-mss.nft
chain clat_mss_clamp {
    type filter hook forward priority mangle; policy accept;
    oifname "464-clat" tcp flags syn / syn,rst tcp option maxseg size $((CLAT_TCP_MSS + 1))-65535 tcp option maxseg size set ${CLAT_TCP_MSS}
    iifname "464-clat" tcp flags syn / syn,rst tcp option maxseg size $((CLAT_TCP_MSS + 1))-65535 tcp option maxseg size set ${CLAT_TCP_MSS}
}
EOF

# --- 6. Hotplug Hooks: Dynamic IA_PD CLAT Binding + Split MTU (1280/1260/1220) ---
log "Installing /etc/hotplug.d/iface/98-clat-iapd and /etc/hotplug.d/iface/99-clat-mtu..."

mkdir -p /etc/hotplug.d/iface

cat << 'EOF' > /etc/hotplug.d/iface/98-clat-iapd
#!/bin/sh
# Automatically binds 464-clat local.v6 inside wan6's delegated IA_PD /64 prefix
# (prevents source-specific IPv6 routing drops on DHCPv6 IA_NA + IA_PD ODUs,
# while staying a clean no-op on SLAAC-only ODUs that have no ipv6-prefix).
[ "$INTERFACE" = "wan6" ] || exit 0
[ "$ACTION" = "ifup" ] || [ "$ACTION" = "ifupdate" ] || exit 0

PD_PREFIX="$(ifstatus wan6 2>/dev/null | jsonfilter -e '@["ipv6-prefix"][0].address' 2>/dev/null || true)"
CURRENT_IP6="$(uci -q get network.clat.ip6addr || true)"

if [ -z "$PD_PREFIX" ]; then
    # SLAAC-only link (no delegated IA_PD): clear any stale pinned ip6addr
    if [ -n "$CURRENT_IP6" ]; then
        uci -q delete network.clat.ip6addr || true
        uci commit network
        ubus call network reload 2>/dev/null || true
        ifdown clat 2>/dev/null || true
        sleep 1
        ifup clat 2>/dev/null || true
    fi
    exit 0
fi

case "$PD_PREFIX" in
    *::) TARGET_IP6="${PD_PREFIX}464" ;;
    *)   TARGET_IP6="${PD_PREFIX}:464" ;;
esac

NEED_BOUNCE=0
if [ "$CURRENT_IP6" != "$TARGET_IP6" ]; then
    uci set network.clat.ip6addr="$TARGET_IP6"
    uci commit network
    NEED_BOUNCE=1
elif ! grep -qiF "$TARGET_IP6" /proc/net/nat46/control 2>/dev/null; then
    NEED_BOUNCE=1
fi

if [ "$NEED_BOUNCE" -eq 1 ]; then
    ubus call network reload 2>/dev/null || true
    ifdown clat 2>/dev/null || true
    sleep 1
    ifup clat 2>/dev/null || true
fi
EOF
chmod 0755 /etc/hotplug.d/iface/98-clat-iapd

cat << EOF > /etc/hotplug.d/iface/99-clat-mtu
#!/bin/sh
[ "\$INTERFACE" = "clat" ] && [ "\$ACTION" = "ifup" ] || exit 0
sleep 1
ip link set dev 464-clat mtu ${CLAT_DEV_MTU} 2>/dev/null || true
ip route replace default dev 464-clat metric 2048 mtu ${CLAT_ROUTE_MTU} advmss ${CLAT_TCP_MSS} 2>/dev/null || true
EOF
chmod 0755 /etc/hotplug.d/iface/99-clat-mtu

# --- 7. DHCP & DNS: IPv6 Relay / IA_PD Server + Google & Cloudflare DNS (WAN & LAN) ---
if [ "$EFFECTIVE_IPV6_MODE" = "relay" ]; then
    log "Configuring odhcpd IPv6 relay (wan6 master -> lan) + Google/Cloudflare IPv4 & IPv6 DNS..."
    uci set dhcp.wan6=dhcp
    uci set dhcp.wan6.interface='wan6'
    uci set dhcp.wan6.ignore='1'
    uci set dhcp.wan6.master='1'
    uci set dhcp.wan6.ra='relay'
    uci set dhcp.wan6.dhcpv6='relay'
    uci set dhcp.wan6.ndp='relay'

    uci set dhcp.lan.ra='relay'
    uci set dhcp.lan.dhcpv6='relay'
    uci set dhcp.lan.ndp='relay'
else
    log "Configuring odhcpd IPv6 server mode (native IA_PD /64 delegation) + Google/Cloudflare IPv4 & IPv6 DNS..."
    uci -q delete dhcp.wan6 || true
    uci set dhcp.lan.ra='server'
    uci set dhcp.lan.dhcpv6='server'
    uci set dhcp.lan.ra_slaac='1'
    uci -q delete dhcp.lan.ndp || true
    uci -q delete dhcp.lan.ra_flags || true
    uci add_list dhcp.lan.ra_flags='managed-config'
    uci add_list dhcp.lan.ra_flags='other-config'
fi

# Advertise Google + Cloudflare IPv4 DNS to LAN DHCPv4 clients (Option 6)
uci -q delete dhcp.lan.dhcp_option || true
uci add_list dhcp.lan.dhcp_option="6,${DNS_V4_CSV}"

# Advertise Google + Cloudflare IPv6 DNS to LAN clients (RDNSS / DHCPv6)
uci -q delete dhcp.lan.dns || true
for dns6 in $DNS_V6_LIST; do
    uci add_list dhcp.lan.dns="$dns6"
done
uci set dhcp.lan.ra_dns='1'
uci set dhcp.lan.dns_service='1'

# Configure router dnsmasq upstream resolvers (Google + Cloudflare IPv4 & IPv6)
uci set dhcp.@dnsmasq[0].noresolv='1'
uci -q delete dhcp.@dnsmasq[0].server || true
for dns in $DNS_V4_LIST $DNS_V6_LIST; do
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
    ping -4 -I 464-clat -c 1 -W 3 1.1.1.1 >/dev/null 2>&1 && V4_OK=1

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
    chmod 0755 /usr/bin/jio-wan-led.sh

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
    chmod 0755 /etc/init.d/jio-wan-led
    /etc/init.d/jio-wan-led enable
    /etc/init.d/jio-wan-led stop 2>/dev/null || true
    /etc/init.d/jio-wan-led start
fi

# --- 9. Sysupgrade Persistence & Flash Sync ---
log "Updating /etc/sysupgrade.conf..."
for f in \
    /etc/hotplug.d/iface/98-clat-iapd \
    /etc/hotplug.d/iface/99-clat-mtu \
    /etc/nftables.d/99-clat-mss.nft \
    /usr/bin/jio-wan-led.sh \
    /etc/init.d/jio-wan-led; do
    if [ -e "$f" ]; then
        grep -qxF "$f" /etc/sysupgrade.conf 2>/dev/null || echo "$f" >> /etc/sysupgrade.conf
    fi
done

if [ -d "$BACKUP_DIR" ]; then
    for f in /usr/sbin/odhcp6c /lib/netifd/proto/dhcpv6.sh /lib/netifd/dhcpv6.script; do
        if [ -e "$f" ]; then
            grep -qxF "$f" /etc/sysupgrade.conf 2>/dev/null || echo "$f" >> /etc/sysupgrade.conf
        fi
    done
fi

sync

# --- 10. Reload Non-SSH-Disrupting Services ---
log "Restarting odhcpd, dnsmasq, and firewall (SSH stays connected)..."
/etc/init.d/odhcpd restart
/etc/init.d/dnsmasq restart
/etc/init.d/firewall restart

# --- 11. Pre-Restart Verification Checklist (100% written to flash!) ---
log "=== All Files & Configs Committed to Flash ==="
log "  wan6: device=$(uci -q get network.wan6.device) | reqaddress=$(uci -q get network.wan6.reqaddress) | clientid=$(uci -q get network.wan6.clientid || echo auto) | iface_464xlat=$(uci -q get network.wan6.iface_464xlat)"
log "  dhcp IPv6: mode=$EFFECTIVE_IPV6_MODE | wan6_master=$(uci -q get dhcp.wan6.master || echo 0) | lan_ra=$(uci -q get dhcp.lan.ra) | lan_ndp=$(uci -q get dhcp.lan.ndp || echo disabled)"
log "  DNS (WAN+LAN): IPv4=$DNS_V4_LIST | IPv6=$DNS_V6_LIST"
log "  clat: proto=$(uci -q get network.clat.proto) | ip6prefix=$(uci -q get network.clat.ip6prefix) | mtu=$(uci -q get network.clat.mtu) | iapd_hook=OK"
log "  firewall: flow_offloading=$(uci -q get firewall.@defaults[0].flow_offloading) | allow_clat=OK | mss_clamp=$(nft list chain inet fw4 clat_mss_clamp >/dev/null 2>&1 && echo OK || echo PENDING)"
log "  dhcpv6.sh perms: $(ls -l /lib/netifd/proto/dhcpv6.sh | awk '{print $1}')"
log "  setup log: $LOG_FILE"

if uci -q get network.wwan >/dev/null 2>&1; then
    log "Note: Temporary 'wwan' interface detected. Disable/remove 'wwan' in LuCI when ready, plug in Jio 5G ODU, and reboot."
fi

if [ -d "$BACKUP_DIR" ]; then
    log "Rollback stock Official odhcp6c anytime: wget -4 -qO- $REPO_RAW_BASE/scripts/apply-mt7986-odhcp6c.sh | sh -s -- --rollback"
fi

# --- 12. Detached Background netifd Restart + Automatic IA_PD Sync & Self-Check ---
if [ "$NO_RESTART" = "1" ]; then
    log "Skipped network restart (--no-restart). Run 'reboot' or '/etc/init.d/network restart' to activate."
    exit 0
fi

log "Scheduling detached /etc/init.d/network restart in 3 seconds..."
log "Your Wi-Fi / SSH session may briefly drop (~10-15s) while netifd reloads."
log "After reconnecting, check: cat $RESTART_LOG"

(
    trap '' HUP
    sleep 3
    {
        echo "[$(date)] Starting /etc/init.d/network restart..."
        /etc/init.d/network restart
        sleep 4
        if ubus call network get_proto_handlers 2>/dev/null | grep -q '"dhcpv6"'; then
            echo "[$(date)] netifd protocol 'dhcpv6': REGISTERED"
        else
            echo "[$(date)] WARN: netifd protocol 'dhcpv6' not found!"
        fi

        WAN_CARRIER="$(cat /sys/class/net/wan/carrier 2>/dev/null || echo 0)"
        if [ "$WAN_CARRIER" = "1" ]; then
            ELAPSED=0
            while [ "$ELAPSED" -lt 60 ]; do
                if ifstatus wan6 2>/dev/null | grep -q '"address": "2409:'; then
                    break
                fi
                sleep 3
                ELAPSED=$((ELAPSED + 3))
            done

            # Ensure dynamic IA_PD -> clat.ip6addr sync runs immediately once wan6 is up
            if [ -x /etc/hotplug.d/iface/98-clat-iapd ]; then
                INTERFACE=wan6 ACTION=ifup /etc/hotplug.d/iface/98-clat-iapd 2>/dev/null || true
            fi

            # Wait briefly for 464-clat to settle after any IA_PD sync bounce
            CLAT_WAIT=0
            while [ "$CLAT_WAIT" -lt 15 ]; do
                if ip link show dev 464-clat >/dev/null 2>&1; then
                    break
                fi
                sleep 2
                CLAT_WAIT=$((CLAT_WAIT + 2))
            done

            if ip link show dev 464-clat >/dev/null 2>&1; then
                ip link set dev 464-clat mtu "$CLAT_DEV_MTU" 2>/dev/null || true
                ip route replace default dev 464-clat metric 2048 mtu "$CLAT_ROUTE_MTU" advmss "$CLAT_TCP_MSS" 2>/dev/null || true
            fi

            echo "[$(date)] === Post-Restart Status ==="
            ifstatus wan6 2>/dev/null | grep -E '"up"|"proto"|"device"|"address"|"target"' || true
            cat /proc/net/nat46/control 2>/dev/null || true
            ip link show dev 464-clat 2>/dev/null | grep -o 'mtu [0-9]*' || echo "464-clat: waiting for Jio IPv6"
            ip route show dev 464-clat 2>/dev/null || true
            echo "[$(date)] === Live Connectivity Self-Check ==="
            ping -6 -c 2 -W 3 2606:4700:4700::1111 2>&1 | tail -n 2 || true
            ping -4 -I 464-clat -c 2 -W 3 1.1.1.1 2>&1 | tail -n 2 || true
        else
            echo "[$(date)] WAN cable not connected yet. Plug in Jio 5G ODU and reboot."
        fi
        echo "[$(date)] Done."
    } > "$RESTART_LOG" 2>&1
) </dev/null >/dev/null 2>&1 &

log "Setup finished cleanly (exit 0)! Wi-Fi AP settings were left untouched."
