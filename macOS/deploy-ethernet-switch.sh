#!/bin/bash
# deploy-ethernet-switch.sh — Intune macOS Deployment
# Run as: Logged-in user (NICHT root)

set -e

LAUNCH_AGENTS_DIR="$HOME/Library/LaunchAgents"
SCRIPT_PATH="$LAUNCH_AGENTS_DIR/ethernet-switch.sh"
PLIST_PATH="$LAUNCH_AGENTS_DIR/com.user.ethernet-switch.plist"
LABEL="com.user.ethernet-switch"

mkdir -p "$LAUNCH_AGENTS_DIR"

cat > "$SCRIPT_PATH" << 'SCRIPT'
#!/bin/bash
STATE_FILE="/tmp/eth_switch_state"
WIFI_IF=$(networksetup -listallhardwareports | awk '/Hardware Port: Wi-Fi/{getline; print $2}')
ETH_CANDIDATES=$(networksetup -listallhardwareports | awk '
/Hardware Port:/ { port = $0; next }
/Device:/ {
    if (port !~ /Thunderbolt/ && port !~ /Wi-Fi/ && port !~ /Bluetooth/ && $2 !~ /bridge/) {
        print $2
    }
}')
ETH_ACTIVE=""
for iface in $ETH_CANDIDATES; do
    if ifconfig "$iface" 2>/dev/null | grep -q "inet "; then
        ETH_ACTIVE="$iface"; break
    fi
done
PREV=$(cat "$STATE_FILE" 2>/dev/null || echo "down")
NOW=$( [ -n "$ETH_ACTIVE" ] && echo "up" || echo "down" )
echo "$NOW" > "$STATE_FILE"
if [ "$NOW" = "up" ] && [ "$PREV" = "down" ]; then
    logger "ethernet-switch: $ETH_ACTIVE up — WiFi ($WIFI_IF) aus"
    networksetup -setairportpower "$WIFI_IF" off
fi
if [ "$NOW" = "down" ] && [ "$PREV" = "up" ]; then
    logger "ethernet-switch: Ethernet down — WiFi ($WIFI_IF) an"
    networksetup -setairportpower "$WIFI_IF" on
fi
SCRIPT

chmod +x "$SCRIPT_PATH"

cat > "$PLIST_PATH" << PLIST
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN"
  "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
    <key>Label</key>
    <string>$LABEL</string>
    <key>ProgramArguments</key>
    <array>
        <string>/bin/bash</string>
        <string>$SCRIPT_PATH</string>
    </array>
    <key>WatchPaths</key>
    <array>
        <string>/private/var/run/resolv.conf</string>
    </array>
    <key>RunAtLoad</key>
    <true/>
</dict>
</plist>
PLIST

UID_CURRENT=$(id -u)
if launchctl list | grep -q "$LABEL"; then
    launchctl bootout "gui/$UID_CURRENT/$LABEL" 2>/dev/null || true
fi
launchctl bootstrap "gui/$UID_CURRENT" "$PLIST_PATH"
logger "ethernet-switch: deployment via Intune erfolgreich"
