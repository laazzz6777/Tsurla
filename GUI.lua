--[[
    AnkleBreaker AI v5.0 – Neural Kill Edition
    ─────────────────────────────────────────────────────────────────
    MAJOR ENHANCEMENTS OVER v4.2:
    • Deep Neural Network (5 layers, 256→256→128→64 neurons, per-player)
      – Adam optimizer with gradient clipping
      – Online experience replay buffer (512 samples)
      – Backprop runs every 3 frames, not just heatmap updates
      – Per-opponent prediction networks (32→256→128→64→8)
      – Local decision network (40→256→256→128→64→10)
    • Bomb Arrival Time Prediction (BAP)
      – Simulates 5 carrier trajectories × 30 steps each
      – Computes exact seconds until carrier can tag local player
      – Pre-emptive dodge triggered at 3s warning, panic at 1.5s
      – Accounts for ping, carrier velocity, obstacle deflection
    • Ultra-Aggressive Kill Mode
      – Pure intercept targeting: go WHERE target will be, not where they are
      – Corner-forcing: read wall geometry and funnel target into dead-ends
      – Cut-off logic: compute escape arc and block it
      – Herd rays doubled (16), corner-push weight 0.65
      – MOVE_LERP 0.65 when chasing (was 0.28)
      – Instant face direction during all chase phases
    • Neural-guided juke selection replaces win-rate table lookup
    • Neural dump score replaces Monte Carlo oracle for fast decisions
    ─────────────────────────────────────────────────────────────────
]]

local Players             = game:GetService("Players")
local RunService          = game:GetService("RunService")
local VirtualInputManager = game:GetService("VirtualInputManager")
local Workspace           = game:GetService("Workspace")

local LocalPlayer = Players.LocalPlayer
local Camera      = Workspace.CurrentCamera

-- =============================================================
-- VIM MOVEMENT
-- =============================================================
local KC = { W=Enum.KeyCode.W, A=Enum.KeyCode.A, S=Enum.KeyCode.S, D=Enum.KeyCode.D, Space=Enum.KeyCode.Space }
local ks = { W=false, A=false, S=false, D=false }

local function sk(down, key)
    pcall(VirtualInputManager.SendKeyEvent, VirtualInputManager, down, key, false, game)
end
local function releaseAll()
    for n,p in pairs(ks) do if p then sk(false,KC[n]); ks[n]=false end end
end
local function doJump()
    sk(true, KC.Space)
    task.delay(0.08, function() sk(false, KC.Space) end)
end
local function moveDir(dir)
    if not dir or dir.Magnitude < 0.01 then releaseAll(); return end
    local d  = Vector3.new(dir.X,0,dir.Z).Unit
    local cf = Camera.CFrame
    local fw = Vector3.new(cf.LookVector.X, 0, cf.LookVector.Z)
    local rt = Vector3.new(cf.RightVector.X,0, cf.RightVector.Z)
    fw = fw.Magnitude>0.001 and fw.Unit or Vector3.new(0,0,-1)
    rt = rt.Magnitude>0.001 and rt.Unit or Vector3.new(1,0, 0)
    local f,r = d:Dot(fw), d:Dot(rt)
    local T = 0.10
    if     f> T then if not ks.W then sk(true,KC.W);ks.W=true  end; if ks.S then sk(false,KC.S);ks.S=false end
    elseif f<-T then if not ks.S then sk(true,KC.S);ks.S=true  end; if ks.W then sk(false,KC.W);ks.W=false end
    else             if ks.W then sk(false,KC.W);ks.W=false end; if ks.S then sk(false,KC.S);ks.S=false end end
    if     r> T then if not ks.D then sk(true,KC.D);ks.D=true  end; if ks.A then sk(false,KC.A);ks.A=false end
    elseif r<-T then if not ks.A then sk(true,KC.A);ks.A=true  end; if ks.D then sk(false,KC.D);ks.D=false end
    else             if ks.D then sk(false,KC.D);ks.D=false end; if ks.A then sk(false,KC.A);ks.A=false end end
    local char = LocalPlayer.Character
    if char then
        local hum = char:FindFirstChildOfClass("Humanoid")
        if hum and hum.Health>0 then hum:Move(d, false) end
    end
end

-- =============================================================
-- CONFIG
-- =============================================================
local Cfg = {
    WALL_NEAR_DIST       = 3.5,
    WALL_HARD_DIST       = 2.8,
    WALL_MARGIN          = 1.7,
    WALL_ESCAPE_PUSH     = 0.70,
    WALL_REPULSE_RAYS    = 10,
    WALL_REPULSE_WEIGHT  = 0.38,
    WALL_REP_ALPHA       = 0.09,
    CORRIDOR_RAYS        = 12,
    LOOKAHEAD_STEPS      = 4,
    LOOKAHEAD_TIME       = 0.30,
    HBW_DEFAULT          = 1.6,
    MAX_SPEED            = 22,
    ROT_SMOOTH_SPEED     = 30,
    MOVE_LERP            = 0.28,          -- evade lerp (smooth)
    CHASE_MOVE_LERP      = 0.65,          -- chase lerp (AGGRESSIVE – faster)
    LOOP_RATE            = 0.035,
    TARGET_UPDATE_RATE   = 0.05,          -- faster target refresh
    HEATMAP_UPDATE_RATE  = 0.15,          -- faster heatmap for NN
    PRED_STEPS           = 12,            -- more prediction steps
    PRED_VEL_DAMP        = 0.98,
    JUKE_TRIGGER_DIST    = 30,
    JUKE_SCORE_MIN       = 0.06,          -- lower threshold = juke more
    TRANSFER_HITBOX_R    = 2.0,
    STUCK_THRESHOLD      = 0.30,
    STUCK_TIME           = 0.90,
    HEATMAP_CELL         = 6,             -- smaller cells = higher resolution
    HEATMAP_DECAY        = 0.96,

    -- NEURAL NETWORK CONFIG (deep, fast)
    NN_LEARN_RATE        = 0.003,         -- 20x faster than original 0.15
    NN_BETA1             = 0.85,          -- faster momentum decay for speed
    NN_BETA2             = 0.999,
    NN_EPSILON           = 1e-8,
    NN_GRADIENT_CLIP     = 5.0,
    NN_REPLAY_SIZE       = 512,
    NN_BATCH_SIZE        = 16,
    NN_UPDATE_EVERY      = 3,             -- backprop every 3 game frames
    NN_WARMUP            = 8,
    NN_WEIGHT_DIR        = 0.55,          -- stronger neural direction influence

    -- BOMB ARRIVAL PREDICTOR
    BAP_SIM_STEPS        = 30,
    BAP_DT               = 0.10,
    BAP_TRAJECTORIES     = 5,
    BAP_PANIC_THRESHOLD  = 1.5,           -- panic-dodge when carrier <1.5s away
    BAP_WARN_THRESHOLD   = 3.0,
    BAP_SPEED_SCALE      = 1.05,          -- slightly over-estimate carrier speed (safe)

    -- AGGRESSIVE CHASE
    AGGR_INTERCEPT_T     = 0.55,          -- look ahead 0.55s for intercept
    AGGR_PRED_BLEND      = 0.78,          -- heavy blend toward predicted pos
    AGGR_CORNER_WEIGHT   = 0.65,          -- strong wall-herd bias
    AGGR_CUTOFF_DIST     = 14.0,          -- start cut-off at this distance
    AGGR_CUTOFF_ANGLE    = 0.40,          -- dot-product threshold for cut-off
    AGGR_HERD_RAYS       = 16,            -- double rays for wall detection
    AGGR_HERD_DIST       = 12.0,
    AGGR_CORNER_BOOST    = 0.45,          -- extra speed toward cornered targets
    AGGR_INSTANT_FACE    = true,          -- instant face when chasing
    AGGR_CLOSE_THRESHOLD = 5.0,           -- pure straight-line charge below this
    AGGR_PANIC_CHARGE    = true,          -- ignore walls slightly when panicking

    RRT_NODES            = 15,
    RRT_STEP             = 3.5,
    RRT_NEAR_RADIUS      = 5.5,
    RRT_INTERVAL         = 0.55,
    RRT_MC_BLEND         = 0.45,
    PANIC_THRESHOLD      = 0.55,          -- trigger panic mode earlier
    PANIC_LEARN_RATE     = 0.20,          -- faster panic learning
    BOMB_DURATION        = 15,
    BOMB_GRACE           = 0.40,
    PANIC_TAG_TIME       = 2.2,           -- extended panic window
    PRESSURE_TAG_TIME    = 5.0,           -- extended pressure window
    BAIT_MIN_DIST        = 10,
    BAIT_MAX_DIST        = 24,
    BAIT_DISPLAY_TIME    = 0.28,
    BAIT_COOLDOWN        = 2.50,
    TRAP_CONV_ANGLE      = 120,
    TRAP_SPACE_DROP      = 2.5,
    PSYCH_WALL_RADIUS    = 6.0,
    PSYCH_DIR_THRESHOLD  = 0.30,
    MC_SIMULATIONS       = 12,
    MC_HORIZON           = 0.55,
    MC_STEPS             = 5,
    MC_MICRO_STEPS       = 6,
    MC_SPLITS            = 3,
    MC_VEL_DAMP          = 0.80,
    MC_NOISE             = 0.25,
    THREAT_RADIUS        = 32,
    THREAT_ANTICIPATE_T  = 0.50,
    FLOAT_EPS            = 1e-6,
    DRIFT_THRESHOLD      = 0.08,
    TRANSFER_COOLDOWN    = 1.0,
    OPTIMAL_DUMP_TIME    = 0.9,           -- dump earlier
    DODGE_DUMP_TIME      = 2.2,
    DUMP_APPROACH_RANGE  = 5.0,
    DUMP_SAFE_DIST       = 3.5,
    SPEED_NORMAL         = 16,
    SPEED_WITH_TOOL      = 18,

    PING_UPDATE_RATE     = 0.80,
    PING_EMA_ALPHA       = 0.25,
    PING_MIN             = 0.010,
    PING_MAX             = 0.600,
    PING_PRED_SCALE      = 1.80,
    PING_TRANSFER_SCALE  = 2.00,
    PING_DUMP_EXTRA      = 0.10,
    PING_JUKE_EXPAND     = 18,

    AIM_LOOK_WEIGHT      = 0.55,
    AIM_ARM_WEIGHT       = 0.45,
    AIM_TRIGGER          = 0.62,
    AIM_JUKE_DIST        = 18,

    JUMP_COOLDOWN        = 1.10,
    JUMP_PROBE_DIST      = 2.8,
    JUMP_STEP_LOW        = -0.55,
    JUMP_STEP_HIGH       = 0.30,
    JUMP_MIN_SPEED       = 3.0,

    PLAN_UPDATE_INTERVAL = 0.7,
    PLAN_HORIZON         = 15.0,
    PLAN_SIMULATIONS     = 2,
    PLAN_DEPTH           = 7,
    PLAN_DT              = 0.1,

    PATH_WAYPOINT_REACH  = 2.5,
    PATH_REPLAN_INTERVAL = 0.65,

    OPEN_SEEK_RADIUS     = 8.0,
    OPEN_DIR_UPDATE_RATE = 0.22,
    OPEN_THREAT_FAR      = 30.0,
    OPEN_THREAT_NEAR     = 16.0,
    OPEN_BLEND_FAR       = 0.72,
    OPEN_BLEND_NEAR      = 0.18,
    CORNER_THRESHOLD     = 4.2,
    CORNER_ESCAPE_BIAS   = 1,
    ROAM_MOVE_LERP       = 0.55,

    MC_TRANSFER_SIMS     = 8,
    MC_TRANSFER_DT       = 0.20,

    CORRIDOR_CONTINUITY  = 0.28,
    LOS_TRIGGER_DIST     = 20.0,
}

-- =============================================================
-- OPTIMIZATION PROFILES
-- =============================================================
local CfgDefault = {
    WALL_REPULSE_RAYS=10, CORRIDOR_RAYS=12, PRED_STEPS=12,
    MC_SIMULATIONS=12, MC_STEPS=5, MC_MICRO_STEPS=6, MC_SPLITS=3,
    RRT_NODES=15, RRT_INTERVAL=0.55, HEATMAP_UPDATE_RATE=0.15,
    LOOP_RATE=0.035, TARGET_UPDATE_RATE=0.05, PING_UPDATE_RATE=0.80,
    THREAT_RADIUS=32, PLAN_SIMULATIONS=2, MC_TRANSFER_SIMS=8,
}
local CfgOpt = {
    WALL_REPULSE_RAYS=5, CORRIDOR_RAYS=6, PRED_STEPS=6,
    MC_SIMULATIONS=6, MC_STEPS=2, MC_MICRO_STEPS=3, MC_SPLITS=2,
    RRT_NODES=6, RRT_INTERVAL=9999, HEATMAP_UPDATE_RATE=0.40,
    LOOP_RATE=0.050, TARGET_UPDATE_RATE=0.12, PING_UPDATE_RATE=2.00,
    THREAT_RADIUS=22, PLAN_SIMULATIONS=1, MC_TRANSFER_SIMS=3,
}
local OptimizedMode = false
local function ApplyOptProfile(opt)
    local src = opt and CfgOpt or CfgDefault
    for k,v in pairs(src) do Cfg[k]=v end
end

-- =============================================================
-- RAYCAST PARAMS CACHE
-- =============================================================
local _CachedRP      = nil
local _CachedRPDirty = true
local function RefreshRP()
    local rp = RaycastParams.new()
    rp.FilterType = Enum.RaycastFilterType.Exclude
    local t={}
    for _,p in ipairs(Players:GetPlayers()) do
        if p.Character then table.insert(t,p.Character) end
    end
    rp.FilterDescendantsInstances=t; _CachedRP=rp; _CachedRPDirty=false
end
local function MakeRP()
    if _CachedRPDirty or not _CachedRP then RefreshRP() end
    return _CachedRP
end
Players.PlayerAdded:Connect(function()    _CachedRPDirty=true end)
Players.PlayerRemoving:Connect(function() _CachedRPDirty=true end)
LocalPlayer.CharacterAdded:Connect(function() _CachedRPDirty=true end)

-- =============================================================
-- PING ADAPTATION
-- =============================================================
local PingSeconds     = 0.060
local PingRaw         = 0.060
local PingTimer       = 0
local PingInitialized = false
local PingDriftBuf    = {}
local PingDriftPrev   = {}

local function SamplePingFromAPI()
    local ok,p = pcall(function() return LocalPlayer:GetNetworkPing() end)
    if ok and type(p)=="number" and p>0 and p<1 then return p end
    return nil
end
local function UpdatePingDriftEstimate(p, curPos, curVel, dt)
    local key=p.Name; local prev=PingDriftPrev[key]
    if prev and prev.vel.Magnitude>3 and dt>0 then
        local predicted=prev.pos+prev.vel*dt
        local err=(Vector3.new(predicted.X,curPos.Y,predicted.Z)-curPos).Magnitude
        local speed=prev.vel.Magnitude
        if speed>2 then
            local ip=math.clamp(err/speed,Cfg.PING_MIN,Cfg.PING_MAX)
            table.insert(PingDriftBuf,ip)
            if #PingDriftBuf>20 then table.remove(PingDriftBuf,1) end
        end
    end
    PingDriftPrev[key]={pos=curPos,vel=Vector3.new(curVel.X,0,curVel.Z),time=os.clock()}
end
local function GetDriftPingEstimate()
    if #PingDriftBuf<4 then return nil end
    local s={}; for _,v in ipairs(PingDriftBuf) do table.insert(s,v) end
    table.sort(s); return s[math.floor(#s/2)]
end
local function UpdatePing(dt)
    PingTimer+=dt; if PingTimer<Cfg.PING_UPDATE_RATE then return end; PingTimer=0
    local sample=SamplePingFromAPI() or GetDriftPingEstimate(); if not sample then return end
    sample=math.clamp(sample,Cfg.PING_MIN,Cfg.PING_MAX); PingRaw=sample
    if not PingInitialized then PingSeconds=sample; PingInitialized=true
    else PingSeconds=PingSeconds*(1-Cfg.PING_EMA_ALPHA)+sample*Cfg.PING_EMA_ALPHA end
    PingSeconds=math.clamp(PingSeconds,Cfg.PING_MIN,Cfg.PING_MAX)
end
local function GetPing() return PingSeconds end
local function PingAdjustedPredTime(baseTime)
    return baseTime+GetPing()*2.0*Cfg.PING_PRED_SCALE
end
local function PingAdjustedHitboxR()
    return Cfg.TRANSFER_HITBOX_R+GetPing()*Cfg.SPEED_WITH_TOOL*Cfg.PING_TRANSFER_SCALE
end
local function PingAdjustedDumpTime()
    return Cfg.OPTIMAL_DUMP_TIME+GetPing()*2.0+Cfg.PING_DUMP_EXTRA
end
local function PingAdjustedDodgeTime()
    return Cfg.DODGE_DUMP_TIME+GetPing()*2.0
end
local function PingAdjustedJukeDist()
    return Cfg.JUKE_TRIGGER_DIST+GetPing()*Cfg.PING_JUKE_EXPAND
end

-- =============================================================
-- RUNTIME STATE
-- =============================================================
local AutoPlayerEnabled     = false
local AiJumpEnabled         = false
local JumpCooldown          = 0
local IHaveTool             = false
local BombCarrier           = nil
local CurrentTarget         = nil
local LastPosition          = nil
local StuckTimer            = 0
local JukeCooldown          = 0
local JukeStartDist         = 0
local AntiStuckDir          = Vector3.zero
local AntiStuckTimer        = 0
local MoveDir               = Vector3.zero
local FaceDir               = Vector3.zero
local CurrentRotAngle       = 0
local SmoothedRep           = Vector3.zero
local LastOpenSpace         = 8
local PrecisePos            = Vector3.zero
local PrecisePosInitialized = false
local RRTCooldown           = 0
local RRTCachedDir          = nil
local DumpMode              = false
local DumpTarget            = nil
local DumpLockTimer         = 0

local OpenSpaceDir          = Vector3.new(0,0,1)
local _openSpaceDirTimer    = 0
local CornerTrapScore       = 0
local _cornerScoreTimer     = 0

local StrategicGoal = { mode="none", target=nil, expires=0, dumpScore=0 }
local PathFollowing = { active=false, waypoints={}, targetPlayer=nil, lastReplan=0 }
local JukeState     = { active=false, jukeType=nil, phase=0, timer=0, phases=nil,
                        lockedMove=Vector3.zero, lockedFace=Vector3.zero }
local BaitState     = { active=false, phase="display", timer=0,
                        fakeDir=Vector3.zero, escapeDir=Vector3.zero, cooldown=0 }

local loopTimer=0; local targetTimer=0; local heatmapTimer=0; local planTimer=0

-- Bomb Arrival Predictor state
local BAPSecondsUntilTag = math.huge  -- estimated seconds until carrier tags me
local BAPNNLabel         = nil
local BAPFrameCounter    = 0

-- =============================================================
-- BOMB TIMER
-- =============================================================
local bombActive      = false
local bombTimeLeft    = Cfg.BOMB_DURATION
local bombHolder      = "?"
local bombGrace       = 0
local BombTimerLabel  = nil
local BombHolderLabel = nil
local PingLabel       = nil
local bombStartTime   = 0
local bombEndTime     = 0

local function GetAccurateTime() return os.clock() end

local function GetBombTimeFromHolder(holderChar)
    if not holderChar then return nil end
    local head=holderChar:FindFirstChild("Head"); if not head then return nil end
    local tg=head:FindFirstChild("TimerGui"); if not tg then return nil end
    local tl=tg:FindFirstChildOfClass("TextLabel"); if not tl then return nil end
    local clean=tl.Text:gsub("%<[^>]*>","")
    local num=tonumber(clean)
    if num and num>=0 and num<=Cfg.BOMB_DURATION then return num end
    return nil
end

-- =============================================================
-- FLOAT HELPERS
-- =============================================================
local EPS = Cfg.FLOAT_EPS
local function Clamp0(x) return math.abs(x)<EPS and 0 or x end
local function StableV3(v) return Vector3.new(Clamp0(v.X),Clamp0(v.Y),Clamp0(v.Z)) end
local function Flat(v) return Vector3.new(v.X,0,v.Z) end
local function SafeN(v)
    local sv=StableV3(v); local m=sv.Magnitude
    return m<0.001 and Vector3.new(0,0,1) or (sv/m)
end
local function LerpV(a,b,t) return a:Lerp(b,t) end
local function Sigmoid(x) return 1/(1+math.exp(-math.clamp(x,-15,15))) end
local function LeakyReLU(x) return x>0 and x or x*0.1 end
local function dLeakyReLU(x) return x>0 and 1 or 0.1 end

local function GetRoot(p) local c=p.Character; return c and c:FindFirstChild("HumanoidRootPart") or nil end
local function GetPos(p)  local r=GetRoot(p);  return r and r.Position or nil end
local function GetVel(p)  local r=GetRoot(p);  return r and r.Velocity or Vector3.zero end
local function Alive(p)
    local c=p.Character; if not c then return false end
    local h=c:FindFirstChildOfClass("Humanoid"); return h and h.Health>0 or false
end
local function HasTool(p)
    local c=p.Character; if not c then return false end
    for _,v in ipairs(c:GetChildren()) do if v:IsA("Tool") then return true end end
    local rightArm = c:FindFirstChild("RightHand")
                  or c:FindFirstChild("Right Arm")
                  or c:FindFirstChild("RightUpperArm")
    if rightArm then
        for _,v in ipairs(rightArm:GetChildren()) do if v:IsA("Tool") then return true end end
    end
    return false
end
local function GetMySpeed()      return IHaveTool and Cfg.SPEED_WITH_TOOL or Cfg.SPEED_NORMAL end
local function GetPlayerSpeed(p) return HasTool(p) and Cfg.SPEED_WITH_TOOL or Cfg.SPEED_NORMAL end

-- =============================================================
-- CACHED HBW
-- =============================================================
local _CachedHBHW = Cfg.HBW_DEFAULT
local function _RefreshHBHW()
    local char = LocalPlayer.Character
    if char then
        local hrp = char:FindFirstChild("HumanoidRootPart")
        if hrp then _CachedHBHW = math.max(hrp.Size.X, hrp.Size.Z)*0.5; return end
    end
    _CachedHBHW = Cfg.HBW_DEFAULT
end
LocalPlayer.CharacterAdded:Connect(function()
    _CachedHBHW = Cfg.HBW_DEFAULT; task.defer(_RefreshHBHW)
end)
local function GetHBHW() return _CachedHBHW end

-- =============================================================
-- BOMB-AIM DETECTION
-- =============================================================
local function CarrierAimingAtMe(carrier, myPos)
    if not carrier then return false, 0 end
    local char = carrier.Character; if not char then return false, 0 end
    local hrp = char:FindFirstChild("HumanoidRootPart"); if not hrp then return false, 0 end
    local toMe = SafeN(Flat(myPos - hrp.Position))
    local lookDir = SafeN(Flat(hrp.CFrame.LookVector))
    local lookAlign = lookDir:Dot(toMe)
    local rightArm = char:FindFirstChild("RightHand")
                  or char:FindFirstChild("Right Arm")
                  or char:FindFirstChild("RightUpperArm")
    local armAlign = lookAlign
    if rightArm then
        local armLook = SafeN(Flat(rightArm.CFrame.LookVector))
        armAlign = armLook:Dot(toMe)
    end
    local combined = lookAlign*Cfg.AIM_LOOK_WEIGHT + armAlign*Cfg.AIM_ARM_WEIGHT
    return combined >= Cfg.AIM_TRIGGER, combined
end

-- =============================================================
-- BOMB SAFETY OVERRIDE
-- =============================================================
local function BombSafetyOverride(myPos, dir)
    if IHaveTool or not BombCarrier or not Alive(BombCarrier) then return dir end
    local ep = GetPos(BombCarrier); if not ep then return dir end
    local toCarrier = SafeN(Flat(ep - myPos))
    local dist = (ep - myPos).Magnitude
    local hitR = PingAdjustedHitboxR()
    if dist < hitR*3.0 and SafeN(Flat(dir)):Dot(toCarrier) > 0.40 then
        return SafeN(Flat(myPos - ep))
    end
    return dir
end

-- =============================================================
-- ROTATION
-- =============================================================
local function SetAutoRotate(on)
    local char=LocalPlayer.Character; if not char then return end
    local h=char:FindFirstChildOfClass("Humanoid"); if h then h.AutoRotate=on end
end
local function ApplyRotation(facingDir, instant, dt)
    if not facingDir or facingDir.Magnitude<0.01 then return end
    local char=LocalPlayer.Character; if not char then return end
    local hrp=char:FindFirstChild("HumanoidRootPart"); if not hrp then return end
    local target=math.atan2(-facingDir.X,-facingDir.Z)
    if instant then
        CurrentRotAngle=target
    else
        local diff=target-CurrentRotAngle
        while diff> math.pi do diff-=math.pi*2 end
        while diff<-math.pi do diff+=math.pi*2 end
        local alpha=math.min(Cfg.ROT_SMOOTH_SPEED*(dt or 1/30),1)
        CurrentRotAngle=CurrentRotAngle+diff*alpha
    end
    hrp.CFrame=CFrame.new(hrp.Position)*CFrame.Angles(0,CurrentRotAngle,0)
end

-- =============================================================
-- RAYCAST / HITBOX
-- =============================================================
local function IsTraversable(result)
    if not result then return false end
    if result.Instance:IsA("TrussPart") then return true end
    if math.abs(result.Normal.Y)>0.42 then return true end
    return false
end
local function HBCast(origin, dir, dist)
    if dir.Magnitude<0.001 then return false,nil,dist end
    local rp=MakeRP(); local hw=GetHBHW()*0.95
    dir=SafeN(Flat(dir))
    local perp=Vector3.new(-dir.Z,0,dir.X)
    local origins={
        origin, origin+perp*hw, origin-perp*hw,
        origin+perp*hw*0.5, origin-perp*hw*0.5,
        origin+perp*hw*1.15, origin-perp*hw*1.15,
    }
    local closest,cd,minClear=nil,math.huge,dist
    for _,o in ipairs(origins) do
        local res=Workspace:Raycast(o,dir*dist,rp)
        if res and not IsTraversable(res) then
            local d=(res.Position-o).Magnitude
            if d<cd then cd=d; closest=res end
            minClear=math.min(minClear,d)
        end
    end
    return closest~=nil, closest, minClear
end
local function RayHit(origin,dir,dist)
    return Workspace:Raycast(origin,dir.Unit*dist,MakeRP())
end
local function ApplyMarginBuffer(origin, dir)
    local rp=MakeRP()
    local res=Workspace:Raycast(origin,SafeN(Flat(dir))*(Cfg.WALL_MARGIN+0.8),rp)
    if res and not IsTraversable(res) then
        local wn=SafeN(Flat(res.Normal))
        dir=SafeN(Flat(dir)+wn*Cfg.WALL_ESCAPE_PUSH)
    end
    return dir
end

-- =============================================================
-- WALL REPULSION
-- =============================================================
local function WallRepulsionRaw(origin)
    local rep=Vector3.zero; local rp=MakeRP(); local maxD=Cfg.WALL_NEAR_DIST
    for i=0,Cfg.WALL_REPULSE_RAYS-1 do
        local a=(i/Cfg.WALL_REPULSE_RAYS)*math.pi*2
        local dir=Vector3.new(math.cos(a),0,math.sin(a))
        local res=Workspace:Raycast(origin,dir*maxD,rp)
        if res and not IsTraversable(res) then
            local d=math.max(0.1,(res.Position-origin).Magnitude)
            rep+=SafeN(Flat(origin-res.Position))*((maxD-d)/maxD)^2
        end
    end
    return rep
end
local function UpdateSmoothedRep(origin)
    local raw=WallRepulsionRaw(origin)
    SmoothedRep=SmoothedRep+(raw-SmoothedRep)*Cfg.WALL_REP_ALPHA
end
local function WallRepulsion(_) return SmoothedRep end

-- =============================================================
-- OPEN SPACE HELPERS
-- =============================================================
local function OpenSpace4(pos, radius)
    local total=0; local rp=MakeRP()
    for i=0,3 do
        local a=(i/4)*math.pi*2
        local dir=Vector3.new(math.cos(a),0,math.sin(a))
        local res=Workspace:Raycast(pos,dir*radius,rp)
        total+=(res and not IsTraversable(res)) and (res.Position-pos).Magnitude or radius
    end
    return total/4
end
local function OpenSpace(origin,radius)
    local total=0; local rp=MakeRP()
    local rays=OptimizedMode and 4 or 8
    for i=0,rays-1 do
        local a=(i/rays)*math.pi*2; local dir=Vector3.new(math.cos(a),0,math.sin(a))
        local res=Workspace:Raycast(origin,dir*radius,rp)
        total+=(res and not IsTraversable(res)) and (res.Position-origin).Magnitude or radius
    end
    return total/rays
end
-- 8-direction wall scan (for NN input features)
local function WallClearances8(pos, maxDist)
    local out={}; local rp=MakeRP()
    for i=0,7 do
        local a=(i/8)*math.pi*2
        local d=Vector3.new(math.cos(a),0,math.sin(a))
        local res=Workspace:Raycast(pos,d*maxDist,rp)
        out[i+1]=(res and not IsTraversable(res)) and (res.Position-pos).Magnitude/maxDist or 1.0
    end
    return out
end
local function RefreshOpenSpaceDir(myPos)
    local bestDir, bestScore = OpenSpaceDir, -math.huge
    for i=0,7 do
        local a=(i/8)*math.pi*2
        local dir=Vector3.new(math.cos(a),0,math.sin(a))
        if HBCast(myPos, dir, Cfg.WALL_HARD_DIST+0.3) then continue end
        local probe=myPos+dir*4.5
        local score=OpenSpace4(probe, Cfg.OPEN_SEEK_RADIUS)
                  + dir:Dot(SafeN(Flat(OpenSpaceDir)))*1.8
        if score>bestScore then bestScore=score; bestDir=dir end
    end
    OpenSpaceDir=bestDir
end
local function UpdateCornerTrapScore(myPos)
    local os = OpenSpace4(myPos, Cfg.OPEN_SEEK_RADIUS)
    CornerTrapScore = math.clamp(1-(os-Cfg.CORNER_THRESHOLD)/Cfg.CORNER_THRESHOLD,0,1)
end

-- =============================================================
-- CORRIDOR CLEARANCE & SafeDir
-- =============================================================
local function MinCorridorClearance(origin, dir, steps, stepDist)
    local rp=MakeRP(); local d=SafeN(Flat(dir)); local perp=Vector3.new(-d.Z,0,d.X)
    local hw=GetHBHW(); local reach=hw+2.0; local minW=math.huge
    for i=1,steps do
        local probe=origin+d*(stepDist*i)
        local lHit=Workspace:Raycast(probe,-perp*reach,rp)
        local rHit=Workspace:Raycast(probe, perp*reach,rp)
        local lD=(lHit and not IsTraversable(lHit)) and (lHit.Position-probe).Magnitude or reach
        local rD=(rHit and not IsTraversable(rHit)) and (rHit.Position-probe).Magnitude or reach
        local w=lD+rD; if w<minW then minW=w end
    end
    return minW
end
local function FindOpenCorridor(origin, preferredDir)
    preferredDir=SafeN(Flat(preferredDir))
    local probeD=Cfg.WALL_NEAR_DIST*2.5; local hw=GetHBHW()
    local minPassWidth=hw*2.2+0.4
    local bestDir,bestScore=preferredDir,-math.huge; local rp=MakeRP()
    local curMoveDir=MoveDir.Magnitude>0.01 and SafeN(Flat(MoveDir)) or preferredDir
    for i=0,Cfg.CORRIDOR_RAYS-1 do
        local a=(i/Cfg.CORRIDOR_RAYS)*math.pi*2
        local dir=Vector3.new(math.cos(a),0,math.sin(a))
        local perp=Vector3.new(-dir.Z,0,dir.X); local minDist=probeD
        for _,off in ipairs({Vector3.zero,perp*hw*0.9,-perp*hw*0.9,perp*hw*0.45,-perp*hw*0.45}) do
            local hit=Workspace:Raycast(origin+off,dir*probeD,rp)
            if hit and not IsTraversable(hit) then
                local d=(hit.Position-(origin+off)).Magnitude
                if d<minDist then minDist=d end
            end
        end
        local clearance=MinCorridorClearance(origin,dir,2,probeD*0.4)
        if clearance<minPassWidth then continue end
        local score=minDist
            -(1-dir:Dot(preferredDir))*probeD*0.38
            +dir:Dot(curMoveDir)*probeD*Cfg.CORRIDOR_CONTINUITY
        if score>bestScore then bestScore=score; bestDir=dir end
    end
    return ApplyMarginBuffer(origin,bestDir)
end

local SafeDir
local function _SafeDir(origin, intendedDir, repW)
    intendedDir=SafeN(Flat(intendedDir)); repW=repW or Cfg.WALL_REPULSE_WEIGHT
    local blended=SafeN(intendedDir+WallRepulsion(origin)*repW)
    local hitB,resB=HBCast(origin,blended,Cfg.WALL_HARD_DIST)
    if not hitB then return ApplyMarginBuffer(origin,blended) end
    if resB then
        local normal=SafeN(Flat(resB.Normal))
        local slide=SafeN(blended-normal*blended:Dot(normal)+normal*Cfg.WALL_ESCAPE_PUSH)
        if not(HBCast(origin,slide,Cfg.WALL_HARD_DIST)) then return ApplyMarginBuffer(origin,slide) end
    end
    return FindOpenCorridor(origin,intendedDir)
end
SafeDir = _SafeDir

local function PathClear(origin,dir,stepTime)
    dir=SafeN(Flat(dir)); local pos=origin
    for _=1,Cfg.LOOKAHEAD_STEPS do
        if HBCast(pos,dir,16*stepTime+1) then return false end
        pos=pos+dir*16*stepTime
    end
    return true
end

-- =============================================================
-- AI JUMP
-- =============================================================
local function TryAiJump(myPos, movingDir)
    if not AiJumpEnabled then return end
    if JumpCooldown>0 then return end
    if movingDir.Magnitude<Cfg.JUMP_MIN_SPEED*0.1 then return end
    local char=LocalPlayer.Character; if not char then return end
    local hrp=char:FindFirstChild("HumanoidRootPart"); if not hrp then return end
    local hum=char:FindFirstChildOfClass("Humanoid"); if not hum then return end
    if hum.FloorMaterial==Enum.Material.Air then return end
    local speed=Flat(hrp.AssemblyLinearVelocity).Magnitude
    if speed<Cfg.JUMP_MIN_SPEED and AntiStuckTimer<=0 then return end
    local dir=SafeN(Flat(movingDir)); local rp=MakeRP(); local halfH=hrp.Size.Y*0.5
    local kneeSrc=myPos+Vector3.new(0,halfH*Cfg.JUMP_STEP_LOW, 0)
    local midSrc =myPos+Vector3.new(0,halfH*Cfg.JUMP_STEP_HIGH,0)
    local kneeHit=Workspace:Raycast(kneeSrc,dir*Cfg.JUMP_PROBE_DIST,rp)
    local midHit =Workspace:Raycast(midSrc, dir*Cfg.JUMP_PROBE_DIST,rp)
    local kneeBlocked=kneeHit and not IsTraversable(kneeHit)
    local midClear   =(not midHit) or IsTraversable(midHit)
    if (kneeBlocked and midClear) or (AntiStuckTimer>0) then
        doJump(); JumpCooldown=Cfg.JUMP_COOLDOWN
    end
end

-- =============================================================
-- PREDICTION (enhanced with NN integration)
-- =============================================================
local function PredictLinear(player, t)
    local pos=GetPos(player); if not pos then return nil end
    local adjustedT=t+GetPing()*2.0*Cfg.PING_PRED_SCALE
    local p=pos+Flat(GetVel(player))*adjustedT
    return Vector3.new(p.X,pos.Y,p.Z)
end
local function PredictCurved(player,time,steps)
    local pos=GetPos(player); if not pos then return nil end
    steps=steps or Cfg.PRED_STEPS
    local adjustedTime=time+GetPing()*2.0*Cfg.PING_PRED_SCALE
    local dt=adjustedTime/steps
    local vel=Flat(GetVel(player)); local cur=pos; local rp=MakeRP()
    for _=1,steps do
        vel=vel*Cfg.PRED_VEL_DAMP
        if vel.Magnitude>0.1 then
            local res=RayHit(cur,vel,vel.Magnitude*dt+0.5)
            if res then local n=SafeN(Flat(res.Normal)); vel=SafeN(vel-n*vel:Dot(n))*(vel.Magnitude*0.9) end
        end
        cur=cur+vel*dt
    end
    return Vector3.new(cur.X,pos.Y,cur.Z)
end

-- =============================================================
-- ╔══════════════════════════════════════════════════════════════╗
-- ║       DEEP NEURAL NETWORK ENGINE (v5.0 - FULL BACKPROP)      ║
-- ║  Architecture:  Input → 256 → 256 → 128 → 64 → Output       ║
-- ║  Optimizer:     Adam (β₁=0.85, β₂=0.999, clip=5.0)          ║
-- ║  Activation:    LeakyReLU (α=0.1) on all hidden layers       ║
-- ║  Online:        Experience replay buffer, backprop every 3f  ║
-- ╚══════════════════════════════════════════════════════════════╝
-- =============================================================

local DeepNN = {}
DeepNN.__index = DeepNN

function DeepNN.new(layerSizes, lr)
    -- layerSizes: e.g. {40, 256, 256, 128, 64, 10}
    local net = setmetatable({}, DeepNN)
    net.L      = #layerSizes
    net.sizes  = layerSizes
    net.lr     = lr or Cfg.NN_LEARN_RATE
    net.beta1  = Cfg.NN_BETA1
    net.beta2  = Cfg.NN_BETA2
    net.eps    = Cfg.NN_EPSILON
    net.clip   = Cfg.NN_GRADIENT_CLIP
    net.t      = 0                  -- Adam global timestep

    -- Weight matrices: net.W[l][i][j] = weight from neuron j (layer l) to neuron i (layer l+1)
    -- Bias vectors:    net.b[l][i]
    -- Adam moments:    mW, vW, mb, vb
    net.W  = {}; net.b  = {}
    net.mW = {}; net.vW = {}
    net.mb = {}; net.vb = {}

    for l = 1, net.L - 1 do
        local inSz  = layerSizes[l]
        local outSz = layerSizes[l+1]
        -- He initialization: scale = sqrt(2 / in_size)
        local scale = math.sqrt(2.0 / inSz)
        net.W[l]  = {}; net.b[l]  = {}
        net.mW[l] = {}; net.vW[l] = {}
        net.mb[l] = {}; net.vb[l] = {}
        for i = 1, outSz do
            net.W[l][i]  = {}
            net.mW[l][i] = {}; net.vW[l][i] = {}
            net.mb[l][i] = 0;  net.vb[l][i] = 0
            net.b[l][i]  = 0
            for j = 1, inSz do
                net.W[l][i][j]  = (math.random()*2-1) * scale
                net.mW[l][i][j] = 0
                net.vW[l][i][j] = 0
            end
        end
    end

    -- Experience replay buffer
    net.replay = {}         -- circular buffer of {input, target} pairs
    net.replayHead = 1
    net.replayCount = 0
    net.framesSinceUpdate = 0

    return net
end

-- Forward pass → returns {output table, activations table, pre-activations table}
function DeepNN:forward(input)
    local acts  = {input}           -- acts[1] = input
    local pres  = {}                -- pre-activation at each layer
    for l = 1, self.L - 1 do
        local inAct  = acts[l]
        local outSz  = self.sizes[l+1]
        local out    = table.create(outSz)
        local pre    = table.create(outSz)
        local Wl     = self.W[l]
        local bl     = self.b[l]
        local isLast = (l == self.L - 1)
        for i = 1, outSz do
            local s   = bl[i]
            local Wi  = Wl[i]
            for j = 1, #inAct do
                s += Wi[j] * inAct[j]
            end
            pre[i] = s
            out[i] = isLast and s or LeakyReLU(s)   -- linear output, leaky hidden
        end
        pres[l]    = pre
        acts[l+1]  = out
    end
    return acts[self.L], acts, pres
end

-- Backward pass + Adam update (MSE loss on output)
function DeepNN:backward(target, acts, pres)
    local L    = self.L
    local sz   = self.sizes
    -- Compute output delta (MSE gradient: dL/d_out = out - target)
    local deltas   = {}
    local outAct   = acts[L]
    local dOut     = table.create(sz[L])
    for i = 1, sz[L] do
        dOut[i] = outAct[i] - target[i]
    end
    deltas[L-1] = dOut

    -- Backprop through hidden layers
    for l = L-2, 1, -1 do
        local dNext  = deltas[l+1]
        local Wl1    = self.W[l+1]
        local preL   = pres[l]
        local sz_l   = sz[l+1]
        local sz_l1  = sz[l+2]
        local dCur   = table.create(sz_l)
        for j = 1, sz_l do
            local err = 0
            for i = 1, sz_l1 do
                err += Wl1[i][j] * dNext[i]
            end
            dCur[j] = err * dLeakyReLU(preL[j])
        end
        deltas[l] = dCur
    end

    -- Adam weight + bias updates
    self.t += 1
    local t   = self.t
    local b1  = self.beta1;  local b2  = self.beta2
    local eps = self.eps;    local lr  = self.lr
    local clip = self.clip

    for l = 1, L-1 do
        local inAct  = acts[l]
        local delta  = deltas[l]
        local Wl     = self.W[l];  local bl = self.b[l]
        local mWl    = self.mW[l]; local vWl = self.vW[l]
        local mbl    = self.mb[l]; local vbl = self.vb[l]
        local outSz  = sz[l+1]
        local inSz   = sz[l]
        -- bias correction scale factors
        local bc1 = 1 - b1^t
        local bc2 = 1 - b2^t

        for i = 1, outSz do
            -- Gradient clip on delta
            local di = math.clamp(delta[i], -clip, clip)
            -- Bias
            local gb      = di
            mbl[i]        = b1*mbl[i] + (1-b1)*gb
            vbl[i]        = b2*vbl[i] + (1-b2)*gb*gb
            bl[i]        -= lr * (mbl[i]/bc1) / (math.sqrt(vbl[i]/bc2) + eps)
            -- Weights
            local Wi      = Wl[i]
            local mWi     = mWl[i]
            local vWi     = vWl[i]
            for j = 1, inSz do
                local gw  = di * inAct[j]
                mWi[j]    = b1*mWi[j] + (1-b1)*gw
                vWi[j]    = b2*vWi[j] + (1-b2)*gw*gw
                Wi[j]    -= lr * (mWi[j]/bc1) / (math.sqrt(vWi[j]/bc2) + eps)
            end
        end
    end
end

-- Add sample to replay buffer (input and target are tables of numbers)
function DeepNN:remember(input, target)
    local idx = self.replayHead
    self.replay[idx] = {inp=input, tgt=target}
    self.replayHead  = (idx % Cfg.NN_REPLAY_SIZE) + 1
    self.replayCount = math.min(self.replayCount + 1, Cfg.NN_REPLAY_SIZE)
end

-- Sample a mini-batch and do one backprop pass
function DeepNN:learnBatch()
    if self.replayCount < Cfg.NN_WARMUP then return end
    local bsz = math.min(Cfg.NN_BATCH_SIZE, self.replayCount)
    for _ = 1, bsz do
        local idx    = math.random(1, self.replayCount)
        local sample = self.replay[idx]
        if sample then
            local _, acts, pres = self:forward(sample.inp)
            self:backward(sample.tgt, acts, pres)
        end
    end
end

-- Tick: increment frame counter, run batch every N frames
function DeepNN:tick()
    self.framesSinceUpdate += 1
    if self.framesSinceUpdate >= Cfg.NN_UPDATE_EVERY then
        self.framesSinceUpdate = 0
        self:learnBatch()
    end
end

-- =============================================================
-- NN INSTANCE REGISTRY
-- Per-player opponent networks + one local decision network
-- =============================================================
local NNRegistry    = {}       -- NNRegistry[playerName] = DeepNN (opponent net)
local DecisionNet   = nil      -- local player decision network

-- Opponent net: 32 inputs → 256→128→64 → 8 outputs
local OPP_LAYERS  = {32, 256, 128, 64, 8}
-- Decision net:  40 inputs → 256→256→128→64 → 10 outputs
local DEC_LAYERS  = {40, 256, 256, 128, 64, 10}

local function GetOppNet(name)
    if not NNRegistry[name] then
        NNRegistry[name] = DeepNN.new(OPP_LAYERS, Cfg.NN_LEARN_RATE)
    end
    return NNRegistry[name]
end

-- Initialize decision network at startup
DecisionNet = DeepNN.new(DEC_LAYERS, Cfg.NN_LEARN_RATE * 0.8)

-- Previous state snapshots for computing training targets
local NNPrevState   = {}      -- NNPrevState[name] = {pos, vel, input, output}
local DecPrevState  = nil     -- previous decision state

-- =============================================================
-- FEATURE EXTRACTION (for NN inputs)
-- =============================================================
local function NormalizePos(pos)
    -- Normalize world pos to roughly [-1,1] assuming ~500 stud maps
    return pos.X/500, pos.Z/500
end

-- Build opponent NN input vector (32 features)
local function BuildOppInput(p, myPos)
    local pos   = GetPos(p) or myPos
    local vel   = Flat(GetVel(p))
    local dist  = (pos - myPos).Magnitude
    local relX  = math.clamp((pos.X - myPos.X)/100, -1, 1)
    local relZ  = math.clamp((pos.Z - myPos.Z)/100, -1, 1)
    local velX  = math.clamp(vel.X/20, -1, 1)
    local velZ  = math.clamp(vel.Z/20, -1, 1)
    local walls = WallClearances8(pos, 10)
    local mem   = GetMem and GetMem(p) or {psych={aggression=0.5,wallAffinity=0.3,unpredictable=0.3,avgClosingSpeed=8}}
    local ps    = mem.psych or {}
    local wA    = ps.wallAffinity     or 0.3
    local ag    = ps.aggression       or 0.5
    local un    = ps.unpredictable    or 0.3
    local cs    = math.clamp((ps.avgClosingSpeed or 8)/20, 0, 1)
    local btime = math.clamp(bombTimeLeft/15, 0, 1)
    local htool = HasTool(p) and 1 or 0
    local alive = 0; for _,pl in ipairs(Players:GetPlayers()) do if Alive(pl) then alive+=1 end end
    local nalive= math.clamp(alive/8, 0, 1)
    local ping  = math.clamp(GetPing()/0.3, 0, 1)
    local myX, myZ = NormalizePos(myPos)
    return {
        relX, relZ,           -- 1-2: relative position
        velX, velZ,           -- 3-4: velocity
        walls[1], walls[2], walls[3], walls[4],
        walls[5], walls[6], walls[7], walls[8],  -- 5-12: wall clearances
        wA, ag, un, cs,       -- 13-16: psychology
        btime,                -- 17: bomb time
        htool,                -- 18: has tool
        math.clamp(dist/100,0,1),  -- 19: normalized distance
        ping,                 -- 20: ping
        nalive,               -- 21: alive count
        myX, myZ,             -- 22-23: my position
        math.clamp(Flat(GetVel(LocalPlayer)).X/20,-1,1),  -- 24
        math.clamp(Flat(GetVel(LocalPlayer)).Z/20,-1,1),  -- 25
        IHaveTool and 1 or 0, -- 26: I have tool
        math.clamp(BAPSecondsUntilTag/10,0,1),  -- 27: bomb arrival normalized
        CornerTrapScore,      -- 28: corner trap
        OpenSpace4(pos,8)/8,  -- 29: target open space
        OpenSpace4(myPos,8)/8, -- 30: my open space
        bombActive and 1 or 0, -- 31: bomb active
        math.clamp(bombTimeLeft/Cfg.BOMB_DURATION,0,1), -- 32
    }
end

-- Build decision NN input vector (40 features)
local function BuildDecisionInput(myPos, target)
    local tpos   = target and GetPos(target) or myPos
    local tvel   = target and Flat(GetVel(target)) or Vector3.zero
    local myvel  = Flat(GetVel(LocalPlayer))
    local dist   = (tpos - myPos).Magnitude
    local relX   = math.clamp((tpos.X-myPos.X)/100,-1,1)
    local relZ   = math.clamp((tpos.Z-myPos.Z)/100,-1,1)
    local myW    = WallClearances8(myPos, 10)
    local tW     = WallClearances8(tpos, 10)
    local ping   = math.clamp(GetPing()/0.3,0,1)
    local aimAt  = target and (select(1,CarrierAimingAtMe(target,myPos)) and 1 or 0) or 0
    local panic  = target and GetPanicProbability and GetPanicProbability(target) or 0
    local bap    = math.clamp(BAPSecondsUntilTag/10,0,1)
    local threats= 0
    for _,p in ipairs(Players:GetPlayers()) do
        if p~=LocalPlayer and Alive(p) and HasTool(p) then threats+=1 end
    end
    local nthreats = math.clamp(threats/4,0,1)
    local alive = 0; for _,pl in ipairs(Players:GetPlayers()) do if Alive(pl) then alive+=1 end end
    return {
        math.clamp(myvel.X/20,-1,1), math.clamp(myvel.Z/20,-1,1),  -- 1-2
        relX, relZ,                   -- 3-4
        math.clamp(tvel.X/20,-1,1), math.clamp(tvel.Z/20,-1,1),    -- 5-6
        math.clamp(bombTimeLeft/15,0,1),  -- 7
        IHaveTool and 1 or 0,             -- 8
        myW[1],myW[2],myW[3],myW[4],myW[5],myW[6],myW[7],myW[8],  -- 9-16
        tW[1],tW[2],tW[3],tW[4],tW[5],tW[6],tW[7],tW[8],          -- 17-24
        OpenSpace4(myPos,8)/8,            -- 25
        OpenSpace4(tpos,8)/8,             -- 26
        ping,                             -- 27
        aimAt,                            -- 28
        panic,                            -- 29
        bap,                              -- 30
        nthreats,                         -- 31
        math.clamp(dist/100,0,1),         -- 32
        CornerTrapScore,                  -- 33
        bombActive and 1 or 0,            -- 34
        math.clamp(alive/8,0,1),          -- 35
        math.clamp(GetPing()*10,0,1),     -- 36
        HasTool(LocalPlayer) and 1 or 0,  -- 37 (redundant but useful context)
        math.clamp((Cfg.BOMB_DURATION-bombTimeLeft)/Cfg.BOMB_DURATION,0,1), -- 38: bomb elapsed
        SmoothedRep.X/5,                  -- 39: wall repulsion X
        SmoothedRep.Z/5,                  -- 40: wall repulsion Z
    }
end

-- Forward pass the opponent network and return prediction
local function OppNetPredict(p, myPos)
    local net  = GetOppNet(p.Name)
    local inp  = BuildOppInput(p, myPos)
    local out  = net:forward(inp)
    -- out[1..2] = predicted position delta (dx,dz) over 0.5s
    -- out[3]    = panic score
    -- out[4]    = corner likelihood
    -- out[5]    = aggression toward me
    -- out[6..7] = predicted escape direction
    -- out[8]    = "will change direction" probability
    return out
end

-- Train opponent network based on observed movement (called each heatmap tick)
local function TrainOppNet(p, myPos, prevSnap)
    if not prevSnap then return end
    local net   = GetOppNet(p.Name)
    local curP  = GetPos(p); if not curP then return end
    local curV  = Flat(GetVel(p))
    -- Target: observed position delta in 0.5s
    local dt = 0.15  -- approximate dt between calls
    local dX = math.clamp((curP.X - prevSnap.pos.X)/(20*dt), -1, 1)
    local dZ = math.clamp((curP.Z - prevSnap.pos.Z)/(20*dt), -1, 1)
    -- Panic: direction change rate
    local panicScore = 0
    if prevSnap.vel.Magnitude > 0.5 and curV.Magnitude > 0.5 then
        local angle = math.acos(math.clamp(SafeN(curV):Dot(SafeN(prevSnap.vel)),-1,1))
        panicScore  = math.clamp(angle/math.pi, 0, 1)
    end
    local cornerL = math.clamp(1 - OpenSpace4(curP,8)/8, 0, 1)
    local escX    = math.clamp(-curV.X/20, -1, 1)
    local escZ    = math.clamp(-curV.Z/20, -1, 1)
    local dirChg  = panicScore > 0.35 and 1 or 0
    local tgt     = {dX, dZ, panicScore, cornerL, 0, escX, escZ, dirChg}
    net:remember(prevSnap.input, tgt)
    net:tick()
end

-- Decision network: train based on outcome (called retrospectively)
local function TrainDecisionNet(prevSnap, myPos, didImprove)
    if not prevSnap then return end
    -- didImprove: 1=good move, 0=neutral, -1=bad move
    -- We form a target by nudging the previous output toward better values
    local alpha   = 0.25
    local out     = prevSnap.output
    local tgt     = table.create(#out)
    for i=1,#out do tgt[i] = out[i] end
    -- Reinforce move direction that led to improvement
    if didImprove > 0 then
        tgt[1] = math.clamp(tgt[1]*1.05, -1, 1)
        tgt[2] = math.clamp(tgt[2]*1.05, -1, 1)
    elseif didImprove < 0 then
        tgt[1] = math.clamp(-tgt[1]*0.8, -1, 1)
        tgt[2] = math.clamp(-tgt[2]*0.8, -1, 1)
    end
    DecisionNet:remember(prevSnap.input, tgt)
    DecisionNet:tick()
end

-- =============================================================
-- PLAYER MEMORY + PSYCHOLOGY (unchanged from v4.2)
-- =============================================================
local PlayerMemory={}
local function GetMem(p)
    local k=p.Name
    if not PlayerMemory[k] then
        PlayerMemory[k]={
            reactionTime=0.28, reactionSamples={},
            psych={
                wallSamples=0, wallHugCount=0, closingSamples={},
                dirChanges=0, totalDirSamples=0, lastPos=nil, lastDir=nil,
                wallAffinity=0.3, aggression=0.5, unpredictable=0.3, avgClosingSpeed=8,
            },
            jukes={
                spin360={s=0,f=0},      ankleBreaker={s=0,f=0},
                cooldownJuke={s=0,f=0}, jacobMethod={s=0,f=0},
                wallFlick={s=0,f=0},    stallJuke={s=0,f=0},
                doubleCut={s=0,f=0},    tripleCut={s=0,f=0},
                hitboxCorner={s=0,f=0}, camOscillate={s=0,f=0},
                circleBreak={s=0,f=0},  simonSays={s=0,f=0},
                headOnPass={s=0,f=0},   hitboxStall={s=0,f=0},
                insideCut={s=0,f=0},    reverseSpin={s=0,f=0},
                paceBait={s=0,f=0},
            },
            lastJuke=nil,
        }
    end
    return PlayerMemory[k]
end
local function RecordSuccess(p,jt) if p and jt then local m=GetMem(p); if m.jukes[jt] then m.jukes[jt].s+=1 end end end
local function RecordFail(p,jt)    if p and jt then local m=GetMem(p); if m.jukes[jt] then m.jukes[jt].f+=1 end end end
local function AddRTSample(p,t)
    local m=GetMem(p); table.insert(m.reactionSamples,t)
    if #m.reactionSamples>12 then table.remove(m.reactionSamples,1) end
    local sum=0; for _,v in ipairs(m.reactionSamples) do sum+=v end
    m.reactionTime=sum/#m.reactionSamples
end
local function UpdatePsych(p,myPos)
    local pos=GetPos(p); if not pos then return end
    local mem=GetMem(p); local ps=mem.psych; local rp=MakeRP()
    local nearWall=false; local rays=OptimizedMode and 4 or 6
    for i=0,rays-1 do
        local a=(i/rays)*math.pi*2
        local res=Workspace:Raycast(pos,Vector3.new(math.cos(a),0,math.sin(a))*Cfg.PSYCH_WALL_RADIUS,rp)
        if res and not IsTraversable(res) then nearWall=true; break end
    end
    ps.wallSamples+=1; if nearWall then ps.wallHugCount+=1 end
    ps.wallAffinity=ps.wallHugCount/ps.wallSamples
    local vel=Flat(GetVel(p))
    if vel.Magnitude>1 then
        local dir=SafeN(vel); ps.totalDirSamples+=1
        if ps.lastDir and (dir-ps.lastDir).Magnitude>Cfg.PSYCH_DIR_THRESHOLD*2 then ps.dirChanges+=1 end
        ps.lastDir=dir
        ps.unpredictable=ps.totalDirSamples>0 and math.min(ps.dirChanges/ps.totalDirSamples,1.0) or 0.3
    end
    if myPos and ps.lastPos then
        local closing=((ps.lastPos-myPos).Magnitude-(pos-myPos).Magnitude)/Cfg.HEATMAP_UPDATE_RATE
        if closing>0 then
            table.insert(ps.closingSamples,closing)
            if #ps.closingSamples>12 then table.remove(ps.closingSamples,1) end
            local sum=0; for _,v in ipairs(ps.closingSamples) do sum+=v end
            ps.avgClosingSpeed=sum/#ps.closingSamples
            ps.aggression=math.min(ps.avgClosingSpeed/20,1.0)
        end
    end
    ps.lastPos=pos
end
Players.PlayerRemoving:Connect(function(p) PlayerMemory[p.Name]=nil; NNRegistry[p.Name]=nil end)

-- =============================================================
-- NEURAL HEATMAP (enhanced: feeds NN instead of standalone)
-- =============================================================
local NeuralHeatmap={}; local PrevNeuralPos={}
local function HeatCell(pos)
    return math.floor(pos.X/Cfg.HEATMAP_CELL)..","..math.floor(pos.Z/Cfg.HEATMAP_CELL)
end
local function GetNCell(name,cell)
    if not NeuralHeatmap[name] then NeuralHeatmap[name]={} end
    if not NeuralHeatmap[name][cell] then
        NeuralHeatmap[name][cell]={weight=0,velX=0,velZ=0,transitions={}}
    end
    return NeuralHeatmap[name][cell]
end
local function AddHeat(p,pos)
    if OptimizedMode then return end; GetNCell(p.Name,HeatCell(pos)).weight+=1
end
local function UpdateNeuralCell(p,pos,vel)
    if OptimizedMode then return end
    local c=GetNCell(p.Name,HeatCell(pos)); local lr=Cfg.NN_LEARN_RATE*10
    c.velX=c.velX*(1-lr)+vel.X*lr; c.velZ=c.velZ*(1-lr)+vel.Z*lr; c.weight+=1
end
local function UpdateNeuralTransition(p,prevPos,curPos)
    if OptimizedMode or not prevPos then return end
    local from=HeatCell(prevPos); local to=HeatCell(curPos); if from==to then return end
    local c=GetNCell(p.Name,from); c.transitions[to]=(c.transitions[to] or 0)+1
end
local function DecayHeat(name)
    if OptimizedMode or not NeuralHeatmap[name] then return end
    for c,data in pairs(NeuralHeatmap[name]) do
        data.weight=data.weight*Cfg.HEATMAP_DECAY
        if data.weight<0.1 then NeuralHeatmap[name][c]=nil end
    end
end
local function HeatAt(name,pos)
    if OptimizedMode or not name or name=="" or not NeuralHeatmap[name] then return 0 end
    local c=NeuralHeatmap[name][HeatCell(pos)]; return c and c.weight or 0
end

-- NeuralPredictDir: now combines heatmap + DeepNN prediction
local function NeuralPredictDir(name, pos, vel, myPos)
    local base = nil
    -- Heatmap-based direction (v4.2 logic)
    if not OptimizedMode and NeuralHeatmap[name] then
        local cellKey=HeatCell(pos); local cell=NeuralHeatmap[name][cellKey]
        if cell then
            local lv=Vector3.new(cell.velX,0,cell.velZ)
            if lv.Magnitude>=0.3 then
                local bestNext,bestCount=nil,0
                for nc,cnt in pairs(cell.transitions) do if cnt>bestCount then bestCount=cnt;bestNext=nc end end
                local transDir=nil
                if bestNext then
                    local cx=tonumber(cellKey:match("(-?%d+)")); local cz=tonumber(cellKey:match(",(-?%d+)"))
                    local nx=tonumber(bestNext:match("(-?%d+)")); local nz=tonumber(bestNext:match(",(-?%d+)"))
                    if cx and cz and nx and nz then
                        local raw=Vector3.new(nx-cx,0,nz-cz); if raw.Magnitude>0.1 then transDir=raw.Unit end
                    end
                end
                base=transDir and SafeN(lv.Unit*0.55+transDir*0.45) or lv.Unit
                if vel and vel.Magnitude>0.5 then base=SafeN(base*0.60+SafeN(vel)*0.40) end
            end
        end
    end
    -- DeepNN-based direction (new in v5.0)
    local net = NNRegistry[name]
    if net and net.replayCount >= Cfg.NN_WARMUP and myPos then
        local p = nil
        for _,pl in ipairs(Players:GetPlayers()) do if pl.Name==name then p=pl; break end end
        if p then
            local nnOut = OppNetPredict(p, myPos)
            -- nnOut[1..2] = predicted velocity direction (dx, dz)
            local nnDir = Vector3.new(nnOut[1], 0, nnOut[2])
            if nnDir.Magnitude > 0.05 then
                nnDir = SafeN(nnDir)
                if base then
                    base = SafeN(base*(1-Cfg.NN_WEIGHT_DIR) + nnDir*Cfg.NN_WEIGHT_DIR)
                else
                    base = nnDir
                end
            end
        end
    end
    return base
end

-- =============================================================
-- PANIC MODEL
-- =============================================================
local PanicModel={}
local function GetPanicMdl(p)
    local k=p.Name
    if not PanicModel[k] then
        local buckets={}; for i=0,15 do buckets[i]={samples=0,panicSum=0} end
        PanicModel[k]={bombTimeBuckets=buckets,dirChangeRate=0,speedVariance=0,lastSpeed=0,lastDir=Vector3.zero,currentPanic=0}
    end
    return PanicModel[k]
end
local function UpdatePanicModel(p,vel)
    local m=GetPanicMdl(p); local speed=Flat(vel).Magnitude
    local dir=speed>0.5 and SafeN(Flat(vel)) or m.lastDir
    if m.lastDir.Magnitude>0.01 then
        local angle=math.acos(math.clamp(dir:Dot(m.lastDir),-1,1))
        m.dirChangeRate=angle>0.4 and m.dirChangeRate*0.88+0.12 or m.dirChangeRate*0.96
    end
    m.speedVariance=m.speedVariance*0.85+math.abs(speed-m.lastSpeed)*0.15
    local rawPanic=math.clamp(m.dirChangeRate*2.8+m.speedVariance/8,0,1)
    m.currentPanic=m.currentPanic*(1-Cfg.PANIC_LEARN_RATE)+rawPanic*Cfg.PANIC_LEARN_RATE
    if bombActive and bombTimeLeft>0 then
        local slot=math.floor(math.clamp(bombTimeLeft,0,14))
        m.bombTimeBuckets[slot].samples+=1; m.bombTimeBuckets[slot].panicSum+=rawPanic
    end
    m.lastSpeed=speed; m.lastDir=dir
end
local function GetPanicProbability(p)
    local m=GetPanicMdl(p); local base=m.currentPanic
    if bombActive and bombTimeLeft>0 then
        local slot=math.floor(math.clamp(bombTimeLeft,0,14)); local b=m.bombTimeBuckets[slot]
        if b.samples>=3 then base=base*0.30+(b.panicSum/b.samples)*0.70 end
    end
    return math.clamp(base,0,1)
end

-- =============================================================
-- ╔══════════════════════════════════════════════════════════════╗
-- ║         BOMB ARRIVAL TIME PREDICTOR (BAP v5.0)              ║
-- ║  Simulates BAP_TRAJECTORIES carrier paths (accounting for   ║
-- ║  walls, velocity, NN-predicted direction changes) and        ║
-- ║  computes the minimum time until any path can tag the        ║
-- ║  local player, used to pre-emptively evade.                  ║
-- ╚══════════════════════════════════════════════════════════════╝
-- =============================================================

local BAPHistory = {}     -- rolling buffer of BAP estimates for smoothing
local BAPSmoothed = math.huge

local function SimulateCarrierPath(startPos, startVel, myPos, steps, dt, jitterX, jitterZ)
    -- Simulate one carrier trajectory with slight direction jitter
    local cPos   = startPos
    local cVel   = Vector3.new(startVel.X + jitterX, 0, startVel.Z + jitterZ)
    local speed  = Cfg.SPEED_WITH_TOOL * Cfg.BAP_SPEED_SCALE
    local hitR   = PingAdjustedHitboxR()
    local rp     = MakeRP()

    for step = 1, steps do
        local t    = step * dt
        -- Direction: toward local player + velocity momentum
        local toMe = Flat(myPos - cPos)
        if toMe.Magnitude > 0.01 then toMe = toMe.Unit end
        local velDir = cVel.Magnitude > 0.5 and SafeN(cVel) or toMe
        -- Blend toward player with momentum
        local dir = SafeN(toMe*0.55 + velDir*0.45)
        -- Wall deflection
        local res = Workspace:Raycast(cPos, dir*speed*dt*2, rp)
        if res and not IsTraversable(res) then
            local n = SafeN(Flat(res.Normal))
            dir     = SafeN(dir - n*dir:Dot(n))
        end
        cVel = dir * speed
        cPos = cPos + cVel * dt
        -- Check if carrier can tag player at this position
        local d = (cPos - myPos).Magnitude
        if d <= hitR + 0.5 then
            return t   -- return time when tag is possible
        end
    end
    return math.huge   -- carrier doesn't reach player in this simulation
end

local function UpdateBombArrivalPredictor(myPos)
    if not BombCarrier or not Alive(BombCarrier) or IHaveTool then
        BAPSecondsUntilTag = math.huge
        BAPSmoothed        = math.huge
        return
    end
    local cPos = GetPos(BombCarrier)
    if not cPos then BAPSecondsUntilTag = math.huge; return end
    local cVel = Flat(GetVel(BombCarrier))
    local dist = (cPos - myPos).Magnitude

    -- Early exit: far away, no urgency
    if dist > 80 then BAPSecondsUntilTag = math.huge; return end

    local steps   = Cfg.BAP_SIM_STEPS
    local dt      = Cfg.BAP_DT
    local minTime = math.huge
    local N       = OptimizedMode and 2 or Cfg.BAP_TRAJECTORIES

    -- Simulate N trajectories with random jitter on velocity
    for _ = 1, N do
        local jx = (math.random()-0.5)*4
        local jz = (math.random()-0.5)*4
        local t  = SimulateCarrierPath(cPos, cVel, myPos, steps, dt, jx, jz)
        if t < minTime then minTime = t end
    end

    -- Also simulate the "direct charge" case (worst case for us)
    local directT = SimulateCarrierPath(cPos, cVel, myPos, steps, dt, 0, 0)
    if directT < minTime then minTime = directT end

    -- EMA smoothing
    table.insert(BAPHistory, minTime)
    if #BAPHistory > 8 then table.remove(BAPHistory, 1) end
    local sum = 0; local cnt = 0
    for _, v in ipairs(BAPHistory) do
        if v < math.huge then sum += v; cnt += 1 end
    end
    BAPSecondsUntilTag = (cnt > 0) and (sum / cnt) or math.huge
    BAPSmoothed        = BAPSecondsUntilTag
end

-- =============================================================
-- MULTI-THREAT
-- =============================================================
local function GetThreatData(myPos)
    local threats={}
    for _,p in ipairs(Players:GetPlayers()) do
        if p~=LocalPlayer and Alive(p) then
            local pos=GetPos(p); if not pos then continue end
            local vel=Flat(GetVel(p))
            local dist=(pos-myPos).Magnitude
            local pingComp=GetPing()*2.0
            local futurePos=pos+vel*(Cfg.THREAT_ANTICIPATE_T+pingComp)
            local effectiveDist=math.min(dist,(futurePos-myPos).Magnitude)
            if effectiveDist>Cfg.THREAT_RADIUS then continue end
            local isBomber=HasTool(p)
            local bw=(1-(effectiveDist/Cfg.THREAT_RADIUS))^2*(isBomber and 2.5 or 1)
            local ps=GetMem(p).psych
            bw=bw*(1+ps.aggression*0.5)*(ps.wallAffinity>0.6 and 0.85 or 1.0)
            table.insert(threats,{pos=pos,vel=vel,weight=bw,isBomber=isBomber,playerName=p.Name,psych=ps})
        end
    end
    return threats
end

-- =============================================================
-- TRAP DETECTION
-- =============================================================
local function DetectTrap(myPos,threats,bestEscapeDir)
    for i=1,#threats do for j=i+1,#threats do
        local t1,t2=threats[i],threats[j]
        local d1=SafeN(Flat(t1.pos-myPos)); local d2=SafeN(Flat(t2.pos-myPos))
        local ang=math.deg(math.acos(math.clamp(d1:Dot(d2),-1,1)))
        if ang>Cfg.TRAP_CONV_ANGLE then
            if Flat(t1.vel):Dot(-d1)>1 and Flat(t2.vel):Dot(-d2)>1 then return "pincer" end
        end
    end end
    local curOpen=OpenSpace(myPos,10)
    if LastOpenSpace-curOpen>Cfg.TRAP_SPACE_DROP then LastOpenSpace=curOpen; return "herd" end
    LastOpenSpace=curOpen*0.85+LastOpenSpace*0.15
    if bestEscapeDir and bestEscapeDir.Magnitude>0.01 then
        for _,t in ipairs(threats) do
            if Flat(t.vel).Magnitude>3 then
                local td=SafeN(Flat(t.vel))
                local cross=math.abs(td:Dot(Vector3.new(-bestEscapeDir.Z,0,bestEscapeDir.X)))
                local align=td:Dot(SafeN(Flat(t.pos-myPos)))
                if cross<0.35 and align>0.5 and (t.pos-myPos).Magnitude<18 then return "cutoff" end
            end
        end
    end
    return "none"
end

-- =============================================================
-- MONTE CARLO ESCAPE
-- =============================================================
local function MonteCarloEscape(myPos,threats,preferredAway)
    if #threats==0 then return preferredAway end
    local nearestThreatDist=math.huge
    for _,t in ipairs(threats) do
        local d=(t.pos-myPos).Magnitude
        if d<nearestThreatDist then nearestThreatDist=d end
    end
    if nearestThreatDist>50 then return preferredAway end
    local rp=MakeRP(); local speed=GetMySpeed()
    local halfH=Cfg.MC_HORIZON*0.5
    local dt1=halfH/Cfg.MC_STEPS; local dt2=halfH/Cfg.MC_STEPS
    local microDt1=dt1/Cfg.MC_MICRO_STEPS; local microDt2=dt2/Cfg.MC_MICRO_STEPS
    local pingComp=GetPing()*2.0*Cfg.PING_PRED_SCALE
    local function scorePoint(pos,simTime)
        local tScore=0; local closed=0
        for _,t in ipairs(threats) do
            local es=t.isBomber and Cfg.SPEED_WITH_TOOL or Cfg.SPEED_NORMAL
            local tF=t.pos+t.vel*((simTime+pingComp)*Cfg.MC_VEL_DAMP*(es/Cfg.SPEED_NORMAL))
            local d=(pos-tF).Magnitude; tScore+=d*t.weight
            if d<(myPos-t.pos).Magnitude-0.5 then closed+=1 end
        end
        local wClear=0
        for i=0,3 do
            local a=(i/4)*math.pi*2; local wd=Vector3.new(math.cos(a),0,math.sin(a))
            local wr=Workspace:Raycast(pos,wd*Cfg.WALL_NEAR_DIST,rp)
            wClear+=(wr and not IsTraversable(wr)) and (wr.Position-pos).Magnitude or Cfg.WALL_NEAR_DIST
        end
        wClear=wClear/4
        local osBonus=OpenSpace4(pos,Cfg.OPEN_SEEK_RADIUS)*0.55
        local heatP=0
        for _,t in ipairs(threats) do if t.isBomber then heatP+=HeatAt(t.playerName,pos)*0.04 end end
        return tScore*0.8+wClear*0.7+osBonus-closed*2.5-heatP
    end
    local function simPath(startPos,startDir,steps,microDt)
        local pos=startPos; local dir=startDir; local valid=true
        for _=1,steps do
            for _=1,Cfg.MC_MICRO_STEPS do
                local res=Workspace:Raycast(pos,dir*speed*microDt+dir*0.05,rp)
                if res and not IsTraversable(res) then local n=SafeN(Flat(res.Normal)); dir=SafeN(dir-n*dir:Dot(n)) end
                pos=pos+dir*speed*microDt
            end
            if HBCast(pos,dir,Cfg.WALL_HARD_DIST) then valid=false; break end
        end
        return pos,dir,valid
    end
    local s1Cands={}
    for i=0,Cfg.MC_SIMULATIONS-1 do
        local a=(i/Cfg.MC_SIMULATIONS)*math.pi*2+math.random()*Cfg.MC_NOISE
        table.insert(s1Cands,Vector3.new(math.cos(a),0,math.sin(a)))
    end
    table.insert(s1Cands,preferredAway)
    local s1Results={}
    for _,candRaw in ipairs(s1Cands) do
        local cand=SafeN(Flat(candRaw))
        if HBCast(myPos,cand,Cfg.WALL_HARD_DIST+0.5) then continue end
        local eP,eD,valid=simPath(myPos,cand,Cfg.MC_STEPS,microDt1)
        if not valid then continue end
        table.insert(s1Results,{dir=cand,endPos=eP,endDir=eD,score=scorePoint(eP,halfH)})
    end
    if #s1Results==0 then return preferredAway end
    table.sort(s1Results,function(a,b) return a.score>b.score end)
    local topS1={}
    for i=1,math.min(Cfg.MC_SPLITS,#s1Results) do table.insert(topS1,s1Results[i]) end
    local bestDir=topS1[1].dir; local bestScore=-math.huge
    for _,s1 in ipairs(topS1) do
        for j=0,Cfg.MC_SPLITS-1 do
            local a=(j/Cfg.MC_SPLITS)*math.pi*2+math.random()*Cfg.MC_NOISE
            local cand2=Vector3.new(math.cos(a),0,math.sin(a))
            if HBCast(s1.endPos,cand2,Cfg.WALL_HARD_DIST+0.5) then continue end
            local eP2,_,valid2=simPath(s1.endPos,cand2,Cfg.MC_STEPS,microDt2)
            if not valid2 then continue end
            local total=s1.score*0.45+scorePoint(eP2,Cfg.MC_HORIZON)*0.55
            if total>bestScore then bestScore=total; bestDir=s1.dir end
        end
    end
    return bestDir
end

-- =============================================================
-- WIDE PATH CHECK
-- =============================================================
local function pathFreeWide(from, to, rp)
    local hw=GetHBHW(); local dir=to-from; local dist=dir.Magnitude
    if dist<0.05 then return true end
    local d=dir.Unit; local perp=Vector3.new(-d.Z,0,d.X)
    for _,off in ipairs({Vector3.zero,perp*hw,-perp*hw}) do
        local res=Workspace:Raycast(from+off,d*dist,rp)
        if res and not IsTraversable(res) then return false end
    end
    local mid=from+d*(dist*0.5); local reach=hw+1.5
    local lHit=Workspace:Raycast(mid,-perp*reach,rp)
    local rHit=Workspace:Raycast(mid, perp*reach,rp)
    local lD=(lHit and not IsTraversable(lHit)) and (lHit.Position-mid).Magnitude or reach
    local rD=(rHit and not IsTraversable(rHit)) and (rHit.Position-mid).Magnitude or reach
    return (lD+rD)>=hw*1.9
end

-- =============================================================
-- RRT* PATHFINDING
-- =============================================================
local function RRTStarPath(start, goal, maxNodes, stepSize)
    local rp=MakeRP()
    local nodes={{pos=start,parent=nil,cost=0}}
    local goalPos=goal; local bestNode=nil; local bestDist=math.huge
    for _=1,maxNodes do
        local sample
        if math.random()<0.2 then sample=goalPos
        else
            local angle=math.random()*math.pi*2; local radius=math.random()*stepSize*8
            sample=start+Vector3.new(math.cos(angle)*radius,0,math.sin(angle)*radius)
        end
        local nearest,nearDist=1,math.huge
        for i,n in ipairs(nodes) do local d=(n.pos-sample).Magnitude; if d<nearDist then nearDist=d;nearest=i end end
        local dir=SafeN(Flat(sample-nodes[nearest].pos))
        local newPos=nodes[nearest].pos+dir*stepSize
        if pathFreeWide(nodes[nearest].pos,newPos,rp) then
            local nearIndices={}
            for i,n in ipairs(nodes) do if (n.pos-newPos).Magnitude<=Cfg.RRT_NEAR_RADIUS then table.insert(nearIndices,i) end end
            local bestParent=nearest; local bestCost=nodes[nearest].cost+(nodes[nearest].pos-newPos).Magnitude
            for _,idx in ipairs(nearIndices) do
                local candidate=nodes[idx]; local cost=candidate.cost+(candidate.pos-newPos).Magnitude
                if cost<bestCost and pathFreeWide(candidate.pos,newPos,rp) then bestCost=cost;bestParent=idx end
            end
            table.insert(nodes,{pos=newPos,parent=bestParent,cost=bestCost})
            local newNodeIdx=#nodes
            for _,idx in ipairs(nearIndices) do
                if idx~=bestParent then
                    local candidate=nodes[idx]; local newCost=bestCost+(newPos-candidate.pos).Magnitude
                    if newCost<candidate.cost and pathFreeWide(newPos,candidate.pos,rp) then
                        nodes[idx].parent=newNodeIdx; nodes[idx].cost=newCost
                    end
                end
            end
            local distToGoal=(newPos-goalPos).Magnitude
            if distToGoal<stepSize and pathFreeWide(newPos,goalPos,rp) then
                table.insert(nodes,{pos=goalPos,parent=newNodeIdx,cost=bestCost+distToGoal})
                bestNode=#nodes; break
            elseif distToGoal<bestDist then bestDist=distToGoal;bestNode=newNodeIdx end
        end
    end
    if not bestNode then return nil end
    local path={}; local current=bestNode
    while current do table.insert(path,1,nodes[current].pos); current=nodes[current].parent end
    return path
end

local function RRTStarEscape(myPos,threats,maxNodes,stepSize)
    if #threats==0 then return nil end
    local rp=MakeRP()
    local nodes={{pos=myPos,parent=nil,cost=0}}
    local bestNode=nil; local bestScore=-math.huge
    for _=1,maxNodes do
        local angle=math.random()*math.pi*2; local radius=stepSize*(2+math.random()*6)
        local sample=myPos+Vector3.new(math.cos(angle)*radius,0,math.sin(angle)*radius)
        local nearest,nearDist=1,math.huge
        for i,n in ipairs(nodes) do local d=(n.pos-sample).Magnitude; if d<nearDist then nearDist=d;nearest=i end end
        local dir=SafeN(Flat(sample-nodes[nearest].pos))
        local newPos=nodes[nearest].pos+dir*stepSize
        if pathFreeWide(nodes[nearest].pos,newPos,rp) then
            local bestParent=nearest; local bestCost=nodes[nearest].cost+(nodes[nearest].pos-newPos).Magnitude
            for i,n in ipairs(nodes) do
                if (n.pos-newPos).Magnitude<=Cfg.RRT_NEAR_RADIUS then
                    local cost=n.cost+(n.pos-newPos).Magnitude
                    if cost<bestCost and pathFreeWide(n.pos,newPos,rp) then bestCost=cost;bestParent=i end
                end
            end
            table.insert(nodes,{pos=newPos,parent=bestParent,cost=bestCost})
            local nodeIdx=#nodes; local score=0
            for _,t in ipairs(threats) do local d=(newPos-t.pos).Magnitude; score+=d*t.weight end
            score+=OpenSpace4(newPos,6)*0.4
            if score>bestScore and not HBCast(newPos,dir,Cfg.WALL_HARD_DIST) then bestScore=score;bestNode=nodeIdx end
        end
    end
    if not bestNode then return nil end
    local current=bestNode
    while nodes[current].parent and nodes[nodes[current].parent].parent do current=nodes[current].parent end
    if current<=1 then return nil end
    return SafeN(Flat(nodes[current].pos-myPos))
end

-- =============================================================
-- PATH FOLLOWING
-- =============================================================
local function UpdatePathFollowing(myPos, dt)
    if not PathFollowing.active or #PathFollowing.waypoints==0 then return false end
    local targetWP=PathFollowing.waypoints[1]; local dirToWP=targetWP-myPos; local dist=dirToWP.Magnitude
    if dist<Cfg.PATH_WAYPOINT_REACH then
        table.remove(PathFollowing.waypoints,1)
        if #PathFollowing.waypoints==0 then PathFollowing.active=false; return false
        else targetWP=PathFollowing.waypoints[1]; dirToWP=targetWP-myPos end
    end
    local move=SafeN(Flat(dirToWP))
    move=SafeDir(myPos,move,Cfg.WALL_REPULSE_WEIGHT*0.35)
    MoveDir=LerpV(MoveDir,move,Cfg.CHASE_MOVE_LERP)   -- aggressive lerp
    FaceDir=LerpV(FaceDir,move,Cfg.CHASE_MOVE_LERP)
    return true
end
local function RequestPathTo(targetPlayer)
    if not targetPlayer or not Alive(targetPlayer) then PathFollowing.active=false; return end
    local myPos=GetPos(LocalPlayer); local targetPos=GetPos(targetPlayer)
    if not myPos or not targetPos then return end
    local path=RRTStarPath(myPos,targetPos,Cfg.RRT_NODES,Cfg.RRT_STEP)
    if path and #path>1 then
        PathFollowing.waypoints=path; PathFollowing.active=true
        PathFollowing.targetPlayer=targetPlayer; PathFollowing.lastReplan=os.clock()
    else PathFollowing.active=false end
end

-- =============================================================
-- TARGETING
-- =============================================================
-- Aggressive targeting: prefer targets near walls (easier to kill)
local function ClosestNoTool()
    local mp=GetPos(LocalPlayer); if not mp then return nil end
    local best,bestScore=nil,-math.huge
    for _,p in ipairs(Players:GetPlayers()) do
        if p~=LocalPlayer and Alive(p) and not HasTool(p) then
            local pos=GetPos(p); if not pos then continue end
            local d=(pos-mp).Magnitude
            -- Score: prefer close players with low open space (cornered)
            local openSp=OpenSpace4(pos,8)
            local cornerBonus=math.clamp((Cfg.CORNER_THRESHOLD-openSp)/Cfg.CORNER_THRESHOLD,0,1)*15
            local distScore=100-math.clamp(d,0,100)
            local score=distScore+cornerBonus*Cfg.AGGR_CORNER_WEIGHT
            if score>bestScore then bestScore=score; best=p end
        end
    end
    return best
end
local function FindCarrier()
    for _,p in ipairs(Players:GetPlayers()) do
        if p~=LocalPlayer and Alive(p) and HasTool(p) then return p end
    end
    return nil
end
local function UpdateTarget()
    IHaveTool=HasTool(LocalPlayer); BombCarrier=IHaveTool and nil or FindCarrier()
    CurrentTarget=IHaveTool and ClosestNoTool() or BombCarrier
end

-- =============================================================
-- MC TRANSFER ORACLE
-- =============================================================
local function MCEvalDumpTarget(myPos, candidate)
    local candPos=GetPos(candidate); if not candPos then return 0 end
    local mySpeed=GetMySpeed()
    local timeToTag=math.max(0.05,(candPos-myPos).Magnitude/mySpeed)
    if timeToTag>=bombTimeLeft-0.1 then return 0 end
    local N=Cfg.MC_TRANSFER_SIMS; local safeCount=0
    local aliveCount=0; for _,p in ipairs(Players:GetPlayers()) do if Alive(p) then aliveCount+=1 end end
    for _=1,N do
        local states={}
        for _,p in ipairs(Players:GetPlayers()) do
            if not Alive(p) then continue end
            local pos=GetPos(p) or myPos; local vel=Flat(GetVel(p))
            local futurePos=pos+vel*timeToTag
            states[p.Name]={
                pos=futurePos, vel=vel, hasTool=(p.Name==candidate.Name),
                speed=GetPlayerSpeed(p), panic=GetPanicProbability(p),
                openSp=OpenSpace4(pos,8), aggr=GetMem(p).psych.aggression,
                wallAff=GetMem(p).psych.wallAffinity, isMe=(p==LocalPlayer),
            }
        end
        local myFuturePos=myPos+SafeN(Flat(candPos-myPos))*(timeToTag*mySpeed*0.75)
        if states[LocalPlayer.Name] then
            states[LocalPlayer.Name].pos=myFuturePos; states[LocalPlayer.Name].hasTool=false
        end
        local simTime=timeToTag; local dt=Cfg.MC_TRANSFER_DT; local hitR=PingAdjustedHitboxR()
        while simTime<Cfg.BOMB_DURATION do
            simTime+=dt
            local holderName=nil; local holderState=nil
            for name,s in pairs(states) do if s.hasTool then holderName=name;holderState=s;break end end
            if not holderName then break end
            local bestTarget,bestDist=nil,math.huge
            for name,s in pairs(states) do
                if s.hasTool then continue end
                local d=(s.pos-holderState.pos).Magnitude
                local penalty=s.isMe and 1.8 or 1.0
                if d*penalty<bestDist then bestDist=d*penalty;bestTarget=name end
            end
            for name,s in pairs(states) do
                if s.hasTool then
                    if bestTarget and states[bestTarget] then
                        local dir=SafeN(Flat(states[bestTarget].pos-s.pos)); s.pos=s.pos+dir*s.speed*dt
                    end
                else
                    local awayDir=SafeN(Flat(s.pos-holderState.pos))
                    local openBias=s.openSp<Cfg.CORNER_THRESHOLD and 0.35 or 0.10
                    local noise=Vector3.new((math.random()-0.5)*0.3,0,(math.random()-0.5)*0.3)
                    local evadeDir=SafeN(awayDir*(1-openBias)+noise)
                    s.pos=s.pos+evadeDir*s.speed*dt
                end
            end
            for name,s in pairs(states) do
                if s.hasTool then continue end
                if (s.pos-holderState.pos).Magnitude<hitR then
                    holderState.hasTool=false; s.hasTool=true; break
                end
            end
        end
        local myState=states[LocalPlayer.Name]
        if myState and not myState.hasTool then safeCount+=1 end
    end
    return safeCount/N
end

local function FindOptimalDumpTarget(myPos)
    if not bombActive then return ClosestNoTool() end
    local candidates={}
    for _,p in ipairs(Players:GetPlayers()) do
        if p~=LocalPlayer and Alive(p) and not HasTool(p) then
            local pos=GetPos(p); if pos then table.insert(candidates,p) end
        end
    end
    if #candidates==0 then return nil end
    if #candidates==1 then return candidates[1] end
    local reachable={}
    for _,p in ipairs(candidates) do
        local pos=GetPos(p); if pos then
            local dist=(pos-myPos).Magnitude
            if dist/GetMySpeed()<bombTimeLeft-0.2 then table.insert(reachable,p) end
        end
    end
    if #reachable==0 then return candidates[1] end
    if #reachable==1 then return reachable[1] end
    local bestTarget=reachable[1]; local bestScore=-math.huge
    for _,candidate in ipairs(reachable) do
        local score=MCEvalDumpTarget(myPos,candidate)
        local candPos=GetPos(candidate)
        if candPos then
            local openSp=OpenSpace4(candPos,8)
            local openPenalty=(openSp/Cfg.OPEN_SEEK_RADIUS)*0.08
            score-=openPenalty
            -- Bonus for candidates who are cornered (harder to escape)
            local cornerBonus=math.clamp((Cfg.CORNER_THRESHOLD-openSp)/Cfg.CORNER_THRESHOLD,0,1)*0.15
            score+=cornerBonus
            local nearbyCount=0
            for _,p2 in ipairs(Players:GetPlayers()) do
                if p2~=candidate and p2~=LocalPlayer and Alive(p2) then
                    local p2pos=GetPos(p2)
                    if p2pos and (p2pos-candPos).Magnitude<15 then nearbyCount+=1 end
                end
            end
            score+=nearbyCount*0.04
        end
        if score>bestScore then bestScore=score;bestTarget=candidate end
    end
    return bestTarget
end

-- =============================================================
-- JUKE BUILDER (unchanged from v4.2)
-- =============================================================
local function BakeDir(origin,dir,repW)
    local safe=SafeDir(origin,dir,repW or 0.45)
    if not PathClear(origin,safe,0.28) then safe=FindOpenCorridor(origin,dir) end
    return safe
end
local function BuildPhases(jukeName,myPos,enemyPos,enemy)
    local toE=SafeN(Flat(enemyPos-myPos)); local away=-toE
    local p1=Vector3.new(-toE.Z,0,toE.X); local p2=Vector3.new(toE.Z,0,-toE.X)
    local p1ok=not(HBCast(myPos,p1,Cfg.WALL_HARD_DIST*2.5))
    local perp=p1ok and p1 or p2; local opp=p1ok and p2 or p1; local rp=MakeRP()
    if jukeName=="spin360" then
        local aDir=p1ok and 1 or -1
        local function arc(prog) local a=prog*math.pi*1.5*aDir
            return BakeDir(myPos,SafeN(Vector3.new(perp.X*math.cos(a)-toE.X*math.sin(a),0,perp.Z*math.cos(a)-toE.Z*math.sin(a)))) end
        return {{m=arc(0.25),f=arc(0.25),dur=0.20},{m=arc(0.55),f=arc(0.55),dur=0.20},
                {m=arc(0.85),f=arc(0.85),dur=0.20},{m=BakeDir(myPos,away),f=away,dur=0.38}}
    elseif jukeName=="ankleBreaker" then
        return {{m=BakeDir(myPos,away),f=away,dur=0.22},{m=BakeDir(myPos,perp,0.30),f=perp,dur=0.60}}
    elseif jukeName=="cooldownJuke" then
        local wt=enemy and GetMem(enemy).reactionTime or 0.26
        return {{m=BakeDir(myPos,away),f=away,dur=math.max(wt,0.18)},{m=BakeDir(myPos,perp,0.30),f=perp,dur=0.58}}
    elseif jukeName=="jacobMethod" then
        local pDir,bestD=Vector3.new(1,0,0),math.huge
        for a=0,315,45 do
            local r=math.rad(a); local dir=Vector3.new(math.cos(r),0,math.sin(r))
            local hit=Workspace:Raycast(myPos,dir*10,rp)
            if hit and not IsTraversable(hit) then local d=(hit.Position-myPos).Magnitude; if d<bestD then bestD=d;pDir=dir end end
        end
        local lp=Vector3.new(-pDir.Z,0,pDir.X)
        local function loopD(t,total) local ft=t/total
            return SafeN(lp*math.cos(ft*math.pi*1.5)+pDir*math.sin(ft*math.pi*1.5)) end
        return {{m=BakeDir(myPos,loopD(0.27,1.1)),f=loopD(0.27,1.1),dur=0.27},
                {m=BakeDir(myPos,loopD(0.55,1.1)),f=loopD(0.55,1.1),dur=0.27},
                {m=BakeDir(myPos,loopD(0.82,1.1)),f=loopD(0.82,1.1),dur=0.27},
                {m=BakeDir(myPos,away),f=away,dur=0.38}}
    elseif jukeName=="wallFlick" then
        local wNorm,runD=Vector3.new(1,0,0),perp
        for _,pd in ipairs({p1,p2}) do
            local hit=Workspace:Raycast(myPos,pd*6,rp)
            if hit and not IsTraversable(hit) then wNorm=SafeN(Flat(hit.Normal));runD=pd;break end
        end
        return {{m=BakeDir(myPos,runD,0.25),f=runD,dur=0.36},
                {m=BakeDir(myPos,SafeN(wNorm+away*0.70)),f=away,dur=0.58}}
    elseif jukeName=="stallJuke" then
        return {{m=SafeN(toE*0.20),f=toE,dur=0.13},{m=Vector3.zero,f=away,dur=0.08},
                {m=BakeDir(myPos,SafeN(away+perp*0.65)),f=away,dur=0.60}}
    elseif jukeName=="doubleCut" then
        return {{m=BakeDir(myPos,perp,0.30),f=perp,dur=0.20},{m=BakeDir(myPos,opp,0.30),f=opp,dur=0.20},
                {m=BakeDir(myPos,SafeN(away+opp*0.40)),f=away,dur=0.45}}
    elseif jukeName=="tripleCut" then
        return {{m=BakeDir(myPos,perp,0.30),f=perp,dur=0.17},{m=BakeDir(myPos,opp,0.30),f=opp,dur=0.17},
                {m=BakeDir(myPos,away,0.40),f=away,dur=0.17},{m=BakeDir(myPos,perp,0.30),f=perp,dur=0.42}}
    elseif jukeName=="hitboxCorner" then
        local cDir,bestS=-toE,-math.huge
        for a=0,315,45 do
            local r=math.rad(a); local dir=Vector3.new(math.cos(r),0,math.sin(r)); local pp=Vector3.new(-dir.Z,0,dir.X)
            local h1=Workspace:Raycast(myPos,dir*5,rp); local h2=Workspace:Raycast(myPos,pp*5,rp)
            if h1 and not IsTraversable(h1) and h2 and not IsTraversable(h2) then
                local sc=-(toE:Dot(dir)); if sc>bestS then bestS=sc;cDir=dir end
            end
        end
        return {{m=BakeDir(myPos,cDir,0.25),f=cDir,dur=0.55},
                {m=BakeDir(myPos,SafeN(away+Vector3.new(-cDir.Z,0,cDir.X)*0.5)),f=away,dur=0.48}}
    elseif jukeName=="camOscillate" then
        local function oD(t) return BakeDir(myPos,SafeN(away+perp*math.sin(t*math.pi*6)*0.85),0.30) end
        return {{m=oD(0.08),f=oD(0.08),dur=0.15},{m=oD(0.22),f=oD(0.22),dur=0.15},
                {m=oD(0.36),f=oD(0.36),dur=0.15},{m=oD(0.50),f=oD(0.50),dur=0.15}}
    elseif jukeName=="circleBreak" then
        local function cD(t) return BakeDir(myPos,SafeN(away*0.55+perp*math.sin(t*math.pi*1.3)),0.30) end
        return {{m=cD(0.19),f=cD(0.19),dur=0.20},{m=cD(0.38),f=cD(0.38),dur=0.20},
                {m=cD(0.57),f=cD(0.57),dur=0.20},{m=BakeDir(myPos,SafeN(away-perp*0.5)),f=away,dur=0.48}}
    elseif jukeName=="simonSays" then
        local mem=enemy and GetMem(enemy) or {reactionTime=0.26}
        local fakeT=math.clamp(mem.reactionTime+0.05+GetPing(),0.18,0.50)
        return {{m=BakeDir(myPos,perp,0.30),f=perp,dur=fakeT},
                {m=BakeDir(myPos,SafeN(away+opp*0.35)),f=away,dur=0.65}}
    elseif jukeName=="headOnPass" then
        local dist=(enemyPos-myPos).Magnitude
        local chargeTime=math.clamp((dist-PingAdjustedHitboxR()-1.5)/16,0.10,0.55)
        return {{m=BakeDir(myPos,toE,0.10),f=toE,dur=chargeTime},
                {m=BakeDir(myPos,perp,0.30),f=perp,dur=0.60}}
    elseif jukeName=="hitboxStall" then
        local hr=PingAdjustedHitboxR()+0.8; local dist=(enemyPos-myPos).Magnitude
        local osc1=BakeDir(myPos,SafeN(away*0.4+perp),0.20)
        local osc2=BakeDir(myPos,SafeN(away*0.4+opp),0.20)
        local escape=BakeDir(myPos,SafeN(away+perp*0.3))
        if dist<hr+2 then
            return {{m=osc1,f=osc1,dur=0.09},{m=osc2,f=osc2,dur=0.09},
                    {m=BakeDir(myPos,SafeN(away*0.6+perp*0.5),0.20),f=away,dur=0.09},
                    {m=osc1,f=osc1,dur=0.09},{m=osc2,f=osc2,dur=0.09},{m=escape,f=escape,dur=0.45}}
        else
            return {{m=BakeDir(myPos,away),f=away,dur=0.15},{m=osc1,f=osc1,dur=0.10},
                    {m=osc2,f=osc2,dur=0.10},{m=osc1,f=osc1,dur=0.10},{m=escape,f=escape,dur=0.50}}
        end
    elseif jukeName=="insideCut" then
        local eVel=SafeN(Flat(GetVel(enemy) or Vector3.zero))
        local chaserRight=Vector3.new(-eVel.Z,0,eVel.X)
        local insideDir=chaserRight:Dot(p1)>0 and p1 or p2
        return {{m=BakeDir(myPos,SafeN(toE*0.50+insideDir*0.85),0.15),f=toE,dur=0.25},
                {m=BakeDir(myPos,SafeN(insideDir+away*0.50)),f=away,dur=0.65}}
    elseif jukeName=="reverseSpin" then
        local aDir=p1ok and 1 or -1
        local function arcF(prog) local a=prog*math.pi*aDir
            return BakeDir(myPos,SafeN(Vector3.new(perp.X*math.cos(a)-toE.X*math.sin(a),0,perp.Z*math.cos(a)-toE.Z*math.sin(a)))) end
        local function arcR(prog) local a=prog*math.pi*(-aDir)*0.9
            return BakeDir(myPos,SafeN(Vector3.new(perp.X*math.cos(a)-toE.X*math.sin(a),0,perp.Z*math.cos(a)-toE.Z*math.sin(a)))) end
        return {{m=arcF(0.3),f=arcF(0.3),dur=0.18},{m=arcF(0.6),f=arcF(0.6),dur=0.18},
                {m=arcR(0.3),f=arcR(0.3),dur=0.18},{m=BakeDir(myPos,away),f=away,dur=0.40}}
    elseif jukeName=="paceBait" then
        local mem=enemy and GetMem(enemy) or {reactionTime=0.26}
        local driftT=math.clamp(mem.reactionTime+0.08+GetPing()*0.5,0.20,0.50)
        return {{m=SafeN(toE*0.15+perp*0.30),f=toE,dur=driftT},
                {m=BakeDir(myPos,SafeN(away+opp*0.70)),f=away,dur=0.70}}
    end
    local md=BakeDir(myPos,away); return {{m=md,f=md,dur=0.65}}
end

-- =============================================================
-- JUKE EXECUTION
-- =============================================================
local function StartJuke(jt,enemy,myPos,enemyPos)
    local phases=BuildPhases(jt,myPos,enemyPos,enemy)
    if not phases or #phases==0 then return end
    local lastPhase=phases[#phases]
    if lastPhase then
        local exitDir=lastPhase.m
        if exitDir and exitDir.Magnitude>0.01 then
            if HBCast(myPos,SafeN(Flat(exitDir)),Cfg.WALL_HARD_DIST*2.5) then return end
            local exitDest=myPos+SafeN(Flat(exitDir))*5
            if OpenSpace4(exitDest,4)<1.5 then return end
        end
    end
    JukeState.active=true; JukeState.jukeType=jt; JukeState.phase=1
    JukeState.timer=0; JukeState.phases=phases
    JukeState.lockedMove=phases[1].m; JukeState.lockedFace=phases[1].f
    local rt=enemy and GetMem(enemy).reactionTime or 0.28
    JukeCooldown=math.clamp(rt*1.4,0.45,0.90)
    JukeStartDist=(myPos and enemyPos) and (myPos-enemyPos).Magnitude or 0
    if enemy then GetMem(enemy).lastJuke=jt end
    MoveDir=phases[1].m; FaceDir=phases[1].f
end
local function StopJuke() JukeState.active=false; JukeState.jukeType=nil; JukeState.phases=nil end
local function TickJuke(dt)
    if not JukeState.active or not JukeState.phases then return false end
    local phases=JukeState.phases; local phase=JukeState.phase
    if phase>#phases then StopJuke(); return false end
    JukeState.timer+=dt
    if JukeState.timer>=phases[phase].dur then
        JukeState.timer-=phases[phase].dur; JukeState.phase+=1; phase=JukeState.phase
        if phase>#phases then StopJuke(); return false end
        JukeState.lockedMove=phases[phase].m; JukeState.lockedFace=phases[phase].f
    end
    MoveDir=JukeState.lockedMove; FaceDir=JukeState.lockedFace; return true
end

-- =============================================================
-- JUKE SCORER (NN-augmented in v5.0)
-- =============================================================
local function ScoreAndSelectJuke(enemy,myPos,enemyPos,dist)
    local m=GetMem(enemy); local rp=MakeRP(); local ps=m.psych
    local toE=SafeN(Flat(enemyPos-myPos))
    local p1=Vector3.new(-toE.Z,0,toE.X); local p2=Vector3.new(toE.Z,0,-toE.X)
    local hasWallPerp,hasObstacle,hasCorner=false,false,false
    for _,pd in ipairs({p1,p2}) do
        local hit=Workspace:Raycast(myPos,pd*6,rp)
        if hit and not IsTraversable(hit) then hasWallPerp=true; break end
    end
    for a=0,315,45 do
        local r=math.rad(a); local d=Vector3.new(math.cos(r),0,math.sin(r))
        local hit=Workspace:Raycast(myPos,d*7,rp)
        if hit and not IsTraversable(hit) then hasObstacle=true; break end
    end
    for a=0,315,45 do
        local r=math.rad(a); local dir=Vector3.new(math.cos(r),0,math.sin(r)); local pp=Vector3.new(-dir.Z,0,dir.X)
        local h1=Workspace:Raycast(myPos,dir*5,rp); local h2=Workspace:Raycast(myPos,pp*5,rp)
        if h1 and not IsTraversable(h1) and h2 and not IsTraversable(h2) then hasCorner=true; break end
    end
    local eVelMag=Flat(GetVel(enemy)).Magnitude; local openAmt=OpenSpace(myPos,12)
    local pingHR=PingAdjustedHitboxR()
    local chaserVel=SafeN(Flat(GetVel(enemy))); local chaserMomentum=Flat(GetVel(enemy)).Magnitude
    local eligible={
        spin360=dist>=8 and dist<=22,       ankleBreaker=dist>=4 and dist<=22,
        cooldownJuke=dist>=8 and dist<=22,  jacobMethod=dist>=5 and hasObstacle,
        wallFlick=dist>=4 and hasWallPerp,  stallJuke=dist>=7 and dist<=20,
        doubleCut=dist<=14,                 tripleCut=dist<=10,
        hitboxCorner=dist<=9 and hasCorner, camOscillate=dist<=8,
        circleBreak=dist>=10 and dist<=28,  simonSays=dist>=6 and dist<=24,
        headOnPass=dist>=(pingHR+6) and dist<=22, hitboxStall=dist>=(pingHR-0.5) and dist<=14,
        insideCut=dist>=6 and dist<=20 and eVelMag>2,
        reverseSpin=dist>=8 and dist<=26 and openAmt>6,
        paceBait=dist>=10 and dist<=28,
    }
    local exitDirs={
        spin360=-(toE),ankleBreaker=p1,cooldownJuke=p1,jacobMethod=-(toE),
        wallFlick=SafeN(-toE+p1*0.8),stallJuke=SafeN(-toE+p1*0.65),
        doubleCut=p2,tripleCut=-(toE),hitboxCorner=SafeN(-toE+p1*0.5),
        camOscillate=-(toE),circleBreak=SafeN(-toE-p1*0.5),
        simonSays=SafeN(-toE+p2*0.35),headOnPass=p1,
        hitboxStall=SafeN(-toE+p1*0.3),insideCut=SafeN(p1-toE*0.5),
        reverseSpin=-(toE),paceBait=SafeN(-toE+p2*0.70),
    }
    local psychBonus={
        wallFlick=ps.wallAffinity*0.20,    hitboxCorner=ps.wallAffinity*0.15,
        simonSays=ps.aggression*0.18,      paceBait=ps.aggression*0.15,
        stallJuke=ps.aggression*0.12,
        camOscillate=ps.unpredictable>0.5 and -0.10 or 0,
        tripleCut=ps.unpredictable<0.3 and 0.10 or 0,
    }
    -- NN-based bonus: use opponent NN prediction to prefer jukes that go perpendicular to predicted move
    local nnOppPred = nil
    local net = NNRegistry[enemy.Name]
    if net and net.replayCount >= Cfg.NN_WARMUP then
        local nnOut = OppNetPredict(enemy, myPos)
        nnOppPred = Vector3.new(nnOut[1], 0, nnOut[2])
    end
    local bestName,bestScore=nil,-math.huge
    for jt,ok in pairs(eligible) do
        if ok then
            local data=m.jukes[jt]; local total=data.s+data.f
            local winRate=total==0 and 0.5 or (data.s/total)
            local rep=(jt==m.lastJuke) and 0.25 or 0
            local exitD=exitDirs[jt] or -(toE)
            local bonus=psychBonus[jt] or 0
            local exitProbe=myPos+exitD*6
            local exitOpenBonus=OpenSpace4(exitProbe,6)*0.038
            local exitBlocked=HBCast(myPos,SafeN(Flat(exitD)),Cfg.WALL_HARD_DIST*2.0)
            if exitBlocked then continue end
            local momentumPerpBonus=0
            if chaserMomentum>5 then
                local perpToChaser=math.abs(exitD:Dot(Vector3.new(-chaserVel.Z,0,chaserVel.X)))
                momentumPerpBonus=perpToChaser*(chaserMomentum/20)*0.18
            end
            -- NN perpendicularity bonus: if juke exit is perpendicular to predicted opp movement → good
            local nnBonus = 0
            if nnOppPred and nnOppPred.Magnitude > 0.05 then
                local perpToNN = math.abs(exitD:Dot(SafeN(nnOppPred)))
                nnBonus = (1 - perpToNN) * 0.15  -- prefer exits perpendicular to NN prediction
            end
            local score=winRate-rep+bonus+exitOpenBonus+momentumPerpBonus+nnBonus
                       +(PathClear(myPos,exitD,Cfg.LOOKAHEAD_TIME) and 0 or -0.35)
                       -HeatAt(enemy.Name,myPos+exitD*8)*0.02
            if score>bestScore then bestScore=score;bestName=jt end
        end
    end
    return bestName or "ankleBreaker",bestScore
end

-- =============================================================
-- BAIT SYSTEM
-- =============================================================
local function TickBait(myPos,enemy,dt,mcEscapeDir)
    if BaitState.cooldown>0 then BaitState.cooldown-=dt end
    if BaitState.active then
        BaitState.timer-=dt
        if BaitState.phase=="display" and BaitState.timer<=0 then
            BaitState.phase="snap"; BaitState.timer=0.55
            MoveDir=BaitState.escapeDir; FaceDir=BaitState.escapeDir; return true
        end
        if BaitState.phase=="snap" and BaitState.timer<=0 then
            BaitState.active=false; BaitState.cooldown=Cfg.BAIT_COOLDOWN; return false
        end
        if BaitState.phase=="display" then MoveDir=BaitState.fakeDir;FaceDir=BaitState.fakeDir
        else MoveDir=BaitState.escapeDir;FaceDir=BaitState.escapeDir end
        return true
    end
    if not enemy then return false end
    local ep=GetPos(enemy); if not ep then return false end
    local dist=(ep-myPos).Magnitude
    if BaitState.cooldown>0 or JukeState.active then return false end
    if dist<Cfg.BAIT_MIN_DIST or dist>Cfg.BAIT_MAX_DIST then return false end
    if not mcEscapeDir then return false end
    local toE=SafeN(Flat(ep-myPos)); local p1=Vector3.new(-toE.Z,0,toE.X)
    local fakeDir=SafeN(toE*0.25+p1*0.50)
    if HBCast(myPos,fakeDir,Cfg.WALL_HARD_DIST) then return false end
    local angleDiff=math.deg(math.acos(math.clamp(fakeDir:Dot(SafeN(mcEscapeDir)),-1,1)))
    if angleDiff<45 then return false end
    BaitState.active=true; BaitState.phase="display"; BaitState.timer=Cfg.BAIT_DISPLAY_TIME
    BaitState.fakeDir=fakeDir; BaitState.escapeDir=SafeDir(myPos,mcEscapeDir,Cfg.WALL_REPULSE_WEIGHT)
    MoveDir=fakeDir; FaceDir=fakeDir; return true
end

-- =============================================================
-- DUMP CHASE
-- =============================================================
local function DoDumpChase(myPos, dt)
    DumpLockTimer-=dt
    if DumpLockTimer<=0 or not DumpTarget or not Alive(DumpTarget) then
        DumpTarget=FindOptimalDumpTarget(myPos); DumpLockTimer=0.50
    end
    if not DumpTarget then MoveDir=Vector3.zero; FaceDir=Vector3.zero; return end
    local tp=GetPos(DumpTarget); if not tp then return end
    local tVel=Flat(GetVel(DumpTarget))
    local aimPos=tp+tVel*(GetPing()*2.0)
    local toAim=SafeN(Flat(aimPos-myPos)); local toTarget=SafeN(Flat(tp-myPos))
    local rawMove=toAim
    if HBCast(myPos,rawMove,Cfg.WALL_HARD_DIST+0.5) then
        rawMove=FindOpenCorridor(myPos,toTarget)
    else
        rawMove=SafeDir(myPos,rawMove,Cfg.WALL_REPULSE_WEIGHT*0.15)  -- minimal wall avoidance = more aggressive
    end
    MoveDir=rawMove; FaceDir=toTarget
end

-- =============================================================
-- STRATEGIC PLANNER
-- =============================================================
local function RunStrategicPlanner()
    local myPos=GetPos(LocalPlayer); if not myPos then return end
    local aliveCount=0; local otherAlive={}
    for _,p in ipairs(Players:GetPlayers()) do
        if Alive(p) then aliveCount+=1; if p~=LocalPlayer then table.insert(otherAlive,p) end end
    end
    if not bombActive then
        StrategicGoal.mode=IHaveTool and "chase" or "evade"
        StrategicGoal.target=CurrentTarget; StrategicGoal.dumpScore=0; return
    end
    if not IHaveTool then
        local carrier=FindCarrier()
        StrategicGoal.mode="evade"; StrategicGoal.target=carrier; StrategicGoal.dumpScore=0; return
    end
    local dumpThreshold=PingAdjustedDumpTime()
    if bombTimeLeft>Cfg.PRESSURE_TAG_TIME+1.0 then
        local optimalDump=FindOptimalDumpTarget(myPos)
        StrategicGoal.mode="chase"; StrategicGoal.target=CurrentTarget
        if optimalDump then DumpTarget=optimalDump; DumpLockTimer=Cfg.PLAN_UPDATE_INTERVAL end
        StrategicGoal.dumpScore=0; return
    end
    local bestTarget=FindOptimalDumpTarget(myPos)
    if bestTarget then
        local score=MCEvalDumpTarget(myPos,bestTarget)
        StrategicGoal.dumpScore=score
        if bombTimeLeft<=dumpThreshold then
            StrategicGoal.mode="dump"; StrategicGoal.target=bestTarget
            DumpTarget=bestTarget; DumpLockTimer=0.4
        else
            StrategicGoal.mode="chase"; StrategicGoal.target=bestTarget
            CurrentTarget=bestTarget; DumpTarget=bestTarget
        end
    else
        StrategicGoal.mode=IHaveTool and "chase" or "evade"; StrategicGoal.target=CurrentTarget
    end
end

-- =============================================================
-- ╔══════════════════════════════════════════════════════════════╗
-- ║         AGGRESSIVE CHASE (v5.0 – KILL MODE)                  ║
-- ║  Strategies:                                                  ║
-- ║  1. Pure intercept: aim at predicted position 0.55s ahead    ║
-- ║  2. Cut-off: if target is running, block their escape arc     ║
-- ║  3. Wall-herd: force targets into walls for easy kills        ║
-- ║  4. Close-range charge: straight line below 5 studs          ║
-- ║  5. NN-guided intercept from decision network output          ║
-- ╚══════════════════════════════════════════════════════════════╝
-- =============================================================

-- Compute the cut-off intercept direction (v5.0)
-- If target is running perpendicular, cut ahead of them
local function ComputeCutoffDir(myPos, tp, tVel, dist)
    if tVel.Magnitude < 1.5 then return nil end
    local tSpeed   = tVel.Magnitude
    local mySpeed  = Cfg.SPEED_WITH_TOOL
    -- Time for me to travel across target's path
    local tDir     = SafeN(tVel)
    local toTarget = SafeN(Flat(tp - myPos))
    local sideDot  = tDir:Dot(Vector3.new(-toTarget.Z, 0, toTarget.X))
    if math.abs(sideDot) < Cfg.AGGR_CUTOFF_ANGLE then return nil end  -- target not running sideways
    -- Predict where target will be in the cutoff time
    local cutoffT  = math.clamp(dist / mySpeed * 0.6, 0.2, 1.0)
    local targetFuturePos = tp + tVel * cutoffT
    -- Aim for the intercept point
    local cutDir = SafeN(Flat(targetFuturePos - myPos))
    if HBCast(myPos, cutDir, Cfg.WALL_HARD_DIST) then return nil end
    return cutDir
end

-- Aggressive wall herd: find which wall direction forces target into a dead-end
local function ComputeHerdDir(myPos, tp, toTarget, rp2)
    local herdBias = Vector3.zero
    local bestWS   = 0
    local nRays    = OptimizedMode and 8 or Cfg.AGGR_HERD_RAYS
    for i = 0, nRays-1 do
        local a    = (i/nRays)*math.pi*2
        local d    = Vector3.new(math.cos(a), 0, math.sin(a))
        -- Look for walls near target in this direction
        local hit  = Workspace:Raycast(tp, SafeN(-toTarget+d*0.5)*Cfg.AGGR_HERD_DIST, rp2)
        if hit then
            local wd    = (hit.Position - tp).Magnitude
            local sc    = (Cfg.AGGR_HERD_DIST - wd) / Cfg.AGGR_HERD_DIST
            if sc > bestWS then
                local herdDest   = tp + SafeN(Flat(hit.Position - myPos))*5
                local herdOpen   = OpenSpace4(herdDest, 5)
                local herdScore  = sc * (1 + (Cfg.CORNER_THRESHOLD-herdOpen)*0.10)
                if herdScore > bestWS then
                    bestWS   = herdScore
                    herdBias = SafeN(Flat(hit.Position - myPos))*sc
                end
            end
        end
    end
    return herdBias, bestWS
end

local function DoChase(myPos, target, dt)
    if not target then MoveDir=Vector3.zero; FaceDir=Vector3.zero; return end
    local tp   = GetPos(target); if not tp then return end
    local tVel = Flat(GetVel(target))
    local dist = (tp - myPos).Magnitude

    -- Always face target directly (instant – no smoothing during chase)
    local toTarget = SafeN(Flat(tp - myPos))
    FaceDir        = toTarget

    -- ── 0. Ultra-close range: pure straight charge ──────────────
    if dist <= Cfg.AGGR_CLOSE_THRESHOLD then
        local chargeDir = SafeN(Flat(tp - myPos))
        MoveDir         = chargeDir
        return
    end

    -- ── 1. Path check: LOS and distance ─────────────────────────
    local rp = MakeRP()
    local losResult = Workspace:Raycast(myPos, toTarget*dist, rp)
    local hasLOS    = (not losResult) or IsTraversable(losResult)
    local needPath  = not hasLOS or dist > Cfg.LOS_TRIGGER_DIST

    if needPath then
        local shouldReplan = not PathFollowing.active
            or PathFollowing.targetPlayer ~= target
            or (os.clock() - PathFollowing.lastReplan) > Cfg.PATH_REPLAN_INTERVAL
        if shouldReplan then RequestPathTo(target) end
        if PathFollowing.active then if UpdatePathFollowing(myPos, dt) then return end end
        if not PathFollowing.active then
            local fallback = FindOpenCorridor(myPos, toTarget)
            MoveDir = LerpV(MoveDir, fallback, Cfg.CHASE_MOVE_LERP)
            return
        end
        return
    end

    PathFollowing.active = false

    -- ── 2. Determine chase mode based on bomb timer ──────────────
    local dumpThreshold = PingAdjustedDumpTime()
    local mode = "normal"
    if bombActive then
        if bombTimeLeft <= dumpThreshold then DoDumpChase(myPos,dt); return
        elseif bombTimeLeft <= Cfg.PANIC_TAG_TIME then  mode="panic"
        elseif bombTimeLeft <= Cfg.PRESSURE_TAG_TIME then mode="pressure" end
    end

    -- ── 3. Compute intercept position (aggressive) ───────────────
    local mySpeed      = Cfg.SPEED_WITH_TOOL
    local speedRatio   = mySpeed / math.max(GetPlayerSpeed(target),1)
    local rawMove

    if mode == "panic" then
        -- Panic: direct aim at ping-compensated position
        local aimPos = tp + tVel*(GetPing()*2.0)
        rawMove      = SafeN(Flat(aimPos - myPos))
        if HBCast(myPos, rawMove, Cfg.WALL_HARD_DIST) then rawMove=FindOpenCorridor(myPos,rawMove) end
        MoveDir = rawMove; return

    else
        -- Intercept: blend current pos and predicted future pos heavily toward prediction
        local interceptT = PingAdjustedPredTime(
            math.clamp(dist/(mySpeed*speedRatio*1.2), 0.15, Cfg.AGGR_INTERCEPT_T)
        )
        -- Use curved prediction for accuracy
        local pp    = PredictCurved(target, interceptT, Cfg.PRED_STEPS) or tp
        -- Also get NN prediction if available
        local nnDir = NeuralPredictDir(target.Name, tp, tVel, myPos)
        local nnPP  = tp
        if nnDir then
            local nnNextPos = tp + nnDir * Cfg.HEATMAP_CELL * 2
            nnPP = nnNextPos
        end
        -- Triple blend: current → curved prediction → NN prediction
        local blendToCurved = Cfg.AGGR_PRED_BLEND
        local blendToNN     = nnDir and 0.20 or 0
        local blendToCurrent= 1 - blendToCurved - blendToNN
        local targetPoint   = tp*blendToCurrent + pp*blendToCurved + nnPP*blendToNN
        rawMove = SafeN(Flat(targetPoint - myPos))

        -- ── 4. Cut-off logic ────────────────────────────────────
        if dist <= Cfg.AGGR_CUTOFF_DIST then
            local cutDir = ComputeCutoffDir(myPos, tp, tVel, dist)
            if cutDir then
                rawMove = SafeN(rawMove*0.45 + cutDir*0.55)   -- bias heavily toward cut-off
            end
        end

        -- ── 5. Wall herd (force into corners) ───────────────────
        local rp2 = MakeRP()
        local herdBias, herdScore = ComputeHerdDir(myPos, tp, toTarget, rp2)
        if herdScore > 0.15 then
            rawMove = SafeN(rawMove + herdBias*Cfg.AGGR_CORNER_WEIGHT)
        end

        -- ── 6. Corner bonus: if target is trapped, charge hard ──
        local targetOpenSp = OpenSpace4(tp, 8)
        if targetOpenSp < Cfg.CORNER_THRESHOLD then
            -- Target is cornered – ignore wall repulsion, full charge
            local chargeDir = SafeN(Flat(tp - myPos))
            if not HBCast(myPos, chargeDir, Cfg.WALL_HARD_DIST) then
                rawMove = SafeN(rawMove*(1-Cfg.AGGR_CORNER_BOOST) + chargeDir*Cfg.AGGR_CORNER_BOOST)
            end
        end

        -- ── 7. NN decision network guidance ─────────────────────
        if DecisionNet and DecisionNet.replayCount >= Cfg.NN_WARMUP then
            local decInp = BuildDecisionInput(myPos, target)
            local decOut = DecisionNet:forward(decInp)
            -- decOut[1..2] = NN-suggested move direction
            local nnMoveX = decOut[1]; local nnMoveZ = decOut[2]
            local nnMove  = Vector3.new(nnMoveX, 0, nnMoveZ)
            if nnMove.Magnitude > 0.05 then
                nnMove  = SafeN(nnMove)
                rawMove = SafeN(rawMove*0.75 + nnMove*0.25)
            end
        end

        -- ── 8. Wall collision avoidance (minimal for aggression) ─
        if HBCast(myPos, rawMove, Cfg.WALL_HARD_DIST+1) then
            rawMove = FindOpenCorridor(myPos, rawMove)
        else
            -- Light repulsion only when chasing
            rawMove = SafeDir(myPos, rawMove, Cfg.WALL_REPULSE_WEIGHT*0.25)
        end
    end

    -- Apply with aggressive lerp
    MoveDir = LerpV(MoveDir, rawMove, Cfg.CHASE_MOVE_LERP)
end

-- =============================================================
-- EVADE (NN + BAP enhanced)
-- =============================================================
local function DoEvade(myPos, enemy, dt)
    if not enemy then MoveDir=Vector3.zero; FaceDir=Vector3.zero; return end
    local ep=GetPos(enemy); if not ep then return end
    local pingComp=GetPing()*2.0
    local enemyVel=Flat(GetVel(enemy))
    local realEP=ep+enemyVel*pingComp
    local realDist=(realEP-myPos).Magnitude
    local dodgeThreshold=PingAdjustedDodgeTime()

    local aimingAtMe,aimScore=CarrierAimingAtMe(enemy,myPos)
    local effectiveJukeDist=PingAdjustedJukeDist()
    if aimingAtMe and realDist<=Cfg.AIM_JUKE_DIST then
        effectiveJukeDist=math.max(effectiveJukeDist,realDist+1)
    end

    -- BAP-based panic override: if carrier is <BAP_PANIC_THRESHOLD seconds away, dodge NOW
    if BAPSecondsUntilTag < Cfg.BAP_PANIC_THRESHOLD then
        local awayFromCarrier=SafeN(Flat(myPos-realEP))
        local bestDir=awayFromCarrier; local bestScore=-math.huge; local rp=MakeRP()
        for i=0,15 do
            local a=(i/16)*math.pi*2; local d=Vector3.new(math.cos(a),0,math.sin(a))
            if HBCast(myPos,d,Cfg.WALL_HARD_DIST) then continue end
            local awayScore=d:Dot(awayFromCarrier)*2.5
            local openBonus=OpenSpace4(myPos+d*5,6)*0.08
            local heatPenalty=HeatAt(enemy.Name,myPos+d*4)*0.03
            local score=awayScore+openBonus-heatPenalty
            if score>bestScore then bestScore=score;bestDir=d end
        end
        local escDir=SafeDir(myPos,bestDir,Cfg.WALL_REPULSE_WEIGHT)
        MoveDir=LerpV(MoveDir,escDir,0.85)   -- very fast response
        FaceDir=escDir; return
    end

    if CornerTrapScore>0.55 and realDist>Cfg.OPEN_THREAT_NEAR then
        local escapeDir=SafeDir(myPos,OpenSpaceDir,Cfg.WALL_REPULSE_WEIGHT*0.55)
        MoveDir=LerpV(MoveDir,escapeDir,0.55); FaceDir=escapeDir; return
    end

    -- BAP-based warning dodge: if BAP_WARN_THRESHOLD, start early escape
    if BAPSecondsUntilTag < Cfg.BAP_WARN_THRESHOLD and not bombActive then
        -- pre-emptively evade even if carrier isn't in panic range yet
        dodgeThreshold = math.max(dodgeThreshold, BAPSecondsUntilTag * 0.8)
    end

    if bombActive and bombTimeLeft<=dodgeThreshold then
        local timeToReach=realDist/Cfg.SPEED_WITH_TOOL
        if timeToReach<=bombTimeLeft+0.3 then
            local awayFromCarrier=SafeN(Flat(myPos-realEP))
            local bestDir=awayFromCarrier; local bestScore=-math.huge; local rp=MakeRP()
            for i=0,15 do
                local a=(i/16)*math.pi*2; local d=Vector3.new(math.cos(a),0,math.sin(a))
                if HBCast(myPos,d,Cfg.WALL_HARD_DIST) then continue end
                local awayScore=d:Dot(awayFromCarrier)
                local wClear=0
                for j=0,3 do
                    local wa=(j/4)*math.pi*2; local wd=Vector3.new(math.cos(wa),0,math.sin(wa))
                    local wr=Workspace:Raycast(myPos+d*3,wd*Cfg.WALL_NEAR_DIST,rp)
                    wClear+=(wr and not IsTraversable(wr)) and (wr.Position-(myPos+d*3)).Magnitude or Cfg.WALL_NEAR_DIST
                end
                wClear=wClear/4
                local openBonus=OpenSpace4(myPos+d*5,6)*0.06
                local score=awayScore*2.0+wClear*0.3+openBonus
                if score>bestScore then bestScore=score;bestDir=d end
            end
            local escDir=SafeDir(myPos,bestDir,Cfg.WALL_REPULSE_WEIGHT)
            MoveDir=LerpV(MoveDir,escDir,Cfg.MOVE_LERP); FaceDir=escDir; return
        end
    end

    if JukeState.active then
        local alive=TickJuke(Cfg.LOOP_RATE)
        if alive then return end
        local nowDist=(realEP-myPos).Magnitude
        if JukeStartDist>0 then
            if nowDist>=JukeStartDist-0.8 then RecordSuccess(enemy,JukeState.jukeType)
            else
                RecordFail(enemy,JukeState.jukeType)
                AddRTSample(enemy,math.clamp((JukeStartDist-nowDist)/16,0.05,0.6))
            end
        end
        JukeStartDist=0
    end

    local threats=GetThreatData(myPos)
    local mem=GetMem(enemy)
    local predEP=PredictLinear(enemy,mem.reactionTime+0.2) or realEP
    -- Use NN-enhanced prediction for evade direction
    local neuralDir=NeuralPredictDir(enemy.Name,ep,enemyVel,myPos)
    local preferredAway=SafeN(Flat(myPos-predEP))
    if neuralDir then
        local neuralNextEP=ep+neuralDir*Cfg.HEATMAP_CELL*1.5
        local neuralAway=SafeN(Flat(myPos-neuralNextEP))
        preferredAway=SafeN(preferredAway*(1-Cfg.NN_WEIGHT_DIR)+neuralAway*Cfg.NN_WEIGHT_DIR)
    end

    local mcDir=MonteCarloEscape(myPos,threats,preferredAway)
    local trapType=DetectTrap(myPos,threats,mcDir)
    if trapType~="none" then
        local emergencyDir=FindOpenCorridor(myPos,preferredAway)
        if trapType=="pincer" then
            local gapDir=preferredAway; local bestGap=-math.huge
            for i=0,15 do
                local a=(i/16)*math.pi*2; local d=Vector3.new(math.cos(a),0,math.sin(a))
                local minTD=-math.huge
                for _,t in ipairs(threats) do local td=SafeN(Flat(t.pos-myPos)); minTD=math.max(minTD,-d:Dot(td)) end
                if minTD>bestGap then bestGap=minTD;gapDir=d end
            end
            emergencyDir=SafeDir(myPos,gapDir,Cfg.WALL_REPULSE_WEIGHT)
        end
        StopJuke(); RRTCachedDir=nil; RRTCooldown=0
        MoveDir=LerpV(MoveDir,emergencyDir,Cfg.MOVE_LERP); FaceDir=emergencyDir; return
    end

    if bombActive and bombTimeLeft<=Cfg.PANIC_TAG_TIME then
        local escDir=SafeDir(myPos,mcDir,Cfg.WALL_REPULSE_WEIGHT)
        MoveDir=LerpV(MoveDir,escDir,Cfg.MOVE_LERP); FaceDir=escDir; return
    end

    RRTCooldown-=dt
    if RRTCooldown<=0 then
        RRTCooldown=Cfg.RRT_INTERVAL
        local rrtDir=RRTStarEscape(myPos,threats,Cfg.RRT_NODES,Cfg.RRT_STEP)
        if rrtDir and not HBCast(myPos,rrtDir,Cfg.WALL_HARD_DIST) then RRTCachedDir=rrtDir end
    end

    local finalEscape=mcDir
    if RRTCachedDir then
        local blend=SafeN(RRTCachedDir*Cfg.RRT_MC_BLEND+mcDir*(1-Cfg.RRT_MC_BLEND))
        if not HBCast(myPos,blend,Cfg.WALL_HARD_DIST) then finalEscape=blend end
    end

    local openBlend=0
    if realDist>Cfg.OPEN_THREAT_FAR then openBlend=Cfg.OPEN_BLEND_FAR
    elseif realDist>Cfg.OPEN_THREAT_NEAR then
        local t=(realDist-Cfg.OPEN_THREAT_NEAR)/(Cfg.OPEN_THREAT_FAR-Cfg.OPEN_THREAT_NEAR)
        openBlend=Cfg.OPEN_BLEND_NEAR+t*(Cfg.OPEN_BLEND_FAR-Cfg.OPEN_BLEND_NEAR)
    else openBlend=Cfg.OPEN_BLEND_NEAR end

    if openBlend>0.01 and OpenSpaceDir.Magnitude>0.01 then
        local openDot=SafeN(Flat(OpenSpaceDir)):Dot(SafeN(Flat(realEP-myPos)))
        if openDot<0.35 then
            local blended=SafeN(finalEscape*(1-openBlend)+OpenSpaceDir*openBlend)
            if not HBCast(myPos,blended,Cfg.WALL_HARD_DIST) then finalEscape=blended end
        end
    end

    if JukeCooldown<=0 and realDist<effectiveJukeDist then
        local jt,score=ScoreAndSelectJuke(enemy,myPos,realEP,realDist)
        if score>=Cfg.JUKE_SCORE_MIN then StartJuke(jt,enemy,myPos,realEP);TickJuke(Cfg.LOOP_RATE);return end
    end

    if TickBait(myPos,enemy,dt,finalEscape) then return end
    local escDir=SafeDir(myPos,finalEscape,Cfg.WALL_REPULSE_WEIGHT)
    MoveDir=LerpV(MoveDir,escDir,Cfg.MOVE_LERP)
    FaceDir=escDir
end

-- =============================================================
-- ROAM
-- =============================================================
local function DoRoam(myPos)
    if OpenSpaceDir.Magnitude<0.01 then return end
    local curOpen=OpenSpace4(myPos,Cfg.OPEN_SEEK_RADIUS)
    local urgency=math.clamp((Cfg.CORNER_THRESHOLD-curOpen)/Cfg.CORNER_THRESHOLD+0.45,0.45,1.0)
    local roamDir=SafeDir(myPos,OpenSpaceDir,Cfg.WALL_REPULSE_WEIGHT*0.45)
    MoveDir=LerpV(MoveDir,roamDir,Cfg.ROAM_MOVE_LERP*urgency)
    FaceDir=roamDir
end

-- =============================================================
-- ANTI-STUCK
-- =============================================================
local function CheckStuck(myPos,dt)
    if not LastPosition then LastPosition=myPos; return false end
    local moved=(myPos-LastPosition).Magnitude
    StuckTimer=moved<Cfg.STUCK_THRESHOLD*dt and StuckTimer+dt or 0
    LastPosition=myPos; return StuckTimer>Cfg.STUCK_TIME
end

-- =============================================================
-- VELOCITY STABILIZATION
-- =============================================================
local function StabilizeVelocity(hrp)
    local vel=hrp.AssemblyLinearVelocity
    if vel.Magnitude>Cfg.MAX_SPEED+1 then
        hrp.AssemblyLinearVelocity=vel.Unit*Cfg.MAX_SPEED; vel=hrp.AssemblyLinearVelocity
    end
    local vx=Clamp0(vel.X); local vz=Clamp0(vel.Z)
    if vx~=vel.X or vz~=vel.Z then
        hrp.AssemblyLinearVelocity=Vector3.new(vx,vel.Y,vz)
    end
end

-- =============================================================
-- PRECISE POSITION TRACKING
-- =============================================================
local function UpdatePrecisePos(hrp, dt)
    if not PrecisePosInitialized then PrecisePos=hrp.Position; PrecisePosInitialized=true; return end
    local vel=Flat(hrp.AssemblyLinearVelocity); PrecisePos=PrecisePos+vel*dt
    local real=hrp.Position
    if (Vector3.new(PrecisePos.X,real.Y,PrecisePos.Z)-real).Magnitude>Cfg.DRIFT_THRESHOLD then PrecisePos=real end
end

-- NN snapshot state tracking for decision net training
local _decSnap = nil
local _decSnapTime = 0
local _decMyDistThenToTarget = nil

local function TakeDecisionSnapshot(myPos, target)
    if not target then _decSnap=nil; return end
    local inp = BuildDecisionInput(myPos, target)
    local out = DecisionNet:forward(inp)
    _decSnap = {input=inp, output=out, time=os.clock()}
    _decMyDistThenToTarget = target and (GetPos(target) and (GetPos(target)-myPos).Magnitude) or nil
end

local function EvalDecisionOutcome(myPos, target)
    if not _decSnap or not target then return end
    local now = os.clock()
    if now - _decSnap.time < 0.4 then return end   -- wait 0.4s for outcome
    local didImprove = 0
    if _decMyDistThenToTarget then
        local curDist = target and GetPos(target) and (GetPos(target)-myPos).Magnitude or _decMyDistThenToTarget
        if IHaveTool then
            -- Chasing: reward if closer
            didImprove = (curDist < _decMyDistThenToTarget - 1.5) and 1 or
                         (curDist > _decMyDistThenToTarget + 1.5) and -1 or 0
        else
            -- Evading: reward if farther
            didImprove = (curDist > _decMyDistThenToTarget + 1.5) and 1 or
                         (curDist < _decMyDistThenToTarget - 1.5) and -1 or 0
        end
    end
    TrainDecisionNet(_decSnap, myPos, didImprove)
    _decSnap = nil
end

-- =============================================================
-- GUI
-- =============================================================
local function BuildGUI()
    local old=LocalPlayer.PlayerGui:FindFirstChild("TBAI_GUI"); if old then old:Destroy() end
    local sg=Instance.new("ScreenGui"); sg.Name="TBAI_GUI"; sg.ResetOnSpawn=false
    sg.ZIndexBehavior=Enum.ZIndexBehavior.Sibling; sg.Parent=LocalPlayer.PlayerGui
    local fr=Instance.new("Frame"); fr.Name="Panel"
    fr.Size=UDim2.new(0,230,0,250); fr.Position=UDim2.new(0,10,0,10)
    fr.BackgroundColor3=Color3.fromRGB(8,8,12); fr.BorderSizePixel=0
    fr.Active=true; fr.Draggable=true; fr.Parent=sg
    Instance.new("UICorner",fr).CornerRadius=UDim.new(0,8)
    local stk=Instance.new("UIStroke",fr); stk.Color=Color3.fromRGB(40,40,60); stk.Thickness=1
    local function lbl(parent,txt,sz,pos,tsz,font,col,xa)
        local l=Instance.new("TextLabel"); l.Size=sz; l.Position=pos; l.BackgroundTransparency=1
        l.Text=txt; l.TextColor3=col or Color3.fromRGB(188,188,208)
        l.TextSize=tsz or 10; l.Font=font or Enum.Font.Gotham
        l.TextXAlignment=xa or Enum.TextXAlignment.Center; l.Parent=parent; return l
    end
    local function mkBtn(parent,yPos)
        local b=Instance.new("TextButton")
        b.Size=UDim2.new(0,46,0,14); b.Position=UDim2.new(1,-54,0,yPos)
        b.BackgroundColor3=Color3.fromRGB(28,28,40); b.Text="OFF"
        b.TextColor3=Color3.fromRGB(188,188,208); b.TextSize=10
        b.Font=Enum.Font.GothamBold; b.BorderSizePixel=0; b.Parent=parent
        Instance.new("UICorner",b).CornerRadius=UDim.new(0,5); return b
    end
    lbl(fr,"⚡ AnkleBreaker v5.0 ⚡",UDim2.new(1,0,0,18),UDim2.new(0,0,0,4),10,Enum.Font.GothamBold,Color3.fromRGB(255,160,50))
    local sLbl=lbl(fr,"● AI OFF",UDim2.new(1,-64,0,14),UDim2.new(0,6,0,25),10,Enum.Font.Gotham,Color3.fromRGB(210,50,50),Enum.TextXAlignment.Left)
    local aiBtn=mkBtn(fr,25)
    local modeLbl=lbl(fr,"Mode: —",UDim2.new(1,-12,0,13),UDim2.new(0,6,0,42),9,Enum.Font.Gotham,Color3.fromRGB(120,120,150),Enum.TextXAlignment.Left)
    local pingLbl=lbl(fr,"Ping: --ms",UDim2.new(1,-12,0,13),UDim2.new(0,6,0,55),9,Enum.Font.Gotham,Color3.fromRGB(120,120,150),Enum.TextXAlignment.Left)
    local openLbl=lbl(fr,"Space: --",UDim2.new(1,-12,0,13),UDim2.new(0,6,0,68),9,Enum.Font.Gotham,Color3.fromRGB(120,120,150),Enum.TextXAlignment.Left)
    local nnLbl=lbl(fr,"NN: warming...",UDim2.new(1,-12,0,13),UDim2.new(0,6,0,81),9,Enum.Font.Gotham,Color3.fromRGB(100,200,255),Enum.TextXAlignment.Left)
    local bapLbl=lbl(fr,"BAP: —",UDim2.new(1,-12,0,13),UDim2.new(0,6,0,94),9,Enum.Font.Gotham,Color3.fromRGB(150,150,170),Enum.TextXAlignment.Left)
    local jumpSLbl=lbl(fr,"⬆ Jump: OFF",UDim2.new(1,-64,0,13),UDim2.new(0,6,0,109),9,Enum.Font.Gotham,Color3.fromRGB(120,120,150),Enum.TextXAlignment.Left)
    local jumpBtn=mkBtn(fr,108)
    local optSLbl=lbl(fr,"⚙ Optimized: OFF",UDim2.new(1,-64,0,13),UDim2.new(0,6,0,126),9,Enum.Font.Gotham,Color3.fromRGB(120,120,150),Enum.TextXAlignment.Left)
    local optBtn=mkBtn(fr,125)
    local div=Instance.new("Frame"); div.Size=UDim2.new(1,-12,0,1); div.Position=UDim2.new(0,6,0,144)
    div.BackgroundColor3=Color3.fromRGB(48,48,60); div.BorderSizePixel=0; div.Parent=fr
    local bombLbl=lbl(fr,"💣 waiting...",UDim2.new(1,0,0,30),UDim2.new(0,0,0,148),18,Enum.Font.GothamBold,Color3.fromRGB(150,150,170))
    local holderLbl=lbl(fr,"Holder: —",UDim2.new(1,-12,0,14),UDim2.new(0,6,0,183),9,Enum.Font.Gotham,Color3.fromRGB(150,150,170),Enum.TextXAlignment.Left)
    local dumpLbl=lbl(fr,"Dump→ —",UDim2.new(1,-12,0,13),UDim2.new(0,6,0,198),9,Enum.Font.Gotham,Color3.fromRGB(150,150,170),Enum.TextXAlignment.Left)
    local aggLbl=lbl(fr,"Kill mode: —",UDim2.new(1,-12,0,13),UDim2.new(0,6,0,213),9,Enum.Font.Gotham,Color3.fromRGB(255,100,100),Enum.TextXAlignment.Left)

    aiBtn.MouseButton1Click:Connect(function()
        AutoPlayerEnabled=not AutoPlayerEnabled
        if AutoPlayerEnabled then
            aiBtn.Text="ON"; aiBtn.BackgroundColor3=Color3.fromRGB(22,140,70)
            sLbl.Text="● AI ON"; sLbl.TextColor3=Color3.fromRGB(40,210,88); SetAutoRotate(false)
        else
            aiBtn.Text="OFF"; aiBtn.BackgroundColor3=Color3.fromRGB(28,28,40)
            sLbl.Text="● AI OFF"; sLbl.TextColor3=Color3.fromRGB(210,50,50)
            SetAutoRotate(true); releaseAll(); StopJuke()
            BaitState.active=false; RRTCachedDir=nil; MoveDir=Vector3.zero; FaceDir=Vector3.zero
        end
    end)
    jumpBtn.MouseButton1Click:Connect(function()
        AiJumpEnabled=not AiJumpEnabled
        if AiJumpEnabled then
            jumpBtn.Text="ON"; jumpBtn.BackgroundColor3=Color3.fromRGB(22,140,70)
            jumpSLbl.Text="⬆ Jump: ON"; jumpSLbl.TextColor3=Color3.fromRGB(40,210,88)
        else
            jumpBtn.Text="OFF"; jumpBtn.BackgroundColor3=Color3.fromRGB(28,28,40)
            jumpSLbl.Text="⬆ Jump: OFF"; jumpSLbl.TextColor3=Color3.fromRGB(120,120,150); JumpCooldown=0
        end
    end)
    optBtn.MouseButton1Click:Connect(function()
        OptimizedMode=not OptimizedMode; ApplyOptProfile(OptimizedMode); RRTCachedDir=nil; RRTCooldown=0
        if OptimizedMode then
            optBtn.Text="ON"; optBtn.BackgroundColor3=Color3.fromRGB(180,120,20)
            optSLbl.Text="⚙ Optimized: ON"; optSLbl.TextColor3=Color3.fromRGB(240,190,50)
        else
            optBtn.Text="OFF"; optBtn.BackgroundColor3=Color3.fromRGB(28,28,40)
            optSLbl.Text="⚙ Optimized: OFF"; optSLbl.TextColor3=Color3.fromRGB(120,120,150)
        end
    end)
    BombTimerLabel=bombLbl; BombHolderLabel=holderLbl; PingLabel=pingLbl; BAPNNLabel=bapLbl
    return modeLbl, openLbl, dumpLbl, nnLbl, aggLbl
end
local ModeLbl, OpenLbl, DumpLbl, NNLbl, AggLbl = BuildGUI()

-- =============================================================
-- MOBILE JOYSTICK + JUMP BUTTON
-- =============================================================
local SG=Instance.new("ScreenGui"); SG.Name="MobileControls"; SG.ResetOnSpawn=false
SG.ZIndexBehavior=Enum.ZIndexBehavior.Sibling; SG.Parent=LocalPlayer:WaitForChild("PlayerGui")
local jR,tR=70,28
local zone=Instance.new("Frame"); zone.Size=UDim2.new(0,200,0,200); zone.Position=UDim2.new(0,20,1,-230)
zone.BackgroundTransparency=1; zone.Active=true; zone.Parent=SG
local jBase=Instance.new("Frame"); jBase.Size=UDim2.new(0,jR*2,0,jR*2); jBase.AnchorPoint=Vector2.new(0.5,0.5)
jBase.Position=UDim2.new(0.5,0,0.5,0); jBase.BackgroundColor3=Color3.fromRGB(255,255,255)
jBase.BackgroundTransparency=0.6; jBase.BorderSizePixel=0; jBase.Parent=zone
Instance.new("UICorner",jBase).CornerRadius=UDim.new(1,0)
local jThumb=Instance.new("Frame"); jThumb.Size=UDim2.new(0,tR*2,0,tR*2); jThumb.AnchorPoint=Vector2.new(0.5,0.5)
jThumb.Position=UDim2.new(0.5,0,0.5,0); jThumb.BackgroundColor3=Color3.fromRGB(255,255,255)
jThumb.BackgroundTransparency=0.2; jThumb.BorderSizePixel=0; jThumb.Parent=jBase
Instance.new("UICorner",jThumb).CornerRadius=UDim.new(1,0)
local jmpBtn=Instance.new("TextButton"); jmpBtn.Size=UDim2.new(0,90,0,90)
jmpBtn.AnchorPoint=Vector2.new(1,1); jmpBtn.Position=UDim2.new(1,-20,1,-20); jmpBtn.Text="JUMP"
jmpBtn.Font=Enum.Font.GothamBold; jmpBtn.TextColor3=Color3.new(1,1,1); jmpBtn.TextScaled=true
jmpBtn.BackgroundColor3=Color3.fromRGB(255,170,20); jmpBtn.BackgroundTransparency=0.15
jmpBtn.BorderSizePixel=0; jmpBtn.Parent=SG
Instance.new("UICorner",jmpBtn).CornerRadius=UDim.new(1,0)
jmpBtn.InputBegan:Connect(function(inp)
    if inp.UserInputType==Enum.UserInputType.Touch then
        doJump(); jmpBtn.BackgroundColor3=Color3.fromRGB(255,220,80)
        task.delay(0.12,function() jmpBtn.BackgroundColor3=Color3.fromRGB(255,170,20) end)
    end
end)
local maxJR=jR-tR; local activeInp=nil
local function updateJS(iPos)
    if AutoPlayerEnabled then return end
    local ctr=zone.AbsolutePosition+zone.AbsoluteSize/2
    local delta=iPos-ctr; local mag=delta.Magnitude
    local clamp=mag>maxJR and delta.Unit*maxJR or delta
    jThumb.Position=UDim2.new(0.5,clamp.X,0.5,clamp.Y)
    if mag>12 then
        local nx,ny=clamp.X/maxJR,-clamp.Y/maxJR
        local cf=Camera.CFrame
        local fw=Vector3.new(cf.LookVector.X,0,cf.LookVector.Z).Unit
        local rt=Vector3.new(cf.RightVector.X,0,cf.RightVector.Z).Unit
        moveDir((rt*nx+fw*ny).Unit)
    else releaseAll() end
end
zone.InputBegan:Connect(function(inp)
    if inp.UserInputType~=Enum.UserInputType.Touch or activeInp then return end
    activeInp=inp; updateJS(Vector2.new(inp.Position.X,inp.Position.Y))
end)
zone.InputChanged:Connect(function(inp)
    if inp~=activeInp then return end
    updateJS(Vector2.new(inp.Position.X,inp.Position.Y))
end)
zone.InputEnded:Connect(function(inp)
    if inp~=activeInp then return end
    activeInp=nil; jThumb.Position=UDim2.new(0.5,0,0.5,0)
    if not AutoPlayerEnabled then releaseAll() end
end)

-- =============================================================
-- RENDER-STEPPED – rotation (instant when chasing)
-- =============================================================
RunService.RenderStepped:Connect(function(dt)
    if not AutoPlayerEnabled then return end
    local char=LocalPlayer.Character; if not char then return end
    local hrp=char:FindFirstChild("HumanoidRootPart"); if not hrp then return end
    UpdatePrecisePos(hrp, dt)
    StabilizeVelocity(hrp)
    -- When chasing, instant face toward target; otherwise smooth for jukes/baits
    local instant = IHaveTool or (not JukeState.active and not BaitState.active)
    ApplyRotation(FaceDir, instant, dt)
end)

-- =============================================================
-- MAIN HEARTBEAT LOOP
-- =============================================================
RunService.Heartbeat:Connect(function(dt)
    MakeRP()
    UpdatePing(dt)

    if PingLabel then
        local ms=math.floor(PingSeconds*1000+0.5)
        local pingCol=ms<80 and Color3.fromRGB(60,210,80) or ms<150 and Color3.fromRGB(230,200,40) or Color3.fromRGB(230,60,60)
        PingLabel.Text=string.format("Ping: %dms (raw: %dms)", ms, math.floor(PingRaw*1000+0.5))
        PingLabel.TextColor3=pingCol
    end

    if JukeCooldown>0  then JukeCooldown=math.max(0,JukeCooldown-dt) end
    if JumpCooldown>0  then JumpCooldown=math.max(0,JumpCooldown-dt) end
    if BaitState.cooldown>0 then BaitState.cooldown=math.max(0,BaitState.cooldown-dt) end

    -- Bomb state
    local currentHolder=nil; local currentHolderChar=nil
    for _,p in ipairs(Players:GetPlayers()) do
        if HasTool(p) then currentHolder=p; currentHolderChar=p.Character; break end
    end
    if currentHolder then
        bombGrace=0
        if not bombActive then
            bombActive=true; bombStartTime=GetAccurateTime()
            bombEndTime=bombStartTime+Cfg.BOMB_DURATION; bombHolder=currentHolder.Name
        end
        local guiTime=currentHolderChar and GetBombTimeFromHolder(currentHolderChar)
        if guiTime and guiTime>=0 then bombTimeLeft=guiTime
        else bombTimeLeft=math.max(0,bombEndTime-GetAccurateTime()) end
        if bombTimeLeft<0.001 then bombTimeLeft=0 end
    else
        if bombActive then
            bombGrace+=dt
            if bombGrace>=Cfg.BOMB_GRACE then
                bombActive=false; bombStartTime=0; bombEndTime=0
                bombTimeLeft=Cfg.BOMB_DURATION; bombHolder="?"; bombGrace=0
                DumpMode=false; DumpTarget=nil; DumpLockTimer=0
                BAPHistory={}; BAPSecondsUntilTag=math.huge
            end
        end
    end

    if BombTimerLabel then
        if bombActive then
            local col=bombTimeLeft>8 and Color3.fromRGB(80,210,80) or bombTimeLeft>4 and Color3.fromRGB(230,180,40) or Color3.fromRGB(230,60,60)
            BombTimerLabel.Text=string.format("💣 %.1fs",math.ceil(bombTimeLeft*10)/10)
            BombTimerLabel.TextColor3=col
        else
            BombTimerLabel.Text="💣 waiting..."; BombTimerLabel.TextColor3=Color3.fromRGB(150,150,170)
        end
    end
    if BombHolderLabel then
        BombHolderLabel.Text=bombActive and ("Holder: "..bombHolder) or "Holder: —"
    end

    -- Heatmap + NN opponent training
    heatmapTimer+=dt
    if heatmapTimer>=Cfg.HEATMAP_UPDATE_RATE then
        heatmapTimer=0
        local myPos=GetPos(LocalPlayer)
        for _,p in ipairs(Players:GetPlayers()) do
            if p~=LocalPlayer then
                if Alive(p) then
                    local pos=GetPos(p)
                    if pos then
                        local vel=Flat(GetVel(p))
                        AddHeat(p,pos)
                        UpdateNeuralCell(p,pos,vel)
                        UpdateNeuralTransition(p,PrevNeuralPos[p.Name],pos)
                        UpdatePingDriftEstimate(p,pos,vel,Cfg.HEATMAP_UPDATE_RATE)
                        -- NN opponent training
                        if myPos then
                            local prevSnap = NNPrevState[p.Name]
                            TrainOppNet(p, myPos, prevSnap)
                            -- Take new snapshot for next iteration
                            local net = GetOppNet(p.Name)
                            local inp = BuildOppInput(p, myPos)
                            NNPrevState[p.Name] = {pos=pos, vel=vel, input=inp}
                        end
                        PrevNeuralPos[p.Name]=pos
                        if myPos then UpdatePsych(p,myPos) end
                        UpdatePanicModel(p,GetVel(p))
                    end
                end
                DecayHeat(p.Name)
            end
        end
    end

    -- BAP update (every few frames)
    BAPFrameCounter += 1
    if BAPFrameCounter >= 4 then
        BAPFrameCounter = 0
        local myPos = GetPos(LocalPlayer)
        if myPos then UpdateBombArrivalPredictor(myPos) end
    end

    -- BAP label update
    if BAPNNLabel then
        if BombCarrier and Alive(BombCarrier) and BAPSecondsUntilTag < math.huge then
            local bapCol = BAPSecondsUntilTag < Cfg.BAP_PANIC_THRESHOLD and Color3.fromRGB(255,50,50)
                        or BAPSecondsUntilTag < Cfg.BAP_WARN_THRESHOLD  and Color3.fromRGB(255,180,30)
                        or Color3.fromRGB(80,200,120)
            BAPNNLabel.Text=string.format("BAP: %.1fs", BAPSecondsUntilTag)
            BAPNNLabel.TextColor3=bapCol
        else
            BAPNNLabel.Text="BAP: safe"; BAPNNLabel.TextColor3=Color3.fromRGB(80,200,120)
        end
    end

    -- NN label update
    if NNLbl then
        local totalSamples = DecisionNet.replayCount
        local oppSamples = 0
        for _, net in pairs(NNRegistry) do oppSamples += net.replayCount end
        NNLbl.Text=string.format("NN: %d dec / %d opp", totalSamples, oppSamples)
        NNLbl.TextColor3 = totalSamples >= Cfg.NN_WARMUP
            and Color3.fromRGB(80,220,255)
            or  Color3.fromRGB(150,150,100)
    end

    planTimer+=dt
    if planTimer>=Cfg.PLAN_UPDATE_INTERVAL then
        planTimer=0
        if AutoPlayerEnabled then RunStrategicPlanner() end
    end

    if not AutoPlayerEnabled then return end
    SetAutoRotate(false)

    targetTimer+=dt; if targetTimer>=Cfg.TARGET_UPDATE_RATE then targetTimer=0; UpdateTarget() end
    loopTimer+=dt;   if loopTimer<Cfg.LOOP_RATE then return end; loopTimer=0

    local char=LocalPlayer.Character; if not char then return end
    local hum=char:FindFirstChildOfClass("Humanoid")
    if not hum or hum.Health<=0 then releaseAll(); return end
    local myPos=GetPos(LocalPlayer); if not myPos then return end

    _openSpaceDirTimer+=Cfg.LOOP_RATE
    if _openSpaceDirTimer>=Cfg.OPEN_DIR_UPDATE_RATE then
        _openSpaceDirTimer=0
        RefreshOpenSpaceDir(myPos)
        UpdateCornerTrapScore(myPos)
    end

    -- GUI labels
    if OpenLbl then
        local os=OpenSpace4(myPos,Cfg.OPEN_SEEK_RADIUS)
        local trapped=os<Cfg.CORNER_THRESHOLD
        OpenLbl.Text=string.format("Space: %.1f%s",os,trapped and " ⚠" or "")
        OpenLbl.TextColor3=trapped and Color3.fromRGB(230,130,40) or Color3.fromRGB(80,200,120)
    end
    if DumpLbl then
        if IHaveTool and DumpTarget and Alive(DumpTarget) then
            local sc=math.floor((StrategicGoal.dumpScore or 0)*100+0.5)
            DumpLbl.Text=string.format("Dump→ %s (%d%%)",DumpTarget.Name,sc)
            DumpLbl.TextColor3=Color3.fromRGB(230,180,40)
        else
            DumpLbl.Text="Dump→ —"; DumpLbl.TextColor3=Color3.fromRGB(100,100,120)
        end
    end
    -- Kill mode aggression label
    if AggLbl then
        if IHaveTool then
            local tpos = CurrentTarget and GetPos(CurrentTarget)
            if tpos then
                local dist = (tpos - myPos).Magnitude
                local tOpenSp = OpenSpace4(tpos, 8)
                local cornered = tOpenSp < Cfg.CORNER_THRESHOLD
                AggLbl.Text=cornered and string.format("🎯 CORNERED (%.1f)",dist) or string.format("🔪 HUNTING (%.1f)",dist)
                AggLbl.TextColor3=cornered and Color3.fromRGB(255,50,50) or Color3.fromRGB(255,130,50)
            end
        else
            if BAPSecondsUntilTag < Cfg.BAP_PANIC_THRESHOLD then
                AggLbl.Text="🚨 BAP PANIC DODGE"
                AggLbl.TextColor3=Color3.fromRGB(255,30,30)
            elseif BAPSecondsUntilTag < Cfg.BAP_WARN_THRESHOLD then
                AggLbl.Text=string.format("⚠ BAP WARNING %.1fs",BAPSecondsUntilTag)
                AggLbl.TextColor3=Color3.fromRGB(255,200,50)
            else
                AggLbl.Text="✅ SAFE"; AggLbl.TextColor3=Color3.fromRGB(80,200,80)
            end
        end
    end

    UpdateSmoothedRep(myPos)

    if CheckStuck(myPos,Cfg.LOOP_RATE) then
        StuckTimer=0; AntiStuckDir=FindOpenCorridor(myPos,OpenSpaceDir); AntiStuckTimer=0.40
        PathFollowing.active=false
    end
    if AntiStuckTimer>0 then
        AntiStuckTimer-=Cfg.LOOP_RATE; MoveDir=AntiStuckDir; FaceDir=AntiStuckDir
        TryAiJump(myPos,AntiStuckDir); moveDir(MoveDir); return
    end

    -- Decision network snapshot management
    if DecisionNet.replayCount >= Cfg.NN_WARMUP then
        EvalDecisionOutcome(myPos, CurrentTarget or BombCarrier)
    end
    if os.clock() - _decSnapTime > 0.45 then
        TakeDecisionSnapshot(myPos, CurrentTarget or BombCarrier)
        _decSnapTime = os.clock()
    end
    DecisionNet:tick()   -- run batch backprop if needed

    if ModeLbl then
        local modeStr="—"; local dumpThresh=PingAdjustedDumpTime()
        if IHaveTool then
            if bombActive then
                if bombTimeLeft<=dumpThresh then modeStr="⚡ DUMP NOW"
                elseif bombTimeLeft<=Cfg.PANIC_TAG_TIME then modeStr="🔴 PANIC TAG"
                elseif bombTimeLeft<=Cfg.PRESSURE_TAG_TIME then modeStr="🟠 PRESSURE"
                else modeStr="🟢 KILL CHASE" end
            else modeStr="🟢 KILL CHASE" end
        else
            local dodgeThresh=PingAdjustedDodgeTime()
            if BAPSecondsUntilTag<Cfg.BAP_PANIC_THRESHOLD then modeStr="🚨 BAP PANIC"
            elseif BAPSecondsUntilTag<Cfg.BAP_WARN_THRESHOLD then modeStr="⚠ BAP WARN"
            elseif JukeState.active then modeStr="💠 JUKE: "..(JukeState.jukeType or "")
            elseif BaitState.active then modeStr="🎣 BAIT"
            elseif CornerTrapScore>0.55 and not bombActive then modeStr="🏃 ROAM"
            elseif bombActive and bombTimeLeft<=dodgeThresh then modeStr="🟣 DODGE DUMP"
            elseif bombActive and bombTimeLeft<=Cfg.PANIC_TAG_TIME then modeStr="🔴 PANIC EVADE"
            else modeStr="🔵 EVADE" end
        end
        ModeLbl.Text="Mode: "..modeStr
    end

    if StrategicGoal.expires>os.clock() then
        if StrategicGoal.mode=="chase" and StrategicGoal.target and Alive(StrategicGoal.target) then
            CurrentTarget=StrategicGoal.target
        elseif StrategicGoal.mode=="dump" and StrategicGoal.target and Alive(StrategicGoal.target) then
            DumpTarget=StrategicGoal.target; DumpLockTimer=0.5
        elseif StrategicGoal.mode=="evade" and StrategicGoal.target and Alive(StrategicGoal.target) then
            BombCarrier=StrategicGoal.target
        end
    end

    if IHaveTool then
        if CurrentTarget and Alive(CurrentTarget) then DoChase(myPos,CurrentTarget,dt) end
    else
        if BombCarrier and Alive(BombCarrier) then
            DoEvade(myPos,BombCarrier,dt)
        else
            DoRoam(myPos)
        end
    end

    MoveDir=BombSafetyOverride(myPos,MoveDir)
    TryAiJump(myPos,MoveDir)
    moveDir(MoveDir)
end)

-- =============================================================
-- RESPAWN RESET
-- =============================================================
LocalPlayer.CharacterAdded:Connect(function()
    LastPosition=nil; StuckTimer=0; AntiStuckTimer=0
    JukeCooldown=0; JukeStartDist=0; JumpCooldown=0
    MoveDir=Vector3.zero; FaceDir=Vector3.zero
    CurrentRotAngle=0; SmoothedRep=Vector3.zero
    BaitState.active=false; BaitState.cooldown=0
    RRTCachedDir=nil; RRTCooldown=0
    LastOpenSpace=8; PrecisePosInitialized=false
    DumpMode=false; DumpTarget=nil; DumpLockTimer=0
    PingDriftBuf={}; PingDriftPrev={}; _CachedRPDirty=true
    PathFollowing.active=false
    StrategicGoal.mode="none"; StrategicGoal.dumpScore=0
    OpenSpaceDir=Vector3.new(0,0,1); CornerTrapScore=0
    _openSpaceDirTimer=0; _cornerScoreTimer=0
    BAPHistory={}; BAPSecondsUntilTag=math.huge; BAPFrameCounter=0
    _decSnap=nil; _decSnapTime=0
    -- Don't reset NNs – keep learned knowledge across respawns!
    StopJuke(); UpdateTarget(); releaseAll()
    task.defer(_RefreshHBHW)
    if AutoPlayerEnabled then task.wait(0.1); SetAutoRotate(false) end
end)
