# Get all Arc-enabled servers
$arcServers = Get-AzConnectedMachine

foreach ($server in $arcServers) {
    $serverName = $server.Name
    try {
        # Check AMA extension
        $amaExtension = Get-AzConnectedMachineExtension `
            -MachineName $serverName `
            -ResourceGroupName $server.ResourceGroupName `
            -Name "AzureMonitorWindowsAgent"
    } catch {
        # Could not find or access the extension
        Write-Output "$serverName : Not updated (extension not found or inaccessible)"
        continue
    }

    if ($null -eq $amaExtension) {
        Write-Output "$serverName : Not updated (extension not present)"
        continue
    }

    if ($amaExtension.EnableAutomaticUpgrade -eq $true) {
        # Already configured
        Write-Output "$serverName : Not updated"
        continue
    }

    # Attempt update and report single-line result per server
    try {
        Update-AzConnectedMachineExtension `
            -MachineName $serverName `
            -ResourceGroupName $server.ResourceGroupName `
            -Name "AzureMonitorWindowsAgent" `
            -Publisher "Microsoft.Azure.Monitor" `
            -Type "AzureMonitorWindowsAgent" `
            -EnableAutomaticUpgrade | Out-Null

        Write-Output "$serverName : Updated"
    } catch {
        $err = $_.Exception.Message -replace "\r?\n"," "
        Write-Output "$serverName : Update failed - $err"
    }
}
