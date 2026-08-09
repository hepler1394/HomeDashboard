<#
    Keeps this tracked copy of the DeerFlow runtime config in step with the live
    one at C:\HomeDashboard\deer-flow.

    The live files are gitignored by upstream (deer-flow/.gitignore lines 30-46),
    so this directory is their only version-controlled copy. Nothing syncs them
    automatically — run this after changing models, skills, or MCP config, or the
    two WILL drift apart.

        .\sync.ps1              # live  -> repo   (back up before committing)
        .\sync.ps1 -Restore     # repo  -> live   (rebuild after a wipe)
        .\sync.ps1 -Check       # report differences, change nothing

    .env is deliberately never touched: it holds real API keys and must stay out
    of git. After -Restore you must recreate deer-flow\.env by hand, then
    recreate the gateway container.
#>
param(
    [switch]$Restore,
    [switch]$Check
)

$ErrorActionPreference = 'Stop'
$repo = $PSScriptRoot
$live = Join-Path (Split-Path $repo -Parent) 'deer-flow'

if (-not (Test-Path $live)) { throw "live DeerFlow checkout not found at $live" }

# source-relative-path pairs: (name, live path, repo path)
$items = @(
    @{ Name = 'config.yaml';             Live = "$live\config.yaml";             Repo = "$repo\config.yaml" },
    @{ Name = 'extensions_config.json';  Live = "$live\extensions_config.json";  Repo = "$repo\extensions_config.json" }
)

function Compare-Tree($a, $b) {
    $ha = if (Test-Path $a) { (Get-FileHash $a -Algorithm SHA256).Hash } else { $null }
    $hb = if (Test-Path $b) { (Get-FileHash $b -Algorithm SHA256).Hash } else { $null }
    return $ha -eq $hb
}

if ($Check) {
    foreach ($i in $items) {
        $same = Compare-Tree $i.Live $i.Repo
        "{0,-26} {1}" -f $i.Name, $(if ($same) { 'in sync' } else { 'DIFFERS' })
    }
    $liveSkills = Get-ChildItem "$live\skills\custom" -Recurse -File -ErrorAction SilentlyContinue
    $repoSkills = Get-ChildItem "$repo\skills"        -Recurse -File -ErrorAction SilentlyContinue
    "{0,-26} live={1} files, repo={2} files" -f 'skills', $liveSkills.Count, $repoSkills.Count
    return
}

if ($Restore) {
    foreach ($i in $items) { Copy-Item $i.Repo $i.Live -Force; "restored $($i.Name)" }
    New-Item -ItemType Directory -Force -Path "$live\skills\custom" | Out-Null
    Copy-Item "$repo\skills\*" "$live\skills\custom\" -Recurse -Force
    "restored skills"
    ""
    "deer-flow\.env is NOT restored - recreate it with your API keys, then:"
    "  docker compose -p deer-flow -f deer-flow\docker\docker-compose.yaml up -d gateway"
} else {
    foreach ($i in $items) { Copy-Item $i.Live $i.Repo -Force; "backed up $($i.Name)" }
    Remove-Item "$repo\skills\*" -Recurse -Force -ErrorAction SilentlyContinue
    Copy-Item "$live\skills\custom\*" "$repo\skills\" -Recurse -Force
    "backed up skills"
    ""
    "now commit: git add deerflow && git commit -m 'chore: sync deerflow config'"
}
