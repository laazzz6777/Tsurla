-- ============================================================
--  GUI.lua — Autoplay + Aimbot + ESP + AutoDodge + AutoShoot + Juke
--  Enemy = any team with "Murder" in name
--  Autoplay button uses custom PNGs (on/off)
-- ============================================================

local Players             = game:GetService("Players")
local RunService          = game:GetService("RunService")
local UserInputService    = game:GetService("UserInputService")
local VirtualInputManager = game:GetService("VirtualInputManager")
local StarterGui          = game:GetService("StarterGui")
local Workspace           = game:GetService("Workspace")

local player    = Players.LocalPlayer
repeat task.wait() until player
local playerGui = player:WaitForChild("PlayerGui")
local camera    = workspace.CurrentCamera

-- ══════════════════════════════════════════
--  SETTINGS
-- ══════════════════════════════════════════
local Settings = {
    FOV_RADIUS     = 150,
    AIMBOT         = true,
    WALL_CHECK     = true,
    ESP            = true,
    AUTOPLAY       = true,
    AUTO_SHOOT     = true,
    AUTO_DODGE     = true,
    JUKE           = true,
    JUKE_RANGE     = 12,
    SHOOT_COOLDOWN = 0.12,
}

-- PNG asset IDs from your images
local IMG_ON  = "rbxassetid://1773565569861"
local IMG_OFF = "rbxassetid://1773565479579"

-- ══════════════════════════════════════════
--  ENEMY CHECK  (team name contains "Murder")
-- ══════════════════════════════════════════
local function isEnemy(plr)
    if plr == player then return false end
    local t = plr.Team
    if t and t.Name:find("Murder") then return true end
    if not plr.Team or not player.Team then return true end
    return plr.Team ~= player.Team
end

-- ══════════════════════════════════════════
--  ESP
-- ══════════════════════════════════════════
local espObjects = {}

local function createESP(plr)
    if plr == player or not plr.Character then return end
    pcall(function() if espObjects[plr] then espObjects[plr]:Destroy() end end)
    local h                  = Instance.new("Highlight")
    h.Parent                 = plr.Character
    h.FillColor              = Color3.fromRGB(255, 0, 0)
    h.OutlineColor           = Color3.fromRGB(255, 255, 255)
    h.FillTransparency       = 0.5
    h.OutlineTransparency    = 0
    h.DepthMode              = Enum.HighlightDepthMode.AlwaysOnTop
    h.Enabled                = Settings.ESP and isEnemy(plr)
    espObjects[plr]          = h
end

local function removeESP(plr)
    pcall(function() if espObjects[plr] then espObjects[plr]:Destroy() end end)
    espObjects[plr] = nil
end

local function updateESP()
    for plr, h in pairs(espObjects) do
        if h and h.Parent then
            h.Enabled = Settings.ESP and isEnemy(plr)
        end
    end
end

local function setupESP(plr)
    if plr == player then return end
    plr.CharacterAdded:Connect(function() task.wait(0.5) createESP(plr) end)
    plr.CharacterRemoving:Connect(function() removeESP(plr) end)
    plr:GetPropertyChangedSignal("Team"):Connect(function() task.wait(0.1) updateESP() end)
    if plr.Character then task.spawn(function() task.wait(0.5) createESP(plr) end) end
end

for _, p in ipairs(Players:GetPlayers()) do setupESP(p) end
Players.PlayerAdded:Connect(setupESP)
Players.PlayerRemoving:Connect(removeESP)
player:GetPropertyChangedSignal("Team"):Connect(updateESP)

-- ══════════════════════════════════════════
--  AIMBOT
-- ══════════════════════════════════════════
local aimbotTarget = nil
local MOUSE_LOCKED = false

local function isVisible(char)
    if not char or not Settings.WALL_CHECK then return true end
    local hrp = char:FindFirstChild("HumanoidRootPart")
    if not hrp then return false end
    local origin = camera.CFrame.Position
    local dir    = hrp.Position - origin
    local params = RaycastParams.new()
    params.FilterType = Enum.RaycastFilterType.Blacklist
    params.FilterDescendantsInstances = { player.Character, char }
    return Workspace:Raycast(origin, dir, params) == nil
end

local function getClosestToCrosshair()
    local closest, shortest = nil, math.huge
    local center = Vector2.new(camera.ViewportSize.X / 2, camera.ViewportSize.Y / 2)
    for _, plr in ipairs(Players:GetPlayers()) do
        if plr ~= player and plr.Character and isEnemy(plr) then
            local hum = plr.Character:FindFirstChildOfClass("Humanoid")
            local hrp = plr.Character:FindFirstChild("HumanoidRootPart")
            if hum and hum.Health > 0 and hrp then
                local sp, onScreen = camera:WorldToViewportPoint(hrp.Position)
                if onScreen then
                    local dist = (Vector2.new(sp.X, sp.Y) - center).Magnitude
                    if dist < Settings.FOV_RADIUS and isVisible(plr.Character) and dist < shortest then
                        closest  = plr
                        shortest = dist
                    end
                end
            end
        end
    end
    return closest
end

-- ══════════════════════════════════════════
--  KEY HELPERS
-- ══════════════════════════════════════════
local KC = {
    W     = Enum.KeyCode.W,
    A     = Enum.KeyCode.A,
    S     = Enum.KeyCode.S,
    D     = Enum.KeyCode.D,
    Space = Enum.KeyCode.Space,
}
local ks = { W = false, A = false, S = false, D = false }

local function sk(down, key)
    pcall(VirtualInputManager.SendKeyEvent, VirtualInputManager, down, key, false, game)
end

local function releaseAll()
    for n, p in pairs(ks) do
        if p then sk(false, KC[n]); ks[n] = false end
    end
end

local function fireKeys(dir)
    if not dir or dir.Magnitude < 0.01 then releaseAll() return end
    local d = Vector3.new(dir.X, 0, dir.Z)
    if d.Magnitude < 0.001 then releaseAll() return end
    d = d.Unit

    local cf = camera.CFrame
    local fw = Vector3.new(cf.LookVector.X,  0, cf.LookVector.Z)
    local rt = Vector3.new(cf.RightVector.X, 0, cf.RightVector.Z)
    fw = fw.Magnitude > 0.001 and fw.Unit or Vector3.new(0, 0, -1)
    rt = rt.Magnitude > 0.001 and rt.Unit or Vector3.new(1, 0,  0)

    local f, r = d:Dot(fw), d:Dot(rt)
    local T    = 0.02

    if     f >  T then if not ks.W then sk(true, KC.W) ks.W=true  end  if ks.S then sk(false,KC.S) ks.S=false end
    elseif f < -T then if not ks.S then sk(true, KC.S) ks.S=true  end  if ks.W then sk(false,KC.W) ks.W=false end
    else                if ks.W    then sk(false,KC.W) ks.W=false end   if ks.S then sk(false,KC.S) ks.S=false end end

    if     r >  T then if not ks.D then sk(true, KC.D) ks.D=true  end  if ks.A then sk(false,KC.A) ks.A=false end
    elseif r < -T then if not ks.A then sk(true, KC.A) ks.A=true  end  if ks.D then sk(false,KC.D) ks.D=false end
    else                if ks.D    then sk(false,KC.D) ks.D=false end   if ks.A then sk(false,KC.A) ks.A=false end end
end

local lastJump = 0
local function doJump()
    local t = os.clock()
    if t - lastJump < 0.15 then return end
    lastJump = t
    sk(true,  KC.Space)
    task.delay(0.04, function() sk(false, KC.Space) end)
end

-- ══════════════════════════════════════════
--  AUTO SHOOT
-- ══════════════════════════════════════════
local lastShot = 0
local function autoShoot()
    if not Settings.AUTO_SHOOT or not Settings.AUTOPLAY then return end
    if not aimbotTarget or not aimbotTarget.Character then return end
    local now = os.clock()
    if now - lastShot < Settings.SHOOT_COOLDOWN then return end
    lastShot = now
    pcall(function()
        VirtualInputManager:SendMouseButtonEvent(0, 0, 0, true,  game, 0)
        task.delay(0.05, function()
            VirtualInputManager:SendMouseButtonEvent(0, 0, 0, false, game, 0)
        end)
    end)
end

-- ══════════════════════════════════════════
--  JUKE
-- ══════════════════════════════════════════
local jukeActive   = false
local jukeCooldown = 0

local function doJuke()
    if jukeActive then return end
    local now = os.clock()
    if now - jukeCooldown < 0.5 then return end
    jukeCooldown = now
    jukeActive   = true
    releaseAll()
    local dirs = { {"A"}, {"D"}, {"W","A"}, {"W","D"}, {"S","A"}, {"S","D"} }
    local pick = dirs[math.random(1, #dirs)]
    for _, k in ipairs(pick) do sk(true, KC[k]); ks[k] = true end
    task.delay(0.25 + math.random() * 0.2, function()
        releaseAll()
        jukeActive = false
    end)
end

local function checkJuke()
    if not Settings.JUKE or not Settings.AUTOPLAY then return end
    local myHRP = player.Character and player.Character:FindFirstChild("HumanoidRootPart")
    if not myHRP then return end
    for _, plr in ipairs(Players:GetPlayers()) do
        if isEnemy(plr) and plr.Character then
            local hrp = plr.Character:FindFirstChild("HumanoidRootPart")
            if hrp and (hrp.Position - myHRP.Position).Magnitude < Settings.JUKE_RANGE then
                doJuke()
                return
            end
        end
    end
end

-- ══════════════════════════════════════════
--  AUTO DODGE
-- ══════════════════════════════════════════
local CFG = {
    DetectionRange    = 999,
    HitboxPadding     = 6.5,
    MinKnifeSpeed     = 0.1,
    JumpHeightThresh  = 4.5,
    FutureLookAhead   = 2.0,
    ExtraBurstDist    = 9.0,
    ExtraMaxBurstTime = 0.45,
    DotFacing         = 0.0,
    SweepDirs         = 70,
    WalkSpeed         = 16,
    SafeMargin        = 1.5,
}

local SWEEP = {}
for i = 0, CFG.SweepDirs - 1 do
    local a = (i / CFG.SweepDirs) * math.pi * 2
    SWEEP[i + 1] = Vector3.new(math.cos(a), 0, math.sin(a))
end

local dodgeActive    = false
local extraActive    = false
local extraDir       = Vector3.new(1, 0, 0)
local extraTargetPos = nil
local extraStartT    = 0
local lastDir        = Vector3.new(1, 0, 0)
local charParts      = {}
local charFeet       = {}
local charHRP        = nil

local HITBOX_NAMES = {
    "Head","UpperTorso","LowerTorso","HumanoidRootPart","Torso",
    "Left Arm","Right Arm","Left Leg","Right Leg",
    "LeftUpperArm","RightUpperArm","LeftLowerArm","RightLowerArm",
    "LeftHand","RightHand","LeftUpperLeg","RightUpperLeg",
    "LeftLowerLeg","RightLowerLeg","LeftFoot","RightFoot",
}
local FEET_NAMES = { "LeftFoot","RightFoot","LeftLowerLeg","RightLowerLeg","Left Leg","Right Leg" }

local function rebuildCache(char)
    charParts, charFeet = {}, {}
    charHRP = char:FindFirstChild("HumanoidRootPart")
    for _, n in ipairs(HITBOX_NAMES) do
        local p = char:FindFirstChild(n)
        if p and p:IsA("BasePart") then charParts[#charParts + 1] = p end
    end
    for _, n in ipairs(FEET_NAMES) do
        local p = char:FindFirstChild(n)
        if p and p:IsA("BasePart") then charFeet[#charFeet + 1] = p end
    end
end

local function getFeetY()
    local lo = math.huge
    for _, p in ipairs(charFeet) do if p.Position.Y < lo then lo = p.Position.Y end end
    return lo == math.huge and (charHRP and charHRP.Position.Y - 2.5 or 0) or lo
end

local function clearanceForDir(dir, hrpPos, th)
    local mt = math.min(th.t, 0.5)
    local fx  = hrpPos.X + dir.X * CFG.WalkSpeed * mt
    local fz  = hrpPos.Z + dir.Z * CFG.WalkSpeed * mt
    local ox, oz = th.pos.X, th.pos.Z
    local dx, dz = th.vd2.X, th.vd2.Z
    local ex, ez = fx - ox, fz - oz
    local proj   = math.max(0, ex * dx + ez * dz)
    local cx, cz = ox + dx * proj, oz + dz * proj
    local rx, rz = fx - cx, fz - cz
    return math.sqrt(rx * rx + rz * rz)
end

local function bestDodge(hrpPos, threats)
    if #threats == 0 then return nil end
    local safe   = CFG.HitboxPadding * CFG.SafeMargin
    local bestD, bestS = nil, -math.huge

    local function scoreDir(dir)
        local minC, total = math.huge, 0
        for _, th in ipairs(threats) do
            local c = clearanceForDir(dir, hrpPos, th)
            if c < minC then minC = c end
            total = total + (c >= safe and c * th.urgency or -(safe - c) * 20 * th.urgency)
        end
        if minC < CFG.HitboxPadding then return -math.huge end
        return total
    end

    for _, dir in ipairs(SWEEP) do
        local s = scoreDir(dir)
        if s > bestS then bestS = s; bestD = dir end
    end
    for _, th in ipairs(threats) do
        for _, dir in ipairs({ th.pA, th.pB, th.aw, th.bestPerp }) do
            if dir and dir.Magnitude > 0.01 then
                local s = scoreDir(dir.Unit)
                if s > bestS then bestS = s; bestD = dir.Unit end
            end
        end
    end
    if not bestD or bestS == -math.huge then
        bestS = -math.huge
        for _, dir in ipairs(SWEEP) do
            local minC = math.huge
            for _, th in ipairs(threats) do
                local c = clearanceForDir(dir, hrpPos, th)
                if c < minC then minC = c end
            end
            if minC > bestS then bestS = minC; bestD = dir end
        end
    end
    return bestD
end

local function checkThreat(part, data, hrpPos, feetY)
    local vel   = data.vel
    local speed = vel.Magnitude
    if speed < CFG.MinKnifeSpeed then return nil end
    local pos = part.Position
    local toP = hrpPos - pos
    local dist = toP.Magnitude
    if dist > CFG.DetectionRange then return nil end
    if dist > 0.001 and toP:Dot(vel) / (dist * speed) < CFG.DotFacing then return nil end

    local pad  = CFG.HitboxPadding
    local maxT = CFG.FutureLookAhead
    local a    = vel:Dot(vel)
    if a < 1e-10 then return nil end
    local inv2a = 1 / (2 * a)
    local bestT, bestPart = math.huge, nil

    for _, hp in ipairs(charParts) do
        local oc = pos - hp.Position
        local b  = 2 * oc:Dot(vel)
        local c  = oc:Dot(oc) - pad * pad
        local disc = b * b - 4 * a * c
        if disc >= 0 then
            local sq = math.sqrt(disc)
            local t  = (-b - sq) * inv2a
            if t < 0 then t = (-b + sq) * inv2a end
            if t >= 0 and t <= maxT and t < bestT then bestT = t; bestPart = hp end
        end
    end
    if not bestPart then return nil end

    local kp  = pos + vel * bestT
    local vd2 = Vector3.new(vel.X, 0, vel.Z)
    vd2 = vd2.Magnitude > 0.001 and vd2.Unit or Vector3.new(1, 0, 0)
    local pA = Vector3.new(-vd2.Z, 0,  vd2.X)
    local pB = Vector3.new( vd2.Z, 0, -vd2.X)
    local aw = Vector3.new(hrpPos.X - kp.X, 0, hrpPos.Z - kp.Z)
    aw = aw.Magnitude > 0.01 and aw.Unit or -vd2
    local bp = pA:Dot(aw) >= pB:Dot(aw) and pA or pB

    return {
        t        = bestT,
        kp       = kp,
        vel      = vel,
        pos      = pos,
        speed    = speed,
        pA       = pA,
        pB       = pB,
        bestPerp = bp,
        aw       = aw,
        vd2      = vd2,
        needJump = (kp.Y <= feetY + CFG.JumpHeightThresh) and bestT < 0.5,
        urgency  = 1 / (bestT + 0.01),
    }
end

local knifeSet  = {}
local knifeData = {}
local knifeList = {}

local function isKnifeName(n)
    local l = n:lower()
    return l:find("knife") or l:find("projectile") or l:find("throw")
        or l:find("shuriken") or l:find("bullet") or l:find("axe")
        or l:find("rock") or l:find("spear") or l:find("dart")
        or l:find("sword") or l:find("star") or l:find("orb")
        or l:find("arrow") or l:find("shard") or l:find("bolt")
end

local function spawnDodge(vel, knifePos)
    if not Settings.AUTO_DODGE or not Settings.AUTOPLAY then return end
    local hrp = charHRP
    if not hrp then return end
    if vel.Magnitude < CFG.MinKnifeSpeed then return end
    local hrpPos = hrp.Position
    local vFlat  = Vector3.new(vel.X, 0, vel.Z)
    if vFlat.Magnitude < 0.001 then return end
    vFlat = vFlat.Unit
    local away = Vector3.new(hrpPos.X - knifePos.X, 0, hrpPos.Z - knifePos.Z)
    away = away.Magnitude > 0.01 and away.Unit or -vFlat
    local pA = Vector3.new(-vFlat.Z, 0,  vFlat.X)
    local pB = Vector3.new( vFlat.Z, 0, -vFlat.X)
    local bp = pA:Dot(away) >= pB:Dot(away) and pA or pB
    local distToPlayer = (hrpPos - knifePos).Magnitude
    local estimatedT   = math.max(0.05, distToPlayer / math.max(vel.Magnitude, 1))
    local fakeThreat = {
        t = estimatedT, kp = knifePos + vel * estimatedT,
        vel = vel, pos = knifePos, speed = vel.Magnitude,
        pA = pA, pB = pB, bestPerp = bp, aw = away, vd2 = vFlat,
        urgency = 1 / (estimatedT + 0.01),
    }
    local dodgeDir = bestDodge(hrpPos, { fakeThreat }) or bp
    lastDir     = dodgeDir
    dodgeActive = true
    extraActive = false
    extraTargetPos = nil
    fireKeys(dodgeDir)
    if knifePos.Y <= getFeetY() + CFG.JumpHeightThresh then doJump() end
end

local function addKnife(obj)
    if not isKnifeName(obj.Name) then return end
    local part = obj:IsA("BasePart") and obj
              or (obj:IsA("Model") and (obj.PrimaryPart or obj:FindFirstChildWhichIsA("BasePart")))
    if not part or knifeSet[part] then return end
    local vel  = part.Velocity
    local pos  = part.Position
    local data = { lastPos = pos, vel = vel, born = os.clock(), frames = 0 }
    knifeSet[part]  = true
    knifeData[part] = data
    table.insert(knifeList, part)
    spawnDodge(vel, pos)
    local fired = false
    local conn
    conn = part:GetPropertyChangedSignal("Velocity"):Connect(function()
        if fired or not knifeSet[part] then conn:Disconnect() return end
        local v = part.Velocity
        if v.Magnitude > 0.5 then
            fired    = true
            data.vel = v
            spawnDodge(v, part.Position)
            conn:Disconnect()
        end
    end)
    task.defer(function()
        if not knifeSet[part] then return end
        local v = part.Velocity
        if v.Magnitude > data.vel.Magnitude * 0.5 then
            data.vel = v
            if not fired then spawnDodge(v, part.Position) end
        end
    end)
end

local function removeKnife(obj)
    local part = obj:IsA("BasePart") and obj
              or (obj:IsA("Model") and (obj.PrimaryPart or obj:FindFirstChildWhichIsA("BasePart")))
    if part and knifeSet[part] then
        knifeSet[part]  = nil
        knifeData[part] = nil
        for i, v in ipairs(knifeList) do
            if v == part then table.remove(knifeList, i) break end
        end
    end
end

local function connectFolder(folder)
    for _, obj in ipairs(folder:GetDescendants()) do addKnife(obj) end
    folder.DescendantAdded:Connect(addKnife)
    folder.DescendantRemoving:Connect(removeKnife)
end

task.spawn(function()
    local names = { "ProjectilesAndDebris","Projectiles","Debris","Knives","Throwables","Bullets" }
    for _, n in ipairs(names) do
        local f = Workspace:FindFirstChild(n)
        if f then connectFolder(f) return end
    end
    connectFolder(Workspace)
end)

local function updateKnives(dt)
    local i = 1
    while i <= #knifeList do
        local part = knifeList[i]
        if not part or not part.Parent then
            if part then knifeSet[part] = nil; knifeData[part] = nil end
            table.remove(knifeList, i)
        else
            local d = knifeData[part]
            if d and dt > 0 then
                local np = part.Position
                local dv = (np - d.lastPos) / dt
                d.frames = (d.frames or 0) + 1
                d.vel    = d.frames <= 2 and (dv * 0.3 + part.Velocity * 0.7)
                                         or (dv * 0.88 + part.Velocity * 0.12)
                d.lastPos = np
            end
            i = i + 1
        end
    end
end

-- ══════════════════════════════════════════
--  GUI — AUTOPLAY BUTTON WITH PNGs + SMALL PANEL
-- ══════════════════════════════════════════
local mainGui = Instance.new("ScreenGui")
mainGui.Name          = "MainGui"
mainGui.ResetOnSpawn  = false
mainGui.ZIndexBehavior = Enum.ZIndexBehavior.Sibling
mainGui.Parent        = playerGui

-- Autoplay image button
local autoplayBtn = Instance.new("ImageButton")
autoplayBtn.Name            = "AutoplayBtn"
autoplayBtn.Size            = UDim2.new(0, 200, 0, 57)
autoplayBtn.Position        = UDim2.new(0.5, -100, 0, 20)
autoplayBtn.BackgroundTransparency = 1
autoplayBtn.Image           = Settings.AUTOPLAY and IMG_ON or IMG_OFF
autoplayBtn.ScaleType       = Enum.ScaleType.Fit
autoplayBtn.Active          = true
autoplayBtn.Parent          = mainGui

-- Small status panel
local panel = Instance.new("Frame")
panel.Name                = "Panel"
panel.Size                = UDim2.new(0, 180, 0, 170)
panel.Position            = UDim2.new(0, 15, 0.35, 0)
panel.BackgroundColor3    = Color3.fromRGB(18, 18, 28)
panel.BackgroundTransparency = 0.05
panel.BorderSizePixel     = 0
panel.Active              = true
panel.Draggable           = true
panel.Parent              = mainGui
Instance.new("UICorner", panel).CornerRadius = UDim.new(0, 10)

local function makeLabel(parent, text, yOff, color)
    local l = Instance.new("TextLabel")
    l.Size                = UDim2.new(1, -10, 0, 22)
    l.Position            = UDim2.new(0, 5, 0, yOff)
    l.BackgroundTransparency = 1
    l.Text                = text
    l.TextColor3          = color or Color3.new(1,1,1)
    l.TextScaled          = true
    l.Font                = Enum.Font.GothamBold
    l.TextXAlignment      = Enum.TextXAlignment.Left
    l.Parent              = parent
    return l
end

local function makeBtn(parent, text, yOff, color)
    local b = Instance.new("TextButton")
    b.Size               = UDim2.new(1, -20, 0, 24)
    b.Position           = UDim2.new(0, 10, 0, yOff)
    b.BackgroundColor3   = color or Color3.fromRGB(60,60,80)
    b.TextColor3         = Color3.new(1,1,1)
    b.Text               = text
    b.TextScaled         = true
    b.Font               = Enum.Font.GothamBold
    b.BorderSizePixel    = 0
    b.Parent             = parent
    Instance.new("UICorner", b).CornerRadius = UDim.new(0, 6)
    return b
end

local titleLbl  = makeLabel(panel, "⚡ SCRIPT v2",    5,  Color3.fromRGB(180,180,255))
local aimbotBtn = makeBtn  (panel, "Aimbot: ON",     30,  Color3.fromRGB(50,180,50))
local espBtn    = makeBtn  (panel, "ESP: ON",        58,  Color3.fromRGB(100,50,160))
local dodgeBtn  = makeBtn  (panel, "AutoDodge: ON",  86,  Color3.fromRGB(50,80,180))
local shootBtn  = makeBtn  (panel, "AutoShoot: ON",  114, Color3.fromRGB(180,80,50))
local jukeBtn   = makeBtn  (panel, "Juke: ON",       142, Color3.fromRGB(160,130,30))

-- FOV circle
local fovGui = Instance.new("ScreenGui")
fovGui.Name         = "FovGui"
fovGui.ResetOnSpawn = false
fovGui.Parent       = playerGui

local fovCircle = Instance.new("Frame")
fovCircle.Size                  = UDim2.new(0, Settings.FOV_RADIUS*2, 0, Settings.FOV_RADIUS*2)
fovCircle.AnchorPoint           = Vector2.new(0.5, 0.5)
fovCircle.Position              = UDim2.new(0.5, 0, 0.5, 0)
fovCircle.BackgroundColor3      = Color3.fromRGB(255, 0, 0)
fovCircle.BackgroundTransparency = 0.9
fovCircle.BorderSizePixel       = 0
fovCircle.Visible               = Settings.AIMBOT
fovCircle.Parent                = fovGui
Instance.new("UICorner", fovCircle).CornerRadius = UDim.new(1, 0)

-- Button callbacks
autoplayBtn.MouseButton1Click:Connect(function()
    Settings.AUTOPLAY = not Settings.AUTOPLAY
    autoplayBtn.Image = Settings.AUTOPLAY and IMG_ON or IMG_OFF
    if not Settings.AUTOPLAY then releaseAll() end
end)

aimbotBtn.MouseButton1Click:Connect(function()
    Settings.AIMBOT = not Settings.AIMBOT
    aimbotBtn.Text  = "Aimbot: " .. (Settings.AIMBOT and "ON" or "OFF")
    aimbotBtn.BackgroundColor3 = Settings.AIMBOT and Color3.fromRGB(50,180,50) or Color3.fromRGB(160,50,50)
    fovCircle.Visible = Settings.AIMBOT
    if not Settings.AIMBOT then
        UserInputService.MouseBehavior   = Enum.MouseBehavior.Default
        UserInputService.MouseIconEnabled = true
        MOUSE_LOCKED = false
    end
end)

espBtn.MouseButton1Click:Connect(function()
    Settings.ESP = not Settings.ESP
    espBtn.Text  = "ESP: " .. (Settings.ESP and "ON" or "OFF")
    espBtn.BackgroundColor3 = Settings.ESP and Color3.fromRGB(100,50,160) or Color3.fromRGB(160,50,50)
    updateESP()
end)

dodgeBtn.MouseButton1Click:Connect(function()
    Settings.AUTO_DODGE = not Settings.AUTO_DODGE
    dodgeBtn.Text = "AutoDodge: " .. (Settings.AUTO_DODGE and "ON" or "OFF")
    dodgeBtn.BackgroundColor3 = Settings.AUTO_DODGE and Color3.fromRGB(50,80,180) or Color3.fromRGB(160,50,50)
end)

shootBtn.MouseButton1Click:Connect(function()
    Settings.AUTO_SHOOT = not Settings.AUTO_SHOOT
    shootBtn.Text = "AutoShoot: " .. (Settings.AUTO_SHOOT and "ON" or "OFF")
    shootBtn.BackgroundColor3 = Settings.AUTO_SHOOT and Color3.fromRGB(180,80,50) or Color3.fromRGB(160,50,50)
end)

jukeBtn.MouseButton1Click:Connect(function()
    Settings.JUKE = not Settings.JUKE
    jukeBtn.Text  = "Juke: " .. (Settings.JUKE and "ON" or "OFF")
    jukeBtn.BackgroundColor3 = Settings.JUKE and Color3.fromRGB(160,130,30) or Color3.fromRGB(160,50,50)
end)

-- ══════════════════════════════════════════
--  CHARACTER EVENTS
-- ══════════════════════════════════════════
local function onCharAdded(char)
    task.wait(0.3)
    rebuildCache(char)
    dodgeActive = false; extraActive = false; extraTargetPos = nil
    releaseAll()
    camera.CameraType = Enum.CameraType.Custom
    UserInputService.MouseBehavior    = Enum.MouseBehavior.Default
    UserInputService.MouseIconEnabled = true
    MOUSE_LOCKED = false
end

player.CharacterAdded:Connect(onCharAdded)
if player.Character then
    task.spawn(function() task.wait(0.1) rebuildCache(player.Character) end)
end

-- ══════════════════════════════════════════
--  MAIN LOOP
-- ══════════════════════════════════════════
local lastT = os.clock()
local fc    = 0

RunService.RenderStepped:Connect(function()
    local now = os.clock()
    local dt  = now - lastT
    lastT     = now

    updateKnives(dt)
    updateESP()

    -- AIMBOT
    if Settings.AIMBOT and Settings.AUTOPLAY then
        aimbotTarget = getClosestToCrosshair()
        if aimbotTarget and aimbotTarget.Character then
            local hrp = aimbotTarget.Character:FindFirstChild("HumanoidRootPart")
            if hrp then
                camera.CFrame = CFrame.new(camera.CFrame.Position, hrp.Position)
                if not MOUSE_LOCKED then
                    UserInputService.MouseBehavior    = Enum.MouseBehavior.LockCenter
                    UserInputService.MouseIconEnabled = false
                    MOUSE_LOCKED = true
                end
                autoShoot()
            end
        else
            aimbotTarget = nil
            if MOUSE_LOCKED then
                UserInputService.MouseBehavior    = Enum.MouseBehavior.Default
                UserInputService.MouseIconEnabled = true
                MOUSE_LOCKED = false
            end
        end
    elseif MOUSE_LOCKED then
        UserInputService.MouseBehavior    = Enum.MouseBehavior.Default
        UserInputService.MouseIconEnabled = true
        MOUSE_LOCKED = false
    end

    if not Settings.AUTOPLAY then return end

    -- JUKE check every 6 frames
    fc = fc + 1
    if fc % 6 == 0 then checkJuke() end

    -- AUTO DODGE
    if not Settings.AUTO_DODGE then return end

    local char = player.Character
    if not char then releaseAll() return end
    local hrp = char:FindFirstChild("HumanoidRootPart")
    if not hrp then releaseAll() return end
    if #charParts == 0 then rebuildCache(char) end
    if #charParts == 0 then return end

    local hrpPos = hrp.Position
    local feetY  = getFeetY()
    local threats = {}

    for _, part in ipairs(knifeList) do
        local data = knifeData[part]
        if data and part.Parent then
            local th = checkThreat(part, data, hrpPos, feetY)
            if th then threats[#threats + 1] = th end
        end
    end
    if #threats > 1 then table.sort(threats, function(a,b) return a.t < b.t end) end

    if #threats > 0 then
        local dodgeDir = bestDodge(hrpPos, threats)
        if dodgeDir then lastDir = dodgeDir; fireKeys(dodgeDir) end
        for i = 1, math.min(2, #threats) do
            if threats[i].needJump then doJump() break end
        end
        dodgeActive    = true
        extraActive    = false
        extraTargetPos = nil
    elseif dodgeActive then
        dodgeActive    = false
        extraActive    = true
        extraDir       = lastDir
        extraTargetPos = hrpPos + lastDir * CFG.ExtraBurstDist
        extraStartT    = now
        fireKeys(extraDir)
    else
        if extraActive then
            local tgt = extraTargetPos or (hrpPos + extraDir * CFG.ExtraBurstDist)
            local horiz = Vector3.new(hrpPos.X, 0, hrpPos.Z)
            local tH    = Vector3.new(tgt.X,    0, tgt.Z)
            if (horiz - tH).Magnitude > 0.35 and now < extraStartT + CFG.ExtraMaxBurstTime then
                fireKeys(extraDir)
            else
                extraActive    = false
                extraTargetPos = nil
                releaseAll()
            end
        else
            if not jukeActive then releaseAll() end
        end
    end
end)

-- ══════════════════════════════════════════
--  NOTIFICATION
-- ══════════════════════════════════════════
task.wait(1)
pcall(function()
    StarterGui:SetCore("SendNotification", {
        Title   = "Script Loaded",
        Text    = "Autoplay | Aimbot | ESP | Dodge | Shoot | Juke — Enemy=Murder",
        Duration = 6,
    })
end)

print("[Script] Loaded. Enemy = Murder team. Autoplay ON.")
