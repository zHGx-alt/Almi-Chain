#Requires -RunAsAdministrator
<#
.SYNOPSIS
  Hardens a bar POS terminal running Windows 10 (Pro or IoT Enterprise LTSC).

.DESCRIPTION
  Leaves the machine with least privilege and secure defaults:
    1. Computer name (POS1 / POS2).
    2. Standard "cashier" account (not an administrator) and password policy.
    3. UAC: a standard user cannot elevate; the built-in Administrator and Guest are disabled.
    4. USB storage blocked (keyboard, mouse, touch screen and printer keep working).
    5. Firewall: inbound blocked, outbound only to Odoo, DNS, DHCP, NTP and updates.
    6. Microsoft Edge limited to the Odoo POS (URL allowlist, no downloads, no developer tools).
    7. Windows Update and Defender on; updates at 03:00, never rebooting with a session open.
    8. No Remote Desktop, no SMBv1, no autoplay and no sleep.
  Kiosk mode (Assigned Access) is set up by hand afterwards, in 2 minutes.

  With -OdooCertificate it also installs the Odoo HTTPS proxy's certificate as a trusted root.

  Idempotent: safe to run again. Keeps a log in C:\ProgramData\AlmiChain\.

.EXAMPLE
  Set-ExecutionPolicy -Scope Process Bypass
  .\pos-hardening.ps1 -PosNumber 1

.EXAMPLE
  .\pos-hardening.ps1 -PosNumber 2 -OdooCertificate .\odoo.crt
#>
param(
    [Parameter(Mandatory)] [ValidateSet(1, 2)] [int] $PosNumber,
    [string] $Server = '192.168.10.10',       # Odoo server
    [string] $Router = '192.168.10.1',        # gateway and DNS
    [int[]]  $OdooPorts = @(8069, 443),       # 443 once the HTTPS proxy is on
    [string] $CashierUser = 'cashier',
    [string] $OdooCertificate                 # odoo.crt from the HTTPS proxy, optional
)

$ErrorActionPreference = 'Stop'
$RuleGroup = 'Almi-Chain POS'
New-Item -ItemType Directory -Force -Path 'C:\ProgramData\AlmiChain' | Out-Null
Start-Transcript -Path "C:\ProgramData\AlmiChain\pos-hardening-$(Get-Date -Format yyyyMMdd-HHmmss).log" | Out-Null

function Step([string] $text) { Write-Host "`n==> $text" -ForegroundColor Cyan }
function Set-RegistryValue([string] $path, [string] $name, $value, [string] $type = 'DWord') {
    if (-not (Test-Path $path)) { New-Item -Path $path -Force | Out-Null }
    New-ItemProperty -Path $path -Name $name -Value $value -PropertyType $type -Force | Out-Null
}

# ---------------------------------------------------------------------------
Step '0/8 Pre-checks'
$os = Get-CimInstance Win32_OperatingSystem
Write-Host "  System: $($os.Caption) $($os.Version)"
if ($os.Caption -notmatch 'Windows 10') { Write-Warning 'This is not Windows 10, which is what the tills run.' }
if ($os.Caption -match 'Home') { throw 'Windows Home has neither Assigned Access nor policies: Pro, Enterprise or IoT Enterprise is needed.' }

# ---------------------------------------------------------------------------
Step "1/8 Computer name: POS$PosNumber"
$name = "POS$PosNumber"
if ($env:COMPUTERNAME -ne $name) {
    Rename-Computer -NewName $name -Force
    Write-Host "  Renamed (applies after a reboot)."
} else { Write-Host '  Already named that.' }

# ---------------------------------------------------------------------------
Step "2/8 Standard account '$CashierUser' and password policy"
if (-not (Get-LocalUser -Name $CashierUser -ErrorAction SilentlyContinue)) {
    $secret = Read-Host "Password for '$CashierUser' (from the password manager)" -AsSecureString
    New-LocalUser -Name $CashierUser -Password $secret -FullName 'Bar cashier' `
        -Description 'Daily POS use (not an administrator)' -PasswordNeverExpires | Out-Null
    Add-LocalGroupMember -Group (Get-LocalGroup -SID 'S-1-5-32-545') -Member $CashierUser   # Users
    Write-Host '  Created.'
} else { Write-Host '  Already exists.' }
# Never in Administrators (SID S-1-5-32-544: the group name changes with the language)
$admins = Get-LocalGroup -SID 'S-1-5-32-544'
if (Get-LocalGroupMember -Group $admins | Where-Object Name -like "*\$CashierUser") {
    Remove-LocalGroupMember -Group $admins -Member $CashierUser
    Write-Host "  Removed from Administrators."
}
net accounts /minpwlen:12 /lockoutthreshold:10 /lockoutwindow:15 /lockoutduration:15 | Out-Null
Write-Host '  Passwords of 12 characters minimum; lockout for 15 min after 10 attempts.'

# ---------------------------------------------------------------------------
Step '3/8 UAC, built-in Administrator and Guest'
$uac = 'HKLM:\SOFTWARE\Microsoft\Windows\CurrentVersion\Policies\System'
Set-RegistryValue $uac 'EnableLUA' 1
Set-RegistryValue $uac 'ConsentPromptBehaviorAdmin' 2      # the administrator confirms on the secure desktop
Set-RegistryValue $uac 'ConsentPromptBehaviorUser' 0       # a standard user cannot elevate: denied without asking
Set-RegistryValue $uac 'PromptOnSecureDesktop' 1
foreach ($sid in @('-500', '-501')) {                       # built-in Administrator and Guest
    Get-LocalUser | Where-Object { $_.SID.Value.EndsWith($sid) -and $_.Enabled } | Disable-LocalUser
}
Write-Host '  UAC on; built-in Administrator and Guest disabled.'

# ---------------------------------------------------------------------------
Step '4/8 USB storage blocked'
Set-RegistryValue 'HKLM:\SYSTEM\CurrentControlSet\Services\USBSTOR' 'Start' 4
Set-RegistryValue 'HKLM:\SOFTWARE\Policies\Microsoft\Windows\RemovableStorageDevices' 'Deny_All' 1
Set-RegistryValue 'HKLM:\SOFTWARE\Microsoft\Windows\CurrentVersion\Policies\Explorer' 'NoDriveTypeAutoRun' 255
Write-Host '  USB sticks and disks are not mounted; autoplay disabled.'

# ---------------------------------------------------------------------------
Step '5/8 Firewall: inbound blocked, outbound only to what is needed'
Get-NetFirewallRule -Group $RuleGroup -ErrorAction SilentlyContinue | Remove-NetFirewallRule
$rules = @(
    @{ DisplayName = 'POS · Edge to the Odoo server'; Program = "${env:ProgramFiles(x86)}\Microsoft\Edge\Application\msedge.exe"
       Protocol = 'TCP'; RemoteAddress = $Server; RemotePort = $OdooPorts }
    @{ DisplayName = 'POS · DNS to the router (UDP)'; Service = 'Dnscache'; Protocol = 'UDP'; RemoteAddress = $Router; RemotePort = 53 }
    @{ DisplayName = 'POS · DNS to the router (TCP)'; Service = 'Dnscache'; Protocol = 'TCP'; RemoteAddress = $Router; RemotePort = 53 }
    @{ DisplayName = 'POS · DHCP'; Service = 'Dhcp'; Protocol = 'UDP'; RemotePort = 67 }
    @{ DisplayName = 'POS · Time (NTP)'; Service = 'W32Time'; Protocol = 'UDP'; RemotePort = 123 }
)
# Windows, Defender and Edge updates: HTTP/HTTPS only, and only those services
foreach ($service in 'wuauserv', 'BITS', 'UsoSvc', 'DoSvc', 'CryptSvc', 'WinDefend', 'edgeupdate') {
    $rules += @{ DisplayName = "POS · Updates ($service)"; Service = $service; Protocol = 'TCP'; RemotePort = @(80, 443) }
}
foreach ($r in $rules) {
    New-NetFirewallRule @r -Direction Outbound -Action Allow -Group $RuleGroup -Profile Any | Out-Null
    Write-Host "  + $($r.DisplayName)"
}
Set-NetFirewallProfile -Profile Domain, Private, Public -Enabled True `
    -DefaultInboundAction Block -DefaultOutboundAction Block -NotifyOnListen False
Write-Host '  Profiles on: anything not on the list is blocked, both ways.'

# ---------------------------------------------------------------------------
Step '6/8 Microsoft Edge limited to the Odoo POS'
$edge = 'HKLM:\SOFTWARE\Policies\Microsoft\Edge'
Remove-Item "$edge\URLAllowlist", "$edge\URLBlocklist" -Recurse -Force -ErrorAction SilentlyContinue
Set-RegistryValue "$edge\URLBlocklist" '1' '*' 'String'                         # everything blocked...
$i = 1
foreach ($port in $OdooPorts) {
    $url = if ($port -eq 443) { "https://$Server" } else { "http://$($Server):$port" }
    Set-RegistryValue "$edge\URLAllowlist" "$i" $url 'String'                   # ...except Odoo
    $i++
}
Set-RegistryValue $edge 'DeveloperToolsAvailability' 2      # no developer tools
Set-RegistryValue $edge 'InPrivateModeAvailability' 1       # no InPrivate
Set-RegistryValue $edge 'DownloadRestrictions' 3            # no downloads
Set-RegistryValue $edge 'PasswordManagerEnabled' 0          # never stores the cashier's Odoo password
Set-RegistryValue $edge 'BrowserSignin' 0
Set-RegistryValue $edge 'SyncDisabled' 1
Set-RegistryValue $edge 'AutofillCreditCardEnabled' 0
Set-RegistryValue $edge 'HideFirstRunExperience' 1
Set-RegistryValue "$edge\ExtensionInstallBlocklist" '1' '*' 'String'
Write-Host "  It only opens $(($OdooPorts | ForEach-Object { "$($Server):$_" }) -join ', ')."

# ---------------------------------------------------------------------------
Step '7/8 Windows Update and Microsoft Defender'
$wu = 'HKLM:\SOFTWARE\Policies\Microsoft\Windows\WindowsUpdate\AU'
Set-RegistryValue $wu 'NoAutoUpdate' 0
Set-RegistryValue $wu 'AUOptions' 4                          # download and install automatically...
Set-RegistryValue $wu 'ScheduledInstallDay' 0                # ...every day...
Set-RegistryValue $wu 'ScheduledInstallTime' 3               # ...at 03:00, with the restaurant closed
Set-RegistryValue $wu 'NoAutoRebootWithLoggedOnUsers' 1      # never reboots in the middle of a payment
Set-Service wuauserv -StartupType Manual                      # Windows starts it when needed
Set-MpPreference -DisableRealtimeMonitoring $false -PUAProtection Enabled
Write-Host '  Daily updates at 03:00; Defender in real time and against unwanted applications.'

# ---------------------------------------------------------------------------
Step '8/8 Services and power'
Set-RegistryValue 'HKLM:\SYSTEM\CurrentControlSet\Control\Terminal Server' 'fDenyTSConnections' 1
Disable-WindowsOptionalFeature -Online -FeatureName SMB1Protocol -NoRestart -ErrorAction SilentlyContinue | Out-Null
powercfg /change standby-timeout-ac 0
powercfg /change monitor-timeout-ac 30
Write-Host '  Remote Desktop and SMBv1 off; the POS never sleeps (the screen turns off after 30 min).'

if ($OdooCertificate) {
    Step 'Extra: Odoo HTTPS proxy certificate'
    $cert = Import-Certificate -FilePath $OdooCertificate -CertStoreLocation Cert:\LocalMachine\Root
    Write-Host "  Installed as a trusted root. Fingerprint: $($cert.Thumbprint) (compare it with the one enable-https.sh printed)"
}

Write-Host "`nDone. Next: kiosk mode (Assigned Access), reboot and run pos-check.ps1." -ForegroundColor Green
Stop-Transcript | Out-Null
