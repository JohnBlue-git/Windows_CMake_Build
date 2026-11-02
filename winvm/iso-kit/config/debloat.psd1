# What Build-CustomIso.ps1 removes or changes inside install.wim.
# Entries that don't exist in the chosen image are skipped and logged, so the
# same list works for Server Core and Desktop Experience.
# Run  Build-CustomIso.ps1 -ListOnly  to see what your image actually contains.
@{
    # Provisioned (pre-installed) Store apps, matched with -like on DisplayName.
    # Server Core has none; Desktop Experience has a few.
    AppxPatterns = @(
        '*Xbox*'
        '*Zune*'
        '*Bing*'
        '*Solitaire*'
        '*GetHelp*'
        '*Getstarted*'
        '*MicrosoftOfficeHub*'
        '*People*'
        '*SkypeApp*'
        '*YourPhone*'
        '*WindowsFeedbackHub*'
        '*WindowsMaps*'
        '*Microsoft.MixedReality*'
        '*Microsoft.549981C3F5F10*'   # Cortana
    )

    # Windows capabilities (Features on Demand), matched with -like on Name.
    CapabilityPatterns = @(
        'Browser.InternetExplorer*'
        'MathRecognizer*'
        'Media.WindowsMediaPlayer*'
        'Microsoft.Windows.WordPad*'
        'XPS.Viewer*'
        'Print.Fax.Scan*'
        'Hello.Face*'
        'App.StepsRecorder*'
        'App.Support.QuickAssist*'
        'Microsoft.Windows.PowerShell.ISE*'
    )

    # Optional features to disable AND delete the payload of (-Remove).
    # Removed payloads can only be restored from install media.
    Features = @(
        'Printing-XPSServices-Features'
        'Printing-PrintToPDFServices-Features'
        'WorkFolders-Client'
        'MediaPlayback'
        'WindowsMediaPlayer'
        'SearchEngine-Client-Package'
        'Internet-Explorer-Optional-amd64'
        'SMB1Protocol'
        'MicrosoftWindowsPowerShellV2'
        'MicrosoftWindowsPowerShellV2Root'
        'Xps-Foundation-Xps-Viewer'
    )

    # Optional: Microsoft Defender. Removing it makes builds noticeably faster
    # but leaves the VM without antivirus. Enabled with -RemoveDefender.
    DefenderFeatures = @(
        'Windows-Defender'
    )

    # Services set to Disabled (Start=4) in the offline SYSTEM hive.
    DisableServices = @(
        'DiagTrack'          # telemetry
        'dmwappushservice'   # WAP push (telemetry)
        'MapsBroker'         # downloaded maps
        'WSearch'            # search indexer (slows builds)
        'Spooler'            # print spooler (not needed; frequent CVEs)
        'XblAuthManager'
        'XblGameSave'
        'XboxNetApiSvc'
        'XboxGipSvc'
        'lfsvc'              # geolocation
        'RetailDemo'
    )

    # Offline registry values. Hive is SOFTWARE or SYSTEM (ControlSet001).
    Registry = @(
        @{ Hive='SOFTWARE'; Key='Policies\Microsoft\Windows\DataCollection'; Name='AllowTelemetry';             Type='REG_DWORD'; Value='0' }
        @{ Hive='SOFTWARE'; Key='Microsoft\ServerManager';                   Name='DoNotOpenServerManagerAtLogon'; Type='REG_DWORD'; Value='1' }
        @{ Hive='SOFTWARE'; Key='Policies\Microsoft\Windows\CloudContent';    Name='DisableWindowsConsumerFeatures'; Type='REG_DWORD'; Value='1' }
        @{ Hive='SOFTWARE'; Key='Policies\Microsoft\Windows\GameDVR';         Name='AllowGameDVR';                Type='REG_DWORD'; Value='0' }
        @{ Hive='SOFTWARE'; Key='Policies\Microsoft\Windows\Windows Error Reporting'; Name='Disabled';            Type='REG_DWORD'; Value='1' }
        # Long paths: deep CMake build trees exceed MAX_PATH easily.
        @{ Hive='SYSTEM';   Key='Control\FileSystem';                        Name='LongPathsEnabled';            Type='REG_DWORD'; Value='1' }
        # Keep Defender (if present) away from build directories.
        @{ Hive='SOFTWARE'; Key='Policies\Microsoft\Windows Defender\Exclusions'; Name='Exclusions_Paths';       Type='REG_DWORD'; Value='1' }
        @{ Hive='SOFTWARE'; Key='Policies\Microsoft\Windows Defender\Exclusions\Paths'; Name='C:\work';          Type='REG_SZ'   ; Value='0' }
        @{ Hive='SOFTWARE'; Key='Policies\Microsoft\Windows Defender\Exclusions\Paths'; Name='C:\BuildTools';    Type='REG_SZ'   ; Value='0' }
        @{ Hive='SOFTWARE'; Key='Policies\Microsoft\Windows Defender\Exclusions\Paths'; Name='C:\Tools';         Type='REG_SZ'   ; Value='0' }
    )
}
