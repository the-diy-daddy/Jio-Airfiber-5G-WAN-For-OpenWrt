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
