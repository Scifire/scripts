Import-Module ActiveDirectory

Get-ADGroupMember -Identity "group_a" -Recursive | Where-Object {$_.objectClass -eq "user"} | ForEach-Object {Add-ADGroupMember -Identity "group_b" -Members $_.distinguishedName}