<#
.SYNOPSIS
    Builds a username from a full name: first initial + last name, lowercase,
    accents converted to plain letters, and a number added if the name is taken.

.EXAMPLE
    New-LabUsername -FullName "Amjad Khan"                                   # akhan
    New-LabUsername -FullName "Amjad Khan" -Existing @('akhan')              # akhan2
    New-LabUsername -FullName "José Díaz"                                    # jdiaz

.NOTES
    Load it into the session first (dot-source):  . .\New-LabUsername.ps1
    Uses the last word as the surname, so multi-word surnames like "de la Cruz"
    come out as the final word only. Separate first and last name fields from HR avoid that.
#>
function New-LabUsername {
    param(
        [string]$FullName,
        [string[]]$Existing = @()   # usernames already taken
    )

    # Split on one or more spaces; first word and last word
    $parts = $FullName.Trim() -split '\s+'
    $first = $parts[0]
    $last  = $parts[-1]

    # First initial + last name, lowercase, then convert accents (é to e)
    $username = ($first.Substring(0,1) + $last).ToLower()
    $username = $username.Normalize('FormD') -replace '\p{Mn}', ''

    # If taken, try akhan2, akhan3, ... until one is free
    $candidate = $username
    $n = 2
    while ($Existing -contains $candidate) {
        $candidate = "$username$n"
        $n++
    }
    return $candidate
}
