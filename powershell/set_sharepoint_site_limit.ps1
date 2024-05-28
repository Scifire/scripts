Connect-SPOService
# Search for sites With Storage Limit bigger than 1TB (default)
$site=Get-SPOSite -Limit All | Select Title, URL, StorageQuota, StorageUsageCurrent, @{Label="Percentage";Expression={[math]::Round( ($_.StorageUsageCurrent / $_.StorageQuota * 100),2)}} | Where-Object {$_.StorageQuota -gt "1048576"} | Select -expandproperty Url
# Set Limit for each site to 25GB
foreach ($1 in $site){
    Write-Host $1
    Set-SPOSite -Identity $1 -StorageQuota "25600" -StorageQuotaWarningLevel "20480"
}
