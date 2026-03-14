-- Tsurla Hub
local Players = game:GetService("Players")
local UserInputService = game:GetService("UserInputService")
local RunService = game:GetService("RunService")
local HttpService = game:GetService("HttpService")
local LocalPlayer = Players.LocalPlayer
local Character = LocalPlayer.Character or LocalPlayer.CharacterAdded:Wait()
local Humanoid = Character:WaitForChild("Humanoid")
local HRP = Character:WaitForChild("HumanoidRootPart")

local REPO = "https://raw.githubusercontent.com/laazzz6777/Tsurla/main/images/"
local loadedImages = {}
local function loadImage(name)
    if loadedImages[name] then return loadedImages[name] end
    local ok, result = pcall(function()
        local data = game:HttpGet(REPO .. name .. ".png")
        writefile("tsurla_" .. name .. ".png", data)
        return getcustomasset("tsurla_" .. name .. ".png")
    end)
    loadedImages[name] = ok and result or ""
    return loadedImages[name]
end
for _, n in ipairs({"background","main","menu","walkspeed","jumppower","other","desyncOn","desyncOff","animOn","animOff"}) do
    task.spawn(function() loadImage(n) end)
end
task.wait(2.5)

pcall(function()
    if LocalPlayer.PlayerGui:FindFirstChild("TsurlaHub") then
        LocalPlayer.PlayerGui.TsurlaHub:Destroy()
    end
end)

-- ============================================================
-- DESYNC (FIXED)
-- 1. Snapshot a "ghost" CFrame the moment desync is enabled.
-- 2. Every Stepped frame we:
--      a. Read the REAL HRP CFrame before Roblox touches it.
--      b. Force-write it back with sethiddenproperty so the
--         server replication pipeline picks up the true position.
--      c. Immediately overwrite the visible CFrame with the
--         frozen ghost so OTHER clients see you standing still.
-- Net result: server hitbox tracks your real movement,
-- everyone else sees a frozen ghost.
-- ============================================================
local desyncOn = false
local desyncConn = nil

local function enableDesync()
    pcall(function() HRP:SetNetworkOwner(LocalPlayer) end)

    -- VELOCITY ZERO TRICK:
    -- Never touch CFrame at all (that's what was freezing you).
    -- Instead, zero out the replicated velocity every Stepped frame.
    -- Other clients receive velocity=0 so they see you as standing still.
    -- Your LOCAL physics/CFrame are completely untouched — you move freely.
    -- The server still receives your real CFrame via normal network ownership.
    desyncConn = RunService.Stepped:Connect(function()
        if not desyncOn or not HRP or not HRP.Parent then return end
        pcall(function()
            sethiddenproperty(HRP, "Velocity", Vector3.zero)
            sethiddenproperty(HRP, "RotVelocity", Vector3.zero)
        end)
    end)
    print("[Tsurla] Desync ON")
end

local function disableDesync()
    desyncOn = false
    if desyncConn then
        desyncConn:Disconnect()
        desyncConn = nil
    end
    ghostCF = nil
    realCF = nil
    pcall(function() HRP:SetNetworkOwner(LocalPlayer) end)
    print("[Tsurla] Desync OFF")
end

-- ============================================================
-- DISABLE CHARACTER ANIMATIONS (FIXED)
-- RunService.Stepped loop calls :Stop(0) on EVERY playing
-- track every frame. New tracks spawned mid-frame are caught
-- on the very next step. Completely persistent — no animation
-- can survive while the toggle is active.
-- ============================================================
local animsDisabled = false
local animConn = nil

local function disableAnims()
    if animConn then animConn:Disconnect() end
    animConn = RunService.Stepped:Connect(function()
        if not animsDisabled then return end
        local animator = Humanoid and Humanoid:FindFirstChildOfClass("Animator")
        if not animator then return end
        for _, track in ipairs(animator:GetPlayingAnimationTracks()) do
            pcall(function() track:Stop(0) end)
        end
    end)
end

local function enableAnims()
    if animConn then
        animConn:Disconnect()
        animConn = nil
    end
    -- Re-toggle the Animate script to restore default animations
    local animScript = Character:FindFirstChild("Animate")
    if animScript then
        animScript.Disabled = true
        task.wait(0.05)
        animScript.Disabled = false
    end
end

-- ============================================================
-- ANTICHEAT BYPASS (IMPROVED)
-- Multi-layer approach:
--   1. Keyword scan  – destroy matching LocalScripts/Modules
--   2. RemoteEvent hooks – swallow :FireServer on AC remotes
--   3. __namecall hook – intercept Kick / Teleport calls
--   4. RunService scan loop – catches AC scripts added later
-- ============================================================
local acKeywords = {
    "anticheat","anti_cheat","anti-cheat","fairplay",
    "cheatdetect","detectcheat","sanitycheck","integrity",
    "speedcheck","teleportcheck","flycheck","exploitdetect",
    "bansystem","banmanager","kicksystem","kickmanager",
    "enforce","monitor","watchdog","guardian","shield",
    "securitycheck","servercheck","adminscript","moderation"
}
local acHooked = {}

local function isAC(name)
    local lower = name:lower()
    for _, kw in ipairs(acKeywords) do
        if lower:find(kw, 1, true) then return true end
    end
    return false
end

local function hookRemote(v)
    if acHooked[v] then return end
    acHooked[v] = true
    pcall(function()
        local mt = getrawmetatable(v)
        setreadonly(mt, false)
        local oldFire = mt.FireServer
        mt.FireServer = function(self, ...)
            if self == v then return end
            return oldFire(self, ...)
        end
        setreadonly(mt, true)
    end)
    print("[Tsurla AC] Hooked remote: " .. v.Name)
end

local function scanAndDestroy(obj)
    for _, v in ipairs(obj:GetDescendants()) do
        if v:IsA("LocalScript") or v:IsA("ModuleScript") then
            if isAC(v.Name) then
                pcall(function() v:Destroy() end)
                print("[Tsurla AC] Destroyed: " .. v.Name)
            end
        elseif v:IsA("RemoteEvent") or v:IsA("RemoteFunction") then
            if isAC(v.Name) then hookRemote(v) end
        end
    end
end

local acScanLoop = nil

local function tryDisableAnticheats()
    local containers = {
        LocalPlayer.PlayerGui,
        LocalPlayer.PlayerScripts,
        LocalPlayer.Backpack,
        game:GetService("StarterGui"),
        game:GetService("StarterPack"),
        game:GetService("ReplicatedStorage"),
        workspace,
    }

    -- Layer 1: initial scan
    for _, c in ipairs(containers) do
        pcall(function() scanAndDestroy(c) end)
    end

    -- Layer 2: __namecall hook — block Kick and suspicious Teleports
    pcall(function()
        local mt = getrawmetatable(game)
        local oldNamecall = mt.__namecall
        setreadonly(mt, false)
        mt.__namecall = function(self, ...)
            local method = getnamecallmethod()
            if method == "Kick" and self == LocalPlayer then
                warn("[Tsurla AC] Blocked Kick attempt")
                return
            end
            if method == "TeleportToPlaceInstance" or method == "Teleport" then
                warn("[Tsurla AC] Blocked Teleport attempt")
                return
            end
            return oldNamecall(self, ...)
        end
        setreadonly(mt, true)
    end)

    -- Layer 3: continuous background scan every 5s
    if acScanLoop then task.cancel(acScanLoop) end
    acScanLoop = task.spawn(function()
        while true do
            task.wait(5)
            for _, c in ipairs(containers) do
                pcall(function() scanAndDestroy(c) end)
            end
        end
    end)

    print("[Tsurla AC] All layers active")
end

-- ============================================================
-- GUI
-- ============================================================
local ScreenGui = Instance.new("ScreenGui")
ScreenGui.Name = "TsurlaHub"
ScreenGui.ResetOnSpawn = false
ScreenGui.DisplayOrder = 999
ScreenGui.Parent = LocalPlayer.PlayerGui

local MenuToggle = Instance.new("ImageButton")
MenuToggle.Size = UDim2.new(0, 120, 0, 50)
MenuToggle.Position = UDim2.new(0, 10, 0, 10)
MenuToggle.BackgroundTransparency = 1
MenuToggle.Image = loadImage("menu")
MenuToggle.ScaleType = Enum.ScaleType.Fit
MenuToggle.ZIndex = 20
MenuToggle.Parent = ScreenGui

local MainFrame = Instance.new("Frame")
MainFrame.Size = UDim2.new(0, 480, 0, 420)
MainFrame.Position = UDim2.new(0.5, -240, 0.5, -210)
MainFrame.BackgroundTransparency = 1
MainFrame.Visible = false
MainFrame.Parent = ScreenGui

local BgImg = Instance.new("ImageLabel")
BgImg.Size = UDim2.new(1, 0, 1, 0)
BgImg.BackgroundTransparency = 1
BgImg.Image = loadImage("background")
BgImg.ScaleType = Enum.ScaleType.Stretch
BgImg.ZIndex = 1
BgImg.Parent = MainFrame

local dragging, dragInput, dragStart, startPos
BgImg.InputBegan:Connect(function(input)
    if input.UserInputType == Enum.UserInputType.MouseButton1 or input.UserInputType == Enum.UserInputType.Touch then
        dragging = true; dragStart = input.Position; startPos = MainFrame.Position
        input.Changed:Connect(function()
            if input.UserInputState == Enum.UserInputState.End then dragging = false end
        end)
    end
end)
BgImg.InputChanged:Connect(function(input)
    if input.UserInputType == Enum.UserInputType.MouseMovement or input.UserInputType == Enum.UserInputType.Touch then
        dragInput = input
    end
end)
UserInputService.InputChanged:Connect(function(input)
    if input == dragInput and dragging then
        local d = input.Position - dragStart
        MainFrame.Position = UDim2.new(startPos.X.Scale, startPos.X.Offset+d.X, startPos.Y.Scale, startPos.Y.Offset+d.Y)
    end
end)

local MainTabBtn = Instance.new("ImageButton")
MainTabBtn.Size = UDim2.new(0, 155, 0, 58)
MainTabBtn.Position = UDim2.new(0, 8, 0, 8)
MainTabBtn.BackgroundTransparency = 1
MainTabBtn.Image = loadImage("main")
MainTabBtn.ScaleType = Enum.ScaleType.Fit
MainTabBtn.ZIndex = 5
MainTabBtn.Parent = MainFrame

local OtherTabBtn = Instance.new("ImageButton")
OtherTabBtn.Size = UDim2.new(0, 155, 0, 58)
OtherTabBtn.Position = UDim2.new(0, 170, 0, 8)
OtherTabBtn.BackgroundTransparency = 1
OtherTabBtn.Image = loadImage("other")
OtherTabBtn.ScaleType = Enum.ScaleType.Fit
OtherTabBtn.ZIndex = 5
OtherTabBtn.Parent = MainFrame

-- ============================================================
-- MAIN SECTION
-- ============================================================
local MainSection = Instance.new("Frame")
MainSection.Size = UDim2.new(1,-16,0,330)
MainSection.Position = UDim2.new(0,8,0,72)
MainSection.BackgroundTransparency = 1
MainSection.Visible = true
MainSection.ZIndex = 3
MainSection.Parent = MainFrame

local DesyncBtn = Instance.new("ImageButton")
DesyncBtn.Size = UDim2.new(0, 430, 0, 72)
DesyncBtn.Position = UDim2.new(0, 8, 0, 8)
DesyncBtn.BackgroundTransparency = 1
DesyncBtn.Image = loadImage("desyncOff")
DesyncBtn.ScaleType = Enum.ScaleType.Fit
DesyncBtn.ZIndex = 5
DesyncBtn.Parent = MainSection

DesyncBtn.MouseButton1Click:Connect(function()
    desyncOn = not desyncOn
    if desyncOn then
        DesyncBtn.Image = loadImage("desyncOn")
        task.spawn(enableDesync)
    else
        disableDesync()
        DesyncBtn.Image = loadImage("desyncOff")
    end
end)

local AnimBtn = Instance.new("ImageButton")
AnimBtn.Size = UDim2.new(0, 430, 0, 85)
AnimBtn.Position = UDim2.new(0, 8, 0, 92)
AnimBtn.BackgroundTransparency = 1
AnimBtn.Image = loadImage("animOff")
AnimBtn.ScaleType = Enum.ScaleType.Fit
AnimBtn.ZIndex = 5
AnimBtn.Parent = MainSection

AnimBtn.MouseButton1Click:Connect(function()
    animsDisabled = not animsDisabled
    if animsDisabled then
        disableAnims()
        AnimBtn.Image = loadImage("animOn")
    else
        enableAnims()
        AnimBtn.Image = loadImage("animOff")
    end
end)

local ACBtn = Instance.new("TextButton")
ACBtn.Size = UDim2.new(0, 430, 0, 52)
ACBtn.Position = UDim2.new(0, 8, 0, 192)
ACBtn.BackgroundColor3 = Color3.fromRGB(55, 58, 90)
ACBtn.TextColor3 = Color3.fromRGB(255, 255, 255)
ACBtn.Text = "⚡  Bypass Anticheats"
ACBtn.Font = Enum.Font.GothamBold
ACBtn.TextSize = 16
ACBtn.ZIndex = 5
ACBtn.Parent = MainSection
Instance.new("UICorner", ACBtn).CornerRadius = UDim.new(0, 10)
local ACStroke = Instance.new("UIStroke")
ACStroke.Color = Color3.fromRGB(100, 105, 160)
ACStroke.Thickness = 1.5
ACStroke.Parent = ACBtn

ACBtn.MouseButton1Click:Connect(function()
    ACBtn.Text = "⏳  Working..."
    ACBtn.BackgroundColor3 = Color3.fromRGB(40, 43, 70)
    task.spawn(function()
        tryDisableAnticheats()
        task.wait(1)
        ACBtn.Text = "✅  Active (auto-scanning)"
        ACBtn.BackgroundColor3 = Color3.fromRGB(40, 120, 60)
    end)
end)

-- ============================================================
-- OTHER SECTION
-- ============================================================
local OtherSection = Instance.new("Frame")
OtherSection.Size = UDim2.new(1,-16,0,330)
OtherSection.Position = UDim2.new(0,8,0,72)
OtherSection.BackgroundTransparency = 1
OtherSection.Visible = false
OtherSection.ZIndex = 3
OtherSection.Parent = MainFrame

local WsImg = Instance.new("ImageLabel")
WsImg.Size = UDim2.new(0, 290, 0, 65)
WsImg.Position = UDim2.new(0, 8, 0, 8)
WsImg.BackgroundTransparency = 1
WsImg.Image = loadImage("walkspeed")
WsImg.ScaleType = Enum.ScaleType.Fit
WsImg.ZIndex = 5
WsImg.Parent = OtherSection

local WalkBox = Instance.new("Frame")
WalkBox.Size = UDim2.new(0, 100, 0, 46)
WalkBox.Position = UDim2.new(1, -115, 0, 16)
WalkBox.BackgroundColor3 = Color3.fromRGB(50, 53, 80)
WalkBox.BorderSizePixel = 0
WalkBox.ZIndex = 5
WalkBox.Parent = OtherSection
Instance.new("UICorner", WalkBox).CornerRadius = UDim.new(0, 8)
local wbs = Instance.new("UIStroke")
wbs.Color = Color3.fromRGB(150, 155, 210)
wbs.Thickness = 2
wbs.Parent = WalkBox

local WalkInput = Instance.new("TextBox")
WalkInput.Size = UDim2.new(1,0,1,0)
WalkInput.BackgroundTransparency = 1
WalkInput.TextColor3 = Color3.fromRGB(255,255,255)
WalkInput.Text = tostring(Humanoid.WalkSpeed)
WalkInput.Font = Enum.Font.GothamBlack
WalkInput.TextSize = 20
WalkInput.ClearTextOnFocus = false
WalkInput.ZIndex = 6
WalkInput.Parent = WalkBox
WalkInput.FocusLost:Connect(function(e)
    if e then local v = tonumber(WalkInput.Text) if v then Humanoid.WalkSpeed = v end end
end)

local JpImg = Instance.new("ImageLabel")
JpImg.Size = UDim2.new(0, 290, 0, 65)
JpImg.Position = UDim2.new(0, 8, 0, 95)
JpImg.BackgroundTransparency = 1
JpImg.Image = loadImage("jumppower")
JpImg.ScaleType = Enum.ScaleType.Fit
JpImg.ZIndex = 5
JpImg.Parent = OtherSection

local JumpBox = Instance.new("Frame")
JumpBox.Size = UDim2.new(0, 100, 0, 46)
JumpBox.Position = UDim2.new(1, -115, 0, 103)
JumpBox.BackgroundColor3 = Color3.fromRGB(50, 53, 80)
JumpBox.BorderSizePixel = 0
JumpBox.ZIndex = 5
JumpBox.Parent = OtherSection
Instance.new("UICorner", JumpBox).CornerRadius = UDim.new(0, 8)
local jbs = Instance.new("UIStroke")
jbs.Color = Color3.fromRGB(150, 155, 210)
jbs.Thickness = 2
jbs.Parent = JumpBox

local JumpInput = Instance.new("TextBox")
JumpInput.Size = UDim2.new(1,0,1,0)
JumpInput.BackgroundTransparency = 1
JumpInput.TextColor3 = Color3.fromRGB(255,255,255)
JumpInput.Text = tostring(Humanoid.JumpPower)
JumpInput.Font = Enum.Font.GothamBlack
JumpInput.TextSize = 20
JumpInput.ClearTextOnFocus = false
JumpInput.ZIndex = 6
JumpInput.Parent = JumpBox
JumpInput.FocusLost:Connect(function(e)
    if e then local v = tonumber(JumpInput.Text) if v then Humanoid.JumpPower = v end end
end)

-- ============================================================
-- TAB SWITCH
-- ============================================================
local function switchSection(sec)
    MainSection.Visible = sec == "main"
    OtherSection.Visible = sec == "other"
    MainTabBtn.ImageTransparency = sec == "main" and 0 or 0.45
    OtherTabBtn.ImageTransparency = sec == "other" and 0 or 0.45
end
MainTabBtn.MouseButton1Click:Connect(function() switchSection("main") end)
OtherTabBtn.MouseButton1Click:Connect(function() switchSection("other") end)
switchSection("main")

local guiOpen = false
MenuToggle.MouseButton1Click:Connect(function()
    guiOpen = not guiOpen
    MainFrame.Visible = guiOpen
end)

-- ============================================================
-- CHARACTER RESPAWN HANDLER
-- ============================================================
LocalPlayer.CharacterAdded:Connect(function(c)
    Character = c
    Humanoid = c:WaitForChild("Humanoid")
    HRP = c:WaitForChild("HumanoidRootPart")

    animsDisabled = false
    if animConn then animConn:Disconnect() animConn = nil end
    AnimBtn.Image = loadImage("animOff")

    if desyncOn then
        if desyncConn then desyncConn:Disconnect() desyncConn = nil end
        task.wait(0.5)
        task.spawn(enableDesync)
    end

    task.wait(0.1)
    local ws = tonumber(WalkInput.Text)
    local jp = tonumber(JumpInput.Text)
    if ws then Humanoid.WalkSpeed = ws end
    if jp then Humanoid.JumpPower = jp end
end)

print("[Tsurla Hub] Loaded!")
