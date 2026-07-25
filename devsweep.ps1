<#
.SYNOPSIS
  devsweep - interactive cleanup of Flutter / Node / Gradle / FVM build & cache folders.

.DESCRIPTION
  Run this from your projects parent folder (the directory that contains your
  repos), for example:

    cd ~/StudioProjects
    .\devsweep\devsweep.ps1

  It scans child projects (and common monorepo nests), lists reclaimable
  folders with sizes, then lets you delete all or pick specific entries.

  macOS / Linux twin: ./devsweep/devsweep.sh
  Docs: ./devsweep/README.md

  Targets (when present):
    Flutter  - build, .dart_tool
               + android/.gradle, android/**/build, ios/Pods, macos/Pods,
                 */flutter/ephemeral
    FVM      - .fvm/flutter_sdk, .fvm/versions  (keeps fvm_config.json / .fvmrc)
    Node     - node_modules, .next, .nuxt, .turbo, .vercel, .parcel-cache,
               .cache, coverage, .output, storybook-static, dist, out, .svelte-kit
    Gradle   - .gradle (project-local only; not ~/.gradle)

.PARAMETER Root
  Folder to scan. Default: current working directory. Must contain project(s).

.PARAMETER Apply
  Non-interactive: delete everything found after listing (CI / scripts).

.PARAMETER Force
  With -Apply, skip the YES confirmation.

.PARAMETER IncludeGlobalCaches
  Also offer user-level caches (~/.gradle/caches, ~/.pub-cache). Off by default
  because those are shared across all projects on the machine.

.EXAMPLE
  cd C:\Users\You\StudioProjects
  .\devsweep\devsweep.ps1

.EXAMPLE
  .\devsweep\devsweep.ps1 -Apply -Force
#>

[CmdletBinding()]
param(
    [string]$Root = "",
    [switch]$Apply,
    [switch]$Force,
    [switch]$IncludeGlobalCaches,
    # Hide 0-byte targets from the list (still safe; they reclaim nothing)
    [switch]$ShowEmpty
)

$ErrorActionPreference = "Continue"
$script:HadFatalError = $false
$script:ScriptDir = $PSScriptRoot
if ([string]::IsNullOrWhiteSpace($script:ScriptDir)) {
    $script:ScriptDir = Split-Path -Parent $MyInvocation.MyCommand.Path
}
$script:LastReportPath = $null

function Wait-IfInteractive {
    # Always pause unless fully non-interactive (-Apply -Force), so windows don't vanish.
    if ($Apply -and $Force) { return }
    try {
        Write-Host ""
        [void](Read-Host "Press Enter to close")
    } catch { }
}

# ---------------------------------------------------------------------------
# Helpers
# ---------------------------------------------------------------------------

function Format-Bytes {
    param([long]$Bytes)
    if ($Bytes -ge 1GB) { return "{0:N2} GB" -f ($Bytes / 1GB) }
    if ($Bytes -ge 1MB) { return "{0:N2} MB" -f ($Bytes / 1MB) }
    if ($Bytes -ge 1KB) { return "{0:N2} KB" -f ($Bytes / 1KB) }
    return "$Bytes B"
}

function Escape-Html {
    param([string]$Text)
    if ($null -eq $Text) { return "" }
    $t = "$Text"
    $t = $t.Replace("&", "&amp;")
    $t = $t.Replace("<", "&lt;")
    $t = $t.Replace(">", "&gt;")
    $t = $t.Replace('"', "&quot;")
    $t = $t.Replace("'", "&#39;")
    return $t
}

function Get-ResultStatusLabel {
    param($Result)
    if ([int]$Result.Failed -eq 0 -and [int]$Result.Deleted -gt 0) { return "SUCCESS" }
    if ([int]$Result.Failed -gt 0 -and [int]$Result.Deleted -gt 0) { return "PARTIAL SUCCESS" }
    if ([int]$Result.Failed -gt 0 -and [int]$Result.Deleted -eq 0) { return "FAILED" }
    if ([int]$Result.Deleted -eq 0 -and [int]$Result.Skipped -gt 0) { return "NOTHING TO DELETE" }
    return "NO CHANGES"
}

function Get-ResultStatusClass {
    param([string]$Label)
    switch ($Label) {
        "SUCCESS" { return "ok" }
        "PARTIAL SUCCESS" { return "warn" }
        "FAILED" { return "bad" }
        default { return "muted" }
    }
}

function New-HtmlRows {
    param(
        [object[]]$Items,
        [string]$RowClass
    )
    if ($null -eq $Items -or @($Items).Count -eq 0) {
        return "<tr class='empty'><td colspan='4'>None</td></tr>"
    }
    $rows = New-Object System.Text.StringBuilder
    foreach ($item in @($Items)) {
        [void]$rows.AppendLine((
            "<tr class='{0}'><td>{1}</td><td>{2}</td><td>{3}</td><td class='size'>{4}</td></tr>" -f
            $RowClass,
            (Escape-Html $item.Kind),
            (Escape-Html $item.Project),
            (Escape-Html $item.Path),
            (Escape-Html (Format-Bytes ([long]$item.Size)))
        ))
    }
    return $rows.ToString()
}

function Write-HtmlReport {
    param(
        $Result,
        [string]$ScanRoot
    )

    $status = Get-ResultStatusLabel -Result $Result
    $statusClass = Get-ResultStatusClass -Label $status
    $when = Get-Date -Format "yyyy-MM-dd HH:mm:ss"
    $stamp = Get-Date -Format "yyyyMMdd-HHmmss"
    $reportDir = Join-Path $script:ScriptDir "reports"
    if (-not (Test-Path -LiteralPath $reportDir)) {
        New-Item -ItemType Directory -Path $reportDir -Force | Out-Null
    }

    $deletedRows = New-HtmlRows -Items @($Result.DeletedItems) -RowClass "deleted"
    $failedRows = New-HtmlRows -Items @($Result.FailedItems) -RowClass "failed"

    $html = @"
<!DOCTYPE html>
<html lang="en">
<head>
  <meta charset="utf-8" />
  <meta name="viewport" content="width=device-width, initial-scale=1" />
  <title>devsweep report</title>
  <style>
    :root {
      --bg: #f6f7f9;
      --card: #ffffff;
      --text: #1c1f24;
      --muted: #5c6570;
      --line: #e4e7ec;
      --ok: #0f7a43;
      --ok-bg: #e8f7ee;
      --warn: #9a6700;
      --warn-bg: #fff6e0;
      --bad: #b42318;
      --bad-bg: #fef3f2;
      --accent: #1f4e79;
    }
    * { box-sizing: border-box; }
    body {
      margin: 0;
      font-family: "Segoe UI", system-ui, sans-serif;
      color: var(--text);
      background: var(--bg);
      line-height: 1.45;
    }
    main {
      max-width: 960px;
      margin: 0 auto;
      padding: 2rem 1.25rem 3rem;
    }
    h1 {
      margin: 0 0 0.25rem;
      font-size: 1.6rem;
      font-weight: 650;
    }
    .meta {
      color: var(--muted);
      margin-bottom: 1.5rem;
      font-size: 0.95rem;
    }
    .badge {
      display: inline-block;
      padding: 0.35rem 0.7rem;
      border-radius: 999px;
      font-size: 0.85rem;
      font-weight: 650;
      letter-spacing: 0.02em;
      margin-bottom: 1rem;
    }
    .badge.ok { color: var(--ok); background: var(--ok-bg); }
    .badge.warn { color: var(--warn); background: var(--warn-bg); }
    .badge.bad { color: var(--bad); background: var(--bad-bg); }
    .badge.muted { color: var(--muted); background: #eef1f4; }
    .stats {
      display: grid;
      grid-template-columns: repeat(auto-fit, minmax(140px, 1fr));
      gap: 0.75rem;
      margin-bottom: 1.5rem;
    }
    .stat {
      background: var(--card);
      border: 1px solid var(--line);
      border-radius: 10px;
      padding: 0.9rem 1rem;
    }
    .stat .label {
      color: var(--muted);
      font-size: 0.8rem;
      text-transform: uppercase;
      letter-spacing: 0.04em;
    }
    .stat .value {
      font-size: 1.25rem;
      font-weight: 650;
      margin-top: 0.2rem;
    }
    section {
      background: var(--card);
      border: 1px solid var(--line);
      border-radius: 10px;
      padding: 1rem 1rem 0.5rem;
      margin-bottom: 1rem;
    }
    section h2 {
      margin: 0 0 0.75rem;
      font-size: 1.05rem;
    }
    table {
      width: 100%;
      border-collapse: collapse;
      font-size: 0.92rem;
      margin-bottom: 0.75rem;
    }
    th, td {
      text-align: left;
      padding: 0.55rem 0.4rem;
      border-bottom: 1px solid var(--line);
      vertical-align: top;
    }
    th {
      color: var(--muted);
      font-weight: 600;
      font-size: 0.8rem;
      text-transform: uppercase;
      letter-spacing: 0.03em;
    }
    td.size { white-space: nowrap; font-variant-numeric: tabular-nums; }
    tr.failed td { color: var(--bad); }
    tr.empty td { color: var(--muted); font-style: italic; }
    footer {
      margin-top: 1.5rem;
      color: var(--muted);
      font-size: 0.85rem;
    }
    code { font-family: Consolas, "Courier New", monospace; font-size: 0.9em; }
  </style>
</head>
<body>
  <main>
    <h1>devsweep report</h1>
    <p class="meta">
      Generated <strong>$(Escape-Html $when)</strong><br />
      Scan root: <code>$(Escape-Html $ScanRoot)</code>
    </p>
    <div class="badge $statusClass">$(Escape-Html $status)</div>
    <div class="stats">
      <div class="stat"><div class="label">Deleted</div><div class="value">$([int]$Result.Deleted)</div></div>
      <div class="stat"><div class="label">Failed</div><div class="value">$([int]$Result.Failed)</div></div>
      <div class="stat"><div class="label">Skipped</div><div class="value">$([int]$Result.Skipped)</div></div>
      <div class="stat"><div class="label">Space freed</div><div class="value">$(Escape-Html (Format-Bytes ([long]$Result.Freed)))</div></div>
    </div>
    <section>
      <h2>Deleted items</h2>
      <table>
        <thead><tr><th>Kind</th><th>Project</th><th>Path</th><th>Size</th></tr></thead>
        <tbody>
$deletedRows
        </tbody>
      </table>
    </section>
    <section>
      <h2>Failed items</h2>
      <table>
        <thead><tr><th>Kind</th><th>Project</th><th>Path</th><th>Size</th></tr></thead>
        <tbody>
$failedRows
        </tbody>
      </table>
    </section>
    <footer>
      Report files:
      <code>last-report.html</code> (latest) and
      <code>reports/report-$stamp.html</code>
    </footer>
  </main>
</body>
</html>
"@

    $latest = Join-Path $script:ScriptDir "last-report.html"
    $archived = Join-Path $reportDir ("report-{0}.html" -f $stamp)
    Set-Content -LiteralPath $latest -Value $html -Encoding UTF8
    Set-Content -LiteralPath $archived -Value $html -Encoding UTF8
    $script:LastReportPath = $latest
    return $latest
}

function Get-FolderSizeBytes {
    param([string]$Path)
    # Prefer Scripting.FileSystemObject - fast and low memory on Windows.
    # Fall back to a streaming enumeration (never materialize all files into an array).
    try {
        if (-not (Test-Path -LiteralPath $Path)) { return [long]0 }
        try {
            $fso = New-Object -ComObject Scripting.FileSystemObject
            $folder = $fso.GetFolder($Path)
            $size = [long]$folder.Size
            [void][System.Runtime.InteropServices.Marshal]::ReleaseComObject($fso)
            return $size
        } catch {
            # ignore and fall through
        }

        $sum = [long]0
        $enum = [System.IO.Directory]::EnumerateFiles($Path, "*", [System.IO.SearchOption]::AllDirectories)
        foreach ($file in $enum) {
            try {
                $sum += (New-Object System.IO.FileInfo -ArgumentList $file).Length
            } catch { }
        }
        return $sum
    } catch {
        return [long]0
    }
}

function Resolve-ScanRoot {
    param([string]$RequestedRoot)

    $scriptDir = $PSScriptRoot
    if ([string]::IsNullOrWhiteSpace($scriptDir)) {
        $scriptDir = Split-Path -Parent $MyInvocation.MyCommand.Path
    }

    if (-not [string]::IsNullOrWhiteSpace($RequestedRoot)) {
        return [System.IO.Path]::GetFullPath($RequestedRoot)
    }

    $cwd = [System.IO.Path]::GetFullPath((Get-Location).Path)

    # If launched from inside the tools folder (or by double-click), scan the parent projects folder.
    if ($cwd -eq $scriptDir -or ($cwd.TrimEnd('\') -eq $scriptDir.TrimEnd('\'))) {
        $parent = Split-Path -Parent $scriptDir
        if (-not [string]::IsNullOrWhiteSpace($parent)) {
            Write-Host "Note: running from tools folder; scanning parent: $parent" -ForegroundColor DarkGray
            return $parent
        }
    }

    return $cwd
}

function Test-LooksLikeProject {
    param([string]$Dir)
    @(
        "pubspec.yaml",
        "package.json",
        "build.gradle",
        "build.gradle.kts",
        "settings.gradle",
        "settings.gradle.kts",
        "android",
        "ios",
        ".fvm",
        ".fvmrc"
    ) | Where-Object { Test-Path -LiteralPath (Join-Path $Dir $_) } | Select-Object -First 1
}

function Test-IsFlutterProject {
    param([string]$Dir)
    $pubspec = Join-Path $Dir "pubspec.yaml"
    if (-not (Test-Path -LiteralPath $pubspec)) { return $false }
    $content = Get-Content -LiteralPath $pubspec -Raw -ErrorAction SilentlyContinue
    if ($null -eq $content) { return $false }
    return ($content -match '(?m)^\s*flutter\s*:') -or
        (Test-Path -LiteralPath (Join-Path $Dir "android")) -or
        (Test-Path -LiteralPath (Join-Path $Dir "ios"))
}

function Test-IsNodeProject {
    param([string]$Dir)
    Test-Path -LiteralPath (Join-Path $Dir "package.json")
}

function Test-IsAndroidGradleProject {
    param([string]$Dir)
    (Test-Path -LiteralPath (Join-Path $Dir "android")) -or
    (Test-Path -LiteralPath (Join-Path $Dir "build.gradle")) -or
    (Test-Path -LiteralPath (Join-Path $Dir "build.gradle.kts")) -or
    (Test-Path -LiteralPath (Join-Path $Dir "settings.gradle")) -or
    (Test-Path -LiteralPath (Join-Path $Dir "settings.gradle.kts"))
}

function Test-HasFvm {
    param([string]$Dir)
    (Test-Path -LiteralPath (Join-Path $Dir ".fvm")) -or
    (Test-Path -LiteralPath (Join-Path $Dir ".fvmrc"))
}

function Assert-ValidProjectsRoot {
    param([string]$RootPath)

    if (-not (Test-Path -LiteralPath $RootPath -PathType Container)) {
        Write-Host ""
        Write-Host "ERROR: Folder not found: $RootPath" -ForegroundColor Red
        Wait-IfInteractive
        exit 1
    }

    $selfIsProject = [bool](Test-LooksLikeProject -Dir $RootPath)
    $childProjects = @(
        Get-ChildItem -LiteralPath $RootPath -Directory -Force -ErrorAction SilentlyContinue |
            Where-Object { Test-LooksLikeProject -Dir $_.FullName }
    )

    if (-not $selfIsProject -and $childProjects.Count -eq 0) {
        Write-Host ""
        Write-Host "ERROR: This does not look like a projects folder." -ForegroundColor Red
        Write-Host ""
        Write-Host "Run the script from the parent directory that contains your repos," -ForegroundColor Yellow
        Write-Host "or from inside a single Flutter/Node/Android project."
        Write-Host ""
        Write-Host "  cd <your-projects-folder>"
        Write-Host "  .\devsweep\devsweep.ps1"
        Write-Host ""
        Write-Host "Expected markers: pubspec.yaml, package.json, android/, .fvm, build.gradle, ..."
        Write-Host "Current folder: $RootPath"
        Wait-IfInteractive
        exit 1
    }
}

function Get-CandidateProjectDirs {
    param([string]$RootPath)

    $dirs = New-Object System.Collections.Generic.List[string]
    $skipNames = @(
        '.idea', '.qodo', '.git', '.vscode', 'Screenshots', 'node_modules',
        'build', '.dart_tool', '.gradle', '.fvm', 'dist', 'out', 'Pods',
        'coverage', '.next', '.nuxt', '.turbo', 'devsweep', 'cleanup-dev-caches',
        'lib', 'test', 'tests', 'assets', 'images', 'fonts', 'docs', 'doc',
        'tool', 'tools', 'scripts', 'web', 'windows', 'linux', 'macos', 'ios', 'android',
        '.stitch_inspect', 'ephemeral'
    )
    $nestNames = @('packages', 'apps', 'mobile', 'web', 'frontend', 'backend', 'client', 'server', 'admin', 'functions', 'third_party')

    function Add-UniqueDir([string]$Path) {
        if ([string]::IsNullOrWhiteSpace($Path)) { return }
        foreach ($existing in $dirs) {
            if ($existing -eq $Path) { return }
        }
        $dirs.Add($Path)
    }

    if (Test-LooksLikeProject -Dir $RootPath) {
        Add-UniqueDir $RootPath
    }

    Get-ChildItem -LiteralPath $RootPath -Directory -Force -ErrorAction SilentlyContinue |
        Where-Object { $_.Name -notin $skipNames } |
        ForEach-Object {
            $child = $_.FullName
            $name = $_.Name

            if ($name -in $nestNames) {
                Get-ChildItem -LiteralPath $child -Directory -Force -ErrorAction SilentlyContinue |
                    Where-Object { $_.Name -notin $skipNames } |
                    ForEach-Object {
                        if (Test-LooksLikeProject -Dir $_.FullName) {
                            Add-UniqueDir $_.FullName
                        }
                    }
            }

            if (Test-LooksLikeProject -Dir $child) {
                Add-UniqueDir $child

                # One nested monorepo level under a project (apps/packages/...)
                Get-ChildItem -LiteralPath $child -Directory -Force -ErrorAction SilentlyContinue |
                    Where-Object { $_.Name -in $nestNames } |
                    ForEach-Object {
                        Get-ChildItem -LiteralPath $_.FullName -Directory -Force -ErrorAction SilentlyContinue |
                            Where-Object {
                                $_.Name -notin $skipNames -and (Test-LooksLikeProject -Dir $_.FullName)
                            } |
                            ForEach-Object { Add-UniqueDir $_.FullName }
                    }

                # Direct child project roots (e.g. repo/mobile with pubspec)
                Get-ChildItem -LiteralPath $child -Directory -Force -ErrorAction SilentlyContinue |
                    Where-Object {
                        $_.Name -notin $skipNames -and (Test-LooksLikeProject -Dir $_.FullName)
                    } |
                    ForEach-Object { Add-UniqueDir $_.FullName }
            }
        }

    return @($dirs)
}

function Add-Target {
    param(
        [System.Collections.Generic.List[object]]$List,
        [string]$Kind,
        [string]$Project,
        [string]$Path
    )
    if (-not (Test-Path -LiteralPath $Path)) { return }
    # Avoid duplicates
    foreach ($existing in $List) {
        if ($existing.Path -eq $Path) { return }
    }

    Write-Host ("  sizing: [{0}] {1}\{2}" -f $Kind, $Project, (Split-Path $Path -Leaf)) -ForegroundColor DarkGray
    $size = Get-FolderSizeBytes -Path $Path
    if (-not $ShowEmpty -and $size -le 0) { return }

    $List.Add([pscustomobject]@{
        Kind    = $Kind
        Project = $Project
        Name    = Split-Path $Path -Leaf
        Path    = $Path
        Size    = $size
    })
}

function Get-FlutterTargets {
    param([string]$ProjectDir, [string]$Rel, [System.Collections.Generic.List[object]]$List)

    Add-Target -List $List -Kind "Flutter" -Project $Rel -Path (Join-Path $ProjectDir "build")
    Add-Target -List $List -Kind "Flutter" -Project $Rel -Path (Join-Path $ProjectDir ".dart_tool")

    foreach ($extra in @(
        "android\app\build",
        "android\build",
        "ios\Pods",
        "ios\.symlinks",
        "macos\Pods",
        "linux\flutter\ephemeral",
        "windows\flutter\ephemeral",
        ".cxx"
    )) {
        Add-Target -List $List -Kind "Flutter" -Project $Rel -Path (Join-Path $ProjectDir $extra)
    }
}

function Get-FvmTargets {
    param([string]$ProjectDir, [string]$Rel, [System.Collections.Generic.List[object]]$List)

    # Keep .fvm/fvm_config.json and .fvmrc - only clear cached SDK copies
    Add-Target -List $List -Kind "FVM" -Project $Rel -Path (Join-Path $ProjectDir ".fvm\flutter_sdk")
    Add-Target -List $List -Kind "FVM" -Project $Rel -Path (Join-Path $ProjectDir ".fvm\versions")

    # Some FVM layouts store versions only under .fvm/versions/<ver>
    $versionsRoot = Join-Path $ProjectDir ".fvm\versions"
    if (Test-Path -LiteralPath $versionsRoot) {
        Get-ChildItem -LiteralPath $versionsRoot -Directory -Force -ErrorAction SilentlyContinue |
            ForEach-Object {
                Add-Target -List $List -Kind "FVM" -Project $Rel -Path $_.FullName
            }
    }
}

function Get-GradleTargets {
    param([string]$ProjectDir, [string]$Rel, [System.Collections.Generic.List[object]]$List)

    Add-Target -List $List -Kind "Gradle" -Project $Rel -Path (Join-Path $ProjectDir ".gradle")
    Add-Target -List $List -Kind "Gradle" -Project $Rel -Path (Join-Path $ProjectDir "android\.gradle")
    Add-Target -List $List -Kind "Gradle" -Project $Rel -Path (Join-Path $ProjectDir ".android\.gradle")
}

function Get-NodeTargets {
    param([string]$ProjectDir, [string]$Rel, [System.Collections.Generic.List[object]]$List)

    foreach ($name in @(
        "node_modules", ".next", ".nuxt", ".turbo", ".vercel", ".parcel-cache",
        ".cache", "coverage", ".output", "storybook-static", "dist", "out", ".svelte-kit"
    )) {
        Add-Target -List $List -Kind "Node" -Project $Rel -Path (Join-Path $ProjectDir $name)
    }
}

function Get-GlobalCacheTargets {
    param([System.Collections.Generic.List[object]]$List)

    $home = $env:USERPROFILE
    if ([string]::IsNullOrWhiteSpace($home)) { $home = $env:HOME }

    Add-Target -List $List -Kind "Global" -Project "(user)" -Path (Join-Path $home ".gradle\caches")
    Add-Target -List $List -Kind "Global" -Project "(user)" -Path (Join-Path $home ".gradle\daemon")
    Add-Target -List $List -Kind "Global" -Project "(user)" -Path (Join-Path $home ".pub-cache\hosted")
    Add-Target -List $List -Kind "Global" -Project "(user)" -Path (Join-Path $home "fvm\versions")
    Add-Target -List $List -Kind "Global" -Project "(user)" -Path (Join-Path $home "AppData\Local\Pub\Cache\hosted")
}

function Remove-DeepPath {
    param([string]$Path)

    $empty = Join-Path $env:TEMP ("empty_cleanup_" + [guid]::NewGuid().ToString("N"))
    New-Item -ItemType Directory -Path $empty -Force | Out-Null
    try {
        & cmd.exe /c "robocopy `"$empty`" `"$Path`" /MIR /R:1 /W:1 /NFL /NDL /NJH /NJS /nc /ns /np >nul"
        & cmd.exe /c "rmdir /s /q `"$Path`""
        if (Test-Path -LiteralPath $Path) {
            Remove-Item -LiteralPath $Path -Recurse -Force -ErrorAction Stop
        }
        if (Test-Path -LiteralPath $Path) {
            throw "Path still exists after robocopy/rmdir"
        }
    } finally {
        Remove-Item -LiteralPath $empty -Force -ErrorAction SilentlyContinue
    }
}

function Remove-Targets {
    param([object[]]$Items)

    $deleted = 0
    $failed = 0
    $skipped = 0
    $freed = [long]0
    $failedItems = @()
    $deletedItems = @()

    foreach ($item in @($Items)) {
        try {
            if (-not (Test-Path -LiteralPath $item.Path)) {
                Write-Host ("  Skip (gone): {0}" -f $item.Path) -ForegroundColor DarkGray
                $skipped++
                continue
            }
            try {
                Remove-Item -LiteralPath $item.Path -Recurse -Force -ErrorAction Stop
            } catch {
                Remove-DeepPath -Path $item.Path
            }
            if (Test-Path -LiteralPath $item.Path) {
                throw "Path still exists"
            }
            $deleted++
            $freed += [long]$item.Size
            $deletedItems += ,$item
            Write-Host ("  Deleted: {0}" -f $item.Path) -ForegroundColor Green
        } catch {
            $failed++
            $failedItems += ,$item
            Write-Host ("  FAILED:  {0}  ({1})" -f $item.Path, $_.Exception.Message) -ForegroundColor Red
        }
    }

    $out = New-Object psobject -Property @{
        Deleted      = [int]$deleted
        Failed       = [int]$failed
        Skipped      = [int]$skipped
        Freed        = [long]$freed
        FailedItems  = $failedItems
        DeletedItems = $deletedItems
    }
    return $out
}

function Show-OperationResult {
    param(
        $Result,
        [string]$ScanRoot = $script:ScanRoot
    )

    $status = Get-ResultStatusLabel -Result $Result

    Write-Host ""
    Write-Host "========================================" -ForegroundColor DarkGray
    switch ($status) {
        "SUCCESS" { Write-Host "  RESULT: SUCCESS" -ForegroundColor Green }
        "PARTIAL SUCCESS" { Write-Host "  RESULT: PARTIAL SUCCESS" -ForegroundColor Yellow }
        "FAILED" { Write-Host "  RESULT: FAILED" -ForegroundColor Red }
        "NOTHING TO DELETE" { Write-Host "  RESULT: NOTHING TO DELETE (already gone)" -ForegroundColor Yellow }
        default { Write-Host "  RESULT: NO CHANGES" -ForegroundColor DarkGray }
    }
    Write-Host "========================================" -ForegroundColor DarkGray
    Write-Host ("  Deleted : {0}" -f $Result.Deleted)
    Write-Host ("  Failed  : {0}" -f $Result.Failed)
    Write-Host ("  Skipped : {0}" -f $Result.Skipped)
    Write-Host ("  Freed   : ~{0}" -f (Format-Bytes ([long]$Result.Freed)))
    Write-Host "========================================" -ForegroundColor DarkGray

    try {
        $reportPath = Write-HtmlReport -Result $Result -ScanRoot $ScanRoot
        Write-Host ("  HTML report: {0}" -f $reportPath) -ForegroundColor Cyan
    } catch {
        Write-Host ("  Could not write HTML report: {0}" -f $_.Exception.Message) -ForegroundColor Yellow
    }

    Write-Host "Tip: Flutter -> flutter pub get | Node -> npm/pnpm install | FVM -> fvm install"
}

function Open-HtmlReport {
    if ([string]::IsNullOrWhiteSpace($script:LastReportPath) -or -not (Test-Path -LiteralPath $script:LastReportPath)) {
        Write-Host "No report file found yet." -ForegroundColor Yellow
        return
    }
    try {
        Start-Process $script:LastReportPath
        Write-Host ("Opened: {0}" -f $script:LastReportPath) -ForegroundColor Green
    } catch {
        Write-Host ("Could not open report: {0}" -f $_.Exception.Message) -ForegroundColor Red
        Write-Host ("Open manually: {0}" -f $script:LastReportPath)
    }
}

function Invoke-PostActionMenu {
    param(
        $Result,
        [object[]]$AllItems
    )

    Show-OperationResult -Result $Result

    # Remaining = still on disk, excluding successfully deleted paths
    $deletedPaths = @($Result.DeletedItems | ForEach-Object { $_.Path })
    $remaining = @(
        $AllItems | Where-Object {
            ($deletedPaths -notcontains $_.Path) -and (Test-Path -LiteralPath $_.Path)
        }
    )

    while ($true) {
        Write-Host ""
        Write-Host "----------------------------------------" -ForegroundColor DarkGray
        if ([int]$Result.Failed -gt 0 -and @($Result.FailedItems).Count -gt 0) {
            Write-Host ("  [R] Retry {0} failed item(s)" -f @($Result.FailedItems).Count)
        }
        if ($remaining.Count -gt 0) {
            Write-Host ("  [M] Return to menu ({0} item(s) still present)" -f $remaining.Count)
        }
        Write-Host "  [Q] Quit"
        Write-Host "  [O] Open HTML report in browser"
        Write-Host "----------------------------------------" -ForegroundColor DarkGray
        $choice = (Read-UserInput "Choice").ToUpperInvariant()

        if ([string]::IsNullOrWhiteSpace($choice)) {
            Write-Host "Use R, M, O, or Q." -ForegroundColor Yellow
            continue
        }

        switch ($choice) {
            "Q" {
                Write-Host ""
                if ([int]$Result.Failed -eq 0 -and [int]$Result.Deleted -gt 0) {
                    Write-Host "Cleanup finished successfully. Goodbye." -ForegroundColor Green
                } elseif ([int]$Result.Failed -gt 0) {
                    Write-Host "Cleanup finished with failures. You can re-run the script to retry." -ForegroundColor Yellow
                } else {
                    Write-Host "Goodbye." -ForegroundColor DarkGray
                }
                if ($script:LastReportPath) {
                    Write-Host ("Report saved at: {0}" -f $script:LastReportPath) -ForegroundColor Cyan
                }
                Wait-IfInteractive
                return @{ Action = "quit" }
            }
            "O" {
                Open-HtmlReport
                continue
            }
            "R" {
                if ([int]$Result.Failed -eq 0 -or @($Result.FailedItems).Count -eq 0) {
                    Write-Host "No failed items to retry." -ForegroundColor Yellow
                    continue
                }
                Write-Host ""
                Write-Host "Retrying failed items..." -ForegroundColor Cyan
                $retryResult = Remove-Targets -Items @($Result.FailedItems)
                $Result = New-Object psobject -Property @{
                    Deleted      = [int]$Result.Deleted + [int]$retryResult.Deleted
                    Failed       = [int]$retryResult.Failed
                    Skipped      = [int]$Result.Skipped + [int]$retryResult.Skipped
                    Freed        = [long]$Result.Freed + [long]$retryResult.Freed
                    FailedItems  = @($retryResult.FailedItems)
                    DeletedItems = @($Result.DeletedItems) + @($retryResult.DeletedItems)
                }
                Show-OperationResult -Result $Result
                $deletedPaths = @($Result.DeletedItems | ForEach-Object { $_.Path })
                $remaining = @(
                    $AllItems | Where-Object {
                        ($deletedPaths -notcontains $_.Path) -and (Test-Path -LiteralPath $_.Path)
                    }
                )
                continue
            }
            "M" {
                if ($remaining.Count -eq 0) {
                    Write-Host "Nothing left on the list. Use Q to quit." -ForegroundColor Yellow
                    continue
                }
                return @{ Action = "menu"; Items = $remaining }
            }
            default {
                Write-Host "Unknown choice. Use R, M, O, or Q." -ForegroundColor Yellow
            }
        }
    }
}

function Show-TargetTable {
    param([object[]]$Items)

    $i = 1
    foreach ($item in $Items) {
        $label = "[{0}] {1}" -f $item.Kind, $item.Project
        Write-Host ("  {0,3}. {1,-42} {2,-16} {3}" -f $i, $label, $item.Name, (Format-Bytes $item.Size))
        $i++
    }
}

function Parse-Selection {
    param(
        [string]$InputText,
        [int]$Max
    )

    $selected = New-Object System.Collections.Generic.List[int]
    $parts = $InputText -split ',' | ForEach-Object { $_.Trim() } | Where-Object { $_ }

    foreach ($part in $parts) {
        if ($part -match '^\d+$') {
            $n = [int]$part
            if ($n -lt 1 -or $n -gt $Max) { throw "Index out of range: $n (valid 1-$Max)" }
            if (-not $selected.Contains($n)) { $selected.Add($n) }
        } elseif ($part -match '^(\d+)\s*-\s*(\d+)$') {
            $a = [int]$Matches[1]
            $b = [int]$Matches[2]
            if ($a -gt $b) { $tmp = $a; $a = $b; $b = $tmp }
            if ($a -lt 1 -or $b -gt $Max) { throw "Range out of bounds: $part (valid 1-$Max)" }
            for ($n = $a; $n -le $b; $n++) {
                if (-not $selected.Contains($n)) { $selected.Add($n) }
            }
        } else {
            throw "Invalid token: '$part' (use numbers like 1,3,5-8)"
        }
    }

    return @($selected | Sort-Object)
}

function Read-UserInput {
    param([string]$Prompt)
    try {
        $value = Read-Host $Prompt
    } catch {
        return ""
    }
    if ($null -eq $value) { return "" }
    return "$value".Trim()
}

function Confirm-Delete {
    param([object[]]$Items)

    $bytes = ($Items | Measure-Object -Property Size -Sum).Sum
    if ($null -eq $bytes) { $bytes = 0 }

    Write-Host ""
    Write-Host ("About to delete {0} item(s) (~{1}):" -f @($Items).Count, (Format-Bytes ([long]$bytes))) -ForegroundColor Yellow
    Show-TargetTable -Items $Items
    Write-Host ""
    $answer = Read-UserInput "Type YES to permanently delete these"
    return ($answer -eq "YES")
}

function Invoke-InteractiveMenu {
    param([object[]]$AllItems)

    $current = @($AllItems)

    while ($true) {
        if ($current.Count -eq 0) {
            Write-Host ""
            Write-Host "No remaining targets." -ForegroundColor Green
            Wait-IfInteractive
            return
        }

        Write-Host ""
        Write-Host ("Current list: {0} item(s), ~{1}" -f $current.Count, (Format-Bytes ([long](($current | Measure-Object -Property Size -Sum).Sum)))) -ForegroundColor DarkGray
        Write-Host "----------------------------------------" -ForegroundColor DarkGray
        Write-Host "  [A] Delete ALL listed items"
        Write-Host "  [S] Select specific (e.g. 1,3,5-8)"
        Write-Host "  [K] Delete by kind (Flutter / Node / Gradle / FVM / Global)"
        Write-Host "  [L] List targets"
        Write-Host "  [Q] Quit"
        Write-Host "----------------------------------------" -ForegroundColor DarkGray
        $choice = (Read-UserInput "Choice").ToUpperInvariant()

        if ([string]::IsNullOrWhiteSpace($choice)) {
            Write-Host "No input received. Use A, S, K, L, or Q." -ForegroundColor Yellow
            continue
        }

        $result = $null
        switch ($choice) {
            "Q" {
                Write-Host ""
                Write-Host "Quit without further deletes. Goodbye." -ForegroundColor DarkGray
                Wait-IfInteractive
                return
            }
            "L" {
                Write-Host ""
                Show-TargetTable -Items $current
                continue
            }
            "R" {
                # alias for list (old key)
                Write-Host ""
                Show-TargetTable -Items $current
                continue
            }
            "A" {
                if (Confirm-Delete -Items $current) {
                    $result = Remove-Targets -Items $current
                } else {
                    Write-Host "Delete cancelled." -ForegroundColor DarkGray
                    continue
                }
            }
            "S" {
                try {
                    $raw = Read-UserInput "Enter numbers / ranges"
                    if ([string]::IsNullOrWhiteSpace($raw)) {
                        Write-Host "Nothing selected." -ForegroundColor Yellow
                        continue
                    }
                    $indexes = Parse-Selection -InputText $raw -Max $current.Count
                    $picked = @($indexes | ForEach-Object { $current[$_ - 1] })
                    if ($picked.Count -eq 0) {
                        Write-Host "Nothing selected." -ForegroundColor Yellow
                        continue
                    }
                    if (Confirm-Delete -Items $picked) {
                        $result = Remove-Targets -Items $picked
                    } else {
                        Write-Host "Delete cancelled." -ForegroundColor DarkGray
                        continue
                    }
                } catch {
                    Write-Host ("Invalid selection: {0}" -f $_.Exception.Message) -ForegroundColor Red
                    continue
                }
            }
            "K" {
                $kinds = @($current | Select-Object -ExpandProperty Kind -Unique | Sort-Object)
                Write-Host ""
                Write-Host ("Available kinds: {0}" -f ($kinds -join ", "))
                $kind = Read-UserInput "Kind to delete"
                $picked = @($current | Where-Object { $_.Kind -ieq $kind })
                if ($picked.Count -eq 0) {
                    Write-Host "No items for kind '$kind'." -ForegroundColor Yellow
                    continue
                }
                if (Confirm-Delete -Items $picked) {
                    $result = Remove-Targets -Items $picked
                } else {
                    Write-Host "Delete cancelled." -ForegroundColor DarkGray
                    continue
                }
            }
            default {
                Write-Host "Unknown choice. Use A, S, K, L, or Q." -ForegroundColor Yellow
                continue
            }
        }

        if ($null -ne $result) {
            $post = Invoke-PostActionMenu -Result $result -AllItems $current
            if ($post.Action -eq "quit") {
                return
            }
            if ($post.Action -eq "menu") {
                $current = @($post.Items)
                Write-Host ""
                Write-Host "Updated list:" -ForegroundColor Cyan
                Show-TargetTable -Items $current
            }
        }
    }
}

# ---------------------------------------------------------------------------
# Main
# ---------------------------------------------------------------------------

try {
    $Root = Resolve-ScanRoot -RequestedRoot $Root
    $script:ScanRoot = $Root
    Assert-ValidProjectsRoot -RootPath $Root

    Write-Host ""
    Write-Host "devsweep" -ForegroundColor Cyan
    Write-Host "Root:  $Root"
    Write-Host "Scan:  Flutter / FVM / Node / Gradle$(if ($IncludeGlobalCaches) { ' / Global caches' })"
    Write-Host "Mode:  $(if ($Apply) { 'non-interactive (-Apply)' } else { 'interactive (dry-run -> choose)' })"
    Write-Host ""
    Write-Host "Scanning projects (this can take a few minutes on large folders)..." -ForegroundColor DarkGray

    $projectDirs = @(Get-CandidateProjectDirs -RootPath $Root)
    Write-Host ("Found {0} project folder(s) to inspect." -f $projectDirs.Count) -ForegroundColor DarkGray

    $planned = New-Object System.Collections.Generic.List[object]
    $i = 0
    foreach ($dir in $projectDirs) {
        $i++
        if ($dir.StartsWith($Root, [System.StringComparison]::OrdinalIgnoreCase)) {
            $rel = $dir.Substring($Root.Length).TrimStart([char[]]@('\', '/'))
        } else {
            $rel = $dir
        }
        if ([string]::IsNullOrWhiteSpace($rel)) { $rel = "(root)" }

        Write-Host ("[{0}/{1}] {2}" -f $i, $projectDirs.Count, $rel) -ForegroundColor Cyan

        if (Test-IsFlutterProject -Dir $dir) {
            Get-FlutterTargets -ProjectDir $dir -Rel $rel -List $planned
        }
        if (Test-HasFvm -Dir $dir) {
            Get-FvmTargets -ProjectDir $dir -Rel $rel -List $planned
        }
        if (Test-IsAndroidGradleProject -Dir $dir) {
            Get-GradleTargets -ProjectDir $dir -Rel $rel -List $planned
        }
        if (Test-IsNodeProject -Dir $dir) {
            Get-NodeTargets -ProjectDir $dir -Rel $rel -List $planned
        }
    }

    if ($IncludeGlobalCaches) {
        Write-Host "Scanning global caches..." -ForegroundColor Cyan
        Get-GlobalCacheTargets -List $planned
    }

    $items = @($planned | Sort-Object Kind, Project, Name, Path)

    if ($items.Count -eq 0) {
        Write-Host "Nothing to clean." -ForegroundColor Green
        if (-not $Apply) { Wait-IfInteractive }
        exit 0
    }

    $totalBytes = ($items | Measure-Object -Property Size -Sum).Sum
    if ($null -eq $totalBytes) { $totalBytes = 0 }

    Write-Host ""
    Show-TargetTable -Items $items
    Write-Host ""
    Write-Host ("Targets: {0}  |  Reclaimable: ~{1}" -f $items.Count, (Format-Bytes ([long]$totalBytes))) -ForegroundColor Yellow

    if ($Apply) {
        if (-not $Force) {
            $answer = Read-UserInput "Delete ALL of the above? Type YES to continue"
            if ($answer -ne "YES") {
                Write-Host "Aborted." -ForegroundColor Red
                Wait-IfInteractive
                exit 1
            }
        }
        $result = Remove-Targets -Items $items
        Show-OperationResult -Result $result
        if (-not $Force -and $script:LastReportPath) {
            $open = Read-UserInput "Open HTML report in browser? Type YES to open"
            if ($open -eq "YES") { Open-HtmlReport }
        }
        if ($result.Failed -gt 0 -and -not $Force) {
            Write-Host ""
            $retry = Read-UserInput "Retry failed items? Type YES to retry"
            if ($retry -eq "YES" -and @($result.FailedItems).Count -gt 0) {
                $retryResult = Remove-Targets -Items @($result.FailedItems)
                $merged = New-Object psobject -Property @{
                    Deleted      = [int]$result.Deleted + [int]$retryResult.Deleted
                    Failed       = [int]$retryResult.Failed
                    Skipped      = [int]$result.Skipped + [int]$retryResult.Skipped
                    Freed        = [long]$result.Freed + [long]$retryResult.Freed
                    FailedItems  = @($retryResult.FailedItems)
                    DeletedItems = @($result.DeletedItems) + @($retryResult.DeletedItems)
                }
                Show-OperationResult -Result $merged
                if ($merged.Failed -gt 0) { exit 1 } else { exit 0 }
            }
            if ($result.Failed -gt 0) { exit 1 }
        }
        Wait-IfInteractive
        if ($result.Failed -gt 0) { exit 1 } else { exit 0 }
    }

    Invoke-InteractiveMenu -AllItems $items
}
catch {
    $script:HadFatalError = $true
    Write-Host ""
    Write-Host "ERROR: $($_.Exception.Message)" -ForegroundColor Red
    if ($_.ScriptStackTrace) {
        Write-Host $_.ScriptStackTrace -ForegroundColor DarkGray
    }
    Wait-IfInteractive
    exit 1
}