<#
.SYNOPSIS
    Exports every Conditional Access policy to JSON, one file per policy, with user and group
    object IDs replaced by display names so the files are safe to publish.

.NOTES
    Permissions: Policy.Read.All, User.Read.All, GroupMember.Read.All (read-only)
    Connect:     Connect-MgGraph -Scopes "Policy.Read.All","User.Read.All","GroupMember.Read.All"
    Run:         .\Export-CAPolicies.ps1
#>

param([string]$OutFolder = ".\ca-policies")

if (-not (Get-MgContext)) { Write-Error "Not connected to Microsoft Graph. Run Connect-MgGraph first."; return }
$missing = 'Policy.Read.All' | Where-Object { (Get-MgContext).Scopes -notcontains $_ }
if ($missing) { Write-Error "Missing Graph scope: $missing"; return }

New-Item -ItemType Directory -Path $OutFolder -Force | Out-Null
$policies = Invoke-MgGraphRequest -Method GET -Uri 'https://graph.microsoft.com/v1.0/identity/conditionalAccess/policies' -OutputType PSObject

# Look up every user and group ID once, so each one can be swapped for its name
$cache = @{}
function Get-Name([string]$Id, [string]$Kind) {
    if ($Id -in 'All','None','GuestsOrExternalUsers') { return $Id }
    if (-not $cache.ContainsKey($Id)) {
        try {
            $obj = if ($Kind -eq 'user') { Get-MgUser -UserId $Id -Property DisplayName } else { Get-MgGroup -GroupId $Id -Property DisplayName }
            $cache[$Id] = "$Kind`: $($obj.DisplayName)"
        } catch { $cache[$Id] = "$Kind`: (not found)" }
    }
    return $cache[$Id]
}

function Remove-ODataContext($Node) {
    if ($Node -is [System.Management.Automation.PSCustomObject]) {
        foreach ($prop in @($Node.PSObject.Properties)) {
            if ($prop.Name -like '*@odata.context') { $Node.PSObject.Properties.Remove($prop.Name) }
            else { Remove-ODataContext $prop.Value }
        }
    }
    elseif ($Node -is [System.Collections.IEnumerable] -and $Node -isnot [string]) {
        foreach ($item in $Node) { Remove-ODataContext $item }
    }
}

$locations = @{}
(Invoke-MgGraphRequest -Method GET -Uri 'https://graph.microsoft.com/v1.0/identity/conditionalAccess/namedLocations' -OutputType PSObject).value |
    ForEach-Object { $locations[$_.id] = "location: $($_.displayName)" }
function Get-LocationName([string]$Id) {
    if ($Id -in 'All','AllTrusted') { return $Id }
    if ($locations.ContainsKey($Id)) { return $locations[$Id] } else { return 'location: (not found)' }
}

foreach ($p in $policies.value) {
    $u = $p.conditions.users
    $u.includeUsers  = @($u.includeUsers  | ForEach-Object { Get-Name $_ 'user' })
    $u.excludeUsers  = @($u.excludeUsers  | ForEach-Object { Get-Name $_ 'user' })
    $u.includeGroups = @($u.includeGroups | ForEach-Object { Get-Name $_ 'group' })
    $u.excludeGroups = @($u.excludeGroups | ForEach-Object { Get-Name $_ 'group' })

    # Named locations: swap each ID for the location's name
    $l = $p.conditions.locations
    if ($l) {
        $l.includeLocations = @($l.includeLocations | ForEach-Object { Get-LocationName $_ })
        $l.excludeLocations = @($l.excludeLocations | ForEach-Object { Get-LocationName $_ })
    }

    # Graph adds metadata lines that repeat the policy ID, at any depth; drop them all
    Remove-ODataContext $p

    # Fields that identify the tenant or change on every edit
    $p.PSObject.Properties.Remove('id')
    $p.PSObject.Properties.Remove('templateId')

    $file = Join-Path $OutFolder (($p.displayName -replace '[^\w\-]', '_') + '.json')
    $p | ConvertTo-Json -Depth 20 | Set-Content -Path $file -Encoding utf8
    Write-Host "Saved $file  ($($p.state))"
}

# Final check: any GUID left that isn't a well-known directory role template is reported, not hidden
$roleIds = @($policies.value.conditions.users.includeRoles + $policies.value.conditions.users.excludeRoles) | Select-Object -Unique
$left = Get-ChildItem $OutFolder -Filter *.json | Select-String -Pattern '[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}' -AllMatches |
    ForEach-Object { $_.Matches.Value } |
    Where-Object { $_ -notin $roleIds -and $_ -notlike '00000000-0000-0000-0000-00000000000*' } | Select-Object -Unique   # built-in authentication strengths are the same in every tenant
if ($left) { Write-Warning "IDs still in the files, check before publishing: $($left -join ', ')" }
else       { Write-Host "No tenant-specific IDs left. Role template and built-in authentication strength IDs are the same in every tenant." -ForegroundColor Green }
