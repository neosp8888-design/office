$ErrorActionPreference = "Stop"

$root = "G:\StellarBladeModding"
$bundle = "$env:USERPROFILE\Downloads\officestra-sb-setup"
$downloads = "$root\Downloads"
$tools = "$root\Tools"
$addons = "$tools\BlenderAddons"
$mappings = "$root\Mappings"
$docs = "$root\Docs"
$workspace = "$root\Workspace"
$backups = "$root\Backups"
$logs = "$root\Logs"
$blenderRoot = "$tools\blender-4.4.3-windows-x64"

if (-not (Test-Path "$blenderRoot\blender.exe")) { throw "Blender executable is missing" }
if (-not (Test-Path "$tools\FModel\FModel.exe")) { throw "FModel executable is missing" }
if (-not ((& "C:\Program Files\dotnet\dotnet.exe" --list-runtimes) -match "Microsoft.WindowsDesktop.App 10\.0\.11")) {
    throw ".NET Desktop Runtime 10.0.11 is missing"
}

$portableAddons = "$blenderRoot\portable\scripts\addons"
New-Item -ItemType Directory -Force $portableAddons | Out-Null
Copy-Item "$blenderRoot\4.4\scripts\addons\io_scene_ueformat" $portableAddons -Recurse -Force
Copy-Item "$blenderRoot\4.4\scripts\addons\io_scene_psk_psa" $portableAddons -Recurse -Force

$fbxSource = "$addons\Blender_SB_FBX_Fixes"
$fbxCommit = (& git -C $fbxSource rev-parse HEAD).Trim()
if ($fbxCommit -ne "4ec7b6334e7b7583525cc5b2789ba9e41e85f579") { throw "Unexpected FBX fixes commit: $fbxCommit" }
$fbxTarget = "$blenderRoot\4.4\scripts\addons_core\io_scene_fbx"
if (-not (Select-String -Path "$fbxTarget\*.py" -Pattern "Inverted Bones" -Quiet)) {
    throw "Stellar Blade FBX fix is not present in Blender exporter"
}

$guideCommit = (& git -C "$docs\Stellar-Blade-Modding-Guide" rev-parse HEAD).Trim()
$wikiCommit = (& git -C "$docs\Stellar-Blade-Modding-Guide-Wiki" rev-parse HEAD).Trim()
$prmzlCommit = (& git -C "$tools\PRMZL" rev-parse HEAD).Trim()
if ($guideCommit -ne "141310032560cf5bf79699a43789f6e14a84e9e6") { throw "Unexpected guide commit" }
if ($prmzlCommit -ne "9d0c8fb0b3927d9c0f02e6362ab4a922d54162d5") { throw "Unexpected PRMZL commit" }

Copy-Item "$bundle\configure_blender.py" "$root\configure_blender.py" -Force
Copy-Item "$bundle\README-KO.md" "$root\README-KO.md" -Force
Copy-Item "$bundle\Launch-FModel.cmd" "$root\Launch-FModel.cmd" -Force
Copy-Item "$bundle\Launch-Blender-4.4.cmd" "$root\Launch-Blender-4.4.cmd" -Force
Copy-Item "$bundle\Open-Workspace.cmd" "$root\Open-Workspace.cmd" -Force

$stdout = "$logs\blender-configure.stdout.log"
$stderr = "$logs\blender-configure.stderr.log"
$blenderRun = Start-Process `
    -FilePath "$blenderRoot\blender.exe" `
    -ArgumentList @("--background", "--factory-startup", "--python", "$root\configure_blender.py") `
    -WorkingDirectory $blenderRoot `
    -RedirectStandardOutput $stdout `
    -RedirectStandardError $stderr `
    -Wait `
    -PassThru
Get-Content $stdout -ErrorAction SilentlyContinue
Get-Content $stderr -ErrorAction SilentlyContinue
if ($blenderRun.ExitCode -ne 0) { throw "Blender add-on configuration failed with exit $($blenderRun.ExitCode)" }

$downloadFiles = @(
    "$downloads\windowsdesktop-runtime-10.0.11-win-x64.exe",
    "$downloads\blender-4.4.3-windows-x64.zip",
    "$downloads\FModel-aug-2026.zip",
    "$downloads\ueformat-blender-v10.zip",
    "$downloads\io_scene_psk_psa-7.1.0.zip",
    "$mappings\StellarBlade_1.1.0.usmap",
    "$mappings\StellarBlade_1.4.1.usmap",
    "$mappings\StellarBlade_UE4.26.idmap"
)
$downloadRecords = foreach ($path in $downloadFiles) {
    $file = Get-Item $path
    [PSCustomObject]@{
        path = $file.FullName
        size = $file.Length
        sha256 = (Get-FileHash -Algorithm SHA256 $file.FullName).Hash.ToLowerInvariant()
    }
}

$manifest = [PSCustomObject]@{
    installedAt = (Get-Date -Format o)
    root = $root
    game = "H:\SteamLibrary\steamapps\common\StellarBlade"
    gameBuildId = "24463856"
    existingModFiles = 78
    blender = [PSCustomObject]@{
        version = "4.4.3"
        path = "$blenderRoot\blender.exe"
        isolatedPortableConfig = "$blenderRoot\portable"
        fbxFixCommit = $fbxCommit
        enabledAddons = @("io_scene_ueformat", "io_scene_psk_psa", "io_scene_fbx")
    }
    fmodel = [PSCustomObject]@{
        release = "aug-2026"
        path = "$tools\FModel\FModel.exe"
    }
    guideCommit = $guideCommit
    wikiCommit = $wikiCommit
    prmzlCommit = $prmzlCommit
    visualStudio = "C:\Program Files (x86)\Microsoft Visual Studio\2019\BuildTools"
    unrealEngine = [PSCustomObject]@{
        requiredVersion = "4.26"
        installTarget = "G:\StellarBladeModding\UnrealEngine\UE_4.26"
        status = "pending_epic_launcher_user_install"
    }
    files = $downloadRecords
}
$manifest | ConvertTo-Json -Depth 8 | Set-Content "$root\install-manifest.json" -Encoding utf8

Get-ChildItem "H:\SteamLibrary\steamapps\common\StellarBlade\SB\Content\Paks\~mods" -File -ErrorAction SilentlyContinue |
    Select-Object Name,Length,LastWriteTime |
    Export-Csv "$backups\existing-mods-manifest.csv" -NoTypeInformation -Encoding utf8

"SETUP_CONTINUE_COMPLETE"
"BLENDER_USER_CONFIG=" + (& "$blenderRoot\blender.exe" --background --python-expr "import bpy; print(bpy.utils.user_resource('CONFIG'))" 2>$null | Select-String "G:\\StellarBladeModding" | Select-Object -Last 1)
"G_FREE_GB=" + [math]::Round((Get-Volume -DriveLetter G).SizeRemaining / 1GB, 2)
