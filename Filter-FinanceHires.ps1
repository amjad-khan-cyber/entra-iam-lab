# Step 8: filter Finance new hires and add a StartDate column
$hires = Import-Csv .\new-hires.csv

# Data quality check: rows with no department
$bad = $hires | Where-Object { -not $_.Department }
if ($bad) { Write-Warning "Rows with no department: $($bad.FirstName -join ', ')" }

$hires | Where-Object { $_.Department -eq 'Finance' } |
  Select-Object FirstName, LastName, JobTitle, @{Name='StartDate'; Expression={'2026-11-16'}} |
  Export-Csv .\finance-hires.csv -NoTypeInformation -Encoding utf8

Import-Csv .\finance-hires.csv | Format-Table
