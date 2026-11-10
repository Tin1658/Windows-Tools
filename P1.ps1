#Requires -Version 5.1
#Requires -RunAsAdministrator
<#
P1.ps1 - Windows 11 post-install setup.
Order: existing USB programs (p.ps1) -> profile settings -> Office shortcuts
-> MyASUS (ASUS only) -> Windows Update including offered drivers
-> guided current-user default-app associations -> one final reboot.

Run in Windows PowerShell as Administrator, using the TARGET USER account.
Automatic restart can be disabled with -NoRestart.
P1 never calls Windows-Update-All.ps1/u.ps1 because those request AutoReboot.
#>
[CmdletBinding()]
param(
    [switch]$SkipPrograms,
    [switch]$SkipUpdates,
    [switch]$NoRestart
)

$ErrorActionPreference = 'Stop'
$script:Problems = New-Object 'System.Collections.Generic.List[string]'
$script:Completed = New-Object 'System.Collections.Generic.List[string]'
$script:Manual = New-Object 'System.Collections.Generic.List[string]'
$script:RestartRequired = $false

function Step([string]$Name, [scriptblock]$Action) {
    Write-Host ''
    Write-Host ('[P1] ' + $Name) -ForegroundColor Cyan
    try {
        & $Action
        $script:Completed.Add($Name)
    }
    catch {
        $message = $Name + ': ' + $_.Exception.Message
        $script:Problems.Add($message)
        Write-Warning $message
    }
}
function Set-ValueIfDifferent([string]$Path,[string]$Name,$Value,[string]$Type = 'String') {
    if (-not (Test-Path -LiteralPath $Path)) { New-Item -Path $Path -Force | Out-Null }
    $old = Get-ItemProperty -LiteralPath $Path -Name $Name -ErrorAction SilentlyContinue
    if (($null -ne $old) -and ([string]$old.$Name -ceq [string]$Value)) { return }
    New-ItemProperty -LiteralPath $Path -Name $Name -Value $Value -PropertyType $Type -Force | Out-Null
}
function Get-CurrentUserAssociation([string]$Extension) {
    $key = 'HKCU:\Software\Microsoft\Windows\CurrentVersion\Explorer\FileExts\' + $Extension + '\UserChoice'
    try { return [string](Get-ItemProperty -LiteralPath $key -Name ProgId -ErrorAction Stop).ProgId }
    catch { return '' }
}
function Set-DesktopIcons {
    $path = 'HKCU:\Software\Microsoft\Windows\CurrentVersion\Explorer\HideDesktopIcons\NewStartPanel'
    # This PC, Network, Control Panel, User's Files, Recycle Bin
    $ids = @(
        '{20D04FE0-3AEA-1069-A2D8-08002B30309D}',
        '{F02C1A0D-BE21-4350-88B0-7367FC96EF3C}',
        '{5399E694-6CE5-4D6C-8FCE-1D8870FDCBA0}',
        '{59031a47-3f72-44a7-89c5-5595fe6b30ee}',
        '{645FF040-5081-101B-9F08-00AA002F954E}'
    )
    foreach ($id in $ids) { Set-ValueIfDifferent -Path $path -Name $id -Value 0 -Type DWord }
    Write-Host 'Desktop icons enabled (visible after Explorer refresh/sign-in).'
}
function Set-ThailandProfile {
    $current = Get-Culture
    if ($current.Name -ne 'th-TH') { Set-Culture -CultureInfo 'th-TH' }
    $intl = 'HKCU:\Control Panel\International'
    Set-ValueIfDifferent $intl 'sShortDate' 'dd/MM/yyyy'
    Set-ValueIfDifferent $intl 'iCalendarType' '7'
    # Add Thai input keyboard without changing the existing Windows display language.
    $languages = Get-WinUserLanguageList
    if (@($languages | Where-Object { $_.LanguageTag -eq 'th-TH' }).Count -eq 0) {
        $languages.Add('th-TH')
        Set-WinUserLanguageList -LanguageList $languages -Force
    }
    # Thai-enabled Windows supports grave accent as the input-language toggle.
    $toggle = 'HKCU:\Keyboard Layout\Toggle'
    Set-ValueIfDifferent $toggle 'Hotkey' '4'
    Set-ValueIfDifferent $toggle 'Language Hotkey' '4'
    Set-ValueIfDifferent $toggle 'Layout Hotkey' '3'
    Write-Host 'Thai Buddhist calendar (dd/MM/yyyy) and grave-accent key configured.'
    Write-Host 'Language shortcut and region settings may require sign-out/restart.'
}
function Set-StaticWallpaper {
    $preferred = Join-Path $env:WINDIR 'Web\Wallpaper\Windows\img0.jpg'
    $wallpaper = if (Test-Path -LiteralPath $preferred) { $preferred } else { $null }
    if (-not $wallpaper) {
        $image = Get-ChildItem (Join-Path $env:WINDIR 'Web\Wallpaper') -File -Recurse -ErrorAction SilentlyContinue |
            Where-Object { $_.Extension -in @('.jpg','.jpeg','.bmp') } |
            Select-Object -First 1
        if ($image) { $wallpaper = $image.FullName }
    }
    if (-not $wallpaper) { throw 'No built-in Windows wallpaper image was found.' }
    $key = 'HKCU:\Software\Microsoft\Windows\CurrentVersion\Explorer\Wallpapers'
    Set-ValueIfDifferent $key 'BackgroundType' 0 'DWord'
    if (-not ('P1Desktop' -as [type])) {
        Add-Type -TypeDefinition @'
using System;
using System.Runtime.InteropServices;
public static class P1Desktop {
    [DllImport("user32.dll", CharSet=CharSet.Unicode, SetLastError=true)]
    public static extern bool SystemParametersInfo(uint action,uint param,string value,uint flags);
}
'@
    }
    # SPI_SETDESKWALLPAPER=20; update profile & broadcast change=3.
    if (-not [P1Desktop]::SystemParametersInfo(20,0,$wallpaper,3)) {
        throw 'Windows could not apply the static wallpaper.'
    }
    Write-Host ('Single-picture wallpaper: ' + $wallpaper)
}
function Add-OfficeShortcuts {
    $prefixes = @($env:ProgramFiles, [Environment]::GetEnvironmentVariable('ProgramFiles(x86)')) |
        Where-Object { -not [string]::IsNullOrWhiteSpace($_) }
    $folders = @()
    foreach ($prefix in $prefixes) {
        $folders += (Join-Path $prefix 'Microsoft Office\root\Office16')
        $folders += (Join-Path $prefix 'Microsoft Office\Office16')
    }
    $apps = @(
        @{Name='Word';       Exe='WINWORD.EXE'},
        @{Name='Excel';      Exe='EXCEL.EXE'},
        @{Name='PowerPoint'; Exe='POWERPNT.EXE'}
    )
    $desktop = [Environment]::GetFolderPath('Desktop')
    $shell = New-Object -ComObject WScript.Shell
    $missing = @()
    foreach ($app in $apps) {
        $found = $null
        foreach ($folder in $folders) {
            $candidate = Join-Path $folder $app.Exe
            if (Test-Path -LiteralPath $candidate -PathType Leaf) { $found=$candidate; break }
        }
        if (-not $found) { $missing += $app.Name; continue }
        $shortcutPath = Join-Path $desktop ($app.Name + '.lnk')
        $shortcut = $shell.CreateShortcut($shortcutPath)
        if ((Test-Path -LiteralPath $shortcutPath) -and ($shortcut.TargetPath -ieq $found)) {
            Write-Host ('Already present: ' + $app.Name)
            continue
        }
        $shortcut.TargetPath = $found
        $shortcut.WorkingDirectory = Split-Path -Parent $found
        $shortcut.IconLocation = $found + ',0'
        $shortcut.Description = 'Microsoft ' + $app.Name
        $shortcut.Save()
        Write-Host ('Shortcut added: ' + $app.Name)
    }
    if ($missing.Count) { throw ('Office apps not installed/found: ' + ($missing -join ', ')) }
}
function Install-MyASUSIfAppropriate {
    $pc = Get-CimInstance Win32_ComputerSystem
    if ($pc.Manufacturer -notmatch 'ASUS|ASUSTeK') {
        Write-Host ('Skipped MyASUS: manufacturer is ' + $pc.Manufacturer)
        return
    }
    $present = @(Get-AppxPackage -Name 'B9ECED6F.ASUSPCAssistant' -ErrorAction SilentlyContinue)
    if ($present.Count) { Write-Host 'MyASUS already installed.'; return }
    $winget = Get-Command winget.exe -ErrorAction SilentlyContinue
    if (-not $winget) {
        $script:Manual.Add('Install MyASUS from Microsoft Store; WinGet unavailable.')
        return
    }
    # Official ASUS Store ID. MyASUS availability/driver support varies by model.
    & $winget.Source install --id 9N7R5S6B0ZZH --exact --source msstore --silent --accept-source-agreements --accept-package-agreements
    if ($LASTEXITCODE -ne 0) {
        throw ('MyASUS Microsoft Store install failed: exit ' + $LASTEXITCODE)
    }
}
function Install-RecommendedUpdatesWithoutRestart {
    $session = New-Object -ComObject Microsoft.Update.Session
    $session.ClientApplicationID = 'Windows-Tools P1'
    $searcher = $session.CreateUpdateSearcher()
    Write-Host 'Searching assigned Windows updates and drivers. This may take a while.'
    $found = $searcher.Search('IsInstalled=0 and IsHidden=0 and IsAssigned=1')
    $updates = New-Object -ComObject Microsoft.Update.UpdateColl
    for ($i=0; $i -lt $found.Updates.Count; $i++) {
        $update = $found.Updates.Item($i)
        if ($update.InstallationBehavior.CanRequestUserInput) {
            $script:Manual.Add('Interactive update: ' + $update.Title)
            continue
        }
        if (-not $update.EulaAccepted) { $update.AcceptEula() }
        [void]$updates.Add($update)
        Write-Host ('Queued: ' + $update.Title)
    }
    if ($updates.Count -eq 0) {
        Write-Host 'No pending assigned updates. Optional/OEM drivers may still exist.'
        return
    }
    $downloader = $session.CreateUpdateDownloader()
    $downloader.Updates = $updates
    [void]$downloader.Download()
    $ready = New-Object -ComObject Microsoft.Update.UpdateColl
    for ($i=0; $i -lt $updates.Count; $i++) {
        $update = $updates.Item($i)
        if ($update.IsDownloaded) {
            [void]$ready.Add($update)
        } else {
            $script:Manual.Add('Update not downloaded: ' + $update.Title)
        }
    }
    if ($ready.Count -eq 0) { throw 'No updates were downloaded successfully.' }
    $installer = $session.CreateUpdateInstaller()
    $installer.Updates = $ready
    if ($installer.RebootRequiredBeforeInstallation) {
        throw 'Windows requires a reboot BEFORE these updates can be installed. Run P1 again afterward.'
    }
    $result = $installer.Install() # Does not call Restart-Computer or AutoReboot.
    $script:RestartRequired = $script:RestartRequired -or [bool]$result.RebootRequired
    $failed = @()
    for ($i=0; $i -lt $ready.Count; $i++) {
        $item = $result.GetUpdateResult($i)
        if ($item.ResultCode -ne 2) {
            $failed += ($ready.Item($i).Title + ' [code ' + $item.ResultCode + ']')
        }
    }
    if ($failed.Count) {
        throw ('Some updates need another attempt: ' + ($failed -join '; '))
    }
    Write-Host ('Installed ' + $ready.Count + ' updates; no mid-run reboot requested.')
}
function Run-ExistingPrograms {
    # Existing p.ps1 is intentionally kept unchanged and performs its own app checks.
    $local = if ($PSScriptRoot) { Join-Path $PSScriptRoot 'p.ps1' } else { '' }
    if ($local -and (Test-Path -LiteralPath $local -PathType Leaf)) {
        $source = $local
    } else {
        $source = Join-Path $env:TEMP 'WindowsTools-p.ps1'
        $uri = 'https://raw.githubusercontent.com/Tin1658/Windows-Tools/main/p.ps1'
        Invoke-WebRequest -Uri $uri -UseBasicParsing -OutFile $source -ErrorAction Stop
    }
    Write-Host ('Launching original program installer: ' + $source)
    Write-Warning 'Keep your USB Programs folder connected. Existing p.ps1 may request input.'
    & (Join-Path $PSHOME 'powershell.exe') -NoProfile -ExecutionPolicy Bypass -File $source
    if ($LASTEXITCODE -ne 0) { throw ('p.ps1 exit code ' + $LASTEXITCODE) }
    Write-Host 'p.ps1 finished. Review its own warnings; old script may return 0 after an error.'
}
function Check-FileAssociations {
    $rar = Get-CurrentUserAssociation '.rar'
    $png = Get-CurrentUserAssociation '.png'
    Write-Host ('Current .rar default ProgID: ' + $(if($rar){$rar}else{'unknown'}))
    Write-Host ('Current .png default ProgID: ' + $(if($png){$png}else{'unknown'}))
    if ($rar -notlike 'WinRAR*') {
        $script:Manual.Add('Set .rar to WinRAR in Settings > Apps > Default apps.')
    }
    if ($png -notmatch 'Acro|Adobe') {
        $script:Manual.Add('Set .png to the requested Adobe app, if that app supports PNG.')
    }
    if ($script:Manual.Count -gt 0) {
        Write-Host 'Some tasks may need manual action; opening Windows Default apps.'
        Start-Process 'ms-settings:defaultapps'
        Write-Host 'In Default apps search .rar and select WinRAR; search .png and choose Adobe if available.'
    }
}

try {
    $identity = [Security.Principal.WindowsIdentity]::GetCurrent()
    $principal = New-Object Security.Principal.WindowsPrincipal($identity)
    if (-not $principal.IsInRole([Security.Principal.WindowsBuiltInRole]::Administrator)) {
        throw 'Start Windows PowerShell with Run as administrator.'
    }
    Write-Host '============= WINDOWS-TOOLS P1 =============' -ForegroundColor Green
    Write-Host 'Run under the Windows account whose desktop and settings you want to change.'
    Write-Host 'Only P1 schedules a reboot, at the very end. P2 never reboots.'

    if (-not $SkipPrograms) { Step 'Existing USB programs and Office (p.ps1)' { Run-ExistingPrograms } }
    Step 'Thai calendar and grave-accent switch' { Set-ThailandProfile }
    Step 'Windows desktop icons' { Set-DesktopIcons }
    Step 'Single static wallpaper' { Set-StaticWallpaper }
    Step 'Word / Excel / PowerPoint desktop shortcuts' { Add-OfficeShortcuts }
    Step 'MyASUS (ASUS computers only)' { Install-MyASUSIfAppropriate }
    if (-not $SkipUpdates) { Step 'Windows updates and offered drivers; no AutoReboot' { Install-RecommendedUpdatesWithoutRestart } }
    Step 'Check PNG and RAR default app assignments' { Check-FileAssociations }

    Write-Host ''
    Write-Host '============= P1 SUMMARY =============' -ForegroundColor Green
    foreach ($x in $script:Completed) { Write-Host ('DONE: ' + $x) -ForegroundColor Green }
    foreach ($x in $script:Manual) { Write-Warning ('MANUAL: ' + $x) }
    foreach ($x in $script:Problems) { Write-Warning ('FAILED: ' + $x) }
    Write-Host 'Microsoft Office automatic-updates setting was intentionally left unchanged.'

    if ($NoRestart) {
        Write-Host 'NoRestart specified. Restart yourself after completing any manual steps.'
    }
    elseif ($script:Problems.Count -gt 0) {
        Write-Warning 'There are failed steps. Automatic restart was cancelled so you can review and retry.'
    }
    else {
        Write-Warning 'A single Windows restart is scheduled in 60 seconds. Save your work.'
        Write-Host 'To cancel the scheduled restart, run: shutdown /a'
        & shutdown.exe /r /t 60 /c "Windows-Tools P1 setup finished"
        if ($LASTEXITCODE -ne 0) { Write-Warning 'Could not schedule the final restart.' }
    }
}
catch {
    Write-Host ('P1 STOPPED: ' + $_.Exception.Message) -ForegroundColor Red
}
