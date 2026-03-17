-- ════════════════════════════════════════════════════════════════════════
--  §1  SERVICES
-- ════════════════════════════════════════════════════════════════════════
local Players             = game:GetService("Players")
local RunService          = game:GetService("RunService")
local UserInputService    = game:GetService("UserInputService")
local VirtualInputManager = game:GetService("VirtualInputManager")
local Workspace           = game:GetService("Workspace")

local LocalPlayer = Players.LocalPlayer
local Camera      = Workspace.CurrentCamera
local isMobile    = UserInputService.TouchEnabled and not UserInputService.KeyboardEnabled

-- ════════════════════════════════════════════════════════════════════════
--  §2  MASTER CONFIG
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
    DetectionRange      = 999,
    MaxEngageRange      = 340,
    MeleeRange          = 5.2,
    EngageMoveRange     = 14,

    -- ── Combat ──────────────────────────────────────────────────────────
    -- Bullets: INSTANT + LINEAR — zero gravity, zero travel time.
    -- Aim directly at part.Position.  No lead, no prediction.
    ReloadTime          = 2.50,      -- seconds (changed from 3.75 → 2.50)

    -- ── Movement ────────────────────────────────────────────────────────
    WalkSpeed           = 16,
    JumpCooldown        = 0.15,
    JumpHeightThreshold = 4.5,
    KeyThreshold        = 0.02,
    StuckWindow         = 1.8,
    StuckThreshold      = 0.35,

    -- ── MCTS Navigation ─────────────────────────────────────────────────
    MCTSInterval        = 0.40,
    MCTSSimulations     = 14,
    MCTSDepth           = 6,
    MCTSStepSize        = 4.0,

    -- ── Dodge ───────────────────────────────────────────────────────────
    MinProjectileSpeed  = 0.10,
    FutureLookAhead     = 2.20,
    DotFacingThreshold  = 0.00,
    SweepDirs           = 128,
    ExtraBurstDistance  = 9.0,
    ExtraMaxBurstTime   = 0.45,
    HitboxPadding       = 6.5,
    SafeMarginMult      = 1.55,

    -- ── Wall check (low-medium strictness) ──────────────────────────────
    WallCheckPoints     = 12,
    WallCheckStrict     = 0.42,      -- 42% of 12 points must be clear

    -- ── Learning ────────────────────────────────────────────────────────
    LearningRate        = 0.026,
    WeightClampLo       = 0.10,
    WeightClampHi       = 4.20,

    -- ── Enemy filter ────────────────────────────────────────────────────
    EnemyKeyword        = "murder",  -- case-insensitive substring
}

-- ════════════════════════════════════════════════════════════════════════
--  §3  PRE-COMPUTED SWEEP DIRECTIONS  (128 flat unit vectors)
-- ════════════════════════════════════════════════════════════════════════
local SWEEP = {}
for _i = 0, CFG.SweepDirs - 1 do
    local a = (_i / CFG.SweepDirs) * math.pi * 2
    SWEEP[_i + 1] = Vector3.new(math.cos(a), 0, math.sin(a))
end

-- ════════════════════════════════════════════════════════════════════════
--  §4  VIM KEY MANAGEMENT
-- ════════════════════════════════════════════════════════════════════════
local KC = {
    W = Enum.KeyCode.W, A = Enum.KeyCode.A,
    S = Enum.KeyCode.S, D = Enum.KeyCode.D,
    Space = Enum.KeyCode.Space,
}
local keyState = { W=false, A=false, S=false, D=false }

local function sendKey(down, key)
    pcall(VirtualInputManager.SendKeyEvent, VirtualInputManager, down, key, false, game)
end

local function releaseAll()
    for n, pressed in pairs(keyState) do
        if pressed then sendKey(false, KC[n]); keyState[n] = false end
    end
end

-- fireKeys: world-space XZ direction → camera-relative WASD.
-- Movement is ALWAYS camera-relative (camera is the reference frame).
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

-- Orient camera to face a world-space direction (for navigation).
-- Only the yaw (horizontal) component is adjusted so pitch stays natural.
local function setCameraFacing(worldDir)
    if not worldDir or worldDir.Magnitude < 0.01 then return end
    local flat = Vector3.new(worldDir.X, 0, worldDir.Z)
    if flat.Magnitude < 0.001 then return end
    flat = flat.Unit
    local camPos = Camera.CFrame.Position
    -- Preserve camera height offset while pointing horizontally
    local lookTarget = camPos + flat
    -- Blend: 30% correction per frame so it pans smoothly, not snap
    local currentLook = Camera.CFrame.LookVector
    local blended     = (currentLook + flat * 0.30)
    if blended.Magnitude > 0.001 then
        Camera.CFrame = CFrame.new(camPos, camPos + blended.Unit)
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
--  §5  PING  —  GetNetworkPing() * 2  (round-trip, seconds)
--  LocalPlayer:GetNetworkPing() returns ONE-WAY trip in seconds.
--  Multiply by 2 to match the Shift+F3 displayed round-trip value.
--  We store it in seconds for internal use; display in ms.
-- ════════════════════════════════════════════════════════════════════════
local estimatedPingSeconds = 0.065   -- initial fallback (65 ms)

local function updatePing()
    local ok, val = pcall(function()
        return LocalPlayer:GetNetworkPing()   -- returns seconds, one-way
    end)
    if ok and type(val) == "number" and val > 0 then
        -- Round-trip = one-way * 2; smooth with 20% new sample weight
        local rtt = val * 2
        estimatedPingSeconds = estimatedPingSeconds * 0.80 + rtt * 0.20
    end
end

-- ════════════════════════════════════════════════════════════════════════
--  §6  AUTO-SHOOT SYSTEM
--  Reload time = 2.5 seconds exactly.
--  Firing simulates left-mouse click at viewport centre via VIM.
-- ════════════════════════════════════════════════════════════════════════
local lastShotTime = -999
local reloadActive = false

local function canShoot()
    return (os.clock() - lastShotTime) >= CFG.ReloadTime
end

local function getReloadFraction()
    return math.min(1.0, (os.clock() - lastShotTime) / CFG.ReloadTime)
end

local function doShoot()
    if not CFG.AutoShootEnabled then return false end
    if not canShoot()           then return false end

    local vp = Camera.ViewportSize
    local cx = math.floor(vp.X * 0.5)
    local cy = math.floor(vp.Y * 0.5)

    pcall(function()
        VirtualInputManager:SendMouseButtonEvent(cx, cy, 0, true,  game, 1)
    end)
    task.delay(0.033, function()
        pcall(function()
            VirtualInputManager:SendMouseButtonEvent(cx, cy, 0, false, game, 1)
        end)
    end)

    lastShotTime = os.clock()
    reloadActive = true
    task.delay(CFG.ReloadTime, function() reloadActive = false end)
    return true
end

-- ════════════════════════════════════════════════════════════════════════
--  §7  ENEMY IDENTIFICATION
--  Primary   : team name contains "murder" (case-insensitive)
--  Secondary : different teams
--  Fallback  : everyone if no team system
-- ════════════════════════════════════════════════════════════════════════
local function isEnemy(plr)
    if not plr or plr == LocalPlayer then return false end
    if not plr.Parent then return false end
    if plr.Team then
        if plr.Team.Name:lower():find(CFG.EnemyKeyword) then return true end
    end
    if LocalPlayer.Team and plr.Team then
        return plr.Team ~= LocalPlayer.Team
    end
    if not plr.Team and not LocalPlayer.Team then return true end
    return false
end

-- ════════════════════════════════════════════════════════════════════════
--  §8  GLOBAL ENTITY REGISTRY
-- ════════════════════════════════════════════════════════════════════════
local PEEK_HISTORY_CAP = 24
local EntityRegistry   = {}

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

local function registryUpdate(plr, dt)
    local char = plr.Character
    if not char then return end
    local hrp = char:FindFirstChild("HumanoidRootPart")
    local hum = char:FindFirstChildOfClass("Humanoid")
    if not hrp or not hum then return end

    local entry  = registryEnsure(plr)
    local oldPos = entry.pos
    local newPos = hrp.Position

    local posVel = dt > 0 and (newPos - oldPos) / dt or entry.vel
    local rbxVel = hrp.AssemblyLinearVelocity
    entry.vel    = entry.vel * 0.50 + posVel * 0.30 + rbxVel * 0.20
    entry.avgVel = entry.avgVel * 0.90 + entry.vel * 0.10

    entry.pos        = newPos
    entry.lastCFrame = hrp.CFrame
    entry.lastSeen   = os.clock()

    entry.prevHealth = entry.health
    entry.health     = hum.Health
    entry.maxHealth  = hum.MaxHealth
    if entry.health < entry.prevHealth - 0.5 then
        entry.damageTaken = entry.damageTaken + (entry.prevHealth - entry.health)
    end

    local ph = entry.peekHistory
    ph[#ph + 1] = { pos = newPos, t = os.clock(),
                    vel = Vector3.new(entry.vel.X, 0, entry.vel.Z) }
    if #ph > PEEK_HISTORY_CAP then table.remove(ph, 1) end

    local parts = {}
    for _, p in ipairs(char:GetDescendants()) do
        if p:IsA("BasePart") then parts[#parts + 1] = p end
    end
    entry.hitboxParts = parts

    entry.wasVisible = entry.isVisible
end

-- Peek prediction: return last-known position or predicted re-emergence point.
-- NOTE: prediction is for MOVEMENT/NAVIGATION only — NOT for aim (direct snap).
local function predictEnemyPosition(plr, t)
    local entry = EntityRegistry[plr]
    if not entry then return nil end
    local now   = os.clock()
    local stale = now - entry.lastSeen
    if stale > 5.0 then
        return entry.predictedPeekPos or entry.pos
    end
    -- Movement prediction for navigation only (t = small lookahead)
    local predicted = entry.pos + entry.vel * t
    if not entry.isVisible and entry.wasVisible then
        local ph = entry.peekHistory
        if #ph >= 6 then
            local recent  = ph[#ph]
            local older   = ph[math.max(1, #ph - 6)]
            local ingress = recent.pos - older.pos
            if ingress.Magnitude > 0.4 then
                entry.predictedPeekPos = entry.pos - ingress.Unit * 1.8
            end
        end
        if entry.predictedPeekPos then return entry.predictedPeekPos end
    end
    return predicted
end

local function getClosestEnemyToPos(fromPos)
    local bestPlr, bestEntry, bestDist = nil, nil, math.huge
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
--  §9  LOCAL CHARACTER CACHE
-- ════════════════════════════════════════════════════════════════════════
local charParts  = {}
local charFeet   = {}
local charHRP    = nil
local charHuman  = nil

local HITBOX_NAMES = {
    "Head","UpperTorso","LowerTorso","HumanoidRootPart","Torso",
    "Left Arm","Right Arm","Left Leg","Right Leg",
    "LeftUpperArm","RightUpperArm","LeftLowerArm","RightLowerArm",
    "LeftHand","RightHand","LeftUpperLeg","RightUpperLeg",
    "LeftLowerLeg","RightLowerLeg","LeftFoot","RightFoot",
}
local FEET_NAMES = {
    "LeftFoot","RightFoot","LeftLowerLeg","RightLowerLeg",
    "Left Leg","Right Leg","LowerTorso",
}

local function rebuildCharCache(char)
    charParts, charFeet = {}, {}
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

    local checkOrder = {
        "Head","UpperTorso","Torso","HumanoidRootPart","LowerTorso",
        "LeftUpperArm","RightUpperArm","LeftUpperLeg","RightUpperLeg",
        "LeftHand","RightHand","LeftFoot",
    }

    local checkPoints = {}
    for _, name in ipairs(checkOrder) do
        local p = targetChar:FindFirstChild(name)
        if p and p:IsA("BasePart") then
            checkPoints[#checkPoints + 1] = {
                pos = p.Position, part = p, priority = #checkPoints + 1
            }
        end
        if #checkPoints >= 12 then break end
    end
    if #checkPoints < 12 then
        for _, p in ipairs(targetChar:GetDescendants()) do
            if p:IsA("BasePart") then
                checkPoints[#checkPoints + 1] = {
                    pos = p.Position, part = p, priority = #checkPoints + 1
                }
            end
            if #checkPoints >= 12 then break end
        end
    end

    local visCount = 0
    local bestPt   = nil
    local bestPri  = math.huge

    for i, cp in ipairs(checkPoints) do
        if i > 12 then break end
        local dir    = cp.pos - originPos
        local result = Workspace:Raycast(originPos, dir, params)
        local hit    = result and result.Instance
        local visible = (result == nil)
            or (hit and hit:IsDescendantOf(targetChar))
        if visible then
            visCount = visCount + 1
            if cp.priority < bestPri then
                bestPri = cp.priority
                bestPt  = cp.pos
            end
        end
    end

    local total = math.min(#checkPoints, 12)
    return visCount, total, visCount / math.max(total, 1), bestPt
end

-- ════════════════════════════════════════════════════════════════════════
--  §11  PART-AWARE NAVIGATION  (trusses, ramps, wedges, ledges)
-- ════════════════════════════════════════════════════════════════════════
local function classifyPart(part)
    if not part or not part:IsA("BasePart") then return nil end
    if part:IsA("TrussPart")       then return "truss"    end
    if part:IsA("WedgePart")       then return "ramp"     end
    if part:IsA("CornerWedgePart") then return "ramp"     end
    if part.Size.Y < 1.5           then return "floor"    end
    return "obstacle"
end

local function getYCorrectionForDir(hrpPos, moveDir)
    if not charHRP then return 0, nil end
    local myChar = LocalPlayer.Character
    local params = RaycastParams.new()
    params.FilterType = Enum.RaycastFilterType.Blacklist
    params.FilterDescendantsInstances = myChar and { myChar } or {}

    local checkDist = 3.4
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
            if cls == "truss"    then return delta + 0.6,        "truss"    end
            if cls == "ramp"     then return math.max(0, delta * 0.4), "ramp" end
            if cls == "obstacle" then
                return delta, delta <= CFG.JumpHeightThreshold and "step" or "wall"
            end
        end
    end

    -- Ledge detection
    local groundHere  = Workspace:Raycast(
        hrpPos + Vector3.new(0,-0.2,0), Vector3.new(0,-8,0), params)
    local groundAhead = Workspace:Raycast(
        hrpPos + moveDir * 2.5 + Vector3.new(0,-0.2,0), Vector3.new(0,-8,0), params)
    if groundHere and not groundAhead then return -99, "ledge" end
    if groundHere and groundAhead then
        local su = groundAhead.Position.Y - groundHere.Position.Y
        if su > 0.55 and su < CFG.JumpHeightThreshold then return su + 0.25, "step" end
    end
    return 0, nil
end

local function shouldJumpForObstacle(yDelta, cls)
    if not cls then return false end
    if cls == "ledge"   then return false end
    if cls == "truss"   then return true  end
    if cls == "step"    then return yDelta and yDelta > 0.3 end
    if cls == "ramp"    then return yDelta and yDelta > 0.8 end
    return false
end

-- ════════════════════════════════════════════════════════════════════════
--  §12  MONTE CARLO TREE SEARCH  — path planning
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
    local goalDir   = rawDir.Magnitude > 0.1 and rawDir.Unit or Vector3.new(0,0,-1)

    local step      = CFG.MCTSStepSize
    local depth     = CFG.MCTSDepth
    local bestScore = -math.huge
    local bestFirstDir = goalDir

    for _ = 1, simCount do
        local baseAngle  = math.atan2(goalDir.Z, goalDir.X)
        local spread     = math.pi * 0.55
        local firstAngle = baseAngle + (math.random() * 2 - 1) * spread
        local firstDir   = Vector3.new(math.cos(firstAngle), 0, math.sin(firstAngle))

        local pos   = startPos
        local score = 0
        local valid = true

        for d = 1, depth do
            local ta   = math.atan2(goalDir.Z, goalDir.X)
            local ca   = math.atan2(firstDir.Z, firstDir.X)
            local tb   = (d / depth) * 0.5
            local ba   = ca + (ta - ca) * tb
            local sd   = Vector3.new(math.cos(ba), 0, math.sin(ba))
            local np   = pos + sd * step

            local wallHit = Workspace:Raycast(
                pos + Vector3.new(0, 0.5, 0), sd * (step * 1.15), params)
            if wallHit and wallHit.Instance then
                local cls     = classifyPart(wallHit.Instance)
                local partTop = wallHit.Instance.Position.Y + wallHit.Instance.Size.Y * 0.5
                local yD      = partTop - pos.Y
                if cls == "obstacle" or cls == "wall" then
                    if yD > CFG.JumpHeightThreshold then
                        score = score - 90; valid = false; break
                    else
                        score = score - 12
                    end
                end
            end

            local ga = Workspace:Raycast(
                np + Vector3.new(0,0.3,0), Vector3.new(0,-9,0), params)
            if not ga then score = score - 70; valid = false; break end

            for tplr, entry in pairs(EntityRegistry) do
                if isEnemy(tplr) and entry.health > 0 then
                    local ed = (np - entry.pos).Magnitude
                    if ed < 8 then score = score - 50 / (ed + 0.5) end
                end
            end

            pos   = np
            score = score + 6
        end

        if valid then
            local fd = Vector3.new(pos.X,0,pos.Z) - goalFlat
            score = score + 280 / (fd.Magnitude + 1)
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
--  §13  NEURAL-HEURISTIC BRAIN  (pre-tuned weights, online learning)
-- ════════════════════════════════════════════════════════════════════════
local Brain = {
    w = {
        dodge       = 1.72,
        juke        = 1.18,
        engage      = 1.30,
        retreat     = 0.58,
        navigate    = 0.95,
        wait_reload = 1.15,
    },
    lastAction    = "navigate",
    decisionCount = 0,
}

local function brainDecide(ctx)
    local hpRatio = ctx.health / math.max(ctx.maxHealth, 1)
    local visFrac = ctx.visFraction or 0
    local threats = ctx.threatCount or 0
    local reload  = ctx.isReloading and 1 or 0
    local melee   = ctx.inMeleeRange and 1 or 0
    local hasTgt  = ctx.hasTarget and 1 or 0
    local dist    = ctx.targetDist or 999
    local visGate = visFrac >= CFG.WallCheckStrict and 1 or (visFrac / CFG.WallCheckStrict)

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

    local best, bestV = "navigate", -math.huge
    for act, val in pairs(scores) do
        if val > bestV then bestV = val; best = act end
    end

    Brain.lastAction    = best
    Brain.decisionCount = Brain.decisionCount + 1
    return best, scores
end

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
    for k, v in pairs(w) do
        Brain.w[k] = math.max(CFG.WeightClampLo, math.min(CFG.WeightClampHi, v))
    end
end

-- ════════════════════════════════════════════════════════════════════════
--  §14  PIXEL-PERFECT AIM  —  ZERO PREDICTION, DIRECT SNAP
--
--  Bullets are INSTANT + LINEAR with ZERO GRAVITY.
--  Camera.CFrame is snapped to CFrame.new(camPos, partPos) exactly.
--  No velocity lead.  No arc correction.  Shoot directly at part.
--
--  Part priority: Head > UpperTorso/Torso > HRP > any visible part.
-- ════════════════════════════════════════════════════════════════════════
local AIM_PRIORITY = {
    "Head","UpperTorso","Torso","HumanoidRootPart",
    "LowerTorso","LeftUpperArm","RightUpperArm",
    "LeftLowerArm","RightLowerArm",
}

-- Returns: aimPoint (Vector3, direct part position), partName | nil, nil
-- NO prediction, NO lead — just the current live part.Position
local function getBestAimPoint(targetChar, originPos)
    if not targetChar then return nil, nil end
    local myChar = LocalPlayer.Character
    local params = RaycastParams.new()
    params.FilterType = Enum.RaycastFilterType.Blacklist
    params.FilterDescendantsInstances = myChar and { myChar } or {}

    -- Scan priority parts
    for _, name in ipairs(AIM_PRIORITY) do
        local part = targetChar:FindFirstChild(name)
        if part and part:IsA("BasePart") then
            -- Direct position: zero prediction
            local aimPos = part.Position
            local dir    = aimPos - originPos
            local result = Workspace:Raycast(originPos, dir, params)
            if result == nil then
                return aimPos, name                        -- clean line of sight
            elseif result.Instance and result.Instance:IsDescendantOf(targetChar) then
                return result.Position, name               -- hit is on the target
            end
        end
    end

    -- Fall-through: scan every descendant BasePart
    for _, part in ipairs(targetChar:GetDescendants()) do
        if part:IsA("BasePart") then
            local aimPos = part.Position
            local dir    = aimPos - originPos
            local result = Workspace:Raycast(originPos, dir, params)
            if result == nil or (result.Instance and result.Instance:IsDescendantOf(targetChar)) then
                return aimPos, part.Name
            end
        end
    end

    -- Absolute fallback: HRP direct position even if slightly occluded
    local hrp = targetChar:FindFirstChild("HumanoidRootPart")
    if hrp then return hrp.Position, "HRP_fallback" end
    return nil, nil
end

-- Snap camera CFrame to look exactly at aimPoint from current camera position.
-- Pixel-perfect: rendered crosshair is on the part.
local function applyAim(aimPoint)
    if not aimPoint then return end
    Camera.CFrame = CFrame.new(Camera.CFrame.Position, aimPoint)
end

-- ════════════════════════════════════════════════════════════════════════
--  §15  AIM TARGET SELECTION
--  Select NEAREST alive enemy (world distance), no FOV radius gate.
--  Wall check: low-medium strictness (42% of 12 points visible).
-- ════════════════════════════════════════════════════════════════════════
local function selectAimTarget()
    local myChar = LocalPlayer.Character
    if not myChar then return nil, nil end
    local myHRP = myChar:FindFirstChild("HumanoidRootPart")
    if not myHRP then return nil, nil end

    local originPos  = Camera.CFrame.Position
    local myPos      = myHRP.Position
    local bestPlr    = nil
    local bestDist   = math.huge
    local bestAimPt  = nil

    for _, plr in ipairs(Players:GetPlayers()) do
        if not isEnemy(plr) then continue end
        local char = plr.Character
        if not char then continue end
        local hrp = char:FindFirstChild("HumanoidRootPart")
        local hum = char:FindFirstChildOfClass("Humanoid")
        if not hrp or not hum or hum.Health <= 0 then continue end

        local dist = (hrp.Position - myPos).Magnitude
        if dist >= bestDist then continue end

        -- Wall check (low-medium: 42% of 12 points)
        local _, _, frac, _ = atomicLoS(char, originPos)
        if frac < CFG.WallCheckStrict then continue end

        -- Direct aim point (zero prediction)
        local aimPt, _ = getBestAimPoint(char, originPos)
        if aimPt then
            bestDist   = dist
            bestPlr    = plr
            bestAimPt  = aimPt
        end
    end

    return bestPlr, bestAimPt
end

-- ════════════════════════════════════════════════════════════════════════
--  §16  KNIFE / PROJECTILE DODGE  (linear trajectory, time-delayed travel)
-- ════════════════════════════════════════════════════════════════════════
local function evalProjectileThreat(partPos, partVel, hrpPos, feetY)
    local speed = partVel.Magnitude
    if speed < CFG.MinProjectileSpeed then return nil end

    local toPlayer = hrpPos - partPos
    local dist     = toPlayer.Magnitude
    if dist > CFG.DetectionRange then return nil end
    if dist > 0.001 then
        local cosA = toPlayer:Dot(partVel) / (dist * speed)
        if cosA < CFG.DotFacingThreshold then return nil end
    end

    local a     = partVel:Dot(partVel)
    if a < 1e-10 then return nil end
    local inv2a = 0.5 / a
    local pad   = CFG.HitboxPadding
    local pad2  = pad * pad

    local bestT, bestPart = math.huge, nil
    for _, hp in ipairs(charParts) do
        local oc   = partPos - hp.Position
        local b    = 2 * oc:Dot(partVel)
        local c    = oc:Dot(oc) - pad2
        local disc = b * b - 4 * a * c
        if disc >= 0 then
            local sq = math.sqrt(disc)
            local t1 = (-b - sq) * inv2a
            local t2 = (-b + sq) * inv2a
            local t  = (t1 >= 0) and t1 or t2
            if t >= 0 and t <= CFG.FutureLookAhead and t < bestT then
                bestT    = t
                bestPart = hp
            end
        end
    end
    if not bestPart then return nil end

    local impact = partPos + partVel * bestT
    local vFlat  = Vector3.new(partVel.X, 0, partVel.Z)
    vFlat = vFlat.Magnitude > 0.001 and vFlat.Unit or Vector3.new(1,0,0)
    local pA   = Vector3.new(-vFlat.Z, 0,  vFlat.X)
    local pB   = Vector3.new( vFlat.Z, 0, -vFlat.X)
    local away = Vector3.new(hrpPos.X - impact.X, 0, hrpPos.Z - impact.Z)
    away = away.Magnitude > 0.01 and away.Unit or (-vFlat)
    local bestPerp = pA:Dot(away) >= pB:Dot(away) and pA or pB

    return {
        t        = bestT,
        impact   = impact,
        vel      = partVel,
        pos      = partPos,
        speed    = speed,
        pA       = pA,
        pB       = pB,
        bestPerp = bestPerp,
        away     = away,
        vFlat    = vFlat,
        needJump = (impact.Y <= feetY + CFG.JumpHeightThreshold) and (bestT < 0.55),
        urgency  = 1 / (bestT + 0.01),
    }
end

local function computeClearance(dir, hrpPos, th)
    local mt = math.min(th.t, 0.5)
    local fx = hrpPos.X + dir.X * CFG.WalkSpeed * mt
    local fz = hrpPos.Z + dir.Z * CFG.WalkSpeed * mt
    local ox, oz = th.pos.X, th.pos.Z
    local dx, dz = th.vFlat.X, th.vFlat.Z
    local ex     = fx - ox; local ez = fz - oz
    local proj   = math.max(0, ex*dx + ez*dz)
    local cx     = ox + dx*proj; local cz = oz + dz*proj
    local rx     = fx - cx; local rz = fz - cz
    return math.sqrt(rx*rx + rz*rz)
end

local function scoreDodgeDir(dir, hrpPos, threats)
    local safe = CFG.HitboxPadding * CFG.SafeMarginMult
    local minC = math.huge
    local tot  = 0
    for _, th in ipairs(threats) do
        local c = computeClearance(dir, hrpPos, th)
        if c < minC then minC = c end
        if c >= safe then
            tot = tot + c * th.urgency
        else
            tot = tot - (safe - c) * 22 * th.urgency
        end
    end
    if minC < CFG.HitboxPadding then return -math.huge end
    return tot
end

local function computeBestDodge(hrpPos, threats)
    if #threats == 0 then return nil end
    local bestDir, bestScore = nil, -math.huge
    for _, d in ipairs(SWEEP) do
        local s = scoreDodgeDir(d, hrpPos, threats)
        if s > bestScore then bestScore = s; bestDir = d end
    end
    for _, th in ipairs(threats) do
        for _, cand in ipairs({th.pA, th.pB, th.away, th.bestPerp}) do
            if cand and cand.Magnitude > 0.01 then
                local s = scoreDodgeDir(cand.Unit, hrpPos, threats)
                if s > bestScore then bestScore = s; bestDir = cand.Unit end
            end
        end
    end
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
--  §17  PROJECTILE TRACKING
-- ════════════════════════════════════════════════════════════════════════
local projSet  = {}
local projData = {}
local projList = {}

local function isProjectileName(n)
    local lo = n:lower()
    return lo:find("knife")  or lo:find("projectile") or lo:find("throw")
        or lo:find("bullet") or lo:find("axe")        or lo:find("rock")
        or lo:find("spear")  or lo:find("dart")       or lo:find("star")
        or lo:find("arrow")  or lo:find("shard")      or lo:find("bolt")
        or lo:find("orb")    or lo:find("shuriken")
end

local function spawnInstantDodge(vel, knifePos)
    if not CFG.DodgeEnabled then return end
    local hrp = charHRP
    if not hrp or vel.Magnitude < CFG.MinProjectileSpeed then return end
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
    local fake = {
        t = estT, impact = knifePos + vel * estT, vel = vel, pos = knifePos,
        speed = vel.Magnitude, pA = pA, pB = pB, bestPerp = bp, away = away,
        vFlat = vFlat, urgency = 1 / (estT + 0.01),
    }
    local dodgeDir = computeBestDodge(hrpPos, {fake}) or bp
    fireKeys(dodgeDir)
    if knifePos.Y <= getFeetY() + CFG.JumpHeightThreshold then doJump() end
end

local function registerProjectile(obj)
    if not isProjectileName(obj.Name) then return end
    local part = obj:IsA("BasePart") and obj
              or (obj:IsA("Model") and (obj.PrimaryPart or obj:FindFirstChildWhichIsA("BasePart")))
    if not part or projSet[part] then return end
    local vel  = part.AssemblyLinearVelocity
    local pos  = part.Position
    local data = { lastPos = pos, vel = vel, born = os.clock(), frames = 0 }
    projSet[part]           = true
    projData[part]          = data
    projList[#projList + 1] = part
    spawnInstantDodge(vel, pos)
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
    task.defer(function()
        if projSet[part] then
            local v = part.AssemblyLinearVelocity
            if v.Magnitude > data.vel.Magnitude * 0.5 then data.vel = v end
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
    local names = {
        "ProjectilesAndDebris","Projectiles","Debris","Knives","Throwables","Bullets"
    }
    for _, n in ipairs(names) do
        local f = Workspace:FindFirstChild(n)
        if f then connectProjectileFolder(f); return end
    end
    connectProjectileFolder(Workspace)
end)

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
                local np   = part.Position
                local dv   = (np - d.lastPos) / dt
                d.frames   = (d.frames or 0) + 1
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
--  §18  MELEE JUKE  —  ATOMIC ORBIT  (character movement, camera stays on aim)
-- ════════════════════════════════════════════════════════════════════════
local JukeState = {
    active       = false,
    orbitDir     = 1,
    targetPlayer = nil,
    changeTimer  = 0,
}

local function computeJukeDir(myPos, enemyPos, enemyLook)
    local blindSpot = enemyPos - enemyLook * 2.0
    local toBlind   = Vector3.new(blindSpot.X - myPos.X, 0, blindSpot.Z - myPos.Z)
    local toEnemy   = Vector3.new(enemyPos.X - myPos.X,  0, enemyPos.Z - myPos.Z)
    if toBlind.Magnitude < 0.5 then
        local perp = Vector3.new(-enemyLook.Z, 0, enemyLook.X) * JukeState.orbitDir
        return perp.Magnitude > 0.01 and perp.Unit or enemyLook
    end
    toBlind = toBlind.Unit
    local perpComp  = Vector3.new(-toEnemy.Unit.Z, 0, toEnemy.Unit.X) * JukeState.orbitDir
    local blended   = toBlind * 0.70 + perpComp * 0.30
    return blended.Magnitude > 0.01 and blended.Unit or toBlind
end

local function executeJuke(myPos, now)
    if not CFG.JukeEnabled then JukeState.active = false; return false end
    local closestPlr, closestDist, closestEntry = nil, CFG.MeleeRange, nil
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
    if not closestPlr then JukeState.active = false; return false end
    if not JukeState.active or JukeState.targetPlayer ~= closestPlr then
        JukeState.active       = true
        JukeState.targetPlayer = closestPlr
        JukeState.orbitDir     = math.random() > 0.5 and 1 or -1
        JukeState.changeTimer  = now + 0.6
    end
    if now > JukeState.changeTimer then
        JukeState.orbitDir    = -JukeState.orbitDir
        JukeState.changeTimer = now + math.random() * 0.5 + 0.3
    end
    local eLook = closestEntry.lastCFrame.LookVector
    eLook = Vector3.new(eLook.X, 0, eLook.Z)
    eLook = eLook.Magnitude > 0.01 and eLook.Unit or Vector3.new(0,0,1)
    local jukeDir = computeJukeDir(myPos, closestEntry.pos, eLook)
    fireKeys(jukeDir)
    return true
end

-- ════════════════════════════════════════════════════════════════════════
--  §19  ANTI-STUCK SYSTEM
-- ════════════════════════════════════════════════════════════════════════
local stuckTracker = {
    lastPos       = Vector3.new(),
    lastMoveTime  = os.clock(),
    stuckTryDir   = nil,
    stuckTryStart = 0,
}

local function updateStuck(hrpPos, moveDir, now)
    local disp = (hrpPos - stuckTracker.lastPos).Magnitude
    if disp > CFG.StuckThreshold then
        stuckTracker.lastPos      = hrpPos
        stuckTracker.lastMoveTime = now
        stuckTracker.stuckTryDir  = nil
        return false
    end
    if now - stuckTracker.lastMoveTime > CFG.StuckWindow then
        if not stuckTracker.stuckTryDir then
            local ref = moveDir or Vector3.new(0,0,1)
            local perp = Vector3.new(-ref.Z, 0, ref.X)
            stuckTracker.stuckTryDir  = math.random() > 0.5 and perp or -perp
            stuckTracker.stuckTryStart = now
        end
        if now - stuckTracker.stuckTryStart < 0.5 then
            fireKeys(stuckTracker.stuckTryDir)
            doJump()
            return true
        else
            stuckTracker.stuckTryDir  = nil
            stuckTracker.lastMoveTime = now
        end
    end
    return false
end

-- ════════════════════════════════════════════════════════════════════════
--  §20  ESP  SYSTEM
-- ════════════════════════════════════════════════════════════════════════
local espHighlights = {}

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
    hl.Name                = "MC_ESP_" .. plr.Name
    hl.Parent              = char
    hl.FillColor           = isEnemy(plr) and Color3.fromRGB(255,38,38) or Color3.fromRGB(38,255,80)
    hl.OutlineColor        = Color3.fromRGB(255,255,255)
    hl.FillTransparency    = 0.42
    hl.OutlineTransparency = 0
    hl.DepthMode           = Enum.HighlightDepthMode.AlwaysOnTop
    hl.Enabled             = CFG.ESPEnabled and isEnemy(plr)
    espHighlights[plr]     = hl
end

local function refreshAllESP()
    for plr, hl in pairs(espHighlights) do
        if hl and hl.Parent then
            hl.Enabled   = CFG.ESPEnabled and isEnemy(plr)
            hl.FillColor = isEnemy(plr) and Color3.fromRGB(255,38,38) or Color3.fromRGB(38,255,80)
        end
    end
end

local function setupPlayerESP(plr)
    if plr == LocalPlayer then return end
    plr.CharacterAdded:Connect(function()
        task.wait(0.35); createESP(plr)
    end)
    plr.CharacterRemoving:Connect(function()
        task.wait(0.1); removeESP(plr)
    end)
    plr:GetPropertyChangedSignal("Team"):Connect(function()
        task.wait(0.1); createESP(plr)
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
--  §21  DIAGNOSTIC HUD  (draggable, toggles, reload bar, no FOV ring)
-- ════════════════════════════════════════════════════════════════════════
local HUD = { ready = false }

task.spawn(function()
    local playerGui = LocalPlayer:WaitForChild("PlayerGui")

    local SG = Instance.new("ScreenGui")
    SG.Name           = "MC_HUD"
    SG.ResetOnSpawn   = false
    SG.ZIndexBehavior = Enum.ZIndexBehavior.Sibling
    SG.DisplayOrder   = 99
    SG.Parent         = playerGui

    -- Reload bar background (appears below crosshair when reloading)
    local rBarBG = Instance.new("Frame")
    rBarBG.Size                  = UDim2.new(0, 180, 0, 7)
    rBarBG.AnchorPoint           = Vector2.new(0.5, 0)
    rBarBG.Position              = UDim2.new(0.5, 0, 0.5, 22)
    rBarBG.BackgroundColor3      = Color3.fromRGB(30, 30, 30)
    rBarBG.BackgroundTransparency = 0.22
    rBarBG.BorderSizePixel       = 0
    rBarBG.Visible               = false
    rBarBG.Parent                = SG
    Instance.new("UICorner", rBarBG).CornerRadius = UDim.new(0, 4)

    local rBar = Instance.new("Frame")
    rBar.Size             = UDim2.new(0, 0, 1, 0)
    rBar.BackgroundColor3 = Color3.fromRGB(255, 200, 40)
    rBar.BorderSizePixel  = 0
    rBar.Parent           = rBarBG
    Instance.new("UICorner", rBar).CornerRadius = UDim.new(0, 4)
    HUD.rBarBG = rBarBG
    HUD.rBar   = rBar

    -- Small crosshair dot at screen centre
    local dot = Instance.new("Frame")
    dot.Size                  = UDim2.new(0, 5, 0, 5)
    dot.AnchorPoint           = Vector2.new(0.5, 0.5)
    dot.Position              = UDim2.new(0.5, 0, 0.5, 0)
    dot.BackgroundColor3      = Color3.fromRGB(255, 55, 55)
    dot.BackgroundTransparency = 0.0
    dot.BorderSizePixel       = 0
    dot.Parent                = SG
    Instance.new("UICorner", dot).CornerRadius = UDim.new(1, 0)

    -- Main panel
    local panel = Instance.new("Frame")
    panel.Name                   = "MCPanel"
    panel.Size                   = UDim2.new(0, 220, 0, 325)
    panel.Position               = UDim2.new(0, 14, 0, 14)
    panel.BackgroundColor3       = Color3.fromRGB(8, 8, 18)
    panel.BackgroundTransparency = 0.07
    panel.BorderSizePixel        = 0
    panel.Active                 = true
    panel.Parent                 = SG
    Instance.new("UICorner", panel).CornerRadius = UDim.new(0, 10)

    -- Title bar
    local titleBar = Instance.new("Frame")
    titleBar.Size             = UDim2.new(1, 0, 0, 28)
    titleBar.BackgroundColor3 = Color3.fromRGB(18, 18, 42)
    titleBar.BorderSizePixel  = 0
    titleBar.Parent           = panel
    Instance.new("UICorner", titleBar).CornerRadius = UDim.new(0, 10)

    local titleLbl = Instance.new("TextLabel")
    titleLbl.Size                = UDim2.new(1, -10, 1, 0)
    titleLbl.Position            = UDim2.new(0, 10, 0, 0)
    titleLbl.BackgroundTransparency = 1
    titleLbl.Text                = "Autoplayer"
    titleLbl.TextColor3          = Color3.fromRGB(140, 175, 255)
    titleLbl.TextScaled          = true
    titleLbl.Font                = Enum.Font.GothamBold
    titleLbl.TextXAlignment      = Enum.TextXAlignment.Left
    titleLbl.Parent              = titleBar

    -- Toggle row factory
    local function makeToggle(yOff, label, initState, onToggle)
        local row = Instance.new("Frame")
        row.Size                 = UDim2.new(1, -16, 0, 30)
        row.Position             = UDim2.new(0, 8, 0, yOff)
        row.BackgroundTransparency = 1
        row.Parent               = panel
        local lbl = Instance.new("TextLabel")
        lbl.Size                 = UDim2.new(0, 135, 1, 0)
        lbl.BackgroundTransparency = 1
        lbl.Text                 = label
        lbl.TextColor3           = Color3.fromRGB(195, 195, 210)
        lbl.TextScaled           = true
        lbl.Font                 = Enum.Font.Gotham
        lbl.TextXAlignment       = Enum.TextXAlignment.Left
        lbl.Parent               = row
        local btn = Instance.new("TextButton")
        btn.Size             = UDim2.new(0, 52, 0, 21)
        btn.Position         = UDim2.new(1, -52, 0.5, -10)
        btn.Text             = initState and "ON" or "OFF"
        btn.TextColor3       = Color3.new(1,1,1)
        btn.TextScaled       = true
        btn.Font             = Enum.Font.GothamBold
        btn.BackgroundColor3 = initState
            and Color3.fromRGB(0,195,75) or Color3.fromRGB(195,45,45)
        btn.BorderSizePixel  = 0
        btn.Parent           = row
        Instance.new("UICorner", btn).CornerRadius = UDim.new(0, 5)
        btn.MouseButton1Click:Connect(function()
            local ns = onToggle()
            btn.Text             = ns and "ON" or "OFF"
            btn.BackgroundColor3 = ns
                and Color3.fromRGB(0,195,75) or Color3.fromRGB(195,45,45)
        end)
        return btn
    end

    local function makeStatus(yOff, col)
        local lbl = Instance.new("TextLabel")
        lbl.Size                 = UDim2.new(1, -16, 0, 17)
        lbl.Position             = UDim2.new(0, 8, 0, yOff)
        lbl.BackgroundTransparency = 1
        lbl.TextColor3           = col or Color3.fromRGB(145,145,165)
        lbl.TextScaled           = true
        lbl.Font                 = Enum.Font.Gotham
        lbl.TextXAlignment       = Enum.TextXAlignment.Left
        lbl.Text                 = ""
        lbl.Parent               = panel
        return lbl
    end

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
    sep.BackgroundColor3 = Color3.fromRGB(55,55,75)
    sep.BorderSizePixel  = 0
    sep.Parent           = panel
    y = y + 10

    HUD.lblAction  = makeStatus(y, Color3.fromRGB(145,145,175)); y = y + 20
    HUD.lblTarget  = makeStatus(y);                               y = y + 20
    HUD.lblThreats = makeStatus(y, Color3.fromRGB(255,90,90));    y = y + 20
    HUD.lblHP      = makeStatus(y, Color3.fromRGB(90,220,90));    y = y + 20
    HUD.lblPing    = makeStatus(y);                               y = y + 20
    HUD.lblReload  = makeStatus(y, Color3.fromRGB(255,200,50));   y = y + 20
    HUD.lblWeights = makeStatus(y, Color3.fromRGB(90,190,90))

    -- Drag logic
    local dragging, dragStart, panelStart = false, nil, nil
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

-- Per-frame HUD refresh (every 8 frames)
local hudTick = 0
local function refreshHUD(action, targetName, threatCount, hpVal, maxHpVal)
    hudTick = hudTick + 1
    if hudTick % 8 ~= 0 or not HUD.ready then return end

    if HUD.lblAction then
        local txt, col
        if     action == "dodge"       then txt="⚡ DODGE";   col=Color3.fromRGB(80,255,80)
        elseif action == "juke"        then txt="🔄 JUKE";    col=Color3.fromRGB(255,155,50)
        elseif action == "engage"      then txt="🎯 ENGAGE";  col=Color3.fromRGB(255,75,75)
        elseif action == "retreat"     then txt="← RETREAT";  col=Color3.fromRGB(100,185,255)
        elseif action == "navigate"    then txt="▶ NAVIGATE"; col=Color3.fromRGB(210,210,90)
        elseif action == "wait_reload" then txt="↺ RELOAD";   col=Color3.fromRGB(255,220,50)
        else                                txt="◉ IDLE";     col=Color3.fromRGB(130,130,150)
        end
        HUD.lblAction.Text       = txt
        HUD.lblAction.TextColor3 = col
    end

    if HUD.lblTarget  then
        HUD.lblTarget.Text = "Target  : " .. (targetName or "—")
    end
    if HUD.lblThreats then
        HUD.lblThreats.Text       = "Threats : " .. (threatCount or 0)
        HUD.lblThreats.TextColor3 = (threatCount and threatCount > 0)
            and Color3.fromRGB(255,75,75) or Color3.fromRGB(145,145,165)
    end
    if HUD.lblHP then
        local hpRatio = (hpVal or 100) / math.max(maxHpVal or 100, 1)
        HUD.lblHP.Text       = string.format("HP      : %d / %d", hpVal or 0, maxHpVal or 100)
        HUD.lblHP.TextColor3 = hpRatio < 0.35
            and Color3.fromRGB(255,80,80) or Color3.fromRGB(80,225,90)
    end
    if HUD.lblPing then
        HUD.lblPing.Text = string.format("Ping    : %d ms",
            math.floor(estimatedPingSeconds * 1000))
    end
    if HUD.lblReload then
        local rPct = math.floor(getReloadFraction() * 100)
        HUD.lblReload.Text       = string.format("Reload  : %d %%", rPct)
        HUD.lblReload.TextColor3 = rPct < 30
            and Color3.fromRGB(255,75,75) or Color3.fromRGB(100,225,100)
    end
    if HUD.lblWeights then
        HUD.lblWeights.Text = string.format(
            "w[e=%.2f d=%.2f j=%.2f n=%.2f]",
            Brain.w.engage, Brain.w.dodge, Brain.w.juke, Brain.w.navigate)
    end

    -- Reload bar
    if HUD.rBarBG and HUD.rBar then
        HUD.rBarBG.Visible = reloadActive
        if reloadActive then
            HUD.rBar.Size = UDim2.new(getReloadFraction(), 0, 1, 0)
        end
    end
end

-- ════════════════════════════════════════════════════════════════════════
--  §22  MAIN LOOP STATE
-- ════════════════════════════════════════════════════════════════════════
local dodgeActive    = false
local extraActive    = false
local extraDir       = Vector3.new(1,0,0)
local extraTargetPos = nil
local extraStartTime = 0
local lastMoveDir    = Vector3.new(1,0,0)

local currentAction  = "idle"
local currentTarget  = nil
local currentAimPoint = nil

local prevLocalHP      = 100
local prevEnemyHPMap   = {}

local clockPingUpdate   = 0
local clockEntityUpdate = 0
local clockMCTS         = 0
local frameCount        = 0
local lastFrameTime     = os.clock()

-- ════════════════════════════════════════════════════════════════════════
--  §23  MAIN RENDER-STEPPED LOOP
-- ════════════════════════════════════════════════════════════════════════
RunService.RenderStepped:Connect(function()
    local now = os.clock()
    local dt  = math.clamp(now - lastFrameTime, 0.001, 0.10)
    lastFrameTime = now
    frameCount    = frameCount + 1

    -- §23.1  Projectile velocity refinement
    updateProjectileVelocities(dt)

    -- §23.2  Character validity
    local char = LocalPlayer.Character
    if not char then releaseAll(); return end
    local hrp = char:FindFirstChild("HumanoidRootPart")
    if not hrp then releaseAll(); return end
    if not charHRP or charHRP.Parent ~= char or #charParts == 0 then
        rebuildCharCache(char)
    end

    local hrpPos        = hrp.Position
    local feetY         = getFeetY()
    local myHP, myMaxHP = getLocalHP()

    -- §23.3  Ping update (every 3 s)
    if now - clockPingUpdate > 3.0 then
        clockPingUpdate = now
        task.spawn(updatePing)
    end

    -- §23.4  Entity registry update (every 50 ms)
    if now - clockEntityUpdate > 0.05 then
        clockEntityUpdate = now
        for _, plr in ipairs(Players:GetPlayers()) do
            if plr ~= LocalPlayer then
                registryUpdate(plr, dt)
            end
        end
    end

    -- §23.5  Threat detection
    local threats = {}
    for _, part in ipairs(projList) do
        local data = projData[part]
        if data and part.Parent then
            local th = evalProjectileThreat(part.Position, data.vel, hrpPos, feetY)
            if th then threats[#threats + 1] = th end
        end
    end
    if #threats > 1 then
        table.sort(threats, function(a,b) return a.t < b.t end)
    end

    -- §23.6  Visibility scan (every enemy, every frame for accuracy)
    local originPos = Camera.CFrame.Position
    for plr, entry in pairs(EntityRegistry) do
        if isEnemy(plr) and plr.Character then
            local _, _, frac, _ = atomicLoS(plr.Character, originPos)
            entry.wasVisible  = entry.isVisible
            entry.isVisible   = frac >= CFG.WallCheckStrict
            entry.visFraction = frac
        end
    end

    -- §23.7  Aim target selection (nearest enemy, no FOV gate)
    if CFG.AutoAimEnabled then
        local aimPlr, aimPt = selectAimTarget()
        if aimPlr and aimPt then
            currentTarget   = aimPlr
            currentAimPoint = aimPt
        elseif not currentTarget then
            local cp, _, _ = getClosestEnemyToPos(hrpPos)
            if cp then currentTarget = cp end
        end
    end

    -- Validate current target still alive
    if currentTarget then
        local ce = EntityRegistry[currentTarget]
        if not ce or ce.health <= 0 or not currentTarget.Character then
            currentTarget   = nil
            currentAimPoint = nil
        end
    end

    -- §23.8  Brain decision
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

    -- §23.9  Online learning rewards
    local hpDelta = myHP - prevLocalHP
    if hpDelta < -2 then
        brainReward(-1.2)
    elseif hpDelta > 0 then
        brainReward(0.15)
    end
    if currentTarget and targetEntry then
        local prevEHP    = prevEnemyHPMap[currentTarget] or targetEntry.health
        local enemyDelta = targetEntry.health - prevEHP
        if enemyDelta < -2 then
            brainReward(1.6)
            Brain.w.engage = math.min(Brain.w.engage + CFG.LearningRate * 0.5, CFG.WeightClampHi)
        end
        prevEnemyHPMap[currentTarget] = targetEntry.health
    end
    prevLocalHP = myHP

    -- §23.10  ACTION EXECUTION ─────────────────────────────────────────

    -- ─ DODGE ─────────────────────────────────────────────────────────
    if action == "dodge" and CFG.DodgeEnabled and #threats > 0 then
        local dodgeDir = computeBestDodge(hrpPos, threats)
        if dodgeDir then
            dodgeActive = true
            lastMoveDir = dodgeDir
            -- Orient camera toward dodge direction so WASD stays aligned
            setCameraFacing(dodgeDir)
            fireKeys(dodgeDir)
            for i = 1, math.min(2, #threats) do
                if threats[i].needJump then doJump(); break end
            end
        end
        extraActive    = false
        extraTargetPos = nil
        -- Continue aiming and shooting while dodging
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
        -- Camera aims at enemy; character moves independently via fireKeys
        if CFG.AutoAimEnabled and currentAimPoint then
            applyAim(currentAimPoint)
        end

    -- ─ ENGAGE ────────────────────────────────────────────────────────
    elseif action == "engage" and currentAimPoint then
        dodgeActive = false

        -- Direct pixel-perfect aim snap (no prediction)
        if CFG.AutoAimEnabled then
            applyAim(currentAimPoint)
        end

        -- Shoot if reloaded
        if CFG.AutoShootEnabled and canShoot() and hasLoS then
            doShoot()
        end

        -- Navigate/strafe using camera as movement reference frame
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
                -- Orient camera to movement direction for engage nav
                setCameraFacing(mvDir)
                local yc, cls = getYCorrectionForDir(hrpPos, mvDir)
                if cls == "ledge" then
                    local alt = Vector3.new(-mvDir.Z, 0, mvDir.X)
                    setCameraFacing(alt)
                    fireKeys(alt)
                elseif shouldJumpForObstacle(yc, cls) then
                    fireKeys(mvDir); doJump()
                else
                    fireKeys(mvDir)
                end
            end
        elseif CFG.AutoNavEnabled and targetDist <= CFG.EngageMoveRange then
            -- In range: strafe to avoid incoming fire
            local strafeDir = Vector3.new(-lastMoveDir.Z, 0, lastMoveDir.X)
                            * (math.sin(now * 2.8) > 0 and 1 or -1)
            fireKeys(strafeDir)
        end

    -- ─ RETREAT ───────────────────────────────────────────────────────
    elseif action == "retreat" then
        dodgeActive = false
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
            -- Orient camera to retreat direction
            setCameraFacing(retreatDir)
            fireKeys(retreatDir)
        end
        -- Still aim and shoot while retreating
        if CFG.AutoAimEnabled and currentAimPoint then
            applyAim(currentAimPoint)
            if CFG.AutoShootEnabled and canShoot() and hasLoS then
                doShoot()
            end
        end

    -- ─ WAIT / RELOAD ─────────────────────────────────────────────────
    elseif action == "wait_reload" then
        dodgeActive = false
        -- Evasive lateral movement during reload; camera follows strafe
        local strafeDir = Vector3.new(-lastMoveDir.Z, 0, lastMoveDir.X)
                        * (math.sin(now * 3.2) > 0 and 1 or -1)
        -- Orient camera toward strafe direction so W moves correctly
        setCameraFacing(strafeDir)
        fireKeys(strafeDir)
        -- Keep aim on target even while reloading
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
                -- Camera faces movement direction for correct WASD mapping
                setCameraFacing(mvDir)
                local yc, cls = getYCorrectionForDir(hrpPos, mvDir)
                if cls == "ledge" then
                    local alt = Vector3.new(-mvDir.Z, 0, mvDir.X)
                    setCameraFacing(alt)
                    fireKeys(alt)
                elseif shouldJumpForObstacle(yc, cls) then
                    fireKeys(mvDir); doJump()
                else
                    fireKeys(mvDir)
                end
                updateStuck(hrpPos, mvDir, now)
            end
        else
            releaseAll()
        end

    -- ─ IDLE ──────────────────────────────────────────────────────────
    else
        dodgeActive = false
        if not extraActive then releaseAll() end
    end

    -- §23.11  Post-dodge burst momentum
    if not dodgeActive then
        if extraActive then
            local target = extraTargetPos or (hrpPos + extraDir * CFG.ExtraBurstDistance)
            local hVec   = Vector3.new(hrpPos.X,  0, hrpPos.Z)
            local tVec   = Vector3.new(target.X,  0, target.Z)
            if (hVec - tVec).Magnitude > 0.35
            and now < extraStartTime + CFG.ExtraMaxBurstTime then
                setCameraFacing(extraDir)
                fireKeys(extraDir)
            else
                extraActive    = false
                extraTargetPos = nil
            end
        end
    else
        extraActive    = true
        extraDir       = lastMoveDir
        extraTargetPos = hrpPos + lastMoveDir * CFG.ExtraBurstDistance
        extraStartTime = now
    end

    -- §23.12  HUD refresh
    local tName = currentTarget and currentTarget.Name or nil
    refreshHUD(currentAction, tName, #threats, myHP, myMaxHP)
end)

-- ════════════════════════════════════════════════════════════════════════
--  §24  CHARACTER RESPAWN
-- ════════════════════════════════════════════════════════════════════════
local function onCharAdded(char)
    task.wait(0.2)
    rebuildCharCache(char)
    dodgeActive     = false
    extraActive     = false
    extraTargetPos  = nil
    currentTarget   = nil
    currentAimPoint = nil
    MCTSCache.bestDirection = nil
    JukeState.active = false
    releaseAll()
    Camera.CameraType = Enum.CameraType.Custom
end

LocalPlayer.CharacterAdded:Connect(onCharAdded)
if LocalPlayer.Character then
    task.spawn(function() task.wait(0.1); rebuildCharCache(LocalPlayer.Character) end)
end

-- ════════════════════════════════════════════════════════════════════════
--  §25  PLAYER REGISTRY EVENTS
-- ════════════════════════════════════════════════════════════════════════
Players.PlayerAdded:Connect(function(plr)
    setupPlayerESP(plr)
    plr.CharacterAdded:Connect(function()
        task.wait(0.1); registryEnsure(plr)
    end)
    plr.CharacterRemoving:Connect(function()
        EntityRegistry[plr] = nil
    end)
end)

Players.PlayerRemoving:Connect(function(plr)
    EntityRegistry[plr]    = nil
    prevEnemyHPMap[plr]    = nil
    removeESP(plr)
end)

for _, plr in ipairs(Players:GetPlayers()) do
    if plr ~= LocalPlayer then
        plr.CharacterAdded:Connect(function()
            task.wait(0.1); registryEnsure(plr)
        end)
        plr.CharacterRemoving:Connect(function()
            EntityRegistry[plr] = nil
        end)
        if plr.Character then registryEnsure(plr) end
    end
end

-- ════════════════════════════════════════════════════════════════════════
--  §26  STARTUP NOTIFICATION
-- ════════════════════════════════════════════════════════════════════════
task.delay(1.0, function()
    pcall(function()
        game:GetService("StarterGui"):SetCore("SendNotification", {
            Title    = "Autoplayer",
            Text     = "Loaded!",
            Duration = 3,
        })
    end)
end)