#Requires -Version 5.1
[CmdletBinding()]
param()

$ErrorActionPreference = 'Stop'
$REPO = 'aensley/backdrop'

# Resolve install source: local repo checkout or remote download.
$scriptDir = if ($PSScriptRoot) { $PSScriptRoot } else { $null }
$repoRaw   = $null

if (-not $scriptDir) {
    Write-Host 'Fetching latest release info from GitHub...'
    $apiResp   = (Invoke-WebRequest -Uri "https://api.github.com/repos/$REPO/releases/latest" `
        -UseBasicParsing -TimeoutSec 15 -ErrorAction Stop).Content
    $latestTag = ($apiResp | ConvertFrom-Json).tag_name
    $repoRaw   = "https://raw.githubusercontent.com/$REPO/$latestTag/src"
    Write-Host "Installing backdrop $latestTag..."
} else {
    Write-Host 'Installing backdrop...'
}

# Determine the per-user PowerShell modules directory for the running PS version.
$modulesRoot = if ($PSVersionTable.PSVersion.Major -ge 6) {
    Join-Path $env:USERPROFILE 'Documents\PowerShell\Modules'
} else {
    Join-Path $env:USERPROFILE 'Documents\WindowsPowerShell\Modules'
}
$destDir = Join-Path $modulesRoot 'backdrop'
$null = New-Item -ItemType Directory -Force -Path $destDir

$tmp = $null
if ($repoRaw) {
    # Remote install: download both files to a temp directory first.
    $tmp = Join-Path $env:TEMP "backdrop-install-$(Get-Random)"
    $null = New-Item -ItemType Directory -Force -Path $tmp
    foreach ($file in 'backdrop.psm1', 'backdrop.psd1') {
        $ProgressPreference = 'SilentlyContinue'
        Invoke-WebRequest -Uri "$repoRaw/$file" -UseBasicParsing -OutFile (Join-Path $tmp $file) `
            -TimeoutSec 30 -ErrorAction Stop
    }
    $srcDir = $tmp
} else {
    $srcDir = $scriptDir
}

try {
    Copy-Item (Join-Path $srcDir 'backdrop.psm1') $destDir -Force
    Copy-Item (Join-Path $srcDir 'backdrop.psd1') $destDir -Force
} finally {
    if ($tmp -and (Test-Path $tmp)) { Remove-Item $tmp -Recurse -Force -ErrorAction SilentlyContinue }
}

Write-Host "backdrop: installed to $destDir"

# Load the module and enable the scheduled task.
Import-Module (Join-Path $destDir 'backdrop.psm1') -Force
backdrop enable

Write-Host 'Done.'
