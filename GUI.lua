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
-- CHECK SETFFLAG SUPPORT
-- ============================================================
local hasFFlag = typeof(setfflag) == "function"
if not hasFFlag then
    warn("[Tsurla] setfflag not supported by this executor!")
else
    print("[Tsurla] setfflag supported!")
end

-- ============================================================
-- DESYNC
-- Goal: Server hitbox moves with you, other clients see you frozen
--
-- Method 1 (newer Roblox): NextGenReplicatorEnabledWrite4
--   Breaks server→other clients replication pipeline only.
--   Client→Server stays intact so server hitbox still moves.
--
-- Method 2 (older Roblox): WorldStepMax
--   setfflag("WorldStepMax","-99999999999999") then wait(1)
--   then setfflag("WorldStepMax","-1")
--   Corrupts physics step timing, breaks outgoing replication
--   to other clients while server still receives position.
--
-- Both methods together cover all Roblox versions.
-- ============================================================
local desyncOn = false
local desyncConn = nil

local function enableDesync()
    if not hasFFlag then
        warn("[Tsurla] Cannot desync: setfflag not available")
        return
    end

    -- Method 1: NextGenReplicator (2026 Roblox)
    pcall(function()
        setfflag("NextGenReplicatorEnabledWrite4", "False")
        setfflag("NextGenReplicatorEnabledWrite4", "True")
    end)

    -- Method 2: WorldStepMax (older Roblox, backup)
    pcall(function()
        setfflag("WorldStepMax", "-99999999999999")
    end)
    task.wait(1)
    pcall(function()
        setfflag("WorldStepMax", "-1")
    end)

    -- Keep re-triggering NextGenReplicator every 2s to maintain desync
    -- (some Roblox versions reset it automatically)
    desyncConn = task.spawn(function()
        while desyncOn do
            pcall(function()
                setfflag("NextGenReplicatorEnabledWrite4", "False")
                setfflag("NextGenReplicatorEnabledWrite4", "True")
            end)
            task.wait(2)
        end
    end)

    print("[Tsurla] Desync enabled")
end

local function disableDesync()
    if not hasFFlag then return end
    desyncOn = false

    -- Restore NextGenReplicator
    pcall(function()
        setfflag("NextGenReplicatorEnabledWrite4", "False")
    end)

    -- Restore WorldStepMax
    pcall(function()
        setfflag("WorldStepMax", "0.1")
    end)

    print("[Tsurla] Desync disabled")
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
MainFrame.Size = UDim2.new(0, 480, 0, 380)
MainFrame.Position = UDim2.new(0.5, -240, 0.5, -190)
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

-- MAIN SECTION
local MainSection = Instance.new("Frame")
MainSection.Size = UDim2.new(1,-16,0,295)
MainSection.Position = UDim2.new(0,8,0,72)
MainSection.BackgroundTransparency = 1
MainSection.Visible = true
MainSection.ZIndex = 3
MainSection.Parent = MainFrame

local DesyncBtn = Instance.new("ImageButton")
DesyncBtn.Size = UDim2.new(0, 430, 0, 75)
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
AnimBtn.Size = UDim2.new(0, 430, 0, 90)
AnimBtn.Position = UDim2.new(0, 8, 0, 98)
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

-- OTHER SECTION
local OtherSection = Instance.new("Frame")
OtherSection.Size = UDim2.new(1,-16,0,295)
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
    if desyncOn then task.spawn(enableDesync) end
    task.wait(0.1)
    local ws = tonumber(WalkInput.Text)
    local jp = tonumber(JumpInput.Text)
    if ws then Humanoid.WalkSpeed = ws end
    if jp then Humanoid.JumpPower = jp end
end)

print("[Tsurla Hub] Loaded! setfflag supported: " .. tostring(hasFFlag))
