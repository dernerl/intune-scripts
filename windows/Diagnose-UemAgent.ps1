#Requires -RunAsAdministrator

<#
.SYNOPSIS
    Diagnose fuer Matrix42 UEM Agent / Empirum-Registrierung.
    Read-only. Sammelt Service-, Install-, Log- und Netzwerk-Fakten ohne
    Matrix42-interne Pfade/Namen vorauszusetzen - sucht sie stattdessen.

.KONTEXT
    HO-1FLSGY2: Intune Detected-Apps-Inventar zeigt "UEM Agent Windows (64 bit)"
    v2408.1.2.0 als installiert, aber der Client fehlt in Empirum's Software-
    verteilung. Dieses Skript klaert die Client-seitige Haelfte der Frage:
    laeuft der Agent, findet er seinen Server, was sagt sein eigenes Log.

.EXAMPLE
    Als Intune "Run script" (Devices > Scripts) oder lokal als Admin:
    .\Diagnose-UemAgent.ps1
#>

param(
    [string]$OutputPath = "C:\temp\Diagnose-UemAgent-$env:COMPUTERNAME-$(Get-Date -Format 'yyyyMMdd-HHmmss').txt"
)

if (-not (Test-Path "C:\temp")) { New-Item -ItemType Directory -Path "C:\temp" -Force | Out-Null }

function Write-Section {
    param([string]$Title)
    $sep = "=" * 70
    $output = "`n$sep`n  $Title`n$sep"
    Write-Host $output -ForegroundColor Cyan
    $output | Out-File -Append $OutputPath
}
function Write-Result { param([string]$Text) Write-Host $Text; $Text | Out-File -Append $OutputPath }
function Write-OK     { param([string]$Text) Write-Host "  [OK] $Text" -ForegroundColor Green; "  [OK] $Text" | Out-File -Append $OutputPath }
function Write-Fail   { param([string]$Text) Write-Host "  [FAIL] $Text" -ForegroundColor Red; "  [FAIL] $Text" | Out-File -Append $OutputPath }
function Write-Warn   { param([string]$Text) Write-Host "  [!] $Text" -ForegroundColor Yellow; "  [!] $Text" | Out-File -Append $OutputPath }

"Diagnose-UemAgent Report | Computer: $env:COMPUTERNAME | User: $env:USERNAME | $(Get-Date)" | Out-File $OutputPath

# ============================================================
# 1. Services (Matrix42 / Empirum / UEM)
# ============================================================
Write-Section "1. Services"

$svcKeywords = 'Matrix42|Empirum|UEM'
$services = Get-CimInstance Win32_Service | Where-Object {
    $_.Name -match $svcKeywords -or $_.DisplayName -match $svcKeywords -or $_.PathName -match $svcKeywords
}

if ($services) {
    foreach ($s in $services) {
        Write-Result "Name: $($s.Name) | DisplayName: $($s.DisplayName)"
        Write-Result "  State: $($s.State) | StartMode: $($s.StartMode) | PathName: $($s.PathName)"
        if ($s.State -eq 'Running') { Write-OK "$($s.Name) laeuft" } else { Write-Fail "$($s.Name) laeuft NICHT (State: $($s.State))" }
    }
} else {
    Write-Fail "Kein Service gefunden, der auf Matrix42/Empirum/UEM matcht."
}

# ============================================================
# 2. Installierte Programme (Uninstall-Registry, 32+64bit)
# ============================================================
Write-Section "2. Installierte Programme"

$uninstallPaths = @(
    'HKLM:\SOFTWARE\Microsoft\Windows\CurrentVersion\Uninstall\*',
    'HKLM:\SOFTWARE\WOW6432Node\Microsoft\Windows\CurrentVersion\Uninstall\*'
)
$installedApps = Get-ItemProperty $uninstallPaths -ErrorAction SilentlyContinue |
    Where-Object { $_.DisplayName -match $svcKeywords -or $_.Publisher -match 'Matrix42' }

$installLocations = @()
if ($installedApps) {
    foreach ($a in $installedApps) {
        Write-Result "DisplayName: $($a.DisplayName) | Version: $($a.DisplayVersion) | Publisher: $($a.Publisher)"
        Write-Result "  InstallDate: $($a.InstallDate) | InstallLocation: $($a.InstallLocation)"
        if ($a.InstallLocation) { $installLocations += $a.InstallLocation }
    }
} else {
    Write-Warn "Kein passender Uninstall-Registry-Eintrag gefunden (Agent evtl. ueber anderen Mechanismus installiert)."
}

# ============================================================
# 3. Dateisystem: Install-Ordner + bekannte Matrix42-Basispfade
# ============================================================
Write-Section "3. Dateisystem (Install-Ordner, Logs, Config)"

$candidatePaths = @($installLocations)
$candidatePaths += "$env:ProgramData\Matrix42"
$candidatePaths += "$env:ProgramFiles\Matrix42"
$candidatePaths += "${env:ProgramFiles(x86)}\Matrix42"
$candidatePaths = $candidatePaths | Where-Object { $_ } | Select-Object -Unique

$logFiles = @()
foreach ($p in $candidatePaths) {
    if (Test-Path $p) {
        Write-OK "Pfad existiert: $p"
        $items = Get-ChildItem -Path $p -Recurse -Depth 3 -ErrorAction SilentlyContinue
        $items | Select-Object FullName, LastWriteTime, Length | ForEach-Object {
            Write-Result "  $($_.LastWriteTime)  $($_.Length.ToString().PadLeft(10))  $($_.FullName)"
        }
        $logFiles += $items | Where-Object { -not $_.PSIsContainer -and $_.Extension -in '.log', '.txt' }
    } else {
        Write-Warn "Pfad existiert NICHT: $p"
    }
}

# ============================================================
# 4. Juengstes Log auszugsweise (letzte 60 Zeilen)
# ============================================================
Write-Section "4. Juengstes Log (Tail)"

if ($logFiles) {
    $newest = $logFiles | Sort-Object LastWriteTime -Descending | Select-Object -First 1
    Write-Result "Neuestes Log: $($newest.FullName) (LastWriteTime: $($newest.LastWriteTime))"
    Write-Result "---"
    Get-Content -Path $newest.FullName -Tail 60 -ErrorAction SilentlyContinue | ForEach-Object { Write-Result $_ }
} else {
    Write-Fail "Keine .log/.txt Datei unter den gefundenen Pfaden - kann Agent-Log nicht auszugsweise zeigen."
}

# ============================================================
# 5. Registry unter HKLM:\SOFTWARE\Matrix42 (Server-/Config-Werte)
# ============================================================
Write-Section "5. Registry HKLM:\SOFTWARE\Matrix42"

$regRoots = @('HKLM:\SOFTWARE\Matrix42', 'HKLM:\SOFTWARE\WOW6432Node\Matrix42')

# Bekannt riesig (Objekt-Cache) und fuer die Registrierungs-Diagnose irrelevant.
$excludedKeyNames = @(
    'HKEY_LOCAL_MACHINE\SOFTWARE\Matrix42\Platform\Service\Extension\ObjectStore\Data',
    'HKEY_LOCAL_MACHINE\SOFTWARE\WOW6432Node\Matrix42\Platform\Service\Extension\ObjectStore\Data'
)

function Show-RegistryTree {
    param([string]$Path)
    $key = Get-Item -Path $Path -ErrorAction SilentlyContinue
    if (-not $key) { return }
    if ($excludedKeyNames -contains $key.Name) {
        Write-Warn "Ausgeschlossen (zu gross): $($key.Name)"
        return
    }
    Write-Result "  Key: $($key.Name)"
    Get-ItemProperty -Path $key.PSPath -ErrorAction SilentlyContinue |
        Select-Object * -ExcludeProperty PS* |
        ForEach-Object { $_.PSObject.Properties | ForEach-Object { Write-Result "    $($_.Name) = $($_.Value)" } }
    Get-ChildItem -Path $key.PSPath -ErrorAction SilentlyContinue | ForEach-Object { Show-RegistryTree -Path $_.PSPath }
}

foreach ($root in $regRoots) {
    if (Test-Path $root) {
        Write-OK "Vorhanden: $root"
        Show-RegistryTree -Path $root
    } else {
        Write-Warn "Nicht vorhanden: $root"
    }
}

# ============================================================
# 6. Netzwerk: Serverhostname aus Logs/Config extrahieren + testen
# ============================================================
Write-Section "6. Netzwerk-Erreichbarkeit"

$found = New-Object System.Collections.Generic.HashSet[string]
foreach ($lf in $logFiles) {
    Select-String -Path $lf.FullName -Pattern 'https?://([a-zA-Z0-9\-\.]+)' -ErrorAction SilentlyContinue |
        ForEach-Object { foreach ($m in $_.Matches) { [void]$found.Add($m.Groups[1].Value) } }
}

if ($found.Count -gt 0) {
    foreach ($hostName in $found) {
        Write-Result "Gefundener Hostname/URL-Host in Logs/Config: $hostName"
        try {
            $dns = Resolve-DnsName -Name $hostName -ErrorAction Stop
            Write-OK "DNS aufgeloest: $($dns.IPAddress -join ', ')"
        } catch { Write-Fail "DNS-Aufloesung fehlgeschlagen fuer $hostName" }

        foreach ($port in 443, 80) {
            $test = Test-NetConnection -ComputerName $hostName -Port $port -WarningAction SilentlyContinue
            if ($test.TcpTestSucceeded) { Write-OK "TCP $port zu $hostName erreichbar" }
            else { Write-Fail "TCP $port zu $hostName NICHT erreichbar" }
        }
    }
} else {
    Write-Warn "Kein Server-Hostname aus Logs/Config extrahierbar - manuelle Pruefung noetig."
}

# ============================================================
# 7. Eventlog (Application/System, Quelle enthaelt Matrix42/Empirum/UEM)
# ============================================================
Write-Section "7. Eventlog (letzte 30 Tage)"

$since = (Get-Date).AddDays(-30)
$events = Get-WinEvent -FilterHashtable @{ LogName = 'Application', 'System'; StartTime = $since } -ErrorAction SilentlyContinue |
    Where-Object { $_.ProviderName -match $svcKeywords -or $_.Message -match $svcKeywords }

if ($events) {
    $events | Select-Object -First 20 TimeCreated, LevelDisplayName, ProviderName, Id, Message | ForEach-Object {
        Write-Result "$($_.TimeCreated) [$($_.LevelDisplayName)] $($_.ProviderName) (Id $($_.Id))"
        $msg = ($_.Message -replace '\r?\n', ' ')
        if ($msg.Length -gt 300) { $msg = $msg.Substring(0, 300) }
        Write-Result "  $msg"
    }
} else {
    Write-Warn "Keine Eventlog-Eintraege mit Matrix42/Empirum/UEM in den letzten 30 Tagen."
}

Write-Section "Ende"
Write-Result "Report gespeichert unter: $OutputPath"
