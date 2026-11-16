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
# Set WT_QUICKFIX=1 to apply only Thai date/time and Windows 11 light/Bloom theme.
$QuickFix = ($env:WT_QUICKFIX -eq '1')

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
function Set-ThailandClock {
    # Thailand uses UTC+07:00 with no daylight-saving change.
    $desiredZone = 'SE Asia Standard Time'
    $currentZone = Get-TimeZone
    if ($currentZone.Id -ne $desiredZone) {
        Set-TimeZone -Id $desiredZone -ErrorAction Stop
        Write-Host ('Time zone changed to Thailand (UTC+07:00) from ' + $currentZone.Id)
    } else {
        Write-Host 'Time zone already Thailand (UTC+07:00).'
    }

    # Synchronize with the configured Windows time source: do not invent a clock value.
    try {
        $timeService = Get-Service -Name 'W32Time' -ErrorAction Stop
        if ($timeService.Status -ne 'Running') {
            Start-Service -Name 'W32Time' -ErrorAction Stop
        }
        $w32tm = Join-Path $env:WINDIR 'System32\w32tm.exe'
        $syncOutput = & $w32tm /resync /rediscover 2>&1
        if ($LASTEXITCODE -ne 0) {
            throw (($syncOutput | Out-String).Trim())
        }
        Write-Host 'Windows time synchronized using its configured time source.' -ForegroundColor Green
    }
    catch {
        Write-Warning ('Time synchronization not verified: ' + $_.Exception.Message)
        $script:Manual.Add('Check internet access and Settings > Time & language > Date & time > Sync now.')
    }
    $thaiCulture = [Globalization.CultureInfo]::GetCultureInfo('th-TH')
    Write-Host ('Local Thailand time: ' + (Get-Date).ToString('dd/MM/yyyy HH:mm:ss', $thaiCulture))
}

function Set-Windows11LightBloomTheme {
    # Match the user's Windows 11 light/Bloom preview, not a random wallpaper.
    $themeKey = 'HKCU:\Software\Microsoft\Windows\CurrentVersion\Themes\Personalize'
    Set-ValueIfDifferent $themeKey 'AppsUseLightTheme' 1 'DWord'
    Set-ValueIfDifferent $themeKey 'SystemUsesLightTheme' 1 'DWord'
    Set-ValueIfDifferent $themeKey 'EnableTransparency' 1 'DWord'
    Set-ValueIfDifferent $themeKey 'ColorPrevalence' 0 'DWord'

    $wallpaper = Join-Path $env:WINDIR 'Web\Wallpaper\Windows\img0.jpg'
    if (-not (Test-Path -LiteralPath $wallpaper -PathType Leaf)) {
        $folder = Join-Path $env:WINDIR 'Web\4K\Wallpaper\Windows'
        $fallback = @(Get-ChildItem -LiteralPath $folder -Filter 'img0_*' -File -ErrorAction SilentlyContinue |
            Where-Object { $_.Extension -in @('.jpg', '.jpeg', '.png') } |
            Sort-Object Length -Descending | Select-Object -First 1)
        if ($fallback.Count) { $wallpaper = $fallback[0].FullName }
        else {
            throw 'Windows 11 light Bloom wallpaper was not found. Not substituting another picture.'
        }
    }

    $desktopKey = 'HKCU:\Control Panel\Desktop'
    Set-ValueIfDifferent $desktopKey 'WallpaperStyle' '10'
    Set-ValueIfDifferent $desktopKey 'TileWallpaper' '0'
    $wallpaperKey = 'HKCU:\Software\Microsoft\Windows\CurrentVersion\Explorer\Wallpapers'
    Set-ValueIfDifferent $wallpaperKey 'BackgroundType' 0 'DWord'

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
    if (-not [P1Desktop]::SystemParametersInfo(20,0,$wallpaper,3)) {
        throw 'Windows could not apply the light Bloom desktop wallpaper.'
    }
    Write-Host ('Windows 11 light mode enabled. Bloom wallpaper: ' + $wallpaper) -ForegroundColor Green
    Write-Host 'Some taskbar/Settings theme changes may require signing out and back in.'
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
    $abortRequested = $false
    $activity = 'Windows Update and drivers - ' + $Stage
    try {
        $cbProgress = New-WuaCallback
        $cbCompleted = New-WuaCallback
        try {
            if ($Stage -eq 'Download') {
                $job = $Worker.BeginDownload($cbProgress,$cbCompleted,$null)
            } else {
                $job = $Worker.BeginInstall($cbProgress,$cbCompleted,$null)
            }
        }
        catch {
            # A synchronous fallback could block indefinitely with no progress or cancel option.
            throw ('Could not start asynchronous ' + $Stage + ': ' + $_.Exception.Message)
        }

        $started = Get-Date
        $lastMoved = $started
        $fullSince = $null
        $lastPrinted = [datetime]::MinValue
        $lastPercent = -1
        $lastBytes = -1.0
        $lastIndex = -1
        $lastWarning = [datetime]::MinValue
        $lastReportedPercent = -1
        Write-Host ($Stage + ' started for ' + $SelectedUpdates.Count + ' updates. Checking every 3 seconds.')
        while (-not $job.IsCompleted) {
            $status = 'Waiting for Windows Update progress...'
            $percent = 0
            $etaSeconds = -1.0
            $downloaded = -1.0
            $index = -1
            $now = Get-Date
            try {
                $p = $job.GetProgress()
                $percent = [Math]::Max(0,[Math]::Min(100,[int]$p.PercentComplete))
                $elapsed = ($now - $started).TotalSeconds
                $index = [Math]::Max(0,[Math]::Min(($SelectedUpdates.Count - 1),[int]$p.CurrentUpdateIndex))
                $itemLabel = ('[{0}/{1}]' -f ($index + 1),$SelectedUpdates.Count)
                if ($Stage -eq 'Download') {
                    $total = 0.0
                    $bytesReported = [double]::TryParse([string]$p.TotalBytesDownloaded,
                        [System.Globalization.NumberStyles]::Float,
                        [System.Globalization.CultureInfo]::InvariantCulture,[ref]$downloaded)
                    $totalReported = [double]::TryParse([string]$p.TotalBytesToDownload,
                        [System.Globalization.NumberStyles]::Float,
                        [System.Globalization.CultureInfo]::InvariantCulture,[ref]$total)
                    if ($bytesReported -and $totalReported -and $total -gt 0 -and $downloaded -ge 0 -and $downloaded -le $total) {
                        $status = ('{0} {1} / {2} ({3}%)' -f $itemLabel,(Format-WuaBytes $downloaded),(Format-WuaBytes $total),$percent)
                        if ($elapsed -ge 10 -and $downloaded -gt 0 -and $total -gt $downloaded) {
                            $etaSeconds = ($total - $downloaded) * $elapsed / $downloaded
                        }
                    } else {
                        $status = ('{0} {1}% (byte totals unavailable/inconsistent)' -f $itemLabel,$percent)
                    }
                } else {
                    $status = ('{0} {1}% installed (current update: {2}%)' -f $itemLabel,$percent,[int]$p.CurrentUpdatePercentComplete)
                }

                if ($percent -gt $lastPercent -or $downloaded -gt $lastBytes -or $index -ne $lastIndex) {
                    $lastMoved = $now
                    $lastPercent = $percent
                    $lastBytes = $downloaded
                    $lastIndex = $index
                }
                if ($etaSeconds -lt 0 -and $elapsed -ge 20 -and $percent -ge 5 -and $percent -lt 100) {
                    $etaSeconds = $elapsed * (100 - $percent) / $percent
                }
            }
            catch {
                $status = 'Progress snapshot unavailable. Checking Windows Update job status.'
            }

            if ($percent -ge 100) {
                # 100% means bytes/progress were reported; completion still requires IsCompleted.
                if ($null -eq $fullSince) { $fullSince = $now }
                $etaSeconds = -1.0
                $status += ' | 100% reported, waiting for Windows Update to finalize'
            } else { $fullSince = $null }

            if ($Stage -eq 'Download') {
                $timeoutReason = ''
                if ($null -ne $fullSince -and ($now - $fullSince).TotalSeconds -ge 60) {
                    $timeoutReason = 'Download stayed at 100% for 60 seconds without completion.'
                } elseif (($now - $lastMoved).TotalSeconds -ge 180) {
                    $timeoutReason = 'Download progress has not advanced for 3 minutes.'
                }
                if ($timeoutReason) {
                    Write-Warning ($timeoutReason + ' Requesting safe abort; no updates will be installed by this pass.')
                    $abortRequested = $true
                    try { $job.RequestAbort() }
                    catch { Write-Warning ('Abort request failed: ' + $_.Exception.Message) }
                    for ($wait = 0; $wait -lt 10; $wait++) {
                        if ($job.IsCompleted) { break }
                        Start-Sleep -Seconds 1
                    }
                    throw ($timeoutReason + ' Use Settings > Windows Update to retry or continue later.')
                }
            } elseif ($null -ne $fullSince -and ($now - $fullSince).TotalSeconds -ge 300 -and ($now - $lastWarning).TotalSeconds -ge 60) {
                # Never automatically abort a possibly in-progress OS update installation.
                Write-Warning 'Install reports 100% but is still finalizing. Do not force shutdown while installing.'
                $lastWarning = $now
            }

            $etaText = Format-WuaEta $etaSeconds
            Write-Progress -Activity $activity -Status ($status + ' | ETA: ' + $etaText) -PercentComplete $percent -SecondsRemaining ([int]$etaSeconds)
            if (($now - $lastPrinted).TotalSeconds -ge 20 -or ($percent -ge ($lastReportedPercent + 10))) {
                Write-Host ('[{0}] {1} | ETA: {2}' -f $Stage.ToUpperInvariant(),$status,$etaText)
                $lastPrinted = $now
                $lastReportedPercent = $percent
            }
            Start-Sleep -Seconds 3
        }

        if ($Stage -eq 'Download') { $result = $Worker.EndDownload($job) }
        else { $result = $Worker.EndInstall($job) }
        Write-Host ('{0} finished. Windows Update result code: {1}.' -f $Stage,$result.ResultCode) -ForegroundColor Green
        return $result
    }
    finally {
        Write-Progress -Activity $activity -Completed
        if ($null -ne $job) {
            try {
                if ($job.IsCompleted) {
                    $job.CleanUp() # Safe only when completed; otherwise this call waits indefinitely.
                } elseif ($abortRequested) {
                    Write-Warning 'Windows Update abort still pending. Skipping blocking cleanup; close PowerShell after P1 finishes.'
                } else {
                    $job.RequestAbort()
                    Write-Warning 'Requested Windows Update abort; no blocking cleanup while job remains active.'
                }
            }
            catch { Write-Warning ('Could not clean up Windows Update job: ' + $_.Exception.Message) }
        }
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

    if ($QuickFix) {
        Write-Host 'QUICK FIX: Thai clock/date and Windows 11 light Bloom theme only.' -ForegroundColor Cyan
        Step 'Thai calendar and grave-accent switch' { Set-ThailandProfile }
        Step 'Thailand time zone and clock synchronization' { Set-ThailandClock }
        Step 'Windows 11 light theme and Bloom wallpaper' { Set-Windows11LightBloomTheme }
        foreach ($problem in $script:Problems) { Write-Warning ('FAILED: ' + $problem) }
        if ($script:Problems.Count -eq 0) { Write-Host 'Quick fix complete. No updates, downloads, or application installs were started.' -ForegroundColor Green }
        Write-Host 'Sign out and back in if the theme has not fully changed. No restart command was issued.'
        return
    }

    Step 'Check Windows profile name (User)' { Check-ExpectedWindowsProfile }
    if (-not $SkipPrograms) { Step 'Existing USB programs and Office (p.ps1)' { Run-ExistingPrograms } }
    Step 'Thai calendar and grave-accent switch' { Set-ThailandProfile }
    Step 'Thailand time zone and clock synchronization' { Set-ThailandClock }
    Step 'Windows desktop icons' { Set-DesktopIcons }
    Step 'Windows 11 light theme and Bloom wallpaper' { Set-Windows11LightBloomTheme }
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
