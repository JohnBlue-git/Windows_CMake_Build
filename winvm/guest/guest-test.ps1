# Runs inside the VM (copied there by vm.sh test). Unpacks the MinGW build
# output from mingw/build.sh and runs the demo on real Windows.
$ErrorActionPreference = 'Stop'

$dir = 'C:\work\test'

Remove-Item -Recurse -Force $dir -ErrorAction SilentlyContinue
New-Item -ItemType Directory -Path $dir | Out-Null
tar -xf "$HOME\test.tar" -C $dir
if ($LASTEXITCODE -ne 0) { throw 'failed to unpack test files' }

& (Join-Path $dir 'ThreadDemo.exe')
if ($LASTEXITCODE -ne 0) { throw "ThreadDemo.exe failed (exit $LASTEXITCODE)" }
