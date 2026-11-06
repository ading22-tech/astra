local Players = game:GetService("Players")
local RS = game:GetService("ReplicatedStorage")
local TweenService = game:GetService("TweenService")
local HttpService = game:GetService("HttpService")
local TeleportService = game:GetService("TeleportService")
local RunService = game:GetService("RunService")

if not game:IsLoaded() then game.Loaded:Wait() end 
local player = Players.LocalPlayer

local SCRIPT_FILE = "fruitfarm.lua" 
local DIR = "FruitFarmConfig"
local SETTINGS_FILE = DIR .. "/settings.json"
local VISITED_FILE = DIR .. "/visited.json"
local SERVERS_FILE = DIR .. "/servers.json"
local STACKS_FILE = DIR .. "/stacks.json"

local CommF = RS:WaitForChild("Remotes"):WaitForChild("CommF_")
local httpRequest = (syn and syn.request) or http_request or request

local WindUI = loadstring(game:HttpGet(
	"https://github.com/Footagesus/WindUI/releases/latest/download/main.lua"
))()

local ICONS = { info = "info", ok = "check", warn = "triangle-alert", error = "circle-x" }
local MAX_CONTENT = 400
local NotifyState = { on = true } 

local function notify(kind, title, content, duration)
	if not NotifyState.on and kind ~= "error" then return end
	content = tostring(content or "")
	if #content > MAX_CONTENT then content = string.sub(content, 1, MAX_CONTENT - 3) .. "..." end
	local data = { Title = title, Content = content, Duration = duration or 5, Icon = ICONS[kind] or ICONS.info }
	if not pcall(WindUI.Notify, WindUI, data) then
		data.Icon = nil 
		pcall(WindUI.Notify, WindUI, data)
	end
end

local function shortList(list, max, sep)
	max, sep = max or 8, sep or ", "
	if #list <= max then return table.concat(list, sep) end
	return table.concat(list, sep, 1, max) .. sep .. "+" .. (#list - max) .. " more"
end

local function fmtAge(sec)
	sec = math.max(0, math.floor(sec))
	local h, m, s = math.floor(sec / 3600), math.floor((sec % 3600) / 60), sec % 60
	if h > 0 then return string.format("%dh %02dm %02ds", h, m, s) end
	return string.format("%dm %02ds", m, s)
end

local function readJson(path)
	local ok, data = pcall(function() return HttpService:JSONDecode(readfile(path)) end)
	return ok and type(data) == "table" and data or nil
end

local function makeSaver(path, tbl)
	local last
	return function()
		local s = HttpService:JSONEncode(tbl)
		if s ~= last then
			last = s
			pcall(writefile, path, s)
		end
	end
end

local function weakKeys() return setmetatable({}, { __mode = "k" }) end

local Config = {
	Enabled = false,
	AutoStore = true,
	TweenSpeed = 150,      
	ArcHeight = 60,        
	Easing = "Sine",       
	FallMode = true,       
	MaxFallTime = 2.5,     
	SpeedJitter = true,    
	AvoidPlayers = true,   
	AvoidRadius = 150,
	NameFilter = "",       
	PriorityList = "Kitsune, Dragon, Tiger, Leopard, Dough, Spirit, Control, Venom, T-Rex, Mammoth, Portal",
	ScanInterval = 2,

	AutoHop = false,
	StayTime = 8,          
	MinServerPlayers = 4,
	MaxServerPlayers = 9,  
	RandomFallback = true, 
	AutoRejoin = true,     

	AutoTeam = true,
	Team = "Marines",      

	UseGameCap = false,    
	MaxPerFruit = 4,       
	UnknownStackFull = true, 

	NotifyEnabled = true,
	Theme = "Dark",
	ToggleKey = "RightShift",

	WebhookUrl = "",
	WebhookUsername = "Fruit Farm",
	WebhookPingId = "",    
	RarePingList = "Kitsune, Dragon, Leopard",
	HookFound = true,
	HookCollected = true,
	HookStored = false,
	HookHop = false,
	HookError = true,
	HookSummaryMins = 0,   
}

pcall(makefolder, DIR)
for k, v in pairs(readJson(SETTINGS_FILE) or {}) do
	if Config[k] ~= nil and type(v) == type(Config[k]) then Config[k] = v end
end
NotifyState.on = Config.NotifyEnabled
local sessionStart = os.clock()
local saveDisabled = false 
do
	local saveConfig = makeSaver(SETTINGS_FILE, Config)
	task.spawn(function()
		while task.wait(2) do
			if not saveDisabled then saveConfig() end
		end
	end)
end

local Skipped = weakKeys() 
local joinTime = os.clock()
local busy = false         
local stats = { collected = 0 }

local function getHRP()
	local char = player.Character
	local hum = char and char:FindFirstChildOfClass("Humanoid")
	local hrp = char and char:FindFirstChild("HumanoidRootPart")
	if hum and hrp and hum.Health > 0 then return hrp end
end

local function playerNear(pos, radius)
	for _, p in ipairs(Players:GetPlayers()) do
		if p ~= player then
			local hrp = p.Character and p.Character:FindFirstChild("HumanoidRootPart")
			if hrp and (hrp.Position - pos).Magnitude <= radius then return p end
		end
	end
end

local listCache = {}
local function parseList(s)
	s = s or ""
	local out = listCache[s]
	if out then return out end
	out = {}
	for term in string.gmatch(string.lower(s), "[^,]+") do
		term = string.match(term, "^%s*(.-)%s*$")
		if term ~= "" then out[#out + 1] = term end
	end
	listCache[s] = out
	return out
end

local function matchesFilter(name)
	local terms = parseList(Config.NameFilter)
	if #terms == 0 then return true end
	local lname = string.lower(name)
	for _, t in ipairs(terms) do
		if string.find(lname, t, 1, true) then return true end
	end
	return false
end

local function fruitRank(name)
	local lname = string.lower(name)
	for i, t in ipairs(parseList(Config.PriorityList)) do
		if string.find(lname, t, 1, true) then return i end
	end
	return math.huge
end

local RealFruits = {}
for name in string.gmatch(
	"bomb,spike,chop,spring,smoke,flame,ice,sand,dark,light,rubber,barrier,magma,quake,"
	.. "buddha,string,phoenix,rumble,paw,gravity,dough,venom,control,dragon,"
	.. "spirit,leopard,tiger,kitsune,t-rex,mammoth,portal,shadow,blizzard,sound,gas,yeti,"
	.. "falcon,diamond,love,spider,door,pain,rocket,spin,blade,eagle,creation,ghost",
	"[^,]+") do
	RealFruits[name] = true
end

local function isFruitName(name)
	local base = string.match(name, "^(.-)%s+Fruit$")
	return base ~= nil and RealFruits[string.lower(base)] == true
end

local function undouble(s)
	local len = #s
	if len % 2 == 0 then return nil end
	local mid = math.floor((len + 1) / 2)
	if string.sub(s, mid, mid) ~= "-" then return nil end
	local left = string.sub(s, 1, mid - 1)
	if left == string.sub(s, mid + 1) then return left end
end

local function normFruit(name)
	name = string.lower(name)
	name = string.match(name, ":%s*(.+)$") or name
	name = string.gsub(name, "%s*fruit$", "")
	name = string.match(name, "^%s*(.-)%s*$")
	return undouble(name) or name
end

local function playerRange()
	return math.min(Config.MinServerPlayers, Config.MaxServerPlayers),
		math.max(Config.MinServerPlayers, Config.MaxServerPlayers)
end

local WH_COLORS = {
	found = 0x57F287, collected = 0xFEE75C, stored = 0x3498DB,
	hop = 0x95A5A6, error = 0xED4245, test = 0x5865F2, summary = 0x9B59B6,
}
local EVENT_KEYS = {
	found = "HookFound", collected = "HookCollected", stored = "HookStored",
	hop = "HookHop", error = "HookError",
}
local WH_PATTERNS = {
	"^https://discord%.com/api/webhooks/%d+/[%w_%-]+",
	"^https://discordapp%.com/api/webhooks/%d+/[%w_%-]+",
	"^https://ptb%.discord%.com/api/webhooks/%d+/[%w_%-]+",
	"^https://canary%.discord%.com/api/webhooks/%d+/[%w_%-]+",
}

local whQueue, whRunning = {}, false
local whLast = { ok = nil, text = "nothing sent yet", t = 0 }

local function webhookValid()
	local url = Config.WebhookUrl
	for _, p in ipairs(WH_PATTERNS) do
		if string.find(url, p) then return true end
	end
	return false
end

local function webhookReady()
	return httpRequest ~= nil and webhookValid()
end

local function pingFor(fruitName)
	local id = Config.WebhookPingId
	if not string.match(id, "^%d+$") then return nil end
	if not fruitName then return "<@" .. id .. ">" end
	local lname = string.lower(fruitName)
	for _, t in ipairs(parseList(Config.RarePingList)) do
		if string.find(lname, t, 1, true) then return "<@" .. id .. ">" end
	end
end

local function pumpWebhook()
	if whRunning then return end
	whRunning = true
	task.spawn(function()
		while #whQueue > 0 do
			local item = table.remove(whQueue, 1)
			local ok, res = pcall(httpRequest, {
				Url = Config.WebhookUrl,
				Method = "POST",
				Headers = { ["Content-Type"] = "application/json" },
				Body = item.body,
			})
			local code = ok and type(res) == "table" and res.StatusCode or nil

			if code == 429 and item.tries < 3 then
				item.tries = item.tries + 1
				local h = res.Headers or {}
				local wait = tonumber(h["retry-after"] or h["Retry-After"] or h["x-ratelimit-reset-after"]) or 2
				table.insert(whQueue, 1, item)
				whLast = { ok = false, text = "rate limited, retrying", t = os.time() }
				task.wait(math.clamp(wait, 1, 30))
			else
				if code and code >= 200 and code < 300 then
					whLast = { ok = true, text = "last message sent", t = os.time() }
				elseif code == 404 then
					whLast = { ok = false, text = "webhook not found (deleted?)", t = os.time() }
				elseif code == 401 or code == 403 then
					whLast = { ok = false, text = "webhook rejected (bad token?)", t = os.time() }
				else
					whLast = { ok = false, text = "failed (" .. tostring(code or "no response") .. ")", t = os.time() }
				end
				task.wait(1)
			end
		end
		whRunning = false
	end)
end

local function sendEmbed(kind, title, eventFields, opts)
	opts = opts or {}
	local toggleKey = EVENT_KEYS[kind]
	if not webhookReady() or (toggleKey and not Config[toggleKey]) then return end
	if #whQueue >= 20 then table.remove(whQueue, 1) end 

	local fields = table.move(eventFields or {}, 1, #(eventFields or {}), 1, {})
	fields[#fields + 1] = { name = "Server age", value = fmtAge(workspace.DistributedGameTime), inline = true }
	fields[#fields + 1] = { name = "Players", value = #Players:GetPlayers() .. "/" .. Players.MaxPlayers, inline = true }
	fields[#fields + 1] = {
		name = "Join",
		value = "[Click to join this server](https://www.roblox.com/games/start?placeId="
			.. game.PlaceId .. "&gameInstanceId=" .. game.JobId .. ")",
		inline = true,
	}

	local username = Config.WebhookUsername
	if username == "" then username = "Fruit Farm" end

	whQueue[#whQueue + 1] = {
		tries = 0,
		body = HttpService:JSONEncode({
			username = string.sub(username, 1, 80),
			content = opts.ping,
			allowed_mentions = { parse = { "users" } },
			embeds = { {
				title = title,
				description = opts.description,
				color = WH_COLORS[kind] or WH_COLORS.test,
				fields = fields,
				footer = { text = player.Name .. " • " .. player.DisplayName },
				timestamp = os.date("!%Y-%m-%dT%H:%M:%SZ"),
			} },
		}),
	}
	pumpWebhook()
end

local function webhookStatusText()
	if not httpRequest then return "your executor has no request function" end
	if Config.WebhookUrl == "" then return "no URL set" end
	if not webhookValid() then return "URL doesn't look like a Discord webhook" end
	local age = whLast.t > 0 and (", " .. fmtAge(os.time() - whLast.t) .. " ago") or ""
	return whLast.text .. age
end

local Inv = {
	stacks = {},  
	types = {},   
	counts = {},  
	unknown = {}, 
	src = {},     
	ok = false,
	memBad = 0,   
	dirty = true,
}
for k, v in pairs(readJson(STACKS_FILE) or {}) do
	if type(v) == "number" then Inv.stacks[k] = v end
end
local saveStacks = makeSaver(STACKS_FILE, Inv.stacks)

local lastRefresh, lastMemScan, scanningMem = 0, -1000, false
local invReady = false 

local function capFor()
	if Config.UseGameCap then
		local data = player:FindFirstChild("Data")
		local v = data and data:FindFirstChild("FruitCap")
		if v and tonumber(v.Value) then return tonumber(v.Value), "game FruitCap" end
	end
	return Config.MaxPerFruit, "slider"
end

local modules = {}
local function lazyRequire(key, getPath, pick)
	if modules[key] == nil then
		local ok, mod = pcall(function()
			local m = require(getPath())
			if pick then return m[pick] end
			return m
		end)
		modules[key] = (ok and type(mod) == "table") and mod or false
	end
	return modules[key]
end

local function getRemoteUtil()
	return lazyRequire("util", function() return RS.Controllers.UI.Inventory.RemoteUtil end)
end
local function getConfigs()
	return lazyRequire("cfg", function() return RS.ItemConfig.Generated.Configs end, "Configs")
end

local function storageKey(id)
	local cfgs = getConfigs()
	if not cfgs then return nil end
	local ok, key = pcall(function()
		local c = cfgs[id] or cfgs[tostring(id)]
		return c and c.Index and c.Index.StorageKey
	end)
	return ok and key or nil
end

local function callTimed(fn, timeout)
	local result
	local th = task.spawn(function() result = table.pack(pcall(fn)) end)
	local t0 = os.clock()
	while not result and os.clock() - t0 < (timeout or 3) do task.wait() end
	if not result then pcall(task.cancel, th) end
	return result
end

local function findTileGrid()
	local gui = player:FindFirstChild("PlayerGui")
	local root = gui and gui:FindFirstChild("ModificationsMenuRoot")
	return root and root:FindFirstChild("TileGrid", true)
end

local function menuVisible(grid)
	local gui = player:FindFirstChild("PlayerGui")
	local o = grid
	while o and o ~= gui do
		if o:IsA("GuiObject") and not o.Visible then return false end
		if o:IsA("LayerCollector") and not o.Enabled then return false end
		o = o.Parent
	end
	return true
end

local function syncFromMenu()
	local grid = findTileGrid()
	if not grid or not menuVisible(grid) then return 0 end

	local read = 0
	for _, tile in ipairs(grid:GetChildren()) do
		if string.find(tile.Name, "^Tile%-") then
			local details = tile:FindFirstChild("Details")
			local nameLabel = details and details:FindFirstChild("Line-1")
			local category = details and details:FindFirstChild("Category")
			if nameLabel and nameLabel:IsA("TextLabel") and category and category.Text == "Blox Fruit" then
				local badge = tile:FindFirstChild("Count")
				local label = badge and badge:FindFirstChild("Label")
				local n = label and tonumber(label.Text) or 1
				if badge and badge:IsA("GuiObject") and not badge.Visible then n = 1 end
				Inv.stacks[normFruit(nameLabel.Text)] = math.max(1, math.floor(n))
				read = read + 1
			end
		end
	end
	if read > 0 then Inv.src.menu = true end
	return read
end

local function readTiles()
	local util, cfgs = getRemoteUtil(), getConfigs()
	if not (util and cfgs and type(util.getTiles) == "function") then return nil end

	local ok, promise = pcall(util.getTiles, "Treasure")
	if not ok or type(promise) ~= "table" or type(promise.await) ~= "function" then return nil end

	local r = callTimed(function() return promise:await() end, 5)
	if not r or not r[1] or type(r[2]) ~= "table" then return nil end

	local types, ids = {}, {}
	for _, tile in pairs(r[2]) do
		local id = type(tile) == "table" and rawget(tile, "ItemId")
		if id then
			local key = storageKey(id)
			if key and undouble(string.lower(key)) then 
				local name = normFruit(key)
				types[name], ids[id] = true, name
			end
		end
	end
	return types, ids
end

local function readMemoryStacks(idToName)
	local gc = getgc(true)
	local out, any = {}, false
	for i, t in ipairs(gc) do
		if i % 5000 == 0 then task.wait() end
		if type(t) == "table" then
			local id = rawget(t, "ItemId")
			if type(id) == "number" and idToName[id] and rawget(t, "Key") == "Quantity" then
				local v = tonumber(rawget(t, "Value"))
				if v then
					local name = idToName[id]
					out[name] = math.max(out[name] or 0, math.floor(v))
					any = true
				end
			end
		end
	end
	return any and out or nil
end

local function rebuildCounts()
	local cap = capFor()
	local counts, unknown = {}, {}
	for name in pairs(Inv.types) do
		local n = Inv.stacks[name]
		if not n then
			unknown[name] = true
			if Config.UnknownStackFull then n = cap end
		end
		counts[name] = math.max(1, n or 1)
	end
	for name in pairs(Inv.stacks) do
		if not Inv.types[name] then Inv.stacks[name] = nil end 
	end
	Inv.counts, Inv.unknown = counts, unknown
	saveStacks()
end

local function refreshInventory(force)
	lastRefresh = os.clock()
	local types, idToName = readTiles()
	if not types then return false end
	Inv.types = types
	if force then Inv.memBad = 0 end

	local now = os.clock()
	local missing = false
	for name in pairs(types) do
		if not Inv.stacks[name] then missing = true break end
	end
	local recheck = Inv.recheckAt and now >= Inv.recheckAt
	local due = force or Inv.dirty or recheck
		or (missing and now - lastMemScan > 30)
		or now - lastMemScan > 120

	if due and not scanningMem and Inv.memBad < 3 and getgc then
		scanningMem, lastMemScan, Inv.dirty = true, now, false
		if recheck then Inv.recheckAt = nil end
		local ok, found = pcall(readMemoryStacks, idToName)
		scanningMem = false
		if ok and found then
			for name in pairs(types) do
				if found[name] then Inv.stacks[name] = found[name] end
			end
			Inv.src.memory = true
			Inv.memBad = 0
		else
			Inv.memBad = Inv.memBad + 1
		end
	end

	syncFromMenu()
	rebuildCounts()
	Inv.ok = true
	return true
end

local function fruitTools()
	local out = {}
	for _, container in ipairs({ player:FindFirstChild("Backpack") or false, player.Character or false }) do
		if container then
			for _, c in ipairs(container:GetChildren()) do
				if c:IsA("Tool") and isFruitName(c.Name) then out[#out + 1] = c end
			end
		end
	end
	return out
end

local function ownedCounts()
	local counts = table.clone(Inv.counts)
	for _, tool in ipairs(fruitTools()) do
		local k = normFruit(tool.Name)
		counts[k] = (counts[k] or 0) + 1
	end
	return counts
end

local MapFruits = {} 

local function trackFruit(o)
	if (o:IsA("Tool") or o:IsA("Model")) and isFruitName(o.Name) then MapFruits[o] = true end
end
for _, o in ipairs(workspace:GetChildren()) do trackFruit(o) end
workspace.ChildAdded:Connect(trackFruit)
workspace.ChildRemoved:Connect(function(o) MapFruits[o] = nil end)

local function skipReason(o, owned, cap)
	if Skipped[o] then return "player nearby or failed pickup" end
	local key = normFruit(o.Name)
	local have = owned[key] or 0
	if have >= cap then
		if Inv.unknown[key] and Config.UnknownStackFull then
			return "you own it, stack size unknown, open the Treasure menu"
		end
		return "you own " .. have .. ", cap " .. cap
	end
	if not matchesFilter(o.Name) then return "name filter" end
end

local function mapFruits()
	local out = {}
	if next(MapFruits) == nil then return out end
	local owned, cap = ownedCounts(), capFor()
	for o in pairs(MapFruits) do
		out[#out + 1] = { obj = o, reason = skipReason(o, owned, cap) }
	end
	return out
end

local function fruitPart(o)
	return o:FindFirstChild("Handle")
		or (o:IsA("Model") and o.PrimaryPart)
		or o:FindFirstChildWhichIsA("BasePart", true)
end

local function findFruits()
	local list = {}
	for _, f in ipairs(mapFruits()) do
		if not f.reason then
			local part = fruitPart(f.obj)
			if part then list[#list + 1] = { obj = f.obj, part = part } end
		end
	end
	return list
end

local function nearestFruit(origin)
	local best, bestRank, bestDist
	for _, f in ipairs(findFruits()) do
		local rank = fruitRank(f.obj.Name)
		local d = (f.part.Position - origin).Magnitude
		if not best or rank < bestRank or (rank == bestRank and d < bestDist) then
			best, bestRank, bestDist = f, rank, d
		end
	end
	return best
end

local EasingStyles = {
	Sine = Enum.EasingStyle.Sine,
	Quad = Enum.EasingStyle.Quad,
	Quart = Enum.EasingStyle.Quart,
	Linear = Enum.EasingStyle.Linear,
}

local function bezier(a, c, b, t)
	local u = 1 - t
	return a * (u * u) + c * (2 * u * t) + b * (t * t)
end

local function controlPoint(a, b)
	local lift = math.min(Config.ArcHeight, (b - a).Magnitude * 0.25)
	return (a + b) / 2 + Vector3.new(0, lift * 2, 0)
end

local function arcLength(a, c, b)
	local len, prev = 0, a
	for i = 1, 12 do
		local p = bezier(a, c, b, i / 12)
		len = len + ((p - prev).Magnitude)
		prev = p
	end
	return len
end

local function flyBallistic(targetPart, offset)
	local hrp = getHRP()
	if not hrp or not targetPart.Parent then return false end
	local char = player.Character
	local hum = char:FindFirstChildOfClass("Humanoid")

	local a = hrp.Position
	local b = targetPart.Position + offset
	local delta = b - a
	if delta.Magnitude < 1.5 then return true end

	local g = workspace.Gravity
	local T = math.clamp(delta.Magnitude / math.max(Config.TweenSpeed, 1), 0.5, Config.MaxFallTime)
	if Config.SpeedJitter then T = T * (0.9 + math.random() * 0.2) end

	local v0 = Vector3.new(delta.X / T, delta.Y / T + 0.5 * g * T, delta.Z / T)
	local grav = Vector3.new(0, -g, 0)

	local flat = Vector3.new(delta.X, 0, delta.Z)
	if flat.Magnitude > 1 then
		hrp.CFrame = CFrame.lookAt(hrp.Position, hrp.Position + flat.Unit)
	end

	local parts = {}
	for _, p in ipairs(char:GetDescendants()) do
		if p:IsA("BasePart") then parts[p] = p.CanCollide end
	end
	local noclip = RunService.Stepped:Connect(function()
		for p in pairs(parts) do p.CanCollide = false end
	end)

	if hum then hum:ChangeState(Enum.HumanoidStateType.Jumping) end

	local ok = true
	local t0 = os.clock()
	local ran, err = pcall(function()
		while true do
			RunService.Heartbeat:Wait()
			local t = os.clock() - t0
			if t >= T then break end

			if not Config.Enabled or not hrp.Parent or (hum and hum.Health <= 0) or not targetPart.Parent
				or (Config.AvoidPlayers and playerNear(targetPart.Position, Config.AvoidRadius)) then
				ok = false
				return
			end

			local want = a + v0 * t + grav * (0.5 * t * t)
			hrp.AssemblyLinearVelocity = (v0 + grav * t) + (want - hrp.Position) * 5
			hrp.AssemblyAngularVelocity = Vector3.zero

			if hum and t > 0.25 and hum:GetState() ~= Enum.HumanoidStateType.Freefall then
				hum:ChangeState(Enum.HumanoidStateType.Freefall)
			end
		end

		local cur = getHRP()
		if cur and (cur.Position - b).Magnitude < 15 then
			cur.CFrame = CFrame.new(b) * (cur.CFrame - cur.CFrame.Position)
		end
	end)
	if not ran then
		warn("Fall flight error:", err)
		ok = false
	end

	noclip:Disconnect()
	for part, original in pairs(parts) do
		pcall(function() part.CanCollide = original end)
	end
	local cur = getHRP()
	if cur then
		cur.AssemblyLinearVelocity = Vector3.zero
		cur.AssemblyAngularVelocity = Vector3.zero
	end
	if hum then hum:ChangeState(Enum.HumanoidStateType.Running) end

	return ok
end

local function flyTo(targetPart, offset)
	if Config.FallMode then return flyBallistic(targetPart, offset) end
	local hrp = getHRP()
	if not hrp or not targetPart.Parent then return false end
	local char = player.Character
	local hum = char:FindFirstChildOfClass("Humanoid")

	local function goal() return targetPart.Position + offset end
	local a, b0 = hrp.Position, goal()
	if (b0 - a).Magnitude < 1.5 then return true end

	local duration = math.max(arcLength(a, controlPoint(a, b0), b0) / math.max(Config.TweenSpeed, 1), 0.15)
	if Config.SpeedJitter then duration = duration * (0.9 + math.random() * 0.2) end

	local flat = Vector3.new(b0.X - a.X, 0, b0.Z - a.Z)
	local rot = flat.Magnitude > 1 and CFrame.lookAt(Vector3.zero, flat.Unit) or (hrp.CFrame - hrp.CFrame.Position)

	local parts = {}
	for _, p in ipairs(char:GetDescendants()) do
		if p:IsA("BasePart") then parts[p] = p.CanCollide end
	end
	local noclip = RunService.Stepped:Connect(function()
		for p in pairs(parts) do p.CanCollide = false end
	end)

	local lock = Instance.new("BodyVelocity")
	lock.MaxForce = Vector3.new(math.huge, math.huge, math.huge)
	lock.Velocity = Vector3.zero
	lock.Parent = hrp
	if hum then hum.PlatformStand = true end

	local progress = Instance.new("NumberValue")
	local tween = TweenService:Create(
		progress,
		TweenInfo.new(duration, EasingStyles[Config.Easing] or Enum.EasingStyle.Sine, Enum.EasingDirection.InOut),
		{ Value = 1 }
	)
	local done = false
	local conn = tween.Completed:Connect(function() done = true end)
	tween:Play()

	local ok, frame = true, 0
	local ran, err = pcall(function()
		while not done do
			RunService.Heartbeat:Wait()
			frame = frame + 1

			if not Config.Enabled or not hrp.Parent or (hum and hum.Health <= 0) or not targetPart.Parent
				or (frame % 10 == 0 and Config.AvoidPlayers and playerNear(targetPart.Position, Config.AvoidRadius)) then
				ok = false
				return
			end

			local b = goal()
			hrp.CFrame = CFrame.new(bezier(a, controlPoint(a, b), b, progress.Value)) * rot
			hrp.AssemblyLinearVelocity = Vector3.zero
			hrp.AssemblyAngularVelocity = Vector3.zero
		end
		hrp.CFrame = CFrame.new(goal()) * rot 
	end)
	if not ran then
		warn("Flight error:", err)
		ok = false
	end

	tween:Cancel()
	conn:Disconnect()
	noclip:Disconnect()
	progress:Destroy()
	lock:Destroy()
	for part, original in pairs(parts) do
		pcall(function() part.CanCollide = original end)
	end
	local cur = getHRP()
	if cur then
		cur.AssemblyLinearVelocity = Vector3.zero
		cur.AssemblyAngularVelocity = Vector3.zero
	end
	if hum then hum.PlatformStand = false end

	return ok
end

local function pickUp(fruit)
	local hrp = getHRP()
	if not hrp or not fruit.part.Parent then return end
	hrp.CFrame = fruit.part.CFrame

	local prompt = fruit.obj:FindFirstChildWhichIsA("ProximityPrompt", true)
	if prompt then pcall(fireproximityprompt, prompt) end
	pcall(function()
		firetouchinterest(hrp, fruit.part, 0)
		firetouchinterest(hrp, fruit.part, 1)
	end)
end

local function getFruitKey(tool)
	for _, v in pairs(tool:GetAttributes()) do
		if type(v) == "string" and string.find(v, "%-") then return v end
	end
	for _, d in ipairs(tool:GetDescendants()) do
		if d:IsA("StringValue") and string.find(d.Value, "%-") then return d.Value end
	end
	local base = string.match(tool.Name, "^(.-)%s*Fruit$")
	if base and base ~= "" then return base .. "-" .. base end
	return tool.Name
end

local function storeFruits()
	local hum = getHRP() and player.Character:FindFirstChildOfClass("Humanoid")
	local storedNames = {}

	for _, tool in ipairs(fruitTools()) do
		if hum and tool.Parent ~= player.Character then 
			pcall(hum.EquipTool, hum, tool)
			task.wait(0.3)
		end
		pcall(CommF.InvokeServer, CommF, "StoreFruit", getFruitKey(tool), tool)
		task.wait(0.4)

		local p = tool.Parent
		if p ~= player.Character and p ~= player:FindFirstChild("Backpack") then
			storedNames[#storedNames + 1] = tool.Name
			local k = normFruit(tool.Name)
			if Inv.stacks[k] then
				Inv.stacks[k] = Inv.stacks[k] + 1
			elseif not Inv.types[k] then
				Inv.stacks[k] = 1
			end
			Inv.types[k] = true
		end
	end

	if #storedNames > 0 then
		sendEmbed("stored", "Fruit stored", {
			{ name = "Fruits", value = shortList(storedNames, 10), inline = true },
		})
	end

	rebuildCounts()
	Inv.dirty = true
	Inv.recheckAt = os.clock() + 10
	task.spawn(refreshInventory)
end

local function setTeam()
	for _ = 1, 10 do
		if player.Team then break end
		local ok, err = pcall(CommF.InvokeServer, CommF, "SetTeam", Config.Team)
		if not ok then warn("Team select failed:", err) end
		task.wait(1)
	end
	joinTime = os.clock() 
end

task.spawn(function()
	while true do
		if Config.AutoTeam and not player.Team then setTeam() end
		task.wait(3)
	end
end)

task.spawn(function()
	while task.wait(2) do
		if Inv.ok and syncFromMenu() > 0 then rebuildCounts() end
	end
end)

local notified, foundAt = weakKeys(), weakKeys()
local lastSkipReport = ""

task.spawn(function()
	local t0 = os.clock()
	while not Inv.ok and os.clock() - t0 < 10 do
		if refreshInventory() then break end
		task.wait(1)
	end
	invReady = true

	if not Inv.ok then
		notify("error", "Inventory unreadable", "Couldn't read your inventory, so owned fruits can't be detected.", 8)
		sendEmbed("error", "Inventory unreadable", { { name = "Effect", value = "Owned fruits can't be detected" } })
	elseif next(Inv.unknown) ~= nil then
		local names = {}
		for k in pairs(Inv.unknown) do names[#names + 1] = k end
		table.sort(names)
		notify("warn", "Fruit counts unknown",
			"Couldn't read these stack sizes. Open the Treasure menu once.\nUnknown: " .. shortList(names, 10)
				.. (Config.UnknownStackFull and ".\nUntil then they count as full." or ".\nUntil then they count as 1."), 10)
	end

	while true do
	repeat
		if not Config.Enabled then busy = false task.wait(0.5) break end

		local hrp = getHRP()
		if not hrp then busy = false task.wait(1) break end

		if os.clock() - lastRefresh > 5 then refreshInventory() end

		local fruit = nearestFruit(hrp.Position)
		if not fruit then
			busy = false
			local parts = {}
			for _, f in ipairs(mapFruits()) do
				parts[#parts + 1] = f.obj.Name .. ": " .. (f.reason or "will take")
			end
			table.sort(parts)
			local report = table.concat(parts, "\n")
			if #parts > 0 and report ~= lastSkipReport then
				lastSkipReport = report
				notify("info", "No fruit to take", shortList(parts, 5, "\n"), 8)
			end
			task.wait(Config.ScanInterval)
			break
		end

		if Config.AvoidPlayers and playerNear(fruit.part.Position, Config.AvoidRadius) then
			Skipped[fruit.obj] = true
			notify("warn", "Fruit skipped", fruit.obj.Name .. ": player nearby.", 4)
			task.wait(0.3)
			break
		end

		busy = true
		if not notified[fruit.obj] then
			notified[fruit.obj] = true
			foundAt[fruit.obj] = os.clock()
			notify("ok", "Fruit found", fruit.obj.Name, 4)
			sendEmbed("found", "Fruit found", {
				{ name = "Fruit", value = fruit.obj.Name, inline = true },
			}, { ping = pingFor(fruit.obj.Name) })
		end

		if flyTo(fruit.part, Vector3.new(0, 3, 0)) and fruit.part.Parent then
			pickUp(fruit)
			task.wait(0.8 + math.random() * 0.4)

			if fruit.obj.Parent ~= workspace then
				stats.collected = stats.collected + 1
				sendEmbed("collected", "Fruit collected", {
					{ name = "Fruit", value = fruit.obj.Name, inline = true },
					{ name = "This session", value = tostring(stats.collected), inline = true },
					{ name = "Took", value = string.format("%.1fs", os.clock() - (foundAt[fruit.obj] or os.clock())), inline = true },
				}, { ping = pingFor(fruit.obj.Name) })
				if Config.AutoStore then storeFruits() end
			else
				Skipped[fruit.obj] = true 
			end
		end

		task.wait(0.3 + math.random() * 0.5)
	until true
	end
end)

local visited = {}
for id, v in pairs(readJson(VISITED_FILE) or {}) do
	if type(v) == "table" and v.t and v.ttl then visited[id] = v end
end

local function saveVisited()
	for id, v in pairs(visited) do
		if os.time() - v.t >= v.ttl then visited[id] = nil end
	end
	pcall(writefile, VISITED_FILE, HttpService:JSONEncode(visited))
end

local function avoid(id, ttl)
	visited[id] = { t = os.time(), ttl = ttl or 1800 }
end

local function isAvoided(id)
	local v = visited[id]
	return v ~= nil and os.time() - v.t < v.ttl
end

avoid(game.JobId) 
saveVisited()

local ServerBrowser = RS:FindFirstChild("__ServerBrowser")

local function fetchBrowserServers()
	if not ServerBrowser then return nil end
	local found, pending = {}, 0

	for i = 1, 100 do
		pending = pending + 1
		task.spawn(function()
			local ok, res = pcall(ServerBrowser.InvokeServer, ServerBrowser, i)
			if ok and type(res) == "table" then
				for id, info in pairs(res) do
					if type(id) == "string" and type(info) == "table" and tonumber(info.Count) then
						found[id] = info
					end
				end
			end
			pending = pending - 1
		end)
		if i % 10 == 0 then task.wait(0.1) end 
	end

	local t0 = os.clock()
	while pending > 0 and os.clock() - t0 < 8 do task.wait(0.1) end

	local out = {}
	for id, info in pairs(found) do
		if os.time() - (tonumber(info.__LastUpdate) or 0) < 300 then 
			out[#out + 1] = { id = id, playing = tonumber(info.Count), maxPlayers = Players.MaxPlayers, region = info.Region }
		end
	end
	return #out > 0 and out or nil
end

local function teleportTo(id)
	task.spawn(function()
		local ok = ServerBrowser and pcall(ServerBrowser.InvokeServer, ServerBrowser, "teleport", id)
		if not ok then pcall(TeleportService.TeleportToPlaceInstance, TeleportService, game.PlaceId, id, player) end
	end)
end

local function fetchPage(cursor)
	local url = "https://games.roblox.com/v1/games/" .. game.PlaceId
		.. "/servers/Public?sortOrder=Asc&excludeFullGames=true&limit=100" 
	if cursor then url = url .. ("&cursor=" .. cursor) end

	local body
	if httpRequest then
		local ok, res = pcall(httpRequest, { Url = url, Method = "GET" })
		if not ok or type(res) ~= "table" then return nil, "request failed" end
		if res.StatusCode == 429 then
			local h = res.Headers or {}
			return nil, "rate limited by Roblox (429)", tonumber(h["retry-after"] or h["Retry-After"])
		end
		if res.StatusCode ~= 200 then return nil, "http " .. tostring(res.StatusCode) end
		body = res.Body
	else
		local ok, b = pcall(function() return game:HttpGet(url) end)
		if not ok then return nil, tostring(b) end
		body = b
	end

	local ok, data = pcall(HttpService.JSONDecode, HttpService, body)
	if ok and type(data) == "table" then
		if type(data.data) == "table" then return data end
		if data.errors then return nil, "rate limited by Roblox (" .. string.sub(body, 1, 60) .. ")" end
	end
	return nil, "bad response '" .. string.sub((string.gsub(tostring(body), "%s+", " ")), 1, 60) .. "'"
end

local hopping, queued, scanning = false, false, false
local lastScan = -1000
local rateUntil = 0 
local hopFails, rateLimited = 0, 0 
local lastTarget

local function usable(srv)
	local lo, hi = playerRange()
	local playing = srv.playing or 0
	return srv.id ~= game.JobId and not isAvoided(srv.id)
		and playing >= lo and playing <= hi and playing < (srv.maxPlayers or Players.MaxPlayers)
end

local function loadCache()
	local cache = readJson(SERVERS_FILE)
	if not cache or type(cache.list) ~= "table" or cache.place ~= game.PlaceId then return nil end
	local maxAge = os.clock() < rateUntil and 1200 or 180
	if os.time() - (cache.t or 0) > maxAge then return nil end

	local list = {}
	for _, srv in ipairs(cache.list) do
		if usable(srv) then list[#list + 1] = srv end
	end
	return #list > 0 and list or nil
end

local function saveCache(list)
	pcall(writefile, SERVERS_FILE, HttpService:JSONEncode({
		t = os.time(), place = game.PlaceId,
		list = table.move(list, 1, math.min(#list, 60), 1, {}),
	}))
end

local function scanApi(candidates)
	local cursor
	for page = 1, 5 do 
		if page > 1 then task.wait(2.5) end 

		local data, err, retry = fetchPage(cursor)
		if not data then
			if string.find(err, "rate limited") then rateUntil = os.clock() + (retry or 60) end
			return err
		end

		for _, srv in ipairs(data.data) do
			local s = { id = srv.id, playing = srv.playing, maxPlayers = srv.maxPlayers }
			if s.playing and s.maxPlayers and usable(s) then candidates[#candidates + 1] = s end
		end

		local last = data.data[#data.data]
		if #candidates >= 15 or (last and last.playing and last.playing > select(2, playerRange())) then return end
		cursor = data.nextPageCursor
		if not cursor then return end
	end
end

local function scanServers()
	scanning, lastScan = true, os.clock()
	local candidates, lastErr = {}, nil

	local ok, err = pcall(function()
		for _, srv in ipairs(fetchBrowserServers() or {}) do
			if usable(srv) then candidates[#candidates + 1] = srv end
		end
		if #candidates > 0 then return end
		if os.clock() < rateUntil then
			lastErr = "rate limited by Roblox (cooldown)"
		else
			lastErr = scanApi(candidates)
		end
	end)
	scanning = false
	if not ok then lastErr = tostring(err) end

	if #candidates > 0 then saveCache(candidates) end
	return candidates, lastErr
end

local function pickServer()
	local candidates = loadCache()
	if not candidates then
		local t0 = os.clock() 
		while scanning and os.clock() - t0 < 40 do task.wait(0.5) end
		candidates = loadCache()
	end

	local lastErr
	if not candidates then candidates, lastErr = scanServers() end
	if #candidates == 0 then return nil, lastErr ~= nil, lastErr end
	return candidates[math.random(#candidates)]
end

task.spawn(function()
	while task.wait(3) do
	repeat
		if not (Config.AutoHop and Config.Enabled) or hopping or scanning then break end
		if os.clock() - lastScan < 45 or os.clock() - joinTime < 3 then break end

		local list = loadCache()
		if list and #list >= 5 then break end
		scanServers()
	until true
	end
end)

local function queueReload()
	if queue_on_teleport and not queued then
		queued = true
		pcall(queue_on_teleport, 'loadstring(readfile("' .. SCRIPT_FILE .. '"))()')
	end
end

task.spawn(function()
	local ok, overlay = pcall(function()
		local gui = game:GetService("CoreGui"):WaitForChild("RobloxPromptGui", 15)
		return gui and gui:WaitForChild("promptOverlay", 15)
	end)
	if not ok or not overlay then return end 

	local rejoining = false
	overlay.ChildAdded:Connect(function(child)
		if child.Name ~= "ErrorPrompt" or not Config.AutoRejoin or rejoining then return end
		rejoining = true
		task.wait(3)
		queueReload()
		for _ = 1, 20 do 
			if not Config.AutoRejoin then break end
			pcall(TeleportService.Teleport, TeleportService, game.PlaceId, player)
			task.wait(15)
		end
		rejoining = false
	end)
end)

local function tryHop()
	local server, failed, err = pickServer()

	if not server then
		hopFails = math.min(hopFails + 1, 5)
		local limited = failed and string.find(tostring(err), "rate limited") ~= nil
		local delay = failed and (10 * hopFails) or 5

		if limited then
			rateLimited = rateLimited + 1
			delay = math.min(60 * rateLimited, 300) 
		else
			rateLimited = 0
		end
		if failed then
			warn("Server list failed:", err)
			sendEmbed("error", "Server list failed", {
				{ name = "Error", value = string.sub(tostring(err), 1, 200) },
				{ name = "Retry in", value = delay .. "s", inline = true },
			})
		end

		if limited and rateLimited >= 2 and Config.RandomFallback then
			queueReload()
			notify("warn", "Server hop", "Server list is rate limited. Joining a random server.", 4)
			pcall(TeleportService.Teleport, TeleportService, game.PlaceId, player)
			task.wait(10) 
			return
		end

		notify("warn", "Server hop",
			(failed and ("Server list failed: " .. string.sub(tostring(err), 1, 140)) or "No free server found")
				.. ".\nRetrying in " .. delay .. "s.", 6)
		task.wait(delay)
		return
	end
	hopFails, rateLimited = 0, 0

	lastTarget = server.id
	queueReload()
	notify("info", "Server hop", "Joining a server with " .. server.playing .. "/" .. server.maxPlayers .. " players"
		.. (server.region and (" in " .. server.region) or "") .. ".", 3)
	sendEmbed("hop", "Server hop", {
		{ name = "Target", value = server.playing .. "/" .. server.maxPlayers .. " players", inline = true },
		{ name = "Region", value = tostring(server.region or "unknown"), inline = true },
		{ name = "Collected", value = tostring(stats.collected), inline = true },
	})
	teleportTo(server.id)

	task.wait(10) 
	avoid(server.id, 600)
	saveVisited()
end

local function hop()
	if hopping then return end
	hopping = true
	local ok, err = pcall(tryHop)
	if not ok then warn("Hop error:", err) end
	hopping = false
end

TeleportService.TeleportInitFailed:Connect(function()
	if lastTarget then 
		avoid(lastTarget, 600)
		saveVisited()
	end
	hopping = false
end)

task.spawn(function()
	while task.wait(1) do
	repeat
		if not (Config.AutoHop and Config.Enabled) or hopping then break end
		if not invReady or not getHRP() then break end
		if Config.AutoTeam and not player.Team then break end 
		if os.clock() - joinTime < Config.StayTime or busy then break end
		if #findFruits() > 0 then break end

		if Config.AutoStore then storeFruits() end 
		hop()
	until true
	end
end)

local function statusText()
	local names = {}
	for k, n in pairs(ownedCounts()) do
		names[#names + 1] = k .. " x" .. n .. (Inv.unknown[k] and "?" or "")
	end
	table.sort(names)

	local onMap = {}
	for _, f in ipairs(mapFruits()) do
		onMap[#onMap + 1] = f.obj.Name .. " (" .. (f.reason or "will take") .. ")"
	end
	table.sort(onMap)

	local srcs = {}
	for k in pairs(Inv.src) do srcs[#srcs + 1] = k end
	table.sort(srcs)

	local cap, capSrc = capFor()
	local state = not Config.Enabled and "idle" or (busy and "collecting" or "scanning")

	return table.concat({
		"State: " .. state .. (Config.AutoHop and " (auto hop on)" or ""),
		"Collected: " .. stats.collected .. " in " .. fmtAge(os.clock() - sessionStart),
		"Server: " .. #Players:GetPlayers() .. "/" .. Players.MaxPlayers .. " players, up "
			.. fmtAge(workspace.DistributedGameTime),
		"On the map: " .. (#onMap > 0 and shortList(onMap, 4) or "none"),
		"Cap per fruit: " .. cap .. " (" .. capSrc .. ")",
		"Owned (" .. #names .. " types" .. (Inv.ok and "" or ", unreadable")
			.. (next(Inv.unknown) ~= nil and ", ? = size unknown" or "") .. "): "
			.. (#names > 0 and shortList(names, 12) or "none"),
		"Stack sizes from: " .. (#srcs > 0 and table.concat(srcs, ", ") or "saved file only"),
		"Webhook: " .. webhookStatusText(),
	}, "\n")
end

local function sendSummary()
	sendEmbed("summary", "Status summary", {
		{ name = "Collected", value = tostring(stats.collected), inline = true },
		{ name = "Session", value = fmtAge(os.clock() - sessionStart), inline = true },
	}, { description = "```\n" .. statusText() .. "\n```" })
end

task.spawn(function()
	local last = os.clock()
	while task.wait(10) do
		local mins = Config.HookSummaryMins
		if mins > 0 and os.clock() - last >= mins * 60 then
			last = os.clock()
			sendSummary()
		end
	end
end)

local KEY_NAMES = { "RightShift", "RightControl", "LeftAlt", "Insert", "Home", "K", "M" }
if not table.find(KEY_NAMES, Config.ToggleKey) then Config.ToggleKey = "RightShift" end

local themeNames = { "Dark", "Light" }
pcall(function()
	local list = {}
	for name in pairs(WindUI:GetThemes()) do list[#list + 1] = name end
	if #list > 0 then table.sort(list) themeNames = list end
end)
if not table.find(themeNames, Config.Theme) then Config.Theme = themeNames[1] end

local Window = WindUI:CreateWindow({
	Title = "astra hub",
	Author = "somin",
	Folder = DIR,
	Size = UDim2.fromOffset(600, 480),
	Theme = Config.Theme,
	ToggleKey = Enum.KeyCode[Config.ToggleKey],
})

local function toggle(tab, key, title, desc, onChange)
	tab:Toggle({
		Title = title, Desc = desc, Value = Config[key],
		Callback = function(v)
			Config[key] = v
			if onChange then onChange(v) end
		end,
	})
end

local function slider(tab, key, title, desc, min, max, step)
	Config[key] = math.clamp(Config[key], min, max)
	tab:Slider({
		Title = title, Desc = desc, Step = step or 1,
		Value = { Min = min, Max = max, Default = Config[key] },
		Callback = function(v) Config[key] = v end,
	})
end

local function dropdown(tab, key, title, desc, values, onChange)
	if not table.find(values, Config[key]) then Config[key] = values[1] end
	tab:Dropdown({
		Title = title, Desc = desc, Values = values, Value = Config[key],
		Callback = function(v)
			Config[key] = v
			if onChange then onChange(v) end
		end,
	})
end

local function input(tab, key, title, desc, placeholder)
	tab:Input({
		Title = title, Desc = desc, Value = Config[key], Placeholder = placeholder,
		Callback = function(text) Config[key] = text or "" end,
	})
end

local function copy(text, what)
	if setclipboard then
		setclipboard(text)
		notify("ok", "Copied", what .. " copied to the clipboard.", 3)
	else
		notify("warn", "Copy", "Your executor has no setclipboard.", 4)
	end
end

local Dash = Window:Tab({ Title = "Dashboard", Icon = "layout-dashboard" })
local okPara, statusPara = pcall(Dash.Paragraph, Dash, { Title = "Status", Desc = "Loading..." })
if okPara and type(statusPara) == "table" and statusPara.SetDesc then
	task.spawn(function()
		while task.wait(2) do
			pcall(statusPara.SetDesc, statusPara, statusText())
		end
	end)
else
	Dash:Button({ Title = "Show Status", Callback = function() notify("info", "Status", statusText(), 12) end })
end
Dash:Section({ Title = "Quick controls" })
toggle(Dash, "Enabled", "Auto Collect Fruits", "Fly to spawned fruits and pick them up")
toggle(Dash, "AutoStore", "Auto Store Fruits", "Put picked up fruits into storage")
toggle(Dash, "AutoHop", "Auto Hop Servers", "Leave when no fruit is left to take", function() joinTime = os.clock() end)
Dash:Button({
	Title = "Read Stacks Now",
	Desc = "Reads stack sizes from the game's data right away (takes a few seconds)",
	Callback = function()
		task.spawn(function()
			local ok = refreshInventory(true)
			local n = 0
			for _ in pairs(Inv.stacks) do n = n + 1 end
			notify(ok and "ok" or "error", "Read stacks",
				ok and ("Read " .. n .. " fruit types.") or "Couldn't read the inventory.", 5)
		end)
	end,
})
Dash:Button({
	Title = "Copy Server Join Link",
	Callback = function()
		copy("https://www.roblox.com/games/start?placeId=" .. game.PlaceId .. "&gameInstanceId=" .. game.JobId,
			"Join link")
	end,
})

local Farm = Window:Tab({ Title = "Farm", Icon = "apple" })
Farm:Section({ Title = "Flight" })
slider(Farm, "TweenSpeed", "Flight Speed", "Studs per second", 60, 200, 10)
slider(Farm, "ArcHeight", "Arc Height", "How high the flight curves above the straight line (0 = straight)", 0, 150, 10)
dropdown(Farm, "Easing", "Easing", "Sine is gentle, Quart is sharper, Linear has no easing",
	{ "Sine", "Quad", "Quart", "Linear" })
toggle(Farm, "SpeedJitter", "Vary Flight Time", "Up to 10% random difference per flight")
toggle(Farm, "FallMode", "Fall Mode", "Fly as a jump/fall arc driven by physics instead of moving the character directly")
slider(Farm, "MaxFallTime", "Max Arc Time", "Seconds per flight. Longer = higher arc, shorter = faster and flatter", 1, 4, 0.5)

Farm:Section({ Title = "Safety" })
toggle(Farm, "AvoidPlayers", "Skip Fruits With Players Nearby", "Leave a fruit another player is standing at")
slider(Farm, "AvoidRadius", "Player Distance", "Studs around the fruit", 50, 400, 10)

Farm:Section({ Title = "Team" })
toggle(Farm, "AutoTeam", "Auto Set Team", "Pick a team automatically on every join")
dropdown(Farm, "Team", "Team", nil, { "Marines", "Pirates" })

local Hop = Window:Tab({ Title = "Server Hop", Icon = "server" })
slider(Hop, "StayTime", "Stay Time", "Seconds to scan a server before leaving", 5, 15)

Hop:Section({ Title = "Target Server" })
slider(Hop, "MinServerPlayers", "Min Players", "Lowest player count to hop to", 1, 11)
slider(Hop, "MaxServerPlayers", "Max Players", "Highest player count to hop to", 1, 11)

Hop:Section({ Title = "Reliability" })
toggle(Hop, "RandomFallback", "Random Server When Rate Limited", "Let Roblox pick a server if the list stays blocked")
toggle(Hop, "AutoRejoin", "Auto Rejoin", "Rejoin after a kick or disconnect")

Hop:Section({ Title = "Actions" })
Hop:Button({ Title = "Hop Now", Callback = function() task.spawn(hop) end })
Hop:Button({
	Title = "Test Server Browser",
	Callback = function()
		task.spawn(function()
			local list = fetchBrowserServers()
			if not list then return notify("error", "Server browser", "No servers returned.", 6) end
			local n = 0
			for _, s in ipairs(list) do
				if usable(s) then n = n + 1 end
			end
			notify("info", "Server browser", #list .. " servers found, " .. n .. " you could hop to.", 6)
		end)
	end,
})
Hop:Button({
	Title = "Clear Visited Servers",
	Callback = function()
		table.clear(visited)
		avoid(game.JobId)
		saveVisited()
		notify("ok", "Server hop", "Visited servers cleared.", 3)
	end,
})

local Filters = Window:Tab({ Title = "Filters", Icon = "filter" })
input(Filters, "NameFilter", "Name Filter", "Empty = any fruit", "e.g. Dragon, Leopard")
input(Filters, "PriorityList", "Priority Order", "Grabbed first to last, the rest nearest first",
	"e.g. Kitsune, Dragon, Leopard")

Filters:Section({ Title = "Storage Cap (per fruit type)" })
toggle(Filters, "UseGameCap", "Use Game Fruit Cap",
	"Read the cap from player.Data.FruitCap instead of the slider", rebuildCounts)
slider(Filters, "MaxPerFruit", "Max Per Fruit", "Stack limit per fruit type, used when the game cap is off", 1, 20)
toggle(Filters, "UnknownStackFull", "Unknown Stack Counts As Full",
	"Owned fruit whose stack size hasn't been read yet is skipped. Open the Treasure menu to read sizes",
	rebuildCounts)
Filters:Button({
	Title = "Clear Skipped Fruits",
	Callback = function()
		table.clear(Skipped)
		notify("ok", "Filters", "Skipped fruits cleared.", 3)
	end,
})

local Hook = Window:Tab({ Title = "Webhook", Icon = "bell" })
local okHook, hookPara = pcall(Hook.Paragraph, Hook, { Title = "Webhook status", Desc = webhookStatusText() })
if okHook and type(hookPara) == "table" and hookPara.SetDesc then
	task.spawn(function()
		while task.wait(2) do
			pcall(hookPara.SetDesc, hookPara, webhookStatusText())
		end
	end)
end

input(Hook, "WebhookUrl", "Discord Webhook URL", "Saved to the config file. Empty = no alerts",
	"https://discord.com/api/webhooks/...")
input(Hook, "WebhookUsername", "Sender Name", "Name shown on the messages", "Fruit Farm")

Hook:Section({ Title = "Pings" })
input(Hook, "WebhookPingId", "Your Discord User ID", "Digits only. Pings you for the fruits listed below",
	"e.g. 123456789012345678")
input(Hook, "RarePingList", "Ping For Fruits", "Comma separated. Empty = never ping", "e.g. Kitsune, Dragon")

Hook:Section({ Title = "Events" })
toggle(Hook, "HookFound", "Fruit Found", "When a fruit is spotted")
toggle(Hook, "HookCollected", "Fruit Collected", "When a fruit is picked up")
toggle(Hook, "HookStored", "Fruit Stored", "When fruits are put into storage")
toggle(Hook, "HookHop", "Server Hop", "Each time the script hops")
toggle(Hook, "HookError", "Errors", "Server list failures and unreadable inventory")
slider(Hook, "HookSummaryMins", "Status Summary Every (min)", "0 = off", 0, 60, 5)

Hook:Section({ Title = "Actions" })
Hook:Button({
	Title = "Test Webhook",
	Callback = function()
		if not httpRequest then return notify("error", "Webhook", "Your executor has no request function.", 4) end
		if not webhookValid() then return notify("warn", "Webhook", "Enter a valid Discord webhook URL first.", 4) end
		sendEmbed("test", "Fruit Farm test", { { name = "Fruit", value = "Test Fruit", inline = true } },
			{ ping = pingFor() })
		notify("ok", "Webhook", "Test message queued.", 4)
	end,
})
Hook:Button({
	Title = "Send Status Summary Now",
	Callback = function()
		if not webhookReady() then return notify("warn", "Webhook", "Set a valid webhook URL first.", 4) end
		sendSummary()
		notify("ok", "Webhook", "Summary queued.", 3)
	end,
})

local Settings = Window:Tab({ Title = "Settings", Icon = "settings" })
toggle(Settings, "NotifyEnabled", "Notifications", "In-game popups (errors always show)",
	function(v) NotifyState.on = v end)
dropdown(Settings, "Theme", "Theme", nil, themeNames, function(v)
	pcall(WindUI.SetTheme, WindUI, v)
end)
dropdown(Settings, "ToggleKey", "Menu Key", "Applies after the next load", KEY_NAMES, function(v)
	pcall(function() Window:SetToggleKey(Enum.KeyCode[v]) end)
end)
Settings:Section({ Title = "Config" })
Settings:Button({
	Title = "Reset Settings",
	Desc = "Deletes the saved settings file. Re-execute the script afterwards",
	Callback = function()
		Config.Enabled, Config.AutoHop = false, false
		saveDisabled = true
		pcall(delfile, SETTINGS_FILE)
		notify("warn", "Settings", "Settings file deleted. Re-execute the script to load defaults.", 6)
	end,
})
Settings:Button({
	Title = "Close UI And Stop",
	Desc = "Turns the farm off and removes the window",
	Callback = function()
		Config.Enabled, Config.AutoHop = false, false
		pcall(function() Window:Destroy() end)
	end,
})
