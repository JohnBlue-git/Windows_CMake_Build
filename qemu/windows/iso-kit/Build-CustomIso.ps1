<#
.SYNOPSIS
    Step 2: build a customized Windows Server 2022 ISO for CMake_DLL builds:
    one edition, unneeded components removed, toolchain embedded.

.DESCRIPTION
    Uses only built-in Windows tooling (DISM PowerShell module, reg.exe) plus
    oscdimg.exe from the Windows ADK "Deployment Tools" feature.

      source ISO -> copy files -> export ONE edition from install.wim/.esd
                 -> mount -> remove Appx / capabilities / features
                 -> disable services, set offline registry policies
                 -> component cleanup (/ResetBase)
                 -> embed C:\Setup (VS layout, CMake, Ninja, installer) + SetupComplete.cmd
                 -> unmount + re-export (compact) -> [autounattend.xml] -> oscdimg
                 -> <name>.iso, <name>.iso.sha256, <name>.manifest.json

    The toolchain is installed by SetupComplete.cmd at the end of Windows Setup
    (offline, from the embedded layout). MSVC can't be pre-installed into an
    offline WIM because its installer needs a running Windows.

    Run in an elevated PowerShell on Windows 10/11 or Server 2019+.

.EXAMPLE
    # see which editions the ISO contains
    .\Build-CustomIso.ps1 -SourceIso D:\iso\SERVER_EVAL_x64FRE_en-us.iso -ListImages

.EXAMPLE
    # inspect what the chosen edition contains (CSV reports), change nothing
    .\Build-CustomIso.ps1 -SourceIso D:\iso\server2022.iso -ListOnly

.EXAMPLE
    # the normal build
    .\Build-CustomIso.ps1 -SourceIso D:\iso\server2022.iso -WorkDir D:\isowork

.EXAMPLE
    # also make the ISO install itself without questions (WIPES DISK 0 of whatever boots it)
    .\Build-CustomIso.ps1 -SourceIso D:\iso\server2022.iso -Unattended -AdminPassword 'S0me!Pass'
#>
[CmdletBinding(DefaultParameterSetName = 'ByName')]
param(
    [Parameter(Mandatory)][string]$SourceIso,
    [string]$WorkDir = 'C:\isowork',
    [string]$OutputIso,

    [Parameter(ParameterSetName = 'ByName')]
    [string]$ImageName = 'Windows Server 2022 SERVERSTANDARDCORE',
    [Parameter(ParameterSetName = 'ByIndex', Mandatory)]
    [int]$ImageIndex,

    [switch]$ListImages,
    [switch]$ListOnly,
    [switch]$Clean,          # reset the work dir (keeps payload) before building

    [switch]$SkipDebloat,
    [switch]$RemoveDefender,
    [switch]$SkipToolchain,
    [switch]$SkipCleanup,

    [switch]$Unattended,
    [string]$AdminPassword,
    [string]$ProductKey,

    [ValidateLength(1, 32)][string]$Label = 'WS2022_CMAKE_DLL',
    [string]$DebloatConfig = (Join-Path $PSScriptRoot 'config\debloat.psd1'),
    [string]$ToolchainConfig = (Join-Path $PSScriptRoot 'config\toolchain.psd1')
)

$ErrorActionPreference = 'Stop'
$ProgressPreference = 'SilentlyContinue'

# --- helpers -------------------------------------------------------------------
function Write-Step([string]$msg) { Write-Host "`n==> $msg" -ForegroundColor Cyan }
function Write-Info([string]$msg) { Write-Host "    $msg" }

function Invoke-Native([string]$exe, [string[]]$arguments, [int[]]$okCodes = @(0)) {
    & $exe @arguments
    if ($okCodes -notcontains $LASTEXITCODE) {
        throw "$exe $($arguments -join ' ') failed with exit code $LASTEXITCODE"
    }
}

function Copy-Tree([string]$from, [string]$to) {
    # robocopy: exit codes below 8 mean success
    & robocopy.exe $from $to /E /R:1 /W:1 /NFL /NDL /NJH /NJS /NP | Out-Null
    if ($LASTEXITCODE -ge 8) { throw "robocopy $from -> $to failed ($LASTEXITCODE)" }
}

function Find-Oscdimg {
    $candidates = @(
        "${env:ProgramFiles(x86)}\Windows Kits\10\Assessment and Deployment Kit\Deployment Tools\amd64\Oscdimg\oscdimg.exe",
        "$env:ProgramFiles\Windows Kits\10\Assessment and Deployment Kit\Deployment Tools\amd64\Oscdimg\oscdimg.exe"
    )
    $found = $candidates | Where-Object { Test-Path $_ } | Select-Object -First 1
    if (-not $found) { $found = (Get-Command oscdimg.exe -ErrorAction SilentlyContinue).Source }
    if (-not $found) {
        throw "oscdimg.exe not found. Install the Windows ADK and select only 'Deployment Tools':`n  winget install Microsoft.WindowsADK"
    }
    return $found
}

# --- preflight -------------------------------------------------------------------
$principal = New-Object Security.Principal.WindowsPrincipal([Security.Principal.WindowsIdentity]::GetCurrent())
if (-not $principal.IsInRole([Security.Principal.WindowsBuiltInRole]::Administrator)) {
    throw 'Run this script from an elevated (Administrator) PowerShell.'
}
$SourceIso = (Resolve-Path $SourceIso).Path
if ($WorkDir -match '\s') { throw "WorkDir must not contain spaces (oscdimg boot arguments): $WorkDir" }
if ($Unattended -and -not $AdminPassword) { throw '-Unattended requires -AdminPassword.' }
if (-not $ListImages -and -not $ListOnly) { $null = Find-Oscdimg }   # fail fast, before the slow steps

New-Item -ItemType Directory -Force -Path $WorkDir | Out-Null
if ($Clean) { & (Join-Path $PSScriptRoot 'Clean-Workdir.ps1') -WorkDir $WorkDir }
$isoDir    = Join-Path $WorkDir 'iso'
$mountDir  = Join-Path $WorkDir 'mount'
$reportDir = Join-Path $WorkDir 'report'
$logDir    = Join-Path $WorkDir 'logs'
$payload   = Join-Path $WorkDir 'payload'
if (-not $OutputIso) { $OutputIso = Join-Path $WorkDir 'out\CMakeDLL-WS2022-custom.iso' }
$OutputIso = [IO.Path]::GetFullPath($OutputIso)
New-Item -ItemType Directory -Force -Path $logDir, $reportDir, (Split-Path $OutputIso) | Out-Null

Start-Transcript -Path (Join-Path $logDir ("Build-CustomIso-{0:yyyyMMdd-HHmmss}.log" -f (Get-Date))) | Out-Null

$manifest = [ordered]@{
    builtAt        = (Get-Date).ToString('s')
    builtOn        = $env:COMPUTERNAME
    sourceIso      = Split-Path $SourceIso -Leaf
    sourceSha256   = $null
    image          = $null
    unattended     = [bool]$Unattended
    removedAppx    = @()
    removedCaps    = @()
    removedFeatures = @()
    disabledServices = @()
    registry       = @()
    toolchain      = $null
}
$isoMounted = $false
$wimMounted = $false

try {
    # --- 1. read the source ISO ------------------------------------------------------
    Write-Step "Mounting source ISO $SourceIso"
    $disk = Mount-DiskImage -ImagePath $SourceIso -PassThru
    $isoMounted = $true
    $vol = Get-Volume -DiskImage $disk
    if (-not $vol.DriveLetter) { throw 'The mounted ISO got no drive letter (already mounted elsewhere, or automount disabled?).' }
    $srcRoot = "$($vol.DriveLetter):\"
    $srcWim = @('sources\install.wim', 'sources\install.esd') |
        ForEach-Object { Join-Path $srcRoot $_ } | Where-Object { Test-Path $_ } | Select-Object -First 1
    if (-not $srcWim) { throw 'No sources\install.wim or install.esd on the ISO.' }

    $images = Get-WindowsImage -ImagePath $srcWim
    if ($ListImages) {
        $images | Format-Table ImageIndex, ImageName, @{n = 'SizeGB'; e = { [math]::Round($_.ImageSize / 1GB, 1) } } -AutoSize
        return
    }

    $selected = if ($PSCmdlet.ParameterSetName -eq 'ByIndex') {
        $images | Where-Object ImageIndex -eq $ImageIndex
    } else {
        $images | Where-Object ImageName -eq $ImageName
    }
    if (-not $selected) {
        $names = ($images | ForEach-Object { "  [$($_.ImageIndex)] $($_.ImageName)" }) -join "`n"
        throw "Edition not found on the ISO. Available:`n$names`nUse -ImageName '<name>' or -ImageIndex <n>."
    }
    $manifest.image = [ordered]@{ index = $selected.ImageIndex; name = $selected.ImageName }
    Write-Info "Edition: [$($selected.ImageIndex)] $($selected.ImageName)"

    if (-not $ListOnly) {
        Write-Step 'Hashing source ISO'
        $manifest.sourceSha256 = (Get-FileHash -Algorithm SHA256 $SourceIso).Hash.ToLower()

        Write-Step "Copying ISO contents to $isoDir"
        if (Test-Path $isoDir) { Remove-Item $isoDir -Recurse -Force }
        Copy-Tree $srcRoot $isoDir
        Get-ChildItem $isoDir -Recurse -File | Where-Object IsReadOnly | ForEach-Object { $_.IsReadOnly = $false }
        Remove-Item (Join-Path $isoDir 'sources\install.wim'), (Join-Path $isoDir 'sources\install.esd'), (Join-Path $isoDir 'autounattend.xml') -ErrorAction SilentlyContinue
    }

    # --- 2. export only the selected edition --------------------------------------------
    $wim = Join-Path $WorkDir 'install.wim'
    Remove-Item $wim -ErrorAction SilentlyContinue
    Write-Step 'Exporting the selected edition to a new install.wim'
    Export-WindowsImage -SourceImagePath $srcWim -SourceIndex $selected.ImageIndex `
        -DestinationImagePath $wim -CompressionType max | Out-Null

    Dismount-DiskImage -ImagePath $SourceIso | Out-Null
    $isoMounted = $false

    # --- 3. mount ---------------------------------------------------------------------
    Get-WindowsImage -Mounted | Where-Object { $_.Path -eq $mountDir } |
        ForEach-Object { Dismount-WindowsImage -Path $mountDir -Discard | Out-Null }
    & (Join-Path $PSScriptRoot 'Clean-Workdir.ps1') -WorkDir $WorkDir -MountOnly
    New-Item -ItemType Directory -Path $mountDir | Out-Null

    Write-Step "Mounting install.wim at $mountDir"
    Mount-WindowsImage -ImagePath $wim -Index 1 -Path $mountDir | Out-Null
    $wimMounted = $true

    # --- inventory (always written; -ListOnly stops here) ---------------------------------
    Write-Step "Writing inventory to $reportDir"
    # Server Core has no Appx/Store stack, so Get-AppxProvisionedPackage fails with
    # 'module not found' there. Treat that as "no packages" instead of aborting.
    function Get-AppxSafe {
        try { @(Get-AppxProvisionedPackage -Path $mountDir -ErrorAction Stop) }
        catch { Write-Info "Appx provisioning not available in this image (normal for Server Core): skipping"; @() }
    }
    function Get-CapabilitiesSafe {
        try { @(Get-WindowsCapability -Path $mountDir -ErrorAction Stop) }
        catch { Write-Warning "Capabilities not readable in this image: $($_.Exception.Message)"; @() }
    }
    Get-AppxSafe | Select-Object DisplayName, PackageName, Version |
        Export-Csv -NoTypeInformation (Join-Path $reportDir 'appx.csv')
    Get-CapabilitiesSafe | Select-Object Name, State |
        Export-Csv -NoTypeInformation (Join-Path $reportDir 'capabilities.csv')
    Get-WindowsOptionalFeature -Path $mountDir | Select-Object FeatureName, State |
        Export-Csv -NoTypeInformation (Join-Path $reportDir 'features.csv')
    if ($ListOnly) {
        Write-Info 'ListOnly: discarding mount. Edit config\debloat.psd1 using the CSVs, then run without -ListOnly.'
        return
    }

    # --- 4. debloat ---------------------------------------------------------------------
    if (-not $SkipDebloat) {
        $db = Import-PowerShellDataFile $DebloatConfig

        Write-Step 'Removing provisioned Appx packages'
        foreach ($pkg in Get-AppxSafe) {
            if ($db.AppxPatterns | Where-Object { $pkg.DisplayName -like $_ }) {
                Write-Info "remove $($pkg.DisplayName)"
                Remove-AppxProvisionedPackage -Path $mountDir -PackageName $pkg.PackageName | Out-Null
                $manifest.removedAppx += $pkg.DisplayName
            }
        }

        Write-Step 'Removing capabilities'
        foreach ($cap in Get-CapabilitiesSafe | Where-Object State -eq 'Installed') {
            if ($db.CapabilityPatterns | Where-Object { $cap.Name -like $_ }) {
                Write-Info "remove $($cap.Name)"
                try {
                    Remove-WindowsCapability -Path $mountDir -Name $cap.Name | Out-Null
                    $manifest.removedCaps += $cap.Name
                } catch { Write-Warning "could not remove $($cap.Name): $($_.Exception.Message)" }
            }
        }

        Write-Step 'Disabling and removing optional features'
        $featureList = @($db.Features)
        if ($RemoveDefender) { $featureList += $db.DefenderFeatures }
        # 'Disabled' features still carry their payload; remove it too.
        $present = Get-WindowsOptionalFeature -Path $mountDir | Where-Object { $_.State -in 'Enabled', 'Disabled' }
        foreach ($f in $present | Where-Object { $featureList -contains $_.FeatureName }) {
            Write-Info "remove $($f.FeatureName)"
            try {
                Disable-WindowsOptionalFeature -Path $mountDir -FeatureName $f.FeatureName -Remove -NoRestart | Out-Null
                $manifest.removedFeatures += $f.FeatureName
            } catch { Write-Warning "could not remove $($f.FeatureName): $($_.Exception.Message)" }
        }

        Write-Step 'Offline registry: services and policies'
        $hives = @{
            SOFTWARE = @{ Mount = 'HKLM\CDLL_SOFTWARE'; File = 'Windows\System32\config\SOFTWARE'; Prefix = '' }
            SYSTEM   = @{ Mount = 'HKLM\CDLL_SYSTEM';   File = 'Windows\System32\config\SYSTEM';   Prefix = 'ControlSet001\' }
        }
        $loaded = @()
        try {
            foreach ($h in $hives.Values) {
                Invoke-Native reg.exe @('load', $h.Mount, (Join-Path $mountDir $h.File)) | Out-Null
                $loaded += $h.Mount
            }
            foreach ($svc in $db.DisableServices) {
                $key = "$($hives.SYSTEM.Mount)\ControlSet001\Services\$svc"
                # via cmd so stderr redirection does not become a terminating error in PS 5.1
                cmd.exe /c "reg query `"$key`" >nul 2>&1"
                if ($LASTEXITCODE -eq 0) {
                    Invoke-Native reg.exe @('add', $key, '/v', 'Start', '/t', 'REG_DWORD', '/d', '4', '/f') | Out-Null
                    Write-Info "disable service $svc"
                    $manifest.disabledServices += $svc
                }
            }
            foreach ($r in $db.Registry) {
                $h = $hives[$r.Hive]
                $key = "$($h.Mount)\$($h.Prefix)$($r.Key)"
                Invoke-Native reg.exe @('add', $key, '/v', $r.Name, '/t', $r.Type, '/d', $r.Value, '/f') | Out-Null
                Write-Info "set $($r.Hive)\$($r.Key)\$($r.Name) = $($r.Value)"
                $manifest.registry += "$($r.Hive)\$($r.Key)\$($r.Name)=$($r.Value)"
            }
        }
        finally {
            [GC]::Collect(); [GC]::WaitForPendingFinalizers()
            foreach ($m in $loaded) {
                for ($i = 0; $i -lt 5; $i++) {
                    cmd.exe /c "reg unload $m >nul 2>&1"
                    if ($LASTEXITCODE -eq 0) { break }
                    Start-Sleep -Seconds 2
                }
                # Warn rather than throw here, so an earlier error is not masked.
                if ($LASTEXITCODE -ne 0) { Write-Warning "could not unload $m - run: reg unload $m" }
            }
        }
    }

    # --- 5. shrink the component store -------------------------------------------------------
    if (-not $SkipCleanup) {
        Write-Step 'Component store cleanup (/StartComponentCleanup /ResetBase)'
        Invoke-Native dism.exe @("/Image:$mountDir", '/Cleanup-Image', '/StartComponentCleanup', '/ResetBase')
    }

    # --- 6. embed the toolchain -------------------------------------------------------------
    if (-not $SkipToolchain) {
        Write-Step 'Embedding toolchain payload into C:\Setup'
        $tc = Import-PowerShellDataFile $ToolchainConfig
        foreach ($tool in $tc.Tools) {
            $zip = Join-Path $payload ('tools\' + [IO.Path]::GetFileName($tool.Url))
            if (-not (Test-Path $zip)) { throw "Missing $zip - run .\Prepare-Payload.ps1 -WorkDir $WorkDir first." }
        }
        $setup = Join-Path $mountDir 'Setup'
        New-Item -ItemType Directory -Force -Path $setup | Out-Null
        Copy-Tree (Join-Path $payload 'tools') (Join-Path $setup 'tools')
        if (Test-Path (Join-Path $payload 'vslayout')) {
            Write-Info 'copying VS offline layout (several GB)...'
            Copy-Tree (Join-Path $payload 'vslayout') (Join-Path $setup 'vslayout')
        } else {
            Write-Warning 'No VS layout in payload: the ISO will have CMake/Ninja but no MSVC.'
        }
        Copy-Item (Join-Path $PSScriptRoot 'payload\Setup\Install-Toolchain.ps1') $setup -Force
        Copy-Item $ToolchainConfig (Join-Path $setup 'toolchain.psd1') -Force
        if (Test-Path (Join-Path $payload 'payload.json')) { Copy-Item (Join-Path $payload 'payload.json') $setup -Force }

        $scripts = Join-Path $mountDir 'Windows\Setup\Scripts'
        New-Item -ItemType Directory -Force -Path $scripts | Out-Null
        if (Test-Path (Join-Path $scripts 'SetupComplete.cmd')) { Write-Warning 'Image already has SetupComplete.cmd; replacing it.' }
        Copy-Item (Join-Path $PSScriptRoot 'payload\Setup\SetupComplete.cmd') $scripts -Force

        $manifest.toolchain = [ordered]@{
            vsComponents = $tc.VisualStudio.Components
            vsLayout     = (Test-Path (Join-Path $setup 'vslayout'))
            tools        = @($tc.Tools | ForEach-Object { [ordered]@{ name = $_.Name; url = $_.Url; sha256 = $_.Sha256 } })
        }
    }

    # --- 7. commit and compact -------------------------------------------------------------
    Write-Step 'Saving and unmounting install.wim'
    Dismount-WindowsImage -Path $mountDir -Save | Out-Null
    $wimMounted = $false

    Write-Step 'Re-exporting install.wim (drops deleted payload, max compression)'
    $finalWim = Join-Path $isoDir 'sources\install.wim'
    Export-WindowsImage -SourceImagePath $wim -SourceIndex 1 -DestinationImagePath $finalWim -CompressionType max | Out-Null
    Remove-Item $wim -Force

    # --- 8. optional answer file ----------------------------------------------------------
    $efiName = 'efisys.bin'
    if ($Unattended) {
        Write-Step 'Writing autounattend.xml (fully automatic install - wipes disk 0)'
        $xml = Get-Content -Raw (Join-Path $PSScriptRoot 'unattend\autounattend.template.xml')
        $keyBlock = ''
        if ($ProductKey) {
            $keyBlock = "<ProductKey><Key>$([Security.SecurityElement]::Escape($ProductKey))</Key><WillShowUI>OnError</WillShowUI></ProductKey>"
        }
        $xml = $xml.Replace('{{ADMIN_PASSWORD}}', [Security.SecurityElement]::Escape($AdminPassword)).Replace('{{PRODUCT_KEY_BLOCK}}', $keyBlock)
        [IO.File]::WriteAllText((Join-Path $isoDir 'autounattend.xml'), $xml, (New-Object Text.UTF8Encoding($false)))
        if (Test-Path (Join-Path $isoDir 'efi\microsoft\boot\efisys_noprompt.bin')) { $efiName = 'efisys_noprompt.bin' }
    }

    # --- 9. build the ISO (BIOS + UEFI bootable) ----------------------------------------------
    Write-Step "Building $OutputIso"
    $oscdimg = Find-Oscdimg
    $etfs = Join-Path $isoDir 'boot\etfsboot.com'
    $efi  = Join-Path $isoDir "efi\microsoft\boot\$efiName"
    Remove-Item $OutputIso -ErrorAction SilentlyContinue
    Invoke-Native $oscdimg @('-m', '-o', '-u2', '-udfver102', "-l$Label",
        "-bootdata:2#p0,e,b$etfs#pEF,e,b$efi", $isoDir, $OutputIso)

    $hash = (Get-FileHash -Algorithm SHA256 $OutputIso).Hash.ToLower()
    $isoName = Split-Path $OutputIso -Leaf
    Set-Content -Encoding ASCII -Path "$OutputIso.sha256" -Value "$hash  $isoName"
    $manifest.outputIso = $isoName
    $manifest.outputSha256 = $hash
    $manifest.outputSizeGB = [math]::Round((Get-Item $OutputIso).Length / 1GB, 2)
    $manifestPath = [IO.Path]::ChangeExtension($OutputIso, '.manifest.json')
    [IO.File]::WriteAllText($manifestPath, ($manifest | ConvertTo-Json -Depth 6), (New-Object Text.UTF8Encoding($false)))

    Write-Step 'Done'
    Write-Info "ISO:      $OutputIso ($($manifest.outputSizeGB) GB)"
    Write-Info "SHA-256:  $hash"
    Write-Info "Manifest: $manifestPath"
    Write-Info 'Copy all three files to the Linux host, e.g.:'
    Write-Info "  scp `"$OutputIso`" `"$OutputIso.sha256`" `"$manifestPath`" yujen@192.168.11.76:~/CMake_DLL/qemu/windows/iso/"
}
catch {
    Write-Host "`nFAILED: $($_.Exception.Message)" -ForegroundColor Red
    throw
}
finally {
    if ($wimMounted) {
        Write-Host 'Discarding mounted image...'
        Dismount-WindowsImage -Path $mountDir -Discard -ErrorAction SilentlyContinue | Out-Null
    }
    if ($isoMounted) { Dismount-DiskImage -ImagePath $SourceIso -ErrorAction SilentlyContinue | Out-Null }
    Stop-Transcript | Out-Null
}
