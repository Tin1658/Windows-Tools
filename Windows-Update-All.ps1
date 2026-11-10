# Windows-Update-All.ps1
# Run from an elevated Windows PowerShell (Administrator).
# Downloads and installs available Windows/Microsoft updates, then reboots if required.
# Review this script before executing code from GitHub.

#Requires -Version 5.1
$ErrorActionPreference = 'Stop'

try {
    $admin = ([Security.Principal.WindowsPrincipal] [Security.Principal.WindowsIdentity]::GetCurrent()).IsInRole(
        [Security.Principal.WindowsBuiltInRole]::Administrator
    )
    if (-not $admin) {
        throw 'Open Windows PowerShell as Administrator and run this script again.'
    }

    Write-Host '[1/4] Preparing package downloads...' -ForegroundColor Cyan
    [Net.ServicePointManager]::SecurityProtocol = [Net.ServicePointManager]::SecurityProtocol -bor [Net.SecurityProtocolType]::Tls12

    if (-not (Get-PackageProvider -Name NuGet -ListAvailable -ErrorAction SilentlyContinue)) {
        Install-PackageProvider -Name NuGet -MinimumVersion '2.8.5.201' -Scope CurrentUser -Force -ErrorAction Stop | Out-Null
    }

    $repo = Get-PSRepository -Name PSGallery -ErrorAction SilentlyContinue
    if (-not $repo) {
        throw 'PSGallery is not registered. Check network access and PowerShellGet configuration.'
    }

    Write-Host '[2/4] Installing/importing PSWindowsUpdate...' -ForegroundColor Cyan
    $originalPolicy = $repo.InstallationPolicy
    try {
        if ($originalPolicy -ne 'Trusted') {
            Set-PSRepository -Name PSGallery -InstallationPolicy Trusted -ErrorAction Stop
        }
        if (-not (Get-Module -ListAvailable -Name PSWindowsUpdate)) {
            Install-Module -Name PSWindowsUpdate -Repository PSGallery -Scope CurrentUser -Force -AllowClobber -ErrorAction Stop
        }
        Import-Module PSWindowsUpdate -Force -ErrorAction Stop
    }
    finally {
        if ($originalPolicy -ne 'Trusted') {
            Set-PSRepository -Name PSGallery -InstallationPolicy $originalPolicy -ErrorAction SilentlyContinue
        }
    }

    if (-not (Get-Command -Name Get-WindowsUpdate -ErrorAction SilentlyContinue)) {
        throw 'PSWindowsUpdate was not loaded; Get-WindowsUpdate is unavailable.'
    }

    Write-Host '[3/4] Enabling Microsoft Update...' -ForegroundColor Cyan
    try {
        Add-WUServiceManager -MicrosoftUpdate -Confirm:$false -ErrorAction Stop | Out-Null
    }
    catch {
        Write-Warning "Could not register Microsoft Update: $($_.Exception.Message)"
        Write-Warning 'Attempting the update scan anyway.'
    }

    Write-Host '[4/4] Searching, downloading and installing available updates...' -ForegroundColor Green
    Write-Warning 'Save your work: this PC may restart automatically.'
    Get-WindowsUpdate -MicrosoftUpdate -Install -AcceptAll -AutoReboot -Verbose -ErrorAction Stop
    Write-Host 'Update pass complete. Run again after a restart to check for newly available updates.' -ForegroundColor Green
}
catch {
    Write-Host "FAILED: $($_.Exception.Message)" -ForegroundColor Red
    Write-Host 'Copy or photograph this error to troubleshoot it.' -ForegroundColor Yellow
}
