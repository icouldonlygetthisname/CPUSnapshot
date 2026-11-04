-- CPUSnapshot: /cpustart .. do stuff in-game .. /cpustop
-- Prints which addons burned the most CPU time in between, and which ones
-- had individual calls blow past 100ms/500ms (i.e. caused a visible stutter),
-- using the real C_AddOnProfiler API (the old GetAddOnCPUUsage/
-- UpdateAddOnCPUUsage globals are vestigial in this patch and always read 0).

local TICKS_PER_MS = C_AddOnProfiler.GetTicksPerSecond() / 1000

local METRIC_RECENT = Enum.AddOnProfilerMetric.RecentAverageTime
local METRIC_OVER_100MS = Enum.AddOnProfilerMetric.CountTimeOver100Ms
local METRIC_OVER_500MS = Enum.AddOnProfilerMetric.CountTimeOver500Ms

local function GetAddOnName(i)
	local ok, result = pcall(C_AddOns.GetAddOnInfo, i)
	if not ok then return nil end
	if type(result) == "table" then
		return result.name or result.Name
	end
	return result
end

local snapshot = nil

local function TakeSnapshot()
	if not C_AddOnProfiler.IsEnabled() then
		print("|cffff5555CPUSnapshot:|r C_AddOnProfiler.IsEnabled() is false -- no profiling data available.")
		return nil
	end

	local data = {}
	local n = C_AddOns.GetNumAddOns()
	for i = 1, n do
		local name = GetAddOnName(i)
		if name and C_AddOns.IsAddOnLoaded(i) then
			local okRecent, recent = pcall(C_AddOnProfiler.GetAddOnMetric, name, METRIC_RECENT)
			local ok100, over100 = pcall(C_AddOnProfiler.GetAddOnMetric, name, METRIC_OVER_100MS)
			local ok500, over500 = pcall(C_AddOnProfiler.GetAddOnMetric, name, METRIC_OVER_500MS)
			data[name] = {
				recentMs = (okRecent and type(recent) == "number") and (recent / TICKS_PER_MS) or 0,
				over100 = (ok100 and type(over100) == "number") and over100 or 0,
				over500 = (ok500 and type(over500) == "number") and over500 or 0,
			}
		end
	end
	return data
end

SLASH_CPUSNAPNOW1 = "/cpunow"
SlashCmdList["CPUSNAPNOW"] = function(msg)
	-- these are all "Recent"-windowed metrics, not lifetime cumulative counters,
	-- so read them directly right now rather than relying on a before/after delta.
	local data = TakeSnapshot()
	if not data then return end

	local topN = tonumber(msg) or 15
	local rows = {}
	for name, v in pairs(data) do
		if v.over100 > 0 or v.over500 > 0 or v.recentMs > 0.5 then
			rows[#rows + 1] = { name = name, recentMs = v.recentMs, over100 = v.over100, over500 = v.over500 }
		end
	end

	table.sort(rows, function(x, y)
		if x.over500 ~= y.over500 then return x.over500 > y.over500 end
		if x.over100 ~= y.over100 then return x.over100 > y.over100 end
		return x.recentMs > y.recentMs
	end)

	print(string.format("|cff55ff55CPUSnapshot now:|r %d addon(s) active, top %d:", #rows, math.min(topN, #rows)))
	for i = 1, math.min(topN, #rows) do
		local r = rows[i]
		print(string.format("  %2d. %-28s recent=%.2fms  100ms+ hits=%d  500ms+ hits=%d", i, r.name, r.recentMs, r.over100, r.over500))
	end
end

SLASH_CPUSNAPSTART1 = "/cpustart"
SlashCmdList["CPUSNAPSTART"] = function()
	snapshot = TakeSnapshot()
	if snapshot then
		print("|cff55ff55CPUSnapshot:|r baseline captured. Go do the thing, then run /cpustop.")
	end
end

SLASH_CPUSNAPSTOP1 = "/cpustop"
SlashCmdList["CPUSNAPSTOP"] = function(msg)
	if not snapshot then
		print("|cffff5555CPUSnapshot:|r run /cpustart first.")
		return
	end

	local after = TakeSnapshot()
	if not after then return end

	local topN = tonumber(msg) or 15

	-- rank by delta in 100ms+ violations first (actual visible stutters),
	-- then by recent average CPU as a tiebreaker/secondary signal
	local rows = {}
	for name, a in pairs(after) do
		local b = snapshot[name] or { recentMs = 0, over100 = 0, over500 = 0 }
		local d100 = a.over100 - b.over100
		local d500 = a.over500 - b.over500
		if d100 > 0 or d500 > 0 or a.recentMs > 1 then
			rows[#rows + 1] = { name = name, recentMs = a.recentMs, d100 = d100, d500 = d500 }
		end
	end

	table.sort(rows, function(x, y)
		if x.d500 ~= y.d500 then return x.d500 > y.d500 end
		if x.d100 ~= y.d100 then return x.d100 > y.d100 end
		return x.recentMs > y.recentMs
	end)

	print(string.format("|cff55ff55CPUSnapshot:|r %d addon(s) with activity since /cpustart, top %d (sorted by 500ms+/100ms+ stutter count):", #rows, math.min(topN, #rows)))
	for i = 1, math.min(topN, #rows) do
		local r = rows[i]
		print(string.format("  %2d. %-28s recent=%.2fms  +100ms hits=%d  +500ms hits=%d", i, r.name, r.recentMs, r.d100, r.d500))
	end

	snapshot = nil
end
