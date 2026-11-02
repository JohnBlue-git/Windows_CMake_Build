# Fails the Packer build if the toolchain is not usable.
$ErrorActionPreference = 'Stop'

cmake --version
if ($LASTEXITCODE -ne 0) { throw 'cmake not found on PATH' }

$vswhere = 'C:\Program Files (x86)\Microsoft Visual Studio\Installer\vswhere.exe'
$vs = & $vswhere -products * -requires Microsoft.VisualStudio.Component.VC.Tools.x86.x64 -property installationPath
if (-not $vs) { throw 'MSVC x64 tools not found' }
Write-Host "MSVC found at: $vs"
