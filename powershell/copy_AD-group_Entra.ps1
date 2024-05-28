# Adjust Searchbase as required
$groups= Get-ADGroup -SearchBase "OU=Rundeck,OU=Service Gruppe,DC=some,DC=local" -Filter *
ForEach($group in $groups)
{

Do {
    Try {
            $adgroupname = $group.name
            $adgroup = Get-ADGroup -Identity $adgroupname -ErrorAction Stop
            $success = $true
        }
    Catch {
        $success = $false
        Write-host "A group with the name above doesn't exist in AD!"`n -ForegroundColor Red
    }
}
Until ($success)

Write-host "Found the group!"`n -ForegroundColor Green

$adgroupdescription = (Get-ADGroup -Identity $adgroupname -Properties Description).Description

$adgroupnotes = (Get-ADGroup -Identity $adgroupname -Properties info).info

$adfulldescription = $adgroupdescription + "`n" + $adgroupnotes

$adgroupmembers = Get-ADGroupMember -Identity $adgroupname | Where-Object -FilterScript {$_.ObjectClass -eq 'user'}

$adgroupmembersids = $adgroupmembers.SID.Value

$emails = @()

ForEach ($adgroupmemebersid in $adgroupmembersids) {
    $email = (Get-ADUser -Identity $adgroupmemebersid -Properties Mail).Mail
    $emails += $email
}

$adgroupnestedgroups = Get-ADGroupMember -Identity $adgroupname | Where-Object -FilterScript {$_.ObjectClass -eq 'group'}

$adgroupnestedgroupnames = $adgroupnestedgroups.name


Do {
    $aadgroupname = $group.name
    $aadgroup = Get-MsolGroup | Where-Object {$_.DisplayName -eq $aadgroupname} -ErrorAction SilentlyContinue
}

Until ($aadgroup.Count -eq 0)

$newaadgroup = New-MsolGroup -DisplayName $aadgroupname -Description $adfulldescription

$users = @()

$emails | ForEach {
    Try {
        $user=(Get-MsolUser -UserPrincipalName $_ -ErrorAction Stop).ObjectID      
        $users += $user          
    }
    Catch {}
    
}

If ($users.Count -gt 0) {
    $users | ForEach {
        Add-MsolGroupMember -GroupObjectId $newaadgroup.ObjectID -GroupMemberType User -GroupMemberObjectId $_
    }
}

If ($adgroupnestedgroupnames.Count -gt 0) {
    ForEach ($adgroupnestedgroupname in $adgroupnestedgroupnames) {
        $aadnestedgroup = Get-MsolGroup | Where-Object {$_.DisplayName -eq $adgroupnestedgroupname}
        Add-MsolGroupMember -GroupObjectId $newaadgroup.ObjectID -GroupMemberType Group -GroupMemberObjectId $aadnestedgroup.ObjectID        
    }
}

Remove-Variable * -ErrorAction SilentlyContinue
}