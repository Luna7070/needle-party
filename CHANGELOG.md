# Changelog

All versions need every player on the same version; older ones are refused when joining.

## 1.3.1 (17 November 2026)

- Fixed: a guest's exact belts switched off for the rest of the session when the host's game stood
  still for a few seconds (for example while it prepares graphics after building a machine), or when
  few belts were moving. They now come back on by themselves.
- Fixed: when the host changed a machine (a cabinet door, a radar's tier, a switch) right after a guest
  changed the same one, the guest's old setting came back and undid the host's change.
- New settings page: the gear at the top right of the panel (F9) has SMOOTH BELTS and the anonymous
  logs switch.

## 1.3.0 (16 November 2026)

The big belt update. Belts now look the same and run smoothly on every PC, and guests see the host's
belts exactly. Everything is done in the mod's own scripts: no extra library and no game file
replaced. Everyone in the session needs 1.3.0.

### Belts
- **SMOOTH BELTS** (new, on by default, one switch in F9): belts are drawn smoothly for the host, the
  guests and in single player. Items no longer stop for a moment and then jump forward when the belt
  in front of them moves. Only the drawing changes, not how the belts work.
- **Guests see the host's exact belts:** near a guest (about 45 m) every item sits where the host
  has it. No more jumping, blinking, doubled or missing items on a guest's belts. Picking items up
  and the machines work as before.
- **Safe by itself:** on a game build it does not know yet, SMOOTH BELTS is watched for the first 5
  minutes and turns itself off on any problem, without a restart. The F9 panel shows what it does
  right now (on, off after a game update, off after a problem).
- Fixed: items that fell off a belt end in front of a full machine were made twice on a guest and
  counted on the host too (extra eco bricks out of nowhere).
- Fixed: items a guest put on a belt could vanish (for example 6 hay wads put on, 4 arrived).
- Fixed: a T-splitter's way in, switched by hand, never reached the other player, and a T-joiner's
  way out did not change its belts. The first switch by hand is no longer undone.
- Fixed: splitter door filters set by a guest let items out of a door the new filter shuts.

### Machines on guests
- **Fixed: machines stood still on guests when the host was not looking at them.** Machines near a
  guest now always move.
- Smoother machines: depot drones fly without stop-and-go, robot arms further away keep moving, the
  piston rake no longer shoots past its throw position, the briquette press runs at the right speed,
  and the sell stand's scale and money sack follow the host.
- Fixed: machine shadows twitched on guests.
- Machine jam meters no longer flicker.

### Shared between players
- Sell stand on guests: payout text, "selling too fast", new best, register sound and combo count,
  as on the host.
- Needle cabinet: the doors work both ways, a guest's end-button presses count, and only the host
  forges the key (guests see it carried to the hatch).
- Guests see rake throw limits, radar tier overrides, drone fill lamps, jump pad counters and each
  drone's status line (working, waiting, blocked, what it carries).
- A guest's depot "empty this item", drone pick filter and arm filter work at once.
- Fixed: in a sandbox run, two players buying the same upgrade at once got money back that was never
  paid.
- Fixed: a needle could be missing on a guest.

### Less lag
- The host no longer stutters every half second with a guest in a big yard.
- Belt sync, machine checks and pose sending are much cheaper. Building or taking something down
  costs the other player 8-13 ms instead of 17-50 ms.
- Many moving items: every item gets its updates in turn, so none of them stand and then jump.

### Other fixes
- A quick off-then-on switch click by a guest is no longer lost.
- No more error spam when the other player takes down a building or item you are aiming at, when
  pressing F8 while connecting, or from the panel's stripes.
- Sturdier start: if one part of the world sync does not fit a game build, only that part turns off.
- The demo build loads every part of the mod.
- install.bat and uninstall.bat also work with Windows Smart App Control turned on. Nothing is
  installed outside the game's mods folder. install.bat also removes a file left by early test builds.

## 1.2.21

For the game update of 13 November 2026.

- Fixed: on guests, machines whose animation starts again every cycle (the hay compressor's press, the biogas digester's feed and others) ran backwards for a moment or stood still. They now move with the host.
- **Selling stand:** guests see the sale animation when hay is sold.
- **Supply shop:** moving the shop or taking it down shows for everyone, like the sell stand.
- Fixed: moving the sell stand or taking it down only showed for the other players after they loaded the yard again. It now moves for everyone right away.
- **Needle radars:** each radar's tier and its upgrades are synced, either player.
- **Depot "no drones" switch** (per item): set by either player, it applies for everyone.
- The new yard options (metal cleanup, scrap cap, scrap decay, straw tuft cap) follow the host for everyone in the session, like the other yard rules, so a guest's game no longer cleans up things the host keeps.
- Old saves that the game sends round the metal detector mission first: where the mission list continues afterwards follows the host.

## 1.2.20

(1.2.19 was never released: everything from it is in here too.)

- Fixed: items a guest threw or dropped could vanish after a few seconds. The host's game cleans up the floor when it is full and only spared items near the host; now items near every player are spared.
- Fixed: taking an item off a belt as a guest could make it vanish from your hands, or pop back onto the belt for a moment. The host now takes exactly that item.
- Throwing feels smooth for guests: the guest's own game flies the item until it lands, then hands it to the host.
- Items that land on a belt no longer blink out for a moment on the guest's screen, and an item a machine eats disappears right away.
- Fixed: guests could make extra hay at belt ends that feed machines (like the hay stairs), and the host's machines then used it: hay from nothing.
- Guests see the hay in the robot arms' claws, and machines move across the whole yard for guests, not only close by.
- Guests: the rake panel shows its numbers and alerts (JAMMED, RAKING NOTHING, BELT FULL), and Back/Forward drive the rake. Fabricator moulds and depot drone lamps update. Taking down a drone no longer gives its load back twice.
- Demo: items and contracts sync again (part of the mod did not load on the demo).
- The bug report window (F11) closes when you click back into the game, so your keys no longer type into it.
- Better logs for finding bugs: host and guest logs line up in time, every item's life is noted, and F11 sends the last 30 seconds.

## 1.2.19 (not released, part of 1.2.20)

- **Public servers (experimental):** in the panel (F9) → PUBLIC SERVERS, join a server from the list or host your own. Only tested with 2 players so far; the first time you host, a note explains what can happen.
- **Kick and ban:** the host can remove players in the panel (F9). Ban asks once more, sticks to the player's Steam account and is kept on the host's PC only. CLEAR BANS undoes them.
- **New bug report window (F11):** in the mod's own style. Pick what kind of problem it is (lag, out of sync, broken, other) and write one line.
- **Smooth machines for guests:** machines like the press, pelletizer, compressor and wrapper now play their animations on the guest's own PC at full frame rate, instead of jumping 10 times a second. Pumps, pulpers and other machines with shader motion now run in step with the host.
- Fixed: big machines (skyline crane, paper machine, smelter, carbon kiln, fibre spinner, assembler) only had their first 120 parts synced, so most of their moving parts stood still for guests. Now up to 1000.
- Joining over Steam works for more friend pairs: if the lobby can't be entered, the mod connects straight to the host.
- Host and guest must now have exactly the same build (not only the same version number): a guest whose host has another build gets a clear message instead of jammed belts. A guest only starts following the host's belt hand-overs once the host really sends them.
- **Smooth moving machines for guests:** drones, robot arms, cranes and other moving parts are shown 0.2 s behind the host and slide between the host's positions, like other players in online games, instead of stopping and jumping. Measured: robot arms now move in 92% of frames on a guest (host 90%, before 43%), drones 99% (host 100%, before 77%).
- **New belt sync for guests:** the host sends nearby belts four times a second (all belts every two seconds) with every item's own id, place, gap and speed, and the guest writes them straight into its belts and restarts their step clock, so items continue without a jump. Joints between belts hand items on like the game does; only belt ends into machines wait for the host. Approach adopted from xRangerDE's Multiplayer Enhanced (MIT), adapted to the full game.
- Faster belts on the host: a belt is only sent when something on it changed.

## 1.2.18

- Smoother hosting: syncing the machines cost every host 3-4 ms ten times a second, even in small worlds. Now it costs about half as much (the slowest part of it, six times less). Laptop hosts also lose a small stutter every 2 seconds.
- New: **F11** sends a bug report. Write one line about what went wrong, and a log goes out from every player in the session at that moment. It needs the anonymous logs on.
- Crash logs now include the game's own crash findings: how the run ended, how long it ran, and what Windows recorded. Before, they held only a few lines.
- Logs show the game version.
- Fixed: a player with a very short name could blank normal words in their own log.

## 1.2.17

- Works with the game's Steam beta (EA V15.2) as well as the normal game.
- Fixed a crash on guests: when the world changed, the mod still asked the player what they were aiming at.
- RESYNC (F8) on a guest works: the new world gets the host's items and tables.
- Machine clocks: setting a machine back to 100% now shows for every player. Before, a pulper could stay at 1% on one PC.
- Game beta: depot limits and refused items work for every player.
- UPDATE NOW button in the panel (F9): one click downloads and installs a new version.
- Anonymous logs: clearer cards, and all logs of one lobby have the same session number.

## 1.2.14

Anonymous logs
- To make the mod better for big lobbies and big worlds, it sends anonymous logs every 30 minutes during multiplayer. No names, no Steam IDs, no chat, no screenshots, no saves, no personal information. The first start says so and lets you turn it off; the panel (F9) has the same switch.

Items
- A guest selling a bucket or wheelbarrow at the shop: it could come back and be sold again and again, for money.
- The shop bringing something to your feet moves it for everyone, not only on your screen.
- Rides falling off the end of a belt came out twice, once for each player: bales and ingots out of nowhere.
- The Forcetron lets go of an item the host removes, before it asks where that item is.
- A guest's machines really stop now. They kept working on the guest and their products reached the host as extra items, which copied things like eco bricks without anyone touching them.
- Taking something off a belt as a guest no longer clones it.
- What a building holds comes out once when it is taken down, not once per player.
- Two players grabbing one item in the same moment: one gets it, the other lets go.
- An item can no longer vanish because two players disagreed about who owned it.
- Pouring into a bucket works for every player, whoever put the bucket down.

Power and panels
- No more false "too little power" on a guest. A real shortage shows the same for everyone.
- Machine clocks and machine paint are no longer wiped when another player builds something.
- Machine panels match: work timers, warnings, counts, silo rates, money per minute.
- Cables strung or cut by hand between standing poles show for everyone.
- Scanner Drawer: turning the tube works for everyone and no longer jumps back.
- Upgrades on scanners, robotic arms and hay drones show on the other players' side.
- T-splitter: a closed lane shows on the other players' side.
- Tube launcher dial, work lamp switch, hay drone and crane zones, excavator aim: all work for guests.
- A host change to one machine setting is not undone by a guest changing another.

Buildings
- Free buildings from missions are shared: one player placing one uses it up for everybody.
- The players' buildings are compared now and then, and a guest puts strays right by itself.
- A belt gate shows for the other player. Before, it never got there.
- Signs, markings, belt hangers, belt meters and other fittings: every one reaches the other player, not only the first of each kind.
- Items spilled by laying or taking down a belt as a guest stay on the belts instead of falling on the host's floor.

Deliveries and the market
- The delivery truck shows the load for guests, also on a new contract or after joining mid-load.
- Deliveries board: contracts that want several items show the same counts for everyone.
- A contract signed by a guest stays signed.
- A guest's sales lower the prices for everyone. Records set by a guest count for everyone.

The rest
- Much less work per frame on a guest, for belts and machine settings. On a low frame rate the belts no longer fall behind.
- Esc never pauses a session, for any player, also if somebody turns the game's pause option on while playing.
- Machines on a guest no longer copy their materials for nothing. In a long session the graphics card ran out of room for them, which made the screen flicker.
- "Always day": the host's time of day no longer overwrites it on a guest.
- A guest sees the smelter's arms work.
- Looking at something else while the world loads: the game does not hold the mouse while it is in the background, and a click brings it back.
- An old Steam invite now says the game is gone, instead of a number.
- A guest can fire the needle radar, and its marks show for everyone.
- Paint boards: a stroke is not lost when another player's drawing arrives at the same moment.
- A guest's digging is not lost when the host's pile update arrives first.
- An item that lands after its last move got lost now ends up in the right place.
- A guest that disconnects while loading goes back to the menu without touching its saves.
- Guests get the new world when the host loads another save from inside a world.
- The host can stop hosting and play on: the guests' items work normally again.
- With three or more players: a leaving player's straw goes away, and a late joiner sees the straw already lying around.
- Smaller fixes: player list on quick Alt presses, mouse after closing panels, Enter in text fields, expired invites, Steam "join game" after leaving.

Performance
- Machine values go in a little per frame on a guest instead of all at once: fewer slow frames.
- Belts: only the belts that changed are sent and rebuilt, not every belt four times a second. Much less stutter on a guest and far less traffic.

## 1.2.2

- Connection is always through Steam's relay: the Direct option is removed.
- The panel fits the screen and scrolls inside instead of being cut off.
- First start: the NEEDLE PARTY button now appears after the language picker.

## 1.2.1

- Update check: when a newer version is out, the panel shows a button that opens the
  download page. Nothing is downloaded automatically.

## 1.2.0 — first public release

- **Smooth near busy factories**: machine animation sync now works within a time budget on
  the host and the guest. Measured with a player standing among the machines: host from
  15 ms (spikes to 99 ms) to about 6 ms, guest spikes from 233 ms to under 20 ms; machine
  part lists are built in one pass instead of re-walking every part.
- **Complete world for joining players**: after building the world it sends, the host also
  asks the game's own save builder and adds anything missing — this found the sell stand
  position, the yard rules and the sandbox flag, which guests never got before.
- **Moving the sell stand** is synced (either player).
- Turning belts around is confirmed to sync both ways (the game reports it as a building
  change); the brick machine's throw direction has synced since 1.0.2.
- The self test now compares every building's complete data, the barn/yard settings and
  item counts between host and guest — 0 differences on a Hayverest yard.
- Mod folder is now `mods/needle_party`; the installer moves older multiplayer mod
  folders into a dated backup.
- Clean repository layout, release script, documentation.

## 1.1.7

- **Safe join spot**: a joining player gets free floor next to the host that is not a belt,
  splitter or joiner. Before, a guest could land on a belt (stuck, then carried away) or
  inside a machine.
- **Connection switch**: *Direct* by default (lower ping, falls back to Steam's relay);
  *Steam relay* hides IP addresses. The host chooses, guests follow.
- A guest's loose straw that a belt really took is handed to the host (first part of
  upstream #17).

## 1.1.6

- Joining players no longer land in the hay pile (the old new-game start point).

## 1.1.5 — performance pass

- Measured with two copies of the game and the game's own stutter logger: **0 stutters**
  on host and guest (before: a 35–80 ms freeze every 2 seconds).
- At most one heavy sync job per frame; machine refresh, field checks and the hay-pile scan
  are spread over time.
- Silo contents travel compressed; guests apply belt updates in a free frame and skip
  unchanged ones.
- Loose straw: fixed a loop that deleted and re-sent up to 400 straws.
- Standing players do not re-send their position (keep-alive every 0.5 s).
- Built-in stopwatch: any sync job over 4 ms is logged by name.

## 1.1.4

- Fixed an 80 ms freeze every 2 s: the machine scan rebuilt every machine's part list in one
  frame (from the original mod).

## 1.1.3

- Fixed a loop that flooded the connection when the host refused a guest's machine value.

## 1.1.2 — every building checked against the game's save data

- Fittings synced: fans, jump pads, lights, work lamps, signs, markings, valves, belt gates,
  outlets; paint on all non-machine buildings.
- Shared state: depot stock (as changes, cannot be taken twice), depot limits, story
  progress, records; the hay market follows the host; the host's yard options apply.
- Keys moved off the game's own: panel F9, chat Enter, join invite F10.

## 1.1.1

- Machine jams synced (with the game's jam glow); day and night follow the host; more panel
  values (needles inside machines, generator kW, tanks, stats).

## 1.1.0

- Snapshot interpolation for other players' movement.
- New look: warm charcoal and hay amber, hazard stripe, spaced small caps.

## 1.0.x

- Yard tables synced (machine paint, power tags, routes, clocks, plugs, blueprint groups).
- Player list with ping, in-game friends list and invites, emotes over the farmer,
  Esc does not pause the session, silo stop/start and contents, every machine panel setting.
- Steam channel overflow fixed, unreliable poses, tool/item duplication fixed (upstream #21),
  guest hay and paper reach the host, one-click installer with backup and rollback.

Based on AleDev11's FindTheNeedle-Coop-Mod 0.19.5 (MIT).
