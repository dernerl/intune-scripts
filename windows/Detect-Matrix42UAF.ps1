<#
.SYNOPSIS
    Intune Proactive Remediation - Detection.
    Prueft ob der Service "Matrix42UAF" (Matrix42 Universal Agent Framework,
    Matrix42.Platform.Service.Host.exe) laeuft. Dieser Service ist der lokale
    Host, ueber den der UEM Agent mit Empirum kommuniziert - stirbt er, meldet
    sich der Client nirgends mehr, obwohl Intune/Dateisystem "installiert" zeigen.

.EXIT CODES
    0 = Service laeuft, kein Remediation noetig
    1 = Service existiert nicht oder laeuft nicht -> Remediation wird getriggert
#>

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
