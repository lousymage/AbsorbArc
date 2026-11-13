-- AbsorbArc 0.5.5 -- WoW: Forever (client 1.60.1, interface 16001, Lua 5.1)
-- Shows the remaining absorb of several shield spells as bars (arc or
-- straight) next to each other.
--
-- Forever runs on the modern client, which restricts addons:
--   - no combat log for addons
--   - in combat, the player's auras can't be read at all, and
--     UnitGetTotalAbsorbs is a "secret" value: it may be handed to widgets
--     (StatusBar, FontString, SetAlpha) but not compared or used in math
-- So shields are tracked like this:
--   - out of combat: exact, from the aura's points (remaining absorb)
--   - own shield cast in combat: UNIT_SPELLCAST_SUCCEEDED (spellID readable)
--   - shield from someone else in combat: inferred when the absorb amount
--     changes and Blizzard's buff bar gains a button at the same moment
--   - remaining amount in combat: the secret total absorb, drawn through
--     StatusBar dots; a bar's alpha is the secret total, so it vanishes at 0
--   - Mana Shield (its aura has no points): counted down from mana drops

local ADDON = ...
local PI = 3.14159265358979
local N = 192 -- dots per bar (dense, so the edges stay smooth)
local PREVIEW_BARS = 3
local ADDON_PATH = "Interface\\AddOns\\" .. ADDON .. "\\"
local PWS = "Power Word: Shield"
local INFER_WINDOW = 0.3 -- seconds between absorb change and buff change
local COMBAT_TICK = 0.1
local IDLE_TICK = 0.5
local SECRET_REDRAW = 0.1

-- Tracked shields. One fixed color per shield.
--   ids      = spell IDs of all ranks (verified in game)
--   fallback = maximum used when neither a remembered value nor the spell
--              description is available
local SHIELD_ORDER = {
	"Ice Barrier",
	"Power Word: Shield",
	"Mana Shield",
	"Fire Ward",
	"Frost Ward",
	"Shadow Ward",
	"Sacrifice",
}
local SHIELDS = {
	["Ice Barrier"] = {
		duration = 60,
		fallback = 925,
		color = { 0.45, 0.85, 1.0 },
		ids = { 11426, 13031, 13032, 13033 },
	},
	["Power Word: Shield"] = {
		duration = 30,
		fallback = 942,
		color = { 1.0, 0.9, 0.45 },
		ids = { 17, 592, 600, 3747, 6065, 6066, 10898, 10899, 10900, 10901 },
	},
	["Mana Shield"] = {
		duration = 60,
		fallback = 570,
		color = { 0.25, 0.35, 1.0 },
		ids = { 1463, 8494, 8495, 10191, 10192, 10193 },
		-- neither its aura (no points) nor the player's mana (always secret
		-- on Forever) tells how much is left: estimated from the number of
		-- absorbed hits, see OnAbsorbedHit
		noAmount = true,
		schools = 1, -- physical only (its spell description says so)
	},
	["Fire Ward"] = {
		duration = 30,
		fallback = 675,
		color = { 1.0, 0.4, 0.1 },
		ids = { 543, 8457, 8458, 10223, 10225 },
		schools = 4,
	},
	["Frost Ward"] = {
		duration = 30,
		fallback = 675,
		color = { 0.2, 1.0, 0.8 },
		ids = { 6143, 8461, 8462, 10177, 28609 },
		schools = 16,
	},
	["Shadow Ward"] = {
		duration = 30,
		fallback = 675,
		color = { 0.7, 0.35, 1.0 },
		ids = { 6229, 11739, 11740, 28610 },
		schools = 32,
	},
	["Sacrifice"] = {
		duration = 30,
		fallback = 1000,
		color = { 0.85, 0.2, 0.45 },
		ids = { 7812, 19438, 19440, 19441, 19442, 19443 },
	},
}
local SHIELD_BY_ID = {}
for name, def in pairs(SHIELDS) do
	for _, id in ipairs(def.ids) do
		SHIELD_BY_ID[id] = name
	end
end

local DEFAULTS = {
	x = -150, -- position of the first bar's middle point (offset from screen center)
	y = 0,
	size = 12, -- base thickness, multiplied by scale
	scale = 1,
	length = 471, -- base length of a bar, multiplied by scale
	curve = 100, -- 0 = straight, 100 = half circle
	side = "left", -- side of the character: left, right, top, bottom
	alpha = 1,
	bgalpha = 0.55,
	anchor = "bottom", -- "bottom": first end (top/left) recedes first; "top": other end
	style = "dot", -- "dot" (custom texture) or "square" (fallback)
	text = true,
	smooth = true, -- draw each bar as one layer (see ApplySmooth)
	debug = false,
}

local DB
local cfg, mover = nil, nil
local barCX, barCY = 0, 0
local unlocked = false
local arc = nil
local bars = {} -- bars[0], bars[1], ... created on demand
local geo = { sc = 1, L = 471, size = 12, theta = PI, side = "left", p = 18, tex = "", quad = 1 }
-- dot_smooth.tga: the visible circle (alpha 0.5) is 26 of its 32 pixels wide, so the
-- soft edge can fade out completely; quads are enlarged to keep the thickness
local DOT_QUAD = 32 / 26
local lastN = -1
local shields = {} -- shield name -> state table
-- the current fight, for Mana Shield learning (see NewFight / LearnAfterFight)
local fight = { hits = 0, keys = {}, unsure = false, casts = 0, breaks = {} }
local test = nil
local testKeys = { {}, {}, {} }
local previewKeys = { {}, {}, {} }

local function say(t)
	DEFAULT_CHAT_FRAME:AddMessage("|cff66ccffAbsorbArc:|r " .. t)
end

-- With /aa debug, every line also goes into the saved variables
-- (AbsorbArcCharDB.debugLog, written on /reload or logout).
local DEBUG_LOG_MAX = 1000

local function trace(t)
	if DB and DB.debug then
		local log = DB.debugLog
		if type(log) ~= "table" then
			log = {}
			DB.debugLog = log
		end
		local lock = InCombatLockdown and InCombatLockdown() and " [combat]" or ""
		log[#log + 1] = string.format("%.2f%s %s", GetTime(), lock, t)
		if #log > DEBUG_LOG_MAX then
			table.remove(log, 1)
		end
	end
end

local function dbg(t)
	if DB and DB.debug then
		DEFAULT_CHAT_FRAME:AddMessage(string.format("|cff888888AbsorbArc %.1f:|r %s", GetTime(), t))
		trace(t)
	end
end

-- Own sine (avoids any radians/degrees ambiguity of the WoW math library).
-- Valid for x in [-PI/2, PI].
local function sinn(x)
	if x < 0 then
		return -sinn(-x)
	end
	if x > PI / 2 then
		x = PI - x
	end
	local x2 = x * x
	return x * (1 - x2 / 6 * (1 - x2 / 20 * (1 - x2 / 42 * (1 - x2 / 72 * (1 - x2 / 110)))))
end

------------------------------------------------------------------------
-- Secret values: never compare, index or calculate with them
------------------------------------------------------------------------

local function IsSecret(v)
	if issecretvalue and issecretvalue(v) then
		return true
	end
	if issecrettable and type(v) == "table" and issecrettable(v) then
		return true
	end
	return false
end

-- v if it is a plain value, nil if it is secret
local function Plain(v)
	if IsSecret(v) then
		return nil
	end
	return v
end

-- t[k] without raising an error (t may be secret); nil on error
local function Get(t, k)
	local ok, v = pcall(function()
		return t[k]
	end)
	if ok then
		return v
	end
	return nil
end

local function GetMeta(field)
	local f = (C_AddOns and C_AddOns.GetAddOnMetadata) or GetAddOnMetadata
	if not f then
		return nil
	end
	local ok, v = pcall(f, ADDON, field)
	if ok then
		return v
	end
	return nil
end

------------------------------------------------------------------------
-- Maximum values
------------------------------------------------------------------------

-- Base value from the spell description ("absorbing 432 damage").
-- Descriptions load asynchronously, so this is filled over time.
local descBase = {}

local function CacheDescriptions()
	if not (C_Spell and C_Spell.GetSpellDescription) then
		return
	end
	for id in pairs(SHIELD_BY_ID) do
		if not descBase[id] then
			local ok, d = pcall(C_Spell.GetSpellDescription, id)
			if ok and type(d) == "string" and not IsSecret(d) and d ~= "" then
				local v = string.match(d, "[Aa]bsorb%a*%s+(%d+)")
				if v then
					descBase[id] = tonumber(v)
				end
			elseif C_Spell.RequestLoadSpellData then
				pcall(C_Spell.RequestLoadSpellData, id)
			end
		end
	end
end

-- Best known full value of a shield. mine = cast by the player (the value
-- then includes the player's spell power).
local function Positive(v)
	return type(v) == "number" and v > 0 and v or nil
end

local function KnownMax(name, spellId, mine)
	local v = nil
	if mine and spellId then
		v = Positive(DB.maxBySpell[spellId])
	elseif not mine then
		v = Positive(DB.maxForeign[name])
	end
	if v then
		return v, "learned"
	end
	if spellId then
		if not descBase[spellId] then
			CacheDescriptions() -- descriptions load in the background; try again
		end
		v = Positive(descBase[spellId])
		if v then
			return v, "description"
		end
	end
	return SHIELDS[name].fallback, "default"
end

------------------------------------------------------------------------
-- Shield state
------------------------------------------------------------------------

-- source: "aura" (exact, out of combat), "cast" (own cast in combat),
-- "inferred" (someone else's shield, seen in combat)
local function NewShield(name, spellId, source)
	local def = SHIELDS[name]
	local now = GetTime()
	return {
		name = name,
		def = def,
		spellId = spellId,
		source = source,
		gained = now,
		expires = now + def.duration,
		appliedAt = nil, -- aura's expirationTime - duration (changes on a refresh)
		max = nil,
		rem = nil, -- plain remaining absorb, nil = unknown (use the secret total)
		est = false, -- remaining value is partly estimated (shown with ~)
		hits = 0, -- Mana Shield: absorbed hits counted so far
		absorbed = 0, -- Mana Shield: estimated damage absorbed so far
		hitKeys = {}, -- Mana Shield: enemy -> absorbed hits while targeting it
		unsure = nil, -- Mana Shield: a hit may have been taken by another shield
		idx = nil, -- index of the absorb amount in the aura's points
		inst = nil,
	}
end

-- expirationTime of every buff from the last readable scan: in combat a
-- buff button that disappears at one of these times was no broken shield
local buffExpiries = {}

-- Read all shield auras. Returns name -> info, or nil when the auras can't
-- be read (in combat they are blocked for addons).
local function ScanAuras()
	if not (C_UnitAuras and C_UnitAuras.GetAuraDataByIndex) then
		return nil
	end
	local found = {}
	local expiries = {}
	for i = 1, 40 do
		local ok, aura = pcall(C_UnitAuras.GetAuraDataByIndex, "player", i, "HELPFUL")
		if (not ok) or IsSecret(aura) then
			return nil
		end
		if aura == nil then
			break
		end
		local exp = Plain(Get(aura, "expirationTime"))
		if type(exp) == "number" and exp > 0 then
			expiries[#expiries + 1] = exp
		end
		local sid = Plain(Get(aura, "spellId"))
		local name = Plain(Get(aura, "name"))
		local key = nil
		if type(sid) == "number" and SHIELD_BY_ID[sid] then
			key = SHIELD_BY_ID[sid]
		elseif type(name) == "string" and SHIELDS[name] then
			key = name
		end
		if key then
			local pts = Get(aura, "points")
			if IsSecret(pts) or type(pts) ~= "table" then
				return nil
			end
			local copy = {}
			for j = 1, #pts do
				local v = pts[j]
				if IsSecret(v) then
					return nil
				end
				copy[j] = v
			end
			local src = Plain(Get(aura, "sourceUnit"))
			found[key] = {
				spellId = (type(sid) == "number") and sid or nil,
				inst = Plain(Get(aura, "auraInstanceID")),
				points = copy,
				duration = Plain(Get(aura, "duration")),
				expires = Plain(Get(aura, "expirationTime")),
				mine = (src == "player" or src == "pet"),
			}
		end
	end
	buffExpiries = expiries
	return found
end

-- Mana Shield: every hit it absorbs is reported (UNIT_COMBAT, flag ABSORB),
-- only the amount is secret. Each such hit takes the learned damage per
-- absorbed hit off the estimate; at every break that value is learned again
-- from max / hits (see OnShieldBroke).
local HIT_DEFAULT = 24 -- first in-game test: 120 absorbed in 5 hits
local HIT_LEARN = 0.5 -- weight of the newest shield in the learned value

-- The enemy a hit is credited to: the player's target, as "name (level)".
-- UNIT_COMBAT doesn't say who hit; nil when there is no hostile target or
-- its name/level are secret.
local function EnemyKey()
	local okA, hostile = pcall(UnitCanAttack, "player", "target")
	if not okA or IsSecret(hostile) or not hostile then
		return nil
	end
	local okN, name = pcall(UnitName, "target")
	local okL, level = pcall(UnitLevel, "target")
	name, level = okN and Plain(name), okL and Plain(level)
	if type(name) ~= "string" or name == "" or type(level) ~= "number" then
		return nil
	end
	return name .. " (" .. level .. ")"
end

-- learned damage per absorbed hit: for this enemy; else the average of
-- known enemies within 2 levels; else over all shields
local LEVEL_RANGE = 2

local function DamagePerHit(key)
	local v = key and Positive(DB.hitByEnemy[key])
	if v then
		return v
	end
	local level = key and tonumber(string.match(key, "%((%-?%d+)%)$"))
	if level then
		local sum, n = 0, 0
		for k, d in pairs(DB.hitByEnemy) do
			local l = tonumber(string.match(k, "%((%-?%d+)%)$"))
			if l and math.abs(l - level) <= LEVEL_RANGE and Positive(d) then
				sum, n = sum + d, n + 1
			end
		end
		if n > 0 then
			return sum / n
		end
	end
	return Positive(DB.dmgPerAbsorbedHit) or HIT_DEFAULT
end

local function EstimateRem(st)
	local r = st.max - (st.absorbed or 0)
	local sliver = st.max * 0.05 -- the shield is still up: keep a sliver
	if r < sliver then
		r = sliver
	end
	st.rem = r
	st.est = true
end

-- Take over exact aura data. Shields not found any more are gone.
local function ApplyScan(found)
	local now = GetTime()
	for name, info in pairs(found) do
		local st = shields[name]
		local fresh = type(info.expires) == "number" and type(info.duration) == "number"
			and info.duration > 0 and info.expires - info.duration > now - 1.5
		if (not st) or st.source ~= "aura" or st.inst ~= info.inst then
			local old = st
			st = NewShield(name, info.spellId, "aura")
			st.inst = info.inst
			if old then
				st.gained = old.gained
				if not fresh then
					-- the same shield, known before from a cast in combat
					st.max, st.est = old.max, old.est
					st.hits, st.unsure = old.hits, old.unsure
					st.absorbed, st.hitKeys = old.absorbed, old.hitKeys
				end
			end
			shields[name] = st
			dbg(name .. " seen in auras (spellId " .. tostring(info.spellId) .. ", points {" .. table.concat(info.points, ",") .. "})")
		end
		if type(info.expires) == "number" and info.expires > 0 then
			st.expires = info.expires
		end
		-- recast while still up: the client may keep the auraInstanceID, but
		-- the application time moves. Start over with a full shield.
		if type(info.expires) == "number" and type(info.duration) == "number" and info.duration > 0 then
			local appliedAt = info.expires - info.duration
			if st.appliedAt and appliedAt > st.appliedAt + 0.5 then
				dbg(name .. " refreshed")
				st.est, st.savedMax, st.max = false, nil, nil
				st.hits, st.unsure, st.absorbed, st.hitKeys = 0, nil, 0, {}
			end
			st.appliedAt = appliedAt
		end
		if st.def.noAmount then
			-- Mana Shield: full value from the description, estimated from hits
			if not st.max then
				st.max = KnownMax(name, info.spellId, info.mine)
			end
			EstimateRem(st)
		else
			-- The absorb amount is the largest point when the shield is first
			-- seen (other effects like Ice Barrier's +15% are small numbers).
			if not st.idx then
				local best, bi = -1, 1
				for j, v in ipairs(info.points) do
					if type(v) == "number" and v > best then
						best, bi = v, j
					end
				end
				st.idx = bi
				st.noPoints = best <= 0
			end
			if st.noPoints then
				-- no usable value in the aura: show the secret total instead
				st.rem = nil
				if not st.max then
					st.max = KnownMax(name, info.spellId, info.mine)
				end
			else
				local rem = info.points[st.idx]
				if type(rem) ~= "number" then
					rem = 0
				end
				st.rem = rem
				if fresh and not st.savedMax and rem > 0 then
					-- just applied: this is the full value; remember it for casts in combat
					st.max = rem
					st.savedMax = true
					if info.mine and info.spellId then
						DB.maxBySpell[info.spellId] = rem
					elseif not info.mine then
						DB.maxForeign[name] = rem
					end
				elseif not st.max then
					-- joined late (e.g. /reload): best guess for the full value
					st.max = math.max(rem, (KnownMax(name, info.spellId, info.mine)))
				end
				if rem > st.max then
					st.max = rem
				end
			end
		end
	end
	for name in pairs(shields) do
		if not found[name] then
			dbg(name .. " gone (auras)")
			shields[name] = nil
		end
	end
end

-- Returns false when the auras can't be read right now.
local function Rescan()
	local found = ScanAuras()
	if not found then
		return false
	end
	ApplyScan(found)
	return true
end

-- In combat the auras can't be read, so a value read before the fight would
-- freeze. Switch those shields to the secret total until combat ends
-- (Mana Shield keeps its estimate, see SHIELDS).
local function ForgetAuraValues()
	for _, st in pairs(shields) do
		if st.rem and not st.def.noAmount then
			st.rem = nil
		end
	end
end

-- A shield known only from an event (in combat): timer from its duration,
-- remaining amount from the secret total absorb.
local function StartUnseen(name, spellId, source)
	local st = NewShield(name, spellId, source)
	local from
	st.max, from = KnownMax(name, spellId, source == "cast")
	if st.def.noAmount then
		EstimateRem(st)
		fight.casts = fight.casts + 1
	end
	shields[name] = st
	dbg(name .. " started in combat (" .. source .. ", max " .. st.max .. " from " .. from .. ")")
end

-- Per fight: Mana Shield's absorbed hits and from whom. After the fight the
-- damage meter tells exactly how much Mana Shield absorbed (in combat its
-- values are secret, afterwards plain), see LearnAfterFight.
local function NewFight()
	fight = { hits = 0, keys = {}, unsure = false, casts = 0, breaks = {} }
end

-- learn a damage-per-hit sample: overall, and per enemy if all hits came
-- while targeting the same enemy
local function LearnSample(sample, keys, what)
	local function Learn(old)
		old = Positive(old)
		return old and (old * (1 - HIT_LEARN) + sample * HIT_LEARN) or sample
	end
	DB.dmgPerAbsorbedHit = Learn(DB.dmgPerAbsorbedHit)
	local only, n = nil, 0
	for k in pairs(keys) do
		only, n = k, n + 1
	end
	if n == 1 and only ~= "?" then
		DB.hitByEnemy[only] = Learn(DB.hitByEnemy[only])
		dbg(string.format("%s: learned ~%.0f per hit from %s", what, DB.hitByEnemy[only], only))
	else
		dbg(string.format("%s (%s): learned ~%.0f per hit overall", what,
			n > 1 and "several enemies" or "unknown enemy", DB.dmgPerAbsorbedHit))
	end
end

-- A hit on the player was absorbed (UNIT_COMBAT flag ABSORB). It counts for
-- Mana Shield if Mana Shield can absorb its school and no other tracked
-- shield could have taken it instead.
local function OnAbsorbedHit(school)
	local st = shields["Mana Shield"]
	if not st then
		return
	end
	if type(school) == "number" and school ~= st.def.schools then
		trace("absorbed hit of school " .. school .. ": not Mana Shield")
		return
	end
	for name, other in pairs(shields) do
		if other ~= st and (not other.def.schools or other.def.schools == school) then
			st.unsure = true
			fight.unsure = true
			dbg("Mana Shield: absorbed hit not counted, " .. name .. " may have taken it")
			return
		end
	end
	local key = EnemyKey()
	local per = DamagePerHit(key)
	local k = key or "?"
	st.hits = (st.hits or 0) + 1
	st.absorbed = (st.absorbed or 0) + per
	st.hitKeys[k] = (st.hitKeys[k] or 0) + 1
	fight.hits = fight.hits + 1
	fight.keys[k] = (fight.keys[k] or 0) + 1
	EstimateRem(st)
	dbg(string.format("Mana Shield: absorbed hit %d from %s, ~%.0f left (~%.0f per hit)",
		st.hits, key or "unknown enemy", st.rem, per))
end

-- A Mana Shield broke: remember max / hits as a fallback sample, used only
-- if the damage meter can't be read after the fight.
local function OnShieldBroke(st)
	if not (st.def.noAmount and (st.hits or 0) > 0 and st.max) or st.unsure then
		return
	end
	table.insert(fight.breaks, { sample = st.max / st.hits, keys = st.hitKeys })
end

-- How much Mana Shield absorbed in the fight that just ended, from the
-- damage meter (plain after combat); nil if it can't be read.
local function MeterAbsorbed()
	local dm, E = C_DamageMeter, Enum
	if not (dm and dm.GetCombatSessionSourceFromType and E and E.DamageMeterSessionType and E.DamageMeterType) then
		return nil
	end
	local okG, me = pcall(UnitGUID, "player")
	local ok, src = pcall(dm.GetCombatSessionSourceFromType, E.DamageMeterSessionType.Current,
		E.DamageMeterType.Absorbs, okG and me or nil)
	if not ok or IsSecret(src) or type(src) ~= "table" then
		return nil
	end
	local spells = Get(src, "combatSpells")
	if IsSecret(spells) or type(spells) ~= "table" then
		return nil
	end
	local total = 0
	for i = 1, #spells do
		local id, amount = Plain(Get(spells[i], "spellID")), Plain(Get(spells[i], "totalAmount"))
		if type(id) == "number" and SHIELD_BY_ID[id] == "Mana Shield" then
			if type(amount) ~= "number" then
				return nil
			end
			total = total + amount
		end
	end
	return total
end

-- After a fight: learn from the exact absorbed amount (meter) divided by the
-- counted absorbed hits. A Mana Shield that survived the fight (and was the
-- only one in it) gets its exact absorbed amount.
local function LearnAfterFight()
	local absorbed = MeterAbsorbed()
	trace("fight over: " .. fight.hits .. " absorbed hits counted, meter says Mana Shield absorbed " .. tostring(absorbed))
	if absorbed and absorbed > 0 and fight.hits > 0 and not fight.unsure then
		LearnSample(absorbed / fight.hits, fight.keys,
			string.format("Mana Shield absorbed %d in %d hits", absorbed, fight.hits))
		local st = shields["Mana Shield"]
		if st and #fight.breaks == 0 and fight.casts <= 1 then
			st.absorbed = absorbed
			EstimateRem(st)
			dbg(string.format("Mana Shield after the fight: %d absorbed, ~%.0f left", absorbed, st.rem))
		end
	elseif not absorbed then
		for _, b in ipairs(fight.breaks) do
			LearnSample(b.sample, b.keys, "Mana Shield broke (no meter data)")
		end
	end
	NewFight()
end

-- Shields sorted by gain time (oldest first)
local function ActiveList()
	local list = {}
	for _, st in pairs(shields) do
		table.insert(list, st)
	end
	table.sort(list, function(a, b)
		return a.gained < b.gained
	end)
	return list
end

local function ExpireShields(now)
	for name, st in pairs(shields) do
		if st.expires and now > st.expires + 0.3 then
			dbg(name .. " expired")
			shields[name] = nil
		end
	end
end

------------------------------------------------------------------------
-- Combat: casts and inference
------------------------------------------------------------------------

local sentTarget = {} -- castGUID -> target name from UNIT_SPELLCAST_SENT
local buffCount = nil -- visible buttons on Blizzard's buff bar
local countUpAt, countDownAt, absorbAt, ownCastAt, anyCastAt = nil, nil, nil, nil, nil
local ownPwsOther = nil -- { t, spellId } of an own PW:S cast that seemed to go to someone else
local handledUp = 0 -- countUpAt that was already used

-- Blizzard's buff buttons keep a readable IsShown in combat, even when
-- their content is secret.
local function BlizzBuffCount()
	local frames = BuffFrame and BuffFrame.auraFrames
	if type(frames) ~= "table" then
		return nil
	end
	local n = 0
	for _, b in ipairs(frames) do
		local ok, s = pcall(b.IsShown, b)
		if ok and (not IsSecret(s)) and s then
			n = n + 1
		end
	end
	return n
end

local function UpdateBuffCount(now)
	local c = BlizzBuffCount()
	if not c then
		return
	end
	if buffCount and c ~= buffCount then
		trace("Blizzard buff buttons " .. buffCount .. " -> " .. c)
	end
	if buffCount and c > buffCount then
		countUpAt = now
	elseif buffCount and c < buffCount then
		countDownAt = now
	end
	buffCount = c
end

-- Someone else's shield: the absorb amount changed and Blizzard's buff bar
-- gained a button at the same moment, without an own shield cast. Each
-- new button is used once.
-- A broken shield is not detected this way: absorb changes happen on every
-- hit, so a buff that ends during a fight would look the same. A broken
-- shield's bar vanishes anyway (its alpha is the secret total), and its
-- timer or the next rescan out of combat removes it.
local function CheckInference(now)
	if not (absorbAt and countUpAt) or countUpAt <= handledUp then
		return
	end
	if math.abs(absorbAt - countUpAt) > INFER_WINDOW then
		if now - countUpAt > INFER_WINDOW then
			handledUp = countUpAt -- no absorb change came with this buff
		end
		return
	end
	handledUp = countUpAt
	if ownCastAt and now - ownCastAt < 1.5 then
		dbg("buff + absorb change right after own shield cast: nothing to infer")
	elseif ownPwsOther and now - ownPwsOther.t < 2 then
		-- the own PW:S that seemed to target someone else landed on us
		dbg(PWS .. ": the own cast landed on you after all")
		StartUnseen(PWS, ownPwsOther.spellId, "cast")
		ownPwsOther = nil
	else
		StartUnseen(PWS, nil, "inferred")
	end
end

------------------------------------------------------------------------
-- Broken shields in combat
------------------------------------------------------------------------

-- In combat a shield that breaks can't be seen in the auras. But Blizzard's
-- buff bar loses a button at that moment. If none of the buffs known from
-- before the fight (or a tracked shield's timer) runs out right then, and no
-- own spell was cast (which may use up a buff like Clearcasting), a shield
-- broke. Shields counted in the total absorb come with an absorb change;
-- Mana Shield (not counted there) without one.
local BREAK_EXPIRY_SLACK = 1.5
local handledDown = 0 -- countDownAt that was already used

local function KnownExpiryNear(t)
	for _, exp in ipairs(buffExpiries) do
		if math.abs(exp - t) <= BREAK_EXPIRY_SLACK then
			return true
		end
	end
	for _, st in pairs(shields) do
		if st.expires and math.abs(st.expires - t) <= BREAK_EXPIRY_SLACK then
			return true
		end
	end
	return false
end

local function CheckBreak(now)
	if not countDownAt or countDownAt <= handledDown or now - countDownAt < INFER_WINDOW then
		return -- wait a moment: the absorb change may come right after
	end
	local t = countDownAt
	handledDown = t
	if KnownExpiryNear(t) then
		trace("buff button gone: a known buff or shield ran out")
		return
	end
	if anyCastAt and math.abs(anyCastAt - t) <= 0.5 then
		trace("buff button gone right after an own cast: not a shield")
		return
	end
	local list = ActiveList()
	local withAbsorb = absorbAt and math.abs(absorbAt - t) <= INFER_WINDOW
	local pick = {}
	for _, st in ipairs(list) do
		if (st.def.noAmount and not withAbsorb) or (withAbsorb and not st.def.noAmount) then
			pick[#pick + 1] = st
		end
	end
	if #list == 1 then
		pick = list
	end
	if #pick == 1 then
		dbg(pick[1].name .. " broke (buff button gone" .. (withAbsorb and ", absorb changed" or "") .. ")")
		OnShieldBroke(pick[1])
		shields[pick[1].name] = nil
	else
		trace("buff button gone, but can't tell which of " .. #list .. " shields broke")
	end
end

-- Only Power Word: Shield can be cast on someone else: remember its target
-- until the cast succeeds.
local function OnCastSent(unit, target, guid, spellID)
	local sid = Plain(spellID)
	if unit == "player" and type(sid) == "number" and SHIELD_BY_ID[sid] == PWS and guid and not IsSecret(guid) then
		sentTarget[guid] = target
	end
end

local function OnCastSucceeded(unit, guid, spellID)
	local sid = Plain(spellID)
	if type(sid) ~= "number" then
		return
	end
	if unit == "player" then
		anyCastAt = GetTime() -- a cast may use up a buff (see CheckBreak)
		trace("cast " .. sid)
	end
	if not SHIELD_BY_ID[sid] then
		return
	end
	local name = SHIELD_BY_ID[sid]
	if unit == "player" and name == PWS and guid and not IsSecret(guid) then
		local tgt = sentTarget[guid]
		sentTarget[guid] = nil
		local me = UnitName("player")
		local function Base(n)
			return type(n) == "string" and string.match(n, "^([^%-]+)") or n
		end
		if type(tgt) == "string" and (not IsSecret(tgt)) and tgt ~= "" and Base(tgt) ~= Base(me) then
			dbg(PWS .. " cast on " .. tgt .. ", not on you")
			ownPwsOther = { t = GetTime(), spellId = sid }
			return
		end
	end
	ownCastAt = GetTime()
	if Rescan() then
		return -- out of combat the aura shows up with exact data
	end
	StartUnseen(name, sid, "cast")
end

------------------------------------------------------------------------
-- Display
------------------------------------------------------------------------

local function BarPoint(k, u)
	-- local frame: first bar's middle point at the origin, bars run along y and
	-- bend towards +x (towards the character); bar k lies k pitches further out
	local theta = geo.theta
	if theta < 0.005 then
		return -k * geo.p, (0.5 - u) * geo.L
	end
	local r0 = geo.L / theta
	local R = r0 + k * geo.p
	local phi = (u - 0.5) * theta
	local sg = 1
	local ap = phi
	if phi < 0 then
		sg = -1
		ap = -phi
	end
	return r0 - R * sinn(PI / 2 - ap), -R * sg * sinn(ap)
end

local function ToScreen(lx, ly)
	local side = geo.side
	if side == "right" then
		return -lx, ly
	elseif side == "top" then
		return -ly, -lx
	elseif side == "bottom" then
		return -ly, lx
	end
	return lx, ly
end

local function FontSize()
	local fs = math.floor(16 * geo.sc + 0.5)
	if fs < 8 then
		fs = 8
	end
	return fs
end

-- Each dot of a bar is a StatusBar covering one slice of the bar's range.
-- Fed with the same value (plain or secret), the dots together draw the
-- fill level without the addon ever comparing the value.
local function SetRanges(b, max)
	if max < 1 then
		max = 1
	end
	for i = 1, N do
		local j
		if DB.anchor == "top" then
			j = i
		else
			j = N - i + 1
		end
		b.fg[i]:SetMinMaxValues((j - 1) * max / N, j * max / N)
	end
	b.lastMax = max
	b.lastAnchor = DB.anchor
end

local function SetBarValue(b, v)
	for i = 1, N do
		b.fg[i]:SetValue(v)
	end
end

-- Opacity applies to every region on its own, so where two semi-transparent
-- dots overlap the color gets stronger and the bar looks like a string of
-- beads. The colored dots and the dark track are therefore each rendered
-- into an offscreen buffer and get their opacity once, as a whole. Without
-- that API (or with /aa smooth off) the old way is used.
local function ApplySmooth(b)
	local on = (DB.smooth and b.frame.SetIsFrameBuffer) and true or false
	if b.smooth == on then
		return
	end
	local ok = pcall(b.frame.SetIsFrameBuffer, b.frame, on)
	ok = ok and pcall(b.bgframe.SetIsFrameBuffer, b.bgframe, on)
	if not ok then
		pcall(b.frame.SetIsFrameBuffer, b.frame, false)
		pcall(b.bgframe.SetIsFrameBuffer, b.bgframe, false)
		on = false
	end
	b.smooth = on
	b.alpha = nil -- ApplyAlpha must run again
end

-- Smooth: the track's dots are opaque inside their buffer, which gets the
-- background opacity. Otherwise every track dot carries it itself.
local function ApplyAlpha(b)
	b.frame:SetAlpha(DB.alpha)
	b.tframe:SetAlpha(DB.alpha)
	local va
	if b.smooth then
		b.bgframe:SetAlpha(DB.alpha * DB.bgalpha)
		va = 1
	else
		b.bgframe:SetAlpha(DB.alpha)
		va = DB.bgalpha
	end
	for i = 1, N do
		b.bg[i]:SetVertexColor(0, 0, 0, va)
	end
	b.alpha, b.bgalpha = DB.alpha, DB.bgalpha
end

local function LayoutBar(k)
	local b = bars[k]
	local minx, maxx, miny, maxy = 1000000, -1000000, 1000000, -1000000
	for i = 1, N do
		local lx, ly = BarPoint(k, (i - 0.5) / N)
		local x, y = ToScreen(lx, ly)
		local bg = b.bg[i]
		bg:SetTexture(geo.tex)
		bg:ClearAllPoints()
		bg:SetPoint("CENTER", arc, "CENTER", x, y)
		local bgs = (geo.size + 4 * geo.sc) * geo.quad
		bg:SetSize(bgs, bgs)
		local fg = b.fg[i]
		fg:SetStatusBarTexture(geo.tex)
		fg:ClearAllPoints()
		fg:SetPoint("CENTER", arc, "CENTER", x, y)
		fg:SetSize(geo.size * geo.quad, geo.size * geo.quad)
		minx, maxx = math.min(minx, x), math.max(maxx, x)
		miny, maxy = math.min(miny, y), math.max(maxy, y)
	end
	-- the frame must cover the whole bar: an offscreen buffer only holds
	-- what lies inside the frame
	local pad = (geo.size + 4 * geo.sc) * geo.quad / 2 + 2
	for _, fr in ipairs({ b.frame, b.bgframe }) do
		fr:ClearAllPoints()
		fr:SetPoint("CENTER", arc, "CENTER", (minx + maxx) / 2, (miny + maxy) / 2)
		fr:SetSize(maxx - minx + 2 * pad, maxy - miny + 2 * pad)
	end
	b.text:SetFont("Fonts\\FRIZQT__.TTF", FontSize(), "OUTLINE")
	ApplySmooth(b)
	ApplyAlpha(b)
	b.lastDrawn = -1
	b.lr = -1
	b.lastMax = nil
end

local function EnsureBar(k)
	local b = bars[k]
	if b then
		return b
	end
	b = { bg = {}, fg = {}, shown = nil, lastDrawn = -1, lr = -1, lg = -1, lb = -1, cur = nil }
	-- bgframe (dark track) below frame (colored dots); both sized to the bar
	-- (see LayoutBar) and carrying the opacity. bginner/inner: 1, or the
	-- secret total absorb in combat (alpha is clamped to 0..1, so the bar
	-- vanishes when no absorb is left)
	b.bgframe = CreateFrame("Frame", nil, arc)
	b.bgframe:SetFrameLevel(arc:GetFrameLevel() + 1)
	b.bginner = CreateFrame("Frame", nil, b.bgframe)
	b.bginner:SetAllPoints(b.bgframe)
	b.frame = CreateFrame("Frame", nil, arc)
	b.frame:SetFrameLevel(arc:GetFrameLevel() + 3)
	b.inner = CreateFrame("Frame", nil, b.frame)
	b.inner:SetAllPoints(b.frame)
	for i = 1, N do
		b.bg[i] = b.bginner:CreateTexture(nil, "BACKGROUND")
		local fg = CreateFrame("StatusBar", nil, b.inner)
		fg:SetFrameLevel(b.inner:GetFrameLevel() + 1)
		b.fg[i] = fg
	end
	-- the text sits outside the bar, so it gets its own frames (same roles)
	b.tframe = CreateFrame("Frame", nil, arc)
	b.tframe:SetSize(1, 1)
	b.tframe:SetPoint("CENTER", arc, "CENTER", 0, 0)
	b.tinner = CreateFrame("Frame", nil, b.tframe)
	b.tinner:SetAllPoints(b.tframe)
	b.text = b.tinner:CreateFontString(nil, "OVERLAY")
	bars[k] = b
	LayoutBar(k)
	return b
end

-- one text line per bar, outside the outermost bar
local function PlaceTexts(n)
	local fs = FontSize()
	local lh = fs + 2
	local out = geo.size / 2 + 6 * geo.sc
	local base = (n - 1) * geo.p + out
	for k = 0, n - 1 do
		local b = bars[k]
		if b then
			b.text:ClearAllPoints()
			if geo.side == "right" then
				b.text:SetJustifyH("LEFT")
				b.text:SetPoint("LEFT", arc, "CENTER", base, ((n - 1) / 2 - k) * lh)
			elseif geo.side == "top" then
				b.text:SetJustifyH("CENTER")
				b.text:SetPoint("BOTTOM", arc, "CENTER", 0, base + (n - 1 - k) * lh)
			elseif geo.side == "bottom" then
				b.text:SetJustifyH("CENTER")
				b.text:SetPoint("TOP", arc, "CENTER", 0, -(base + (n - 1 - k) * lh))
			else
				b.text:SetJustifyH("RIGHT")
				b.text:SetPoint("RIGHT", arc, "CENTER", -base, ((n - 1) / 2 - k) * lh)
			end
		end
	end
end

local function Build()
	mover = CreateFrame("Frame", "AbsorbArcMover", UIParent)
	mover:SetFrameStrata("HIGH")
	mover:SetMovable(true)
	mover:EnableMouse(false)
	mover:RegisterForDrag("LeftButton")
	mover.tex = mover:CreateTexture(nil, "BACKGROUND")
	mover.tex:SetAllPoints(mover)
	mover.tex:SetColorTexture(0, 1, 0, 0.22)
	mover.label = mover:CreateFontString(nil, "OVERLAY", "GameFontNormal")
	mover.label:SetPoint("CENTER", mover, "CENTER", 0, 0)
	mover.label:SetText("drag")
	mover:Hide()

	arc = CreateFrame("Frame", "AbsorbArcFrame", UIParent)
	arc:SetSize(1, 1)
	arc:SetFrameStrata("MEDIUM")
	arc:EnableMouse(false)
end

local function Layout()
	local sc = DB.scale
	geo.sc = sc
	geo.L = DB.length * sc
	geo.size = DB.size * sc
	geo.theta = DB.curve / 100 * PI
	geo.side = DB.side
	geo.p = geo.size + 6 * sc
	if DB.style == "square" then
		geo.tex = "Interface\\Buttons\\WHITE8X8"
		geo.quad = 1
	else
		geo.tex = ADDON_PATH .. "dot_smooth"
		geo.quad = DOT_QUAD
	end

	-- bounding box of the first and the last preview bar (for the drag area)
	local minx, maxx, miny, maxy = 1000000, -1000000, 1000000, -1000000
	for pass = 1, 2 do
		local k = 0
		if pass == 2 then
			k = PREVIEW_BARS - 1
		end
		for i = 1, N do
			local lx, ly = BarPoint(k, (i - 0.5) / N)
			local x, y = ToScreen(lx, ly)
			if x < minx then
				minx = x
			end
			if x > maxx then
				maxx = x
			end
			if y < miny then
				miny = y
			end
			if y > maxy then
				maxy = y
			end
		end
	end
	local pad = geo.size / 2 + 6
	minx = minx - pad
	maxx = maxx + pad
	miny = miny - pad
	maxy = maxy + pad
	barCX = (minx + maxx) / 2
	barCY = (miny + maxy) / 2

	mover:ClearAllPoints()
	mover:SetPoint("CENTER", UIParent, "CENTER", DB.x + barCX, DB.y + barCY)
	mover:SetSize(math.max(maxx - minx, 30), math.max(maxy - miny, 30))

	arc:ClearAllPoints()
	arc:SetPoint("CENTER", mover, "CENTER", -barCX, -barCY)
	arc:SetAlpha(1)

	for k in pairs(bars) do
		LayoutBar(k)
	end
	lastN = -1
end

local function ResetPos()
	-- put the first bar where a full half circle would be centered on the
	-- screen center (i.e. around the character)
	local d = DB.length / PI * DB.scale
	local side = DB.side
	if side == "right" then
		DB.x, DB.y = d, 0
	elseif side == "top" then
		DB.x, DB.y = 0, d
	elseif side == "bottom" then
		DB.x, DB.y = 0, -d
	else
		DB.x, DB.y = -d, 0
	end
	DB.x = math.floor(DB.x + 0.5)
	DB.y = math.floor(DB.y + 0.5)
	Layout()
end

local function IsPreview()
	return unlocked or (cfg and cfg:IsShown())
end

-- What to draw right now: one entry per bar.
--   value  = plain remaining absorb, or the secret total absorb (secret = true)
--   max    = plain full value (range of the bar)
local function BuildEntries(now)
	local entries = {}
	if test then
		local p = (now - test.start) / test.dur
		if p >= 1 then
			test = nil
		else
			for k = 1, 3 do
				local frac = 1 - p * (0.5 + 0.25 * k)
				table.insert(entries, {
					key = testKeys[k],
					def = SHIELDS[SHIELD_ORDER[k]],
					value = 1000 * frac,
					max = 1000,
					left = test.dur * (1 - p),
				})
			end
			return entries
		end
	end
	local list = ActiveList()
	local unknown = 0
	for i = 1, #list do
		if not list[i].rem then
			unknown = unknown + 1
		end
	end
	local total = nil
	if unknown > 0 then
		local ok, t = pcall(UnitGetTotalAbsorbs, "player")
		if ok then
			total = t
		else
			total = 0
		end
	end
	for i = 1, #list do
		local st = list[i]
		local e = {
			key = st,
			def = st.def,
			max = st.max or st.def.fallback,
			left = st.expires and (st.expires - now) or nil,
		}
		if st.rem then
			e.value = st.rem
			e.est = st.est
		else
			e.value = total
			e.secret = true
			-- several shields share one total: each bar shows the total
			e.est = #list > 1
		end
		-- a shield counted down to 0 (Mana Shield) is used up: no bar
		if e.secret or e.value > 0 then
			table.insert(entries, e)
		end
	end
	if #entries == 0 and IsPreview() then
		local fr = { 0.75, 0.5, 0.9 }
		for k = 1, 3 do
			table.insert(entries, {
				key = previewKeys[k],
				def = SHIELDS[SHIELD_ORDER[k]],
				value = 1000 * fr[k],
				max = 1000,
				left = 30,
			})
		end
	end
	return entries
end

local function ColorPrefix(r, g, bl)
	return string.format("|cff%02x%02x%02x", math.floor(r * 255 + 0.5), math.floor(g * 255 + 0.5), math.floor(bl * 255 + 0.5))
end

local function Render(elapsed)
	if not arc then
		return
	end
	local now = GetTime()
	local entries = BuildEntries(now)
	local n = #entries
	if n == 0 then
		for _, b in pairs(bars) do
			b.cur = nil
		end
		arc:Hide()
		return
	end
	arc:Show()
	for k = 0, n - 1 do
		EnsureBar(k)
	end
	if n ~= lastN then
		PlaceTexts(n)
		lastN = n
	end

	for k, b in pairs(bars) do
		if k >= n then
			b.cur = nil
			b.frame:Hide()
			b.bgframe:Hide()
			b.tframe:Hide()
		end
	end

	for k = 0, n - 1 do
		local e = entries[k + 1]
		local b = bars[k]
		if b.alpha ~= DB.alpha or b.bgalpha ~= DB.bgalpha then
			ApplyAlpha(b)
		end
		b.frame:Show()
		b.bgframe:Show()
		b.tframe:Show()
		local newKey = b.cur ~= e.key
		b.cur = e.key

		local c = e.def.color
		local r, g, bl = c[1], c[2], c[3]
		if r ~= b.lr or g ~= b.lg or bl ~= b.lb then
			for i = 1, N do
				b.fg[i]:SetStatusBarColor(r, g, bl, 1)
			end
			b.lr, b.lg, b.lb = r, g, bl
		end
		if b.lastMax ~= e.max or b.lastAnchor ~= DB.anchor then
			SetRanges(b, e.max)
			b.lastDrawn = -1
			b.lastSecret = nil
		end
		local left = e.left
		if left and left < 0 then
			left = 0
		end

		if e.secret then
			-- secret total: no animation, redraw at a fixed rate
			if newKey or (not b.secretMode) or (not b.lastSecret) or now - b.lastSecret >= SECRET_REDRAW then
				b.lastSecret = now
				b.secretMode = true
				b.shown = nil
				pcall(SetBarValue, b, e.value)
				pcall(b.inner.SetAlpha, b.inner, e.value)
				pcall(b.bginner.SetAlpha, b.bginner, e.value)
				pcall(b.tinner.SetAlpha, b.tinner, e.value)
				if DB.text then
					local fmt = ColorPrefix(r, g, bl) .. (e.est and "~" or "") .. "%d|r"
					local ok
					if left then
						ok = pcall(b.text.SetFormattedText, b.text, fmt .. " |cffcccccc%ds|r", e.value, math.floor(left + 0.5))
					else
						ok = pcall(b.text.SetFormattedText, b.text, fmt, e.value)
					end
					if not ok then
						pcall(b.text.SetText, b.text, e.value)
					end
					b.text:Show()
				else
					b.text:Hide()
				end
			end
		else
			if b.secretMode then
				b.secretMode = false
				b.inner:SetAlpha(1)
				b.bginner:SetAlpha(1)
				b.tinner:SetAlpha(1)
				b.lastDrawn = -1
			end
			local target = e.value / e.max
			if target > 1 then
				target = 1
			elseif target < 0 then
				target = 0
			end
			if newKey or not b.shown then
				b.shown = target
			end
			b.shown = b.shown + (target - b.shown) * math.min(1, elapsed * 8)
			if math.abs(b.shown - b.lastDrawn) > 0.002 then
				SetBarValue(b, b.shown * e.max)
				b.lastDrawn = b.shown
			end
			if DB.text then
				local txt = ColorPrefix(r, g, bl) .. (e.est and "~" or "") .. math.floor(e.value + 0.5) .. "|r"
				if left and left > 0 then
					txt = txt .. " |cffcccccc" .. math.floor(left + 0.5) .. "s|r"
				end
				b.text:SetText(txt)
				b.text:Show()
			else
				b.text:Hide()
			end
		end
	end
end

------------------------------------------------------------------------
-- Config UI
------------------------------------------------------------------------

local sliders = {}
local checks = {}
local sideButtons = {}
local updating = false

local SIDE_LABELS = { left = "Left", right = "Right", top = "Top", bottom = "Bottom" }

-- child region of a template, by parentKey or by global name
local function Region(f, key)
	local r = f[key]
	if r then
		return r
	end
	local name = f:GetName()
	if name then
		return _G[name .. key]
	end
	return nil
end

local function SliderText(s)
	local v = s:GetValue()
	if s.step >= 1 then
		v = math.floor(v + 0.5)
	end
	local t = Region(s, "Text")
	if t then
		t:SetText(s.label .. ": " .. string.format(s.fmt, v))
	end
end

local function RefreshChecks()
	for i = 1, #checks do
		local c = checks[i]
		c:SetChecked(c.getter() and true or false)
	end
end

local function RefreshConfig()
	if not cfg then
		return
	end
	updating = true
	for key, s in pairs(sliders) do
		s:SetValue(DB[key])
		SliderText(s)
	end
	updating = false
	RefreshChecks()
	for key, b in pairs(sideButtons) do
		if DB.side == key then
			b:SetText("|cff00ff00" .. SIDE_LABELS[key] .. "|r")
		else
			b:SetText(SIDE_LABELS[key])
		end
	end
end

local function SetUnlocked(v)
	unlocked = v
	if mover then
		mover:EnableMouse(v)
		if v then
			mover:Show()
		else
			mover:Hide()
		end
	end
	RefreshConfig()
end

local function MakeSlider(key, label, minv, maxv, step, fmt, y)
	local name = "AbsorbArcSlider" .. key
	local s = CreateFrame("Slider", name, cfg, "OptionsSliderTemplate")
	s:SetSize(220, 16)
	s:SetPoint("TOP", cfg, "TOP", 0, y)
	s:SetMinMaxValues(minv, maxv)
	s:SetValueStep(step)
	if s.SetObeyStepOnDrag then
		s:SetObeyStepOnDrag(true)
	end
	local low, high = Region(s, "Low"), Region(s, "High")
	if low then
		low:SetText(tostring(minv))
	end
	if high then
		high:SetText(tostring(maxv))
	end
	s.key = key
	s.label = label
	s.fmt = fmt
	s.step = step
	s:SetScript("OnValueChanged", function(self)
		SliderText(self)
		if updating then
			return
		end
		local v = self:GetValue()
		if self.step >= 1 then
			v = math.floor(v + 0.5)
		end
		DB[self.key] = v
		Layout()
	end)
	sliders[key] = s
end

local function MakeCheck(name, label, y, getter, setter)
	local c = CreateFrame("CheckButton", name, cfg, "UICheckButtonTemplate")
	c:SetPoint("TOPLEFT", cfg, "TOPLEFT", 24, y)
	local t = Region(c, "text") or Region(c, "Text")
	if t then
		t:SetText(label)
	end
	c.getter = getter
	c.setter = setter
	c:SetScript("OnClick", function(self)
		self.setter(self:GetChecked() and true or false)
		lastN = -1
		for _, b in pairs(bars) do
			b.lastDrawn = -1
			b.lastSecret = nil
		end
	end)
	table.insert(checks, c)
end

local function MakeButton(label, x, onclick)
	local b = CreateFrame("Button", nil, cfg, "UIPanelButtonTemplate")
	b:SetSize(78, 22)
	b:SetPoint("BOTTOMLEFT", cfg, "BOTTOMLEFT", x, 20)
	b:SetText(label)
	b:SetScript("OnClick", onclick)
end

local function MakeSideButton(key, x)
	local b = CreateFrame("Button", nil, cfg, "UIPanelButtonTemplate")
	b:SetSize(58, 22)
	b:SetPoint("TOPLEFT", cfg, "TOPLEFT", x, -322)
	b.key = key
	b:SetText(SIDE_LABELS[key])
	b:SetScript("OnClick", function(self)
		DB.side = self.key
		Layout()
		RefreshConfig()
	end)
	sideButtons[key] = b
end

local function BuildConfig()
	cfg = CreateFrame("Frame", "AbsorbArcConfig", UIParent, "BackdropTemplate")
	cfg:SetSize(290, 490)
	cfg:SetPoint("CENTER", UIParent, "CENTER", 320, 0)
	cfg:SetFrameStrata("MEDIUM")
	cfg:SetMovable(true)
	cfg:EnableMouse(true)
	cfg:RegisterForDrag("LeftButton")
	cfg:SetScript("OnDragStart", function(self)
		self:StartMoving()
	end)
	cfg:SetScript("OnDragStop", function(self)
		self:StopMovingOrSizing()
	end)
	cfg:SetBackdrop({
		bgFile = "Interface\\DialogFrame\\UI-DialogBox-Background",
		edgeFile = "Interface\\DialogFrame\\UI-DialogBox-Border",
		tile = true,
		tileSize = 32,
		edgeSize = 32,
		insets = { left = 11, right = 12, top = 12, bottom = 11 },
	})

	local title = cfg:CreateFontString(nil, "OVERLAY", "GameFontNormal")
	title:SetPoint("TOP", cfg, "TOP", 0, -18)
	title:SetText("AbsorbArc")

	local close = CreateFrame("Button", nil, cfg, "UIPanelCloseButton")
	close:SetPoint("TOPRIGHT", cfg, "TOPRIGHT", -6, -6)

	MakeSlider("scale", "Size", 0.3, 3, 0.05, "%.2f", -62)
	MakeSlider("size", "Thickness", 4, 40, 1, "%d", -105)
	MakeSlider("length", "Length", 100, 1400, 10, "%d", -148)
	MakeSlider("curve", "Curvature", 0, 100, 1, "%d%%", -191)
	MakeSlider("alpha", "Opacity", 0.1, 1, 0.05, "%.2f", -234)
	MakeSlider("bgalpha", "Background opacity", 0, 1, 0.05, "%.2f", -277)

	local sl = cfg:CreateFontString(nil, "OVERLAY", "GameFontNormalSmall")
	sl:SetPoint("TOPLEFT", cfg, "TOPLEFT", 28, -298)
	sl:SetText("Side of the character")
	sl:SetJustifyH("LEFT")
	MakeSideButton("left", 24)
	MakeSideButton("right", 86)
	MakeSideButton("top", 148)
	MakeSideButton("bottom", 210)

	MakeCheck("AbsorbArcCheckUnlock", "Unlock (drag the green area)", -352,
		function() return unlocked end,
		function(v) SetUnlocked(v) end)
	MakeCheck("AbsorbArcCheckText", "Show numbers and timers", -380,
		function() return DB.text end,
		function(v) DB.text = v end)
	MakeCheck("AbsorbArcCheckAnchor", "Shrink from the top/left end", -408,
		function() return DB.anchor == "bottom" end,
		function(v)
			if v then
				DB.anchor = "bottom"
			else
				DB.anchor = "top"
			end
		end)

	MakeButton("Test", 22, function()
		test = { start = GetTime(), dur = 12 }
	end)
	MakeButton("Reset pos", 106, function()
		ResetPos()
	end)
	MakeButton("Close", 190, function()
		cfg:Hide()
	end)

	cfg:SetScript("OnHide", function()
		SetUnlocked(false)
	end)
	table.insert(UISpecialFrames, "AbsorbArcConfig")
	cfg:Hide()
end

local function ToggleConfig()
	if not cfg then
		BuildConfig()
	end
	if cfg:IsShown() then
		cfg:Hide()
	else
		RefreshConfig()
		cfg:Show()
	end
end

------------------------------------------------------------------------
-- Setup, events, slash commands
------------------------------------------------------------------------

local function Init()
	if type(AbsorbArcCharDB) ~= "table" then
		AbsorbArcCharDB = {}
	end
	DB = AbsorbArcCharDB
	for k, v in pairs(DEFAULTS) do
		if DB[k] == nil then
			DB[k] = v
		end
	end
	if type(DB.maxBySpell) ~= "table" then
		DB.maxBySpell = {}
	end
	if type(DB.maxForeign) ~= "table" then
		DB.maxForeign = {}
	end
	if type(DB.hitByEnemy) ~= "table" then
		DB.hitByEnemy = {} -- "name (level)" -> damage per absorbed hit
	end
	Build()
	mover:SetScript("OnDragStart", function(self)
		self:StartMoving()
	end)
	mover:SetScript("OnDragStop", function(self)
		self:StopMovingOrSizing()
		local mx, my = self:GetCenter()
		local ux, uy = UIParent:GetCenter()
		DB.x = math.floor(mx - ux - barCX + 0.5)
		DB.y = math.floor(my - uy - barCY + 0.5)
		Layout()
	end)
	Layout()
	arc:Hide()
end

-- no parent: keeps tracking while the UI is hidden (Alt+Z)
local f = CreateFrame("Frame", "AbsorbArcEventFrame")
f:RegisterEvent("ADDON_LOADED")
f:RegisterEvent("PLAYER_LOGIN")
f:RegisterEvent("PLAYER_ENTERING_WORLD")
f:RegisterEvent("PLAYER_REGEN_DISABLED")
f:RegisterEvent("PLAYER_REGEN_ENABLED")
f:RegisterEvent("SPELLS_CHANGED")
f:RegisterUnitEvent("UNIT_AURA", "player")
pcall(f.RegisterUnitEvent, f, "UNIT_ABSORB_AMOUNT_CHANGED", "player")
f:RegisterUnitEvent("UNIT_SPELLCAST_SENT", "player")
f:RegisterUnitEvent("UNIT_SPELLCAST_SUCCEEDED", "player", "pet") -- pet: Sacrifice
-- hits on the player (combat text): the amount is secret, but absorbed hits
-- are flagged, which drives the Mana Shield estimate (OnAbsorbedHit)
pcall(f.RegisterUnitEvent, f, "UNIT_COMBAT", "player")

local function Describe(v)
	if IsSecret(v) then
		return "<secret>"
	end
	return tostring(v)
end

f:SetScript("OnEvent", function(self, event, a1, a2, a3, a4, a5)
	if event == "ADDON_LOADED" then
		if a1 == ADDON then
			Init()
		end
		return
	end
	if not DB then
		return
	end
	if event == "PLAYER_LOGIN" then
		CacheDescriptions()
		if C_Timer and C_Timer.After then
			C_Timer.After(5, CacheDescriptions)
		end
		say("v" .. tostring(GetMeta("Version")) .. " loaded - /aa for config")
	elseif event == "PLAYER_ENTERING_WORLD" or event == "PLAYER_REGEN_ENABLED" then
		Rescan()
		buffCount = BlizzBuffCount()
		if event == "PLAYER_REGEN_ENABLED" and C_Timer and C_Timer.After then
			C_Timer.After(0.5, LearnAfterFight) -- let the meter finish the fight
		end
	elseif event == "PLAYER_REGEN_DISABLED" then
		buffCount = BlizzBuffCount()
		NewFight()
	elseif event == "SPELLS_CHANGED" then
		CacheDescriptions()
	elseif event == "UNIT_AURA" then
		trace("event UNIT_AURA")
		Rescan()
	elseif event == "UNIT_ABSORB_AMOUNT_CHANGED" then
		trace("event UNIT_ABSORB_AMOUNT_CHANGED")
		absorbAt = GetTime()
		Rescan()
	elseif event == "UNIT_SPELLCAST_SENT" then
		OnCastSent(a1, a2, a3, a4)
	elseif event == "UNIT_COMBAT" then
		trace("UNIT_COMBAT action=" .. Describe(a2) .. " flag=" .. Describe(a3)
			.. " amount=" .. Describe(a4) .. " school=" .. Describe(a5)
			.. (shields["Mana Shield"] and " (Mana Shield up)" or ""))
		if Plain(a3) == "ABSORB" or Plain(a2) == "ABSORB" then
			OnAbsorbedHit(Plain(a5))
		end
	elseif event == "UNIT_SPELLCAST_SUCCEEDED" then
		OnCastSucceeded(a1, a2, a3)
	end
end)

local tickAcc, descTry = 0, 0
f:SetScript("OnUpdate", function(self, elapsed)
	if not DB then
		return
	end
	elapsed = elapsed or 0
	tickAcc = tickAcc + elapsed
	local locked = InCombatLockdown()
	if tickAcc >= (locked and COMBAT_TICK or IDLE_TICK) then
		tickAcc = 0
		local now = GetTime()
		if locked then
			ForgetAuraValues()
			UpdateBuffCount(now)
			CheckInference(now)
			CheckBreak(now)
			ExpireShields(now)
		else
			if next(shields) and not Rescan() then
				ForgetAuraValues()
				ExpireShields(now)
			end
			if now - descTry > 10 then
				descTry = now
				CacheDescriptions() -- fills in descriptions that weren't loaded yet
			end
		end
	end
	Render(elapsed)
end)

local function PrintHelp()
	say("/aa opens the config window. Other commands:")
	say("  unlock || lock  - toggle drag mode")
	say("  test            - 12s demo bars")
	say("  scale <0.3-3>, alpha <0.1-1>, length <100-1400>, curve <0-100>")
	say("  side left||right||top||bottom, pos <x> <y>")
	say("  style dot||square - use 'square' if the dots look wrong (now " .. DB.style .. ")")
	say("  smooth          - toggle drawing each bar as one layer (now " .. (DB.smooth and "on" or "off") .. ")")
	say("  status          - list the tracked shields")
	say("  total           - show the game's total absorb (test)")
	say("  debug           - print what the tracking decides")
end

local function PrintStatus()
	local list = ActiveList()
	if #list == 0 then
		say("no shields tracked")
	end
	local now = GetTime()
	for _, st in ipairs(list) do
		say(string.format("%s: %s, remaining %s / max %s, %ds left",
			st.name, st.source, st.rem and ((st.est and "~" or "") .. tostring(st.rem)) or "secret total",
			tostring(st.max), math.floor((st.expires or now) - now + 0.5)))
	end
	say("in combat lockdown: " .. tostring(InCombatLockdown()) .. ", Blizzard buff buttons: " .. tostring(BlizzBuffCount()))
	local key = EnemyKey()
	local learned = 0
	for _ in pairs(DB.hitByEnemy) do
		learned = learned + 1
	end
	say(string.format("Mana Shield estimate: ~%.0f per absorbed hit vs %s (%d enemies learned)",
		DamagePerHit(key), key or "no hostile target", learned))
end

-- /aa total: shows the game's total absorb (a secret value the game draws
-- itself) at the top of the screen, to check which shields it includes
local totalFrame = nil
local function ToggleTotal()
	if not totalFrame then
		totalFrame = CreateFrame("Frame", nil, UIParent)
		totalFrame:SetSize(1, 1)
		totalFrame:SetPoint("TOP", UIParent, "TOP", 0, -120)
		totalFrame.text = totalFrame:CreateFontString(nil, "OVERLAY", "GameFontNormalLarge")
		totalFrame.text:SetPoint("TOP", totalFrame, "TOP", 0, 0)
		totalFrame:SetScript("OnUpdate", function(self)
			local ok, v = pcall(UnitGetTotalAbsorbs, "player")
			if ok and not pcall(self.text.SetFormattedText, self.text, "AbsorbArc test - total absorb: %d", v) then
				pcall(self.text.SetText, self.text, v)
			end
		end)
		totalFrame:Hide()
	end
	if totalFrame:IsShown() then
		totalFrame:Hide()
		say("total absorb display off")
	else
		totalFrame:Show()
		say("total absorb display on (top of the screen)")
	end
end

local function NumCmd(rest, key, lo, hi, usage)
	local v = tonumber(rest)
	if v and v >= lo and v <= hi then
		DB[key] = v
		Layout()
		RefreshConfig()
	else
		say("usage: " .. usage)
	end
end

SLASH_ABSORBARC1 = "/absorbarc"
SLASH_ABSORBARC2 = "/aa"
SlashCmdList["ABSORBARC"] = function(input)
	if not DB then
		return
	end
	local cmd, rest = string.match(input or "", "^(%S*)%s*(.-)$")
	cmd = string.lower(cmd or "")
	rest = rest or ""

	if cmd == "" or cmd == "config" then
		ToggleConfig()
	elseif cmd == "help" then
		PrintHelp()
	elseif cmd == "test" then
		test = { start = GetTime(), dur = 12 }
	elseif cmd == "unlock" then
		SetUnlocked(true)
	elseif cmd == "lock" then
		SetUnlocked(false)
	elseif cmd == "pos" then
		local x, y = string.match(rest, "^(-?%d+)%s+(-?%d+)$")
		if x then
			DB.x = tonumber(x)
			DB.y = tonumber(y)
			Layout()
		else
			say("usage: /aa pos <x> <y>")
		end
	elseif cmd == "scale" then
		NumCmd(rest, "scale", 0.3, 3, "/aa scale <0.3-3>")
	elseif cmd == "alpha" then
		NumCmd(rest, "alpha", 0.1, 1, "/aa alpha <0.1-1>")
	elseif cmd == "length" then
		NumCmd(rest, "length", 100, 1400, "/aa length <100-1400>")
	elseif cmd == "curve" then
		NumCmd(rest, "curve", 0, 100, "/aa curve <0-100>")
	elseif cmd == "side" then
		rest = string.lower(rest)
		if SIDE_LABELS[rest] then
			DB.side = rest
			Layout()
			RefreshConfig()
		else
			say("usage: /aa side left||right||top||bottom")
		end
	elseif cmd == "style" then
		rest = string.lower(rest)
		if rest == "dot" or rest == "square" then
			DB.style = rest
			Layout()
		else
			say("usage: /aa style dot||square")
		end
	elseif cmd == "smooth" then
		DB.smooth = not DB.smooth
		local supported = true
		for _, b in pairs(bars) do
			ApplySmooth(b)
			ApplyAlpha(b)
			supported = b.frame.SetIsFrameBuffer ~= nil
		end
		say("smooth bars " .. (DB.smooth and "on" or "off") .. (supported and "" or " (not supported by this client)"))
	elseif cmd == "status" then
		PrintStatus()
	elseif cmd == "total" then
		ToggleTotal()
	elseif cmd == "debug" then
		DB.debug = not DB.debug
		if DB.debug then
			DB.debugLog = {}
			trace("debug on, v" .. tostring(GetMeta("Version")))
		end
		say("debug " .. (DB.debug and "on (log saved on /reload)" or "off"))
	else
		PrintHelp()
	end
end
