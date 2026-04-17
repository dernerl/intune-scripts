# macOS: WiFi automatisch per launchd-Agent abschalten wenn Ethernet anliegt

## Problem

Wenn ein Mac per Ethernet verbunden ist, nutzen Apps wie Teams und Citrix trotzdem WiFi — weil sie beim Start eine Verbindung aufgebaut haben und bestehende TCP-Verbindungen nicht ohne Weiteres auf ein anderes Interface migriert werden können.

> Eine TCP-Verbindung ist an eine Source-IP gebunden. Sie kann nicht auf eine andere IP umziehen — das ist eine fundamentale Protokoll-Einschränkung.

Das ist kein Einzelproblem: In Büros mit vielen Macs am Docking-Kabel kann unnötiger WiFi-Traffic das WLAN merklich belasten.

## Was nicht funktioniert

| Methode | Warum nicht |
|---|---|
| Service Order ändern | Gilt nur für neue Verbindungen |
| pf / NAT | Kann bestehende TCP-Verbindungen nicht umleiten |
| Routing-Tabelle | Ebenfalls nur für neue Verbindungen |
| MPTCP | Teams/Citrix implementieren es nicht |
| App-Neustart | Keine Option im laufenden Betrieb |

## Lösung: launchd-Agent mit WiFi-Cycling

Der einfachste Weg: WiFi kurz abschalten wenn Ethernet kommt. Apps wie Teams und Citrix erkennen den Verbindungsabbruch und bauen die Verbindung neu auf — diesmal über Ethernet.

> **Event-driven statt Polling:** Die Plist verwendet `WatchPaths` auf `/private/var/run/resolv.conf` — macOS aktualisiert diese Datei bei jeder Netzwerkänderung. Der Agent feuert damit nur wenn sich tatsächlich etwas ändert, statt alle N Sekunden blind zu pollen. Das Script selbst bleibt idempotent (State-File-Vergleich), also kein Problem wenn es gelegentlich auch bei anderen Netzwerkereignissen ausgelöst wird.

### Warum `resolv.conf` als Trigger?

`/private/var/run/resolv.conf` listet die DNS-Server auf, die das System gerade verwendet — klassisch unter Linux/Unix für DNS-Konfiguration, auf macOS eigentlich durch `mDNSResponder` ersetzt, aber die Datei existiert noch als Kompatibilitäts-Shim.

**Der entscheidende Punkt:** Immer wenn sich ein Netzwerkinterface ändert — Kabel rein, Kabel raus, WiFi-Verbindung auf/ab, IP-Zuteilung via DHCP — schreibt `configd` (macOS Network Configuration Daemon) neue DNS-Server in diese Datei. Das passiert zuverlässig bei *jeder* relevanten Netzwerkänderung.

`WatchPaths` in der Plist lässt launchd genau diese Datei beobachten. Sobald sie sich ändert, feuert launchd den Agent. Der vollständige Ablauf beim Einstecken des Ethernet-Kabels:

```
Ethernet-Kabel wird eingesteckt
  → DHCP gibt IP für den Ethernet-Adapter aus
    → configd schreibt neue DNS-Server in resolv.conf
      → launchd erkennt Änderung via WatchPaths
        → ethernet-switch.sh wird gestartet
          → Ethernet-Kandidat hat jetzt "inet" → WiFi wird abgeschaltet
```

Das Script ist **idempotent**: Wenn `resolv.conf` sich aus einem anderen Grund ändert (z.B. VPN, WiFi-Wechsel), läuft das Script auch — stört aber nicht, weil es den vorherigen State im State-File (`/tmp/eth_switch_state`) vergleicht und nur bei echten Übergängen (`down→up` bzw. `up→down`) handelt.

### Script: `~/Library/LaunchAgents/ethernet-switch.sh`

Interface-Namen werden dynamisch ermittelt — kein hardcodiertes `en6` oder `en0`. Das Script läuft auf jedem Mac unverändert, egal welcher Adapter oder welches Dock verwendet wird.

```bash
#!/bin/bash
# ethernet-switch.sh
# Schaltet WiFi aus wenn Ethernet anliegt — Interface-Namen werden dynamisch ermittelt.

STATE_FILE="/tmp/eth_switch_state"

# WiFi Interface (auf MacBooks fast immer en0, aber sicher ermitteln)
WIFI_IF=$(networksetup -listallhardwareports | awk '/Hardware Port: Wi-Fi/{getline; print $2}')

# Ethernet-Kandidaten: alles ausser Wi-Fi, Thunderbolt, Bluetooth und Bridge
ETH_CANDIDATES=$(networksetup -listallhardwareports | awk '
/Hardware Port:/ { port = $0; next }
/Device:/ {
    if (port !~ /Thunderbolt/ && port !~ /Wi-Fi/ && port !~ /Bluetooth/ && $2 !~ /bridge/) {
        print $2
    }
}')

# Prüfe ob einer der Kandidaten eine IP hat (= Kabel angeschlossen + DHCP)
ETH_ACTIVE=""
for iface in $ETH_CANDIDATES; do
    if ifconfig "$iface" 2>/dev/null | grep -q "inet "; then
        ETH_ACTIVE="$iface"
        break
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
```

### Plist: `~/Library/LaunchAgents/com.user.ethernet-switch.plist`

```xml
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN"
  "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
    <key>Label</key>
    <string>com.user.ethernet-switch</string>
    <key>ProgramArguments</key>
    <array>
        <string>/bin/bash</string>
        <string>/Users/USERNAME/Library/LaunchAgents/ethernet-switch.sh</string>
    </array>
    <key>WatchPaths</key>
    <array>
        <string>/private/var/run/resolv.conf</string>
    </array>
    <key>RunAtLoad</key>
    <true/>
</dict>
</plist>
```

### Aktivieren

`launchctl` ist das Kommandozeilentool für macOS' Init-System `launchd`. Es verwaltet Hintergrundprozesse (LaunchAgents/LaunchDaemons) — vergleichbar mit `systemctl` unter Linux.

```bash
chmod +x ~/Library/LaunchAgents/ethernet-switch.sh
launchctl bootstrap gui/$(id -u) ~/Library/LaunchAgents/com.user.ethernet-switch.plist

# Status prüfen
launchctl list | grep ethernet
```

**Agent bereits registriert?** Beim erneuten Laden (z.B. nach Änderungen) schlägt `bootstrap` mit `Bootstrap failed: 5: Input/output error` fehl. Lösung: erst `bootout`, dann neu bootstrappen:

```bash
launchctl bootout gui/$(id -u)/com.user.ethernet-switch
launchctl bootstrap gui/$(id -u) ~/Library/LaunchAgents/com.user.ethernet-switch.plist
```

> `launchctl load` / `launchctl unload` sind auf modernem macOS deprecated — immer `bootstrap` / `bootout` verwenden.

## Deployment für viele Macs (Jamf / Intune)

Der Agent braucht keine Root-Rechte — `networksetup -setairportpower` funktioniert als normaler User für das eigene WiFi.

### Intune

Da Intune keine Dateien direkt in User-Verzeichnisse legen kann, braucht es **ein einzelnes Deploy-Script**, das beide Dateien schreibt und den Agent registriert.

Einstellungen beim Upload in Intune (Devices → macOS → Shell scripts):

| Einstellung | Wert |
|---|---|
| Run script as signed-in user | **Yes** — zwingend, LaunchAgents sind User-kontext |
| Hide script notifications | Yes |
| Script frequency | Not configured (einmalig, Script ist idempotent) |
| Max retries if script fails | 3 |

```bash
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
```

### Jamf

Script-Policy + File-Deployment, beim ersten Login ausführen. Gleiches Deploy-Script wie oben, alternativ Script und Plist als separate File-Deployments mit abschliessender Policy zum Bootstrappen.

