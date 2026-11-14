<#
.SYNOPSIS
  Checks that a POS terminal meets the hardening applied by pos-hardening.ps1.

.DESCRIPTION
  Read-only: changes nothing. Prints an OK / FAIL table per check and, optionally, saves it.
  Run as administrator (to read the firewall and Defender). Exit code 1 if anything fails.

.EXAMPLE
  .\pos-check.ps1 -Output .\pos1-check.txt
#>
param(
    [string] $Server = '192.168.10.10',
    [int]    $OdooPort = 8069,
    [string] $CashierUser = 'cashier',
    [string] $Output
)

$results = [System.Collections.Generic.List[object]]::new()
function Test-Item([string] $area, [string] $what, [scriptblock] $probe) {
    # Each probe returns @{ ok = <bool>; detail = <text> }
    try { $r = & $probe } catch { $r = @{ ok = $false; detail = "error: $($_.Exception.Message)" } }
    $results.Add([pscustomobject]@{
        Area = $area; Check = $what
        Result = if ($r.ok) { 'OK' } else { 'FAIL' }; Detail = $r.detail })
}
function Get-RegistryValue([string] $path, [string] $name) { (Get-ItemProperty -Path $path -Name $name -ErrorAction SilentlyContinue).$name }

$os = Get-CimInstance Win32_OperatingSystem
Test-Item 'System' 'Windows 10 Pro / Enterprise / IoT' {
    @{ ok = [bool](($os.Caption -match 'Windows 10') -and ($os.Caption -notmatch 'Home')); detail = "$($os.Caption) $($os.Version)" } }
Test-Item 'System' 'Computer named POS1 or POS2' { @{ ok = [bool]($env:COMPUTERNAME -match '^POS[12]$'); detail = $env:COMPUTERNAME } }

Test-Item 'Accounts' "Account '$CashierUser' exists and is enabled" {
    $u = Get-LocalUser -Name $CashierUser -ErrorAction SilentlyContinue
    @{ ok = [bool]($u -and $u.Enabled); detail = $(if ($u) { "enabled: $($u.Enabled)" } else { 'does not exist' }) } }
Test-Item 'Accounts' "'$CashierUser' is not an administrator" {
    $admins = Get-LocalGroupMember -Group (Get-LocalGroup -SID 'S-1-5-32-544') | ForEach-Object Name
    @{ ok = [bool](-not ($admins -like "*\$CashierUser")); detail = "Administrators: $($admins -join ', ')" } }
Test-Item 'Accounts' 'A standard user cannot elevate (UAC)' {
    $lua = Get-RegistryValue 'HKLM:\SOFTWARE\Microsoft\Windows\CurrentVersion\Policies\System' 'EnableLUA'
    $usr = Get-RegistryValue 'HKLM:\SOFTWARE\Microsoft\Windows\CurrentVersion\Policies\System' 'ConsentPromptBehaviorUser'
    @{ ok = [bool](($lua -eq 1) -and ($usr -eq 0)); detail = "EnableLUA=$lua, ConsentPromptBehaviorUser=$usr" } }
Test-Item 'Accounts' 'Built-in Administrator and Guest disabled' {
    $enabled = Get-LocalUser | Where-Object { ($_.SID.Value -match '-50[01]$') -and $_.Enabled } | ForEach-Object Name
    @{ ok = [bool](-not $enabled); detail = $(if ($enabled) { "enabled: $($enabled -join ', ')" } else { 'disabled' }) } }

Test-Item 'USB' 'USB storage blocked' {
    $usb = Get-RegistryValue 'HKLM:\SYSTEM\CurrentControlSet\Services\USBSTOR' 'Start'
    $deny = Get-RegistryValue 'HKLM:\SOFTWARE\Policies\Microsoft\Windows\RemovableStorageDevices' 'Deny_All'
    @{ ok = [bool](($usb -eq 4) -and ($deny -eq 1)); detail = "USBSTOR Start=$usb, Deny_All=$deny" } }

Test-Item 'Firewall' 'Firewall on and everything blocked by default' {
    $p = Get-NetFirewallProfile
    $good = -not ($p | Where-Object { -not $_.Enabled -or $_.DefaultInboundAction -ne 'Block' -or $_.DefaultOutboundAction -ne 'Block' })
    @{ ok = [bool]($good); detail = ($p | ForEach-Object { "$($_.Name): $($_.Enabled)/$($_.DefaultInboundAction)/$($_.DefaultOutboundAction)" }) -join '; ' } }
Test-Item 'Firewall' 'POS outbound rules' {
    $n = @(Get-NetFirewallRule -Group 'Almi-Chain POS' -ErrorAction SilentlyContinue).Count
    @{ ok = ($n -ge 12); detail = "$n rules in the 'Almi-Chain POS' group" } }
Test-Item 'Firewall' 'Edge only opens Odoo' {
    $blocked = Get-RegistryValue 'HKLM:\SOFTWARE\Policies\Microsoft\Edge\URLBlocklist' '1'
    $allowed = (Get-ItemProperty 'HKLM:\SOFTWARE\Policies\Microsoft\Edge\URLAllowlist' -ErrorAction SilentlyContinue).PSObject.Properties |
               Where-Object Name -match '^\d+$' | ForEach-Object Value
    @{ ok = [bool](($blocked -eq '*') -and ($allowed -match [regex]::Escape($Server))); detail = "blocked: $blocked; allowed: $($allowed -join ', ')" } }
Test-Item 'Firewall' "Edge reaches Odoo ($($Server):$OdooPort)" {
    # PowerShell has no outbound rule: check that the Edge rule targets the server
    $r = Get-NetFirewallRule -Group 'Almi-Chain POS' -ErrorAction SilentlyContinue | Where-Object DisplayName -like '*Odoo*'
    $target = $r | Get-NetFirewallAddressFilter | ForEach-Object RemoteAddress
    @{ ok = [bool]($target -contains $Server); detail = "rule: $($r.DisplayName); target: $target" } }
Test-Item 'Firewall' 'Any other site fails (PowerShell, no rule, to 1.1.1.1:443)' {
    $connected = (Test-NetConnection 1.1.1.1 -Port 443 -WarningAction SilentlyContinue).TcpTestSucceeded
    @{ ok = [bool](-not $connected); detail = "connected: $connected" } }

Test-Item 'Updates' 'Automatic Windows Update' {
    $au = Get-RegistryValue 'HKLM:\SOFTWARE\Policies\Microsoft\Windows\WindowsUpdate\AU' 'AUOptions'
    @{ ok = [bool]($au -eq 4); detail = "AUOptions=$au" } }
Test-Item 'Updates' 'Defender real-time protection' {
    $mp = Get-MpComputerStatus
    @{ ok = [bool]($mp.RealTimeProtectionEnabled); detail = "real time: $($mp.RealTimeProtectionEnabled); signatures: $($mp.AntivirusSignatureLastUpdated)" } }
Test-Item 'Services' 'Remote Desktop disabled' {
    $rdp = Get-RegistryValue 'HKLM:\SYSTEM\CurrentControlSet\Control\Terminal Server' 'fDenyTSConnections'
    @{ ok = [bool]($rdp -eq 1); detail = "fDenyTSConnections=$rdp" } }
Test-Item 'Kiosk' 'Kiosk mode (Assigned Access) configured' {
    $aa = Get-ChildItem 'HKLM:\SOFTWARE\Microsoft\Windows\AssignedAccessConfiguration\Profiles' -ErrorAction SilentlyContinue
    @{ ok = [bool]$aa; detail = $(if ($aa) { "$(@($aa).Count) profile(s)" } else { 'not configured yet' }) } }

$table = $results | Format-Table -AutoSize -Wrap | Out-String -Width 200
$failures = @($results | Where-Object Result -eq 'FAIL').Count
$summary = "{0} checks: {1} OK, {2} FAIL · {3} · {4}" -f $results.Count, ($results.Count - $failures), $failures, $env:COMPUTERNAME, (Get-Date -Format 'yyyy-MM-dd HH:mm')
Write-Host $table
Write-Host $summary -ForegroundColor $(if ($failures) { 'Yellow' } else { 'Green' })
if ($Output) {
    $dir = Split-Path $Output
    if ($dir) { New-Item -ItemType Directory -Force -Path $dir | Out-Null }
    "# pos-check.ps1`n$table`n$summary" | Out-File -FilePath $Output -Encoding utf8
    Write-Host "Saved to $Output"
}
exit [int]($failures -gt 0)
