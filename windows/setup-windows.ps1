#requires -RunAsAdministrator
<#!
Windows-side WSL2 cluster network setup.
Enter one cluster IP per line and type EOF to finish.
#>

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

function Assert-Administrator {
    $identity = [Security.Principal.WindowsIdentity]::GetCurrent()
    $principal = [Security.Principal.WindowsPrincipal]::new($identity)
    if (-not $principal.IsInRole([Security.Principal.WindowsBuiltInRole]::Administrator)) {
        throw '관리자 권한 PowerShell에서 실행해야 합니다.'
    }
}

function Read-ClusterIps {
    $clusterIps = [System.Collections.Generic.List[string]]::new()
    Write-Host ''
    Write-Host '클러스터 IP를 한 줄에 하나씩 입력하세요. 끝내려면 EOF를 입력하세요.' -ForegroundColor Cyan

    while ($true) {
        $value = (Read-Host 'Cluster IP').Trim()
        if ($value -ieq 'EOF') { break }
        if ([string]::IsNullOrWhiteSpace($value)) { continue }

        $parsedIp = $null
        if (-not [System.Net.IPAddress]::TryParse($value, [ref]$parsedIp)) {
            Write-Warning "유효한 IP 주소가 아닙니다. 다시 입력하세요: $value"
            continue
        }
        if (-not $clusterIps.Contains($parsedIp.ToString())) {
            [void]$clusterIps.Add($parsedIp.ToString())
        }
    }

    if ($clusterIps.Count -eq 0) {
        throw '최소 하나의 Cluster IP가 필요합니다.'
    }
    return $clusterIps.ToArray()
}

function Set-IniKey {
    param(
        [AllowEmptyString()][string]$Content,
        [string]$Section,
        [string]$Key,
        [string]$Value
    )

    $lines = if ([string]::IsNullOrEmpty($Content)) { @() } else { $Content -split "`r?`n" }
    $result = [System.Collections.Generic.List[string]]::new()
    $sectionFound = $false
    $inTargetSection = $false
    $keyWritten = $false
    $escapedKey = [regex]::Escape($Key)

    foreach ($line in $lines) {
        if ($line -match '^\s*\[([^\]]+)\]\s*(?:[;#].*)?$') {
            if ($inTargetSection -and -not $keyWritten) {
                [void]$result.Add("$Key=$Value")
                $keyWritten = $true
            }
            $inTargetSection = ($Matches[1] -ieq $Section)
            if ($inTargetSection) { $sectionFound = $true }
            [void]$result.Add($line)
            continue
        }

        if ($inTargetSection -and $line -match "^\s*$escapedKey\s*=") {
            if (-not $keyWritten) {
                [void]$result.Add("$Key=$Value")
                $keyWritten = $true
            }
            continue
        }
        [void]$result.Add($line)
    }

    if ($inTargetSection -and -not $keyWritten) {
        [void]$result.Add("$Key=$Value")
    }
    if (-not $sectionFound) {
        if ($result.Count -gt 0 -and -not [string]::IsNullOrWhiteSpace($result[$result.Count - 1])) {
            [void]$result.Add('')
        }
        [void]$result.Add("[$Section]")
        [void]$result.Add("$Key=$Value")
    }
    return ($result -join "`n").TrimEnd() + "`n"
}

function Remove-IniKey {
    param(
        [AllowEmptyString()][string]$Content,
        [string]$Section,
        [string]$Key
    )

    $lines = if ([string]::IsNullOrEmpty($Content)) { @() } else { $Content -split "`r?`n" }
    $result = [System.Collections.Generic.List[string]]::new()
    $inTargetSection = $false
    $escapedKey = [regex]::Escape($Key)

    foreach ($line in $lines) {
        if ($line -match '^\s*\[([^\]]+)\]\s*(?:[;#].*)?$') {
            $inTargetSection = ($Matches[1] -ieq $Section)
            [void]$result.Add($line)
            continue
        }
        if ($inTargetSection -and $line -match "^\s*$escapedKey\s*=") {
            continue
        }
        [void]$result.Add($line)
    }
    return ($result -join "`n").TrimEnd() + "`n"
}

function Set-ManagedFirewallRule {
    param([string]$Name, [hashtable]$Parameters)
    Get-NetFirewallRule -Name $Name -ErrorAction SilentlyContinue | Remove-NetFirewallRule
    New-NetFirewallRule -Name $Name @Parameters | Out-Null
}

function Set-ManagedHyperVFirewallRule {
    param([string]$Name, [hashtable]$Parameters)
    Get-NetFirewallHyperVRule -Name $Name -ErrorAction SilentlyContinue | Remove-NetFirewallHyperVRule
    New-NetFirewallHyperVRule -Name $Name @Parameters | Out-Null
}

Assert-Administrator

$windowsBuild = [Environment]::OSVersion.Version.Build
if ($windowsBuild -lt 22621) {
    throw 'Mirrored networking과 hostAddressLoopback은 Windows 11 22H2(빌드 22621) 이상이 필요합니다.'
}

foreach ($command in 'New-NetFirewallRule', 'New-NetFirewallHyperVRule', 'Get-NetFirewallHyperVRule') {
    if (-not (Get-Command $command -ErrorAction SilentlyContinue)) {
        throw "필수 PowerShell 명령을 찾을 수 없습니다: $command"
    }
}

$wslInstalled = $false
if (Get-Command wsl.exe -ErrorAction SilentlyContinue) {
    & wsl.exe --status *> $null
    $wslInstalled = ($LASTEXITCODE -eq 0)
}
if (-not $wslInstalled) {
    Write-Host 'WSL 설치가 필요합니다. 관리자 PowerShell에서 wsl --install을 실행하고 PC를 재부팅한 후 다시 실행해주세요.' -ForegroundColor Yellow
    exit 0
}

$ClusterIPs = Read-ClusterIps
$WSL_ID = '{40E0AC32-46A5-438A-A0B2-2B479E8F2E90}'

# Windows-side global WSL settings. generateHosts is not written to .wslconfig.
$wslConfigPath = Join-Path $env:USERPROFILE '.wslconfig'
$wslConfigContent = if (Test-Path $wslConfigPath) { Get-Content -LiteralPath $wslConfigPath -Raw } else { '' }
$wslConfigContent = Remove-IniKey $wslConfigContent 'network' 'generateHosts'
$wslConfigContent = Set-IniKey $wslConfigContent 'wsl2' 'networkingMode' 'mirrored'
$wslConfigContent = Set-IniKey $wslConfigContent 'experimental' 'hostAddressLoopback' 'true'
if (Test-Path $wslConfigPath) {
    Copy-Item -LiteralPath $wslConfigPath -Destination "$wslConfigPath.before-mlops.bak" -Force
}
Set-Content -LiteralPath $wslConfigPath -Value $wslConfigContent -Encoding utf8

# Apply the Windows-side .wslconfig on the next WSL startup.
wsl.exe --shutdown
Start-Sleep -Seconds 2

Set-ManagedFirewallRule 'MLOps-Cluster-Internal' @{
    DisplayName = 'MLOps Cluster Internal'
    Direction = 'Inbound'
    RemoteAddress = $ClusterIPs
    Protocol = 'Any'
    Action = 'Allow'
    Profile = 'Any'
}

Set-ManagedHyperVFirewallRule 'WSL-MLOps-Cluster-Internal' @{
    DisplayName = 'WSL MLOps Cluster Internal'
    Direction = 'Inbound'
    VMCreatorId = $WSL_ID
    RemoteAddresses = $ClusterIPs
    Action = 'Allow'
}

Write-Host "`n===== 최종 Windows 측 네트워크 설정 =====" -ForegroundColor Green
Write-Host "WSL Creator ID: $WSL_ID"
Write-Host "Cluster IPs: $($ClusterIPs -join ', ')"

Write-Host "`n[.wslconfig] $wslConfigPath"
Get-Content -LiteralPath $wslConfigPath

Write-Host "`n[Windows Firewall]"
Get-NetFirewallRule -Name 'MLOps-Cluster-Internal' |
    Get-NetFirewallAddressFilter |
    Select-Object InstanceID, RemoteAddress |
    Format-Table -AutoSize

Write-Host "`n[Hyper-V Firewall]"
Get-NetFirewallHyperVRule -Name 'WSL-MLOps-Cluster-Internal' |
    Select-Object Name, DisplayName, Direction, Protocol, RemoteAddresses, VMCreatorId, Action |
    Format-Table -AutoSize

Write-Host "`n[Cluster IP 연결 확인]"
$networkResults = foreach ($clusterIp in $ClusterIPs) {
    [PSCustomObject]@{
        ClusterIP = $clusterIp
        Ping = Test-Connection -ComputerName $clusterIp -Count 1 -Quiet -ErrorAction SilentlyContinue
    }
}
$networkResults | Format-Table -AutoSize

Write-Host "`nWindows 측 기본 네트워크 설정이 완료되었습니다." -ForegroundColor Green
