#!/bin/sh
# ==============================================================================
# Jio Airfiber 5G WAN For OpenWrt — First-Boot Wi-Fi Setup (uci-defaults)
# Enables 2.4GHz & 5GHz Wi-Fi on first boot with MT76 DHCP fix.
# ==============================================================================

WIFI_SSID="OpenWrt-Jio5G"
WIFI_KEY="12345678"

[ ! -f /etc/config/wireless ] && /sbin/wifi config 2>/dev/null || true

if [ -f /etc/config/wireless ]; then
    for radio in $(uci show wireless | grep "=wifi-device" | cut -d'.' -f2 | cut -d'=' -f1); do
        BAND=$(uci -q get wireless."$radio".band || echo "")
        HWMODE=$(uci -q get wireless."$radio".hwmode || echo "")
        uci set wireless."$radio".country='IN'
        uci set wireless."$radio".disabled='0'
        if [ "$BAND" = "5g" ] || echo "$HWMODE" | grep -q "11a"; then
            uci set wireless."$radio".htmode='HE80'
            uci set wireless."$radio".channel='36'
        else
            uci set wireless."$radio".htmode='HT20'
            uci set wireless."$radio".channel='auto'
        fi
    done

    for iface in $(uci show wireless | grep "=wifi-iface" | cut -d'.' -f2 | cut -d'=' -f1); do
        uci set wireless."$iface".disabled='0'
        uci set wireless."$iface".network='lan'
        uci set wireless."$iface".ssid="$WIFI_SSID"
        uci set wireless."$iface".encryption='psk2'
        uci set wireless."$iface".key="$WIFI_KEY"
        uci set wireless."$iface".multicast_to_unicast='0'
    done

    uci commit wireless
fi

exit 0
