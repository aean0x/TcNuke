#Requires -RunAsAdministrator
# purge_beckhoff_files.ps1 — Finds and removes all Beckhoff / TwinCAT filesystem remnants
# Phase 1: Known fixed paths (instant)
# Phase 2: Targeted scans (drivers, VS extensions, NuGet, temp, etc.)
# Phase 3: Optional full-disk sweep via `dir /s /b /ad`

$ErrorActionPreference = "Stop"

# ── Phase 1: Known fixed paths ──────────────────────────────────────────────

$knownPaths = @(
    # Primary installations
    "C:\TwinCAT",
    "C:\TcXaeShell",
    "${env:ProgramFiles}\Beckhoff",
    "${env:ProgramFiles(x86)}\Beckhoff",
    "${env:ProgramData}\Beckhoff",
    "${env:ProgramData}\TwinCAT",
    "${env:ProgramFiles}\Common Files\Beckhoff",
    "${env:ProgramFiles(x86)}\Common Files\Beckhoff",
    "${env:ProgramFiles}\Common Files\TwinCAT",
    "${env:ProgramFiles(x86)}\Common Files\TwinCAT",

    # Per-user data
    "${env:APPDATA}\Beckhoff",
    "${env:APPDATA}\TwinCAT",
    "${env:LOCALAPPDATA}\Beckhoff",
    "${env:LOCALAPPDATA}\TwinCAT",

    # Temp installer artifacts
    "${env:TEMP}\Beckhoff",
    "${env:TEMP}\TwinCAT",
    "${env:TEMP}\TcXaeShell",

    # User documents
    "${env:USERPROFILE}\Documents\TwinCAT",
    "${env:USERPROFILE}\Documents\Beckhoff",
    "${env:USERPROFILE}\Documents\TcXaeShell Projects",

    # Start menu shortcuts
    "${env:ProgramData}\Microsoft\Windows\Start Menu\Programs\Beckhoff",
    "${env:ProgramData}\Microsoft\Windows\Start Menu\Programs\TwinCAT",
    "${env:ProgramData}\Microsoft\Windows\Start Menu\Programs\TwinCAT 3",
    "${env:APPDATA}\Microsoft\Windows\Start Menu\Programs\Beckhoff",
    "${env:APPDATA}\Microsoft\Windows\Start Menu\Programs\TwinCAT",

    # Desktop shortcuts
    "${env:PUBLIC}\Desktop\TwinCAT 3.lnk",
    "${env:USERPROFILE}\Desktop\TwinCAT 3.lnk",
    "${env:PUBLIC}\Desktop\TwinCAT XAE Shell.lnk",
    "${env:USERPROFILE}\Desktop\TwinCAT XAE Shell.lnk"
)

# ── Phase 2: Pattern-scanned directories (targeted, fast) ───────────────────

$namePatterns = @("Beckhoff", "TwinCAT", "TcXae", "TcSys", "TcAds", "TcRoute", "TcPnScanner", "TcEtherCAT", "TcPkg")

# Parent dirs to scan for matching children (depth 1-2 only)
$scanTargets = @(
    @{ Path = "${env:SystemRoot}\System32\drivers";               Depth = 1; Type = "files"  },
    @{ Path = "${env:SystemRoot}\SysWOW64";                       Depth = 1; Type = "files"  },
    @{ Path = "${env:SystemRoot}\System32\DriverStore\FileRepository"; Depth = 1; Type = "dirs" },
    @{ Path = "${env:LOCALAPPDATA}\Microsoft\VisualStudio";       Depth = 4; Type = "dirs"   },
    @{ Path = "${env:USERPROFILE}\.nuget\packages";               Depth = 1; Type = "dirs"   },
    @{ Path = "${env:ProgramFiles}\dotnet\sdk\NuGetFallbackFolder"; Depth = 1; Type = "dirs" },
    @{ Path = "${env:ProgramData}\Package Cache";                 Depth = 2; Type = "dirs"   },
    @{ Path = "${env:SystemRoot}\Installer";                      Depth = 1; Type = "files"  },
    @{ Path = "${env:SystemRoot}\Prefetch";                       Depth = 1; Type = "files"  }
)

function Test-NameMatch($name)
{
    foreach ($pattern in $namePatterns)
    {
        if ($name -match [regex]::Escape($pattern))
        { return $true
        }
    }
    return $false
}

function Find-MatchesInTarget($target)
{
    $results = [System.Collections.Generic.List[string]]::new()
    $path = $target.Path
    $depth = $target.Depth
    $type = $target.Type

    if (-not (Test-Path $path))
    { return $results
    }

    try
    {
        $items = if ($type -eq "files")
        {
            Get-ChildItem -Path $path -Depth $depth -File -ErrorAction SilentlyContinue
        } else
        {
            Get-ChildItem -Path $path -Depth $depth -Directory -ErrorAction SilentlyContinue
        }
    } catch
    {
        return $results
    }

    foreach ($item in $items)
    {
        if (Test-NameMatch $item.Name)
        {
            $results.Add($item.FullName)
        }
    }

    return $results
}

# ── Phase 3: Full-disk sweep (parallel, single pass per drive) ──────────────

function Find-AllDriveMatches
{
    $drives = Get-PSDrive -PSProvider FileSystem | Where-Object { $_.Used -ne $null } | ForEach-Object { "$($_.Root)" }

    # Build combined regex once: Beckhoff|TwinCAT|TcXae|...
    $combinedPattern = ($namePatterns | ForEach-Object { [regex]::Escape($_) }) -join "|"

    Write-Host "  Launching parallel scan across $($drives.Count) drive(s)..." -ForegroundColor DarkGray

    $jobs = foreach ($drive in $drives)
    {
        Write-Host "    -> $drive" -ForegroundColor DarkGray
        Start-ThreadJob -ArgumentList $drive, $combinedPattern -ScriptBlock {
            param($drv, $pattern)
            $found = [System.Collections.Generic.List[string]]::new()
            $lines = cmd /c "dir `"$drv`" /s /b /ad 2>nul"
            foreach ($line in $lines)
            {
                if ($line -match $pattern -and $line -notmatch "\\Windows\\(WinSxS|servicing|assembly)")
                {
                    $found.Add($line)
                }
            }
            return $found
        }
    }

    Write-Host "  Waiting for $($jobs.Count) job(s)..." -ForegroundColor DarkGray

    $results = [System.Collections.Generic.HashSet[string]]::new([System.StringComparer]::OrdinalIgnoreCase)
    foreach ($job in $jobs)
    {
        $jobResults = Receive-Job -Job $job -Wait -AutoRemoveJob
        foreach ($item in $jobResults)
        {
            [void]$results.Add($item)
        }
    }

    return $results
}

# ── Environment variable check ──────────────────────────────────────────────

function Find-EnvPathEntries
{
    $entries = [System.Collections.Generic.List[string]]::new()

    $pathVar = [Environment]::GetEnvironmentVariable("PATH", "Machine")
    if ($pathVar)
    {
        foreach ($segment in $pathVar.Split(";", [System.StringSplitOptions]::RemoveEmptyEntries))
        {
            if (Test-NameMatch $segment)
            { $entries.Add("[Machine PATH] $segment")
            }
        }
    }

    $pathVar = [Environment]::GetEnvironmentVariable("PATH", "User")
    if ($pathVar)
    {
        foreach ($segment in $pathVar.Split(";", [System.StringSplitOptions]::RemoveEmptyEntries))
        {
            if (Test-NameMatch $segment)
            { $entries.Add("[User PATH] $segment")
            }
        }
    }

    # Check for dedicated Beckhoff/TwinCAT env vars
    foreach ($scope in @("Machine", "User"))
    {
        $vars = [Environment]::GetEnvironmentVariables($scope)
        foreach ($key in $vars.Keys)
        {
            if ((Test-NameMatch $key) -or (Test-NameMatch $vars[$key]))
            {
                $entries.Add("[$scope ENV] $key = $($vars[$key])")
            }
        }
    }

    return $entries
}

# ── Windows services check ──────────────────────────────────────────────────

function Find-BeckhoffServices
{
    $services = [System.Collections.Generic.List[string]]::new()
    Get-CimInstance -ClassName Win32_Service -ErrorAction SilentlyContinue | ForEach-Object {
        if ((Test-NameMatch $_.Name) -or (Test-NameMatch $_.DisplayName) -or ($_.PathName -and (Test-NameMatch $_.PathName)))
        {
            $services.Add("$($_.Name) [$($_.State)] -> $($_.PathName)")
        }
    }
    return $services
}

# ── Scheduled tasks check ───────────────────────────────────────────────────

function Find-BeckhoffTasks
{
    $tasks = [System.Collections.Generic.List[string]]::new()
    Get-ScheduledTask -ErrorAction SilentlyContinue | ForEach-Object {
        if ((Test-NameMatch $_.TaskName) -or (Test-NameMatch $_.TaskPath))
        {
            $tasks.Add("$($_.TaskPath)$($_.TaskName)")
        }
    }
    return $tasks
}

# ── Main ────────────────────────────────────────────────────────────────────

Write-Host "`n=== Beckhoff / TwinCAT Filesystem Cleanup ===" -ForegroundColor Cyan

# Phase 1
Write-Host "`n[Phase 1] Checking known installation paths..." -ForegroundColor Yellow
$foundPaths = [System.Collections.Generic.List[string]]::new()
foreach ($path in $knownPaths)
{
    if (Test-Path $path)
    {
        $item = Get-Item $path -Force -ErrorAction SilentlyContinue
        $size = ""
        if ($item -is [System.IO.DirectoryInfo])
        {
            try
            {
                $bytes = (Get-ChildItem $path -Recurse -Force -ErrorAction SilentlyContinue | Measure-Object -Property Length -Sum).Sum
                if ($bytes)
                { $size = " ({0:N1} MB)" -f ($bytes / 1MB)
                }
            } catch
            {
            }
        }
        Write-Host "  FOUND: $path$size" -ForegroundColor Red
        $foundPaths.Add($path)
    }
}
if ($foundPaths.Count -eq 0)
{ Write-Host "  None found." -ForegroundColor Green
}

# Phase 2
Write-Host "`n[Phase 2] Scanning targeted directories..." -ForegroundColor Yellow
$scannedMatches = [System.Collections.Generic.List[string]]::new()
foreach ($target in $scanTargets)
{
    $label = $target.Path
    if (-not (Test-Path $target.Path))
    { continue
    }

    Write-Host "  Scanning: $label" -ForegroundColor DarkGray
    $matches = Find-MatchesInTarget $target
    foreach ($m in $matches)
    {
        if ($m -notin $foundPaths -and $m -notin $scannedMatches)
        {
            Write-Host "  FOUND: $m" -ForegroundColor Red
            $scannedMatches.Add($m)
        }
    }
}
if ($scannedMatches.Count -eq 0)
{ Write-Host "  None found." -ForegroundColor Green
}

# Services
Write-Host "`n[Check] Windows services..." -ForegroundColor Yellow
$services = Find-BeckhoffServices
foreach ($svc in $services)
{ Write-Host "  SERVICE: $svc" -ForegroundColor Magenta
}
if ($services.Count -eq 0)
{ Write-Host "  None found." -ForegroundColor Green
}

# Scheduled tasks
Write-Host "`n[Check] Scheduled tasks..." -ForegroundColor Yellow
$tasks = Find-BeckhoffTasks
foreach ($task in $tasks)
{ Write-Host "  TASK: $task" -ForegroundColor Magenta
}
if ($tasks.Count -eq 0)
{ Write-Host "  None found." -ForegroundColor Green
}

# Environment variables
Write-Host "`n[Check] Environment variables..." -ForegroundColor Yellow
$envEntries = Find-EnvPathEntries
foreach ($entry in $envEntries)
{ Write-Host "  ENV: $entry" -ForegroundColor Magenta
}
if ($envEntries.Count -eq 0)
{ Write-Host "  None found." -ForegroundColor Green
}

# Phase 3 prompt
Write-Host ""
$runFullScan = Read-Host "Run full-disk sweep? This is thorough but slow (y/N)"

$diskMatches = [System.Collections.Generic.List[string]]::new()
if ($runFullScan -eq "y")
{
    Write-Host "`n[Phase 3] Full-disk directory sweep..." -ForegroundColor Yellow
    $diskMatches = Find-AllDriveMatches

    # Deduplicate against already-found
    $newDisk = [System.Collections.Generic.List[string]]::new()
    foreach ($d in $diskMatches)
    {
        $dominated = $false
        foreach ($existing in ($foundPaths + $scannedMatches))
        {
            if ($d.StartsWith($existing, [System.StringComparison]::OrdinalIgnoreCase))
            {
                $dominated = $true
                break
            }
        }
        if (-not $dominated -and $d -notin $foundPaths -and $d -notin $scannedMatches)
        {
            Write-Host "  FOUND: $d" -ForegroundColor Red
            $newDisk.Add($d)
        }
    }
    $diskMatches = $newDisk

    if ($diskMatches.Count -eq 0)
    { Write-Host "  No additional paths found." -ForegroundColor Green
    }
}

# ── Deletion ────────────────────────────────────────────────────────────────

$allFiles = [System.Collections.Generic.List[string]]::new()
foreach ($p in $foundPaths)
{ [void]$allFiles.Add($p)
}
foreach ($p in $scannedMatches)
{ [void]$allFiles.Add($p)
}
foreach ($p in $diskMatches)
{ [void]$allFiles.Add($p)
}

# Prune children whose parents are already in the list
$pruned = [System.Collections.Generic.List[string]]::new()
$sorted = $allFiles | Sort-Object
foreach ($path in $sorted)
{
    $isChild = $false
    foreach ($existing in $pruned)
    {
        if ($path.StartsWith("$existing\", [System.StringComparison]::OrdinalIgnoreCase))
        {
            $isChild = $true
            break
        }
    }
    if (-not $isChild)
    { $pruned.Add($path)
    }
}

if ($pruned.Count -eq 0)
{
    Write-Host "`nSystem is clean — no Beckhoff / TwinCAT filesystem remnants found." -ForegroundColor Green
    exit 0
}

Write-Host "`n────────────────────────────────────────────" -ForegroundColor Cyan
Write-Host "Summary: $($pruned.Count) top-level paths to delete" -ForegroundColor Yellow
Write-Host ""
foreach ($p in $pruned)
{ Write-Host "  $p" -ForegroundColor White
}

if ($services.Count -gt 0)
{
    Write-Host "`n  WARNING: $($services.Count) service(s) detected — stop/delete them first:" -ForegroundColor Red
    foreach ($svc in $services)
    { Write-Host "    $svc" -ForegroundColor DarkYellow
    }
}

if ($envEntries.Count -gt 0)
{
    Write-Host "`n  WARNING: $($envEntries.Count) environment variable(s) reference Beckhoff/TwinCAT" -ForegroundColor Red
    Write-Host "  These must be cleaned manually or with a separate registry edit." -ForegroundColor DarkYellow
}

Write-Host ""
$confirm = Read-Host "Delete all $($pruned.Count) paths? (y/N)"
if ($confirm -ne "y")
{
    Write-Host "Aborted." -ForegroundColor Red
    exit 1
}

Write-Host ""
$deleted = 0
$failed  = 0

foreach ($path in $pruned)
{
    try
    {
        if (Test-Path $path)
        {
            $item = Get-Item $path -Force -ErrorAction SilentlyContinue
            if ($item -is [System.IO.DirectoryInfo])
            {
                Remove-Item -Path $path -Recurse -Force -ErrorAction Stop
            } else
            {
                Remove-Item -Path $path -Force -ErrorAction Stop
            }
            Write-Host "  Deleted: $path" -ForegroundColor Green
            $deleted++
        } else
        {
            Write-Host "  Gone:    $path" -ForegroundColor DarkYellow
        }
    } catch
    {
        # Retry with cmd /c rd for stubborn directories
        if (Test-Path $path -PathType Container)
        {
            $rdResult = cmd /c "rd /s /q `"$path`"" 2>&1
            if (-not (Test-Path $path))
            {
                Write-Host "  Deleted (rd): $path" -ForegroundColor Green
                $deleted++
                continue
            }
        }
        Write-Warning "  Failed: $path - $($_.Exception.Message)"
        $failed++
    }
}

Write-Host "`nDone. Deleted: $deleted | Failed: $failed" -ForegroundColor Cyan

if ($envEntries.Count -gt 0)
{
    Write-Host ""
    $cleanEnv = Read-Host "Clean Beckhoff/TwinCAT entries from PATH environment variables? (y/N)"
    if ($cleanEnv -eq "y")
    {
        foreach ($scope in @("Machine", "User"))
        {
            $pathVar = [Environment]::GetEnvironmentVariable("PATH", $scope)
            if (-not $pathVar)
            { continue
            }

            $segments = $pathVar.Split(";", [System.StringSplitOptions]::RemoveEmptyEntries)
            $cleaned = $segments | Where-Object { -not (Test-NameMatch $_) }
            $newPath = ($cleaned -join ";")

            if ($newPath -ne $pathVar)
            {
                [Environment]::SetEnvironmentVariable("PATH", $newPath, $scope)
                $removedCount = $segments.Count - $cleaned.Count
                Write-Host "  Removed $removedCount entries from $scope PATH" -ForegroundColor Green
            }
        }

        # Remove dedicated env vars
        foreach ($scope in @("Machine", "User"))
        {
            $vars = [Environment]::GetEnvironmentVariables($scope)
            foreach ($key in @($vars.Keys))
            {
                if ($key -eq "PATH")
                { continue
                }

                if ((Test-NameMatch $key) -or (Test-NameMatch $vars[$key]))
                {
                    [Environment]::SetEnvironmentVariable($key, $null, $scope)
                    Write-Host "  Removed $scope env var: $key" -ForegroundColor Green
                }
            }
        }

        Write-Host "`nEnvironment cleaned." -ForegroundColor Cyan
    }
}
