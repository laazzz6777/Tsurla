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
--  §2  PLAYSTYLE DEFINITIONS
--  Each playstyle is a table of brain weight overrides.
--  Auto = balanced, Passive = defensive, Aggro = offensive.
-- ════════════════════════════════════════════════════════════════════════
local PLAYSTYLES = {
    auto = {
        name          = "AUTO",
        color         = Color3.fromRGB(90, 180, 255),
        dodge         = 1.72,
        juke          = 1.18,
        engage        = 1.30,
        retreat       = 0.58,
        navigate      = 0.95,
        wait_reload   = 1.15,
        retreatHPGate = 0.35,   -- retreat below this HP fraction
        engageMinHP   = 0.20,   -- won't engage below this HP fraction
        aggroChaseMax = 340,    -- max studs to chase enemy
        strafeFreq    = 2.8,    -- strafe oscillation Hz
    },
    passive = {
        name          = "PASSIVE",
        color         = Color3.fromRGB(90, 255, 140),
        dodge         = 2.10,
        juke          = 0.80,
        engage        = 0.85,
        retreat       = 1.60,
        navigate      = 0.60,
        wait_reload   = 1.55,
        retreatHPGate = 0.60,
        engageMinHP   = 0.45,
        aggroChaseMax = 160,
        strafeFreq    = 3.8,
    },
    aggro = {
        name          = "AGGRO",
        color         = Color3.fromRGB(255, 75, 75),
        dodge         = 1.30,
        juke          = 1.55,
        engage        = 2.20,
        retreat       = 0.28,
        navigate      = 1.65,
        wait_reload   = 0.70,
        retreatHPGate = 0.12,
        engageMinHP   = 0.05,
        aggroChaseMax = 999,
        strafeFreq    = 1.9,
    },
}

local currentPlaystyle = "auto"   -- "auto" | "passive" | "aggro"

local function getStyle() return PLAYSTYLES[currentPlaystyle] end

-- ════════════════════════════════════════════════════════════════════════
--  §3  MASTER CONFIG
-- ════════════════════════════════════════════════════════════════════════
local CFG = {
    -- ── Toggles ─────────────────────────────────────────────────────────
    AutoNavEnabled      = true,
    AutoAimEnabled      = true,
    AutoShootEnabled    = true,
    DodgeEnabled        = true,
    JukeEnabled         = true,
    ESPEnabled          = true,

    -- ── Range ───────────────────────────────────────────────────────────
    EntityTrackRange    = 999,   -- studs: global entity registry range
    DodgeDetectRange    = 130,   -- studs: knife/projectile threat detection range
    MeleeRange          = 5.2,
    EngageMoveRange     = 14,

    -- ── Combat ──────────────────────────────────────────────────────────
    ReloadTime          = 2.50,

    -- ── Movement ────────────────────────────────────────────────────────
    WalkSpeed           = 16,
    JumpCooldown        = 0.15,
    JumpHeightThreshold = 4.5,
    KeyThreshold        = 0.02,
    StuckWindow         = 1.4,
    StuckThreshold      = 0.30,

    -- ── Repositioning (anti-camp) ────────────────────────────────────────
    RepositionInterval  = 5.0,   -- seconds before bot decides to reposition
    RepositionRadius    = 22,    -- studs: how far to reposition laterally

    -- ── MCTS ────────────────────────────────────────────────────────────
    MCTSInterval        = 0.35,
    MCTSSimulations     = 16,
    MCTSDepth           = 7,
    MCTSStepSize        = 3.8,

    -- ── Dodge ───────────────────────────────────────────────────────────
    MinProjectileSpeed  = 0.10,
    FutureLookAhead     = 2.20,
    DotFacingThreshold  = 0.00,
    SweepDirs           = 128,
    ExtraBurstDistance  = 9.0,
    ExtraMaxBurstTime   = 0.45,
    HitboxPadding       = 6.5,
    SafeMarginMult      = 1.55,

    -- ── Wall check (low-medium) ──────────────────────────────────────────
    WallCheckStrict     = 0.42,

    -- ── Camera blend for navigation ──────────────────────────────────────
    CamNavBlend         = 0.18,   -- how fast camera pans toward nav direction
    CamAimBlend         = 0.55,   -- how fast camera snaps to aim point

    -- ── Learning ────────────────────────────────────────────────────────
    LearningRate        = 0.024,
    WeightClampLo       = 0.05,
    WeightClampHi       = 4.50,

    -- ── Enemy filter ────────────────────────────────────────────────────
    EnemyKeyword        = "murder",
}

-- ════════════════════════════════════════════════════════════════════════
--  §4  PRE-COMPUTED SWEEP DIRECTIONS
-- ════════════════════════════════════════════════════════════════════════
local SWEEP = {}
for _i = 0, CFG.SweepDirs - 1 do
    local a = (_i / CFG.SweepDirs) * math.pi * 2
    SWEEP[_i + 1] = Vector3.new(math.cos(a), 0, math.sin(a))
end

-- ════════════════════════════════════════════════════════════════════════
--  §5  VIM KEY MANAGEMENT
-- ════════════════════════════════════════════════════════════════════════
local KC = { W=Enum.KeyCode.W, A=Enum.KeyCode.A,
             S=Enum.KeyCode.S, D=Enum.KeyCode.D, Space=Enum.KeyCode.Space }
local keyState = { W=false, A=false, S=false, D=false }

local function sendKey(down, key)
    pcall(VirtualInputManager.SendKeyEvent, VirtualInputManager, down, key, false, game)
end

local function releaseAll()
    for n, p in pairs(keyState) do
        if p then sendKey(false, KC[n]); keyState[n] = false end
    end
end

-- Convert world-space XZ dir → camera-relative WASD presses
local function fireKeys(dir)
    if not dir or dir.Magnitude < 0.001 then releaseAll(); return end
    local d = Vector3.new(dir.X, 0, dir.Z)
    if d.Magnitude < 0.001 then releaseAll(); return end
    d = d.Unit

    local cf = Camera.CFrame
    local fw = Vector3.new(cf.LookVector.X,  0, cf.LookVector.Z)
    local rt = Vector3.new(cf.RightVector.X, 0, cf.RightVector.Z)
    fw = fw.Magnitude > 0.001 and fw.Unit or Vector3.new(0,0,-1)
    rt = rt.Magnitude > 0.001 and rt.Unit or Vector3.new(1,0,0)

    local fDot, rDot = d:Dot(fw), d:Dot(rt)
    local T = CFG.KeyThreshold

    if fDot > T then
        if not keyState.W then sendKey(true, KC.W);  keyState.W=true  end
        if     keyState.S then sendKey(false,KC.S);  keyState.S=false end
    elseif fDot < -T then
        if not keyState.S then sendKey(true, KC.S);  keyState.S=true  end
        if     keyState.W then sendKey(false,KC.W);  keyState.W=false end
    else
        if keyState.W then sendKey(false,KC.W); keyState.W=false end
        if keyState.S then sendKey(false,KC.S); keyState.S=false end
    end

    if rDot > T then
        if not keyState.D then sendKey(true, KC.D);  keyState.D=true  end
        if     keyState.A then sendKey(false,KC.A);  keyState.A=false end
    elseif rDot < -T then
        if not keyState.A then sendKey(true, KC.A);  keyState.A=true  end
        if     keyState.D then sendKey(false,KC.D);  keyState.D=false end
    else
        if keyState.D then sendKey(false,KC.D); keyState.D=false end
        if keyState.A then sendKey(false,KC.A); keyState.A=false end
    end
end

-- ── Camera control ───────────────────────────────────────────────────────
-- Used for NAVIGATION: gently rotates camera toward a world direction
-- so that W always moves the character in the intended heading.
local function camTurnToward(worldDir, blend)
    if not worldDir or worldDir.Magnitude < 0.001 then return end
    local flat = Vector3.new(worldDir.X, 0, worldDir.Z)
    if flat.Magnitude < 0.001 then return end
    flat = flat.Unit
    local camPos  = Camera.CFrame.Position
    local curLook = Camera.CFrame.LookVector
    local newLook = (curLook + flat * blend)
    if newLook.Magnitude > 0.001 then
        -- preserve vertical look angle
        Camera.CFrame = CFrame.new(camPos, camPos + newLook.Unit)
    end
end

-- Used for AIMING: hard snap camera to look exactly at a world point
local function camAimAt(worldPos)
    if not worldPos then return end
    Camera.CFrame = CFrame.new(Camera.CFrame.Position, worldPos)
end

local lastJumpTime = 0
local function doJump()
    local t = os.clock()
    if t - lastJumpTime < CFG.JumpCooldown then return end
    lastJumpTime = t
    sendKey(true, KC.Space)
    task.delay(0.05, function() sendKey(false, KC.Space) end)
end

-- ════════════════════════════════════════════════════════════════════════
--  §6  PING  —  GetNetworkPing() is ONE-WAY in seconds.
--  Display = val * 1000 (ms).  No doubling — that was the bug.
--  Update every 1 second, light 85/15 smoothing for stable display.
-- ════════════════════════════════════════════════════════════════════════
local pingMs = 50   -- display value in milliseconds

local function updatePing()
    local ok, val = pcall(function()
        return LocalPlayer:GetNetworkPing()  -- one-way seconds
    end)
    if ok and type(val) == "number" and val > 0 and val < 2 then
        local sample = val * 1000            -- convert to ms (one-way, not doubled)
        pingMs = pingMs * 0.85 + sample * 0.15
    end
end

-- ════════════════════════════════════════════════════════════════════════
--  §7  AUTO-SHOOT   (2.5 s reload, VIM left-click at viewport centre)
-- ════════════════════════════════════════════════════════════════════════
local lastShotTime = -999
local reloadActive = false

local function canShoot()  return (os.clock()-lastShotTime) >= CFG.ReloadTime end
local function reloadPct() return math.min(1,(os.clock()-lastShotTime)/CFG.ReloadTime) end

local function doShoot()
    if not CFG.AutoShootEnabled or not canShoot() then return false end
    local vp = Camera.ViewportSize
    local cx, cy = math.floor(vp.X*0.5), math.floor(vp.Y*0.5)
    pcall(function() VirtualInputManager:SendMouseButtonEvent(cx,cy,0,true, game,1) end)
    task.delay(0.033, function()
        pcall(function() VirtualInputManager:SendMouseButtonEvent(cx,cy,0,false,game,1) end)
    end)
    lastShotTime = os.clock()
    reloadActive = true
    task.delay(CFG.ReloadTime, function() reloadActive = false end)
    return true
end

-- ════════════════════════════════════════════════════════════════════════
--  §8  ENEMY IDENTIFICATION
-- ════════════════════════════════════════════════════════════════════════
local function isEnemy(plr)
    if not plr or plr == LocalPlayer or not plr.Parent then return false end
    if plr.Team and plr.Team.Name:lower():find(CFG.EnemyKeyword) then return true end
    if LocalPlayer.Team and plr.Team then return plr.Team ~= LocalPlayer.Team end
    if not plr.Team and not LocalPlayer.Team then return true end
    return false
end

-- ════════════════════════════════════════════════════════════════════════
--  §9  GLOBAL ENTITY REGISTRY
-- ════════════════════════════════════════════════════════════════════════
local PEEK_CAP       = 24
local EntityRegistry = {}

local function regEnsure(plr)
    if not EntityRegistry[plr] then
        EntityRegistry[plr] = {
            pos=Vector3.new(), vel=Vector3.new(), health=100, maxHealth=100,
            lastCFrame=CFrame.new(), lastSeen=0, isVisible=false, wasVisible=false,
            visFraction=0, peekHistory={}, avgVel=Vector3.new(),
            hitboxParts={}, predictedPeekPos=nil, damageTaken=0, prevHealth=100,
        }
    end
    return EntityRegistry[plr]
end

local function regUpdate(plr, dt)
    local char = plr.Character; if not char then return end
    local hrp  = char:FindFirstChild("HumanoidRootPart")
    local hum  = char:FindFirstChildOfClass("Humanoid")
    if not hrp or not hum then return end

    local e      = regEnsure(plr)
    local newPos = hrp.Position
    local posVel = dt>0 and (newPos-e.pos)/dt or e.vel
    e.vel    = e.vel*0.50 + posVel*0.30 + hrp.AssemblyLinearVelocity*0.20
    e.avgVel = e.avgVel*0.90 + e.vel*0.10
    e.pos          = newPos
    e.lastCFrame   = hrp.CFrame
    e.lastSeen     = os.clock()
    e.prevHealth   = e.health
    e.health       = hum.Health
    e.maxHealth    = hum.MaxHealth
    if e.health < e.prevHealth-0.5 then
        e.damageTaken = e.damageTaken + (e.prevHealth-e.health)
    end
    local ph = e.peekHistory
    ph[#ph+1] = {pos=newPos, t=os.clock(), vel=Vector3.new(e.vel.X,0,e.vel.Z)}
    if #ph > PEEK_CAP then table.remove(ph,1) end
    local parts={}
    for _,p in ipairs(char:GetDescendants()) do
        if p:IsA("BasePart") then parts[#parts+1]=p end
    end
    e.hitboxParts  = parts
    e.wasVisible   = e.isVisible
end

-- Navigation-only position estimate (no aim prediction — bullets instant)
local function enemyNavPos(plr)
    local e = EntityRegistry[plr]; if not e then return nil end
    local stale = os.clock()-e.lastSeen
    if stale > 5 then return e.predictedPeekPos or e.pos end
    if not e.isVisible and e.wasVisible then
        local ph = e.peekHistory
        if #ph >= 6 then
            local ing = ph[#ph].pos - ph[math.max(1,#ph-6)].pos
            if ing.Magnitude > 0.4 then
                e.predictedPeekPos = e.pos - ing.Unit*1.8
            end
        end
        if e.predictedPeekPos then return e.predictedPeekPos end
    end
    return e.pos
end

local function closestEnemy(fromPos)
    local bp,be,bd = nil,nil,math.huge
    for plr,e in pairs(EntityRegistry) do
        if isEnemy(plr) and plr.Character and e.health>0 then
            local d=(e.pos-fromPos).Magnitude
            if d<bd then bd=d; bp=plr; be=e end
        end
    end
    return bp,be,bd
end

-- ════════════════════════════════════════════════════════════════════════
--  §10  LOCAL CHARACTER CACHE
-- ════════════════════════════════════════════════════════════════════════
local charParts={}, charFeet={}, charHRP=nil, charHuman=nil

local HIT_NAMES = {
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

local function rebuildChar(char)
    charParts,charFeet={},{}
    charHRP   = char:FindFirstChild("HumanoidRootPart")
    charHuman = char:FindFirstChildOfClass("Humanoid")
    for _,n in ipairs(HIT_NAMES) do
        local p=char:FindFirstChild(n)
        if p and p:IsA("BasePart") then charParts[#charParts+1]=p end
    end
    for _,n in ipairs(FEET_NAMES) do
        local p=char:FindFirstChild(n)
        if p and p:IsA("BasePart") then charFeet[#charFeet+1]=p end
    end
end

local function getFeetY()
    local lo=math.huge
    for _,p in ipairs(charFeet) do
        local y=p.Position.Y-p.Size.Y*0.5
        if y<lo then lo=y end
    end
    return lo==math.huge and (charHRP and charHRP.Position.Y-2.6 or 0) or lo
end

local function getLocalHP()
    if charHuman then return charHuman.Health, charHuman.MaxHealth end
    return 100,100
end

-- ════════════════════════════════════════════════════════════════════════
--  §11  12-POINT ATOMIC LINE-OF-SIGHT
-- ════════════════════════════════════════════════════════════════════════
local function atomicLoS(tChar, originPos)
    if not tChar then return 0,12,0,nil end
    local myChar=LocalPlayer.Character
    local fl={}
    if myChar then
        fl[1]=myChar
        for _,p in ipairs(myChar:GetDescendants()) do
            if p:IsA("BasePart") then fl[#fl+1]=p end
        end
    end
    local params=RaycastParams.new()
    params.FilterType=Enum.RaycastFilterType.Blacklist
    params.FilterDescendantsInstances=fl

    local ORDER={
        "Head","UpperTorso","Torso","HumanoidRootPart","LowerTorso",
        "LeftUpperArm","RightUpperArm","LeftUpperLeg","RightUpperLeg",
        "LeftHand","RightHand","LeftFoot",
    }
    local pts={}
    for _,n in ipairs(ORDER) do
        local p=tChar:FindFirstChild(n)
        if p and p:IsA("BasePart") then
            pts[#pts+1]={pos=p.Position,part=p,pri=#pts+1}
        end
        if #pts>=12 then break end
    end
    if #pts<12 then
        for _,p in ipairs(tChar:GetDescendants()) do
            if p:IsA("BasePart") then
                pts[#pts+1]={pos=p.Position,part=p,pri=#pts+1}
            end
            if #pts>=12 then break end
        end
    end

    local vis,bestPt,bestPri=0,nil,math.huge
    for i,cp in ipairs(pts) do
        if i>12 then break end
        local r=Workspace:Raycast(originPos,cp.pos-originPos,params)
        local hit=r and r.Instance
        local ok=(r==nil) or (hit and hit:IsDescendantOf(tChar))
        if ok then
            vis=vis+1
            if cp.pri<bestPri then bestPri=cp.pri; bestPt=cp.pos end
        end
    end
    local tot=math.min(#pts,12)
    return vis,tot,vis/math.max(tot,1),bestPt
end

-- ════════════════════════════════════════════════════════════════════════
--  §12  PART-AWARE NAVIGATION
-- ════════════════════════════════════════════════════════════════════════
local function classifyPart(p)
    if not p or not p:IsA("BasePart") then return nil end
    if p:IsA("TrussPart")       then return "truss"    end
    if p:IsA("WedgePart")       then return "ramp"     end
    if p:IsA("CornerWedgePart") then return "ramp"     end
    if p.Size.Y < 1.5           then return "floor"    end
    return "obstacle"
end

local function yCorrection(hrpPos, moveDir)
    if not charHRP then return 0,nil end
    local myChar=LocalPlayer.Character
    local params=RaycastParams.new()
    params.FilterType=Enum.RaycastFilterType.Blacklist
    params.FilterDescendantsInstances=myChar and {myChar} or {}
    local dist=3.4
    local origins={
        hrpPos+Vector3.new(0,-1.8,0),
        hrpPos+Vector3.new(0, 0.0,0),
        hrpPos+Vector3.new(0, 1.2,0),
    }
    for _,o in ipairs(origins) do
        local r=Workspace:Raycast(o,moveDir*dist,params)
        if r and r.Instance then
            local cls=classifyPart(r.Instance)
            local top=r.Instance.Position.Y+r.Instance.Size.Y*0.5
            local dy=top-hrpPos.Y
            if cls=="truss"    then return dy+0.6,"truss" end
            if cls=="ramp"     then return math.max(0,dy*0.4),"ramp" end
            if cls=="obstacle" then
                return dy, dy<=CFG.JumpHeightThreshold and "step" or "wall"
            end
        end
    end
    local gh =Workspace:Raycast(hrpPos+Vector3.new(0,-0.2,0),Vector3.new(0,-8,0),params)
    local ga =Workspace:Raycast(hrpPos+moveDir*2.5+Vector3.new(0,-0.2,0),Vector3.new(0,-8,0),params)
    if gh and not ga then return -99,"ledge" end
    if gh and ga then
        local su=ga.Position.Y-gh.Position.Y
        if su>0.55 and su<CFG.JumpHeightThreshold then return su+0.25,"step" end
    end
    return 0,nil
end

local function needsJump(yDelta, cls)
    if not cls or cls=="ledge" then return false end
    if cls=="truss" then return true end
    if cls=="step"  then return yDelta and yDelta>0.3 end
    if cls=="ramp"  then return yDelta and yDelta>0.8 end
    return false
end

-- ════════════════════════════════════════════════════════════════════════
--  §13  MCTS PATH PLANNER
-- ════════════════════════════════════════════════════════════════════════
local MCTS = { dir=nil, goal=nil, lastRun=0 }

local function mctsSearch(startPos, goalPos, N)
    if not goalPos then return nil end
    local myChar=LocalPlayer.Character
    local params=RaycastParams.new()
    params.FilterType=Enum.RaycastFilterType.Blacklist
    params.FilterDescendantsInstances=myChar and {myChar} or {}

    local gf=Vector3.new(goalPos.X,0,goalPos.Z)
    local sf=Vector3.new(startPos.X,0,startPos.Z)
    local raw=gf-sf
    local gDir=raw.Magnitude>0.1 and raw.Unit or Vector3.new(0,0,-1)
    local step,depth=CFG.MCTSStepSize,CFG.MCTSDepth
    local bestScore,bestDir=-math.huge,gDir

    for _=1,N do
        local base=math.atan2(gDir.Z,gDir.X)
        local ang=base+(math.random()*2-1)*math.pi*0.55
        local fDir=Vector3.new(math.cos(ang),0,math.sin(ang))
        local pos=startPos; local score=0; local ok=true

        for d=1,depth do
            local ta=math.atan2(gDir.Z,gDir.X)
            local ca=math.atan2(fDir.Z,fDir.X)
            local ba=ca+(ta-ca)*(d/depth*0.5)
            local sd=Vector3.new(math.cos(ba),0,math.sin(ba))
            local np=pos+sd*step

            local wh=Workspace:Raycast(pos+Vector3.new(0,0.5,0),sd*(step*1.15),params)
            if wh and wh.Instance then
                local cls=classifyPart(wh.Instance)
                local top=wh.Instance.Position.Y+wh.Instance.Size.Y*0.5
                local dy=top-pos.Y
                if (cls=="obstacle" or cls=="wall") and dy>CFG.JumpHeightThreshold then
                    score=score-90; ok=false; break
                elseif cls=="obstacle" then
                    score=score-12
                end
            end
            local ga=Workspace:Raycast(np+Vector3.new(0,0.3,0),Vector3.new(0,-9,0),params)
            if not ga then score=score-70; ok=false; break end

            for tp,e in pairs(EntityRegistry) do
                if isEnemy(tp) and e.health>0 then
                    local ed=(np-e.pos).Magnitude
                    if ed<8 then score=score-50/(ed+0.5) end
                end
            end
            pos=np; score=score+6
        end
        if ok then
            local fd=Vector3.new(pos.X,0,pos.Z)-gf
            score=score+280/(fd.Magnitude+1)+fDir:Dot(gDir)*28
        end
        if score>bestScore then bestScore=score; bestDir=fDir end
    end
    return bestDir
end

-- ════════════════════════════════════════════════════════════════════════
--  §14  NEURAL-HEURISTIC BRAIN  (weights sync'd from playstyle)
-- ════════════════════════════════════════════════════════════════════════
local Brain = {
    w = {
        dodge=1.72, juke=1.18, engage=1.30,
        retreat=0.58, navigate=0.95, wait_reload=1.15,
    },
    lastAction="navigate", count=0,
}

-- Sync brain weights from current playstyle (called on mode change + each cycle)
local function syncBrainToStyle()
    local s=getStyle()
    Brain.w.dodge       = Brain.w.dodge*0.88       + s.dodge*0.12
    Brain.w.juke        = Brain.w.juke*0.88        + s.juke*0.12
    Brain.w.engage      = Brain.w.engage*0.88      + s.engage*0.12
    Brain.w.retreat     = Brain.w.retreat*0.88     + s.retreat*0.12
    Brain.w.navigate    = Brain.w.navigate*0.88    + s.navigate*0.12
    Brain.w.wait_reload = Brain.w.wait_reload*0.88 + s.wait_reload*0.12
    for k,v in pairs(Brain.w) do
        Brain.w[k]=math.max(CFG.WeightClampLo,math.min(CFG.WeightClampHi,v))
    end
end

-- Hard reset weights to style on explicit mode switch
local function hardSyncToStyle()
    local s=getStyle()
    Brain.w.dodge       = s.dodge
    Brain.w.juke        = s.juke
    Brain.w.engage      = s.engage
    Brain.w.retreat     = s.retreat
    Brain.w.navigate    = s.navigate
    Brain.w.wait_reload = s.wait_reload
end

local function brainDecide(ctx)
    local style   = getStyle()
    local hpRatio = ctx.health / math.max(ctx.maxHealth,1)
    local visFrac = ctx.visFraction or 0
    local threats = ctx.threatCount or 0
    local reload  = ctx.isReloading and 1 or 0
    local melee   = ctx.inMeleeRange and 1 or 0
    local hasTgt  = ctx.hasTarget and 1 or 0
    local dist    = ctx.targetDist or 999
    local visGate = visFrac>=CFG.WallCheckStrict and 1 or (visFrac/CFG.WallCheckStrict)

    -- Playstyle gates
    local engageHPOK  = hpRatio >= style.engageMinHP and 1 or 0
    local chaseOK     = dist<=style.aggroChaseMax and 1 or 0

    local scores = {
        dodge       = Brain.w.dodge * math.max(0, threats*0.9+(threats>0 and 0.5 or 0)),
        juke        = Brain.w.juke  * melee * (1-reload*0.25),
        engage      = Brain.w.engage * visGate * hpRatio * (1-reload)
                      * hasTgt * chaseOK * engageHPOK,
        retreat     = Brain.w.retreat * (1-hpRatio)
                      * (hpRatio < style.retreatHPGate and 2.6 or 1.0),
        navigate    = Brain.w.navigate * hasTgt * (dist>10 and 1 or 0)
                      * chaseOK * (1-(ctx.hasLoS and 0.3 or 0)),
        wait_reload = Brain.w.wait_reload * reload * (0.5+(1-hpRatio)*0.5),
    }

    local best,bestV="navigate",-math.huge
    for act,val in pairs(scores) do
        if val>bestV then bestV=val; best=act end
    end
    Brain.lastAction=best; Brain.count=Brain.count+1
    return best,scores
end

local function brainReward(r)
    local act=Brain.lastAction; local lr=CFG.LearningRate; local w=Brain.w
    if     act=="dodge"       then w.dodge       = w.dodge+lr*r
    elseif act=="juke"        then w.juke        = w.juke+lr*r
    elseif act=="engage"      then w.engage      = w.engage+lr*r
    elseif act=="retreat"     then w.retreat     = w.retreat+lr*r
    elseif act=="navigate"    then w.navigate    = w.navigate+lr*r
    elseif act=="wait_reload" then w.wait_reload = w.wait_reload+lr*r
    end
    for k,v in pairs(w) do
        Brain.w[k]=math.max(CFG.WeightClampLo,math.min(CFG.WeightClampHi,v))
    end
end

-- ════════════════════════════════════════════════════════════════════════
--  §15  DIRECT AIM  (zero prediction, zero lead — instant bullets)
-- ════════════════════════════════════════════════════════════════════════
local AIM_PRI = {
    "Head","UpperTorso","Torso","HumanoidRootPart",
    "LowerTorso","LeftUpperArm","RightUpperArm","LeftLowerArm","RightLowerArm",
}

local function getBestAimPoint(tChar, originPos)
    if not tChar then return nil,nil end
    local myChar=LocalPlayer.Character
    local params=RaycastParams.new()
    params.FilterType=Enum.RaycastFilterType.Blacklist
    params.FilterDescendantsInstances=myChar and {myChar} or {}

    for _,name in ipairs(AIM_PRI) do
        local part=tChar:FindFirstChild(name)
        if part and part:IsA("BasePart") then
            local pos=part.Position   -- DIRECT, no prediction
            local r=Workspace:Raycast(originPos,pos-originPos,params)
            if r==nil then return pos,name end
            if r.Instance and r.Instance:IsDescendantOf(tChar) then
                return r.Position,name
            end
        end
    end
    for _,p in ipairs(tChar:GetDescendants()) do
        if p:IsA("BasePart") then
            local pos=p.Position
            local r=Workspace:Raycast(originPos,pos-originPos,params)
            if r==nil or (r.Instance and r.Instance:IsDescendantOf(tChar)) then
                return pos,p.Name
            end
        end
    end
    local hrp=tChar:FindFirstChild("HumanoidRootPart")
    if hrp then return hrp.Position,"hrp_fallback" end
    return nil,nil
end

-- Select NEAREST enemy (world dist), no FOV gate, wall-check gate
local function selectAimTarget()
    local myChar=LocalPlayer.Character; if not myChar then return nil,nil end
    local myHRP=myChar:FindFirstChild("HumanoidRootPart"); if not myHRP then return nil,nil end
    local origin=Camera.CFrame.Position
    local myPos=myHRP.Position
    local bestPlr,bestDist,bestPt=nil,math.huge,nil

    for _,plr in ipairs(Players:GetPlayers()) do
        if not isEnemy(plr) then continue end
        local char=plr.Character; if not char then continue end
        local hrp=char:FindFirstChild("HumanoidRootPart")
        local hum=char:FindFirstChildOfClass("Humanoid")
        if not hrp or not hum or hum.Health<=0 then continue end
        local dist=(hrp.Position-myPos).Magnitude
        if dist>=bestDist then continue end
        local _,_,frac,_=atomicLoS(char,origin)
        if frac<CFG.WallCheckStrict then continue end
        local pt,_=getBestAimPoint(char,origin)
        if pt then bestDist=dist; bestPlr=plr; bestPt=pt end
    end
    return bestPlr,bestPt
end

-- ════════════════════════════════════════════════════════════════════════
--  §16  DODGE  (DodgeDetectRange = 130 studs)
-- ════════════════════════════════════════════════════════════════════════
local function evalThreat(pPos, pVel, hrpPos, feetY)
    local speed=pVel.Magnitude
    if speed < CFG.MinProjectileSpeed then return nil end
    local toP=hrpPos-pPos; local dist=toP.Magnitude
    -- ← 130-stud gate
    if dist > CFG.DodgeDetectRange then return nil end
    if dist>0.001 and toP:Dot(pVel)/(dist*speed) < CFG.DotFacingThreshold then return nil end

    local a=pVel:Dot(pVel); if a<1e-10 then return nil end
    local inv2a=0.5/a
    local pad=CFG.HitboxPadding; local pad2=pad*pad
    local bestT,bestPart=math.huge,nil

    for _,hp in ipairs(charParts) do
        local oc=pPos-hp.Position
        local b=2*oc:Dot(pVel); local c=oc:Dot(oc)-pad2
        local disc=b*b-4*a*c
        if disc>=0 then
            local sq=math.sqrt(disc)
            local t1=(-b-sq)*inv2a; local t2=(-b+sq)*inv2a
            local t=t1>=0 and t1 or t2
            if t>=0 and t<=CFG.FutureLookAhead and t<bestT then
                bestT=t; bestPart=hp
            end
        end
    end
    if not bestPart then return nil end

    local impact=pPos+pVel*bestT
    local vf=Vector3.new(pVel.X,0,pVel.Z)
    vf=vf.Magnitude>0.001 and vf.Unit or Vector3.new(1,0,0)
    local pA=Vector3.new(-vf.Z,0,vf.X); local pB=Vector3.new(vf.Z,0,-vf.X)
    local away=Vector3.new(hrpPos.X-impact.X,0,hrpPos.Z-impact.Z)
    away=away.Magnitude>0.01 and away.Unit or (-vf)
    local bp=pA:Dot(away)>=pB:Dot(away) and pA or pB

    return {
        t=bestT, impact=impact, vel=pVel, pos=pPos, speed=speed,
        pA=pA, pB=pB, bestPerp=bp, away=away, vFlat=vf,
        needJump=(impact.Y<=feetY+CFG.JumpHeightThreshold) and (bestT<0.55),
        urgency=1/(bestT+0.01),
    }
end

local function clearance(dir, hrpPos, th)
    local mt=math.min(th.t,0.5)
    local fx=hrpPos.X+dir.X*CFG.WalkSpeed*mt
    local fz=hrpPos.Z+dir.Z*CFG.WalkSpeed*mt
    local ox,oz=th.pos.X,th.pos.Z
    local dx,dz=th.vFlat.X,th.vFlat.Z
    local ex=fx-ox; local ez=fz-oz
    local pr=math.max(0,ex*dx+ez*dz)
    local cx=ox+dx*pr; local cz=oz+dz*pr
    local rx=fx-cx; local rz=fz-cz
    return math.sqrt(rx*rx+rz*rz)
end

local function scoreDodge(dir, hrpPos, threats)
    local safe=CFG.HitboxPadding*CFG.SafeMarginMult
    local minC,tot=math.huge,0
    for _,th in ipairs(threats) do
        local c=clearance(dir,hrpPos,th)
        if c<minC then minC=c end
        if c>=safe then tot=tot+c*th.urgency
        else tot=tot-(safe-c)*22*th.urgency end
    end
    if minC<CFG.HitboxPadding then return -math.huge end
    return tot
end

local function bestDodge(hrpPos, threats)
    if #threats==0 then return nil end
    local bestDir,bestScore=nil,-math.huge
    for _,d in ipairs(SWEEP) do
        local s=scoreDodge(d,hrpPos,threats)
        if s>bestScore then bestScore=s; bestDir=d end
    end
    for _,th in ipairs(threats) do
        for _,c in ipairs({th.pA,th.pB,th.away,th.bestPerp}) do
            if c and c.Magnitude>0.01 then
                local s=scoreDodge(c.Unit,hrpPos,threats)
                if s>bestScore then bestScore=s; bestDir=c.Unit end
            end
        end
    end
    if not bestDir or bestScore==-math.huge then
        bestScore=-math.huge
        for _,d in ipairs(SWEEP) do
            local minC=math.huge
            for _,th in ipairs(threats) do
                local c=clearance(d,hrpPos,th)
                if c<minC then minC=c end
            end
            if minC>bestScore then bestScore=minC; bestDir=d end
        end
    end
    return bestDir
end

-- ════════════════════════════════════════════════════════════════════════
--  §17  PROJECTILE TRACKING
-- ════════════════════════════════════════════════════════════════════════
local projSet,projData,projList={},{},{}

local function isProjName(n)
    local lo=n:lower()
    return lo:find("knife") or lo:find("projectile") or lo:find("throw")
        or lo:find("bullet") or lo:find("axe")   or lo:find("rock")
        or lo:find("spear")  or lo:find("dart")  or lo:find("star")
        or lo:find("arrow")  or lo:find("shard") or lo:find("bolt")
        or lo:find("orb")    or lo:find("shuriken")
end

local function spawnDodge(vel, kPos)
    if not CFG.DodgeEnabled then return end
    local hrp=charHRP; if not hrp or vel.Magnitude<CFG.MinProjectileSpeed then return end
    local hrpPos=hrp.Position
    -- 130-stud gate also applies to spawn-dodge
    if (hrpPos-kPos).Magnitude > CFG.DodgeDetectRange then return end

    local vf=Vector3.new(vel.X,0,vel.Z)
    if vf.Magnitude<0.001 then return end
    vf=vf.Unit
    local away=Vector3.new(hrpPos.X-kPos.X,0,hrpPos.Z-kPos.Z)
    away=away.Magnitude>0.01 and away.Unit or (-vf)
    local pA=Vector3.new(-vf.Z,0,vf.X); local pB=Vector3.new(vf.Z,0,-vf.X)
    local bp=pA:Dot(away)>=pB:Dot(away) and pA or pB
    local estT=math.max(0.05,(hrpPos-kPos).Magnitude/math.max(vel.Magnitude,1))
    local fake={
        t=estT,impact=kPos+vel*estT,vel=vel,pos=kPos,speed=vel.Magnitude,
        pA=pA,pB=pB,bestPerp=bp,away=away,vFlat=vf,urgency=1/(estT+0.01),
    }
    local dDir=bestDodge(hrpPos,{fake}) or bp
    camTurnToward(dDir,0.45)
    fireKeys(dDir)
    if kPos.Y<=getFeetY()+CFG.JumpHeightThreshold then doJump() end
end

local function regProj(obj)
    if not isProjName(obj.Name) then return end
    local part=obj:IsA("BasePart") and obj
              or (obj:IsA("Model") and (obj.PrimaryPart or obj:FindFirstChildWhichIsA("BasePart")))
    if not part or projSet[part] then return end
    local vel=part.AssemblyLinearVelocity
    local data={lastPos=part.Position,vel=vel,born=os.clock(),frames=0}
    projSet[part]=true; projData[part]=data; projList[#projList+1]=part
    spawnDodge(vel,part.Position)
    local conn
    conn=part:GetPropertyChangedSignal("AssemblyLinearVelocity"):Connect(function()
        if not projSet[part] then conn:Disconnect(); return end
        local v=part.AssemblyLinearVelocity
        if v.Magnitude>0.5 then data.vel=v; spawnDodge(v,part.Position); conn:Disconnect() end
    end)
    task.defer(function()
        if projSet[part] then
            local v=part.AssemblyLinearVelocity
            if v.Magnitude>data.vel.Magnitude*0.5 then data.vel=v end
        end
    end)
end

local function unregProj(obj)
    local part=obj:IsA("BasePart") and obj
              or (obj:IsA("Model") and (obj.PrimaryPart or obj:FindFirstChildWhichIsA("BasePart")))
    if not part or not projSet[part] then return end
    projSet[part]=nil; projData[part]=nil
    for i=#projList,1,-1 do
        if projList[i]==part then table.remove(projList,i); break end
    end
end

local function connectProjFolder(f)
    for _,o in ipairs(f:GetDescendants()) do regProj(o) end
    f.DescendantAdded:Connect(regProj)
    f.DescendantRemoving:Connect(unregProj)
end

task.spawn(function()
    for _,n in ipairs({"ProjectilesAndDebris","Projectiles","Debris","Knives","Throwables","Bullets"}) do
        local f=Workspace:FindFirstChild(n)
        if f then connectProjFolder(f); return end
    end
    connectProjFolder(Workspace)
end)

local function updateProjVel(dt)
    local i=1
    while i<=#projList do
        local part=projList[i]
        if not part or not part.Parent then
            if part then projSet[part]=nil; projData[part]=nil end
            table.remove(projList,i)
        else
            local d=projData[part]
            if d and dt>0 then
                local np=part.Position
                local dv=(np-d.lastPos)/dt
                d.frames=(d.frames or 0)+1
                if d.frames<=2 then d.vel=dv*0.30+part.AssemblyLinearVelocity*0.70
                else d.vel=dv*0.85+part.AssemblyLinearVelocity*0.15 end
                d.lastPos=np
            end
            i=i+1
        end
    end
end

-- ════════════════════════════════════════════════════════════════════════
--  §18  MELEE JUKE  (character moves, camera still aims)
-- ════════════════════════════════════════════════════════════════════════
local JukeState={active=false,orbitDir=1,targetPlayer=nil,changeTimer=0}

local function computeJukeDir(myPos,enemyPos,eLook)
    local blind=enemyPos-eLook*2.0
    local toB=Vector3.new(blind.X-myPos.X,0,blind.Z-myPos.Z)
    local toE=Vector3.new(enemyPos.X-myPos.X,0,enemyPos.Z-myPos.Z)
    if toB.Magnitude<0.5 then
        local p=Vector3.new(-eLook.Z,0,eLook.X)*JukeState.orbitDir
        return p.Magnitude>0.01 and p.Unit or eLook
    end
    toB=toB.Unit
    local perp=Vector3.new(-toE.Unit.Z,0,toE.Unit.X)*JukeState.orbitDir
    local bl=toB*0.70+perp*0.30
    return bl.Magnitude>0.01 and bl.Unit or toB
end

local function executeJuke(myPos,now)
    if not CFG.JukeEnabled then JukeState.active=false; return false end
    local cp,cd,ce=nil,CFG.MeleeRange,nil
    for plr,e in pairs(EntityRegistry) do
        if isEnemy(plr) and e.health>0 then
            local d=(e.pos-myPos).Magnitude
            if d<=cd then cd=d; cp=plr; ce=e end
        end
    end
    if not cp then JukeState.active=false; return false end
    if not JukeState.active or JukeState.targetPlayer~=cp then
        JukeState={active=true,orbitDir=math.random()>0.5 and 1 or -1,
                   targetPlayer=cp,changeTimer=now+0.6}
    end
    if now>JukeState.changeTimer then
        JukeState.orbitDir=-JukeState.orbitDir
        JukeState.changeTimer=now+math.random()*0.5+0.3
    end
    local el=ce.lastCFrame.LookVector
    el=Vector3.new(el.X,0,el.Z)
    el=el.Magnitude>0.01 and el.Unit or Vector3.new(0,0,1)
    local jDir=computeJukeDir(myPos,ce.pos,el)
    -- ONLY character moves for juke; camera stays on aim target
    fireKeys(jDir)
    return true
end

-- ════════════════════════════════════════════════════════════════════════
--  §19  ANTI-STUCK + ANTI-CAMP
-- ════════════════════════════════════════════════════════════════════════
local stuck={lastPos=Vector3.new(),lastMoveTime=os.clock(),dir=nil,start=0}
local repositionTimer = os.clock()
local repositionDir   = nil

local function updateStuck(hrpPos, moveDir, now)
    local disp=(hrpPos-stuck.lastPos).Magnitude
    if disp>CFG.StuckThreshold then
        stuck.lastPos=hrpPos; stuck.lastMoveTime=now; stuck.dir=nil; return false
    end
    if now-stuck.lastMoveTime>CFG.StuckWindow then
        if not stuck.dir then
            local ref=moveDir or Vector3.new(0,0,1)
            local p=Vector3.new(-ref.Z,0,ref.X)
            stuck.dir=math.random()>0.5 and p or -p; stuck.start=now
        end
        if now-stuck.start<0.5 then
            camTurnToward(stuck.dir,0.30)
            fireKeys(stuck.dir); doJump(); return true
        else stuck.dir=nil; stuck.lastMoveTime=now end
    end
    return false
end

-- Anti-camp: pick a lateral offset position every RepositionInterval seconds
local function getRepositionGoal(hrpPos, enemyPos, now)
    if now-repositionTimer < CFG.RepositionInterval then return nil end
    repositionTimer = now
    -- Pick a position to the side of the current position,
    -- at an angle relative to enemy so we approach from a different angle
    local toEnemy = enemyPos and (enemyPos-hrpPos) or Vector3.new(0,0,1)
    toEnemy = Vector3.new(toEnemy.X,0,toEnemy.Z)
    if toEnemy.Magnitude < 0.1 then return nil end
    toEnemy = toEnemy.Unit
    local side = Vector3.new(-toEnemy.Z,0,toEnemy.X)
    local lateralSign = math.random()>0.5 and 1 or -1
    repositionDir = (toEnemy*0.5 + side*lateralSign*1.2)
    if repositionDir.Magnitude<0.001 then return nil end
    repositionDir = repositionDir.Unit
    return hrpPos + repositionDir * CFG.RepositionRadius
end

-- ════════════════════════════════════════════════════════════════════════
--  §20  ESP
-- ════════════════════════════════════════════════════════════════════════
local espHL={}

local function removeESP(plr)
    if espHL[plr] then pcall(function() espHL[plr]:Destroy() end); espHL[plr]=nil end
end

local function createESP(plr)
    if plr==LocalPlayer then return end
    local char=plr.Character; if not char then return end
    removeESP(plr)
    local hl=Instance.new("Highlight")
    hl.Name="MC_ESP_"..plr.Name; hl.Parent=char
    hl.FillColor=isEnemy(plr) and Color3.fromRGB(255,38,38) or Color3.fromRGB(38,255,80)
    hl.OutlineColor=Color3.fromRGB(255,255,255)
    hl.FillTransparency=0.45; hl.OutlineTransparency=0
    hl.DepthMode=Enum.HighlightDepthMode.AlwaysOnTop
    hl.Enabled=CFG.ESPEnabled and isEnemy(plr)
    espHL[plr]=hl
end

local function refreshESP()
    for plr,hl in pairs(espHL) do
        if hl and hl.Parent then
            hl.Enabled=CFG.ESPEnabled and isEnemy(plr)
            hl.FillColor=isEnemy(plr) and Color3.fromRGB(255,38,38) or Color3.fromRGB(38,255,80)
        end
    end
end

local function setupESP(plr)
    if plr==LocalPlayer then return end
    plr.CharacterAdded:Connect(function() task.wait(0.35); createESP(plr) end)
    plr.CharacterRemoving:Connect(function() task.wait(0.1); removeESP(plr) end)
    plr:GetPropertyChangedSignal("Team"):Connect(function() task.wait(0.1); createESP(plr) end)
    if plr.Character then task.spawn(function() task.wait(0.25); createESP(plr) end) end
end

for _,p in ipairs(Players:GetPlayers()) do setupESP(p) end
Players.PlayerAdded:Connect(setupESP)
Players.PlayerRemoving:Connect(removeESP)
LocalPlayer:GetPropertyChangedSignal("Team"):Connect(refreshESP)

-- ════════════════════════════════════════════════════════════════════════
--  §21  DIAGNOSTIC HUD  — fully self-contained, all elements inside panel
--
--  Panel is 230 × 460 px.  All labels and toggles fit inside.
--  Playstyle buttons are in their own row.
--  Reload bar sits at the very bottom of the panel.
-- ════════════════════════════════════════════════════════════════════════
local HUD={ready=false}
-- References to playstyle buttons for colour updates
local styleButtons={}

task.spawn(function()
    local gui=LocalPlayer:WaitForChild("PlayerGui")

    local SG=Instance.new("ScreenGui")
    SG.Name="MC_HUD_v5"; SG.ResetOnSpawn=false
    SG.ZIndexBehavior=Enum.ZIndexBehavior.Sibling
    SG.DisplayOrder=99; SG.Parent=gui

    -- ── Crosshair dot at screen centre ────────────────────────────────
    local dot=Instance.new("Frame")
    dot.Size=UDim2.new(0,6,0,6); dot.AnchorPoint=Vector2.new(0.5,0.5)
    dot.Position=UDim2.new(0.5,0,0.5,0)
    dot.BackgroundColor3=Color3.fromRGB(255,60,60)
    dot.BackgroundTransparency=0; dot.BorderSizePixel=0; dot.Parent=SG
    Instance.new("UICorner",dot).CornerRadius=UDim.new(1,0)

    -- ── Reload bar (under crosshair) ───────────────────────────────────
    local rBG=Instance.new("Frame")
    rBG.Size=UDim2.new(0,180,0,6); rBG.AnchorPoint=Vector2.new(0.5,0)
    rBG.Position=UDim2.new(0.5,0,0.5,14)
    rBG.BackgroundColor3=Color3.fromRGB(28,28,28)
    rBG.BackgroundTransparency=0.15; rBG.BorderSizePixel=0
    rBG.Visible=false; rBG.Parent=SG
    Instance.new("UICorner",rBG).CornerRadius=UDim.new(0,3)
    local rFill=Instance.new("Frame")
    rFill.Size=UDim2.new(0,0,1,0); rFill.BackgroundColor3=Color3.fromRGB(255,200,40)
    rFill.BorderSizePixel=0; rFill.Parent=rBG
    Instance.new("UICorner",rFill).CornerRadius=UDim.new(0,3)
    HUD.rBG=rBG; HUD.rFill=rFill

    -- ── Main panel ─────────────────────────────────────────────────────
    --  Width 230, height 460 — all content allocated inside.
    local panel=Instance.new("Frame")
    panel.Name="MC_Panel"
    panel.Size=UDim2.new(0,230,0,460)
    panel.Position=UDim2.new(0,14,0,14)
    panel.BackgroundColor3=Color3.fromRGB(8,8,18)
    panel.BackgroundTransparency=0.06; panel.BorderSizePixel=0
    panel.Active=true; panel.Parent=SG
    Instance.new("UICorner",panel).CornerRadius=UDim.new(0,10)
    -- Clip children so nothing overflows
    Instance.new("UIListLayout",panel)  -- do NOT use layout, manual positioning

    -- ── Title / drag bar ───────────────────────────────────────────────
    local titleBar=Instance.new("Frame")
    titleBar.Size=UDim2.new(1,0,0,28); titleBar.BackgroundColor3=Color3.fromRGB(18,18,42)
    titleBar.BorderSizePixel=0; titleBar.Parent=panel
    Instance.new("UICorner",titleBar).CornerRadius=UDim.new(0,10)
    local titleLbl=Instance.new("TextLabel")
    titleLbl.Size=UDim2.new(1,-10,1,0); titleLbl.Position=UDim2.new(0,10,0,0)
    titleLbl.BackgroundTransparency=1; titleLbl.Text="Autoplayer"
    titleLbl.TextColor3=Color3.fromRGB(140,175,255); titleLbl.TextScaled=true
    titleLbl.Font=Enum.Font.GothamBold; titleLbl.TextXAlignment=Enum.TextXAlignment.Left
    titleLbl.Parent=titleBar

    -- Remove the UIListLayout since we're doing manual positioning
    -- (needed to remove it to allow AbsolutePosition-based drag)
    panel:FindFirstChildOfClass("UIListLayout"):Destroy()

    -- ── Helpers ────────────────────────────────────────────────────────
    local function makeToggle(y, label, init, cb)
        local row=Instance.new("Frame")
        row.Size=UDim2.new(1,-16,0,28); row.Position=UDim2.new(0,8,0,y)
        row.BackgroundTransparency=1; row.Parent=panel
        local lbl=Instance.new("TextLabel")
        lbl.Size=UDim2.new(0,132,1,0); lbl.BackgroundTransparency=1
        lbl.Text=label; lbl.TextColor3=Color3.fromRGB(195,195,210)
        lbl.TextScaled=true; lbl.Font=Enum.Font.Gotham
        lbl.TextXAlignment=Enum.TextXAlignment.Left; lbl.Parent=row
        local btn=Instance.new("TextButton")
        btn.Size=UDim2.new(0,52,0,20); btn.Position=UDim2.new(1,-52,0.5,-10)
        btn.Text=init and "ON" or "OFF"
        btn.BackgroundColor3=init and Color3.fromRGB(0,195,75) or Color3.fromRGB(195,45,45)
        btn.TextColor3=Color3.new(1,1,1); btn.TextScaled=true
        btn.Font=Enum.Font.GothamBold; btn.BorderSizePixel=0; btn.Parent=row
        Instance.new("UICorner",btn).CornerRadius=UDim.new(0,5)
        btn.MouseButton1Click:Connect(function()
            local ns=cb()
            btn.Text=ns and "ON" or "OFF"
            btn.BackgroundColor3=ns and Color3.fromRGB(0,195,75) or Color3.fromRGB(195,45,45)
        end)
        return btn
    end

    local function makeLabel(y, col)
        local lbl=Instance.new("TextLabel")
        lbl.Size=UDim2.new(1,-16,0,16); lbl.Position=UDim2.new(0,8,0,y)
        lbl.BackgroundTransparency=1; lbl.TextColor3=col or Color3.fromRGB(145,145,165)
        lbl.TextScaled=true; lbl.Font=Enum.Font.Gotham
        lbl.TextXAlignment=Enum.TextXAlignment.Left; lbl.Text=""; lbl.Parent=panel
        return lbl
    end

    local function makeSep(y)
        local s=Instance.new("Frame")
        s.Size=UDim2.new(0.88,0,0,1); s.Position=UDim2.new(0.06,0,0,y)
        s.BackgroundColor3=Color3.fromRGB(50,50,70); s.BorderSizePixel=0; s.Parent=panel
    end

    -- ── Toggle rows  (y starts at 32, each row 30 px) ─────────────────
    local y=32

    makeToggle(y,"Auto Navigate",  CFG.AutoNavEnabled,   function()
        CFG.AutoNavEnabled=not CFG.AutoNavEnabled
        if not CFG.AutoNavEnabled then releaseAll() end
        return CFG.AutoNavEnabled end); y=y+30

    makeToggle(y,"Auto Aim",       CFG.AutoAimEnabled,   function()
        CFG.AutoAimEnabled=not CFG.AutoAimEnabled
        return CFG.AutoAimEnabled end); y=y+30

    makeToggle(y,"Auto Shoot",     CFG.AutoShootEnabled, function()
        CFG.AutoShootEnabled=not CFG.AutoShootEnabled
        return CFG.AutoShootEnabled end); y=y+30

    makeToggle(y,"Knife Dodge",    CFG.DodgeEnabled,     function()
        CFG.DodgeEnabled=not CFG.DodgeEnabled
        return CFG.DodgeEnabled end); y=y+30

    makeToggle(y,"Melee Juke",     CFG.JukeEnabled,      function()
        CFG.JukeEnabled=not CFG.JukeEnabled
        return CFG.JukeEnabled end); y=y+30

    makeToggle(y,"ESP",            CFG.ESPEnabled,       function()
        CFG.ESPEnabled=not CFG.ESPEnabled; refreshESP()
        return CFG.ESPEnabled end); y=y+30

    makeSep(y+2); y=y+10

    -- ── Playstyle selector (3 stacked buttons) ─────────────────────────
    local psLabel=Instance.new("TextLabel")
    psLabel.Size=UDim2.new(1,-16,0,15); psLabel.Position=UDim2.new(0,8,0,y)
    psLabel.BackgroundTransparency=1; psLabel.Text="PLAYSTYLE"
    psLabel.TextColor3=Color3.fromRGB(160,160,200); psLabel.TextScaled=true
    psLabel.Font=Enum.Font.GothamBold
    psLabel.TextXAlignment=Enum.TextXAlignment.Left; psLabel.Parent=panel
    y=y+18

    local function updateStyleButtons()
        for mode,btn in pairs(styleButtons) do
            local active=(mode==currentPlaystyle)
            local s=PLAYSTYLES[mode]
            btn.BackgroundColor3 = active and s.color
                or Color3.fromRGB(40,40,55)
            btn.TextColor3 = active and Color3.fromRGB(10,10,20)
                or Color3.fromRGB(180,180,200)
        end
    end

    for _,mode in ipairs({"auto","passive","aggro"}) do
        local s=PLAYSTYLES[mode]
        local btn=Instance.new("TextButton")
        btn.Size=UDim2.new(1,-16,0,24); btn.Position=UDim2.new(0,8,0,y)
        btn.Text=s.name; btn.TextScaled=true; btn.Font=Enum.Font.GothamBold
        btn.BackgroundColor3=mode==currentPlaystyle and s.color or Color3.fromRGB(40,40,55)
        btn.TextColor3=mode==currentPlaystyle and Color3.fromRGB(10,10,20) or Color3.fromRGB(180,180,200)
        btn.BorderSizePixel=0; btn.Parent=panel
        Instance.new("UICorner",btn).CornerRadius=UDim.new(0,5)
        btn.MouseButton1Click:Connect(function()
            currentPlaystyle=mode
            hardSyncToStyle()
            updateStyleButtons()
        end)
        styleButtons[mode]=btn
        y=y+27
    end

    makeSep(y+2); y=y+10

    -- ── Status labels  (16 px each, 8 px gap) ─────────────────────────
    HUD.lblAction  = makeLabel(y, Color3.fromRGB(145,145,175)); y=y+18
    HUD.lblTarget  = makeLabel(y, Color3.fromRGB(200,200,210)); y=y+18
    HUD.lblThreats = makeLabel(y, Color3.fromRGB(255,90,90));   y=y+18
    HUD.lblHP      = makeLabel(y, Color3.fromRGB(90,220,90));   y=y+18
    HUD.lblPing    = makeLabel(y, Color3.fromRGB(180,180,100)); y=y+18
    HUD.lblReload  = makeLabel(y, Color3.fromRGB(255,200,50));  y=y+18
    HUD.lblWeights = makeLabel(y, Color3.fromRGB(90,190,90));   y=y+18
    HUD.lblStyle   = makeLabel(y, Color3.fromRGB(140,175,255))

    -- Resize panel to exactly fit content
    panel.Size=UDim2.new(0,230,0,y+20)

    -- ── Drag ──────────────────────────────────────────────────────────
    local dragging,dragStart,panelStart=false,nil,nil
    titleBar.InputBegan:Connect(function(inp)
        if inp.UserInputType==Enum.UserInputType.MouseButton1
        or inp.UserInputType==Enum.UserInputType.Touch then
            dragging=true; dragStart=inp.Position; panelStart=panel.Position
            inp.Changed:Connect(function()
                if inp.UserInputState==Enum.UserInputState.End then dragging=false end
            end)
        end
    end)
    UserInputService.InputChanged:Connect(function(inp)
        if not dragging then return end
        if inp.UserInputType==Enum.UserInputType.MouseMovement
        or inp.UserInputType==Enum.UserInputType.Touch then
            local d=inp.Position-dragStart
            panel.Position=UDim2.new(
                panelStart.X.Scale,panelStart.X.Offset+d.X,
                panelStart.Y.Scale,panelStart.Y.Offset+d.Y)
        end
    end)

    HUD.panel=panel
    HUD.updateStyleButtons=updateStyleButtons
    HUD.ready=true
end)

-- HUD refresh (every 8 frames)
local hudTick=0
local function refreshHUD(action,tName,threats,hp,maxHp)
    hudTick=hudTick+1
    if hudTick%8~=0 or not HUD.ready then return end
    local style=getStyle()

    if HUD.lblAction then
        local txt,col
        if     action=="dodge"       then txt="⚡ DODGE";   col=Color3.fromRGB(80,255,80)
        elseif action=="juke"        then txt="🔄 JUKE";    col=Color3.fromRGB(255,155,50)
        elseif action=="engage"      then txt="🎯 ENGAGE";  col=Color3.fromRGB(255,75,75)
        elseif action=="retreat"     then txt="← RETREAT";  col=Color3.fromRGB(100,185,255)
        elseif action=="navigate"    then txt="▶ NAVIGATE"; col=Color3.fromRGB(210,210,90)
        elseif action=="wait_reload" then txt="↺ RELOAD";   col=Color3.fromRGB(255,220,50)
        else                              txt="◉ IDLE";     col=Color3.fromRGB(130,130,150)
        end
        HUD.lblAction.Text=txt; HUD.lblAction.TextColor3=col
    end

    if HUD.lblTarget  then HUD.lblTarget.Text ="Target  : "..(tName or "—") end
    if HUD.lblThreats then
        HUD.lblThreats.Text="Threats : "..(threats or 0)
        HUD.lblThreats.TextColor3=(threats and threats>0)
            and Color3.fromRGB(255,75,75) or Color3.fromRGB(145,145,165)
    end
    if HUD.lblHP then
        local r=(hp or 100)/math.max(maxHp or 100,1)
        HUD.lblHP.Text=string.format("HP      : %d/%d",hp or 0,maxHp or 100)
        HUD.lblHP.TextColor3=r<0.35 and Color3.fromRGB(255,80,80) or Color3.fromRGB(80,225,90)
    end
    if HUD.lblPing   then
        HUD.lblPing.Text=string.format("Ping    : %d ms",math.floor(pingMs))
    end
    if HUD.lblReload then
        local rp=math.floor(reloadPct()*100)
        HUD.lblReload.Text=string.format("Reload  : %d%%",rp)
        HUD.lblReload.TextColor3=rp<30
            and Color3.fromRGB(255,75,75) or Color3.fromRGB(100,225,100)
    end
    if HUD.lblWeights then
        HUD.lblWeights.Text=string.format(
            "w[e%.2f d%.2f j%.2f n%.2f]",
            Brain.w.engage,Brain.w.dodge,Brain.w.juke,Brain.w.navigate)
    end
    if HUD.lblStyle then
        HUD.lblStyle.Text="Style   : "..style.name
        HUD.lblStyle.TextColor3=style.color
    end

    -- Reload bar
    if HUD.rBG and HUD.rFill then
        HUD.rBG.Visible=reloadActive
        if reloadActive then HUD.rFill.Size=UDim2.new(reloadPct(),0,1,0) end
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
local lastMoveDir    = Vector3.new(0,0,-1)

local curAction      = "idle"
local curTarget      = nil
local curAimPt       = nil

local prevLocalHP    = 100
local prevEnemyHP    = {}

local tPing=0, tEntity=0, tMCTS=0
local lastFT=os.clock()

-- ════════════════════════════════════════════════════════════════════════
--  §23  MAIN RENDER-STEPPED LOOP
-- ════════════════════════════════════════════════════════════════════════
RunService.RenderStepped:Connect(function()
    local now=os.clock()
    local dt=math.clamp(now-lastFT,0.001,0.10)
    lastFT=now

    updateProjVel(dt)

    local char=LocalPlayer.Character
    if not char then releaseAll(); return end
    local hrp=char:FindFirstChild("HumanoidRootPart")
    if not hrp then releaseAll(); return end
    if not charHRP or charHRP.Parent~=char or #charParts==0 then rebuildChar(char) end

    local hrpPos=hrp.Position
    local feetY=getFeetY()
    local myHP,myMaxHP=getLocalHP()

    -- ── Periodic tasks ─────────────────────────────────────────────────
    if now-tPing>1.0 then tPing=now; task.spawn(updatePing) end

    if now-tEntity>0.05 then
        tEntity=now
        for _,plr in ipairs(Players:GetPlayers()) do
            if plr~=LocalPlayer then regUpdate(plr,dt) end
        end
    end

    -- Softly converge brain toward playstyle each frame
    syncBrainToStyle()

    -- ── Threat detection (130-stud range applied inside evalThreat) ────
    local threats={}
    for _,part in ipairs(projList) do
        local d=projData[part]
        if d and part.Parent then
            local th=evalThreat(part.Position,d.vel,hrpPos,feetY)
            if th then threats[#threats+1]=th end
        end
    end
    if #threats>1 then table.sort(threats,function(a,b) return a.t<b.t end) end

    -- ── Visibility scan ────────────────────────────────────────────────
    local origin=Camera.CFrame.Position
    for plr,e in pairs(EntityRegistry) do
        if isEnemy(plr) and plr.Character then
            local _,_,frac,_=atomicLoS(plr.Character,origin)
            e.wasVisible=e.isVisible
            e.isVisible=frac>=CFG.WallCheckStrict
            e.visFraction=frac
        end
    end

    -- ── Aim target selection ───────────────────────────────────────────
    if CFG.AutoAimEnabled then
        local ap,apt=selectAimTarget()
        if ap and apt then curTarget=ap; curAimPt=apt
        elseif not curTarget then
            local cp,_,_=closestEnemy(hrpPos)
            if cp then curTarget=cp end
        end
    end

    if curTarget then
        local ce=EntityRegistry[curTarget]
        if not ce or ce.health<=0 or not curTarget.Character then
            curTarget=nil; curAimPt=nil
        end
    end

    -- ── Brain context ──────────────────────────────────────────────────
    local tE=curTarget and EntityRegistry[curTarget]
    local tDist=tE and (tE.pos-hrpPos).Magnitude or 999
    local inMelee=tDist<=CFG.MeleeRange
    local visFrac=tE and (tE.visFraction or 0) or 0
    local hasLoS=visFrac>=CFG.WallCheckStrict

    local ctx={
        health=myHP,maxHealth=myMaxHP,targetDist=tDist,
        hasLoS=hasLoS,visFraction=visFrac,threatCount=#threats,
        isReloading=reloadActive,inMeleeRange=inMelee,
        hasTarget=curTarget~=nil,targetHP=tE and tE.health or 0,
    }
    local action,_=brainDecide(ctx)
    curAction=action

    -- ── Rewards ────────────────────────────────────────────────────────
    local hpD=myHP-prevLocalHP
    if hpD<-2 then brainReward(-1.2) elseif hpD>0 then brainReward(0.15) end
    if curTarget and tE then
        local prev=prevEnemyHP[curTarget] or tE.health
        if tE.health-prev<-2 then
            brainReward(1.6)
            Brain.w.engage=math.min(Brain.w.engage+CFG.LearningRate*0.5,CFG.WeightClampHi)
        end
        prevEnemyHP[curTarget]=tE.health
    end
    prevLocalHP=myHP

    -- ════════════════════════════════════════════════════════════════════
    --  ACTION DISPATCH
    -- ════════════════════════════════════════════════════════════════════

    -- ─ DODGE ───────────────────────────────────────────────────────────
    if action=="dodge" and CFG.DodgeEnabled and #threats>0 then
        local dDir=bestDodge(hrpPos,threats)
        if dDir then
            dodgeActive=true; lastMoveDir=dDir
            -- Camera pans toward dodge dir (helps WASD align)
            camTurnToward(dDir, 0.40)
            fireKeys(dDir)
            for i=1,math.min(2,#threats) do
                if threats[i].needJump then doJump(); break end
            end
        end
        extraActive=false; extraTargetPos=nil
        -- Aim + shoot independently while dodging
        if CFG.AutoAimEnabled and curAimPt then
            camAimAt(curAimPt)
            if CFG.AutoShootEnabled and canShoot() and hasLoS then doShoot() end
        end

    -- ─ JUKE ────────────────────────────────────────────────────────────
    elseif action=="juke" and CFG.JukeEnabled and inMelee then
        dodgeActive=false; extraActive=false
        executeJuke(hrpPos,now)
        -- Camera aims at enemy independently; character jukes via fireKeys
        if CFG.AutoAimEnabled and curAimPt then camAimAt(curAimPt) end

    -- ─ ENGAGE ──────────────────────────────────────────────────────────
    elseif action=="engage" and curAimPt then
        dodgeActive=false

        -- Camera snaps to aim point
        if CFG.AutoAimEnabled then camAimAt(curAimPt) end

        -- Shoot
        if CFG.AutoShootEnabled and canShoot() and hasLoS then doShoot() end

        -- Navigate toward or strafe around enemy
        if CFG.AutoNavEnabled then
            if tDist > CFG.EngageMoveRange then
                -- Move toward enemy; also check anti-camp reposition
                local repGoal = tE and getRepositionGoal(hrpPos, tE.pos, now) or nil
                local navGoal = repGoal or (tE and tE.pos)
                if navGoal and now-tMCTS>CFG.MCTSInterval then
                    tMCTS=now
                    local d=mctsSearch(hrpPos,navGoal,CFG.MCTSSimulations)
                    if d then lastMoveDir=d; MCTS.dir=d end
                end
                if MCTS.dir then
                    -- Camera gently turns toward movement; aim override applied after
                    camTurnToward(MCTS.dir, CFG.CamNavBlend)
                    local yc,cls=yCorrection(hrpPos,MCTS.dir)
                    if cls=="ledge" then
                        local alt=Vector3.new(-MCTS.dir.Z,0,MCTS.dir.X)
                        camTurnToward(alt,0.35); fireKeys(alt)
                    elseif needsJump(yc,cls) then
                        fireKeys(MCTS.dir); doJump()
                    else
                        fireKeys(MCTS.dir)
                    end
                    updateStuck(hrpPos,MCTS.dir,now)
                end
            else
                -- In range: lateral strafe
                local s=getStyle()
                local strafeDir=Vector3.new(-lastMoveDir.Z,0,lastMoveDir.X)
                               *(math.sin(now*s.strafeFreq)>0 and 1 or -1)
                camTurnToward(strafeDir, CFG.CamNavBlend)
                fireKeys(strafeDir)
            end
            -- After movement keys, re-snap camera to aim (aim takes priority over nav pan)
            if CFG.AutoAimEnabled and curAimPt then camAimAt(curAimPt) end
        end

    -- ─ RETREAT ─────────────────────────────────────────────────────────
    elseif action=="retreat" then
        dodgeActive=false
        local rDir=Vector3.new()
        for plr,e in pairs(EntityRegistry) do
            if isEnemy(plr) and e.health>0 then
                local aw=hrpPos-e.pos
                aw=Vector3.new(aw.X,0,aw.Z)
                if aw.Magnitude>0.01 then rDir=rDir+aw.Unit/(aw.Magnitude+0.5) end
            end
        end
        if rDir.Magnitude>0.01 then
            rDir=rDir.Unit; lastMoveDir=rDir
            camTurnToward(rDir, CFG.CamNavBlend)
            fireKeys(rDir)
        end
        if CFG.AutoAimEnabled and curAimPt then
            camAimAt(curAimPt)
            if CFG.AutoShootEnabled and canShoot() and hasLoS then doShoot() end
        end

    -- ─ WAIT / RELOAD ───────────────────────────────────────────────────
    elseif action=="wait_reload" then
        dodgeActive=false
        local s=getStyle()
        local sd=Vector3.new(-lastMoveDir.Z,0,lastMoveDir.X)
                *(math.sin(now*s.strafeFreq)>0 and 1 or -1)
        camTurnToward(sd, CFG.CamNavBlend)
        fireKeys(sd)
        if CFG.AutoAimEnabled and curAimPt then camAimAt(curAimPt) end

    -- ─ NAVIGATE ────────────────────────────────────────────────────────
    elseif action=="navigate" and CFG.AutoNavEnabled then
        dodgeActive=false
        local goalPos=tE and enemyNavPos(curTarget) or nil

        -- Anti-camp: inject a reposition goal periodically even during nav
        if goalPos then
            local repGoal=getRepositionGoal(hrpPos,goalPos,now)
            if repGoal then goalPos=repGoal end
        end

        if goalPos then
            if now-tMCTS>CFG.MCTSInterval then
                tMCTS=now
                local d=mctsSearch(hrpPos,goalPos,CFG.MCTSSimulations)
                if d then lastMoveDir=d; MCTS.dir=d; MCTS.goal=goalPos end
            end
            local mvDir=MCTS.dir
            if mvDir then
                -- Camera turns toward navigation heading
                camTurnToward(mvDir, CFG.CamNavBlend)
                local yc,cls=yCorrection(hrpPos,mvDir)
                if cls=="ledge" then
                    local alt=Vector3.new(-mvDir.Z,0,mvDir.X)
                    camTurnToward(alt,0.35); fireKeys(alt)
                elseif needsJump(yc,cls) then
                    fireKeys(mvDir); doJump()
                else
                    fireKeys(mvDir)
                end
                updateStuck(hrpPos,mvDir,now)
            end
        else
            releaseAll()
        end

        -- If we can see target while navigating, still aim at them
        if CFG.AutoAimEnabled and curAimPt and hasLoS then
            camAimAt(curAimPt)
        end

    -- ─ IDLE ────────────────────────────────────────────────────────────
    else
        dodgeActive=false
        if not extraActive then releaseAll() end
    end

    -- ── Post-dodge burst ────────────────────────────────────────────────
    if not dodgeActive then
        if extraActive then
            local tgt=extraTargetPos or (hrpPos+extraDir*CFG.ExtraBurstDistance)
            local hv=Vector3.new(hrpPos.X,0,hrpPos.Z)
            local tv=Vector3.new(tgt.X,0,tgt.Z)
            if (hv-tv).Magnitude>0.35 and now<extraStartTime+CFG.ExtraMaxBurstTime then
                camTurnToward(extraDir,0.25); fireKeys(extraDir)
            else
                extraActive=false; extraTargetPos=nil
            end
        end
    else
        extraActive=true; extraDir=lastMoveDir
        extraTargetPos=hrpPos+lastMoveDir*CFG.ExtraBurstDistance
        extraStartTime=now
    end

    refreshHUD(curAction,curTarget and curTarget.Name or nil,#threats,myHP,myMaxHP)
end)

-- ════════════════════════════════════════════════════════════════════════
--  §24  RESPAWN
-- ════════════════════════════════════════════════════════════════════════
local function onCharAdded(char)
    task.wait(0.2); rebuildChar(char)
    dodgeActive=false; extraActive=false; extraTargetPos=nil
    curTarget=nil; curAimPt=nil; MCTS.dir=nil; JukeState.active=false
    stuck.dir=nil; repositionTimer=os.clock()
    releaseAll(); Camera.CameraType=Enum.CameraType.Custom
end

LocalPlayer.CharacterAdded:Connect(onCharAdded)
if LocalPlayer.Character then
    task.spawn(function() task.wait(0.1); rebuildChar(LocalPlayer.Character) end)
end

-- ════════════════════════════════════════════════════════════════════════
--  §25  PLAYER EVENTS
-- ════════════════════════════════════════════════════════════════════════
Players.PlayerAdded:Connect(function(plr)
    setupESP(plr)
    plr.CharacterAdded:Connect(function() task.wait(0.1); regEnsure(plr) end)
    plr.CharacterRemoving:Connect(function() EntityRegistry[plr]=nil end)
end)
Players.PlayerRemoving:Connect(function(plr)
    EntityRegistry[plr]=nil; prevEnemyHP[plr]=nil; removeESP(plr)
end)
for _,plr in ipairs(Players:GetPlayers()) do
    if plr~=LocalPlayer then
        plr.CharacterAdded:Connect(function() task.wait(0.1); regEnsure(plr) end)
        plr.CharacterRemoving:Connect(function() EntityRegistry[plr]=nil end)
        if plr.Character then regEnsure(plr) end
    end
end