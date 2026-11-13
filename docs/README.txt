NEEDLE PARTY  -  online co-op for Find The Needle (full game)
made by Luna7070  -  https://github.com/Luna7070/needle-party
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

PROBLEMS?
---------
Send these two files (from the PC that had the problem):
  %APPDATA%\Godot\app_userdata\FindTheNeedle\mp_trace.log
  %APPDATA%\Godot\app_userdata\FindTheNeedle\logs\godot.log

CREDITS
-------
NEEDLE PARTY ............ Luna7070 (vibecoded with an AI assistant)
Original co-op mod ...... AleDev11, anxo0 and contributors (MIT)
Performance ideas ....... xRangerDE, Multiplayer Enhanced (MIT)
Farmer model ............ Quaternius (CC0)
GodotSteam .............. godotsteam.com (MIT)
Find The Needle is made by FindTheNeedleDev. Not affiliated with the developer.
