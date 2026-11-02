<#
.SYNOPSIS
    Step 1: download everything the custom ISO embeds, so Windows Setup can
    install the toolchain later with no internet access.

.DESCRIPTION
    Creates  <WorkDir>\payload\
               vslayout\   Visual Studio 2022 Build Tools offline layout (~3-4 GB)
               tools\      CMake and Ninja zip files (SHA-256 verified)
               payload.json  versions that went in (used by Build-CustomIso.ps1)

    Run on a Windows 10/11 or Server PC with internet access, in an elevated
    PowerShell 5.1 or 7 session. Re-running reuses existing downloads; the VS
    layout is updated in place.

.EXAMPLE
    .\Prepare-Payload.ps1 -WorkDir D:\isowork
#>
[CmdletBinding()]
param(
    [string]$WorkDir = 'C:\isowork',
    [string]$ConfigFile = (Join-Path $PSScriptRoot 'config\toolchain.psd1'),
    [switch]$SkipVisualStudio
)

$ErrorActionPreference = 'Stop'
$ProgressPreference = 'SilentlyContinue'
[Net.ServicePointManager]::SecurityProtocol = [Net.SecurityProtocolType]::Tls12

if ($WorkDir -match '\s') { throw "WorkDir must not contain spaces: $WorkDir" }
$cfg = Import-PowerShellDataFile $ConfigFile
$payload = Join-Path $WorkDir 'payload'
$toolsDir = Join-Path $payload 'tools'
$layoutDir = Join-Path $payload 'vslayout'
New-Item -ItemType Directory -Force -Path $toolsDir | Out-Null

function Write-Step([string]$msg) { Write-Host "==> $msg" -ForegroundColor Cyan }

# --- CMake / Ninja -------------------------------------------------------------
foreach ($tool in $cfg.Tools) {
    $file = Join-Path $toolsDir ([IO.Path]::GetFileName($tool.Url))
    if (-not (Test-Path $file)) {
        Write-Step "Downloading $($tool.Name): $($tool.Url)"
        Invoke-WebRequest -Uri $tool.Url -OutFile $file -UseBasicParsing
    }
    $hash = (Get-FileHash -Algorithm SHA256 $file).Hash.ToLower()
    if ($hash -ne $tool.Sha256.ToLower()) {
        Remove-Item $file -Force
        throw "SHA-256 mismatch for $file`n expected $($tool.Sha256)`n got      $hash"
    }
    Write-Host "    $($tool.Name) OK ($hash)"
}

# --- Visual Studio Build Tools offline layout ----------------------------------
if (-not $SkipVisualStudio) {
    $vs = $cfg.VisualStudio
    $boot = Join-Path $WorkDir 'vs_buildtools.exe'
    Write-Step 'Downloading Visual Studio Build Tools bootstrapper'
    Invoke-WebRequest -Uri $vs.Bootstrapper -OutFile $boot -UseBasicParsing

    $layoutArgs = @('--layout', $layoutDir, '--lang', $vs.Language, '--wait', '--quiet')
    foreach ($c in $vs.Components) { $layoutArgs += @('--add', $c) }
    if ($vs.IncludeRecommended) { $layoutArgs += '--includeRecommended' }

    Write-Step "Creating VS offline layout in $layoutDir (several GB, 10-40 min)"
    $p = Start-Process -FilePath $boot -ArgumentList $layoutArgs -Wait -PassThru
    if ($p.ExitCode -ne 0) {
        throw "vs_buildtools.exe --layout failed with exit code $($p.ExitCode). Logs: $env:TEMP\dd_*.log"
    }
    $markers = 'Catalog.json', 'ChannelManifest.json', 'Response.json', 'vs_installer.opc'
    if (-not ($markers | Where-Object { Test-Path (Join-Path $layoutDir $_) })) {
        throw "Layout looks incomplete: none of $($markers -join ', ') in $layoutDir"
    }
    # Make sure the layout has a bootstrapper with a known name for Install-Toolchain.ps1.
    if (-not (Test-Path (Join-Path $layoutDir 'vs_buildtools.exe'))) {
        Copy-Item $boot (Join-Path $layoutDir 'vs_buildtools.exe')
    }
}

# --- record what was prepared --------------------------------------------------
$sizeGB = [math]::Round(((Get-ChildItem $payload -Recurse -File | Measure-Object Length -Sum).Sum / 1GB), 2)
$info = [ordered]@{
    preparedAt   = (Get-Date).ToString('s')
    preparedOn   = $env:COMPUTERNAME
    vsComponents = $cfg.VisualStudio.Components
    vsLayout     = (Test-Path $layoutDir)
    tools        = @($cfg.Tools | ForEach-Object { [ordered]@{ name = $_.Name; url = $_.Url; sha256 = $_.Sha256 } })
    sizeGB       = $sizeGB
}
[IO.File]::WriteAllText((Join-Path $payload 'payload.json'), ($info | ConvertTo-Json -Depth 5), (New-Object Text.UTF8Encoding($false)))

Write-Step "Payload ready: $payload ($sizeGB GB)"
Write-Host  "Next: .\Build-CustomIso.ps1 -SourceIso <path-to-server-2022.iso> -WorkDir $WorkDir"
