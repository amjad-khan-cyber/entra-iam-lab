<#
.SYNOPSIS
    Processes joiner, mover, and leaver events from an HR feed CSV.
    Runs in PREVIEW mode by default and changes nothing. Add -Apply to make the changes.

.NOTES
    Modules:     Microsoft.Graph.Authentication, Microsoft.Graph.Users,
                 Microsoft.Graph.Groups, Microsoft.Graph.Users.Actions
    Permissions: User.ReadWrite.All, GroupMember.ReadWrite.All, User.RevokeSessions.All
    Connect:     Connect-MgGraph -TenantId <tenant>.onmicrosoft.com -Scopes "User.ReadWrite.All","GroupMember.ReadWrite.All","User.RevokeSessions.All"
    Preview:     .\Invoke-JML.ps1 -Domain <tenant>.onmicrosoft.com
    Apply:       .\Invoke-JML.ps1 -Domain <tenant>.onmicrosoft.com -Apply
#>

param(
    [Parameter(Mandatory)]
    [string]$Domain,
    [string]$FeedPath = ".\hr-feed.csv",
    [string]$LogPath  = ".\jml-log.csv",
    [string]$ProcessedPath = ".\hr-feed-processed.csv",
    [switch]$Apply
)

if (-not (Get-MgContext)) { Write-Error "Not connected to Microsoft Graph. Run Connect-MgGraph first."; return }
if (-not (Test-Path $FeedPath)) { Write-Error "HR feed not found: $FeedPath"; return }

$mode = if ($Apply) { 'APPLIED' } else { 'PREVIEW' }
Write-Host "Mode: $mode" -ForegroundColor $(if ($Apply) { 'Red' } else { 'Cyan' })

# ---- Role-based access: groups each department gets automatically (birthright) ----
# Sensitive groups (IT-Admins, AP-*) are never granted here; they need a separate approved request.
$birthrightGroups = @{
    'Finance' = @('Finance-Share')
    'Sales'   = @('Sales-Share')
    'IT'      = @()
}
$allBirthright = $birthrightGroups.Values | ForEach-Object { $_ }

# ---- Helpers ----

function Write-Log {
    param($Action, $User, $Change)
    [PSCustomObject]@{
        Timestamp = (Get-Date).ToString('yyyy-MM-dd HH:mm:ss')
        Mode      = $mode
        Action    = $Action
        User      = $User
        Change    = $Change
    } | Export-Csv -Path $LogPath -NoTypeInformation -Append
    Write-Host "  [$mode] $Change"

    # Rows that failed or were skipped for bad data stay in the feed for a person to fix
    if ($Change -like 'FAILED*' -or ($Change -like 'SKIPPED*' -and $Change -notlike '*already exists*')) {
        $script:keepRow = $true
    }
}

# Logs the step, then returns $true only when -Apply was used
function Confirm-Step {
    param($Action, $User, $Change)
    Write-Log $Action $User $Change
    return [bool]$Apply
}

function Find-User {
    param([string]$Name)
    $safe = $Name.Replace("'", "''")
    Get-MgUser -Filter "displayName eq '$safe'" -Property Id, DisplayName, UserPrincipalName, Department, AccountEnabled
}

function Find-Group {
    param([string]$Name)
    $safe = $Name.Replace("'", "''")
    Get-MgGroup -Filter "displayName eq '$safe'"
}

function Get-UserGroups {
    param([string]$UserId)
    Get-MgUserMemberOf -UserId $UserId -All |
        Where-Object { $_.AdditionalProperties['@odata.type'] -eq '#microsoft.graph.group' } |
        ForEach-Object { [PSCustomObject]@{ Id = $_.Id; Name = $_.AdditionalProperties['displayName'] } }
}

function Set-Manager {
    param([string]$UserId, [string]$ManagerId)
    Set-MgUserManagerByRef -UserId $UserId -BodyParameter @{ '@odata.id' = "https://graph.microsoft.com/v1.0/users/$ManagerId" }
}

# ---- Process the HR feed ----

$feed = Import-Csv -Path $FeedPath
$processed = New-Object System.Collections.Generic.List[object]
$remaining = New-Object System.Collections.Generic.List[object]

foreach ($row in $feed) {
    $script:keepRow = $false
    $action = $row.Action.Trim()
    $name   = $row.DisplayName.Trim()
    Write-Host ""
    Write-Host "== $action : $name ==" -ForegroundColor Yellow

    try {
        switch ($action) {

            'Join' {
                if (Find-User $name) { Write-Log 'Join' $name 'SKIPPED: user already exists'; break }
                if (-not $birthrightGroups.ContainsKey($row.Department)) {
                    Write-Log 'Join' $name "SKIPPED: no access rules for department '$($row.Department)'"; break
                }

                $manager  = if ($row.Manager) { Find-User $row.Manager.Trim() } else { $null }
                $nickname = (($name.Normalize([Text.NormalizationForm]::FormD) -replace '\p{Mn}', '').ToLower() -replace '[^a-z ]', '') -replace ' ', '.'
                $upn      = "$nickname@$Domain"
                $newUser  = $null

                if (Confirm-Step 'Join' $name "Create account $upn ($($row.Department), $($row.JobTitle))") {
                    $password = (-join ((48..57) + (65..90) + (97..122) | Get-Random -Count 16 | ForEach-Object { [char]$_ })) + 'Aa1!'
                    $newUser = New-MgUser -DisplayName $name -UserPrincipalName $upn -MailNickname $nickname `
                        -AccountEnabled:$true -Department $row.Department -JobTitle $row.JobTitle `
                        -PasswordProfile @{ Password = $password; ForceChangePasswordNextSignIn = $true }
                    Start-Sleep -Seconds 10   # give the new account time to be available before changing it
                }

                if ($manager) {
                    if (Confirm-Step 'Join' $name "Set manager to $($manager.DisplayName)") {
                        Set-Manager $newUser.Id $manager.Id
                    }
                }

                foreach ($g in $birthrightGroups[$row.Department]) {
                    $grp = Find-Group $g
                    if (Confirm-Step 'Join' $name "Add to $g (birthright for $($row.Department))") {
                        New-MgGroupMember -GroupId $grp.Id -DirectoryObjectId $newUser.Id
                    }
                }
            }

            'Move' {
                $user = Find-User $name
                if (-not $user) { Write-Log 'Move' $name 'SKIPPED: user not found'; break }
                if (-not $birthrightGroups.ContainsKey($row.Department)) {
                    Write-Log 'Move' $name "SKIPPED: no access rules for department '$($row.Department)'"; break
                }

                $newDept   = $row.Department
                $manager   = if ($row.Manager) { Find-User $row.Manager.Trim() } else { $null }
                $newGroups = @($birthrightGroups[$newDept])
                $current   = @(Get-UserGroups $user.Id)

                if (Confirm-Step 'Move' $name "Department $($user.Department) -> $newDept, title -> $($row.JobTitle)") {
                    Update-MgUser -UserId $user.Id -Department $newDept -JobTitle $row.JobTitle
                }

                if ($manager) {
                    if (Confirm-Step 'Move' $name "Set manager to $($manager.DisplayName)") {
                        Set-Manager $user.Id $manager.Id
                    }
                }

                # Add the new department's birthright groups
                foreach ($g in $newGroups) {
                    if ($current.Name -contains $g) { Write-Log 'Move' $name "Already in $g"; continue }
                    $grp = Find-Group $g
                    if (Confirm-Step 'Move' $name "Add to $g (birthright for $newDept)") {
                        New-MgGroupMember -GroupId $grp.Id -DirectoryObjectId $user.Id
                    }
                }

                # Remove old department access; flag requested access for review instead of removing it
                foreach ($cg in $current) {
                    if ($cg.Name -in $allBirthright -and $cg.Name -notin $newGroups) {
                        if (Confirm-Step 'Move' $name "Remove from $($cg.Name) (old department access)") {
                            Remove-MgGroupMemberByRef -GroupId $cg.Id -DirectoryObjectId $user.Id
                        }
                    }
                    elseif ($cg.Name -notin $allBirthright) {
                        Write-Log 'Move' $name "REVIEW: still in $($cg.Name) (requested access, confirm with group owner)"
                    }
                }
            }

            'Leave' {
                $user = Find-User $name
                if (-not $user) { Write-Log 'Leave' $name 'SKIPPED: user not found'; break }

                if (Confirm-Step 'Leave' $name 'Disable account') {
                    Update-MgUser -UserId $user.Id -AccountEnabled:$false
                }

                if (Confirm-Step 'Leave' $name 'Revoke sign-in sessions') {
                    Revoke-MgUserSignInSession -UserId $user.Id | Out-Null
                }

                foreach ($cg in @(Get-UserGroups $user.Id)) {
                    if (Confirm-Step 'Leave' $name "Remove from $($cg.Name)") {
                        Remove-MgGroupMemberByRef -GroupId $cg.Id -DirectoryObjectId $user.Id
                    }
                }
            }

            default {
                Write-Log $action $name 'SKIPPED: unknown action'
            }
        }
    }
    catch {
        Write-Log $action $name "FAILED: $($_.Exception.Message)"
    }

    if ($script:keepRow) { $remaining.Add($row) } else { $processed.Add($row) }
}

# ---- Archive finished rows (only when changes were applied) ----

if ($Apply) {
    $today = (Get-Date).ToString('yyyy-MM-dd')
    if ($processed.Count -gt 0) {
        $processed | Select-Object Action, DisplayName, Department, JobTitle, Manager, @{ n = 'ProcessedDate'; e = { $today } } |
            Export-Csv -Path $ProcessedPath -NoTypeInformation -Append -Encoding utf8 -UseQuotes AsNeeded
    }
    if ($remaining.Count -gt 0) {
        $remaining | Export-Csv -Path $FeedPath -NoTypeInformation -Encoding utf8 -UseQuotes AsNeeded
    }
    else {
        Set-Content -Path $FeedPath -Value 'Action,DisplayName,Department,JobTitle,Manager' -Encoding utf8
    }
    Write-Host ""
    Write-Host "$($processed.Count) row(s) moved to $ProcessedPath, $($remaining.Count) left in $FeedPath for review" -ForegroundColor Green
}

Write-Host ""
if ($Apply) {
    Write-Host "Done. Changes logged to $LogPath" -ForegroundColor Green
}
else {
    Write-Host "Preview only. Nothing was changed. Review the steps above, then run again with -Apply." -ForegroundColor Cyan
}