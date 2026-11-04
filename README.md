# CPU Snapshot

A tiny World of Warcraft (retail, Midnight 12.x) addon that shows which addons are burning CPU and which ones cause visible stutters.

It uses `C_AddOnProfiler`. The old `GetAddOnCPUUsage`/`UpdateAddOnCPUUsage` globals still exist but always return 0 in this patch.

## Commands

| Command | What it does |
|---|---|
| `/cpustart` | Take a baseline snapshot. |
| `/cpustop [N]` | Compare against the baseline and list the top N addons (default 15). Sorted by new 500ms+ hits, then 100ms+ hits, then recent average CPU time. |
| `/cpunow [N]` | List the top N addons by current metrics, with no baseline needed. |

Typical use: `/cpustart`, do the thing that stutters (open a window, enter combat, zone in), then `/cpustop`.

## Columns

- `recent`: the profiler's recent average time per frame, in ms.
- `100ms+ hits` / `500ms+ hits`: how many times a single call took longer than 100ms or 500ms. For `/cpustop` these are the increase since `/cpustart`.

If `C_AddOnProfiler.IsEnabled()` is false the addon says so and prints nothing else.

## Install

Copy the folder (without `.git`) to `World of Warcraft\_retail_\Interface\AddOns\CPUSnapshot`.

## License

GPL-3.0. See [LICENSE](LICENSE).
