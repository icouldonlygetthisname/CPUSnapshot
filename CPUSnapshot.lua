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

-- /cpuwatch [seconds]: sample every addon's recent average CPU for a while
-- (e.g. while hovering bag items) and rank them by their share of the
-- application's frame time. A share is unit-free, so it doesn't depend on
-- whether this client reports metrics in ms or in ticks.
local watching = false
SLASH_CPUSNAPWATCH1 = "/cpuwatch"
SlashCmdList["CPUSNAPWATCH"] = function(msg)
	if watching then
		print("|cffff5555CPUSnapshot:|r already watching.")
		return
	end
	if not C_AddOnProfiler.IsEnabled() then
		print("|cffff5555CPUSnapshot:|r C_AddOnProfiler.IsEnabled() is false -- no profiling data available.")
		return
	end
	local seconds = tonumber(msg) or 15
	local interval = 0.25
	local samples = math.max(1, math.floor(seconds / interval))

	local names = {}
	for i = 1, C_AddOns.GetNumAddOns() do
		local name = GetAddOnName(i)
		if name and C_AddOns.IsAddOnLoaded(i) and name ~= "CPUSnapshot" then
			names[#names + 1] = name
		end
	end

	local sum, peak, appSum, taken = {}, {}, 0, 0
	-- Real frame rate over the window, independent of how the profiler attributes blame.
	local fpsSum, fpsMin, fpsSamples = 0, math.huge, 0
	-- Per-frame times: GetFramerate() is smoothed and hides short hitches.
	local frames, slowFrames, worstFrame = 0, 0, 0
	local frameWatcher = CreateFrame("Frame")
	frameWatcher:SetScript("OnUpdate", function(_, elapsed)
		frames = frames + 1
		if elapsed > 0.025 then slowFrames = slowFrames + 1 end
		if elapsed > worstFrame then worstFrame = elapsed end
	end)
	watching = true
	print(string.format("|cff55ff55CPUSnapshot:|r watching %d addons for %ds -- do the laggy thing now.", #names, seconds))
	C_Timer.NewTicker(interval, function()
		local fps = GetFramerate()
		fpsSum, fpsSamples = fpsSum + fps, fpsSamples + 1
		if fps < fpsMin then fpsMin = fps end

		local app = C_AddOnProfiler.GetApplicationMetric(METRIC_RECENT)
		if app and app > 0 then
			appSum = appSum + app
			taken = taken + 1
			for _, name in ipairs(names) do
				local ok, v = pcall(C_AddOnProfiler.GetAddOnMetric, name, METRIC_RECENT)
				if ok and type(v) == "number" then
					local share = v / app
					sum[name] = (sum[name] or 0) + share
					if share > (peak[name] or 0) then peak[name] = share end
				end
			end
		end
		samples = samples - 1
		if samples > 0 then return end

		watching = false
		local overall = C_AddOnProfiler.GetOverallMetric(METRIC_RECENT)
		local rows = {}
		for name, s in pairs(sum) do
			local avg = s / math.max(1, taken)
			if avg >= 0.001 or (peak[name] or 0) >= 0.005 then
				rows[#rows + 1] = { name = name, avg = avg, peak = peak[name] or 0 }
			end
		end
		table.sort(rows, function(x, y) return x.avg > y.avg end)
		local appNow = C_AddOnProfiler.GetApplicationMetric(METRIC_RECENT)
		print(string.format("|cff55ff55CPUSnapshot watch:|r %d samples. All addons now = %.1f%% of frame time. Top %d by average share:",
			taken, (appNow > 0 and overall / appNow or 0) * 100, math.min(15, #rows)))
		frameWatcher:SetScript("OnUpdate", nil)
		print(string.format("  |cffffd200FPS:|r avg %.0f, lowest %.0f", fpsSum / math.max(1, fpsSamples), fpsMin))
		print(string.format("  |cffffd200Hitches:|r %d of %d frames over 25ms, worst frame %.0fms",
			slowFrames, frames, worstFrame * 1000))
		for i = 1, math.min(15, #rows) do
			local r = rows[i]
			print(string.format("  %2d. %-28s avg=%5.1f%%  peak=%5.1f%%", i, r.name, r.avg * 100, r.peak * 100))
		end
	end, samples)
end

-- /cpuace [seconds]: time every AceEvent-3.0 event and message handler, per addon.
-- Shared libraries run from the copy that loaded first, and C_AddOnProfiler charges
-- that addon for every other addon's handlers dispatched through it. This wraps
-- each registered handler with a timer for the sample period, then restores it.
-- Handlers registered during the sample aren't timed.
local function AceOwnerName(owner)
	if type(owner) == "string" then return owner end
	if type(owner) == "table" then
		local name = rawget(owner, "name") or rawget(owner, "moduleName")
		if type(name) == "string" then return name end
	end
	return tostring(owner)
end

local aceWatching = false
SLASH_CPUSNAPACE1 = "/cpuace"
SlashCmdList["CPUSNAPACE"] = function(msg)
	if aceWatching then
		print("|cffff5555CPUSnapshot:|r already timing AceEvent handlers.")
		return
	end
	local AceEvent = LibStub and LibStub("AceEvent-3.0", true)
	if not AceEvent then
		print("|cffff5555CPUSnapshot:|r no AceEvent-3.0 loaded.")
		return
	end
	local seconds = tonumber(msg) or 15

	local byOwner, byOwnerEvent, calls = {}, {}, {}
	local wrapped = {} -- { handlers, owner, original, wrapper }
	for kind, registry in pairs({ event = AceEvent.events, message = AceEvent.messages }) do
		local events = registry and registry.events
		if events then
			for eventName, handlers in pairs(events) do
				for owner, original in pairs(handlers) do
					if type(original) == "function" then
						local who = AceOwnerName(owner)
						local key = who .. "  " .. eventName .. (kind == "message" and " (msg)" or "")
						local function wrapper(...)
							local start = debugprofilestop()
							original(...)
							local ms = debugprofilestop() - start
							byOwner[who] = (byOwner[who] or 0) + ms
							byOwnerEvent[key] = (byOwnerEvent[key] or 0) + ms
							calls[key] = (calls[key] or 0) + 1
						end
						handlers[owner] = wrapper
						wrapped[#wrapped + 1] = { handlers, owner, original, wrapper }
					end
				end
			end
		end
	end

	local frames = 0
	local counter = CreateFrame("Frame")
	counter:SetScript("OnUpdate", function() frames = frames + 1 end)
	aceWatching = true
	print(string.format("|cff55ff55CPUSnapshot:|r timing %d AceEvent handlers for %ds.", #wrapped, seconds))

	C_Timer.After(seconds, function()
		counter:SetScript("OnUpdate", nil)
		-- Restore, unless the owner re-registered in the meantime.
		for _, w in ipairs(wrapped) do
			local handlers, owner, original, wrapper = w[1], w[2], w[3], w[4]
			if handlers[owner] == wrapper then handlers[owner] = original end
		end
		aceWatching = false

		local owners, total = {}, 0
		for who, ms in pairs(byOwner) do
			owners[#owners + 1] = { who = who, ms = ms }
			total = total + ms
		end
		table.sort(owners, function(x, y) return x.ms > y.ms end)
		local keys = {}
		for key, ms in pairs(byOwnerEvent) do keys[#keys + 1] = { key = key, ms = ms } end
		table.sort(keys, function(x, y) return x.ms > y.ms end)

		print(string.format("|cff55ff55CPUSnapshot ace:|r %.0fms in AceEvent handlers over %d frames (%.2fms per frame). By addon:",
			total, frames, frames > 0 and total / frames or 0))
		for i = 1, math.min(8, #owners) do
			local o = owners[i]
			print(string.format("  %2d. %-28s %7.0fms  %.2fms/frame", i, o.who, o.ms, frames > 0 and o.ms / frames or 0))
		end
		print("  Top handlers:")
		for i = 1, math.min(8, #keys) do
			local k = keys[i]
			print(string.format("  %2d. %-40s %6.0fms  %d calls", i, k.key, k.ms, calls[k.key] or 0))
		end
	end)
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

-- ---------------------------------------------------------------------------
-- Hitch recorder: always on. Every frame slower than HITCH_MS is logged to
-- CPUSnapshotDB.hitches (SavedVariables, written on /reload or logout) with
-- the addons that were busiest in that frame (LastTime metric) and what the
-- player was doing (tooltip item, bags open, zone, combat, nameplates).
-- /cpurec        -- print the last 10 hitches
-- /cpurec clear  -- empty the log
-- /cpurec off|on -- pause / resume recording
-- ---------------------------------------------------------------------------
local HITCH_MS = 50
local MAX_HITCHES = 500
local METRIC_LAST = Enum.AddOnProfilerMetric.LastTime

local loadTime = GetTime()
local recording = true

local function Plain(v)
	if issecretvalue and issecretvalue(v) then return nil end
	return v
end

local function TooltipContext()
	if not GameTooltip:IsShown() then return nil end
	local ctx = {}
	local ok, owner = pcall(GameTooltip.GetOwner, GameTooltip)
	if ok and owner and owner.GetDebugName then
		local okName, name = pcall(owner.GetDebugName, owner)
		ctx.owner = okName and Plain(name) or nil
	end
	local okItem, _, link = pcall(GameTooltip.GetItem, GameTooltip)
	if okItem then ctx.item = Plain(link) end
	return ctx
end

-- Baganator names its bag frames after the active skin ("blizzard", "dark", ...).
local BAG_FRAMES = { "ContainerFrameCombinedBags", "ContainerFrame1" }
for _, skin in ipairs({ "blizzard", "dark", "elvui", "gw2", "ndui", "" }) do
	BAG_FRAMES[#BAG_FRAMES + 1] = "Baganator_SingleViewBackpackViewFrame" .. skin
	BAG_FRAMES[#BAG_FRAMES + 1] = "Baganator_CategoryViewBackpackViewFrame" .. skin
end

local function BagsOpen()
	for _, name in ipairs(BAG_FRAMES) do
		local f = _G[name]
		if f and f.IsShown and f:IsShown() then return name end
	end
	return nil
end

local function RecordHitch(elapsed)
	CPUSnapshotDB = CPUSnapshotDB or {}
	CPUSnapshotDB.hitches = CPUSnapshotDB.hitches or {}
	local log = CPUSnapshotDB.hitches

	local entry = {
		when = date("%Y-%m-%d %H:%M:%S"),
		ms = math.floor(elapsed * 1000 + 0.5),
		sinceLoad = math.floor(GetTime() - loadTime),
		app = C_AddOnProfiler.GetApplicationMetric(METRIC_LAST),
		addons = C_AddOnProfiler.GetOverallMetric(METRIC_LAST),
		zone = GetRealZoneText(),
		subzone = GetSubZoneText(),
		combat = InCombatLockdown() or nil,
		nameplates = C_NamePlate and C_NamePlate.GetNamePlates and #C_NamePlate.GetNamePlates() or nil,
		bags = BagsOpen(),
		tooltip = TooltipContext(),
		top = {},
	}
	local ok, top = pcall(C_AddOnProfiler.GetTopKAddOnsForMetric, METRIC_LAST, 5)
	if ok and type(top) == "table" then
		for i, r in ipairs(top) do
			entry.top[i] = { name = r.addOnName, value = r.metricValue }
		end
	end

	log[#log + 1] = entry
	while #log > MAX_HITCHES do table.remove(log, 1) end
end

local recorder = CreateFrame("Frame")
recorder:SetScript("OnUpdate", function(_, elapsed)
	if recording and elapsed * 1000 >= HITCH_MS and C_AddOnProfiler.IsEnabled() then
		RecordHitch(elapsed)
	end
end)

SLASH_CPUSNAPREC1 = "/cpurec"
SlashCmdList["CPUSNAPREC"] = function(msg)
	msg = (msg or ""):lower()
	if msg == "clear" then
		if CPUSnapshotDB then CPUSnapshotDB.hitches = {} end
		print("|cff55ff55CPUSnapshot:|r hitch log cleared.")
		return
	elseif msg == "off" or msg == "on" then
		recording = msg == "on"
		print("|cff55ff55CPUSnapshot:|r hitch recording " .. msg .. ".")
		return
	end
	local log = CPUSnapshotDB and CPUSnapshotDB.hitches or {}
	print(string.format("|cff55ff55CPUSnapshot:|r %d hitches (>%dms) logged%s. Last 10:", #log, HITCH_MS, recording and "" or " (paused)"))
	for i = math.max(1, #log - 9), #log do
		local e = log[i]
		local first = e.top[1]
		print(string.format("  %s  %dms  top=%s  bags=%s  tip=%s", e.when:sub(12), e.ms,
			first and first.name or "-", e.bags and "y" or "n", e.tooltip and (e.tooltip.item or e.tooltip.owner or "?") or "-"))
	end
end
