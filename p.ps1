# Programs installer from a USB flash drive.
# Run in Windows PowerShell 5.1 as Administrator.
# Only the specifically named installers below will be launched.
# Font folder is mandatory and installed before any application.

$ErrorActionPreference = 'Stop'

function Say([string]$Message) {
    Write-Host ("[Windows-Tools] " + $Message) -ForegroundColor Cyan
}

function Find-UsbPrograms {
    $roots = New-Object 'System.Collections.Generic.List[string]'
    $physicalDisks = @(Get-CimInstance Win32_DiskDrive -ErrorAction Stop |
        Where-Object { $_.InterfaceType -eq 'USB' -or $_.PNPDeviceID -like 'USB*' })

    foreach ($disk in $physicalDisks) {
        $partitions = @(Get-CimAssociatedInstance -InputObject $disk -Association Win32_DiskDriveToDiskPartition -ErrorAction SilentlyContinue)
        foreach ($part in $partitions) {
            $volumes = @(Get-CimAssociatedInstance -InputObject $part -Association Win32_LogicalDiskToPartition -ErrorAction SilentlyContinue)
            foreach ($volume in $volumes) {
                if ($volume.DeviceID) { $roots.Add(($volume.DeviceID + '\')) }
            }
        }
    }

    # Some USB flash drives are reported as removable rather than as USB disk interfaces.
    foreach ($drive in @(Get-CimInstance Win32_LogicalDisk -Filter 'DriveType=2' -ErrorAction SilentlyContinue)) {
        if ($drive.DeviceID) { $roots.Add(($drive.DeviceID + '\')) }
    }

    $usbRoots = @($roots | Sort-Object -Unique)
    if ($usbRoots.Count -eq 0) {
        throw 'No USB flash drive was found. Connect your USB flash drive first.'
    }

    # Scan every folder level on the USB drive, not just its root.
    # Prefer a Programs folder that contains the required Thai font directory.
    $candidatePaths = New-Object 'System.Collections.Generic.List[string]'
    foreach ($root in $usbRoots) {
        Say ("Searching all folders on USB: " + $root)
        $direct = Join-Path $root 'Programs'
        if (Test-Path -LiteralPath $direct -PathType Container) {
            $candidatePaths.Add($direct)
        }
        $matches = @(Get-ChildItem -LiteralPath $root -Directory -Filter 'Programs' -Recurse -Force -ErrorAction SilentlyContinue)
        foreach ($match in $matches) {
            $candidatePaths.Add($match.FullName)
        }
    }

    foreach ($candidate in @($candidatePaths | Select-Object -Unique)) {
        $fontFolder = Join-Path $candidate 'Font พร้อมใช้'
        if (Test-Path -LiteralPath $fontFolder -PathType Container) {
            Say ("USB Programs folder found: " + $candidate)
            return $candidate
        }
    }

    if ($candidatePaths.Count -gt 0) {
        throw 'Found Programs on a USB drive, but no Programs folder contains the required Font folder. Nothing was installed.'
    }
    throw 'No Programs folder was found anywhere on a USB flash drive. Nothing was installed.'
}

function Install-FontsFirst([string]$ProgramsFolder) {
    $source = Join-Path $ProgramsFolder 'Font พร้อมใช้'
    if (-not (Test-Path -LiteralPath $source -PathType Container)) {
        throw 'Missing required Font folder (Font ready-to-use). Stopping before installing applications.'
    }

    $fonts = @(Get-ChildItem -LiteralPath $source -File -Recurse -ErrorAction Stop |
        Where-Object { $_.Extension -in @('.ttf', '.otf', '.ttc') })
    if ($fonts.Count -eq 0) { throw 'The Font folder contains no TTF, OTF, or TTC files. Stopping.' }

    $registryPath = 'HKLM:\SOFTWARE\Microsoft\Windows NT\CurrentVersion\Fonts'
    $fontDirectory = Join-Path $env:WINDIR 'Fonts'
    $existing = @((Get-ItemProperty -Path $registryPath).PSObject.Properties |
        Where-Object { $_.Name -notlike 'PS*' } |
        ForEach-Object { [string]$_.Value })
    $added = 0
    Say ("Installing/checking " + $fonts.Count + " fonts FIRST...")

    foreach ($font in $fonts) {
        $destination = Join-Path $fontDirectory $font.Name
        if (-not (Test-Path -LiteralPath $destination)) {
            Copy-Item -LiteralPath $font.FullName -Destination $destination -ErrorAction Stop
            $added++
        }
        if ($existing -notcontains $font.Name) {
            $type = if ($font.Extension -eq '.otf') { 'OpenType' } else { 'TrueType' }
            $valueName = $font.BaseName + ' (' + $type + ')'
            New-ItemProperty -Path $registryPath -Name $valueName -Value $font.Name -PropertyType String -Force -ErrorAction Stop | Out-Null
            $existing += $font.Name
        }
    }
    Say ("Fonts completed. New font files: " + $added + ". A reboot may be needed for some applications to detect them.")
}


# Query standard uninstall entries instead of Win32_Product (which can initiate repairs).
function Test-AppInstalled([string]$Label) {
    $patterns = @{
        'Adobe Acrobat Reader' = '^Adobe (?:Acrobat )?Reader(?:\s|$|[\(])|^Adobe Acrobat Reader'
        'AIMP'                = '^AIMP(?:\s|$)'
        'UltraViewer'         = '^UltraViewer(?:\s|$)'
        'VLC media player'    = '^VLC media player(?:\s|$)'
        'WinRAR (English)'    = '^WinRAR(?:\s|$)'
        'Google Chrome'      = '^Google Chrome(?:\s|$)'
        'Zoom'               = '^Zoom(?:\s|$|[\(])|^Zoom Workplace'
        'LINE PC (Thai)'     = '^LINE(?:\s|$|[\(])'
    }
    $pattern = $patterns[$Label]
    if (-not $pattern) { return $false }

    $paths = @(
        'HKLM:\SOFTWARE\Microsoft\Windows\CurrentVersion\Uninstall\*',
        'HKLM:\SOFTWARE\WOW6432Node\Microsoft\Windows\CurrentVersion\Uninstall\*',
        'HKCU:\SOFTWARE\Microsoft\Windows\CurrentVersion\Uninstall\*',
        'HKCU:\SOFTWARE\WOW6432Node\Microsoft\Windows\CurrentVersion\Uninstall\*'
    )
    $entries = @(Get-ItemProperty -Path $paths -ErrorAction SilentlyContinue |
        Where-Object { $_.DisplayName -and $_.DisplayName -match $pattern })
    if ($entries.Count -gt 0) { return $true }

    # Fallback for apps without an Uninstall registry entry.
    $pf86 = [Environment]::GetFolderPath('ProgramFilesX86')
    $possibleFiles = switch ($Label) {
        'AIMP'             { @("$env:ProgramFiles\AIMP\AIMP.exe", "$pf86\AIMP\AIMP.exe") }
        'UltraViewer'      { @("$env:ProgramFiles\UltraViewer\UltraViewer_Desktop.exe", "$pf86\UltraViewer\UltraViewer_Desktop.exe") }
        'VLC media player' { @("$env:ProgramFiles\VideoLAN\VLC\vlc.exe", "$pf86\VideoLAN\VLC\vlc.exe") }
        'WinRAR (English)' { @("$env:ProgramFiles\WinRAR\WinRAR.exe", "$pf86\WinRAR\WinRAR.exe") }
        'Google Chrome'   { @("$env:ProgramFiles\Google\Chrome\Application\chrome.exe", "$pf86\Google\Chrome\Application\chrome.exe", "$env:LOCALAPPDATA\Google\Chrome\Application\chrome.exe") }
        'Zoom'            { @("$env:APPDATA\Zoom\bin\Zoom.exe", "$env:LOCALAPPDATA\Zoom\bin\Zoom.exe", "$env:ProgramFiles\Zoom\bin\Zoom.exe") }
        'LINE PC (Thai)'  { @("$env:LOCALAPPDATA\LINE\bin\LineLauncher.exe", "$env:LOCALAPPDATA\LINE\bin\LINE.exe", "$env:LOCALAPPDATA\Programs\LINE\LINE.exe") }
        default           { @() }
    }
    foreach ($file in @($possibleFiles)) {
        if ($file -and (Test-Path -LiteralPath $file -PathType Leaf)) { return $true }
    }
    return $false
}

function Test-Office2024Installed {
    $config = Get-ItemProperty -Path 'HKLM:\SOFTWARE\Microsoft\Office\ClickToRun\Configuration' -ErrorAction SilentlyContinue
    if (-not $config -or -not $config.ProductReleaseIds) { return $false }
    return (([string]$config.ProductReleaseIds -split ',') -contains 'HomeBusiness2024Retail')
}

function Install-SelectedApp([string]$ProgramsFolder, [string]$Label, [string]$FilenameRegex, [string]$Arguments) {
    if (Test-AppInstalled -Label $Label) {
        Say ("ALREADY INSTALLED - SKIP: " + $Label)
        return
    }
    $found = @(Get-ChildItem -LiteralPath $ProgramsFolder -File -ErrorAction Stop |
        Where-Object { $_.Name -match $FilenameRegex } |
        Sort-Object Name -Descending)
    if ($found.Count -eq 0) {
        Write-Warning ("SKIPPED: " + $Label + " - installer not found on USB.")
        return
    }
    $file = $found[0]
    Say ("Installing: " + $Label + " [" + $file.Name + "]")
    try {
        $process = Start-Process -FilePath $file.FullName -ArgumentList $Arguments -PassThru -Wait -ErrorAction Stop
        if ($process.ExitCode -notin @(0, 3010, 1641)) {
            Write-Warning ("Installer reported exit code " + $process.ExitCode + " for " + $Label)
            return
        }
        if (Test-AppInstalled -Label $Label) {
            Say ("VERIFIED INSTALLED: " + $Label)
        }
        else {
            Write-Warning ("Installer exited successfully, but installation is not yet verified: " + $Label)
        }
    }
    catch {
        Write-Warning ("FAILED: " + $Label + " - " + $_.Exception.Message)
    }
}

function Install-Line([string]$ProgramsFolder) {
    $label = 'LINE PC (Thai)'
    if (Test-AppInstalled $label) {
        Say 'ALREADY INSTALLED - SKIP: LINE'
        Write-Host 'To change the LINE language: Settings > Basic > Language > Thai.' -ForegroundColor Yellow
        return
    }

    $setups = @(Get-ChildItem -LiteralPath $ProgramsFolder -File -ErrorAction Stop |
        Where-Object { $_.Name -match '^LineInst.*\.exe$' } |
        Sort-Object Name -Descending)
    if ($setups.Count -eq 0) {
        Write-Warning 'SKIPPED LINE: LineInst.exe was not found in Programs.'
        return
    }

    # WinGet can accept installer terms and install silently without UI clicks.
    # If unavailable, fall back to the existing local USB installer.
    $winget = Get-Command winget.exe -ErrorAction SilentlyContinue
    if ($winget) {
        Say 'Installing LINE using WinGet (silent; internet required)...'
        try {
            & $winget.Source install --id LINE.LINE --exact --source winget --silent --no-upgrade --accept-package-agreements --accept-source-agreements | Out-Host
            $wingetExit = $LASTEXITCODE
            if ($wingetExit -eq 0 -and (Test-AppInstalled $label)) {
                Say 'VERIFIED INSTALLED: LINE'
                Write-Host 'LINE language: Settings > Basic > Language > Thai; restart LINE if requested.' -ForegroundColor Yellow
                return
            }
            Write-Warning ("WinGet installation not verified (exit code " + $wingetExit + "); using USB instead.")
        }
        catch { Write-Warning ("WinGet failed: " + $_.Exception.Message) }
    }

    Say ("Opening LINE installer from USB: " + $setups[0].Name)
    Write-Host 'Tick the LINE terms checkbox and click Install.' -ForegroundColor Yellow
    Write-Host 'Press S in this PowerShell window to SKIP LINE and continue to Office.' -ForegroundColor Yellow
    Write-Host 'Then set LINE: Settings > Basic > Language > Thai (ภาษาไทย).' -ForegroundColor Yellow
    try { $null = Start-Process -FilePath $setups[0].FullName -PassThru -ErrorAction Stop }
    catch { Write-Warning ("Could not start LINE installer: " + $_.Exception.Message); return }

    # Never wait forever for LINE's installer/launcher process tree to close.
    $deadline = (Get-Date).AddMinutes(6)
    while ((Get-Date) -lt $deadline) {
        if (Test-AppInstalled $label) {
            Say 'VERIFIED INSTALLED: LINE'
            Write-Host 'Set LINE language to Thai in LINE Settings if needed.' -ForegroundColor Yellow
            return
        }
        try {
            if ($Host.UI.RawUI.KeyAvailable) {
                $key = $Host.UI.RawUI.ReadKey('NoEcho,IncludeKeyDown')
                if ($key.Character -eq 's' -or $key.Character -eq 'S') {
                    Write-Warning 'LINE skipped by user. Continuing to Office.'
                    return
                }
            }
        }
        catch { }
        Start-Sleep -Seconds 3
    }
    Write-Warning 'LINE not verified within 6 minutes. Continuing to Office.'
}

function Install-OfficeLast([string]$ProgramsFolder) {
    if (Test-Office2024Installed) {
        Say 'ALREADY INSTALLED - SKIP: Office Home and Business 2024'
        return $true
    }

    # Office Tool Plus is a portable application. Locate its console executable
    # inside the USB's Programs\Office Tool directory without running arbitrary EXEs.
    $toolFolder = Join-Path $ProgramsFolder 'Office Tool'
    if (-not (Test-Path -LiteralPath $toolFolder -PathType Container)) {
        $folders = @(Get-ChildItem -LiteralPath $ProgramsFolder -Directory -Recurse -ErrorAction SilentlyContinue |
            Where-Object { $_.Name -eq 'Office Tool' })
        if ($folders.Count -gt 0) { $toolFolder = $folders[0].FullName }
    }

    if (-not (Test-Path -LiteralPath $toolFolder -PathType Container)) {
        Write-Warning "SKIPPED Office: USB Programs\Office Tool folder was not found."
        return $false
    }

    $console = @(Get-ChildItem -LiteralPath $toolFolder -File -Filter 'Office Tool Plus.Console.exe' -Recurse -ErrorAction SilentlyContinue |
        Select-Object -First 1)
    if ($console.Count -eq 0) {
        Write-Warning 'SKIPPED Office: Office Tool Plus.Console.exe was not found. Extract Office Tool Plus (with runtime) inside Office Tool first.'
        return $false
    }

    # Preserve any existing Office installation: do not uninstall, activate, or alter licenses.
    # Home & Business 2024 Retail includes the selected six apps in the screenshot:
    # Word, Excel, PowerPoint, Outlook (classic), OneNote, and OneDrive.
    # Language: Thai (th-th); architecture: 64-bit; Retail update channel: default.
    Say 'FINAL STEP: Deploy Office Home and Business 2024 (64-bit, Thai).'
    Write-Host 'Office Tool Plus will download Office first and then install it. Internet may be required.' -ForegroundColor Yellow
    Write-Host 'A valid Office Home and Business 2024 license is required to activate Office.' -ForegroundColor Yellow
    $officeExe = $console[0].FullName
    Push-Location -LiteralPath $console[0].DirectoryName
    try {
        & $officeExe deploy /add HomeBusiness2024Retail_th-th /edition 64 /display true /enableupdates true /dlfirst | Out-Host
        $officeExit = $LASTEXITCODE
        if ($officeExit -ne 0) {
            Write-Warning ("Office deployment returned exit code " + $officeExit + ". Check Office Tool Plus logs.")
            return $false
        }
        else {
            Say 'Office Tool Plus deployment command completed. Verify Office apps and activation.'
            return $true
        }
    }
    catch {
        Write-Warning ("Office deployment failed: " + $_.Exception.Message)
        return $false
    }
    finally {
        Pop-Location
    }
}

# Best-effort, read-only Windows UI Automation snapshot.
# Returns text exposed by the window's accessible controls; some terminals
# and console windows do not expose their screen buffer through UI Automation.

try {
    $admin = ([Security.Principal.WindowsPrincipal] [Security.Principal.WindowsIdentity]::GetCurrent()).IsInRole(
        [Security.Principal.WindowsBuiltInRole]::Administrator)
    if (-not $admin) { throw 'Open Windows PowerShell as Administrator and try again.' }

    $programs = Find-UsbPrograms
    Install-FontsFirst -ProgramsFolder $programs

    # Only approved installers from the Programs folder.
    Install-SelectedApp $programs 'Adobe Acrobat Reader' '^AcroRdrDC.*_en_US\.exe$' '/sAll /rs /msi EULA_ACCEPT=YES'
    Install-SelectedApp $programs 'AIMP' '^aimp_[0-9.]+_w64\.exe$' '/AUTO /SILENT'
    Install-SelectedApp $programs 'UltraViewer' '^UltraViewer_setup_[0-9.]+_en\.exe$' '/VERYSILENT /SUPPRESSMSGBOXES /NORESTART'
    Install-SelectedApp $programs 'VLC media player' '^vlc-[0-9.]+-win64\.exe$' '/S'
    Install-SelectedApp $programs 'WinRAR (English)' '^winrar-x64-[0-9]+\.exe$' '-s1'
    Install-SelectedApp $programs 'Google Chrome' '^ChromeSetup.*\.exe$' '/silent /install'
    Install-SelectedApp $programs 'Zoom' '^ZoomInstaller.*\.exe$' '/silent'
    Install-Line -ProgramsFolder $programs

    $officeInstalled = Install-OfficeLast -ProgramsFolder $programs
    if (-not $officeInstalled) {
        Write-Warning 'Office installation was not confirmed. Review its status manually.'
    }

    Say 'Completed all selected setup steps. Check any warnings above, then restart Windows if needed.'
}
catch {
    Write-Host ("STOPPED: " + $_.Exception.Message) -ForegroundColor Red
}
