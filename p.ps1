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

function Install-SelectedApp([string]$ProgramsFolder, [string]$Label, [string]$FilenameRegex, [string]$Arguments, [bool]$Interactive = $false) {
    $found = @(Get-ChildItem -LiteralPath $ProgramsFolder -File -ErrorAction Stop |
        Where-Object { $_.Name -match $FilenameRegex } |
        Sort-Object Name -Descending)

    if ($found.Count -eq 0) {
        Write-Warning ("SKIPPED: " + $Label + " - setup file not found on this USB.")
        return
    }

    $file = $found[0]
    Say ("Installing: " + $Label + " [" + $file.Name + "]")

    try {
        if ($Interactive) {
            Write-Host 'LINE: choose Thai (ภาษาไทย) in the installer, then complete the installation.' -ForegroundColor Yellow
            $process = Start-Process -FilePath $file.FullName -PassThru -Wait -ErrorAction Stop
        }
        else {
            $process = Start-Process -FilePath $file.FullName -ArgumentList $Arguments -PassThru -Wait -ErrorAction Stop
        }

        if ($process.ExitCode -in @(0, 3010, 1641)) {
            Say ("Installer finished: " + $Label + " (exit code " + $process.ExitCode + ").")
        }
        else {
            Write-Warning ("Installer returned code " + $process.ExitCode + ": " + $Label + ". Check installation manually.")
        }
    }
    catch {
        Write-Warning ("FAILED: " + $Label + " - " + $_.Exception.Message)
    }
}

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
    Install-SelectedApp $programs 'LINE PC (Thai)' '^LineInst.*\.exe$' '' $true

    Say 'Completed all selected setup steps. Check any warnings above, then restart Windows if needed.'
}
catch {
    Write-Host ("STOPPED: " + $_.Exception.Message) -ForegroundColor Red
}
