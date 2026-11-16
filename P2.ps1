#Requires -Version 5.1
<#
P2.ps1 - Notebook diagnostic assistant.
Read-only hardware discovery plus optional human tests.
Run in Windows PowerShell. No installation, reboot or data upload.
#>
# Inline-compatible script: no top-level param block for Invoke-Expression.
$Quick = $false

$ErrorActionPreference = 'Stop'
$script:Lines = New-Object 'System.Collections.Generic.List[string]'
$desktop = [Environment]::GetFolderPath('Desktop')
$stamp = Get-Date -Format 'yyyyMMdd-HHmmss'
$reportPath = Join-Path $desktop ("P2-Diagnostic-" + $stamp + ".txt")

function Report([string]$Title, [string]$Value) {
    $line = ('{0}: {1}' -f $Title, $Value)
    Write-Host $line
    $script:Lines.Add($line)
}
function Try-GetCim([string]$ClassName, [string]$Namespace = 'root/cimv2') {
    try { @(Get-CimInstance -Namespace $Namespace -ClassName $ClassName -ErrorAction Stop) }
    catch { @() }
}
function Test-Manual([string]$Prompt) {
    if ($Quick) { return 'SKIPPED (-Quick)' }
    $answer = Read-Host ($Prompt + ' [Y=yes / N=no / Enter=skip]')
    switch -Regex ($answer) {
        '^(y|yes)$' { return 'PASS (user confirmed)' }
        '^(n|no)$' { return 'FAIL (user reported)' }
        default { return 'NOT TESTED' }
    }
}

function Show-ColorTest {
    try {
        Add-Type -AssemblyName System.Windows.Forms
        Add-Type -AssemblyName System.Drawing
        $palette = @(
            @{Name='RED';   Color=[System.Drawing.Color]::Red;   Fore=[System.Drawing.Color]::White},
            @{Name='GREEN'; Color=[System.Drawing.Color]::Green; Fore=[System.Drawing.Color]::Black},
            @{Name='BLUE';  Color=[System.Drawing.Color]::Blue;  Fore=[System.Drawing.Color]::White},
            @{Name='WHITE'; Color=[System.Drawing.Color]::White; Fore=[System.Drawing.Color]::Black},
            @{Name='BLACK'; Color=[System.Drawing.Color]::Black; Fore=[System.Drawing.Color]::White}
        )
        $form = New-Object System.Windows.Forms.Form
        $form.Text = 'P2 - Display color check'
        $form.FormBorderStyle = [System.Windows.Forms.FormBorderStyle]::None
        $form.WindowState = [System.Windows.Forms.FormWindowState]::Maximized
        $form.TopMost = $true
        $form.KeyPreview = $true
        $form.BackColor = $palette[0].Color
        $label = New-Object System.Windows.Forms.Label
        $label.Dock = [System.Windows.Forms.DockStyle]::Top
        $label.Height = 70
        $label.Font = New-Object System.Drawing.Font('Segoe UI',22,[System.Drawing.FontStyle]::Bold)
        $label.TextAlign = [System.Drawing.ContentAlignment]::MiddleCenter
        $label.BackColor = [System.Drawing.Color]::Transparent
        $label.ForeColor = $palette[0].Fore
        $label.Text = 'RED 1/5 - SPACE: next / ESC: exit'
        $form.Controls.Add($label)
        $script:P2ColorIndex = 0
        $onKey = {
            param($sender,$e)
            if ($e.KeyCode -eq [System.Windows.Forms.Keys]::Escape) {
                $sender.Close()
            }
            elseif ($e.KeyCode -eq [System.Windows.Forms.Keys]::Space) {
                $script:P2ColorIndex++
                if ($script:P2ColorIndex -ge $palette.Count) {
                    $sender.Close()
                }
                else {
                    $sender.BackColor = $palette[$script:P2ColorIndex].Color
                    $label.ForeColor = $palette[$script:P2ColorIndex].Fore
                    $label.Text = ('{0} {1}/5 - SPACE: next / ESC: exit' -f $palette[$script:P2ColorIndex].Name, ($script:P2ColorIndex + 1))
                }
                $e.SuppressKeyPress = $true
            }
        }.GetNewClosure()
        $form.Add_KeyDown($onKey)
        [void]$form.ShowDialog()
        $form.Dispose()
    }
    catch { Write-Warning ('Display test could not open: ' + $_.Exception.Message) }
}

try {
    Write-Host '========== P2 NOTEBOOK DIAGNOSTICS ==========' -ForegroundColor Cyan
    Report 'Checked at' (Get-Date -Format 'yyyy-MM-dd HH:mm:ss')
    $pc = @(Try-GetCim 'Win32_ComputerSystem' | Select-Object -First 1)
    $bios = @(Try-GetCim 'Win32_BIOS' | Select-Object -First 1)
    $product = @(Try-GetCim 'Win32_ComputerSystemProduct' | Select-Object -First 1)
    $os = @(Try-GetCim 'Win32_OperatingSystem' | Select-Object -First 1)

    if ($pc.Count -gt 0) {
        Report 'Manufacturer' ([string]$pc[0].Manufacturer)
        Report 'Notebook model' ([string]$pc[0].Model)
        Report 'Memory GB' ([math]::Round($pc[0].TotalPhysicalMemory / 1GB, 1))
    }
    if ($product.Count -gt 0) { Report 'Product version' ([string]$product[0].Version) }
    if ($bios.Count -gt 0) {
        Report 'Serial number' ([string]$bios[0].SerialNumber)
        Report 'BIOS version' ([string]$bios[0].SMBIOSBIOSVersion)
    }
    if ($os.Count -gt 0) { Report 'Windows' ([string]$os[0].Caption + ' ' + [string]$os[0].Version) }

    Write-Host ''
    Write-Host '--- 1. DISPLAY COLORS ---' -ForegroundColor Yellow
    if (-not $Quick) { Show-ColorTest }
    Report 'Display color test' (Test-Manual 'Did all colors look normal, with no lines/stuck pixels?')

    Write-Host ''
    Write-Host '--- 2. MOUSE ---' -ForegroundColor Yellow
    $mice = @()
    try { $mice = @(Get-PnpDevice -Class Mouse -PresentOnly -ErrorAction Stop) } catch {}
    Report 'Windows mouse devices' ($(if($mice.Count){($mice.FriendlyName -join '; ')}else{'none reported'}))
    Report 'Mouse manual check' (Test-Manual 'Move an external mouse and test left/right clicks. OK?')

    Write-Host ''
    Write-Host '--- 3. TOUCHPAD ---' -ForegroundColor Yellow
    $touch = @()
    try {
        $touch = @(Get-PnpDevice -PresentOnly -ErrorAction Stop | Where-Object {
            $_.FriendlyName -match 'Touchpad|Touch Pad|ELAN|Synaptics'
        })
    } catch {}
    Report 'Touchpad candidates' ($(if($touch.Count){($touch.FriendlyName -join '; ')}else{'not identified; does NOT mean broken'}))
    Report 'Touchpad manual check' (Test-Manual 'Use touchpad to move cursor and click. OK?')

    Write-Host ''
    Write-Host '--- 4. KEYBOARD ---' -ForegroundColor Yellow
    $keyboards = @()
    try { $keyboards = @(Get-PnpDevice -Class Keyboard -PresentOnly -ErrorAction Stop) } catch {}
    Report 'Windows keyboards' ($(if($keyboards.Count){($keyboards.FriendlyName -join '; ')}else{'none reported'}))
    if ($Quick) {
        Report 'Keyboard manual check' 'SKIPPED (-Quick)'
    } else {
        $typed = Read-Host 'Type TEST123 using the notebook keyboard, then Enter (blank to skip)'
        $state = if ($typed -ceq 'TEST123') { 'PASS (sample keys only)' }
                 elseif ([string]::IsNullOrWhiteSpace($typed)) { 'NOT TESTED' }
                 else { 'FAIL/INCONCLUSIVE (check layout and keys)' }
        Report 'Keyboard manual check' $state
    }

    Write-Host ''
    Write-Host '--- 5. FAN ---' -ForegroundColor Yellow
    $fans = @(Try-GetCim 'Win32_Fan')
    if ($fans.Count) {
        Report 'Fan firmware entries' ([string]$fans.Count + ' (presence is not proof of function)')
    } else {
        Report 'Fan sensor' 'Unavailable via standard Windows WMI on this machine'
    }
    Report 'Fan manual check' (Test-Manual 'When warm or under load, can you hear/feel airflow and no scraping?')

    Write-Host ''
    Write-Host '--- 6. BATTERY ---' -ForegroundColor Yellow
    $batteries = @(Try-GetCim 'Win32_Battery')
    if ($batteries.Count -gt 0) {
        Report 'Battery detected' 'YES'
        Report 'Battery level %' ([string]$batteries[0].EstimatedChargeRemaining)
        Report 'Battery status code' ([string]$batteries[0].BatteryStatus)
        $batteryHtml = Join-Path $desktop 'P2-Battery-Report.html'
        try {
            & powercfg.exe /batteryreport /output $batteryHtml | Out-Null
            if (Test-Path -LiteralPath $batteryHtml) {
                Report 'Battery report HTML' $batteryHtml
            }
        } catch { Report 'Battery report' ('unavailable: ' + $_.Exception.Message) }

        $batteryXml = Join-Path $env:TEMP 'WindowsTools-P2-Battery.xml'
        try {
            & powercfg.exe /batteryreport /xml /output $batteryXml | Out-Null
            if (Test-Path -LiteralPath $batteryXml) {
                $raw = Get-Content -LiteralPath $batteryXml -Raw
                $designMatch = [regex]::Match($raw,'<DesignCapacity>(\d+)</DesignCapacity>')
                $fullMatch = [regex]::Match($raw,'<FullChargeCapacity>(\d+)</FullChargeCapacity>')
                if ($designMatch.Success -and $fullMatch.Success) {
                    $design = [double]$designMatch.Groups[1].Value
                    $full = [double]$fullMatch.Groups[1].Value
                    if ($design -gt 0) {
                        Report 'Battery health % (capacity estimate)' ([string][math]::Round(($full / $design) * 100, 1))
                    }
                }
            }
        } catch { Report 'Battery capacity estimate' 'Unavailable' }
    } else {
        Report 'Battery detected' 'NO (or not exposed via WMI)'
    }

    Write-Host ''
    Write-Host '--- FINISH ---' -ForegroundColor Green
    Report 'Test limitation' 'Device detection is not a full functional test. Fan RPM often unavailable.'
}
catch {
    Report 'ERROR' $_.Exception.Message
}
finally {
    try {
        $script:Lines | Out-File -LiteralPath $reportPath -Encoding UTF8
        Write-Host ('Report saved: ' + $reportPath) -ForegroundColor Cyan
    } catch { Write-Warning ('Could not save report: ' + $_.Exception.Message) }
}
