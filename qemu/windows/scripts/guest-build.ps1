# Runs inside the VM (copied there by vm.sh). Unpacks the source, builds with
# MSVC, runs the demo, and packs the Release output for vm.sh to fetch.
param([string]$Config = 'Release')
$ErrorActionPreference = 'Stop'

$src   = 'C:\work\src'
$build = 'C:\work\build'
$config = $Config

Remove-Item -Recurse -Force 'C:\work' -ErrorAction SilentlyContinue
New-Item -ItemType Directory -Path $src | Out-Null
tar -xf "$HOME\src.tar" -C $src
if ($LASTEXITCODE -ne 0) { throw 'failed to unpack source' }

cmake -S $src -B $build -G 'Visual Studio 17 2022' -A x64
if ($LASTEXITCODE -ne 0) { throw 'cmake configure failed' }

cmake --build $build --config $config --parallel
if ($LASTEXITCODE -ne 0) { throw 'cmake build failed' }

$bin = Join-Path $build "bin\$config"
& (Join-Path $bin 'ThreadDemo.exe')
if ($LASTEXITCODE -ne 0) { throw 'ThreadDemo.exe failed' }

Remove-Item "$HOME\artifacts.tar" -ErrorAction SilentlyContinue
tar -cf "$HOME\artifacts.tar" -C $bin .
if ($LASTEXITCODE -ne 0) { throw 'failed to pack artifacts' }
