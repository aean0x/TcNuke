#Requires -RunAsAdministrator
# purge_beckhoff_registry.ps1 — Removes all Beckhoff / TwinCAT registry keys
# Uses native `reg query /s /f` for fast recursive discovery, PowerShell for deletion

$ErrorActionPreference = "Stop"

$searchTerms = @("Beckhoff", "TwinCAT", "TcSys", "TcRoute", "TcAds", "TcXae", "TcPnScanner", "TcPkg")

$hives = @(
    "HKLM\SOFTWARE",
    "HKLM\SYSTEM\CurrentControlSet\Services",
    "HKCU\SOFTWARE"
)

# Also check Uninstall keys by DisplayName value
$uninstallHives = @(
    "HKLM\SOFTWARE\Microsoft\Windows\CurrentVersion\Uninstall",
    "HKLM\SOFTWARE\WOW6432Node\Microsoft\Windows\CurrentVersion\Uninstall"
)

function Find-RegistryKeys
{
    $results = [System.Collections.Generic.HashSet[string]]::new([System.StringComparer]::OrdinalIgnoreCase)

    foreach ($hive in $hives)
    {
        foreach ($term in $searchTerms)
        {
            Write-Host "  reg query $hive /s /f `"$term`" /k" -ForegroundColor DarkGray
            $output = reg query $hive /s /f $term /k 2>$null
            if ($LASTEXITCODE -ne 0 -or -not $output)
            { continue
            }

            foreach ($line in $output)
            {
                $trimmed = $line.Trim()
                if ($trimmed -match "^(HKLM|HKCU|HKU|HKCR)\\")
                {
                    [void]$results.Add($trimmed)
                }
            }
        }
    }

    # Check Uninstall keys by DisplayName value
    foreach ($uHive in $uninstallHives)
    {
        foreach ($term in $searchTerms)
        {
            Write-Host "  reg query $uHive /s /f `"$term`" /d /e" -ForegroundColor DarkGray
            $output = reg query $uHive /s /f $term /d /e 2>$null
            if ($LASTEXITCODE -ne 0 -or -not $output)
            { continue
            }

            foreach ($line in $output)
            {
                $trimmed = $line.Trim()
                if ($trimmed -match "^(HKLM|HKCU)\\")
                {
                    [void]$results.Add($trimmed)
                }
            }
        }
    }

    return $results
}

function Remove-ParentDuplicates($keys)
{
    # If both a parent and child are matched, keep only the parent since Remove-Item -Recurse handles children
    $sorted = $keys | Sort-Object
    $pruned = [System.Collections.Generic.List[string]]::new()

    foreach ($key in $sorted)
    {
        $isChild = $false
        foreach ($existing in $pruned)
        {
            if ($key.StartsWith("$existing\", [System.StringComparison]::OrdinalIgnoreCase))
            {
                $isChild = $true
                break
            }
        }
        if (-not $isChild)
        {
            $pruned.Add($key)
        }
    }

    return $pruned
}

# Convert reg.exe paths (HKLM\...) to PowerShell paths (HKLM:\...)
function ConvertTo-PSPath($regPath)
{
    return $regPath -replace '^(HKLM|HKCU|HKU|HKCR)\\', '$1:\'
}

Write-Host "`n=== Scanning registry for Beckhoff / TwinCAT keys ===" -ForegroundColor Cyan
Write-Host ""

$rawKeys = Find-RegistryKeys

if ($rawKeys.Count -eq 0)
{
    Write-Host "`nNo Beckhoff / TwinCAT registry keys found." -ForegroundColor Green
    exit 0
}

$pruned = Remove-ParentDuplicates $rawKeys

Write-Host "`nFound $($pruned.Count) top-level matching keys ($($rawKeys.Count) total including children):`n" -ForegroundColor Yellow
foreach ($key in $pruned)
{
    Write-Host "  $key" -ForegroundColor DarkGray
}

Write-Host ""
$confirm = Read-Host "Delete all $($pruned.Count) keys (and their children)? (y/N)"
if ($confirm -ne "y")
{
    Write-Host "Aborted." -ForegroundColor Red
    exit 1
}

Write-Host ""
$deleted = 0
$failed  = 0

foreach ($key in $pruned)
{
    $psPath = ConvertTo-PSPath $key
    try
    {
        if (Test-Path $psPath)
        {
            Remove-Item -Path $psPath -Recurse -Force
            Write-Host "  Deleted: $key" -ForegroundColor Green
            $deleted++
        } else
        {
            Write-Host "  Gone:    $key" -ForegroundColor DarkYellow
        }
    } catch
    {
        # Fallback to reg.exe delete for keys PowerShell can't handle
        $regResult = reg delete $key /f 2>&1
        if ($LASTEXITCODE -eq 0)
        {
            Write-Host "  Deleted (reg.exe): $key" -ForegroundColor Green
            $deleted++
        } else
        {
            Write-Warning "  Failed: $key - $($_.Exception.Message)"
            $failed++
        }
    }
}

Write-Host "`nDone. Deleted: $deleted | Failed: $failed" -ForegroundColor Cyan
