<#
.SYNOPSIS
  Enables automatic update on the Azure Monitor Agent (AMA) extension for all Arc-enabled servers
  where it is not already configured.

.DESCRIPTION
  - Enumerates Arc-enabled servers across chosen subscriptions/resource groups.
  - Detects AMA (Windows/Linux) and enables:
      * -AutoUpgradeMinorVersion
      * -EnableAutomaticUpgrade
  - Preserves existing extension settings & protected settings.
  - Produces a summary report.

  Requires:
    Az.Accounts, Az.ConnectedMachine

  Tested with:
    Az.ConnectedMachine cmdlet 'Set-AzConnectedMachineExtension' which supports
    -AutoUpgradeMinorVersion and -EnableAutomaticUpgrade.
#>

[CmdletBinding(SupportsShouldProcess)]
param(
    # One or more subscription IDs to scope to. If not supplied and -AllSubscriptions is not set,
    # the current Az context subscription is used.
    [string[]] $SubscriptionId,

    # Limit to a single Resource Group name (optional).
    [string]   $ResourceGroupName,

    # Process all subscriptions visible to the caller.
    [switch]   $AllSubscriptions,

    # Concurrency for processing machines (PowerShell 7+)
    [int]      $ThrottleLimit = 16,
    # Run the machine-processing loop in parallel (PowerShell 7+)
    [switch]   $Parallel,
    # When set, do not perform updates; useful because -WhatIf isn't available inside -Parallel runspaces
    [switch]   $DryRun
)

begin {
    # Ensure modules are present
    $required = @('Az.Accounts','Az.ConnectedMachine')
    foreach ($m in $required) {
        if (-not (Get-Module -ListAvailable -Name $m)) {
            Write-Verbose "Installing missing module: $m"
            Install-Module $m -Scope CurrentUser -Force -AllowClobber
        }
    }

    Import-Module Az.Accounts -ErrorAction Stop
    Import-Module Az.ConnectedMachine -ErrorAction Stop

    # Login if needed
    try {
        if (-not (Get-AzContext)) { Connect-AzAccount -ErrorAction Stop | Out-Null }
    } catch { 
        throw "Failed to authenticate: $($_.Exception.Message)"
    }

    # AMA identifiers (publisher & types)
    $amaPublisher = 'Microsoft.Azure.Monitor'
    $amaTypes     = @('AzureMonitorWindowsAgent','AzureMonitorLinuxAgent')  # Arc extension types
    # (Ref: Extension catalog and AMA types) 

    $result = [System.Collections.Concurrent.ConcurrentBag[pscustomobject]]::new()
}

process {
    # Resolve subscription list
    $subs = @()
    if ($AllSubscriptions.IsPresent) {
        $subs = Get-AzSubscription | Select-Object -ExpandProperty Id
    } elseif ($SubscriptionId) {
        $subs = $SubscriptionId
    } else {
        $subs = (Get-AzContext).Subscription.Id
    }

    foreach ($sub in $subs) {
        Write-Host "`n==> Subscription: $sub" -ForegroundColor Cyan
        Set-AzContext -Subscription $sub | Out-Null

        # Optional provider registrations often required by customers for extension upgrade services
        try {
            $prov = Get-AzResourceProvider -ProviderNamespace Microsoft.Compute -ErrorAction Stop
            if ($prov.RegistrationState -ne 'Registered') {
                Write-Verbose "Registering Microsoft.Compute in $sub..."
                Register-AzResourceProvider -ProviderNamespace Microsoft.Compute | Out-Null
            }
        } catch {
            Write-Verbose "Could not verify/register Microsoft.Compute: $($_.Exception.Message)"
        }

        # Enumerate Arc machines in scope
        $machines = if ($ResourceGroupName) {
            Get-AzConnectedMachine -ResourceGroupName $ResourceGroupName -ErrorAction SilentlyContinue
        } else {
            Get-AzConnectedMachine -ErrorAction SilentlyContinue
        }

        if (-not $machines) {
            Write-Host "No Arc-enabled machines found in scope." -ForegroundColor Yellow
            continue
        }

        if ($Parallel.IsPresent -and $PSVersionTable.PSVersion.Major -ge 7) {
            # Parallel processing (PowerShell 7+).
            # Build the parallel script as a string so PS5.1 parser doesn't choke on $using: tokens.
            $parallelScript = @'
$machines | ForEach-Object -Parallel {
    Import-Module Az.ConnectedMachine -ErrorAction Stop

    $m = $_
    try {
        $exts = Get-AzConnectedMachineExtension -MachineName $m.Name -ResourceGroupName $m.ResourceGroupName -ErrorAction SilentlyContinue

        $ama = $exts | Where-Object {
            $_.Publisher -eq $using:amaPublisher -and $using:amaTypes -contains $_.ExtensionType
        }

        if (-not $ama) {
            $using:result.Add([pscustomobject]@{
                SubscriptionId         = $m.Id.Split('/')[2]
                ResourceGroup          = $m.ResourceGroupName
                MachineName            = $m.Name
                ExtensionType          = $null
                Previous_AutoMinor     = $null
                Previous_AutoUpgrade   = $null
                Status                 = 'AMA extension not installed'
            })
            return
        }

        foreach ($ext in $ama) {
            $prevMinor   = [bool]($ext.AutoUpgradeMinorVersion)
            $prevUpgrade = [bool]($ext.EnableAutomaticUpgrade)

            if ($prevMinor -and $prevUpgrade) {
                $using:result.Add([pscustomobject]@{
                    SubscriptionId         = $m.Id.Split('/')[2]
                    ResourceGroup          = $m.ResourceGroupName
                    MachineName            = $m.Name
                    ExtensionType          = $ext.ExtensionType
                    Previous_AutoMinor     = $prevMinor
                    Previous_AutoUpgrade   = $prevUpgrade
                    Status                 = 'AlreadyCompliant'
                })
                continue
            }

            $settings         = $ext.Setting
            $protectedSettings= $ext.ProtectedSetting

            if ($using:DryRun) {
                $using:result.Add([pscustomobject]@{
                    SubscriptionId         = $m.Id.Split('/')[2]
                    ResourceGroup          = $m.ResourceGroupName
                    MachineName            = $m.Name
                    ExtensionType          = $ext.ExtensionType
                    Previous_AutoMinor     = $prevMinor
                    Previous_AutoUpgrade   = $prevUpgrade
                    Status                 = 'WouldChange'
                })
            } else {
                $updated = Set-AzConnectedMachineExtension \
                    -MachineName $m.Name \
                    -ResourceGroupName $m.ResourceGroupName \
                    -Location $m.Location \
                    -Name $ext.Name \
                    -Publisher $ext.Publisher \
                    -ExtensionType $ext.ExtensionType \
                    -TypeHandlerVersion $ext.TypeHandlerVersion \
                    -Setting $settings \
                    -ProtectedSetting $protectedSettings \
                    -AutoUpgradeMinorVersion \
                    -EnableAutomaticUpgrade \
                    -Confirm:$false -ErrorAction Stop

                $using:result.Add([pscustomobject]@{
                    SubscriptionId         = $m.Id.Split('/')[2]
                    ResourceGroup          = $m.ResourceGroupName
                    MachineName            = $m.Name
                    ExtensionType          = $ext.ExtensionType
                    Previous_AutoMinor     = $prevMinor
                    Previous_AutoUpgrade   = $prevUpgrade
                    Status                 = 'Changed'
                })
            }
        }
    } catch {
        $using:result.Add([pscustomobject]@{
            SubscriptionId         = $m.Id.Split('/')[2]
            ResourceGroup          = $m.ResourceGroupName
            MachineName            = $m.Name
            ExtensionType          = $null
            Previous_AutoMinor     = $null
            Previous_AutoUpgrade   = $null
            Status                 = "Error: $($_.Exception.Message)"
        })
    }
} -ThrottleLimit $using:ThrottleLimit
'@

            # Execute the parallel scriptblock only in PS7+ where ForEach-Object -Parallel is supported.
            $sb = [ScriptBlock]::Create($parallelScript)
            & $sb
        } else {
            # Sequential processing (Windows PowerShell or when -Parallel not requested)
            $machines | ForEach-Object {
                $m = $_
                try {
                    # Fetch all extensions for this Arc machine
                    $exts = Get-AzConnectedMachineExtension -MachineName $m.Name -ResourceGroupName $m.ResourceGroupName -ErrorAction SilentlyContinue

                    # Find AMA (Windows/Linux). Names may vary; match by Publisher & ExtensionType to be safe.
                    $ama = $exts | Where-Object {
                        $_.Publisher -eq $amaPublisher -and $amaTypes -contains $_.ExtensionType
                    }

                    if (-not $ama) {
                        $result.Add([pscustomobject]@{
                            SubscriptionId         = $m.Id.Split('/')[2]
                            ResourceGroup          = $m.ResourceGroupName
                            MachineName            = $m.Name
                            ExtensionType          = $null
                            Previous_AutoMinor     = $null
                            Previous_AutoUpgrade   = $null
                            Status                 = 'AMA extension not installed'
                        })
                        return
                    }

                    foreach ($ext in $ama) {
                        $prevMinor   = [bool]($ext.AutoUpgradeMinorVersion)
                        $prevUpgrade = [bool]($ext.EnableAutomaticUpgrade)

                        if ($prevMinor -and $prevUpgrade) {
                            $result.Add([pscustomobject]@{
                                SubscriptionId         = $m.Id.Split('/')[2]
                                ResourceGroup          = $m.ResourceGroupName
                                MachineName            = $m.Name
                                ExtensionType          = $ext.ExtensionType
                                Previous_AutoMinor     = $prevMinor
                                Previous_AutoUpgrade   = $prevUpgrade
                                Status                 = 'AlreadyCompliant'
                            })
                            continue
                        }

                        # Preserve existing settings to avoid losing configuration (e.g., DCR links not stored here but keep consistency)
                        $settings         = $ext.Setting
                        $protectedSettings= $ext.ProtectedSetting

                        $msg = "Enable AMA auto-update on [$($m.Name)] ext [$($ext.Name)]"
                        if ($PSCmdlet.ShouldProcess($m.Name, $msg)) {
                            # Update in place
                            $updated = Set-AzConnectedMachineExtension `
                                -MachineName $m.Name `
                                -ResourceGroupName $m.ResourceGroupName `
                                -Location $m.Location `
                                -Name $ext.Name `
                                -Publisher $ext.Publisher `
                                -ExtensionType $ext.ExtensionType `
                                -TypeHandlerVersion $ext.TypeHandlerVersion `
                                -Setting $settings `
                                -ProtectedSetting $protectedSettings `
                                -AutoUpgradeMinorVersion `
                                -EnableAutomaticUpgrade `
                                -Confirm:$false -ErrorAction Stop

                            $result.Add([pscustomobject]@{
                                SubscriptionId         = $m.Id.Split('/')[2]
                                ResourceGroup          = $m.ResourceGroupName
                                MachineName            = $m.Name
                                ExtensionType          = $ext.ExtensionType
                                Previous_AutoMinor     = $prevMinor
                                Previous_AutoUpgrade   = $prevUpgrade
                                Status                 = 'Changed'
                            })
                        }
                    }
                } catch {
                    $result.Add([pscustomobject]@{
                        SubscriptionId         = $m.Id.Split('/')[2]
                        ResourceGroup          = $m.ResourceGroupName
                        MachineName            = $m.Name
                        ExtensionType          = $null
                        Previous_AutoMinor     = $null
                        Previous_AutoUpgrade   = $null
                        Status                 = "Error: $($_.Exception.Message)"
                    })
                }
            }
        }

    }

    # Print a neat summary grouped by Status
    $summary = $result.ToArray() | Sort-Object Status, SubscriptionId, ResourceGroup, MachineName
    Write-Host "`nSummary:" -ForegroundColor Cyan
    $summary | Group-Object Status | ForEach-Object {
        Write-Host ("{0,-18} {1,5}" -f $_.Name, $_.Count)
    }

    # Return full objects to the pipeline for export if desired
    $summary
}
