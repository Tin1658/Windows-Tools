#Requires -Version 5.1
#Requires -RunAsAdministrator
<#
P1.ps1 - Windows 11 post-install setup.
Order: existing USB programs (p.ps1) -> profile settings -> Office shortcuts
-> Windows Update including offered drivers -> MyASUS (ASUS only)
-> guided current-user default-app associations -> manual restart by user.

Run in Windows PowerShell as Administrator, using the TARGET USER account.
P1 never schedules a Windows restart. Restart manually when ready.
P1 never calls Windows-Update-All.ps1/u.ps1 because those request AutoReboot.
#>
# Inline-compatible script: Invoke-Expression cannot bind a top-level param block.
# Defaults for optional stages.
$SkipPrograms = $false
$SkipUpdates = $false

$ErrorActionPreference = 'Stop'
$script:Problems = New-Object 'System.Collections.Generic.List[string]'
$script:Completed = New-Object 'System.Collections.Generic.List[string]'
$script:Manual = New-Object 'System.Collections.Generic.List[string]'
$script:RestartRequired = $false
$script:TranscriptRunning = $false
$script:LogPath = Join-Path ([Environment]::GetFolderPath('Desktop')) 'P1-Setup.log'
try {
    Start-Transcript -Path $script:LogPath -Append -ErrorAction Stop | Out-Null
    $script:TranscriptRunning = $true
}
catch { Write-Warning ('P1 could not start the log file: ' + $_.Exception.Message) }

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
function Check-ExpectedWindowsProfile {
    $currentName = [Environment]::UserName
    Write-Host ('Windows profile: ' + $currentName + ' (expected User)')
    if ($currentName -cne 'User') {
        $script:Manual.Add('Windows account is ' + $currentName + '; expected User. Existing account will not be renamed automatically.')
    }
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
function Test-MyASUSInstalled {
    try { return (@(Get-AppxPackage -Name 'B9ECED6F.ASUSPCAssistant' -ErrorAction Stop).Count -gt 0) }
    catch { return $false }
}
function Test-ASUSSystemControlInterface {
    try {
        $devices = @(Get-CimInstance Win32_PnPEntity -ErrorAction Stop |
            Where-Object { $_.Name -match 'ASUS System Control Interface' -and $_.ConfigManagerErrorCode -eq 0 })
        return ($devices.Count -gt 0)
    }
    catch { return $false }
}
function Install-MyASUSIfAppropriate {
    $pc = Get-CimInstance Win32_ComputerSystem
    if ($pc.Manufacturer -notmatch 'ASUS|ASUSTeK') {
        Write-Host ('Skipping MyASUS: manufacturer is ' + $pc.Manufacturer)
        return
    }
    if (Test-MyASUSInstalled) { Write-Host 'MyASUS already installed. Skipped.' }
    else {
        $winget = Get-Command winget.exe -ErrorAction SilentlyContinue
        if ($winget) {
            Write-Host 'Installing MyASUS from official Microsoft Store using WinGet.'
            & $winget.Source install --id 9N7R5S6B0ZZH --exact --source msstore --silent --accept-source-agreements --accept-package-agreements
            if ($LASTEXITCODE -ne 0 -and -not (Test-MyASUSInstalled)) {
                Write-Warning 'Store-source install failed. Refreshing msstore source and retrying once.'
                & $winget.Source source update --name msstore
                & $winget.Source install --id 9N7R5S6B0ZZH --exact --source msstore --silent --accept-source-agreements --accept-package-agreements
            }
        }
        if (-not (Test-MyASUSInstalled)) {
            Write-Warning 'MyASUS was not installed through WinGet. Opening official Microsoft Store.'
            try { Start-Process 'ms-windows-store://pdp/?ProductId=9N7R5S6B0ZZH' -ErrorAction Stop }
            catch { Start-Process 'https://www.microsoft.com/store/apps/9N7R5S6B0ZZH' }
            [void](Read-Host 'Install MyASUS in Microsoft Store, then press Enter to recheck')
        }
        if (-not (Test-MyASUSInstalled)) {
            $script:Manual.Add('MyASUS still missing: troubleshoot Microsoft Store connection/certificate, then use the official Store.')
            throw 'MyASUS installation could not be verified for this account.'
        }
        Write-Host 'Verified: MyASUS installed.' -ForegroundColor Green
    }
    if (Test-ASUSSystemControlInterface) {
        Write-Host 'ASUS System Control Interface device driver detected.'
    }
    else {
        $script:Manual.Add('ASUS System Control Interface not detected. MyASUS System Update may be unavailable; check official ASUS drivers for this model.')
        Write-Warning 'MyASUS may not have System Update without the ASUS System Control Interface driver.'
    }
}
function Open-MyASUSForUpdates {
    $pc = Get-CimInstance Win32_ComputerSystem
    if ($pc.Manufacturer -notmatch 'ASUS|ASUSTeK') { return }
    if (-not (Test-MyASUSInstalled)) { return }
    $app = @(Get-StartApps -ErrorAction SilentlyContinue |
        Where-Object { $_.Name -eq 'MyASUS' } | Select-Object -First 1)
    if ($app.Count -eq 0 -or [string]::IsNullOrWhiteSpace($app[0].AppID)) {
        $script:Manual.Add('Open MyASUS from Start > System Update and review pending drivers.')
        return
    }
    # The app provides no documented supported command-line interface for
    # choosing updates. Manual selection is required, especially for BIOS.
    Start-Process explorer.exe -ArgumentList ('shell:AppsFolder\' + $app[0].AppID)
    Write-Host 'In MyASUS, select System Update > Update selected items.'
    Write-Host 'Review Update History afterward; defer BIOS/firmware updates until ready for a manual restart.'
    [void](Read-Host 'After reviewing MyASUS System Update, press Enter to continue P1')
    $script:Manual.Add('Verify MyASUS System Update / Update History on this PC.')
}
# WUA supports asynchronous download/install jobs with real progress snapshots.
# Percentages and byte totals come from WUA; ETAs are estimates based on elapsed progress.
function Format-WuaBytes([double]$Bytes) {
    if ($Bytes -lt 0) { return 'unknown size' }
    if ($Bytes -ge 1GB) { return ('{0:N2} GB' -f ($Bytes / 1GB)) }
    return ('{0:N1} MB' -f ($Bytes / 1MB))
}
function Format-WuaEta([double]$Seconds) {
    if ($Seconds -lt 0 -or [double]::IsNaN($Seconds) -or [double]::IsInfinity($Seconds)) {
        return 'calculating'
    }
    if ($Seconds -gt 86400) { return 'over 1 day (very rough)' }
    $remaining = [TimeSpan]::FromSeconds([Math]::Ceiling($Seconds))
    if ($remaining.TotalHours -ge 1) {
        return ('about {0}h {1}m' -f [int][Math]::Floor($remaining.TotalHours),$remaining.Minutes)
    }
    return ('about {0}m {1}s' -f $remaining.Minutes,$remaining.Seconds)
}
function New-WuaCallback {
    # WUA accepts an Automation callback exposing DISPID 0.
    # The callback only satisfies WUA's async contract; progress is polled
    # from the job so it never touches PowerShell from a COM background thread.
    if (-not ('WindowsToolsWuaCallback' -as [type])) {
        Add-Type -TypeDefinition @'
using System;
using System.Runtime.InteropServices;
[ComVisible(true)]
[Guid("FDCBC9B8-4028-43F0-83EB-17F3C94D70BB")]
[ClassInterface(ClassInterfaceType.AutoDual)]
public sealed class WindowsToolsWuaCallback {
    [DispId(0)]
    public void Invoke(object job, object args) { }
}
'@ -ErrorAction Stop
    }
    return (New-Object WindowsToolsWuaCallback)
}
function Invoke-WuaWithProgress($Worker,[string]$Stage,$SelectedUpdates) {
    $job = $null
    $cbProgress = $null
    $cbCompleted = $null
    $activity = 'Windows Update and drivers - ' + $Stage
    try {
        try {
            $cbProgress = New-WuaCallback
            $cbCompleted = New-WuaCallback
            if ($Stage -eq 'Download') {
                $job = $Worker.BeginDownload($cbProgress,$cbCompleted,$null)
            } else {
                $job = $Worker.BeginInstall($cbProgress,$cbCompleted,$null)
            }
        }
        catch {
            Write-Warning ('Could not start asynchronous ' + $Stage + ': ' + $_.Exception.Message)
            Write-Warning 'Using standard Windows Update method. Live MB/ETA unavailable in this mode.'
            if ($Stage -eq 'Download') { return $Worker.Download() }
            return $Worker.Install()
        }

        $started = Get-Date
        $lastPrinted = [datetime]::MinValue
        $lastPercent = -1
        Write-Host ($Stage + ' started for ' + $SelectedUpdates.Count + ' updates. Checking progress every 3 seconds.')
        while (-not $job.IsCompleted) {
            $status = 'Waiting for Windows Update progress... ETA unavailable'
            $percent = 0
            $etaSeconds = -1.0
            try {
                # GetProgress returns a snapshot; it must be fetched again each poll.
                $p = $job.GetProgress()
                $percent = [Math]::Max(0,[Math]::Min(100,[int]$p.PercentComplete))
                $elapsed = ((Get-Date) - $started).TotalSeconds
                $index = [Math]::Max(0,[Math]::Min(($SelectedUpdates.Count - 1),[int]$p.CurrentUpdateIndex))
                $itemLabel = ('[{0}/{1}]' -f ($index + 1),$SelectedUpdates.Count)
                if ($Stage -eq 'Download') {
                    $downloaded = 0.0
                    $total = 0.0
                    $hasDownloaded = [double]::TryParse([string]$p.TotalBytesDownloaded,
                        [System.Globalization.NumberStyles]::Float,
                        [System.Globalization.CultureInfo]::InvariantCulture,[ref]$downloaded)
                    $hasTotal = [double]::TryParse([string]$p.TotalBytesToDownload,
                        [System.Globalization.NumberStyles]::Float,
                        [System.Globalization.CultureInfo]::InvariantCulture,[ref]$total)
                    if ($hasDownloaded -and $hasTotal -and $total -gt 0) {
                        $status = ('{0} {1} / {2} ({3}%)' -f $itemLabel,(Format-WuaBytes $downloaded),(Format-WuaBytes $total),$percent)
                        if ($elapsed -ge 10 -and $downloaded -gt 0 -and $total -gt $downloaded) {
                            $etaSeconds = ($total - $downloaded) * $elapsed / $downloaded
                        }
                    } else {
                        $status = ('{0} {1}% (download size not reported)' -f $itemLabel,$percent)
                    }
                } else {
                    $status = ('{0} {1}% installed (current: {2}%)' -f $itemLabel,$percent,[int]$p.CurrentUpdatePercentComplete)
                }
                if ($etaSeconds -lt 0 -and $elapsed -ge 20 -and $percent -ge 5 -and $percent -lt 100) {
                    $etaSeconds = $elapsed * (100 - $percent) / $percent
                }
            }
            catch {
                $status = 'Windows Update is working; progress snapshot unavailable for now'
            }
            $etaText = Format-WuaEta $etaSeconds
            Write-Progress -Activity $activity -Status ($status + ' | ETA: ' + $etaText) -PercentComplete $percent -SecondsRemaining ([int]$etaSeconds)
            $now = Get-Date
            if (($now - $lastPrinted).TotalSeconds -ge 15 -or $percent -ge ($lastPercent + 10)) {
                Write-Host ('[{0}] {1} | ETA: {2}' -f $Stage.ToUpperInvariant(),$status,$etaText)
                $lastPrinted = $now
                $lastPercent = $percent
            }
            Start-Sleep -Seconds 3
        }
        if ($Stage -eq 'Download') { $result = $Worker.EndDownload($job) }
        else { $result = $Worker.EndInstall($job) }
        Write-Host ('{0} finished. WUA result code: {1}.' -f $Stage,$result.ResultCode) -ForegroundColor Green
        return $result
    }
    finally {
        Write-Progress -Activity $activity -Completed
        if ($null -ne $job) {
            try {
                if (-not $job.IsCompleted) { $job.RequestAbort() }
                $job.CleanUp()  # Releases callbacks after operation completes.
            } catch { Write-Warning ('Could not clean up Windows Update job: ' + $_.Exception.Message) }
        }
        # Keep callback objects alive until job cleanup has completed.
        $cbProgress = $null
        $cbCompleted = $null
    }
}

function Install-RecommendedUpdatesWithoutRestart {
    $session = New-Object -ComObject Microsoft.Update.Session
    $session.ClientApplicationID = 'Windows-Tools P1'
    $searcher = $session.CreateUpdateSearcher()
    Write-Host 'Searching assigned Windows updates and drivers. Scan progress/ETA is not supplied by Windows.'
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
    Write-Host ('Queued updates (Windows and offered drivers): ' + $updates.Count)
    if ($updates.Count -eq 0) {
        Write-Host 'No pending assigned updates. Optional/OEM drivers may still exist.'
        return
    }
    $downloader = $session.CreateUpdateDownloader()
    $downloader.Updates = $updates
    $downloadOutcome = Invoke-WuaWithProgress -Worker $downloader -Stage 'Download' -SelectedUpdates $updates
    if ($downloadOutcome.ResultCode -notin @(2,3)) {
        Write-Warning ('Windows Update download returned code ' + $downloadOutcome.ResultCode + '. Checking each item.')
    }
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
    $result = Invoke-WuaWithProgress -Worker $installer -Stage 'Install' -SelectedUpdates $ready
    # No Restart-Computer or AutoReboot is called by P1.
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
    Write-Host 'p.ps1 finished. Check any SKIPPED or WARNING messages for optional items.'
}
function Run-PostSetupBetaTest {
    # This is a read-only verification step; it does not install anything.
    $local = if ($PSScriptRoot) { Join-Path $PSScriptRoot 'P1-BetaTest.ps1' } else { '' }
    if ($local -and (Test-Path -LiteralPath $local -PathType Leaf)) {
        $source = $local
    } else {
        $source = Join-Path $env:TEMP 'WindowsTools-P1-BetaTest.ps1'
        $uri = 'https://raw.githubusercontent.com/Tin1658/Windows-Tools/main/P1-BetaTest.ps1'
        Invoke-WebRequest -Uri $uri -UseBasicParsing -OutFile $source -ErrorAction Stop
    }
    Write-Host ('Running read-only Beta Test: ' + $source)
    & (Join-Path $PSHOME 'powershell.exe') -NoProfile -ExecutionPolicy Bypass -File $source
    if ($LASTEXITCODE -ne 0) {
        throw ('Beta Test reported failed checks (exit ' + $LASTEXITCODE + '). Review the P1-BetaTest report on Desktop.')
    }
    Write-Host 'Beta Test completed. Review warnings and manual checks in the Desktop report.'
}

function Check-FileAssociations {
    # PDF belongs to Acrobat Reader; image file associations such as PNG are untouched.
    $rar = Get-CurrentUserAssociation '.rar'
    $pdf = Get-CurrentUserAssociation '.pdf'
    Write-Host ('Current .rar default ProgID: ' + $(if($rar){$rar}else{'unknown'}))
    Write-Host ('Current .pdf default ProgID: ' + $(if($pdf){$pdf}else{'unknown'}))
    $rarDone = $rar -like 'WinRAR*'
    $pdfDone = $pdf -match 'Acro|Adobe'
    if (-not ($rarDone -and $pdfDone)) {
        Write-Host 'Windows 11 protects current-user defaults; selecting an app requires your confirmation.'
        Write-Host 'Find .rar and choose WinRAR. Find .pdf and choose Adobe Acrobat Reader.'
        Write-Host 'Leave .png unchanged.'
        Start-Process 'ms-settings:defaultapps'
        [void](Read-Host 'After adjusting defaults, press Enter to verify and continue')
        $rar = Get-CurrentUserAssociation '.rar'
        $pdf = Get-CurrentUserAssociation '.pdf'
        $rarDone = $rar -like 'WinRAR*'
        $pdfDone = $pdf -match 'Acro|Adobe'
    }
    if (-not $rarDone) {
        $script:Manual.Add('Current .rar default is not WinRAR. Complete it in Default apps.')
    }
    if (-not $pdfDone) {
        $script:Manual.Add('Current .pdf default was not confirmed as Adobe Acrobat Reader. Check Default apps.')
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
    Write-Host 'P1 does not schedule a restart. Restart Windows manually when ready.'

    Step 'Check Windows profile name (User)' { Check-ExpectedWindowsProfile }
    if (-not $SkipPrograms) { Step 'Existing USB programs and Office (p.ps1)' { Run-ExistingPrograms } }
    Step 'Thai calendar and grave-accent switch' { Set-ThailandProfile }
    Step 'Windows desktop icons' { Set-DesktopIcons }
    Step 'Single static wallpaper' { Set-StaticWallpaper }
    Step 'Word / Excel / PowerPoint desktop shortcuts' { Add-OfficeShortcuts }
    if (-not $SkipUpdates) { Step 'Windows updates and offered drivers; no AutoReboot' { Install-RecommendedUpdatesWithoutRestart } }
    Step 'Install and verify MyASUS' { Install-MyASUSIfAppropriate }
    Step 'Open MyASUS to review remaining updates' { Open-MyASUSForUpdates }
    Step 'Check PDF and RAR default app assignments' { Check-FileAssociations }
    Step 'Read-only post-setup Beta Test and report' { Run-PostSetupBetaTest }

    Write-Host ''
    Write-Host '============= P1 SUMMARY =============' -ForegroundColor Green
    foreach ($x in $script:Completed) { Write-Host ('DONE: ' + $x) -ForegroundColor Green }
    foreach ($x in $script:Manual) { Write-Warning ('MANUAL: ' + $x) }
    foreach ($x in $script:Problems) { Write-Warning ('FAILED: ' + $x) }
    Write-Host 'Microsoft Office automatic-updates setting was intentionally left unchanged.'

    if ($script:Problems.Count -gt 0 -or $script:Manual.Count -gt 0) {
        Write-Warning 'Some setup steps need attention. Review them before restarting manually.'
    }
    if ($script:RestartRequired) {
        Write-Host 'Windows Update reports a restart is required; restart manually when ready.' -ForegroundColor Yellow
    }
    else {
        Write-Host 'P1 finished. No restart command was issued. Restart manually when ready.' -ForegroundColor Green
    }
}
catch {
    Write-Host ('P1 STOPPED: ' + $_.Exception.Message) -ForegroundColor Red
}
finally {
    if ($script:TranscriptRunning) {
        try { Stop-Transcript -ErrorAction Stop | Out-Null } catch {}
        Write-Host ('P1 log file: ' + $script:LogPath)
    }
}
