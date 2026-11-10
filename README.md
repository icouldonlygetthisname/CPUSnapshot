# CPU Snapshot

A tiny World of Warcraft addon that shows which addons are burning CPU and which ones cause visible stutters. It runs on retail (Midnight 12.x) and WoW Forever (Interface 16001).

It uses `C_AddOnProfiler`. The old `GetAddOnCPUUsage`/`UpdateAddOnCPUUsage` globals still exist but always return 0 in this patch.

## Commands

| Command | What it does |
|---|---|
| `/cpustart` | Take a baseline snapshot. |
| `/cpustop [N]` | Compare against the baseline and list the top N addons (default 15). Sorted by new 500ms+ hits, then 100ms+ hits, then recent average CPU time. |
| `/cpunow [N]` | List the top N addons by current metrics, with no baseline needed. |
| `/cpuwatch [seconds]` | Sample for a while (default 15s) and rank addons by their share of frame time. Also prints the real FPS and the number of frames over 25ms. |
| `/cpuace [seconds]` | Time every AceEvent-3.0 event and message handler for a while (default 15s), per addon. Prints ms in total and per frame, and the 8 most expensive handlers. |
| `/cpurec` | Print the last 10 hitches from the hitch recorder. `/cpurec clear` empties the log; `/cpurec off` / `on` pauses and resumes it. |

Typical use: `/cpustart`, do the thing that stutters (open a window, enter combat, zone in), then `/cpustop`. Or run `/cpuwatch` and do the laggy thing until it prints.

## /cpuwatch

- Each addon is shown as `avg` and `peak` share of the application's frame time, not in ms. A share doesn't depend on the profiler's units, but at high FPS a big share can still be very little time: 50% of a 4.7ms frame is about 2ms.
- `FPS: avg, lowest` comes from `GetFramerate()`, which is smoothed.
- `Hitches: N of M frames over 25ms, worst frame Xms` comes from per-frame `OnUpdate` times. This is the best measure of the stutter you actually feel.
- The profiler charges time to the addon that *started* a code path. Shared libraries and hooks can make the blame land on the wrong addon, so confirm a suspect by turning it off and comparing the Hitches line.

## /cpuace

Every Ace3 addon shares the one copy of AceEvent-3.0 that loaded first, and the profiler charges that addon for every other addon's event handlers. A big share on an addon that ships Ace3 (e.g. GatherMate2) may belong to another addon. If disabling it moves the share to the next Ace3 addon in load order, run `/cpuace`: it wraps each registered handler with a timer, so the time lands on the addon whose handler it is. Handlers are restored afterwards; ones registered during the sample aren't timed. Example: GatherMate2 showed ~17% in `/cpuwatch`, and `/cpuace` put it on Routes (1.06ms per frame from a minimap zoom loop on WoW Forever).

## Hitch recorder

Always on. Every frame of 50ms or more is logged to the `CPUSnapshotDB.hitches` SavedVariable, which keeps the last 500. Each entry records the time, frame length, seconds since load, zone and subzone, combat, nameplate count, whether bags were open, the tooltip owner and item, and the top 5 addons by the profiler's `LastTime` metric for that frame. The log is written on `/reload` or logout. Use it for stutters that come and go.

## Columns (`/cpustop`, `/cpunow`)

- `recent`: the profiler's recent average time per frame, in ms.
- `100ms+ hits` / `500ms+ hits`: how many times a single call took longer than 100ms or 500ms. For `/cpustop` these are the increase since `/cpustart`.

If `C_AddOnProfiler.IsEnabled()` is false the addon says so and prints nothing else.

## Install

Copy the folder (without `.git`) to `World of Warcraft\_retail_\Interface\AddOns\CPUSnapshot` (or `_forever_` for WoW Forever).

## License

GPL-3.0. See [LICENSE](LICENSE).
