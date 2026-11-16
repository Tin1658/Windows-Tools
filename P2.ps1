#Requires -Version 5.1
<#
P2.ps1 - Battery health percentage only.
Read-only; no other device tests, no reboot, no desktop reports.
Battery health = FullChargeCapacity / DesignCapacity * 100.
Compatible with: irm https://raw.githubusercontent.com/Tin1658/Windows-Tools/main/P2.ps1 | iex
#>

function Convert-P2BatteryCapacity($Value) {
    if ($null -eq $Value) { return $null }
    $clean = ([string]$Value) -replace '[^\d]', ''
    if (-not $clean) { return $null }
    $parsed = 0.0
    if ([double]::TryParse($clean, [ref]$parsed) -and $parsed -gt 0) { return $parsed }
    return $null
}

function Get-P2HealthFromXml([string]$Path) {
    try {
        [xml]$doc = Get-Content -LiteralPath $Path -Raw -ErrorAction Stop
        $batteries = @($doc.SelectNodes('//*[local-name()="Battery"]'))
        $totalDesign = 0.0
        $totalFull = 0.0
        foreach ($battery in $batteries) {
            $dNode = $battery.SelectSingleNode('./*[local-name()="DesignCapacity"]')
            $fNode = $battery.SelectSingleNode('./*[local-name()="FullChargeCapacity"]')
            if ($null -eq $dNode -or $null -eq $fNode) { continue }
            $design = Convert-P2BatteryCapacity $dNode.InnerText
            $full = Convert-P2BatteryCapacity $fNode.InnerText
            if ($null -ne $design -and $null -ne $full) {
                $totalDesign += $design
                $totalFull += $full
            }
        }
        if ($totalDesign -gt 0 -and $totalFull -gt 0) {
            return [math]::Round(($totalFull / $totalDesign) * 100.0, 1)
        }
    } catch {}

    # Some versions of powercfg export the capacities in a different XML layout.
    try {
        $raw = Get-Content -LiteralPath $Path -Raw -ErrorAction Stop
        $designMatch = [regex]::Match($raw, '(?is)<(?:\w+:)?DesignCapacity(?:\s+[^>]*)?>\s*([\d,.\s]+)\s*</(?:\w+:)?DesignCapacity>')
        $fullMatch = [regex]::Match($raw, '(?is)<(?:\w+:)?FullChargeCapacity(?:\s+[^>]*)?>\s*([\d,.\s]+)\s*</(?:\w+:)?FullChargeCapacity>')
        if ($designMatch.Success -and $fullMatch.Success) {
            $design = Convert-P2BatteryCapacity $designMatch.Groups[1].Value
            $full = Convert-P2BatteryCapacity $fullMatch.Groups[1].Value
            if ($null -ne $design -and $null -ne $full) {
                return [math]::Round(($full / $design) * 100.0, 1)
            }
        }
    } catch {}
    return $null
}

function Get-P2HealthFromWmi {
    try {
        $designs = @(Get-CimInstance -Namespace 'root/wmi' -ClassName 'BatteryStaticData' -ErrorAction Stop)
        $fulls = @(Get-CimInstance -Namespace 'root/wmi' -ClassName 'BatteryFullChargedCapacity' -ErrorAction Stop)
        $totalDesign = 0.0
        $totalFull = 0.0
        foreach ($battery in $designs) {
            $matches = @($fulls | Where-Object { $_.InstanceName -eq $battery.InstanceName })
            if ($matches.Count -ne 1) { continue }
            $design = Convert-P2BatteryCapacity $battery.DesignedCapacity
            $full = Convert-P2BatteryCapacity $matches[0].FullChargedCapacity
            if ($null -ne $design -and $null -ne $full) {
                $totalDesign += $design
                $totalFull += $full
            }
        }
        if ($totalDesign -gt 0 -and $totalFull -gt 0) {
            return [math]::Round(($totalFull / $totalDesign) * 100.0, 1)
        }
    } catch {}
    return $null
}

function Get-P2HealthFromHtml([string]$Path) {
    try {
        $html = Get-Content -LiteralPath $Path -Raw -ErrorAction Stop
        $plain = [regex]::Replace($html, '(?is)<(script|style)\b[^>]*>.*?</\1>', ' ')
        $plain = [regex]::Replace($plain, '(?s)<[^>]+>', ' ')
        $plain = [System.Net.WebUtility]::HtmlDecode($plain)
        $designMatch = [regex]::Match($plain, '(?i)DESIGN\s+CAPACITY\s+([\d,]+)\s*mWh')
        $fullMatch = [regex]::Match($plain, '(?i)FULL\s+CHARGE\s+CAPACITY\s+([\d,]+)\s*mWh')
        if ($designMatch.Success -and $fullMatch.Success) {
            $design = Convert-P2BatteryCapacity $designMatch.Groups[1].Value
            $full = Convert-P2BatteryCapacity $fullMatch.Groups[1].Value
            if ($null -ne $design -and $null -ne $full) {
                return [math]::Round(($full / $design) * 100.0, 1)
            }
        }
    } catch {}
    return $null
}

$health = $null
$xmlPath = Join-Path $env:TEMP ('P2-Battery-' + [guid]::NewGuid().ToString('N') + '.xml')
$htmlPath = [System.IO.Path]::ChangeExtension($xmlPath, '.html')
try {
    # Match the format previously used by P2, which successfully read 68.6% on an ASUS.
    try {
        $powercfgOutput = & powercfg.exe /batteryreport /xml /output $xmlPath 2>&1
        if (Test-Path -LiteralPath $xmlPath -PathType Leaf) {
            $health = Get-P2HealthFromXml $xmlPath
        }
    } catch {}

    if ($null -eq $health) { $health = Get-P2HealthFromWmi }

    if ($null -eq $health) {
        try {
            $powercfgOutput = & powercfg.exe /batteryreport /output $htmlPath 2>&1
            if (Test-Path -LiteralPath $htmlPath -PathType Leaf) {
                $health = Get-P2HealthFromHtml $htmlPath
            }
        } catch {}
    }
}
finally {
    Remove-Item -LiteralPath $xmlPath,$htmlPath -Force -ErrorAction SilentlyContinue
}
if ($null -ne $health) {
    Write-Host ('Battery health: {0:0.0}%' -f $health)
} else {
    Write-Host 'Battery health: Unavailable'
}
