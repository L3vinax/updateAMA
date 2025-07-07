# Requires -Version 7.0 or later
$rgName = "ocs-arc"
$region = "westus2"
$amaName = "AzureMonitorWindowsAgent"
$publisher = "Microsoft.Azure.Monitor"
$settings = @{}

$latest = (Get-AzVMExtensionImage -Location $region -PublisherName $publisher -Type $amaName | Sort-Object { [Version]$_.Version } -Descending | Select-Object -First 1).Version
$servers = Get-AzConnectedMachine -ResourceGroupName $rgName

$servers | ForEach-Object -Parallel {
    $ext = Get-AzConnectedMachineExtension -ResourceGroupName $using:rgName -MachineName $_.Name -Name $using:amaName -ErrorAction SilentlyContinue
    $currentVersion = if ($ext) { $ext.TypeHandlerVersion } else { "0.0.0.0" }
    if ([Version]$currentVersion -lt [Version]$using:latest) {
        New-AzConnectedMachineExtension -Name $using:amaName -ExtensionType $using:amaName -Publisher $using:publisher -ResourceGroupName $using:rgName -MachineName $_.Name -Location $using:region -TypeHandlerVersion $using:latest -Settings $using:settings | Out-Null
        Write-Host "Updated AMA on $($_.Name) from $currentVersion to $using:latest" -ForegroundColor Green
    } else {
        Write-Host "AMA on $($_.Name) is already up to date ($currentVersion)" -ForegroundColor Yellow
    }
}
