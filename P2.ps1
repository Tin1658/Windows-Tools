#Requires -Version 5.1
<#
P2.ps1 - Battery health only.
Shows one battery health percentage (full charge capacity / design capacity).
Does not show current battery charge, run other device tests, or create a report.
Read-only. No installation, reboot, or data upload.
Compatible with: irm .../P2.ps1 | iex
#>

$ErrorActionPreference = 'Stop'
$health = $null

# Prefer firmware-reported design and full-charge capacities.
try {
    $designs = @(Get-CimInstance -Namespace 'root/wmi' -ClassName 'BatteryStaticData' -ErrorAction Stop)
    $fulls = @(Get-CimInstance -Namespace 'root/wmi' -ClassName 'BatteryFullChargedCapacity' -ErrorAction Stop)

    foreach ($battery in $designs) {
        $match = @($fulls | Where-Object { $_.InstanceName -eq $battery.InstanceName } | Select-Object -First 1)
        if ($match.Count -eq 0) { continue }
        $designCapacity = [double]$battery.DesignedCapacity
        $fullCapacity = [double]$match[0].FullChargedCapacity
        if ($designCapacity -gt 0 -and $fullCapacity -gt 0) {
            $health = [math]::Round(100.0 * $fullCapacity / $designCapacity, 1)
            break
        }
    }
}
catch {
    # Some notebooks do not expose battery capacity through WMI.
}

# If WMI lacks capacity readings, use a temporary XML battery report instead.
if ($null -eq $health) {
    $xmlFile = Join-Path $env:TEMP ('WindowsTools-Battery-' + [guid]::NewGuid().ToString('N') + '.xml')
    try {
        & powercfg.exe /batteryreport /xml /output $xmlFile 2>$null | Out-Null
        if ($LASTEXITCODE -eq 0 -and (Test-Path -LiteralPath $xmlFile)) {
            $xmlText = Get-Content -LiteralPath $xmlFile -Raw -ErrorAction Stop
            $designMatch = [regex]::Match($xmlText, '<(?:\w+:)?DesignCapacity>\s*(\d+)\s*</(?:\w+:)?DesignCapacity>')
            $fullMatch = [regex]::Match($xmlText, '<(?:\w+:)?FullChargeCapacity>\s*(\d+)\s*</(?:\w+:)?FullChargeCapacity>')
            if ($designMatch.Success -and $fullMatch.Success) {
                $designCapacity = [double]$designMatch.Groups[1].Value
                $fullCapacity = [double]$fullMatch.Groups[1].Value
                if ($designCapacity -gt 0 -and $fullCapacity -gt 0) {
                    $health = [math]::Round(100.0 * $fullCapacity / $designCapacity, 1)
                }
            }
        }
    }
    catch {
        # Leave health unknown rather than displaying an incorrect percentage.
    }
    finally {
        Remove-Item -LiteralPath $xmlFile -Force -ErrorAction SilentlyContinue
    }
}

if ($null -ne $health) {
    Write-Host ('Battery health: {0:0.0}%' -f $health)
} else {
    Write-Host 'Battery health: Unavailable'
}
