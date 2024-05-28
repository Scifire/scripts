$app_name = "Atlassian Cloud"
$app_role_name = "User"
$group=Get-AzureADGroup -Filter "startswith(DisplayName, '_WIKI_')" -All:$true

$sp = Get-AzureADServicePrincipal -Filter "displayName eq '$app_name'"
$appRole = $sp.AppRoles | Where-Object { $_.DisplayName -eq "$app_role_name" }

foreach ($1 in $group){
New-AzureADGroupAppRoleAssignment -ObjectId $1.ObjectId -PrincipalId $1.ObjectId -ResourceId $sp.ObjectId -Id $appRole.Id
}