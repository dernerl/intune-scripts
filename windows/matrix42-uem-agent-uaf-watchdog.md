# Windows: Matrix42 UEM Agent verliert Empirum-Verbindung, ohne dass Intune es merkt

## Problem

Ein Client zeigte sich in Intune als vollstaendig verwaltet und der "UEM Agent Windows (64 bit)" tauchte sogar im **Detected-Apps-Inventar** als installiert auf — trotzdem fehlte der Client komplett in Empirum's Softwareverteilung.

Das ist der Kern der Falle: Intune's Software-Inventar liest nur, ob die Binaries/Registry-Einträge auf der Platte liegen (MSI-/Registry-Scan). Es prüft **nicht**, ob der Agent auch tatsächlich mit dem Empirum-Server spricht. Beide Systeme können also komplett unterschiedliche Wahrheiten zeigen.

## Root Cause

Auf einer zweiten, unabhängig geprüften Maschine (ganz normaler on-prem Client, nicht der ursprünglich gemeldete) liess sich das Symptom reproduzieren und die Ursache klar fassen:

Der Service **`Matrix42UAF`** (*Matrix42 Universal Agent Framework*, `Matrix42.Platform.Service.Host.exe`) ist der lokale Host, über den der UEM Agent mit Empirum kommuniziert — die Tray-UI (`M42UEM_UI.exe`) redet mit ihm über SignalR auf **Loopback-Port 58644** (aus `HKLM:\SOFTWARE\Matrix42\Agent\ApiPort`).

Stirbt dieser Service, bleibt er stehen (kein automatischer Neustart). Im Eventlog zeigt sich der Auslöser eindeutig:

```
Application Error (Id 1000): Matrix42.Platform.Service.Host.exe
.NET Runtime (Id 1026): unhandled exception
  System.ObjectDisposedException
    at System.Runtime.InteropServices.SafeHandle.DangerousAddRef(Boolean ByRef)
    ...
Service Control Manager (Id 7034): Dienst "Matrix42 Universal Agent Framework" wurde unerwartet beendet.
```

Danach versucht die Tray-UI alle ~30s erfolglos, den Host zu erreichen:

```
[ERROR] [SignalRHubClient.MoveNext] SignalR Connection failed.
 + Es konnte keine Verbindung hergestellt werden, da der Zielcomputer die Verbindung verweigerte [::1]:58644
```

Der Client meldet sich damit nirgends mehr bei Empirum — während Intune weiterhin "installiert" zeigt, weil das nie geprüft wird.

## Diagnose

`Diagnose-UemAgent.ps1` ist read-only und rät nichts — es sucht Matrix42-Services/Installationen/Logs/Registry-Werte programmatisch, statt interne Pfade oder Servicenamen vorauszusetzen:

1. Services, deren Name/DisplayName/Pfad auf `Matrix42|Empirum|UEM` matcht
2. Installierte Programme über die Uninstall-Registry (32+64bit)
3. Alle gefundenen Install-Ordner + bekannte `ProgramData\Matrix42` / `Program Files\Matrix42` Basispfade rekursiv gelistet
4. Tail (60 Zeilen) des jüngsten gefundenen Logs
5. `HKLM:\SOFTWARE\Matrix42` komplett gedumpt — **mit Ausnahme** von `Platform\Service\Extension\ObjectStore\Data` (Objekt-Cache, kann riesig werden, wird nicht mal betreten, nur als "ausgeschlossen" markiert)
6. Aus Logs/Config extrahierte Hostnamen per DNS + TCP 443/80 getestet
7. Eventlog der letzten 30 Tage, gefiltert auf Matrix42/Empirum/UEM

Genau dieser Lauf hat den Service-Crash und den verweigerten Port 58644 aufgedeckt.

## Lösung: Intune Proactive Remediation

Detection prüft nur den Service-Status, Remediation startet ihn neu und verifiziert danach kurz, dass er nicht sofort wieder crasht (Crash-Loop-Erkennung statt False-Positive-Erfolg):

### `Detect-Matrix42UAF.ps1`

```powershell
$service = Get-Service -Name 'Matrix42UAF' -ErrorAction SilentlyContinue

if (-not $service) {
    Write-Output "Service 'Matrix42UAF' nicht gefunden."
    exit 1
}

if ($service.Status -ne 'Running') {
    Write-Output "Service 'Matrix42UAF' Status: $($service.Status) (erwartet: Running)."
    exit 1
}

Write-Output "Service 'Matrix42UAF' laeuft."
exit 0
```

### `Remediate-Matrix42UAF.ps1`

```powershell
$serviceName = 'Matrix42UAF'
$service = Get-Service -Name $serviceName -ErrorAction SilentlyContinue

if (-not $service) {
    Write-Output "Service '$serviceName' existiert nicht auf diesem Geraet."
    exit 1
}

try {
    Start-Service -Name $serviceName -ErrorAction Stop
} catch {
    Write-Output "Start-Service fuer '$serviceName' fehlgeschlagen: $($_.Exception.Message)"
    exit 1
}

Start-Sleep -Seconds 15
$service.Refresh()

if ($service.Status -ne 'Running') {
    Write-Output "Service '$serviceName' ist nach dem Start-Versuch nicht (mehr) im Status Running (aktuell: $($service.Status)) - vermutlich Crash-Loop."
    exit 1
}

Write-Output "Service '$serviceName' laeuft nach Neustart stabil."
exit 0
```

**Wichtig:** Das behebt nur das Symptom (Service down → neu starten), nicht die Ursache des Crashes selbst. Bei häufigem Auftreten ist das ein Fall für Matrix42-Support mit dem `ObjectDisposedException`-Stacktrace als Beleg.

## Deployment (Intune)

*Intune Admin Center → Devices → Scripts and remediations → Proactive remediations → Create*

| Einstellung | Wert |
|---|---|
| Detection script | `Detect-Matrix42UAF.ps1` |
| Remediation script | `Remediate-Matrix42UAF.ps1` |
| Run this script using the logged-on credentials | **No** — muss als SYSTEM laufen, sonst kein Zugriff auf Service-Control |
| Enforce script signature check | No |
| Run script in 64-bit PowerShell | Yes |
| Schedule | z.B. täglich, oder stündlich mit Intervall 4h |

Zuweisung an eine Gerätegruppe bzw. eine Nutzergruppe (funktioniert auch über den primären Nutzer eines Geräts).

`Diagnose-UemAgent.ps1` ist bewusst **kein** Bestandteil der Remediation — es ist ein einmaliges Ad-hoc-Diagnose-Script für den nächsten ähnlichen Fall (Devices → Scripts, einzeln ausführen, Output im Run-Summary bzw. `C:\temp\Diagnose-UemAgent-*.txt`).
