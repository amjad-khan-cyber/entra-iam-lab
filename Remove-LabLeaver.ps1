<#
.SYNOPSIS
    Offboards one leaver, found by employee ID: disables the account, revokes sign-in sessions,
    removes group memberships, and logs every step with the ticket number.
    Runs in PREVIEW mode by default and changes nothing. Add -Apply to make the changes.

.NOTES
    Permissions: User.ReadWrite.All, GroupMember.ReadWrite.All, User.RevokeSessions.All
    Connect:     Connect-MgGraph -Scopes "User.ReadWrite.All","GroupMember.ReadWrite.All","User.RevokeSessions.All"
    Preview:     .\Remove-LabLeaver.ps1 -EmployeeId E1002 -Ticket INC-12345
    Apply:       .\Remove-LabLeaver.ps1 -EmployeeId E1002 -Ticket INC-12345 -Apply
#>

param(
    [Parameter(Mandatory)]
    [string]$EmployeeId,
    [Parameter(Mandatory)]
    [string]$Ticket,
    [string]$LogPath = ".\leaver-log.csv",
    [string[]]$SkipGroups = @('Default Directory'),   # groups managed by the tenant, not by IT
    [switch]$Apply
)

# ---- Checks before anything else ----
if (-not (Get-MgContext)) { Write-Error "Not connected to Microsoft Graph. Run Connect-MgGraph first."; return }
$required = 'User.ReadWrite.All','GroupMember.ReadWrite.All','User.RevokeSessions.All'
$missing  = $required | Where-Object { (Get-MgContext).Scopes -notcontains $_ }
if ($missing) { Write-Error "Missing Graph scopes: $($missing -join ', ')"; return }

$mode = if ($Apply) { 'APPLIED' } else { 'PREVIEW' }
$script:upn = ''

function Write-Log {
    param([string]$Step)
    [PSCustomObject]@{
        Timestamp  = (Get-Date).ToString('yyyy-MM-dd HH:mm:ss')
        Mode       = $mode
        Ticket     = $Ticket
        EmployeeId = $EmployeeId
        User       = $script:upn
        Step       = $Step
    } | Export-Csv -Path $LogPath -NoTypeInformation -Append
    Write-Host "  [$mode] $Step"
}

# ---- 1. Find exactly one user ----
$safe  = $EmployeeId.Trim().Replace("'", "''")
$users = @(Get-MgUser -Filter "employeeId eq '$safe'" -Property Id, DisplayName, UserPrincipalName, AccountEnabled)
if ($users.Count -ne 1) {
    Write-Log "STOPPED: found $($users.Count) users with employee ID $EmployeeId, expected exactly 1"
    return
}
$user = $users[0]
$script:upn = $user.UserPrincipalName
Write-Host "Mode: $mode   Leaver: $($user.DisplayName) ($EmployeeId)   Ticket: $Ticket" -ForegroundColor $(if ($Apply) { 'Red' } else { 'Cyan' })

# ---- 2. Snapshot group memberships before changing anything ----
$groups = @(Get-MgUserMemberOf -UserId $user.Id -All |
    Where-Object { $_.AdditionalProperties['@odata.type'] -eq '#microsoft.graph.group' })
$names = ($groups | ForEach-Object { $_.AdditionalProperties['displayName'] }) -join '; '
Write-Log "SNAPSHOT: member of $($groups.Count) group(s): $names"

# ---- 3. Disable the account (blocks new sign-ins) ----
if ($user.AccountEnabled -eq $false) {
    Write-Log 'Account already disabled'
}
else {
    Write-Log 'Disable account'
    if ($Apply) {
        try   { Update-MgUser -UserId $user.Id -AccountEnabled:$false }
        catch { Write-Log "FAILED to disable, stopping: $($_.Exception.Message)"; return }
    }
}

# ---- 4. Revoke sessions (kills refresh tokens already issued) ----
Write-Log 'Revoke sign-in sessions'
if ($Apply) {
    try   { Revoke-MgUserSignInSession -UserId $user.Id | Out-Null }
    catch { Write-Log "FAILED to revoke sessions: $($_.Exception.Message)" }
}

# ---- 5. Remove group memberships, one at a time ----
foreach ($g in $groups) {
    $gName = $g.AdditionalProperties['displayName']
    $types = @($g.AdditionalProperties['groupTypes'])

    if ($types -contains 'DynamicMembership') { Write-Log "SKIP: $gName (dynamic group, can't remove by hand. Removed only if its rule excludes disabled users, and not instantly: verify later)"; continue }
    if ($SkipGroups -contains $gName)         { Write-Log "SKIP: $gName (managed by the tenant)"; continue }

    Write-Log "Remove from $gName"
    if ($Apply) {
        try   { Remove-MgGroupMemberByRef -GroupId $g.Id -DirectoryObjectId $user.Id }
        catch { Write-Log "FAILED to remove from ${gName}: $($_.Exception.Message)" }
    }
}

Write-Host ""
if ($Apply) { Write-Host "Done. Every step logged to $LogPath" -ForegroundColor Green }
else        { Write-Host "Preview only. Nothing was changed. Run again with -Apply to offboard." -ForegroundColor Green }
