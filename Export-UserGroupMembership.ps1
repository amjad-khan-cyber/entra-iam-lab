<#
.SYNOPSIS
    Exports every user in the tenant with their department, job title, manager,
    account status, and group memberships. This is the raw data for an access review.
 
.NOTES
    Requires: Microsoft.Graph.Authentication, Microsoft.Graph.Users
    Permissions (read-only): User.Read.All, GroupMember.Read.All
    Connect first:  Connect-MgGraph -TenantId <yourtenant>.onmicrosoft.com -Scopes "User.Read.All","GroupMember.Read.All"
    Sign-in is interactive. No passwords or secrets are stored in this script.
#>
 
param(
    [string]$OutputPath = ".\UserGroupMembership.csv"
)
 
# Stop early if not connected
if (-not (Get-MgContext)) {
    Write-Error "Not connected to Microsoft Graph. Run Connect-MgGraph first."
    return
}
 
Write-Host "Connected to tenant: $((Get-MgContext).TenantId)" -ForegroundColor Cyan
 
$users = Get-MgUser -All -Property Id, DisplayName, UserPrincipalName, Department, JobTitle, AccountEnabled
 
$report = foreach ($user in $users) {
 
    # Manager (blank if none is set)
    $managerName = ""
    try {
        $manager = Get-MgUserManager -UserId $user.Id -ErrorAction Stop
        $managerName = $manager.AdditionalProperties['displayName']
    }
    catch {
        $managerName = ""
    }
 
    # Group memberships only (skips directory roles)
    $groups = Get-MgUserMemberOf -UserId $user.Id -All |
        Where-Object { $_.AdditionalProperties['@odata.type'] -eq '#microsoft.graph.group' }
 
    # One row per user per group
    $groupNames = @($groups | ForEach-Object { $_.AdditionalProperties['displayName'] })
    if ($groupNames.Count -eq 0) { $groupNames = @('(no groups)') }
 
    foreach ($groupName in $groupNames) {
        [PSCustomObject]@{
            DisplayName       = $user.DisplayName
            UserPrincipalName = $user.UserPrincipalName
            Department        = $user.Department
            JobTitle          = $user.JobTitle
            Manager           = $managerName
            AccountEnabled    = $user.AccountEnabled
            Group             = $groupName
        }
    }
}
 
$report = $report | Sort-Object DisplayName, Group
 
$report | Export-Csv -Path $OutputPath -NoTypeInformation
$report | Format-Table DisplayName, Department, JobTitle, Manager, AccountEnabled, Group -AutoSize
 
Write-Host "Exported $($report.Count) rows for $($users.Count) users to $OutputPath" -ForegroundColor Green
 