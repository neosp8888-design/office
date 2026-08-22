$ErrorActionPreference = "Stop"
$ProgressPreference = "SilentlyContinue"

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

if (Test-Path $root) {
    $existing = Get-ChildItem $root -Force -ErrorAction SilentlyContinue
    if ($existing.Count -gt 0) {
        throw "Refusing to overwrite non-empty directory: $root"
    }
}

$g = Get-Volume -DriveLetter G
if ($g.FileSystem -ne "NTFS") { throw "G drive must be NTFS" }
if ($g.SizeRemaining -lt 100GB) { throw "G drive needs at least 100GB free before setup" }

@($root, $downloads, $tools, $addons, $mappings, $docs, $workspace, $backups, $logs,
  "$workspace\FModel-Output", "$workspace\Blender", "$workspace\UnrealProjects",
  "$workspace\Packages", "$workspace\Temp") | ForEach-Object {
    New-Item -ItemType Directory -Force -Path $_ | Out-Null
}

function Get-VerifiedFile {
    param(
        [string]$Name,
        [string]$Url,
        [string]$Destination,
        [long]$ExpectedSize,
        [string]$Algorithm = "SHA256",
        [string]$ExpectedHash = ""
    )

    $partial = $Destination + ".part"
    if (-not (Test-Path $Destination)) {
        Write-Host "DOWNLOAD=$Name"
        & curl.exe -L --fail --retry 10 --retry-all-errors --retry-delay 4 --connect-timeout 30 -C - -o $partial $Url
        if ($LASTEXITCODE -ne 0) { throw "curl failed for $Name with exit $LASTEXITCODE" }
        Move-Item -LiteralPath $partial -Destination $Destination
    }

    $file = Get-Item $Destination
    if ($ExpectedSize -gt 0 -and $file.Length -ne $ExpectedSize) {
        throw "Size mismatch for ${Name}: got $($file.Length), expected $ExpectedSize"
    }

    $hash = (Get-FileHash -Algorithm $Algorithm $Destination).Hash.ToLowerInvariant()
    if ($ExpectedHash -and $hash -ne $ExpectedHash.ToLowerInvariant()) {
        throw "$Algorithm mismatch for $Name"
    }

    Write-Host "VERIFIED=$Name SIZE=$($file.Length) $Algorithm=$hash"
    [PSCustomObject]@{
        name = $Name
        path = $Destination
        source = $Url
        size = $file.Length
        algorithm = $Algorithm
        hash = $hash
    }
}

$records = @()
$records += Get-VerifiedFile `
    -Name ".NET 10 Desktop Runtime" `
    -Url "https://builds.dotnet.microsoft.com/dotnet/WindowsDesktop/10.0.11/windowsdesktop-runtime-10.0.11-win-x64.exe" `
    -Destination "$downloads\windowsdesktop-runtime-10.0.11-win-x64.exe" `
    -ExpectedSize 60001888 `
    -Algorithm "SHA512" `
    -ExpectedHash "4dbf26b0b78f55c5f59a46c3c81327b23a04f449f7ac6798204dcd19d99459258936daaede61d1b8c1ba523d6c26bf68bac86b3371d22e67cef235edbdc2f26c"

$records += Get-VerifiedFile `
    -Name "Blender 4.4.3 Portable" `
    -Url "https://download.blender.org/release/Blender4.4/blender-4.4.3-windows-x64.zip" `
    -Destination "$downloads\blender-4.4.3-windows-x64.zip" `
    -ExpectedSize 385412148 `
    -ExpectedHash "60a9703b07f2cf42509f699ccdec4f5ede71c1932f6c14329f0e14c023e27d5c"

$records += Get-VerifiedFile `
    -Name "FModel aug-2026" `
    -Url "https://github.com/4sval/FModel/releases/download/aug-2026/FModel.zip" `
    -Destination "$downloads\FModel-aug-2026.zip" `
    -ExpectedSize 20069380 `
    -ExpectedHash "ce1995fbc876cd0d0f54d3f7af5babc0e949d87fe4c4f2fada55c6e1e062eacc"

$records += Get-VerifiedFile `
    -Name "UEFormat Blender v10" `
    -Url "https://github.com/h4lfheart/UEFormat/releases/download/v10/ueformat-blender.zip" `
    -Destination "$downloads\ueformat-blender-v10.zip" `
    -ExpectedSize 35882 `
    -ExpectedHash "41d464da5278e5079311bd1be22ef9358cc7b280f07b81c648e298be9fae3cee"

$records += Get-VerifiedFile `
    -Name "PSK PSA Blender Addon 7.1.0" `
    -Url "https://github.com/DarklightGames/io_scene_psk_psa/releases/download/7.1.0/add-on-io-scene-psk-psa-v7.1.0.zip" `
    -Destination "$downloads\io_scene_psk_psa-7.1.0.zip" `
    -ExpectedSize 47926

$records += Get-VerifiedFile `
    -Name "Stellar Blade guide mapping 1.1.0" `
    -Url "https://raw.githubusercontent.com/Stellar-Blade-Modding-Team/Stellar-Blade-Modding-Guide/main/StellarBlade_1.1.0.usmap" `
    -Destination "$mappings\StellarBlade_1.1.0.usmap" `
    -ExpectedSize 451005

$records += Get-VerifiedFile `
    -Name "Stellar Blade mapping 1.4.1" `
    -Url "https://raw.githubusercontent.com/TheNaeem/Unreal-Mappings-Archive/main/Stellar%20Blade/1.4.1/Mappings.usmap" `
    -Destination "$mappings\StellarBlade_1.4.1.usmap" `
    -ExpectedSize 1877331

$records += Get-VerifiedFile `
    -Name "Stellar Blade UE 4.26 idmap" `
    -Url "https://raw.githubusercontent.com/Stellar-Blade-Modding-Team/Stellar-Blade-Modding-Guide/main/4.26.2-0%2B%2B%2BUE4%2BRelease-4.26-SB.idmap" `
    -Destination "$mappings\StellarBlade_UE4.26.idmap" `
    -ExpectedSize 556398

Write-Host "INSTALL=.NET 10 Desktop Runtime"
$dotnetInstall = Start-Process `
    -FilePath "$downloads\windowsdesktop-runtime-10.0.11-win-x64.exe" `
    -ArgumentList @("/install", "/quiet", "/norestart") `
    -Wait `
    -PassThru
if ($dotnetInstall.ExitCode -notin @(0, 1638, 3010)) {
    throw ".NET installer failed with exit $($dotnetInstall.ExitCode)"
}
"DOTNET_INSTALL_EXIT=" + $dotnetInstall.ExitCode | Set-Content "$logs\dotnet-install.txt" -Encoding ascii

Write-Host "EXTRACT=Blender 4.4.3"
Expand-Archive -LiteralPath "$downloads\blender-4.4.3-windows-x64.zip" -DestinationPath $tools -Force
$blenderRoot = "$tools\blender-4.4.3-windows-x64"
New-Item -ItemType Directory -Force "$blenderRoot\portable\scripts\addons" | Out-Null

Write-Host "EXTRACT=FModel"
New-Item -ItemType Directory -Force "$tools\FModel" | Out-Null
Expand-Archive -LiteralPath "$downloads\FModel-aug-2026.zip" -DestinationPath "$tools\FModel" -Force

Write-Host "INSTALL=Blender UEFormat v10"
Expand-Archive -LiteralPath "$downloads\ueformat-blender-v10.zip" -DestinationPath "$blenderRoot\portable\scripts\addons" -Force

Write-Host "INSTALL=Blender PSK PSA 7.1.0"
$pskAddon = "$blenderRoot\portable\scripts\addons\io_scene_psk_psa"
New-Item -ItemType Directory -Force $pskAddon | Out-Null
Expand-Archive -LiteralPath "$downloads\io_scene_psk_psa-7.1.0.zip" -DestinationPath $pskAddon -Force

Write-Host "CLONE=FBX exporter fixes"
$fbxSource = "$addons\Blender_SB_FBX_Fixes"
& git clone --depth 1 https://github.com/ByLemi21/Blender_SB_FBX_Fixes.git $fbxSource
if ($LASTEXITCODE -ne 0) { throw "Failed to clone Blender SB FBX fixes" }
$fbxCommit = (& git -C $fbxSource rev-parse HEAD).Trim()
if ($fbxCommit -ne "4ec7b6334e7b7583525cc5b2789ba9e41e85f579") { throw "Unexpected FBX fixes commit: $fbxCommit" }
$fbxTarget = "$blenderRoot\4.4\scripts\addons_core\io_scene_fbx"
$fbxBackup = "$backups\blender-4.4.3-default-io_scene_fbx"
Copy-Item $fbxTarget $fbxBackup -Recurse -Force
Remove-Item "$fbxTarget\*" -Recurse -Force
Copy-Item "$fbxSource\io_scene_fbx\*" $fbxTarget -Recurse -Force

Write-Host "CLONE=Stellar Blade guide"
& git clone --depth 1 https://github.com/Stellar-Blade-Modding-Team/Stellar-Blade-Modding-Guide.git "$docs\Stellar-Blade-Modding-Guide"
if ($LASTEXITCODE -ne 0) { throw "Failed to clone main guide" }
$guideCommit = (& git -C "$docs\Stellar-Blade-Modding-Guide" rev-parse HEAD).Trim()
if ($guideCommit -ne "141310032560cf5bf79699a43789f6e14a84e9e6") { throw "Unexpected guide commit: $guideCommit" }

Write-Host "CLONE=Stellar Blade guide wiki"
& git clone --depth 1 https://github.com/Stellar-Blade-Modding-Team/Stellar-Blade-Modding-Guide.wiki.git "$docs\Stellar-Blade-Modding-Guide-Wiki"
if ($LASTEXITCODE -ne 0) { throw "Failed to clone guide wiki" }
$wikiCommit = (& git -C "$docs\Stellar-Blade-Modding-Guide-Wiki" rev-parse HEAD).Trim()

Write-Host "CLONE=PRMZL packaging helper"
& git clone --depth 1 --branch Stellar-Blade https://github.com/Misberave/UE-Mod-PRMZL.git "$tools\PRMZL"
if ($LASTEXITCODE -ne 0) { throw "Failed to clone PRMZL" }
$prmzlCommit = (& git -C "$tools\PRMZL" rev-parse HEAD).Trim()
if ($prmzlCommit -ne "9d0c8fb0b3927d9c0f02e6362ab4a922d54162d5") { throw "Unexpected PRMZL commit: $prmzlCommit" }

Copy-Item "$bundle\configure_blender.py" "$root\configure_blender.py" -Force
Copy-Item "$bundle\README-KO.md" "$root\README-KO.md" -Force
Copy-Item "$bundle\Launch-FModel.cmd" "$root\Launch-FModel.cmd" -Force
Copy-Item "$bundle\Launch-Blender-4.4.cmd" "$root\Launch-Blender-4.4.cmd" -Force
Copy-Item "$bundle\Open-Workspace.cmd" "$root\Open-Workspace.cmd" -Force

Write-Host "CONFIGURE=Blender addons"
& "$blenderRoot\blender.exe" --background --factory-startup --python "$root\configure_blender.py" 2>&1 | Tee-Object "$logs\blender-configure.log"
if ($LASTEXITCODE -ne 0) { throw "Blender add-on configuration failed" }

$manifest = [PSCustomObject]@{
    installedAt = (Get-Date -Format o)
    root = $root
    game = "H:\SteamLibrary\steamapps\common\StellarBlade"
    gameBuildId = "24463856"
    blender = [PSCustomObject]@{
        version = "4.4.3"
        path = "$blenderRoot\blender.exe"
        isolatedPortableConfig = "$blenderRoot\portable"
        fbxFixCommit = $fbxCommit
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
    downloads = $records
}
$manifest | ConvertTo-Json -Depth 8 | Set-Content "$root\install-manifest.json" -Encoding utf8

Get-ChildItem "H:\SteamLibrary\steamapps\common\StellarBlade\SB\Content\Paks\~mods" -File -ErrorAction SilentlyContinue |
    Select-Object Name,Length,LastWriteTime |
    Export-Csv "$backups\existing-mods-manifest.csv" -NoTypeInformation -Encoding utf8

"SETUP_COMPLETE"
"ROOT=$root"
"BLENDER=$blenderRoot\blender.exe"
"FMODEL=" + (Get-ChildItem "$tools\FModel" -Filter FModel.exe -File -Recurse | Select-Object -First 1 -ExpandProperty FullName)
"G_FREE_GB=" + [math]::Round((Get-Volume -DriveLetter G).SizeRemaining / 1GB, 2)
