<#
.SYNOPSIS
    Intune Proactive Remediation - Remediation.
    Startet den gestoppten Service "Matrix42UAF" (Matrix42 Universal Agent
    Framework) neu und prueft kurz danach, ob er stabil bleibt (kein sofortiger
    Crash-Loop). Behebt nur das Symptom "Service down" - die Ursache fuer den
    urspruenglichen Crash (unhandled Exception in Matrix42.Platform.Service.Host.exe)
    wird dadurch nicht behoben, nur der Zustand.

.EXIT CODES
    0 = Service laeuft nach dem Start und blieb es auch nach kurzer Wartezeit
    1 = Service liess sich nicht starten oder stoppte sofort wieder
#>

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
