# scripts
Helpful scripts I used the past

## Powershell

#### [Copy User from one AD group to another](powershell/copy_group_users.ps1)
Copy all users from AD group a to AD group B.

#### [Copy AD Groups from a specific OU to Entra](powershell/copy_AD-group_Entra.ps1)
Copies all groups from a specific OU to Entra, including members and description.

#### [Add Entra ID groups to an Entra Application](powershell/add_group_to_app.ps1)
Adds Entra ID groups with a specific phrase to a defined Entra Application. 

#### [Delete empty folders](powershell/delete_empty_folders.ps1)
Deletes all empty folders in the given path and in all sub folders.

#### [Robocopy examples](robocopy.md)
Some Robocopy commands

#### [Sharepoint Site Storage Limit](powershell/set_sharepoint_site_limit.ps1)
Set a storage limit of 25GB for all sites which currently have a limit more than 1TB. It will also set the warning to 20GB

#### [Find Email Adress in ExO](powershell/FindEmailAddress.ps1)
Find a Mail address in Exchange Online (including additional proxy addresses)

## Bash

#### [FortiGate Certificate Comparison and Rotation Script](bash/bash/fgt_update_cert_vip.sh)
This script automates the process of comparing SSL certificates used by a FortiGate Virtual Server (VIP) with a local certificate file. If the certificates differ, it uploads the new certificate to the FortiGate and updates the VIP to use it.
