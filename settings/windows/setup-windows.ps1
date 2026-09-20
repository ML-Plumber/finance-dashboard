#requires -RunAsAdministrator
<#
Windows firewall rule setup for cluster IPs and ports.
This script does not install, configure, start, stop, or inspect WSL.
Enter one cluster IP per line and type EOF to finish, then enter TCP/UDP ports.
#>

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

$WINDOWS_RULE_PREFIX = 'MLOps-Cluster-Internal'
$HYPERV_RULE_PREFIX = 'WSL-MLOps-Cluster-Internal'
$LEGACY_WINDOWS_RULE_NAME = 'MLOps-Cluster-Internal'
$LEGACY_HYPERV_RULE_NAME = 'WSL-MLOps-Cluster-Internal'
$WSL_CREATOR_ID = '{40E0AC32-46A5-438A-A0B2-2B479E8F2E90}'
$RULE_PROTOCOLS = @('TCP', 'UDP')
$RULE_DIRECTIONS = @('Inbound', 'Outbound')

function Assert-Administrator {
    $identity = [Security.Principal.WindowsIdentity]::GetCurrent()
    $principal = [Security.Principal.WindowsPrincipal]::new($identity)
    if (-not $principal.IsInRole([Security.Principal.WindowsBuiltInRole]::Administrator)) {
        throw 'Run this script in an elevated PowerShell session.'
    }
}

function Read-ClusterIps {
    $clusterIps = [System.Collections.Generic.List[string]]::new()
    Write-Host ''
    Write-Host 'Enter one Cluster IP per line. Type EOF when finished.' -ForegroundColor Cyan

    while ($true) {
        $value = (Read-Host 'Cluster IP').Trim()
        if ($value -ieq 'EOF') { break }
        if ([string]::IsNullOrWhiteSpace($value)) { continue }

        $parsedIp = $null
        if (-not [System.Net.IPAddress]::TryParse($value, [ref]$parsedIp)) {
            Write-Warning "Invalid IP address. Please try again: $value"
            continue
        }
        if (-not $clusterIps.Contains($parsedIp.ToString())) {
            [void]$clusterIps.Add($parsedIp.ToString())
        }
    }

    if ($clusterIps.Count -eq 0) {
        throw 'At least one Cluster IP is required.'
    }
    return $clusterIps.ToArray()
}

function Read-ClusterPorts {
    $clusterPorts = [System.Collections.Generic.List[string]]::new()
    Write-Host ''
    Write-Host 'Enter one TCP/UDP port per line. Type EOF when finished.' -ForegroundColor Cyan

    while ($true) {
        $value = (Read-Host 'Port').Trim()
        if ($value -ieq 'EOF') { break }
        if ([string]::IsNullOrWhiteSpace($value)) { continue }

        $parsedPort = 0
        if (-not [int]::TryParse($value, [ref]$parsedPort) -or $parsedPort -lt 1 -or $parsedPort -gt 65535) {
            Write-Warning "Invalid port. Enter a number from 1 to 65535: $value"
            continue
        }
        if (-not $clusterPorts.Contains($parsedPort.ToString())) {
            [void]$clusterPorts.Add($parsedPort.ToString())
        }
    }

    if ($clusterPorts.Count -eq 0) {
        throw 'At least one port is required.'
    }
    return $clusterPorts.ToArray()
}

function Assert-RequiredCommands {
    $commands = @(
        'New-NetFirewallRule',
        'Get-NetFirewallRule',
        'Remove-NetFirewallRule',
        'Get-NetFirewallAddressFilter',
        'Get-NetFirewallPortFilter',
        'New-NetFirewallHyperVRule',
        'Get-NetFirewallHyperVRule',
        'Remove-NetFirewallHyperVRule'
    )

    foreach ($command in $commands) {
        if (-not (Get-Command $command -ErrorAction SilentlyContinue)) {
            throw "Required PowerShell command not found: $command"
        }
    }
}

function Set-ManagedWindowsFirewallRule {
    param([string]$Name, [hashtable]$Parameters)

    Get-NetFirewallRule -Name $Name -ErrorAction SilentlyContinue |
        Remove-NetFirewallRule -ErrorAction SilentlyContinue -Confirm:$false
    New-NetFirewallRule -Name $Name @Parameters | Out-Null
}

function Set-ManagedHyperVFirewallRule {
    param([string]$Name, [hashtable]$Parameters)

    Get-NetFirewallHyperVRule -Name $Name -ErrorAction SilentlyContinue |
        Remove-NetFirewallHyperVRule -ErrorAction SilentlyContinue -Confirm:$false
    New-NetFirewallHyperVRule -Name $Name @Parameters | Out-Null
}

function Remove-LegacyRule {
    param([string]$WindowsRuleName, [string]$HyperVRuleName)

    Get-NetFirewallRule -Name $WindowsRuleName -ErrorAction SilentlyContinue |
        Remove-NetFirewallRule -ErrorAction SilentlyContinue -Confirm:$false
    Get-NetFirewallHyperVRule -Name $HyperVRuleName -ErrorAction SilentlyContinue |
        Remove-NetFirewallHyperVRule -ErrorAction SilentlyContinue -Confirm:$false
}

function Get-WindowsFirewallRuleSummary {
    param([string]$Name)

    $rule = Get-NetFirewallRule -Name $Name -ErrorAction Stop
    $addressFilter = $rule | Get-NetFirewallAddressFilter
    $portFilter = $rule | Get-NetFirewallPortFilter

    return [PSCustomObject]@{
        Name = $rule.Name
        DisplayName = $rule.DisplayName
        Enabled = $rule.Enabled
        Direction = $rule.Direction
        Action = $rule.Action
        Profile = $rule.Profile
        Protocol = $portFilter.Protocol
        LocalPort = $portFilter.LocalPort
        RemotePort = $portFilter.RemotePort
        RemoteAddress = $addressFilter.RemoteAddress
    }
}

Assert-Administrator

$windowsBuild = [Environment]::OSVersion.Version.Build
if ($windowsBuild -lt 22621) {
    throw 'Hyper-V firewall rules require Windows 11 22H2 (build 22621) or later.'
}

Assert-RequiredCommands

$ClusterIPs = Read-ClusterIps
$ClusterPorts = Read-ClusterPorts

# Remove the old all-protocol/all-port rules created by earlier versions.
Remove-LegacyRule $LEGACY_WINDOWS_RULE_NAME $LEGACY_HYPERV_RULE_NAME

$windowsRuleNames = @()
$hyperVRuleNames = @()

foreach ($direction in $RULE_DIRECTIONS) {
    foreach ($protocol in $RULE_PROTOCOLS) {
        $suffix = "$protocol-$direction"
        $windowsRuleName = "$WINDOWS_RULE_PREFIX-$suffix"
        $hyperVRuleName = "$HYPERV_RULE_PREFIX-$suffix"

        $windowsParameters = @{
            DisplayName = $windowsRuleName
            Direction = $direction
            RemoteAddress = $ClusterIPs
            Protocol = $protocol
            Action = 'Allow'
            Profile = 'Any'
            Enabled = 'True'
        }

        $hyperVParameters = @{
            DisplayName = $hyperVRuleName
            Direction = $direction
            VMCreatorId = $WSL_CREATOR_ID
            RemoteAddresses = $ClusterIPs
            Protocol = $protocol
            Action = 'Allow'
            Profiles = 'Any'
            Enabled = 'True'
        }

        if ($direction -eq 'Inbound') {
            # Inbound traffic reaches the local service port.
            $windowsParameters.LocalPort = $ClusterPorts
            $hyperVParameters.LocalPorts = $ClusterPorts
        }
        else {
            # Outbound traffic targets the remote cluster service port.
            $windowsParameters.RemotePort = $ClusterPorts
            $hyperVParameters.RemotePorts = $ClusterPorts
        }

        Set-ManagedWindowsFirewallRule $windowsRuleName $windowsParameters
        Set-ManagedHyperVFirewallRule $hyperVRuleName $hyperVParameters

        $windowsRuleNames += $windowsRuleName
        $hyperVRuleNames += $hyperVRuleName
    }
}

Write-Host "`n===== Final Firewall Rule Configuration =====" -ForegroundColor Green
Write-Host "`n[Cluster IPs]"
$ClusterIPs | ForEach-Object { Write-Host "- $_" }
Write-Host "`n[Allowed Ports]"
$ClusterPorts | ForEach-Object { Write-Host "- $_" }

Write-Host "`n[Windows Firewall Rules]"
foreach ($ruleName in $windowsRuleNames) {
    Get-WindowsFirewallRuleSummary $ruleName | Format-List
}

Write-Host "`n[Hyper-V Firewall Rules]"
foreach ($ruleName in $hyperVRuleNames) {
    Get-NetFirewallHyperVRule -Name $ruleName -ErrorAction Stop |
        Select-Object Name, DisplayName, Enabled, Direction, Protocol, LocalPorts, RemotePorts, RemoteAddresses, Profiles, VMCreatorId, Action |
        Format-List
}

Write-Host "`nFirewall rule configuration completed successfully." -ForegroundColor Green
