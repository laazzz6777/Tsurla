--[[
╔══════════════════════════════════════════════════════════════════════════╗
║          MASTER CONTROLLER v3.0  —  OMNI-STATE AUTONOMOUS AGENT         ║
║  Neural-Heuristic Decision | MCTS Navigation | Global Entity Registry   ║
║  Pixel-Perfect Aim (Camera) | Linear Projectile Physics | Adaptive      ║
║  Target  : Any team whose name contains "murder" (case-insensitive)     ║
║  Bullets : Instant, linear, zero gravity  |  Reload : 3.75 s            ║
║  Knives  : Linear trajectory, time-delayed travel, no gravity arc       ║
║  Aim     : Camera CFrame  |  Movement / Juke : Character via VIM        ║
╚══════════════════════════════════════════════════════════════════════════╝
--]]

-- ════════════════════════════════════════════════════════════════════════
--  §1  SERVICES
-- ════════════════════════════════════════════════════════════════════════
local Players             = game:GetService("Players")
local RunService          = game:GetService("RunService")
local UserInputService    = game:GetService("UserInputService")
local VirtualInputManager = game:GetService("VirtualInputManager")
local Workspace           = game:GetService("Workspace")
local StarterGui          = game:GetService("StarterGui")

local LocalPlayer = Players.LocalPlayer
local Camera      = Workspace.CurrentCamera
local isMobile    = UserInputService.TouchEnabled and not UserInputService.KeyboardEnabled

-- ════════════════════════════════════════════════════════════════════════
--  §2  MASTER CONFIG  — every tunable in one place
-- ════════════════════════════════════════════════════════════════════════
local CFG = {
    -- ── System toggles ──────────────────────────────────────────────────
    AutoNavEnabled      = true,
    AutoAimEnabled      = true,
    AutoShootEnabled    = true,
    DodgeEnabled        = true,
    JukeEnabled         = true,
    ESPEnabled          = true,

    -- ── Detection / range ───────────────────────────────────────────────
    DetectionRange      = 999,       -- studs: maximum entity tracking range
    FOVRadius           = 175,       -- pixels: aimbot screen-space FOV radius
    MaxEngageRange      = 340,       -- studs: navigate toward enemy if farther
    MeleeRange          = 5.2,       -- studs: trigger atomic orbit juke
    EngageMoveRange     = 14,        -- studs: keep moving while engaging

    -- ── Combat ──────────────────────────────────────────────────────────
    ReloadTime          = 3.75,      -- seconds: fixed reload / fire cooldown
    HeadAimBias         = 0.88,      -- fraction: prefer head over torso (0–1)
    InitialPingMs       = 65,        -- ms: starting ping estimate (auto-updates)

    -- ── Aim ─────────────────────────────────────────────────────────────
    --  Bullets are instant + linear: lead = ping only.
    --  No gravity, no arc. Camera.CFrame snapped pixel-perfect each frame.

    -- ── Movement ────────────────────────────────────────────────────────
    WalkSpeed           = 16,        -- studs/s: default Roblox walk speed
    JumpCooldown        = 0.15,      -- seconds between jumps
    JumpHeightThreshold = 4.5,       -- studs Y-delta to trigger a jump
    KeyThreshold        = 0.02,      -- WASD dot-product dead-zone
    StuckWindow         = 1.8,       -- seconds of no displacement = stuck
    StuckThreshold      = 0.35,      -- studs: displacement below = stuck

    -- ── MCTS Navigation ─────────────────────────────────────────────────
    MCTSInterval        = 0.40,      -- seconds between full tree searches
    MCTSSimulations     = 14,        -- number of paths simulated per tick
    MCTSDepth           = 6,         -- steps per simulation walk
    MCTSStepSize        = 4.0,       -- studs per simulation step

    -- ── Dodge (knives travel linearly, no gravity) ───────────────────────
    MinProjectileSpeed  = 0.10,      -- studs/s: minimum threat velocity
    FutureLookAhead     = 2.20,      -- seconds: collision prediction window
    DotFacingThreshold  = 0.00,      -- cos angle: reject if knife not facing us
    SweepDirs           = 128,       -- number of directions in dodge sweep
    ExtraBurstDistance  = 9.0,       -- studs: momentum burst after dodge ends
    ExtraMaxBurstTime   = 0.45,      -- seconds: max burst duration
    HitboxPadding       = 6.5,       -- studs: threat sphere radius per part
    SafeMarginMult      = 1.55,      -- multiplier for "safe" clearance

    -- ── Wall check (low-medium strictness) ──────────────────────────────
    WallCheckPoints     = 12,        -- atomic raycast count
    WallCheckStrict     = 0.42,      -- fraction of visible points required

    -- ── Learning ────────────────────────────────────────────────────────
    LearningRate        = 0.026,     -- online weight update rate
    WeightClampLo       = 0.10,
    WeightClampHi       = 4.20,

    -- ── Enemy filter ────────────────────────────────────────────────────
    EnemyKeyword        = "murder",  -- case-insensitive substring match
}

-- ════════════════════════════════════════════════════════════════════════
--  §3  PRE-COMPUTED SWEEP DIRECTIONS  (128 flat unit vectors, xz plane)
-- ════════════════════════════════════════════════════════════════════════
local SWEEP = {}
for _i = 0, CFG.SweepDirs - 1 do
    local a = (_i / CFG.SweepDirs) * math.pi * 2
    SWEEP[_i + 1] = Vector3.new(math.cos(a), 0, math.sin(a))
end

-- ════════════════════════════════════════════════════════════════════════
--  §4  VIM  KEY  MANAGEMENT  (all input via VirtualInputManager only)
-- ════════════════════════════════════════════════════════════════════════
local KC = {
    W     = Enum.KeyCode.W,
    A     = Enum.KeyCode.A,
    S     = Enum.KeyCode.S,
    D     = Enum.KeyCode.D,
    Space = Enum.KeyCode.Space,
}
local keyState = { W = false, A = false, S = false, D = false }

local function sendKey(down, key)
    pcall(VirtualInputManager.SendKeyEvent, VirtualInputManager, down, key, false, game)
end

local function releaseAll()
    for n, pressed in pairs(keyState) do
        if pressed then sendKey(false, KC[n]); keyState[n] = false end
    end
end

-- fireKeys  — converts a world-space XZ direction into camera-relative WASD keys
local function fireKeys(dir)
    if not dir or dir.Magnitude < 0.001 then releaseAll(); return end
    local d = Vector3.new(dir.X, 0, dir.Z)
    if d.Magnitude < 0.001 then releaseAll(); return end
    d = d.Unit

    local cf = Camera.CFrame
    local fw = Vector3.new(cf.LookVector.X,  0, cf.LookVector.Z)
    local rt = Vector3.new(cf.RightVector.X, 0, cf.RightVector.Z)
    fw = fw.Magnitude > 0.001 and fw.Unit or Vector3.new(0, 0, -1)
    rt = rt.Magnitude > 0.001 and rt.Unit or Vector3.new(1, 0, 0)

    local fDot = d:Dot(fw)
    local rDot = d:Dot(rt)
    local T    = CFG.KeyThreshold

    -- Forward / Backward axis
    if fDot > T then
        if not keyState.W then sendKey(true,  KC.W); keyState.W = true  end
        if     keyState.S then sendKey(false, KC.S); keyState.S = false end
    elseif fDot < -T then
        if not keyState.S then sendKey(true,  KC.S); keyState.S = true  end
        if     keyState.W then sendKey(false, KC.W); keyState.W = false end
    else
        if keyState.W then sendKey(false, KC.W); keyState.W = false end
        if keyState.S then sendKey(false, KC.S); keyState.S = false end
    end

    -- Right / Left axis
    if rDot > T then
        if not keyState.D then sendKey(true,  KC.D); keyState.D = true  end
        if     keyState.A then sendKey(false, KC.A); keyState.A = false end
    elseif rDot < -T then
        if not keyState.A then sendKey(true,  KC.A); keyState.A = true  end
        if     keyState.D then sendKey(false, KC.D); keyState.D = false end
    else
        if keyState.D then sendKey(false, KC.D); keyState.D = false end
        if keyState.A then sendKey(false, KC.A); keyState.A = false end
    end
end

local lastJumpTime = 0
local function doJump()
    local t = os.clock()
    if t - lastJumpTime < CFG.JumpCooldown then return end
    lastJumpTime = t
    sendKey(true,  KC.Space)
    task.delay(0.05, function() sendKey(false, KC.Space) end)
end

-- ════════════════════════════════════════════════════════════════════════
--  §5  AUTO-SHOOT SYSTEM
--  Firing is VIM mouse-button simulation.
--  Bullets are instant and linear — aim directly at predicted point.
--  Reload = exactly CFG.ReloadTime seconds between shots.
-- ════════════════════════════════════════════════════════════════════════
local lastShotTime = -999
local reloadActive = false

local function canShoot()
    return (os.clock() - lastShotTime) >= CFG.ReloadTime
end

local function getReloadFraction()
    -- 0 = just fired (0 % done), 1 = fully reloaded
    return math.min(1.0, (os.clock() - lastShotTime) / CFG.ReloadTime)
end

-- Simulate a left-mouse click at the exact screen center
local function doShoot()
    if not CFG.AutoShootEnabled then return false end
    if not canShoot()           then return false end

    local vp = Camera.ViewportSize
    local cx = math.floor(vp.X * 0.5)
    local cy = math.floor(vp.Y * 0.5)

    -- Mouse down
    pcall(function()
        VirtualInputManager:SendMouseButtonEvent(cx, cy, 0, true, game, 1)
    end)
    -- Mouse up  (~33 ms hold = one game frame)
    task.delay(0.033, function()
        pcall(function()
            VirtualInputManager:SendMouseButtonEvent(cx, cy, 0, false, game, 1)
        end)
    end)

    lastShotTime = os.clock()
    reloadActive = true
    task.delay(CFG.ReloadTime, function()
        reloadActive = false
    end)
    return true
end

-- ════════════════════════════════════════════════════════════════════════
--  §6  ENEMY IDENTIFICATION
--  Primary   : team name contains "murder" (case-insensitive)
--  Secondary : different teams (for games with proper team assignment)
--  Fallback  : target everyone if no team system is detected
-- ════════════════════════════════════════════════════════════════════════
local function isEnemy(plr)
    if not plr or plr == LocalPlayer then return false end
    if not plr.Parent then return false end

    -- Primary: team name keyword check
    if plr.Team then
        local tName = plr.Team.Name:lower()
        if tName:find(CFG.EnemyKeyword) then return true end
    end
    -- Also check if LOCAL player is on a non-murder team and target is on murder
    if LocalPlayer.Team and plr.Team then
        return plr.Team ~= LocalPlayer.Team
    end
    -- No team system: everyone is an enemy except self
    if not plr.Team and not LocalPlayer.Team then
        return true
    end
    return false
end

-- ════════════════════════════════════════════════════════════════════════
--  §7  PING ESTIMATION  (adaptive rolling average, 30-sample window)
-- ════════════════════════════════════════════════════════════════════════
local pingHistory    = {}
local estimatedPing  = CFG.InitialPingMs / 1000   -- seconds

local function updatePingEstimate()
    local ms = CFG.InitialPingMs
    pcall(function()
        local stats = game:GetService("Stats")
        ms = stats.Network.ServerStatsItem["Data Ping"]:GetValue()
    end)
    -- Clamp to sane range (0–800 ms)
    ms = math.max(10, math.min(800, ms))
    pingHistory[#pingHistory + 1] = ms
    if #pingHistory > 30 then table.remove(pingHistory, 1) end
    local sum = 0
    for _, v in ipairs(pingHistory) do sum = sum + v end
    estimatedPing = (sum / #pingHistory) / 1000
end

-- ════════════════════════════════════════════════════════════════════════
--  §8  GLOBAL ENTITY REGISTRY
--  Persistent memory for every tracked enemy.
--  Fields: pos, vel, health, maxHealth, lastCFrame, lastSeen, isVisible,
--          visFraction, peekHistory, avgVel, hitboxParts, threatScore,
--          wasVisible, hiddenSince, predictedPeekPos, damageTaken
-- ════════════════════════════════════════════════════════════════════════
local PEEK_HISTORY_CAP = 24

local EntityRegistry = {}  -- keyed by Player object

local function registryEnsure(plr)
    if not EntityRegistry[plr] then
        EntityRegistry[plr] = {
            pos              = Vector3.new(),
            vel              = Vector3.new(),
            health           = 100,
            maxHealth        = 100,
            lastCFrame       = CFrame.new(),
            lastSeen         = 0,
            isVisible        = false,
            wasVisible       = false,
            visFraction      = 0,
            peekHistory      = {},
            avgVel           = Vector3.new(),
            hitboxParts      = {},
            threatScore      = 0,
            hiddenSince      = 0,
            predictedPeekPos = nil,
            damageTaken      = 0,
            prevHealth       = 100,
        }
    end
    return EntityRegistry[plr]
end

-- Full per-enemy update called every 0.05 s
local function registryUpdate(plr, dt)
    local char = plr.Character
    if not char then return end
    local hrp = char:FindFirstChild("HumanoidRootPart")
    local hum = char:FindFirstChildOfClass("Humanoid")
    if not hrp or not hum then return end

    local entry  = registryEnsure(plr)
    local oldPos = entry.pos
    local newPos = hrp.Position

    -- Velocity: blend positional delta with Roblox AssemblyLinearVelocity
    local posVel = dt > 0 and (newPos - oldPos) / dt or entry.vel
    local rbxVel = hrp.AssemblyLinearVelocity          -- accurate physics vel
    -- Weighted blend: positional delta is smoother over walls
    entry.vel    = entry.vel * 0.50 + posVel * 0.30 + rbxVel * 0.20

    -- Long-term average velocity for peek prediction
    entry.avgVel = entry.avgVel * 0.90 + entry.vel * 0.10

    entry.pos        = newPos
    entry.lastCFrame = hrp.CFrame
    entry.lastSeen   = os.clock()

    -- Health tracking (detect damage taken)
    entry.prevHealth = entry.health
    entry.health     = hum.Health
    entry.maxHealth  = hum.MaxHealth
    if entry.health < entry.prevHealth - 0.5 then
        entry.damageTaken = entry.damageTaken + (entry.prevHealth - entry.health)
    end

    -- Peek history ring buffer
    local ph = entry.peekHistory
    ph[#ph + 1] = { pos = newPos, t = os.clock(), vel = Vector3.new(entry.vel.X, 0, entry.vel.Z) }
    if #ph > PEEK_HISTORY_CAP then table.remove(ph, 1) end

    -- Rebuild hitbox parts (enemy's physical hitbox — every BasePart)
    local parts = {}
    for _, p in ipairs(char:GetDescendants()) do
        if p:IsA("BasePart") then parts[#parts + 1] = p end
    end
    entry.hitboxParts = parts

    -- Peek state machine
    entry.wasVisible = entry.isVisible
    -- isVisible / visFraction are written by the LoS system in the main loop
end

-- Linear prediction:  where will enemy be in `t` seconds?
-- Instant bullet → lead = estimatedPing only.
local function predictEnemyPosition(plr, t)
    local entry = EntityRegistry[plr]
    if not entry then return nil end

    local now = os.clock()
    local stale = now - entry.lastSeen

    -- If very stale, return last known or predicted peek
    if stale > 5.0 then
        return entry.predictedPeekPos or entry.pos
    end

    -- Base linear prediction (works perfectly for instant bullets — just ping lead)
    local predicted = entry.pos + entry.vel * t

    -- Peek prediction: enemy just went behind cover → predict re-emergence
    if not entry.isVisible and entry.wasVisible then
        local ph = entry.peekHistory
        if #ph >= 6 then
            local recent  = ph[#ph]
            local older   = ph[math.max(1, #ph - 6)]
            local ingress = recent.pos - older.pos
            if ingress.Magnitude > 0.4 then
                -- Predict peek from the reverse of ingress direction
                entry.predictedPeekPos = entry.pos - ingress.Unit * 1.8
            end
        end
        -- While hidden, refine predicted peek with average velocity
        if entry.predictedPeekPos then
            return entry.predictedPeekPos
        end
    end

    return predicted
end

-- Return (player, entry, dist) for the closest alive enemy
local function getClosestEnemyToPos(fromPos)
    local bestPlr   = nil
    local bestEntry = nil
    local bestDist  = math.huge
    for plr, entry in pairs(EntityRegistry) do
        if isEnemy(plr) and plr.Character and entry.health > 0 then
            local d = (entry.pos - fromPos).Magnitude
            if d < bestDist then
                bestDist  = d
                bestPlr   = plr
                bestEntry = entry
            end
        end
    end
    return bestPlr, bestEntry, bestDist
end

-- ════════════════════════════════════════════════════════════════════════
--  §9  LOCAL CHARACTER CACHE  (rebuilt on respawn and if invalid)
-- ════════════════════════════════════════════════════════════════════════
local charParts   = {}   -- all BasePart references
local charFeet    = {}   -- foot/lower-leg parts for ground detection
local charHRP     = nil  -- HumanoidRootPart reference
local charHuman   = nil  -- Humanoid reference

local HITBOX_NAMES = {
    "Head", "UpperTorso", "LowerTorso", "HumanoidRootPart", "Torso",
    "Left Arm", "Right Arm", "Left Leg", "Right Leg",
    "LeftUpperArm", "RightUpperArm", "LeftLowerArm", "RightLowerArm",
    "LeftHand", "RightHand", "LeftUpperLeg", "RightUpperLeg",
    "LeftLowerLeg", "RightLowerLeg", "LeftFoot", "RightFoot",
}
local FEET_NAMES = {
    "LeftFoot", "RightFoot", "LeftLowerLeg", "RightLowerLeg",
    "Left Leg", "Right Leg", "LowerTorso",
}

local function rebuildCharCache(char)
    charParts  = {}
    charFeet   = {}
    charHRP    = char:FindFirstChild("HumanoidRootPart")
    charHuman  = char:FindFirstChildOfClass("Humanoid")
    for _, name in ipairs(HITBOX_NAMES) do
        local p = char:FindFirstChild(name)
        if p and p:IsA("BasePart") then charParts[#charParts + 1] = p end
    end
    for _, name in ipairs(FEET_NAMES) do
        local p = char:FindFirstChild(name)
        if p and p:IsA("BasePart") then charFeet[#charFeet + 1] = p end
    end
end

-- Lowest Y of feet  (used for jump height threshold vs knife impact Y)
local function getFeetY()
    local lo = math.huge
    for _, p in ipairs(charFeet) do
        local y = p.Position.Y - p.Size.Y * 0.5
        if y < lo then lo = y end
    end
    return lo == math.huge and (charHRP and charHRP.Position.Y - 2.6 or 0) or lo
end

local function getLocalHP()
    if charHuman then return charHuman.Health, charHuman.MaxHealth end
    return 100, 100
end

-- ════════════════════════════════════════════════════════════════════════
--  §10  12-POINT ATOMIC LINE-OF-SIGHT
--  Returns  visibleCount, totalPoints, clearFraction, bestVisiblePoint
--  Low-medium strictness: require  WallCheckStrict fraction (≈42%) visible
-- ════════════════════════════════════════════════════════════════════════
local function atomicLoS(targetChar, originPos)
    if not targetChar then return 0, 12, 0, nil end

    local myChar     = LocalPlayer.Character
    local filterList = {}
    if myChar then
        filterList[1] = myChar
        for _, p in ipairs(myChar:GetDescendants()) do
            if p:IsA("BasePart") then filterList[#filterList + 1] = p end
        end
    end

    local params = RaycastParams.new()
    params.FilterType = Enum.RaycastFilterType.Blacklist
    params.FilterDescendantsInstances = filterList

    -- Ordered check-point names  (head first = highest priority for best aim point)
    local checkOrder = {
        "Head", "UpperTorso", "Torso", "HumanoidRootPart", "LowerTorso",
        "LeftUpperArm", "RightUpperArm", "LeftUpperLeg", "RightUpperLeg",
        "LeftHand", "RightHand", "LeftFoot",
    }

    local checkPoints = {}
    for _, name in ipairs(checkOrder) do
        local p = targetChar:FindFirstChild(name)
        if p and p:IsA("BasePart") then
            checkPoints[#checkPoints + 1] = { pos = p.Position, part = p, priority = #checkPoints + 1 }
        end
        if #checkPoints >= 12 then break end
    end
    -- Fill remaining slots from all descendants
    if #checkPoints < 12 then
        for _, p in ipairs(targetChar:GetDescendants()) do
            if p:IsA("BasePart") then
                checkPoints[#checkPoints + 1] = { pos = p.Position, part = p, priority = #checkPoints + 1 }
            end
            if #checkPoints >= 12 then break end
        end
    end

    local visCount  = 0
    local bestPoint = nil
    local bestPri   = math.huge

    for i, cp in ipairs(checkPoints) do
        if i > 12 then break end
        local dir    = cp.pos - originPos
        local result = Workspace:Raycast(originPos, dir, params)
        local hit    = result and result.Instance

        -- Visible = no wall hit, OR the hit instance belongs to the target character
        local visible = (result == nil)
            or (hit and hit:IsDescendantOf(targetChar))

        if visible then
            visCount = visCount + 1
            if cp.priority < bestPri then
                bestPri   = cp.priority
                bestPoint = cp.pos
            end
        end
    end

    local total = math.min(#checkPoints, 12)
    return visCount, total, visCount / math.max(total, 1), bestPoint
end

-- ════════════════════════════════════════════════════════════════════════
--  §11  PART-AWARE NAVIGATION  (trusses, ramps, wedges, ledges)
--  Casts forward at ankle / hip / chest height.
--  Returns: yDelta (studs), obstacleClass ("truss","ramp","step","wall","ledge",nil)
-- ════════════════════════════════════════════════════════════════════════
local function classifyPart(part)
    if not part or not part:IsA("BasePart") then return nil end
    if part:IsA("TrussPart")         then return "truss"    end
    if part:IsA("WedgePart")         then return "ramp"     end
    if part:IsA("CornerWedgePart")   then return "ramp"     end
    local sy = part.Size.Y
    if sy < 1.5 then return "floor" end
    return "obstacle"
end

local function getYCorrectionForDir(hrpPos, moveDir)
    if not charHRP then return 0, nil end

    local myChar = LocalPlayer.Character
    local params = RaycastParams.new()
    params.FilterType = Enum.RaycastFilterType.Blacklist
    params.FilterDescendantsInstances = myChar and { myChar } or {}

    local checkDist = 3.4
    -- Three scan heights: ankle (−1.8), hip (0), chest (+1.2)
    local origins = {
        hrpPos + Vector3.new(0, -1.8, 0),
        hrpPos + Vector3.new(0,  0.0, 0),
        hrpPos + Vector3.new(0,  1.2, 0),
    }

    for _, origin in ipairs(origins) do
        local result = Workspace:Raycast(origin, moveDir * checkDist, params)
        if result and result.Instance then
            local cls     = classifyPart(result.Instance)
            local partTop = result.Instance.Position.Y + result.Instance.Size.Y * 0.5
            local delta   = partTop - hrpPos.Y

            if cls == "truss" then
                -- Trusses are climbable; hold W + jump near them
                return delta + 0.6, "truss"
            elseif cls == "ramp" then
                return math.max(0, delta * 0.4), "ramp"
            elseif cls == "obstacle" then
                if delta <= CFG.JumpHeightThreshold then
                    return delta + 0.35, "step"
                else
                    return delta, "wall"
                end
            elseif cls == "floor" then
                return 0, "floor"
            end
        end
    end

    -- Ledge detection: check that ground exists 2.5 studs ahead
    local groundHere  = Workspace:Raycast(hrpPos + Vector3.new(0,-0.2,0), Vector3.new(0,-8,0), params)
    local groundAhead = Workspace:Raycast(hrpPos + moveDir * 2.5 + Vector3.new(0,-0.2,0), Vector3.new(0,-8,0), params)
    if groundHere and not groundAhead then
        return -99, "ledge"
    end
    if groundHere and groundAhead then
        local stepUp = groundAhead.Position.Y - groundHere.Position.Y
        if stepUp > 0.55 and stepUp < CFG.JumpHeightThreshold then
            return stepUp + 0.25, "step"
        end
    end

    return 0, nil
end

-- Gravity-aware jump trigger:
--  Given that we're about to walk into a step/truss/ramp, should we jump?
local function shouldJumpForObstacle(yDelta, cls)
    if not cls then return false end
    if cls == "ledge" then return false end   -- don't jump off ledges
    if cls == "truss" then return true  end
    if cls == "step"  then return yDelta and yDelta > 0.3 end
    if cls == "ramp"  then return yDelta and yDelta > 0.8 end
    return false
end

-- ════════════════════════════════════════════════════════════════════════
--  §12  MONTE CARLO TREE SEARCH  — path planning
--  Runs `MCTSSimulations` randomised walks each MCTSInterval seconds.
--  Scores by: progress toward goal, wall collisions, threat proximity,
--             ledge avoidance, directional bias.
-- ════════════════════════════════════════════════════════════════════════
local MCTSCache = {
    lastRunTime   = 0,
    bestDirection = nil,
    goalPos       = nil,
}

local function mctsSearch(startPos, goalPos, simCount)
    if not goalPos then return nil end

    local myChar = LocalPlayer.Character
    local params = RaycastParams.new()
    params.FilterType = Enum.RaycastFilterType.Blacklist
    params.FilterDescendantsInstances = myChar and { myChar } or {}

    local goalFlat  = Vector3.new(goalPos.X, 0, goalPos.Z)
    local startFlat = Vector3.new(startPos.X, 0, startPos.Z)
    local rawDir    = goalFlat - startFlat
    local goalDir   = rawDir.Magnitude > 0.1 and rawDir.Unit or Vector3.new(0, 0, -1)
    local goalDist  = rawDir.Magnitude

    local step      = CFG.MCTSStepSize
    local depth     = CFG.MCTSDepth

    local bestScore    = -math.huge
    local bestFirstDir = goalDir

    for _ = 1, simCount do
        -- Bias first-step direction toward goal with random spread
        local baseAngle  = math.atan2(goalDir.Z, goalDir.X)
        local spread     = math.pi * 0.55
        local firstAngle = baseAngle + (math.random() * 2 - 1) * spread
        local firstDir   = Vector3.new(math.cos(firstAngle), 0, math.sin(firstAngle))

        local pos   = startPos
        local score = 0
        local valid = true

        for d = 1, depth do
            -- Progressively steer toward goal in later steps
            local targetAngle  = math.atan2(goalDir.Z, goalDir.X)
            local currentAngle = math.atan2(firstDir.Z, firstDir.X)
            local t_blend      = (d / depth) * 0.5
            local blendedAngle = currentAngle + (targetAngle - currentAngle) * t_blend
            local stepDir      = Vector3.new(math.cos(blendedAngle), 0, math.sin(blendedAngle))
            local nextPos      = pos + stepDir * step

            -- Wall / obstacle check
            local wallHit = Workspace:Raycast(
                pos + Vector3.new(0, 0.5, 0),
                stepDir * (step * 1.15),
                params
            )
            if wallHit and wallHit.Instance then
                local cls     = classifyPart(wallHit.Instance)
                local partTop = wallHit.Instance.Position.Y + wallHit.Instance.Size.Y * 0.5
                local yDelta  = partTop - pos.Y
                if cls == "wall" or cls == "obstacle" then
                    if yDelta > CFG.JumpHeightThreshold then
                        score = score - 90
                        valid = false
                        break
                    else
                        score = score - 12   -- jumpable obstacle
                    end
                end
            end

            -- Ledge / drop-off check
            local groundAhead = Workspace:Raycast(
                nextPos + Vector3.new(0, 0.3, 0), Vector3.new(0, -9, 0), params
            )
            if not groundAhead then
                score = score - 70
                valid = false
                break
            end

            -- Threat proximity penalty (don't walk into enemy)
            for tplr, entry in pairs(EntityRegistry) do
                if isEnemy(tplr) and entry.health > 0 then
                    local ed = (nextPos - entry.pos).Magnitude
                    if ed < 8 then
                        score = score - (50 / (ed + 0.5))
                    end
                end
            end

            pos   = nextPos
            score = score + 6  -- movement progress
        end

        if valid then
            -- Distance-to-goal reward
            local finalDist = Vector3.new(pos.X, 0, pos.Z) - goalFlat
            score = score + 280 / (finalDist.Magnitude + 1)
            -- Directional alignment bonus
            score = score + firstDir:Dot(goalDir) * 28
        end

        if score > bestScore then
            bestScore    = score
            bestFirstDir = firstDir
        end
    end

    return bestFirstDir
end

-- ════════════════════════════════════════════════════════════════════════
--  §13  NEURAL-HEURISTIC BRAIN
--  Weighted scoring across six actions.  Pre-tuned for combat (smart on frame 1).
--  Online learning: reward/penalise the last action based on outcomes.
--  Weights are clamped to [WeightClampLo, WeightClampHi].
-- ════════════════════════════════════════════════════════════════════════
local Brain = {
    w = {
        dodge       = 1.72,   -- top priority: knife always dodged
        juke        = 1.18,   -- melee orbit
        engage      = 1.30,   -- shoot when LoS clear and loaded
        retreat     = 0.58,   -- flee when low HP
        navigate    = 0.95,   -- approach enemy
        wait_reload = 1.15,   -- evasive movement during reload
    },
    lastAction    = "navigate",
    decisionCount = 0,
}

-- Compute a score for each action and return the winning action name.
-- All inputs are numeric scalars in [0,∞) or booleans.
local function brainDecide(ctx)
    -- ctx fields: health, maxHealth, targetDist, hasLoS, visFraction,
    --             threatCount, isReloading, inMeleeRange, hasTarget, targetHP
    local hpRatio  = ctx.health / math.max(ctx.maxHealth, 1)
    local visFrac  = ctx.visFraction or 0
    local threats  = ctx.threatCount or 0
    local reload   = ctx.isReloading and 1 or 0
    local melee    = ctx.inMeleeRange and 1 or 0
    local hasTgt   = ctx.hasTarget and 1 or 0
    local dist     = ctx.targetDist or 999

    -- Visibility threshold gate (low-medium wall check)
    local visGate  = visFrac >= CFG.WallCheckStrict and 1 or (visFrac / CFG.WallCheckStrict)

    local scores = {
        dodge       = Brain.w.dodge   * math.max(0, threats * 0.9 + (threats > 0 and 0.5 or 0)),
        juke        = Brain.w.juke    * melee * (1 - reload * 0.25),
        engage      = Brain.w.engage  * visGate * hpRatio * (1 - reload)
                      * hasTgt * (dist < CFG.MaxEngageRange and 1 or 0),
        retreat     = Brain.w.retreat * (1 - hpRatio) * (hpRatio < 0.35 and 2.4 or 1.0),
        navigate    = Brain.w.navigate * hasTgt * (dist > 10 and 1 or 0)
                      * (1 - (ctx.hasLoS and 0.35 or 0)),
        wait_reload = Brain.w.wait_reload * reload * (0.5 + (1 - hpRatio) * 0.5),
    }

    local best  = "navigate"
    local bestV = -math.huge
    for act, val in pairs(scores) do
        if val > bestV then bestV = val; best = act end
    end

    Brain.lastAction    = best
    Brain.decisionCount = Brain.decisionCount + 1
    return best, scores
end

-- Online learning: call with positive (good) or negative (bad) reward
local function brainReward(reward)
    local lr  = CFG.LearningRate
    local act = Brain.lastAction
    local w   = Brain.w

    if     act == "dodge"       then w.dodge       = w.dodge       + lr * reward
    elseif act == "juke"        then w.juke        = w.juke        + lr * reward
    elseif act == "engage"      then w.engage      = w.engage      + lr * reward
    elseif act == "retreat"     then w.retreat     = w.retreat     + lr * reward
    elseif act == "navigate"    then w.navigate    = w.navigate    + lr * reward
    elseif act == "wait_reload" then w.wait_reload = w.wait_reload + lr * reward
    end

    -- Hard clamp to prevent divergence
    for k, v in pairs(w) do
        Brain.w[k] = math.max(CFG.WeightClampLo, math.min(CFG.WeightClampHi, v))
    end
end

-- ════════════════════════════════════════════════════════════════════════
--  §14  PIXEL-PERFECT AIM SYSTEM  (camera-based, instant linear bullets)
--
--  Since bullets are INSTANT and LINEAR (zero gravity, zero travel time):
--    • No ballistic arc correction needed
--    • Only lead needed = estimatedPing seconds of target movement
--    • Camera.CFrame is set to exact CFrame.new(camPos, predictedPoint)
--    • This is pixel-perfect: the rendered crosshair lands exactly on the point
--
--  Priority order: Head → UpperTorso/Torso → HRP → any visible part
-- ════════════════════════════════════════════════════════════════════════

-- Part priority for aim (lower index = more preferred)
local AIM_PRIORITY = {
    "Head", "UpperTorso", "Torso", "HumanoidRootPart",
    "LowerTorso", "LeftUpperArm", "RightUpperArm",
    "LeftLowerArm", "RightLowerArm",
}

-- Returns: predictedAimPoint (Vector3), partName (string) | nil, nil
local function getBestAimPoint(targetChar, originPos, targetVel)
    if not targetChar then return nil, nil end

    local myChar = LocalPlayer.Character
    local filterList = myChar and { myChar } or {}
    local params = RaycastParams.new()
    params.FilterType = Enum.RaycastFilterType.Blacklist
    params.FilterDescendantsInstances = filterList

    -- Ping-compensation lead time.
    -- Instant bullet → only network delay matters.
    local lead = estimatedPing
    local vel  = targetVel or Vector3.new()

    -- Scan priority parts first
    for idx, name in ipairs(AIM_PRIORITY) do
        local part = targetChar:FindFirstChild(name)
        if part and part:IsA("BasePart") then
            -- Linear prediction: where will this part be in `lead` seconds?
            local predictedPos = part.Position + vel * lead

            local dir    = predictedPos - originPos
            local result = Workspace:Raycast(originPos, dir, params)

            if result == nil then
                -- Unobstructed: perfect shot
                return predictedPos, name
            elseif result.Instance and result.Instance:IsDescendantOf(targetChar) then
                -- Hit is on the target itself — valid shot point
                return result.Position, name
            end
        end
    end

    -- Fall through: scan every descendant BasePart
    for _, part in ipairs(targetChar:GetDescendants()) do
        if part:IsA("BasePart") then
            local predictedPos = part.Position + vel * lead
            local dir    = predictedPos - originPos
            local result = Workspace:Raycast(originPos, dir, params)
            if result == nil or (result.Instance and result.Instance:IsDescendantOf(targetChar)) then
                return predictedPos, part.Name
            end
        end
    end

    -- Last resort: HRP with ping lead (even if slightly behind wall)
    local hrp = targetChar:FindFirstChild("HumanoidRootPart")
    if hrp then
        return hrp.Position + vel * lead, "HumanoidRootPart_fallback"
    end
    return nil, nil
end

-- Set Camera.CFrame to look exactly at aimPoint from current camera position.
-- This is instantaneous and pixel-perfect for linear/instant projectiles.
local function applyAim(aimPoint)
    if not aimPoint then return end
    local camPos = Camera.CFrame.Position
    -- CFrame.new(pos, target) builds a CFrame looking at target from pos
    Camera.CFrame = CFrame.new(camPos, aimPoint)
end

-- Screen-space distance from viewport center to a world point
local function screenDistFromCenter(worldPos)
    local screenPos, onScreen = Camera:WorldToViewportPoint(worldPos)
    if not onScreen then return math.huge end
    local vp = Camera.ViewportSize
    local dx = screenPos.X - vp.X * 0.5
    local dy = screenPos.Y - vp.Y * 0.5
    return math.sqrt(dx * dx + dy * dy)
end

-- Select the primary aim target: closest to screen center, within FOV, alive, visible
local function selectAimTarget()
    local myChar = LocalPlayer.Character
    if not myChar then return nil, nil end
    local myHRP = myChar:FindFirstChild("HumanoidRootPart")
    if not myHRP then return nil, nil end

    local originPos = Camera.CFrame.Position
    local bestPlr   = nil
    local bestDist  = math.huge
    local bestPoint = nil

    for _, plr in ipairs(Players:GetPlayers()) do
        if not isEnemy(plr) then continue end
        local char = plr.Character
        if not char then continue end
        local hrp = char:FindFirstChild("HumanoidRootPart")
        local hum = char:FindFirstChildOfClass("Humanoid")
        if not hrp or not hum or hum.Health <= 0 then continue end

        -- Quick FOV reject using HRP screen position
        local sDist = screenDistFromCenter(hrp.Position)
        if sDist > CFG.FOVRadius then continue end

        -- Wall check (low-medium: 42% of 12 points)
        local vis, _, frac, _ = atomicLoS(char, originPos)
        if frac < CFG.WallCheckStrict then continue end

        if sDist < bestDist then
            local entry  = EntityRegistry[plr]
            local vel    = entry and entry.vel or Vector3.new()
            local aimPt, _ = getBestAimPoint(char, originPos, vel)
            if aimPt then
                bestDist  = sDist
                bestPlr   = plr
                bestPoint = aimPt
            end
        end
    end

    return bestPlr, bestPoint
end

-- ════════════════════════════════════════════════════════════════════════
--  §15  KNIFE / PROJECTILE DODGE SYSTEM
--  Knife trajectory is FULLY LINEAR (no gravity).
--  Uses analytical ray-sphere intersection for exact impact prediction.
--  Collision check: knife ray vs sphere of radius HitboxPadding around
--  each body part.  Returns the first (smallest t) intersection.
-- ════════════════════════════════════════════════════════════════════════

-- Evaluate one projectile as a threat.  Returns threat table or nil.
local function evalProjectileThreat(partPos, partVel, hrpPos, feetY)
    local speed = partVel.Magnitude
    if speed < CFG.MinProjectileSpeed then return nil end

    local toPlayer = hrpPos - partPos
    local dist     = toPlayer.Magnitude
    if dist > CFG.DetectionRange then return nil end
    -- Reject if knife is not heading toward us (dot < threshold)
    if dist > 0.001 then
        local cosAngle = toPlayer:Dot(partVel) / (dist * speed)
        if cosAngle < CFG.DotFacingThreshold then return nil end
    end

    -- Ray-sphere intersection:  ray origin = partPos, dir = partVel (not normalised)
    --  sphere center = each body part position, radius = HitboxPadding
    --  solve:  |partPos + t*partVel - sphereCenter|² = R²
    local a     = partVel:Dot(partVel)     -- |v|²
    if a < 1e-10 then return nil end
    local inv2a = 0.5 / a
    local pad   = CFG.HitboxPadding
    local pad2  = pad * pad

    local bestT    = math.huge
    local bestPart = nil

    for _, hp in ipairs(charParts) do
        local oc   = partPos - hp.Position   -- origin - sphere center
        local b    = 2 * oc:Dot(partVel)
        local c    = oc:Dot(oc) - pad2
        local disc = b * b - 4 * a * c
        if disc >= 0 then
            local sq = math.sqrt(disc)
            local t1 = (-b - sq) * inv2a
            local t2 = (-b + sq) * inv2a
            -- We want smallest non-negative t
            local t  = (t1 >= 0) and t1 or t2
            if t >= 0 and t <= CFG.FutureLookAhead and t < bestT then
                bestT    = t
                bestPart = hp
            end
        end
    end

    if not bestPart then return nil end

    -- Impact point (linear, no gravity)
    local knifeImpact = partPos + partVel * bestT

    -- Build perpendicular vectors in the XZ plane
    local vFlat = Vector3.new(partVel.X, 0, partVel.Z)
    vFlat = vFlat.Magnitude > 0.001 and vFlat.Unit or Vector3.new(1, 0, 0)
    local pA   = Vector3.new(-vFlat.Z, 0,  vFlat.X)
    local pB   = Vector3.new( vFlat.Z, 0, -vFlat.X)
    local away = Vector3.new(hrpPos.X - knifeImpact.X, 0, hrpPos.Z - knifeImpact.Z)
    away = away.Magnitude > 0.01 and away.Unit or (-vFlat)

    -- bestPerp = the perpendicular side that is "away" from impact direction
    local bestPerp = pA:Dot(away) >= pB:Dot(away) and pA or pB

    -- Gravity-aware jump flag: if impact Y is near feet level, jump
    local needJump = (knifeImpact.Y <= feetY + CFG.JumpHeightThreshold) and (bestT < 0.55)

    return {
        t        = bestT,
        impact   = knifeImpact,
        vel      = partVel,
        pos      = partPos,
        speed    = speed,
        pA       = pA,
        pB       = pB,
        bestPerp = bestPerp,
        away     = away,
        vFlat    = vFlat,
        needJump = needJump,
        urgency  = 1 / (bestT + 0.01),
    }
end

-- Clearance: how far will our future XZ position be from the knife ray
-- if we move in `dir` for min(th.t, 0.5) seconds at WalkSpeed?
local function computeClearance(dir, hrpPos, th)
    local moveTime = math.min(th.t, 0.5)
    local fx = hrpPos.X + dir.X * CFG.WalkSpeed * moveTime
    local fz = hrpPos.Z + dir.Z * CFG.WalkSpeed * moveTime

    -- Closest point on ray (2D XZ) to future player position
    local ox, oz = th.pos.X, th.pos.Z
    local dx, dz = th.vFlat.X, th.vFlat.Z
    local ex     = fx - ox
    local ez     = fz - oz
    local proj   = math.max(0, ex * dx + ez * dz)
    local cx     = ox + dx * proj
    local cz     = oz + dz * proj
    local rx     = fx - cx
    local rz     = fz - cz
    return math.sqrt(rx * rx + rz * rz)
end

-- Score a candidate dodge direction against all threats.
-- Hard-rejects directions that still land inside HitboxPadding.
-- Returns a scalar score (higher = safer).
local function scoreDodgeDir(dir, hrpPos, threats)
    local safe  = CFG.HitboxPadding * CFG.SafeMarginMult
    local minC  = math.huge
    local total = 0
    for _, th in ipairs(threats) do
        local c = computeClearance(dir, hrpPos, th)
        if c < minC then minC = c end
        if c >= safe then
            total = total + c * th.urgency
        else
            total = total - (safe - c) * 22 * th.urgency
        end
    end
    if minC < CFG.HitboxPadding then return -math.huge end
    return total
end

-- Find the best dodge direction across all active threats.
local function computeBestDodge(hrpPos, threats)
    if #threats == 0 then return nil end

    local bestDir   = nil
    local bestScore = -math.huge

    -- 128-direction sweep
    for _, d in ipairs(SWEEP) do
        local s = scoreDodgeDir(d, hrpPos, threats)
        if s > bestScore then bestScore = s; bestDir = d end
    end

    -- Per-threat candidate directions (perpendicular + away)
    for _, th in ipairs(threats) do
        for _, cand in ipairs({ th.pA, th.pB, th.away, th.bestPerp }) do
            if cand and cand.Magnitude > 0.01 then
                local s = scoreDodgeDir(cand.Unit, hrpPos, threats)
                if s > bestScore then bestScore = s; bestDir = cand.Unit end
            end
        end
    end

    -- Fallback if ALL directions remain inside threat (surrounded):
    -- pick the direction with maximum clearance regardless of hard-reject
    if not bestDir or bestScore == -math.huge then
        bestScore = -math.huge
        for _, d in ipairs(SWEEP) do
            local minC = math.huge
            for _, th in ipairs(threats) do
                local c = computeClearance(d, hrpPos, th)
                if c < minC then minC = c end
            end
            if minC > bestScore then bestScore = minC; bestDir = d end
        end
    end

    return bestDir
end

-- ════════════════════════════════════════════════════════════════════════
--  §16  PROJECTILE TRACKING
-- ════════════════════════════════════════════════════════════════════════
local projSet  = {}   -- [BasePart] = true
local projData = {}   -- [BasePart] = { lastPos, vel, born, frames }
local projList = {}   -- ordered array of tracked parts

local function isProjectileName(n)
    local lo = n:lower()
    return lo:find("knife")  or lo:find("projectile") or lo:find("throw")
        or lo:find("bullet") or lo:find("axe")        or lo:find("rock")
        or lo:find("spear")  or lo:find("dart")       or lo:find("star")
        or lo:find("arrow")  or lo:find("shard")      or lo:find("bolt")
        or lo:find("orb")    or lo:find("shuriken")
end

-- Immediate spawn-dodge triggered the moment a knife enters the workspace
local function spawnInstantDodge(vel, knifePos)
    if not CFG.DodgeEnabled then return end
    local hrp = charHRP
    if not hrp then return end
    if vel.Magnitude < CFG.MinProjectileSpeed then return end

    local hrpPos = hrp.Position
    local vFlat  = Vector3.new(vel.X, 0, vel.Z)
    if vFlat.Magnitude < 0.001 then return end
    vFlat = vFlat.Unit

    local away = Vector3.new(hrpPos.X - knifePos.X, 0, hrpPos.Z - knifePos.Z)
    away = away.Magnitude > 0.01 and away.Unit or (-vFlat)
    local pA = Vector3.new(-vFlat.Z, 0,  vFlat.X)
    local pB = Vector3.new( vFlat.Z, 0, -vFlat.X)
    local bp = pA:Dot(away) >= pB:Dot(away) and pA or pB

    local estT = math.max(0.05, (hrpPos - knifePos).Magnitude / math.max(vel.Magnitude, 1))
    local fakeThreat = {
        t        = estT,
        impact   = knifePos + vel * estT,
        vel      = vel,
        pos      = knifePos,
        speed    = vel.Magnitude,
        pA       = pA,
        pB       = pB,
        bestPerp = bp,
        away     = away,
        vFlat    = vFlat,
        urgency  = 1 / (estT + 0.01),
    }

    local dodgeDir = computeBestDodge(hrpPos, { fakeThreat }) or bp
    fireKeys(dodgeDir)

    if knifePos.Y <= getFeetY() + CFG.JumpHeightThreshold then
        doJump()
    end
end

local function registerProjectile(obj)
    if not isProjectileName(obj.Name) then return end
    local part = obj:IsA("BasePart") and obj
              or (obj:IsA("Model") and (obj.PrimaryPart or obj:FindFirstChildWhichIsA("BasePart")))
    if not part or projSet[part] then return end

    local vel  = part.AssemblyLinearVelocity
    local pos  = part.Position
    local data = { lastPos = pos, vel = vel, born = os.clock(), frames = 0 }
    projSet[part]          = true
    projData[part]         = data
    projList[#projList + 1] = part

    -- Immediate dodge on registration
    spawnInstantDodge(vel, pos)

    -- Some knives start at zero velocity then update — hook the change
    local conn
    conn = part:GetPropertyChangedSignal("AssemblyLinearVelocity"):Connect(function()
        if not projSet[part] then conn:Disconnect(); return end
        local v = part.AssemblyLinearVelocity
        if v.Magnitude > 0.5 then
            data.vel = v
            spawnInstantDodge(v, part.Position)
            conn:Disconnect()
        end
    end)

    -- Deferred 1-frame velocity check
    task.defer(function()
        if projSet[part] then
            local v = part.AssemblyLinearVelocity
            if v.Magnitude > data.vel.Magnitude * 0.5 then
                data.vel = v
            end
        end
    end)
end

local function unregisterProjectile(obj)
    local part = obj:IsA("BasePart") and obj
              or (obj:IsA("Model") and (obj.PrimaryPart or obj:FindFirstChildWhichIsA("BasePart")))
    if not part or not projSet[part] then return end
    projSet[part]  = nil
    projData[part] = nil
    for i = #projList, 1, -1 do
        if projList[i] == part then table.remove(projList, i); break end
    end
end

local function connectProjectileFolder(folder)
    for _, obj in ipairs(folder:GetDescendants()) do registerProjectile(obj) end
    folder.DescendantAdded:Connect(registerProjectile)
    folder.DescendantRemoving:Connect(unregisterProjectile)
end

task.spawn(function()
    local folderNames = {
        "ProjectilesAndDebris", "Projectiles", "Debris",
        "Knives", "Throwables", "Bullets",
    }
    for _, n in ipairs(folderNames) do
        local f = Workspace:FindFirstChild(n)
        if f then connectProjectileFolder(f); return end
    end
    -- Fallback: watch entire workspace
    connectProjectileFolder(Workspace)
end)

-- Per-frame velocity refinement for all tracked projectiles
local function updateProjectileVelocities(dt)
    local i = 1
    while i <= #projList do
        local part = projList[i]
        if not part or not part.Parent then
            if part then projSet[part] = nil; projData[part] = nil end
            table.remove(projList, i)
        else
            local d = projData[part]
            if d and dt > 0 then
                local np = part.Position
                local dv = (np - d.lastPos) / dt
                d.frames = (d.frames or 0) + 1
                -- Early frames: trust Roblox velocity more; later frames trust delta more
                if d.frames <= 2 then
                    d.vel = dv * 0.30 + part.AssemblyLinearVelocity * 0.70
                else
                    d.vel = dv * 0.85 + part.AssemblyLinearVelocity * 0.15
                end
                d.lastPos = np
            end
            i = i + 1
        end
    end
end

-- ════════════════════════════════════════════════════════════════════════
--  §17  MELEE JUKE  —  ATOMIC ORBIT  (character-based, not camera)
--  When enemy enters MeleeRange:
--    1. Read enemy CHARACTER's LookVector (not camera)
--    2. Compute the 180° blind spot (behind them)
--    3. Move character there using fireKeys()
--    4. Camera continues to aim at enemy independently
-- ════════════════════════════════════════════════════════════════════════
local JukeState = {
    active       = false,
    orbitDir     = 1,        -- +1 clockwise, −1 counter-clockwise
    targetPlayer = nil,
    changeTimer  = 0,        -- time until orbit direction randomises again
}

-- Given our position, enemy position, and enemy facing direction,
-- return the world-space XZ movement direction to reach their blind spot.
local function computeJukeDir(myPos, enemyPos, enemyLook)
    -- Blind spot position = 2 studs directly behind the enemy
    local blindSpotWorld = enemyPos - enemyLook * 2.0
    local toBlind = Vector3.new(
        blindSpotWorld.X - myPos.X, 0, blindSpotWorld.Z - myPos.Z
    )

    local toEnemy = Vector3.new(enemyPos.X - myPos.X, 0, enemyPos.Z - myPos.Z)

    if toBlind.Magnitude < 0.5 then
        -- Already in blind spot: orbit perpendicular to keep moving
        local perp = Vector3.new(-enemyLook.Z, 0, enemyLook.X) * JukeState.orbitDir
        return perp.Magnitude > 0.01 and perp.Unit or enemyLook
    end

    toBlind = toBlind.Unit
    -- Perpendicular orbit component
    local perpComp = Vector3.new(-toEnemy.Unit.Z, 0, toEnemy.Unit.X) * JukeState.orbitDir

    -- Blend: 70% toward blind spot, 30% perpendicular orbit
    local blended = toBlind * 0.70 + perpComp * 0.30
    return blended.Magnitude > 0.01 and blended.Unit or toBlind
end

-- Execute one juke frame; returns true if juke was active
local function executeJuke(myPos, now)
    if not CFG.JukeEnabled then JukeState.active = false; return false end

    -- Find closest melee-range enemy
    local closestPlr   = nil
    local closestDist  = CFG.MeleeRange
    local closestEntry = nil

    for plr, entry in pairs(EntityRegistry) do
        if isEnemy(plr) and entry.health > 0 then
            local d = (entry.pos - myPos).Magnitude
            if d <= closestDist then
                closestDist  = d
                closestPlr   = plr
                closestEntry = entry
            end
        end
    end

    if not closestPlr then
        JukeState.active = false
        return false
    end

    -- (Re)initialise juke state
    if not JukeState.active or JukeState.targetPlayer ~= closestPlr then
        JukeState.active       = true
        JukeState.targetPlayer = closestPlr
        JukeState.orbitDir     = math.random() > 0.5 and 1 or -1
        JukeState.changeTimer  = now + 0.6
    end

    -- Periodically flip orbit direction (unpredictable)
    if now > JukeState.changeTimer then
        JukeState.orbitDir  = -JukeState.orbitDir
        JukeState.changeTimer = now + math.random() * 0.5 + 0.3
    end

    -- Enemy look vector from their HRP CFrame (character-facing, not camera)
    local eLook = closestEntry.lastCFrame.LookVector
    eLook = Vector3.new(eLook.X, 0, eLook.Z)
    eLook = eLook.Magnitude > 0.01 and eLook.Unit or Vector3.new(0, 0, 1)

    local jukeDir = computeJukeDir(myPos, closestEntry.pos, eLook)
    fireKeys(jukeDir)
    return true
end

-- ════════════════════════════════════════════════════════════════════════
--  §18  ANTI-STUCK SYSTEM
--  If character hasn't moved in StuckWindow seconds, juke direction
-- ════════════════════════════════════════════════════════════════════════
local stuckTracker = {
    lastPos        = Vector3.new(),
    lastMoveTime   = os.clock(),
    stuckTryDir    = nil,
    stuckTryStart  = 0,
}

local function updateStuck(hrpPos, moveDir, now)
    local disp = (hrpPos - stuckTracker.lastPos).Magnitude
    if disp > CFG.StuckThreshold then
        stuckTracker.lastPos      = hrpPos
        stuckTracker.lastMoveTime = now
        stuckTracker.stuckTryDir  = nil
        return false  -- not stuck
    end
    if now - stuckTracker.lastMoveTime > CFG.StuckWindow then
        -- Generate an escape direction perpendicular to intended movement
        if not stuckTracker.stuckTryDir then
            local perp = Vector3.new(-(moveDir or Vector3.new(0,0,1)).Z, 0, (moveDir or Vector3.new(0,0,1)).X)
            stuckTracker.stuckTryDir  = math.random() > 0.5 and perp or -perp
            stuckTracker.stuckTryStart = now
        end
        -- Try escape direction for 0.5 s then reassign
        if now - stuckTracker.stuckTryStart < 0.5 then
            fireKeys(stuckTracker.stuckTryDir)
            doJump()
            return true  -- stuck
        else
            stuckTracker.stuckTryDir  = nil
            stuckTracker.lastMoveTime = now  -- reset timer
        end
    end
    return false
end

-- ════════════════════════════════════════════════════════════════════════
--  §19  ESP  SYSTEM
-- ════════════════════════════════════════════════════════════════════════
local espHighlights = {}   -- [Player] = Highlight instance

local function removeESP(plr)
    if espHighlights[plr] then
        pcall(function() espHighlights[plr]:Destroy() end)
        espHighlights[plr] = nil
    end
end

local function createESP(plr)
    if plr == LocalPlayer then return end
    local char = plr.Character
    if not char then return end
    removeESP(plr)

    local hl = Instance.new("Highlight")
    hl.Name               = "MC_ESP_" .. plr.Name
    hl.Parent             = char
    hl.FillColor          = isEnemy(plr) and Color3.fromRGB(255, 38, 38) or Color3.fromRGB(38, 255, 80)
    hl.OutlineColor       = Color3.fromRGB(255, 255, 255)
    hl.FillTransparency   = 0.42
    hl.OutlineTransparency = 0
    hl.DepthMode          = Enum.HighlightDepthMode.AlwaysOnTop
    hl.Enabled            = CFG.ESPEnabled and isEnemy(plr)

    espHighlights[plr] = hl
end

local function refreshAllESP()
    for plr, hl in pairs(espHighlights) do
        if hl and hl.Parent then
            hl.Enabled   = CFG.ESPEnabled and isEnemy(plr)
            hl.FillColor = isEnemy(plr) and Color3.fromRGB(255, 38, 38) or Color3.fromRGB(38, 255, 80)
        end
    end
end

local function setupPlayerESP(plr)
    if plr == LocalPlayer then return end
    plr.CharacterAdded:Connect(function()
        task.wait(0.35)
        createESP(plr)
    end)
    plr.CharacterRemoving:Connect(function()
        task.wait(0.1)
        removeESP(plr)
    end)
    plr:GetPropertyChangedSignal("Team"):Connect(function()
        task.wait(0.1)
        createESP(plr)
    end)
    if plr.Character then
        task.spawn(function() task.wait(0.25); createESP(plr) end)
    end
end

for _, plr in ipairs(Players:GetPlayers()) do setupPlayerESP(plr) end
Players.PlayerAdded:Connect(setupPlayerESP)
Players.PlayerRemoving:Connect(removeESP)
LocalPlayer:GetPropertyChangedSignal("Team"):Connect(refreshAllESP)

-- ════════════════════════════════════════════════════════════════════════
--  §20  DIAGNOSTIC HUD
--  Draggable panel with per-system toggles, status labels, and reload bar.
-- ════════════════════════════════════════════════════════════════════════
local HUD = { ready = false }

task.spawn(function()
    local playerGui = LocalPlayer:WaitForChild("PlayerGui")

    -- Root ScreenGui
    local SG = Instance.new("ScreenGui")
    SG.Name           = "MC_HUD"
    SG.ResetOnSpawn   = false
    SG.ZIndexBehavior = Enum.ZIndexBehavior.Sibling
    SG.DisplayOrder   = 99
    SG.Parent         = playerGui

    -- FOV circle visual (shown at screen center)
    local fovRing = Instance.new("Frame")
    fovRing.Name                  = "FOVRing"
    fovRing.Size                  = UDim2.new(0, CFG.FOVRadius * 2, 0, CFG.FOVRadius * 2)
    fovRing.AnchorPoint           = Vector2.new(0.5, 0.5)
    fovRing.Position              = UDim2.new(0.5, 0, 0.5, 0)
    fovRing.BackgroundColor3      = Color3.fromRGB(255, 55, 55)
    fovRing.BackgroundTransparency = 0.88
    fovRing.BorderSizePixel       = 0
    fovRing.Parent                = SG
    Instance.new("UICorner", fovRing).CornerRadius = UDim.new(1, 0)
    HUD.fovRing = fovRing

    -- Reload progress bar background
    local rBarBG = Instance.new("Frame")
    rBarBG.Size                = UDim2.new(0, 170, 0, 7)
    rBarBG.AnchorPoint         = Vector2.new(0.5, 0)
    rBarBG.Position            = UDim2.new(0.5, 0, 0.5, 20)
    rBarBG.BackgroundColor3    = Color3.fromRGB(35, 35, 35)
    rBarBG.BackgroundTransparency = 0.25
    rBarBG.BorderSizePixel     = 0
    rBarBG.Visible             = false
    rBarBG.Parent              = SG
    Instance.new("UICorner", rBarBG).CornerRadius = UDim.new(0, 4)
    HUD.rBarBG = rBarBG

    local rBar = Instance.new("Frame")
    rBar.Size             = UDim2.new(0, 0, 1, 0)
    rBar.BackgroundColor3 = Color3.fromRGB(255, 200, 45)
    rBar.BorderSizePixel  = 0
    rBar.Parent           = rBarBG
    Instance.new("UICorner", rBar).CornerRadius = UDim.new(0, 4)
    HUD.rBar = rBar

    -- Main draggable panel
    local panel = Instance.new("Frame")
    panel.Name                  = "MCPanel"
    panel.Size                  = UDim2.new(0, 218, 0, 320)
    panel.Position              = UDim2.new(0, 14, 0, 14)
    panel.BackgroundColor3      = Color3.fromRGB(8, 8, 18)
    panel.BackgroundTransparency = 0.07
    panel.BorderSizePixel       = 0
    panel.Active                = true
    panel.Parent                = SG
    Instance.new("UICorner", panel).CornerRadius = UDim.new(0, 10)

    -- Title / drag-handle bar
    local titleBar = Instance.new("Frame")
    titleBar.Size             = UDim2.new(1, 0, 0, 28)
    titleBar.BackgroundColor3 = Color3.fromRGB(18, 18, 42)
    titleBar.BorderSizePixel  = 0
    titleBar.Parent           = panel
    Instance.new("UICorner", titleBar).CornerRadius = UDim.new(0, 10)

    local titleLbl = Instance.new("TextLabel")
    titleLbl.Size              = UDim2.new(1, -10, 1, 0)
    titleLbl.Position          = UDim2.new(0, 10, 0, 0)
    titleLbl.BackgroundTransparency = 1
    titleLbl.Text              = "⚡  MASTER CONTROLLER  v3.0"
    titleLbl.TextColor3        = Color3.fromRGB(140, 175, 255)
    titleLbl.TextScaled        = true
    titleLbl.Font              = Enum.Font.GothamBold
    titleLbl.TextXAlignment    = Enum.TextXAlignment.Left
    titleLbl.Parent            = titleBar

    -- Helper: create a labelled toggle row at yOffset
    local function makeToggle(yOff, labelText, initState, onToggle)
        local row = Instance.new("Frame")
        row.Size                = UDim2.new(1, -16, 0, 30)
        row.Position            = UDim2.new(0, 8, 0, yOff)
        row.BackgroundTransparency = 1
        row.Parent              = panel

        local lbl = Instance.new("TextLabel")
        lbl.Size                = UDim2.new(0, 130, 1, 0)
        lbl.BackgroundTransparency = 1
        lbl.Text                = labelText
        lbl.TextColor3          = Color3.fromRGB(195, 195, 210)
        lbl.TextScaled          = true
        lbl.Font                = Enum.Font.Gotham
        lbl.TextXAlignment      = Enum.TextXAlignment.Left
        lbl.Parent              = row

        local btn = Instance.new("TextButton")
        btn.Size             = UDim2.new(0, 52, 0, 21)
        btn.Position         = UDim2.new(1, -52, 0.5, -10)
        btn.Text             = initState and "ON" or "OFF"
        btn.TextColor3       = Color3.new(1, 1, 1)
        btn.TextScaled       = true
        btn.Font             = Enum.Font.GothamBold
        btn.BackgroundColor3 = initState and Color3.fromRGB(0, 195, 75) or Color3.fromRGB(195, 45, 45)
        btn.BorderSizePixel  = 0
        btn.Parent           = row
        Instance.new("UICorner", btn).CornerRadius = UDim.new(0, 5)

        btn.MouseButton1Click:Connect(function()
            local newState = onToggle()
            btn.Text             = newState and "ON" or "OFF"
            btn.BackgroundColor3 = newState and Color3.fromRGB(0, 195, 75) or Color3.fromRGB(195, 45, 45)
        end)
        return btn
    end

    -- Helper: create a status text label
    local function makeStatus(yOff, color)
        local lbl = Instance.new("TextLabel")
        lbl.Size                = UDim2.new(1, -16, 0, 17)
        lbl.Position            = UDim2.new(0, 8, 0, yOff)
        lbl.BackgroundTransparency = 1
        lbl.TextColor3          = color or Color3.fromRGB(145, 145, 165)
        lbl.TextScaled          = true
        lbl.Font                = Enum.Font.Gotham
        lbl.TextXAlignment      = Enum.TextXAlignment.Left
        lbl.Text                = ""
        lbl.Parent              = panel
        return lbl
    end

    -- Toggle rows
    local y = 32
    local rH = 33

    makeToggle(y, "Auto Navigate", CFG.AutoNavEnabled, function()
        CFG.AutoNavEnabled = not CFG.AutoNavEnabled
        if not CFG.AutoNavEnabled then releaseAll() end
        return CFG.AutoNavEnabled
    end); y = y + rH

    makeToggle(y, "Auto Aim", CFG.AutoAimEnabled, function()
        CFG.AutoAimEnabled = not CFG.AutoAimEnabled
        return CFG.AutoAimEnabled
    end); y = y + rH

    makeToggle(y, "Auto Shoot", CFG.AutoShootEnabled, function()
        CFG.AutoShootEnabled = not CFG.AutoShootEnabled
        return CFG.AutoShootEnabled
    end); y = y + rH

    makeToggle(y, "Knife Dodge", CFG.DodgeEnabled, function()
        CFG.DodgeEnabled = not CFG.DodgeEnabled
        return CFG.DodgeEnabled
    end); y = y + rH

    makeToggle(y, "Melee Juke", CFG.JukeEnabled, function()
        CFG.JukeEnabled = not CFG.JukeEnabled
        return CFG.JukeEnabled
    end); y = y + rH

    makeToggle(y, "ESP", CFG.ESPEnabled, function()
        CFG.ESPEnabled = not CFG.ESPEnabled
        refreshAllESP()
        return CFG.ESPEnabled
    end); y = y + rH

    -- Separator
    local sep = Instance.new("Frame")
    sep.Size             = UDim2.new(0.88, 0, 0, 1)
    sep.Position         = UDim2.new(0.06, 0, 0, y + 2)
    sep.BackgroundColor3 = Color3.fromRGB(55, 55, 75)
    sep.BorderSizePixel  = 0
    sep.Parent           = panel
    y = y + 9

    -- Status labels
    HUD.lblAction  = makeStatus(y, Color3.fromRGB(145, 145, 175)); y = y + 20
    HUD.lblTarget  = makeStatus(y);                                  y = y + 20
    HUD.lblThreats = makeStatus(y, Color3.fromRGB(255, 90, 90));     y = y + 20
    HUD.lblHP      = makeStatus(y, Color3.fromRGB(90, 220, 90));     y = y + 20
    HUD.lblPing    = makeStatus(y);                                   y = y + 20
    HUD.lblReload  = makeStatus(y);                                   y = y + 20
    HUD.lblWeights = makeStatus(y, Color3.fromRGB(90, 190, 90))

    -- Drag logic
    local dragging   = false
    local dragStart  = nil
    local panelStart = nil

    titleBar.InputBegan:Connect(function(inp)
        if inp.UserInputType == Enum.UserInputType.MouseButton1
        or inp.UserInputType == Enum.UserInputType.Touch then
            dragging   = true
            dragStart  = inp.Position
            panelStart = panel.Position
            inp.Changed:Connect(function()
                if inp.UserInputState == Enum.UserInputState.End then
                    dragging = false
                end
            end)
        end
    end)

    UserInputService.InputChanged:Connect(function(inp)
        if not dragging then return end
        if inp.UserInputType == Enum.UserInputType.MouseMovement
        or inp.UserInputType == Enum.UserInputType.Touch then
            local d = inp.Position - dragStart
            panel.Position = UDim2.new(
                panelStart.X.Scale, panelStart.X.Offset + d.X,
                panelStart.Y.Scale, panelStart.Y.Offset + d.Y
            )
        end
    end)

    HUD.panel = panel
    HUD.ready = true
end)

-- Per-frame HUD refresh (throttled to every 8 frames)
local hudTickCount = 0
local function refreshHUD(action, targetName, threatCount, hpVal, maxHpVal)
    hudTickCount = hudTickCount + 1
    if hudTickCount % 8 ~= 0 then return end
    if not HUD.ready then return end

    -- Action label with colour coding
    if HUD.lblAction then
        local txt, col
        if     action == "dodge"       then txt = "⚡ DODGE";     col = Color3.fromRGB(80, 255, 80)
        elseif action == "juke"        then txt = "🔄 JUKE";      col = Color3.fromRGB(255, 155, 50)
        elseif action == "engage"      then txt = "🎯 ENGAGE";    col = Color3.fromRGB(255, 75, 75)
        elseif action == "retreat"     then txt = "← RETREAT";    col = Color3.fromRGB(100, 185, 255)
        elseif action == "navigate"    then txt = "▶ NAVIGATE";   col = Color3.fromRGB(210, 210, 90)
        elseif action == "wait_reload" then txt = "↺ RELOAD";     col = Color3.fromRGB(255, 220, 50)
        else                                txt = "◉ IDLE";       col = Color3.fromRGB(130, 130, 150)
        end
        HUD.lblAction.Text       = txt
        HUD.lblAction.TextColor3 = col
    end

    if HUD.lblTarget  then HUD.lblTarget.Text  = "Target  : " .. (targetName or "—") end
    if HUD.lblThreats then
        HUD.lblThreats.Text       = "Threats : " .. (threatCount or 0)
        HUD.lblThreats.TextColor3 = (threatCount and threatCount > 0)
            and Color3.fromRGB(255, 75, 75) or Color3.fromRGB(145, 145, 165)
    end
    if HUD.lblHP then
        local hpRatio = (hpVal or 100) / math.max(maxHpVal or 100, 1)
        HUD.lblHP.Text       = string.format("HP      : %d / %d", hpVal or 0, maxHpVal or 100)
        HUD.lblHP.TextColor3 = hpRatio < 0.35
            and Color3.fromRGB(255, 80, 80)
            or  Color3.fromRGB(80, 225, 90)
    end
    if HUD.lblPing   then
        HUD.lblPing.Text   = string.format("Ping    : %d ms", math.floor(estimatedPing * 1000))
    end
    if HUD.lblReload then
        local rPct = math.floor(getReloadFraction() * 100)
        HUD.lblReload.Text       = string.format("Reload  : %d %%", rPct)
        HUD.lblReload.TextColor3 = rPct < 25
            and Color3.fromRGB(255, 75, 75) or Color3.fromRGB(100, 225, 100)
    end
    if HUD.lblWeights then
        HUD.lblWeights.Text = string.format(
            "w[e=%.2f d=%.2f j=%.2f n=%.2f]",
            Brain.w.engage, Brain.w.dodge, Brain.w.juke, Brain.w.navigate
        )
    end

    -- Reload bar visibility
    if HUD.rBarBG and HUD.rBar then
        if reloadActive then
            HUD.rBarBG.Visible = true
            HUD.rBar.Size = UDim2.new(getReloadFraction(), 0, 1, 0)
        else
            HUD.rBarBG.Visible = false
        end
    end
end

-- ════════════════════════════════════════════════════════════════════════
--  §21  MAIN LOOP STATE VARIABLES
-- ════════════════════════════════════════════════════════════════════════
local dodgeActive      = false
local extraActive      = false
local extraDir         = Vector3.new(1, 0, 0)
local extraTargetPos   = nil
local extraStartTime   = 0
local lastMoveDir      = Vector3.new(1, 0, 0)

local currentAction    = "idle"
local currentTarget    = nil
local currentAimPoint  = nil

local prevLocalHP      = 100
local prevEnemyHPMap   = {}

local clockPingUpdate   = 0
local clockEntityUpdate = 0
local clockMCTS         = 0
local frameCount        = 0
local lastFrameTime     = os.clock()

-- ════════════════════════════════════════════════════════════════════════
--  §22  MAIN RENDER-STEPPED LOOP
-- ════════════════════════════════════════════════════════════════════════
RunService.RenderStepped:Connect(function()
    local now = os.clock()
    local dt  = math.clamp(now - lastFrameTime, 0.001, 0.10)
    lastFrameTime = now
    frameCount    = frameCount + 1

    -- ── §22.1  Projectile velocity refinement ─────────────────────────
    updateProjectileVelocities(dt)

    -- ── §22.2  Character validity ─────────────────────────────────────
    local char = LocalPlayer.Character
    if not char then releaseAll(); return end
    local hrp = char:FindFirstChild("HumanoidRootPart")
    if not hrp then releaseAll(); return end

    -- Ensure cache is valid
    if not charHRP or charHRP.Parent ~= char or #charParts == 0 then
        rebuildCharCache(char)
    end

    local hrpPos    = hrp.Position
    local feetY     = getFeetY()
    local myHP, myMaxHP = getLocalHP()

    -- ── §22.3  Periodic: ping + entity registry ────────────────────────
    if now - clockPingUpdate > 2.0 then
        clockPingUpdate = now
        task.spawn(updatePingEstimate)
    end

    if now - clockEntityUpdate > 0.05 then
        clockEntityUpdate = now
        for _, plr in ipairs(Players:GetPlayers()) do
            if plr ~= LocalPlayer and isEnemy(plr) then
                registryUpdate(plr, dt)
            end
        end
    end

    -- ── §22.4  Threat detection (knives / projectiles) ─────────────────
    local threats = {}
    for _, part in ipairs(projList) do
        local data = projData[part]
        if data and part.Parent then
            local th = evalProjectileThreat(part.Position, data.vel, hrpPos, feetY)
            if th then threats[#threats + 1] = th end
        end
    end
    if #threats > 1 then
        table.sort(threats, function(a, b) return a.t < b.t end)
    end

    -- ── §22.5  Visibility scan for all tracked enemies ─────────────────
    local originPos = Camera.CFrame.Position
    for plr, entry in pairs(EntityRegistry) do
        if isEnemy(plr) and plr.Character then
            local vis, total, frac, _ = atomicLoS(plr.Character, originPos)
            entry.wasVisible  = entry.isVisible
            entry.isVisible   = frac >= CFG.WallCheckStrict
            entry.visFraction = frac
        end
    end

    -- ── §22.6  Aim target selection ────────────────────────────────────
    if CFG.AutoAimEnabled then
        local aimPlr, aimPt = selectAimTarget()
        if aimPlr and aimPt then
            currentTarget   = aimPlr
            currentAimPoint = aimPt
        elseif not currentTarget then
            -- No aim target: try closest enemy in registry
            local cp, ce, cd = getClosestEnemyToPos(hrpPos)
            if cp then currentTarget = cp end
        end
    end

    -- Validate currentTarget is still alive
    if currentTarget then
        local ce = EntityRegistry[currentTarget]
        if not ce or ce.health <= 0 or not currentTarget.Character then
            currentTarget   = nil
            currentAimPoint = nil
        end
    end

    -- ── §22.7  Brain decision ──────────────────────────────────────────
    local targetEntry = currentTarget and EntityRegistry[currentTarget]
    local targetDist  = targetEntry and (targetEntry.pos - hrpPos).Magnitude or 999
    local inMelee     = targetDist <= CFG.MeleeRange
    local visFrac     = targetEntry and (targetEntry.visFraction or 0) or 0
    local hasLoS      = visFrac >= CFG.WallCheckStrict

    local ctx = {
        health       = myHP,
        maxHealth    = myMaxHP,
        targetDist   = targetDist,
        hasLoS       = hasLoS,
        visFraction  = visFrac,
        threatCount  = #threats,
        isReloading  = reloadActive,
        inMeleeRange = inMelee,
        hasTarget    = currentTarget ~= nil,
        targetHP     = targetEntry and targetEntry.health or 0,
    }

    local action, _ = brainDecide(ctx)
    currentAction   = action

    -- ── §22.8  Reward computation (online learning) ────────────────────
    local hpDelta = myHP - prevLocalHP
    if hpDelta < -2 then
        -- We took damage — penalise whatever action just ran
        brainReward(-1.2)
    elseif hpDelta > 0 then
        -- Healed / no damage — mild positive
        brainReward(0.15)
    end

    if currentTarget and targetEntry then
        local prevEHP = prevEnemyHPMap[currentTarget] or targetEntry.health
        local enemyDelta = targetEntry.health - prevEHP
        if enemyDelta < -2 then
            -- We hit the enemy — reward engage
            brainReward(1.6)
            Brain.w.engage = Brain.w.engage + CFG.LearningRate * 0.5
            Brain.w.engage = math.min(Brain.w.engage, CFG.WeightClampHi)
        end
        prevEnemyHPMap[currentTarget] = targetEntry.health
    end
    prevLocalHP = myHP

    -- ── §22.9  ACTION EXECUTION ────────────────────────────────────────

    -- ─ DODGE ─────────────────────────────────────────────────────────
    if action == "dodge" and CFG.DodgeEnabled and #threats > 0 then
        local dodgeDir = computeBestDodge(hrpPos, threats)
        if dodgeDir then
            dodgeActive = true
            lastMoveDir = dodgeDir
            fireKeys(dodgeDir)

            -- Gravity-aware jump: if knife is aimed at foot height
            for i = 1, math.min(2, #threats) do
                if threats[i].needJump then doJump(); break end
            end
        end
        extraActive    = false
        extraTargetPos = nil

        -- Dodge does NOT stop aiming/shooting
        if CFG.AutoAimEnabled and currentAimPoint then
            applyAim(currentAimPoint)
            if CFG.AutoShootEnabled and canShoot() and hasLoS then
                doShoot()
            end
        end

    -- ─ JUKE ──────────────────────────────────────────────────────────
    elseif action == "juke" and CFG.JukeEnabled and inMelee then
        dodgeActive = false
        extraActive = false
        executeJuke(hrpPos, now)

        -- Keep aiming at enemy while the character jukes
        if CFG.AutoAimEnabled and currentAimPoint then
            applyAim(currentAimPoint)
        end

    -- ─ ENGAGE ────────────────────────────────────────────────────────
    elseif action == "engage" and currentAimPoint then
        dodgeActive = false

        -- Pixel-perfect aim snap (instant bullet = direct snap to predicted point)
        if CFG.AutoAimEnabled then
            applyAim(currentAimPoint)
        end

        -- Shoot if loaded
        if CFG.AutoShootEnabled and canShoot() and hasLoS then
            doShoot()
        end

        -- While engaging: close distance if too far, strafe if in range
        if CFG.AutoNavEnabled and targetDist > CFG.EngageMoveRange then
            if now - clockMCTS > CFG.MCTSInterval then
                clockMCTS = now
                local dir = mctsSearch(hrpPos, targetEntry.pos, CFG.MCTSSimulations)
                if dir then
                    lastMoveDir             = dir
                    MCTSCache.bestDirection = dir
                end
            end
            if MCTSCache.bestDirection then
                local mvDir = MCTSCache.bestDirection
                local yc, cls = getYCorrectionForDir(hrpPos, mvDir)
                if cls == "ledge" then
                    -- Skirt the edge
                    local alt = Vector3.new(-mvDir.Z, 0, mvDir.X)
                    fireKeys(alt)
                elseif shouldJumpForObstacle(yc, cls) then
                    fireKeys(mvDir)
                    doJump()
                else
                    fireKeys(mvDir)
                end
            end
        elseif CFG.AutoNavEnabled and targetDist <= CFG.EngageMoveRange then
            -- In optimal range: strafing side-to-side to be harder to hit
            local strafeDir = Vector3.new(-lastMoveDir.Z, 0, lastMoveDir.X)
                            * (math.sin(now * 2.8) > 0 and 1 or -1)
            fireKeys(strafeDir)
        end

    -- ─ RETREAT ───────────────────────────────────────────────────────
    elseif action == "retreat" then
        dodgeActive = false

        -- Compute composite retreat direction (away from all enemies)
        local retreatDir = Vector3.new()
        for plr, entry in pairs(EntityRegistry) do
            if isEnemy(plr) and entry.health > 0 then
                local away = hrpPos - entry.pos
                away = Vector3.new(away.X, 0, away.Z)
                if away.Magnitude > 0.01 then
                    retreatDir = retreatDir + away.Unit / (away.Magnitude + 0.5)
                end
            end
        end
        if retreatDir.Magnitude > 0.01 then
            retreatDir  = retreatDir.Unit
            lastMoveDir = retreatDir
            fireKeys(retreatDir)
        end

        -- Continue aiming while retreating (can shoot during retreat)
        if CFG.AutoAimEnabled and currentAimPoint then
            applyAim(currentAimPoint)
            if CFG.AutoShootEnabled and canShoot() and hasLoS then
                doShoot()
            end
        end

    -- ─ WAIT / RELOAD ─────────────────────────────────────────────────
    elseif action == "wait_reload" then
        dodgeActive = false
        --Evasive lateral movement during reload window
local strafeDir = Vector3.new(-lastMoveDir.Z, 0, lastMoveDir.X)
* (math.sin(now * 3.2) > 0 and 1 or -1)
fireKeys(strafeDir)
-- Keep aim locked during reload
    if CFG.AutoAimEnabled and currentAimPoint then
        applyAim(currentAimPoint)
    end

-- ─ NAVIGATE ──────────────────────────────────────────────────────
elseif action == "navigate" and CFG.AutoNavEnabled then
    dodgeActive = false

    local goalPos = nil
    if currentTarget and targetEntry then
        goalPos = predictEnemyPosition(currentTarget, 0)
    end

    if goalPos then
        if now - clockMCTS > CFG.MCTSInterval then
            clockMCTS = now
            local dir = mctsSearch(hrpPos, goalPos, CFG.MCTSSimulations)
            if dir then
                lastMoveDir             = dir
                MCTSCache.bestDirection = dir
                MCTSCache.goalPos       = goalPos
            end
        end

        local mvDir = MCTSCache.bestDirection
        if mvDir then
            local yc, cls = getYCorrectionForDir(hrpPos, mvDir)
            if cls == "ledge" then
                local alt = Vector3.new(-mvDir.Z, 0, mvDir.X)
                fireKeys(alt)
            elseif shouldJumpForObstacle(yc, cls) then
                fireKeys(mvDir)
                doJump()
            else
                fireKeys(mvDir)
            end

            -- Anti-stuck injection
            updateStuck(hrpPos, mvDir, now)
        end
    else
        -- No target: hold position
        releaseAll()
    end

-- ─ IDLE ──────────────────────────────────────────────────────────
else
    dodgeActive = false
    if not extraActive then releaseAll() end
end

-- ── §22.10  Extra-burst momentum after dodge ───────────────────────
if dodgeActive == false then
    -- If just exited dodge, arm the burst
    if extraActive then
        local target = extraTargetPos or (hrpPos + extraDir * CFG.ExtraBurstDistance)
        local horiz  = Vector3.new(hrpPos.X, 0, hrpPos.Z)
        local tH     = Vector3.new(target.X,  0, target.Z)
        if (horiz - tH).Magnitude > 0.35 and now < extraStartTime + CFG.ExtraMaxBurstTime then
            fireKeys(extraDir)
        else
            extraActive    = false
            extraTargetPos = nil
        end
    end
else
    -- Arm burst for next cycle
    extraActive    = true
    extraDir       = lastMoveDir
    extraTargetPos = hrpPos + lastMoveDir * CFG.ExtraBurstDistance
    extraStartTime = now
end

-- ── §22.11  HUD refresh ────────────────────────────────────────────
local tName = currentTarget and currentTarget.Name or nil
refreshHUD(currentAction, tName, #threats, myHP, myMaxHP)
end)
-- ════════════════════════════════════════════════════════════════════════
--  §23  CHARACTER RESPAWN HANDLER
-- ════════════════════════════════════════════════════════════════════════
local function onCharAdded(char)
task.wait(0.2)
rebuildCharCache(char)
dodgeActive    = false
extraActive    = false
extraTargetPos = nil
currentTarget  = nil
currentAimPoint = nil
MCTSCache.bestDirection = nil
JukeState.active = false
releaseAll()
-- Re-apply camera to custom to ensure aim control
Camera.CameraType = Enum.CameraType.Custom
end
LocalPlayer.CharacterAdded:Connect(onCharAdded)
if LocalPlayer.Character then
task.spawn(function()
task.wait(0.1)
rebuildCharCache(LocalPlayer.Character)
end)
end
-- ════════════════════════════════════════════════════════════════════════
--  §24  PLAYER REGISTRY EVENTS  — keep entity table clean
-- ════════════════════════════════════════════════════════════════════════
Players.PlayerAdded:Connect(function(plr)
setupPlayerESP(plr)
plr.CharacterAdded:Connect(function()
task.wait(0.1)
registryEnsure(plr)
end)
plr.CharacterRemoving:Connect(function()
EntityRegistry[plr] = nil
end)
end)
Players.PlayerRemoving:Connect(function(plr)
EntityRegistry[plr] = nil
removeESP(plr)
prevEnemyHPMap[plr] = nil
end)
for _, plr in ipairs(Players:GetPlayers()) do
if plr ~= LocalPlayer then
plr.CharacterAdded:Connect(function()
task.wait(0.1)
registryEnsure(plr)
end)
plr.CharacterRemoving:Connect(function()
EntityRegistry[plr] = nil
end)
if plr.Character then
registryEnsure(plr)
end
end
end