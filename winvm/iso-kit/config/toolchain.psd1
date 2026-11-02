# What gets embedded in the ISO and installed during Windows Setup.
# Bump versions here; Prepare-Payload.ps1 verifies every download against Sha256.
@{
    VisualStudio = @{
        Bootstrapper = 'https://aka.ms/vs/17/release/vs_buildtools.exe'
        InstallPath  = 'C:\BuildTools'
        Language     = 'en-US'
        # Same components the old docker/windows/Dockerfile installed.
        Components   = @(
            'Microsoft.VisualStudio.Workload.VCTools'
            'Microsoft.VisualStudio.Component.VC.CMake.Project'
        )
        IncludeRecommended = $true
    }

    Tools = @(
        @{
            Name     = 'cmake'
            Url      = 'https://github.com/Kitware/CMake/releases/download/v4.1.2/cmake-4.1.2-windows-x86_64.zip'
            Sha256   = '82730741149681597510a4bc7095da1460b472dac24eaf9c23ad7440f47753ab'
            Dest     = 'C:\Tools\cmake'
            PathDirs = @('C:\Tools\cmake\bin')
        }
        @{
            Name     = 'ninja'
            Url      = 'https://github.com/ninja-build/ninja/releases/download/v1.12.1/ninja-win.zip'
            Sha256   = 'f550fec705b6d6ff58f2db3c374c2277a37691678d6aba463adcbb129108467a'
            Dest     = 'C:\Tools\ninja'
            PathDirs = @('C:\Tools\ninja')
        }
    )
}
