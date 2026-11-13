# NEEDLE PARTY - co-op for Find The Needle (made by Luna7070) - installer
# Based on AleDev11's FindTheNeedle-Coop-Mod (MIT). Unofficial mod.
#
#   install.ps1              install / update
#   install.ps1 -Uninstall   remove this mod (old mods stay in the backup folder)
#   install.ps1 -GameDir X   use this game folder instead of looking it up
#
# Old multiplayer mods are not destroyed: they are moved to
# <game>\mods_backup\<date>\ together with a copy of override.cfg.
param(
    [switch]$Uninstall,
    [string]$GameDir = "",
    [switch]$NoPause,
    [switch]$SkipRunningCheck   # for testing on a copy of the game folder
)
$ErrorActionPreference = "Stop"
$ModName   = "needle_party"
$Autoload  = 'MPMod="*mods/needle_party/mp.gd"'
$AppId     = "5160800"
$Here      = Split-Path -Parent $MyInvocation.MyCommand.Path
$Src       = Join-Path (Split-Path -Parent $Here) "mods\$ModName"
$Utf8      = New-Object System.Text.UTF8Encoding $false

function Say($msg, $color = "Gray") {
    # something to say in the middle of a step: it goes on its own line
    if ($script:StepOpen) { Write-Host ""; $script:StepOpen = $false }
    Write-Host $msg -ForegroundColor $color
}
# ---------------------------------------------------------------- how it looks
function Pause-Art($ms) { if (-not $NoPause) { Start-Sleep -Milliseconds $ms } }

function Show-Art($lines, $colors) {
    for ($i = 0; $i -lt $lines.Count; $i++) {
        Write-Host $lines[$i] -ForegroundColor $colors[[Math]::Min($i, $colors.Count - 1)]
        Pause-Art 22
    }
}

function Show-Band($color = "DarkYellow") { Say "  ══════════════════════════════════════════════════════════════════" $color }

function Show-Banner {
    try { if (-not $NoPause) { Clear-Host } } catch {}
    Say ""
    Show-Band
    Say ""
    Show-Art @(
        '     ███╗   ██╗███████╗███████╗██████╗ ██╗     ███████╗',
        '     ████╗  ██║██╔════╝██╔════╝██╔══██╗██║     ██╔════╝',
        '     ██╔██╗ ██║█████╗  █████╗  ██║  ██║██║     █████╗  ',
        '     ██║╚██╗██║██╔══╝  ██╔══╝  ██║  ██║██║     ██╔══╝  ',
        '     ██║ ╚████║███████╗███████╗██████╔╝███████╗███████╗',
        '     ╚═╝  ╚═══╝╚══════╝╚══════╝╚═════╝ ╚══════╝╚══════╝',
        '            ██████╗  █████╗ ██████╗ ████████╗██╗   ██╗',
        '            ██╔══██╗██╔══██╗██╔══██╗╚══██╔══╝╚██╗ ██╔╝',
        '            ██████╔╝███████║██████╔╝   ██║    ╚████╔╝ ',
        '            ██╔═══╝ ██╔══██║██╔══██╗   ██║     ╚██╔╝  ',
        '            ██║     ██║  ██║██║  ██║   ██║      ██║   ',
        '            ╚═╝     ╚═╝  ╚═╝╚═╝  ╚═╝   ╚═╝      ╚═╝   '
    ) @("Yellow", "Yellow", "Yellow", "DarkYellow", "DarkYellow", "DarkGray", "White", "White", "Yellow", "Yellow", "DarkYellow", "DarkGray")
    Say ""
}

function Show-Title($top, $bottom) {
    Say "  ╔══════════════════════════════════════════════════════════════════╗" "Yellow"
    Say ("  ║" + $top.PadLeft(33 + [int]($top.Length / 2)).PadRight(66) + "║") "Yellow"
    Say ("  ║" + $bottom.PadLeft(33 + [int]($bottom.Length / 2)).PadRight(66) + "║") "DarkYellow"
    Say "  ╚══════════════════════════════════════════════════════════════════╝" "Yellow"
    Say ""
}

$script:StepNo = 0
$script:StepOpen = $false

# A step's bar fills when the work behind it is really done.
function Close-Step {
    if (-not $script:StepOpen) { return }
    $script:StepOpen = $false
    Write-Host " [" -NoNewline -ForegroundColor DarkGray
    for ($i = 0; $i -lt 16; $i++) { Write-Host "█" -NoNewline -ForegroundColor Yellow; Pause-Art 14 }
    Write-Host "] " -NoNewline -ForegroundColor DarkGray
    Write-Host "OK" -ForegroundColor Green
}

function Step($text) {
    Close-Step
    $script:StepNo++
    Write-Host "  [$($script:StepNo)/3] " -NoNewline -ForegroundColor Yellow
    Write-Host $text.PadRight(32) -NoNewline -ForegroundColor White
    $script:StepOpen = $true
}

function Show-Finish($title, $color) {
    Close-Step
    Say ""
    Say "   *    .        +        .    *       .       +     .        *    ." "Yellow"
    Say "  ╔══════════════════════════════════════════════════════════════════╗" $color
    Say ("  ║" + $title.PadLeft(33 + [int]($title.Length / 2)).PadRight(66) + "║") $color
    Say "  ╚══════════════════════════════════════════════════════════════════╝" $color
    Say "   .    +        *        .    +       *       .     +        .    *" "Yellow"
    Say ""
}

function Done($code) { if (-not $NoPause) { Read-Host "Press Enter to close" | Out-Null }; exit $code }

function Find-Game {
    if ($GameDir -ne "") { return $GameDir }
    # run from inside the game folder?
    foreach ($d in @($Here, (Split-Path -Parent $Here))) {
        if (Test-Path (Join-Path $d "FindTheNeedle.exe")) { return $d }
    }
    $roots = @()
    foreach ($key in @("HKCU:\Software\Valve\Steam", "HKLM:\SOFTWARE\WOW6432Node\Valve\Steam")) {
        try {
            $p = Get-ItemProperty $key -ErrorAction Stop
            foreach ($v in @($p.SteamPath, $p.InstallPath)) { if ($v) { $roots += ($v -replace "/", "\") } }
        } catch {}
    }
    $roots += "${env:ProgramFiles(x86)}\Steam"
    $libs = @()
    foreach ($r in ($roots | Select-Object -Unique)) {
        $libs += $r
        $vdf = Join-Path $r "steamapps\libraryfolders.vdf"
        if (Test-Path $vdf) {
            foreach ($m in [regex]::Matches((Get-Content $vdf -Raw), '"path"\s+"([^"]+)"')) {
                $libs += ($m.Groups[1].Value -replace "\\\\", "\")
            }
        }
    }
    foreach ($lib in ($libs | Select-Object -Unique)) {
        $acf = Join-Path $lib "steamapps\appmanifest_$AppId.acf"
        if (Test-Path $acf) {
            $m = [regex]::Match((Get-Content $acf -Raw), '"installdir"\s+"([^"]+)"')
            if ($m.Success) {
                $d = Join-Path $lib ("steamapps\common\" + $m.Groups[1].Value)
                if (Test-Path (Join-Path $d "FindTheNeedle.exe")) { return $d }
            }
        }
    }
    return ""
}

# An old multiplayer mod: any folder in mods\ that carries an mp.gd, or whose
# name says multiplayer / coop / mp.
function Test-OldMpMod($dir) {
    if ($dir.Name -eq $ModName) { return $false }
    if ($dir.Name -match '(?i)multi|co-?op|^mp|netplay|online') { return $true }
    return [bool](Get-ChildItem $dir.FullName -Recurse -Filter "mp.gd" -ErrorAction SilentlyContinue | Select-Object -First 1)
}

# override.cfg as an ordered list of sections, each a list of lines.
function Read-Cfg($path) {
    $sections = New-Object System.Collections.ArrayList
    $cur = @{ name = ""; lines = (New-Object System.Collections.ArrayList) }
    [void]$sections.Add($cur)
    if (Test-Path $path) {
        foreach ($line in [IO.File]::ReadAllLines($path)) {
            $m = [regex]::Match($line, '^\s*\[([^\]]+)\]\s*$')
            if ($m.Success) {
                $cur = @{ name = $m.Groups[1].Value; lines = (New-Object System.Collections.ArrayList) }
                [void]$sections.Add($cur)
            } else {
                [void]$cur.lines.Add($line)
            }
        }
    }
    return ,$sections
}

function Get-Section($sections, $name) {
    foreach ($s in $sections) { if ($s.name -eq $name) { return $s } }
    $s = @{ name = $name; lines = (New-Object System.Collections.ArrayList) }
    [void]$sections.Add($s)
    return $s
}

function Write-Cfg($sections, $path) {
    $out = New-Object System.Collections.Generic.List[string]
    foreach ($s in $sections) {
        $all = @($s.lines | ForEach-Object { $_ })
        $n = $all.Count
        while ($n -gt 0 -and $all[$n - 1].Trim() -eq "") { $n-- }
        $first = 0
        while ($first -lt $n -and $all[$first].Trim() -eq "") { $first++ }
        $body = @(); if ($n -gt $first) { $body = @($all[$first..($n - 1)]) }
        if ($s.name -eq "" -and $body.Count -eq 0) { continue }
        if ($s.name -ne "" -and $body.Count -eq 0) { continue }
        if ($out.Count -gt 0) { $out.Add("") }
        if ($s.name -ne "") { $out.Add("[" + $s.name + "]"); $out.Add("") }
        foreach ($l in $body) { $out.Add($l) }
    }
    [IO.File]::WriteAllText($path, ($out -join "`r`n") + "`r`n", $Utf8)
}

# ---------------------------------------------------------------- main
Show-Banner
Show-Title "NEEDLE PARTY  v1.2.20  -  co-op for Find The Needle" "made by Luna7070  -  based on AleDev11's co-op mod (MIT)"

$game = Find-Game
if ($game -eq "" -or -not (Test-Path (Join-Path $game "FindTheNeedle.exe"))) {
    Say "Could not find Find The Needle. Put this folder next to FindTheNeedle.exe" "Red"
    Say "or run:  install.bat -GameDir ""C:\path\to\the\game""" "Red"
    Done 1
}
Say "  Game folder: $game" "DarkGray"
Say ""

if (-not $SkipRunningCheck -and (Get-Process -Name "FindTheNeedle" -ErrorAction SilentlyContinue)) {
    Say "The game is running. Close it first, then run the installer again." "Red"
    Done 1
}

$mods   = Join-Path $game "mods"
$cfg    = Join-Path $game "override.cfg"
$stamp  = Get-Date -Format "yyyy-MM-dd_HH-mm-ss"
$backup = Join-Path $game "mods_backup\$stamp"

if (-not $Uninstall -and -not (Test-Path (Join-Path $Src "mp.gd"))) {
    Say "Mod files not found at $Src - keep the installer folder next to the mods folder." "Red"
    Done 1
}

New-Item -ItemType Directory -Force $backup | Out-Null
if (Test-Path $cfg) { Copy-Item $cfg (Join-Path $backup "override.cfg") }
$moved = New-Object System.Collections.ArrayList   # [from, to] pairs, for the rollback

try {
    Step $(if ($Uninstall) { "Moving the mod to the backup" } else { "Clearing out old versions" })
    # 1. old multiplayer mods (and our own older copy, so an update starts
    #    clean) go to the backup, never straight to the bin
    $removed = @()
    if (Test-Path $mods) {
        foreach ($d in Get-ChildItem $mods -Directory) {
            $isOurs = $d.Name -eq $ModName
            if ($isOurs -or (Test-OldMpMod $d)) {
                $dest = Join-Path $backup ("mods\" + $d.Name)
                New-Item -ItemType Directory -Force (Split-Path -Parent $dest) | Out-Null
                Move-Item $d.FullName $dest
                [void]$moved.Add(@($d.FullName, $dest))
                if (-not $isOurs) { $removed += $d.Name; Say "  removed old multiplayer mod: mods\$($d.Name)  (kept in backup)" "DarkGray" }
            }
        }
    }
    # older demo versions wrote this next to the exe
    $appidTxt = Join-Path $game "steam_appid.txt"
    if (Test-Path $appidTxt) {
        Move-Item $appidTxt (Join-Path $backup "steam_appid.txt")
        [void]$moved.Add(@($appidTxt, (Join-Path $backup "steam_appid.txt")))
        Say "  removed old steam_appid.txt" "DarkGray"
    }

    Step "Setting up the game"
    # 2. override.cfg: drop every multiplayer autoload, add ours; keep the
    #    game's own settings (graphics etc.) exactly as they are
    $sections = Read-Cfg $cfg
    $auto = Get-Section $sections "autoload"
    $keep = New-Object System.Collections.ArrayList
    foreach ($l in $auto.lines) {
        $t = $l.Trim()
        if ($t -eq "") { continue }
        $drop = $false
        if ($t -match '^MPMod\s*=') { $drop = $true }
        elseif ($t -match '(?i)mods/[^"]*(multi|co-?op|/mp)') { $drop = $true }
        else { foreach ($r in $removed) { if ($t -match [regex]::Escape("mods/$r/")) { $drop = $true } } }
        if ($drop) { if ($t -notmatch 'needle_party') { Say "  removed autoload: $t" "DarkGray" } } else { [void]$keep.Add($l) }
    }
    if (-not $Uninstall) { [void]$keep.Add($Autoload) }
    $auto.lines = $keep

    # script call stacks, so a log says which script an error or a crash came from.
    # Measured three times each with and without: no lag to see. Uninstalling takes it out.
    $debug = Get-Section $sections "debug"
    $dk = New-Object System.Collections.ArrayList
    foreach ($l in $debug.lines) { if ($l.Trim() -notmatch '^settings/gdscript/always_track_call_stacks\s*=') { [void]$dk.Add($l) } }
    if (-not $Uninstall) { [void]$dk.Add("settings/gdscript/always_track_call_stacks=true") }
    $debug.lines = $dk

    $steam = Get-Section $sections "steam"
    $sk = New-Object System.Collections.ArrayList
    foreach ($l in $steam.lines) { if ($l.Trim() -notmatch '^multiplayer_peer/max_channels\s*=') { [void]$sk.Add($l) } }
    # GodotSteam defaults to 4 channels; the mod uses more (see mp_steam.gd)
    if (-not $Uninstall) { [void]$sk.Add("multiplayer_peer/max_channels=16") }
    $steam.lines = $sk
    Write-Cfg $sections $cfg

    Step $(if ($Uninstall) { "Finishing" } else { "Copying NEEDLE PARTY" })
    # 3. copy the mod
    if (-not $Uninstall) {
        New-Item -ItemType Directory -Force $mods | Out-Null
        Copy-Item $Src (Join-Path $mods $ModName) -Recurse -Force
    }
} catch {
    Say ""
    Say "Something went wrong: $($_.Exception.Message)" "Red"
    Say "Putting everything back the way it was..." "Yellow"
    if (-not $Uninstall) { Remove-Item (Join-Path $mods $ModName) -Recurse -Force -ErrorAction SilentlyContinue }
    for ($k = $moved.Count - 1; $k -ge 0; $k--) {
        try { Move-Item $moved[$k][1] $moved[$k][0] -Force } catch { Say "  could not restore $($moved[$k][0])" "Red" }
    }
    $bcfg = Join-Path $backup "override.cfg"
    if (Test-Path $bcfg) { Copy-Item $bcfg $cfg -Force }
    Say "Nothing was changed. Backup folder: $backup" "Yellow"
    Done 1
}

if ($Uninstall) {
    Show-Finish "UNINSTALLED  -  your saves are untouched" "Green"
    Say "  Backup: $backup" "DarkGray"
    Say ""
    Done 0
}
Show-Finish "INSTALLED  -  TIME TO FIND THE NEEDLE!" "Green"
Say "  >> Start the game FROM STEAM: the main menu shows NEEDLE PARTY." "White"
Say "  >> Everyone in the session needs this same version (1.2.20)." "White"
Say "  >> F9 in the game opens the panel." "White"
Say ""
Say "  Game updates can reset override.cfg - just run install.bat again." "DarkGray"
Say "  Backup of anything replaced: $backup" "DarkGray"
Say ""
Done 0