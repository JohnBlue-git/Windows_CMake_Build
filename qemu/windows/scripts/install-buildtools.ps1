# Same toolchain the old docker/windows/Dockerfile installed:
# VS 2022 C++ Build Tools (MSVC, Windows SDK) + the CMake bundled with VS.
#
# With the custom ISO from iso-kit/ the toolchain was already installed offline
# by SetupComplete.cmd during Windows Setup; this script then does nothing.
$ErrorActionPreference = 'Stop'
$ProgressPreference = 'SilentlyContinue'

if (Test-Path 'C:\Setup\toolchain.FAILED') {
    Get-Content 'C:\Setup\logs\Install-Toolchain.log' -Tail 60 -ErrorAction SilentlyContinue
    throw "The custom ISO's toolchain install failed during Windows Setup (see C:\Setup\logs)."
}

$vswhere = "${env:ProgramFiles(x86)}\Microsoft Visual Studio\Installer\vswhere.exe"
if (Test-Path $vswhere) {
    $vs = & $vswhere -products * -requires Microsoft.VisualStudio.Component.VC.Tools.x86.x64 -property installationPath
    if ($vs) {
        Write-Host "MSVC already installed at $vs (custom ISO) - skipping download."
        exit 0
    }
}

$installer = 'C:\Windows\Temp\vs_buildtools.exe'
Invoke-WebRequest -Uri 'https://aka.ms/vs/17/release/vs_buildtools.exe' -OutFile $installer -UseBasicParsing

$installArgs = @(
    '--quiet', '--wait', '--norestart', '--nocache',
    '--installPath', 'C:\BuildTools',
    '--add', 'Microsoft.VisualStudio.Workload.VCTools', '--includeRecommended',
    '--add', 'Microsoft.VisualStudio.Component.VC.CMake.Project'
)
Write-Host 'Installing Visual Studio Build Tools (this takes a while)...'
$p = Start-Process -FilePath $installer -ArgumentList $installArgs -Wait -PassThru
if ($p.ExitCode -ne 0 -and $p.ExitCode -ne 3010) {
    throw "Visual Studio Build Tools install failed: $($p.ExitCode)"
}
Remove-Item $installer -Force

# Put the VS-bundled CMake/Ninja on the machine PATH.
$cmakeBin = 'C:\BuildTools\Common7\IDE\CommonExtensions\Microsoft\CMake\CMake\bin'
$ninjaBin = 'C:\BuildTools\Common7\IDE\CommonExtensions\Microsoft\CMake\Ninja'
$path = [Environment]::GetEnvironmentVariable('Path', 'Machine')
foreach ($dir in @($cmakeBin, $ninjaBin)) {
    if (($path -split ';') -notcontains $dir) { $path = "$path;$dir" }
}
[Environment]::SetEnvironmentVariable('Path', $path, 'Machine')
Write-Host 'Build Tools installed.'
