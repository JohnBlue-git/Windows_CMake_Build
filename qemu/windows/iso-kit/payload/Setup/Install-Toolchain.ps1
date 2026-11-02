<#
    Runs inside the freshly installed Windows (from SetupComplete.cmd, as SYSTEM).
    Installs the toolchain embedded in the custom ISO, fully offline:
      - CMake and Ninja zips      -> C:\Tools\..., added to the machine PATH
      - VS 2022 Build Tools layout -> C:\BuildTools (MSVC, Windows SDK, VS CMake)
    Writes C:\Setup\toolchain.json when everything succeeded. Safe to re-run.
#>
[CmdletBinding()]
param(
    [string]$SetupDir = 'C:\Setup',
    [switch]$KeepPayload
)

$ErrorActionPreference = 'Stop'
$exitCode = 0
$logDir = Join-Path $SetupDir 'logs'
New-Item -ItemType Directory -Force -Path $logDir | Out-Null
Start-Transcript -Path (Join-Path $logDir 'Install-Toolchain.log') -Append | Out-Null

try {
    $cfg = Import-PowerShellDataFile (Join-Path $SetupDir 'toolchain.psd1')
    $machinePath = [Environment]::GetEnvironmentVariable('Path', 'Machine')

    # --- CMake / Ninja ---------------------------------------------------------
    foreach ($tool in $cfg.Tools) {
        $zip = Join-Path $SetupDir ('tools\' + [IO.Path]::GetFileName($tool.Url))
        if (-not (Test-Path $zip)) { throw "missing payload: $zip" }
        Write-Host "Installing $($tool.Name) -> $($tool.Dest)"
        $tmp = Join-Path $env:TEMP ("extract-" + $tool.Name)
        Remove-Item $tmp -Recurse -Force -ErrorAction SilentlyContinue
        Expand-Archive -Path $zip -DestinationPath $tmp -Force
        # CMake zips contain one top-level folder; Ninja's contains ninja.exe directly.
        $items = @(Get-ChildItem $tmp)
        $src = if ($items.Count -eq 1 -and $items[0].PSIsContainer) { $items[0].FullName } else { $tmp }
        Remove-Item $tool.Dest -Recurse -Force -ErrorAction SilentlyContinue
        New-Item -ItemType Directory -Force -Path (Split-Path $tool.Dest) | Out-Null
        Move-Item $src $tool.Dest
        Remove-Item $tmp -Recurse -Force -ErrorAction SilentlyContinue
        foreach ($d in $tool.PathDirs) {
            if (($machinePath -split ';') -notcontains $d) { $machinePath = "$d;$machinePath" }
        }
    }
    [Environment]::SetEnvironmentVariable('Path', $machinePath, 'Machine')

    # --- Visual Studio Build Tools (offline) -----------------------------------
    $vs = $cfg.VisualStudio
    $layout = Join-Path $SetupDir 'vslayout'
    if (Test-Path $layout) {
        $boot = @('vs_buildtools.exe', 'vs_setup.exe') |
            ForEach-Object { Join-Path $layout $_ } | Where-Object { Test-Path $_ } | Select-Object -First 1
        if (-not $boot) { throw "no bootstrapper (vs_buildtools.exe / vs_setup.exe) in $layout" }

        $vsArgs = @('--noWeb', '--quiet', '--wait', '--norestart', '--nocache',
                    '--installPath', $vs.InstallPath, '--addProductLang', $vs.Language)
        foreach ($c in $vs.Components) { $vsArgs += @('--add', $c) }
        if ($vs.IncludeRecommended) { $vsArgs += '--includeRecommended' }

        Write-Host "Installing Visual Studio Build Tools from $layout (offline)"
        $p = Start-Process -FilePath $boot -ArgumentList $vsArgs -Wait -PassThru
        # 3010 = success, reboot required
        if ($p.ExitCode -ne 0 -and $p.ExitCode -ne 3010) {
            Copy-Item "$env:TEMP\dd_*.log" $logDir -ErrorAction SilentlyContinue
            throw "Visual Studio Build Tools install failed: exit code $($p.ExitCode)"
        }
    } else {
        Write-Warning "No VS layout in $layout - skipping MSVC install."
    }

    # --- verify ----------------------------------------------------------------
    $env:Path = $machinePath
    $cmakeVer = (& cmake --version | Select-Object -First 1)
    $vswhere = "${env:ProgramFiles(x86)}\Microsoft Visual Studio\Installer\vswhere.exe"
    $msvc = if (Test-Path $vswhere) {
        & $vswhere -products * -requires Microsoft.VisualStudio.Component.VC.Tools.x86.x64 -property installationPath
    }
    if ((Test-Path $layout) -and -not $msvc) { throw 'MSVC not found after install' }

    [ordered]@{
        installedAt = (Get-Date).ToString('s')
        cmake       = $cmakeVer
        msvcPath    = $msvc
    } | ConvertTo-Json | ForEach-Object {
        [IO.File]::WriteAllText((Join-Path $SetupDir 'toolchain.json'), $_, (New-Object Text.UTF8Encoding($false)))
    }
    Write-Host "Toolchain installed: $cmakeVer; MSVC at $msvc"

    # Free ~4 GB: the offline layout is not needed once installed.
    if (-not $KeepPayload) {
        Remove-Item $layout, (Join-Path $SetupDir 'tools') -Recurse -Force -ErrorAction SilentlyContinue
    }
}
catch {
    # Write the marker first: with ErrorActionPreference=Stop, Write-Error would throw.
    Set-Content -Path (Join-Path $SetupDir 'toolchain.FAILED') -Value ($_ | Out-String)
    $exitCode = 1
    Write-Warning "Toolchain install failed: $($_.Exception.Message)"
}
finally {
    Stop-Transcript | Out-Null
}
exit $exitCode
