NEEDLE PARTY  -  online co-op for Find The Needle (full game)
made by Luna and Lolfa  -  https://github.com/Luna7070/needle-party
==========================================================================

Unofficial, free mod. Everyone in the session needs the full game and this
same NEEDLE PARTY version.

INSTALL
-------
1. Close the game.
2. Double-click install.bat
   - finds the game through Steam
   - moves old multiplayer mods into  <game>\mods_backup\<date>\  (never deleted)
   - copies NEEDLE PARTY to  <game>\mods\needle_party\
   - adds its line to override.cfg (your graphics settings stay as they are)
   - puts everything back if anything fails
3. Start the game FROM STEAM. The main menu shows NEEDLE PARTY.

Game updates can reset override.cfg: just run install.bat again.
Game somewhere else?   install.bat -GameDir "D:\Games\Find The Needle"
Remove:                uninstall.bat   (your saves are never touched)

ANONYMOUS LOGS
--------------
To make the mod better, it sends anonymous logs every 30 minutes during
multiplayer: how the game runs, errors, number of players, game data and PC
type (CPU, graphics card, memory). No names, no Steam IDs, no chat, no
screenshots, no saves, no personal information.
The first start tells you this and lets you turn it off; the panel (F9) has the
same switch. Logs go to the author's Discord channel. Like with any upload,
Discord sees your IP address; the author does not. The last log sent stays on
your PC:  %APPDATA%\Godot\app_userdata\FindTheNeedle\reports\last_log.zip

PLAYING
-------
Host: F9 (or NEEDLE PARTY in the menu) > CREATE GAME, load a save, INVITE FRIENDS.
Friends: accept the invite (F10 or JOIN in the panel), or join from Steam.

  F9          panel: create game, invite friends, connection, disconnect
  hold Alt    player list with ping
  Enter       chat
  F10         join a friend's invite
  F8          resync the world
  F6          the game's test menu (the run leaves the leaderboards)

Only the host saves. Machines run on the host (so hay is never counted twice);
everyone sees them move, smoke and light up.

SMOOTH BELTS
------------
Conveyor belts move smoother: a row no longer stops for a moment and then
jumps on when the belt in front of it moves. It is all in the mod's scripts:
install.bat puts no program file anywhere ("NEEDLE PARTY installed - smooth
belts on"). The panel (F9) has the switch "SMOOTH BELTS: ON" and under it what
it does now: "Now: active", "active (new game version, being checked)",
"off (game update - normal belts)", "off (problem found - normal belts)".
Off means the game's own belt drawing, exactly as without the mod.
Guests get the host's exact belts: on a guest, the belts near you (about
45 m) show the items exactly where the host has them. The guest draws them
itself with the game's own models, from the host's belt data; its own belts
keep running underneath for picking up and machines. On any fault it goes
back to the normal smooth belts by itself. Script only, no DLL.
An older test version put a "belt core" file into the game folder: install.bat
takes it out and puts the game's own file back, checked byte for byte. If the
game ever says it "couldn't load libbeltcore": run uninstall.bat, or in Steam
"Verify integrity of game files".
No installer at all: copy the mods\needle_party folder into the game folder and
add the line  MPMod="*mods/needle_party/mp.gd"  under [autoload] in override.cfg.

PROBLEMS?
---------
Send these two files (from the PC that had the problem):
  %APPDATA%\Godot\app_userdata\FindTheNeedle\mp_trace.log
  %APPDATA%\Godot\app_userdata\FindTheNeedle\logs\godot.log

CREDITS
-------
NEEDLE PARTY ............ Luna and Lolfa (vibecoded with an AI assistant)
Original co-op mod ...... AleDev11, anxo0 and contributors (MIT)
Performance ideas ....... xRangerDE, Multiplayer Enhanced (MIT)
Farmer model ............ Quaternius (CC0)
GodotSteam .............. godotsteam.com (MIT)
Find The Needle is made by FindTheNeedleDev. Not affiliated with the developer.
