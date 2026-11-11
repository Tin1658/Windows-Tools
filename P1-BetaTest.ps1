# P1-BetaTest.ps1
# Read-only checklist for the current Windows account, intended for Windows PowerShell 5.1.
# Run after P1. This does not install programs, reboot, or rename the Windows profile.
$ErrorActionPreference = 'Continue'
$results = New-Object 'System.Collections.Generic.List[object]'
$desktop = [Environment]::GetFolderPath('Desktop')
$reportPath = Join-Path $desktop ('P1-BetaTest-' + (Get-Date -Format 'yyyyMMdd-HHmmss') + '.txt')

function Check([string]$Item,[string]$Status,[string]$Details) {
    $obj = [PSCustomObject]@{Check=$Item; Status=$Status; Details=$Details}
    $results.Add($obj)
    $color = if($Status -eq 'PASS') {'Green'} elseif($Status -eq 'FAIL') {'Red'} else {'Yellow'}
    Write-Host ('[{0}] {1}: {2}' -f $Status,$Item,$Details) -ForegroundColor $color
}
function RegValue([string]$Path,[string]$Name) {
    try { return [string](Get-ItemProperty -LiteralPath $Path -Name $Name -ErrorAction Stop).$Name }
    catch { return '' }
}
function UserChoice([string]$Ext) {
    return (RegValue ('HKCU:\Software\Microsoft\Windows\CurrentVersion\Explorer\FileExts\' + $Ext + '\UserChoice') 'ProgId')
}

Write-Host '======== P1 BETA TEST: READ ONLY ========' -ForegroundColor Cyan
Check 'Account name' $(if([Environment]::UserName -ceq 'User'){'PASS'}else{'FAIL'}) ('Expected User; current: ' + [Environment]::UserName)

$culture = (Get-Culture).Name
Check 'Regional format' $(if($culture -eq 'th-TH'){'PASS'}else{'FAIL'}) ('Expected th-TH; current: ' + $culture)
$intl = 'HKCU:\Control Panel\International'
$cal = RegValue $intl 'iCalendarType'
$dateFmt = RegValue $intl 'sShortDate'
Check 'Buddhist calendar' $(if($cal -eq '7'){'PASS'}else{'WARN'}) ('Calendar registry code: ' + $cal)
Check 'Short date dd/MM/yyyy' $(if($dateFmt -eq 'dd/MM/yyyy'){'PASS'}else{'WARN'}) ('Current: ' + $dateFmt)
$toggle = RegValue 'HKCU:\Keyboard Layout\Toggle' 'Hotkey'
Check 'Grave-accent language switch' $(if($toggle -eq '4'){'PASS'}else{'WARN'}) ('Registry code: ' + $toggle + '; test the actual key after sign-out')

$icons = @(
    '{20D04FE0-3AEA-1069-A2D8-08002B30309D}',
    '{F02C1A0D-BE21-4350-88B0-7367FC96EF3C}',
    '{5399E694-6CE5-4D6C-8FCE-1D8870FDCBA0}',
    '{59031a47-3f72-44a7-89c5-5595fe6b30ee}',
    '{645FF040-5081-101B-9F08-00AA002F954E}'
)
$key = 'HKCU:\Software\Microsoft\Windows\CurrentVersion\Explorer\HideDesktopIcons\NewStartPanel'
$hidden = @($icons | Where-Object { (RegValue $key $_) -ne '0' })
Check 'Desktop system icons' $(if($hidden.Count -eq 0){'PASS'}else{'WARN'}) ('Enabled of 5: ' + (5 - $hidden.Count))

foreach($app in @('Word','Excel','PowerPoint')) {
    $shortcut = Join-Path $desktop ($app + '.lnk')
    if (Test-Path -LiteralPath $shortcut) {
        try {
            $target = (New-Object -ComObject WScript.Shell).CreateShortcut($shortcut).TargetPath
            Check ($app + ' shortcut') $(if(Test-Path -LiteralPath $target){'PASS'}else{'WARN'}) $target
        } catch { Check ($app + ' shortcut') 'WARN' 'Shortcut exists but could not validate target.' }
    }
    else { Check ($app + ' shortcut') 'FAIL' 'Shortcut missing from Desktop.' }
}

$wallpaper = RegValue 'HKCU:\Control Panel\Desktop' 'WallPaper'
$wallpaperMode = RegValue 'HKCU:\Software\Microsoft\Windows\CurrentVersion\Explorer\Wallpapers' 'BackgroundType'
Check 'Static wallpaper' $(if($wallpaperMode -eq '0' -and (Test-Path -LiteralPath $wallpaper)){'PASS'}else{'WARN'}) ('Type: ' + $wallpaperMode + '; image: ' + $wallpaper)

$pdf = UserChoice '.pdf'
$rar = UserChoice '.rar'
Check '.pdf default app' $(if($pdf -match 'Acro|Adobe'){'PASS'}else{'WARN'}) ('Current ProgID: ' + $pdf)
Check '.rar default app' $(if($rar -like 'WinRAR*'){'PASS'}else{'WARN'}) ('Current ProgID: ' + $rar)
Check '.png default app' 'SKIP' 'Intentionally untouched by P1.'

try {
    $manufacturer = [string](Get-CimInstance Win32_ComputerSystem -ErrorAction Stop).Manufacturer
    if($manufacturer -match 'ASUS|ASUSTeK') {
        $myasus = @(Get-AppxPackage -Name 'B9ECED6F.ASUSPCAssistant' -ErrorAction SilentlyContinue)
        Check 'MyASUS app installed' $(if($myasus.Count -gt 0){'PASS'}else{'FAIL'}) ('Packages: ' + $myasus.Count)
        $interface = @(Get-CimInstance Win32_PnPEntity -ErrorAction SilentlyContinue |
            Where-Object { $_.Name -match 'ASUS System Control Interface' -and $_.ConfigManagerErrorCode -eq 0 })
        Check 'ASUS System Control Interface' $(if($interface.Count){'PASS'}else{'WARN'}) ('Detected devices: ' + $interface.Count)
        Check 'MyASUS System Update completed' 'MANUAL' 'Open MyASUS > System Update > Update History; photograph screen if you want me to diagnose remaining drivers.'
    } else {
        Check 'MyASUS app' 'SKIP' ('Non-ASUS manufacturer: ' + $manufacturer)
    }
}
catch { Check 'ASUS hardware check' 'WARN' $_.Exception.Message }

$log = Join-Path $desktop 'P1-Setup.log'
Check 'P1 setup log' $(if(Test-Path -LiteralPath $log){'PASS'}else{'WARN'}) $log
Check 'Windows Update / driver status' 'MANUAL' 'Read the P1-Setup.log for pending or failed updates. Run P1 again after manually restarting if needed.'
Check 'Restart policy' 'PASS' 'P1 has no automatic reboot command. Restart manually when ready.'

Write-Host ''
Write-Host '======== RESULTS ========' -ForegroundColor Cyan
$results | Group-Object Status | Sort-Object Name | ForEach-Object {
    Write-Host ($_.Name + ': ' + $_.Count)
}

try {
    $lines = @('P1 BetaTest / ' + (Get-Date -Format 'yyyy-MM-dd HH:mm:ss')) + @(
        $results | ForEach-Object { '[{0}] {1}: {2}' -f $_.Status,$_.Check,$_.Details }
    )
    [System.IO.File]::WriteAllLines($reportPath,[string[]]$lines,[System.Text.Encoding]::UTF8)
    Write-Host ('Report saved: ' + $reportPath) -ForegroundColor Green
} catch {
    Write-Warning ('Could not save beta-test report: ' + $_.Exception.Message)
}
