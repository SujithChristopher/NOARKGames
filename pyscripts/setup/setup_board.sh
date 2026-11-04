#!/bin/bash
# One-time setup of a board: what the tracker needs root for, so that nothing ever
# has to hold the board's password.
#
#     sudo pyscripts/setup/setup_board.sh [COUNTRY]     (default IN)
#
# Two sudoers lines, each allowing one thing without a password: restarting the
# tracker when it has stopped answering (RESTART over the link needs no root at all),
# and the root helper that runs the hotspot for the Camera tab's pictures over BLE.
# Then the hotspot's NetworkManager profile, which does not start by itself, and the
# Wi-Fi region. It prints the hotspot's password, which is made here per board and kept
# only in the root-only profile: never put it in the repo. Typed once into the tablet's
# Camera tab. Run this again to see it; it stays the same.
set -euo pipefail

COUNTRY=${1:-IN}
USER_NAME=${SUDO_USER:-radxa}
HERE=$(cd "$(dirname "$0")" && pwd)
CONNECTION=noark-hotspot
HELPER=/usr/local/sbin/noark-hotspot
HOTSPOT_SUDOERS=/etc/sudoers.d/noark-hotspot
TRACKER_SUDOERS=/etc/sudoers.d/noark-tracker
REGION=/etc/modprobe.d/noark-wifi-region.conf

if [ "$(id -u)" -ne 0 ]; then
    echo "Run with sudo." >&2
    exit 1
fi

# Root-owned and outside the repo: a sudoers line must not point at a file the
# tracker's own user can rewrite.
install -o root -g root -m 755 "$HERE/noark-hotspot" "$HELPER"

install_sudoers() {   # file, line: checked first, a broken file can lock sudo out
    local temporary
    temporary=$(mktemp)
    echo "$2" > "$temporary"
    visudo -cf "$temporary" >/dev/null
    install -o root -g root -m 440 "$temporary" "$1"
    rm -f "$temporary"
}
install_sudoers "$HOTSPOT_SUDOERS" "$USER_NAME ALL=(root) NOPASSWD: $HELPER"
install_sudoers "$TRACKER_SUDOERS" "$USER_NAME ALL=(root) NOPASSWD: $(command -v systemctl) --no-block restart noark-tracker"

if ! nmcli -t -f NAME connection show | grep -qx "$CONNECTION"; then
    mac=$(cat /sys/class/net/wlan0/address)
    ssid="NOARK-$(echo "$mac" | tr -d : | tail -c 5)"
    password=$(openssl rand -base64 18 | tr -dc 'A-Za-z0-9' | cut -c1-16)
    nmcli connection add type wifi ifname "*" con-name "$CONNECTION" autoconnect no \
        ssid "$ssid" mode ap 802-11-wireless.band a 802-11-wireless.channel 149 \
        ipv4.method shared ipv4.addresses 10.42.0.1/24 ipv6.method disabled \
        wifi-sec.key-mgmt wpa-psk wifi-sec.proto rsn wifi-sec.pairwise ccmp wifi-sec.group ccmp \
        wifi-sec.psk "$password" >/dev/null
fi

# Last: the radio can blink as the region changes, and this may be running over it.
echo "options cfg80211 ieee80211_regdom=$COUNTRY" > "$REGION"
iw reg set "$COUNTRY"
sleep 2

echo "Wi-Fi region: $(iw reg get | awk '/^country/{print $2; exit}' | tr -d :)"
echo "Hotspot name: $(nmcli -g 802-11-wireless.ssid connection show "$CONNECTION")"
echo "Hotspot password: $(nmcli -s -g 802-11-wireless-security.psk connection show "$CONNECTION")"
