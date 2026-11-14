# Windows side of the manager's PC: disables the services an office PC does not need and
# writes a before/after report.
# Usage (PowerShell as administrator): powershell -ExecutionPolicy Bypass -File reduce-services.ps1 [-Output C:\Users\admin\Desktop]
# Safe to repeat: services already disabled or missing are skipped.
param([string]$Output = "$env:USERPROFILE\Desktop")
$ErrorActionPreference = 'Stop'

# What goes and why. The print spooler stays: the manager prints.
$remove = [ordered]@{
  'XblAuthManager' = 'Xbox Live: game sign-in'
  'XblGameSave'    = 'Xbox Live: saved games'
  'XboxNetApiSvc'  = 'Xbox Live: networking'
  'XboxGipSvc'     = 'Xbox accessories'
  'Fax'            = 'Fax: there is no fax line'
  'WMPNetworkSvc'  = 'Windows Media Player network sharing'
  'MapsBroker'     = 'Offline map downloads'
  'lfsvc'          = 'Device geolocation'
  'RetailDemo'     = 'Retail demo mode'
  'RemoteRegistry' = 'Editing the registry from another computer'
  'SharedAccess'   = 'Internet Connection Sharing (ICS)'
  'DiagTrack'      = 'Telemetry (Connected User Experiences and Telemetry)'
}

function Get-ActiveServices { Get-Service | Where-Object { $_.StartType -ne 'Disabled' } | Sort-Object Name |
  Select-Object Name, DisplayName, StartType, Status }

$before = Get-ActiveServices
$done = foreach ($n in $remove.Keys) {
  $s = Get-Service -Name $n -ErrorAction SilentlyContinue
  if ($s -and $s.StartType -ne 'Disabled') {
    if ($s.Status -eq 'Running') { Stop-Service -Name $n -Force -ErrorAction SilentlyContinue }
    Set-Service -Name $n -StartupType Disabled
    "$n ($($remove[$n]))"
  }
}
$after = Get-ActiveServices

$f = Join-Path $Output 'reduced-services.txt'
& {
  "# Manager's Windows: reduced services ($(Get-Date -Format 'yyyy-MM-dd HH:mm'))"
  ''; "## Services not disabled BEFORE ($($before.Count))"; $before | Format-Table -AutoSize | Out-String -Width 200
  "## Services not disabled AFTER ($($after.Count))"; $after | Format-Table -AutoSize | Out-String -Width 200
  '## Disabled in this run'; if ($done) { $done } else { '(none: already disabled or missing)' }
  ''; '## Why each one'; foreach ($n in $remove.Keys) { "- ${n}: $($remove[$n])" }
} | Out-File -FilePath $f -Encoding utf8
Write-Host "DONE. Report in $f"
