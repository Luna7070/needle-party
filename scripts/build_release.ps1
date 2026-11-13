# Builds the release zip: release\NeedleParty-<version>.zip
# Contains only what players need: the mod, the installer, README.txt, LICENSE.
# Run from the repository root:  powershell -ExecutionPolicy Bypass -File scripts\build_release.ps1
$ErrorActionPreference = "Stop"
$root = Split-Path -Parent (Split-Path -Parent $MyInvocation.MyCommand.Path)
$mp = Join-Path $root "mods\needle_party\mp.gd"
$m = [regex]::Match((Get-Content $mp -Raw), 'const VERSION := "([^"]+)"')
if (-not $m.Success) { throw "VERSION not found in $mp" }
$version = $m.Groups[1].Value

$out = Join-Path $root "release"
$stage = Join-Path $out "stage"
if (Test-Path $stage) { Remove-Item $stage -Recurse -Force }
New-Item -ItemType Directory -Force "$stage\mods", "$stage\installer" | Out-Null

Copy-Item (Join-Path $root "mods\needle_party") "$stage\mods\needle_party" -Recurse
# dev hooks only load files that are not shipped; make sure none slipped in
Get-ChildItem "$stage\mods\needle_party" -Filter "mp_probe*.gd" | Remove-Item
Get-ChildItem "$stage\mods\needle_party" -Filter "mp_selftest*.gd" | Remove-Item
# no binary ever ships (2026-11-16, owner: no DLL, Smart App Control blocks unsigned ones):
# the dev belt core in mods\needle_party\native stays out, and any other library too
if (Test-Path "$stage\mods\needle_party\native") { Remove-Item "$stage\mods\needle_party\native" -Recurse -Force }
Get-ChildItem "$stage\mods\needle_party" -Recurse -Include "*.dll", "*.so", "*.dylib", "*.exe", "*.np-orig" | Remove-Item -Force
# the test build's log reporter and its webhook address never go in a release
Get-ChildItem "$stage\mods\needle_party" -Filter "mp_report*.gd" | Remove-Item
Get-ChildItem "$stage\mods\needle_party" -Filter "report.cfg" | Remove-Item
# the test tool's remote control never goes in a release either
Get-ChildItem "$stage\mods\needle_party" -Filter "mp_control*.gd" | Remove-Item
Get-ChildItem "$stage\mods\needle_party" -Filter "ctl.cfg" | Remove-Item
# Where anonymous logs go (mp_logs.gd): not in the repository. Without it the zip sends nothing.
$logs = Join-Path $out "logs.cfg"
if (Test-Path $logs) {
    # scrambled among random bytes (see mp_logs.gd: this is not protection)
    # anchored: a plain 'url=' would also match inside 'beta_url='
    $url = [regex]::Match((Get-Content $logs -Raw), '(?m)^\s*url\s*=\s*"([^"]+)"').Groups[1].Value
    if ($url -eq "") { throw "release\logs.cfg has no url" }
    $sha = [Security.Cryptography.SHA256]::Create()
    $key = $sha.ComputeHash([Text.Encoding]::UTF8.GetBytes("needle-rig-1733"))
    $bytes = [Text.Encoding]::UTF8.GetBytes($url)
    $rig = New-Object byte[] 4096
    (New-Object Security.Cryptography.RNGCryptoServiceProvider).GetBytes($rig)
    $rig[1732] = [byte]($bytes.Length -bxor $key[0])
    for ($i = 0; $i -lt $bytes.Length; $i++) { $rig[1733 + $i] = [byte]($bytes[$i] -bxor $key[($i + 1) % $key.Length]) }
    # players on the game's Steam beta: a second address (beta_url) at 2733, its own key
    $burl = [regex]::Match((Get-Content $logs -Raw), '(?m)^\s*beta_url\s*=\s*"([^"]+)"').Groups[1].Value
    $bkey = $sha.ComputeHash([Text.Encoding]::UTF8.GetBytes("needle-rig-2733"))
    $rig[2732] = [byte]$bkey[0]   # length 0 = no beta address (else random bytes would be read as one)
    if ($burl -ne "") {
        $bb = [Text.Encoding]::UTF8.GetBytes($burl)
        # the length is one byte, and the first address must end before 2732
        if ($bytes.Length -gt 255 -or $bb.Length -gt 255) { throw "webhook address too long for rig.dat" }
        $rig[2732] = [byte]($bb.Length -bxor $bkey[0])
        for ($i = 0; $i -lt $bb.Length; $i++) { $rig[2733 + $i] = [byte]($bb[$i] -bxor $bkey[($i + 1) % $bkey.Length]) }
    }
    [IO.File]::WriteAllBytes("$stage\mods\needle_party\models\rig.dat", $rig)
} else {
    Write-Host "No release\logs.cfg: this zip sends no logs"
}
Copy-Item (Join-Path $root "installer\install.ps1") "$stage\installer\"
Copy-Item (Join-Path $root "install.bat"), (Join-Path $root "uninstall.bat") $stage
Copy-Item (Join-Path $root "LICENSE") "$stage\LICENSE.txt"
Copy-Item (Join-Path $root "docs\README.txt") "$stage\README.txt"

$zip = Join-Path $out "NeedleParty-$version.zip"
if (Test-Path $zip) { Remove-Item $zip }
Compress-Archive -Path "$stage\*" -DestinationPath $zip

# The same mod without installer scripts: Nexus quarantines .bat and .ps1 files
foreach ($p in @("$stage\installer", "$stage\install.bat", "$stage\uninstall.bat")) { Remove-Item $p -Recurse -Force }
$manual = @"
NEEDLE PARTY $version - Find The Needle multiplayer mod. Made by Luna and Lolfa.

EASY INSTALL (recommended): get the one-click installer here:
https://github.com/Luna7070/needle-party/releases/latest

MANUAL INSTALL:
1. Close the game. Back up your saves.
2. Copy the "mods" folder into the game folder (next to FindTheNeedle.exe).
3. Open or create override.cfg in the game folder and add:

[autoload]

MPMod="*mods/needle_party/mp.gd"

[steam]

multiplayer_peer/max_channels=16

[debug]

settings/gdscript/always_track_call_stacks=true

4. Start the game from Steam, then NEEDLE PARTY in the main menu.

Everyone needs the same version.
Unofficial mod, not affiliated with FindTheNeedleDev.
"@
Set-Content "$stage\README.txt" $manual -Encoding utf8
$manualZip = Join-Path $out "NeedleParty-$version-manual.zip"
if (Test-Path $manualZip) { Remove-Item $manualZip }
Compress-Archive -Path "$stage\*" -DestinationPath $manualZip
Remove-Item $stage -Recurse -Force
Write-Host "Built $zip and $manualZip"
