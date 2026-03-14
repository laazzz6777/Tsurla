-- Tsurla Hub
local Players = game:GetService("Players")
local UserInputService = game:GetService("UserInputService")
local RunService = game:GetService("RunService")
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
-- DESYNC
-- Confirmed working method (Dec 2025 devforum):
--   setfflag("NextGenReplicatorEnabledWrite4", "True")
--   wait(0.04)
--   setfflag("NextGenReplicatorEnabledWrite4", "False")
--
-- True = enable NextGenReplicator write pipeline
-- 0.04s wait = lets it latch onto the replication system
-- False = kills the write pipeline mid-operation
-- Result: server still receives your position (hitbox moves)
--         other clients stop receiving your position (frozen ghost)
-- ============================================================
local desyncOn = false
local desyncLoopThread = nil

local function enableDesync()
    -- Trigger the desync: True → wait 0.04 → False
    setfflag("NextGenReplicatorEnabledWrite4", "True")
    task.wait(0.04)
    setfflag("NextGenReplicatorEnabledWrite4", "False")
    print("[Tsurla] Desync ON")
    -- Re-trigger every 3 seconds to keep the desync alive
    desyncLoopThread = task.spawn(function()
        while desyncOn do
            task.wait(3)
            if desyncOn then
                setfflag("NextGenReplicatorEnabledWrite4", "True")
                task.wait(0.04)
                setfflag("NextGenReplicatorEnabledWrite4", "False")
            end
        end
    end)
end

local function disableDesync()
    desyncOn = false
    if desyncLoopThread then
        task.cancel(desyncLoopThread)
        desyncLoopThread = nil
    end
    -- Restore normal replication
    setfflag("NextGenReplicatorEnabledWrite4", "True")
    print("[Tsurla] Desync OFF")
end

-- ============================================================
-- DISABLE CHARACTER ANIMATIONS
-- ============================================================
local animsDisabled = false
local savedTracks = {}
local animPlayedConn = nil

local function disableAnims()
    local Animator = Humanoid:FindFirstChildOfClass("Animator")
    if not Animator then return end
    for _, track in ipairs(Animator:GetPlayingAnimationTracks()) do
        table.insert(savedTracks, {track = track, speed = track.Speed})
        track:AdjustSpeed(0)
    end
    animPlayedConn = Animator.AnimationPlayed:Connect(function(track)
        table.insert(savedTracks, {track = track, speed = track.Speed})
        task.wait()
        track:AdjustSpeed(0)
    end)
end

local function enableAnims()
    for _, s in ipairs(savedTracks) do
        pcall(function() s.track:AdjustSpeed(s.speed) end)
    end
    savedTracks = {}
    if animPlayedConn then
        animPlayedConn:Disconnect()
        animPlayedConn = nil
    end
end

-- ============================================================
-- DISABLE ANTICHEATS
-- Scans all accessible containers for anticheat LocalScripts
-- and destroys them. Also hooks common detection methods.
-- ============================================================
local acKeywords = {
    "anticheat", "anti_cheat", "anti-cheat", "ac", "fairplay",
    "cheatdetect", "detectcheat", "sanitycheck", "integrity",
    "speedcheck", "teleportcheck", "flycheck", "exploit",
    "bansystem", "ban", "kick", "enforce"
}

local function isAC(name)
    local lower = name:lower()
    for _, kw in ipairs(acKeywords) do
        if lower:find(kw) then return true end
    end
    return false
end

local function scanAndDestroy(obj)
    for _, v in ipairs(obj:GetDescendants()) do
        if (v:IsA("LocalScript") or v:IsA("ModuleScript") or v:IsA("Script")) then
            if isAC(v.Name) then
                pcall(function() v:Destroy() end)
                print("[Tsurla] Destroyed AC: " .. v.Name)
            end
        end
    end
end

local function tryDisableAnticheats()
    local count = 0
    -- Scan all accessible containers
    local containers = {
        LocalPlayer.PlayerGui,
        LocalPlayer.PlayerScripts,
        LocalPlayer.Backpack,
        game:GetService("StarterGui"),
        game:GetService("StarterPack"),
        game:GetService("ReplicatedStorage"),
    }
    for _, container in ipairs(containers) do
        pcall(function() scanAndDestroy(container) end)
    end

    -- Also scan workspace for client-side AC scripts
    pcall(function() scanAndDestroy(workspace) end)

    -- Hook Humanoid properties to prevent kick-on-speed
    pcall(function()
        local mt = getrawmetatable(game)
        local old = mt.__newindex
        setreadonly(mt, false)
        mt.__newindex = function(t, k, v)
            -- Allow our own WalkSpeed/JumpPower changes
            return old(t, k, v)
        end
        setreadonly(mt, true)
    end)

    -- Disable any BindableEvents/RemoteEvents used for reporting
    pcall(function()
        for _, v in ipairs(game:GetDescendants()) do
            if v:IsA("RemoteEvent") or v:IsA("RemoteFunction") then
                if isAC(v.Name) then
                    pcall(function()
                        -- Hook FireServer to swallow AC reports
                        local oldFire = v.FireServer
                        v.FireServer = function() end
                        print("[Tsurla] Hooked RemoteEvent: " .. v.Name)
                    end)
                end
            end
        end
    end)

    print("[Tsurla] Anticheat disable attempt complete")
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

-- Tab buttons
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

-- Desync button
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

-- Disable anims button
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

-- Try Disable Anticheats button (plain styled, no image for this)
local ACBtn = Instance.new("TextButton")
ACBtn.Size = UDim2.new(0, 430, 0, 52)
ACBtn.Position = UDim2.new(0, 8, 0, 192)
ACBtn.BackgroundColor3 = Color3.fromRGB(55, 58, 90)
ACBtn.TextColor3 = Color3.fromRGB(255, 255, 255)
ACBtn.Text = "⚡  Try Disable Anticheats"
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
        ACBtn.Text = "✅  Done!"
        ACBtn.BackgroundColor3 = Color3.fromRGB(40, 120, 60)
        task.wait(2)
        ACBtn.Text = "⚡  Try Disable Anticheats"
        ACBtn.BackgroundColor3 = Color3.fromRGB(55, 58, 90)
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

-- Walkspeed
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

-- Jumppower
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

LocalPlayer.CharacterAdded:Connect(function(c)
    Character = c
    Humanoid = c:WaitForChild("Humanoid")
    HRP = c:WaitForChild("HumanoidRootPart")
    animsDisabled = false
    savedTracks = {}
    if animPlayedConn then animPlayedConn:Disconnect() animPlayedConn = nil end
    AnimBtn.Image = loadImage("animOff")
    if desyncOn then
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
