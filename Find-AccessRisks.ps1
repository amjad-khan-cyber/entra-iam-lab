<#
.SYNOPSIS
    Checks every user against a few access rules and lists anything that breaks them:
    disabled accounts that still have access, access outside the user's department,
    segregation of duties conflicts, and service accounts with no owner or with admin access.
 
.NOTES
    Requires: Microsoft.Graph.Authentication, Microsoft.Graph.Users
    Permissions (read-only): User.Read.All, GroupMember.Read.All
    Connect first:  Connect-MgGraph -TenantId <yourtenant>.onmicrosoft.com -Scopes "User.Read.All","GroupMember.Read.All"
#>
 
param(
    [string]$OutputPath = ".\AccessFindings.csv"
)
 
if (-not (Get-MgContext)) {
    Write-Error "Not connected to Microsoft Graph. Run Connect-MgGraph first."
    return
}
 
# ---- Rules: edit these to match your groups ----
 
# Which department each group belongs to
$groupDepartment = @{
    'Finance-Share' = 'Finance'
    'Sales-Share'   = 'Sales'
    'IT-Admins'     = 'IT'
}
 
# Groups that give admin-level access
$privilegedGroups = @('IT-Admins')
 
# Pairs of groups one person should never hold together
$sodConflicts = @(
    [PSCustomObject]@{
        GroupA = 'AP-Vendor-Create'
        GroupB = 'AP-Payment-Approve'
        Reason = 'Same person could create a vendor and approve payments to it; remove one group'
    }
)
 
# ---- Collect findings ----
 
$findings = New-Object System.Collections.Generic.List[object]
 
function Add-Finding {
    param($Type, $User, $Detail, $Action)
    $findings.Add([PSCustomObject]@{
        Finding         = $Type
        User            = $User.DisplayName
        Department      = $User.Department
        Detail          = $Detail
        SuggestedAction = $Action
    })
}
 
$users = Get-MgUser -All -Property Id, DisplayName, UserPrincipalName, Department, AccountEnabled
 
foreach ($user in $users) {
 
    $managerName = ""
    try {
        $manager = Get-MgUserManager -UserId $user.Id -ErrorAction Stop
        $managerName = $manager.AdditionalProperties['displayName']
    }
    catch {
        $managerName = ""
    }
 
    $groupNames = @(Get-MgUserMemberOf -UserId $user.Id -All |
        Where-Object { $_.AdditionalProperties['@odata.type'] -eq '#microsoft.graph.group' } |
        ForEach-Object { $_.AdditionalProperties['displayName'] })
 
    $isServiceAccount = ($user.Department -eq 'Service Account') -or ($user.UserPrincipalName -like 'svc*')
 
    # Rule 1: disabled account still holds access
    if (-not $user.AccountEnabled -and $groupNames.Count -gt 0) {
        Add-Finding 'Disabled account with access' $user ("Still in: " + ($groupNames -join ', ')) 'Remove group memberships as part of offboarding'
    }
 
    # Rule 2: service account with no owner
    if ($isServiceAccount -and -not $managerName) {
        Add-Finding 'Service account with no owner' $user 'No manager or owner set' 'Assign an owner; consider an app registration or managed identity instead'
    }
 
    # Rule 3: service account in an admin group
    if ($isServiceAccount) {
        foreach ($g in ($groupNames | Where-Object { $_ -in $privilegedGroups })) {
            Add-Finding 'Service account in privileged group' $user "Member of $g" 'Confirm the need and limit it to only the permissions the service requires'
        }
    }
 
    # Rule 4: access that doesn't match the user's department (likely a mover)
    if (-not $isServiceAccount -and $user.Department) {
        foreach ($g in $groupNames) {
            if ($groupDepartment.ContainsKey($g) -and $groupDepartment[$g] -ne $user.Department) {
                Add-Finding 'Access outside department' $user "In $g but department is $($user.Department)" 'Ask the group owner whether this access is still needed'
            }
        }
    }
 
    # Rule 5: segregation of duties conflicts
    foreach ($pair in $sodConflicts) {
        if ($pair.GroupA -in $groupNames -and $pair.GroupB -in $groupNames) {
            Add-Finding 'Segregation of duties conflict' $user "In both $($pair.GroupA) and $($pair.GroupB)" $pair.Reason
        }
    }

    # Rule 6: user has no department set
    if (-not $user.Department) {
        Add-Finding 'Missing Department' $user 'Department field is empty' 'Set Department from HR Records'
    }
}

# ---- Output ----
 
if ($findings.Count -eq 0) {
    Write-Host "No findings. Checked $($users.Count) users." -ForegroundColor Green
    return
}
 
$findings | Sort-Object Finding, User | Export-Csv -Path $OutputPath -NoTypeInformation
$findings | Sort-Object Finding, User | Format-Table Finding, User, Detail -AutoSize -Wrap
 
Write-Host "$($findings.Count) findings across $($users.Count) users. Saved to $OutputPath" -ForegroundColor Yellow