# Windows side of the manager's PC: BitLocker on C: without a TPM, with a boot password
# (PowerShell as administrator).
# Usage: powershell -ExecutionPolicy Bypass -File bitlocker-without-tpm.ps1 -Output E:\
#   -Output: a folder OUTSIDE C: (USB or network share) for the recovery key and the report.
# The recovery key is NEVER shown on screen: it goes to a file that is moved into the
# password manager and then deleted.
param([Parameter(Mandatory)][string]$Output)
$ErrorActionPreference = 'Stop'
$cv = Get-ItemProperty 'HKLM:\SOFTWARE\Microsoft\Windows NT\CurrentVersion'
if ($cv.EditionID -match 'Core') { throw "Edition $($cv.EditionID): Windows Home has no BitLocker" }

# Policy "Require additional authentication at startup" + "Allow BitLocker without a compatible TPM"
# (the same as gpedit: Windows Components > BitLocker Drive Encryption > Operating System Drives)
$k = 'HKLM:\SOFTWARE\Policies\Microsoft\FVE'; New-Item $k -Force | Out-Null
@{UseAdvancedStartup=1; EnableBDEWithNoTPM=1; UseTPM=2; UseTPMPIN=2; UseTPMKey=2; UseTPMKeyPIN=2}.GetEnumerator() |
  ForEach-Object { New-ItemProperty $k -Name $_.Key -Value $_.Value -PropertyType DWord -Force | Out-Null }
gpupdate /target:computer /force | Out-Null

$v = Get-BitLockerVolume C:
if (-not ($v.KeyProtector | Where-Object KeyProtectorType -eq 'Password')) {
  do {
    $a = Read-Host -AsSecureString 'BitLocker BOOT password (8+ characters, from the password manager)'
    $b = Read-Host -AsSecureString 'Repeat it'
    $pa = [Runtime.InteropServices.Marshal]::PtrToStringBSTR([Runtime.InteropServices.Marshal]::SecureStringToBSTR($a))
    $pb = [Runtime.InteropServices.Marshal]::PtrToStringBSTR([Runtime.InteropServices.Marshal]::SecureStringToBSTR($b))
    $ok = ($pa -ceq $pb) -and $pa.Length -ge 8; $pa = $pb = $null
    if (-not $ok) { Write-Host 'They do not match or are shorter than 8 characters. Try again.' -ForegroundColor Yellow }
  } until ($ok)
  Enable-BitLocker -MountPoint C: -EncryptionMethod XtsAes256 -UsedSpaceOnly -SkipHardwareTest -PasswordProtector -Password $a | Out-Null
}
if (-not ((Get-BitLockerVolume C:).KeyProtector | Where-Object KeyProtectorType -eq 'RecoveryPassword')) {
  # -WarningAction: without it, the cmdlet prints the key on screen as a warning
  Add-BitLockerKeyProtector -MountPoint C: -RecoveryPasswordProtector -WarningAction SilentlyContinue *> $null
}
$rp = (Get-BitLockerVolume C:).KeyProtector | Where-Object KeyProtectorType -eq 'RecoveryPassword' | Select-Object -First 1
@("BitLocker C: $env:COMPUTERNAME ($(Get-Date -Format 'yyyy-MM-dd'))", "Key ID: $($rp.KeyProtectorId)",
  "Recovery password: $($rp.RecoveryPassword)") | Set-Content -Encoding utf8 (Join-Path $Output 'BITLOCKER-RECOVERY-KEY.txt')
$rp = $null
& { "# BitLocker on C: ($(Get-Date -Format 'yyyy-MM-dd HH:mm'))"
    "Edition: $($cv.EditionID)  Version: $($cv.DisplayVersion)  Build: $($cv.CurrentBuild).$($cv.UBR)"
    manage-bde -status C:
    (Get-BitLockerVolume C:).KeyProtector | Format-Table KeyProtectorType, KeyProtectorId -AutoSize | Out-String
} | Set-Content -Encoding utf8 (Join-Path $Output 'bitlocker-status.txt')
Write-Host "DONE. Key in $Output (move it into the password manager and delete the file). Encryption continues in the background." -ForegroundColor Green
