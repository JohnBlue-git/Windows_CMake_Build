<#
.SYNOPSIS
    Reset the ISO work directory so the next Build-CustomIso.ps1 run starts clean.

.DESCRIPTION
    Dismounts any leftover install.wim mount, runs DISM cleanup, and deletes the
    work folders (also ones with locked permissions, such as a half-finished
    mount full of WinSxS files).

    Default:    removes iso\, mount\, report\, out\, install.wim  (keeps payload\ and logs\)
    -All:       also removes payload\ (re-run Prepare-Payload.ps1 afterwards) and logs\
    -MountOnly: only dismounts and removes mount\ (used by Build-CustomIso.ps1)

.EXAMPLE
    .\Clean-Workdir.ps1 -WorkDir D:\isowork
    .\Clean-Workdir.ps1 -WorkDir D:\isowork -All
#>
[CmdletBinding()]
param(
    [string]$WorkDir = 'C:\isowork',
    [switch]$All,
    [switch]$MountOnly
)

$ErrorActionPreference = 'Continue'

$principal = New-Object Security.Principal.WindowsPrincipal([Security.Principal.WindowsIdentity]::GetCurrent())
if (-not $principal.IsInRole([Security.Principal.WindowsBuiltInRole]::Administrator)) {
    throw 'Run this script from an elevated (Administrator) PowerShell.'
}
if (-not (Test-Path $WorkDir)) { Write-Host "Nothing to clean: $WorkDir does not exist."; return }
$WorkDir = (Resolve-Path $WorkDir).Path

function Remove-Stubborn([string]$path) {
    if (-not (Test-Path -LiteralPath $path)) { return }
    Write-Host "    removing $path"
    Remove-Item -LiteralPath $path -Recurse -Force -ErrorAction SilentlyContinue
    if (-not (Test-Path -LiteralPath $path)) { return }
    # Locked ACLs (typical for an interrupted DISM mount): take ownership, then delete.
    if (Test-Path -LiteralPath $path -PathType Container) {
        cmd.exe /c "takeown /f `"$path`" /r /d y >nul 2>&1"
        cmd.exe /c "icacls `"$path`" /grant Administrators:F /t /c /q >nul 2>&1"
        cmd.exe /c "rmdir /s /q `"$path`" >nul 2>&1"
    } else {
        cmd.exe /c "takeown /f `"$path`" >nul 2>&1"
        cmd.exe /c "icacls `"$path`" /grant Administrators:F /c /q >nul 2>&1"
        Remove-Item -LiteralPath $path -Force -ErrorAction SilentlyContinue
    }
    if (Test-Path -LiteralPath $path) {
        throw "Could not remove $path. Close programs using it, reboot, and run this script again."
    }
}

Write-Host '==> Dismounting leftover images'
try {
    Get-WindowsImage -Mounted -ErrorAction Stop |
        Where-Object { $_.Path -like "$WorkDir*" } |
        ForEach-Object {
            Write-Host "    unmount $($_.Path)"
            Dismount-WindowsImage -Path $_.Path -Discard -ErrorAction SilentlyContinue | Out-Null
        }
} catch { Write-Warning $_.Exception.Message }
dism.exe /Cleanup-Wim | Out-Null
try { Clear-WindowsCorruptMountPoint | Out-Null } catch {}

Write-Host '==> Removing work folders'
Remove-Stubborn (Join-Path $WorkDir 'mount')
if (-not $MountOnly) {
    foreach ($name in 'iso', 'report', 'out') { Remove-Stubborn (Join-Path $WorkDir $name) }
    Remove-Stubborn (Join-Path $WorkDir 'install.wim')
    if ($All) {
        foreach ($name in 'payload', 'logs') { Remove-Stubborn (Join-Path $WorkDir $name) }
        Remove-Stubborn (Join-Path $WorkDir 'vs_buildtools.exe')
    }
}
Write-Host "==> Clean done ($WorkDir)"
