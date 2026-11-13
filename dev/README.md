# Dev tools (not shipped)

These scripts are never in the release zip. To use one, copy it into the installed mod folder
(`<game>\mods\needle_party\`) and start the game with the environment variable shown. They run,
write their result to `%APPDATA%\Godot\app_userdata\FindTheNeedle\` and quit the game.
Remove the file again afterwards.

| File | Copy as | Variable | What it does |
|---|---|---|---|
| `mp_selftest.gd` | `mp_selftest.gd` | `MP_SELFTEST=host`, then a second copy with `MP_SELFTEST=guest` | Two copies of the game: host loads save slot 1 (saving off), guest joins over `127.0.0.1:7790`. Both dump every synced value, every building's data per type (`mp_selftest_<role>.txt`, rows in `mp_selftest_<role>_rows.txt`), the barn/yard settings and item counts; then both change things (poles, silo, splitter, belt reversal, compressor), dump again (`..._after.txt`), and the guest checks it can walk (`mp_selftest_guest_move.txt`). Compare host and guest files: only values that run on their own may differ. Traces go to `mp_trace_<role>.log`. |
| `mp_duotest.gd` | `mp_selftest.gd` | `MP_SELFTEST=host` / `guest`, plus `MP_SYNC=<folder>` | Two isolated copies, each with its own `APPDATA` and a copy of save slot 1: a real belt pick-up and pour, clocks, power, truck, cables, market, radar and the rest, and every value of every machine (`dump_<role>_<tag>.txt`). Results in `<folder>/out_<role>.txt`. |
| `mp_perftest.gd` | `mp_selftest.gd` | `MP_SELFTEST=host` / `guest`, plus `MP_SYNC=<folder>` | Same setup. Both stand among the machines for 40 s and write their frame times. Run it on the old and the new version to compare. |
| `mp_probe.gd` | `mp_probe.gd` | `MP_PROBE=1` | Dumps the game's script API (classes, methods, signals, vars) to `mp_probe_dump.txt`. Run after a game update to see what changed. |
| `mp_probe_audit.gd` | `mp_probe.gd` | `MP_PROBE=1` | Loads save slot 1 (saving off) and lists the save data keys of every building class. |
| `mp_probe_keys.gd` | `mp_probe.gd` | `MP_PROBE=1` | Lists the game's key bindings (to keep the mod's keys free). |
| `mp_probe_shot.gd` | `mp_probe.gd` | `MP_PROBE=1` | Screenshots of the panel and the player list for the docs. |

When the guest is started as a second copy, the game may show a crash report for it on the
next start — that is the two copies sharing one user folder, not a crash.
