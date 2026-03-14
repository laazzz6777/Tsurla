-- Tsurla Hub - Original Style
local Players = game:GetService("Players")
local UserInputService = game:GetService("UserInputService")
local LocalPlayer = Players.LocalPlayer
local Character = LocalPlayer.Character or LocalPlayer.CharacterAdded:Wait()
local Humanoid = Character:WaitForChild("Humanoid")

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

-- Preload
local imageNames = {"background","main","menu","walkspeed","jumppower","other","desyncOn","desyncOff","animOn","animOff"}
for _, name in ipairs(imageNames) do
    task.spawn(function() loadImage(name) end)
end
task.wait(2.5)

pcall(function()
    if LocalPlayer.PlayerGui:FindFirstChild("TsurlaHub") then
        LocalPlayer.PlayerGui.TsurlaHub:Destroy()
    end
end)

local ScreenGui = Instance.new("ScreenGui")
ScreenGui.Name = "TsurlaHub"
ScreenGui.ResetOnSpawn = false
ScreenGui.DisplayOrder = 999
ScreenGui.Parent = LocalPlayer.PlayerGui

-- ============================================================
-- MENU TOGGLE BUTTON (always visible, top left)
-- ============================================================
local MenuToggle = Instance.new("ImageButton")
MenuToggle.Size = UDim2.new(0, 130, 0, 55)
MenuToggle.Position = UDim2.new(0, 10, 0, 10)
MenuToggle.BackgroundTransparency = 1
MenuToggle.Image = loadImage("menu")
MenuToggle.ScaleType = Enum.ScaleType.Fit
MenuToggle.ZIndex = 20
MenuToggle.Parent = ScreenGui

-- ============================================================
-- MAIN GUI FRAME (background)
-- ============================================================
local MainFrame = Instance.new("Frame")
MainFrame.Name = "MainFrame"
MainFrame.Size = UDim2.new(0, 500, 0, 400)
MainFrame.Position = UDim2.new(0.5, -250, 0.5, -200)
MainFrame.BackgroundTransparency = 1
MainFrame.Visible = false
MainFrame.Parent = ScreenGui

-- Background image
local BgImg = Instance.new("ImageLabel")
BgImg.Size = UDim2.new(1, 0, 1, 0)
BgImg.BackgroundTransparency = 1
BgImg.Image = loadImage("background")
BgImg.ScaleType = Enum.ScaleType.Stretch
BgImg.ZIndex = 1
BgImg.Parent = MainFrame

-- ============================================================
-- DRAG (on background)
-- ============================================================
local dragging, dragInput, dragStart, startPos
BgImg.InputBegan:Connect(function(input)
    if input.UserInputType == Enum.UserInputType.MouseButton1 or input.UserInputType == Enum.UserInputType.Touch then
        dragging = true
        dragStart = input.Position
        startPos = MainFrame.Position
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
        local delta = input.Position - dragStart
        MainFrame.Position = UDim2.new(startPos.X.Scale, startPos.X.Offset+delta.X, startPos.Y.Scale, startPos.Y.Offset+delta.Y)
    end
end)

-- ============================================================
-- SECTION TABS: Main / Other (image buttons on top of bg)
-- ============================================================
local MainTabBtn = Instance.new("ImageButton")
MainTabBtn.Size = UDim2.new(0, 130, 0, 55)
MainTabBtn.Position = UDim2.new(0, 10, 0, 10)
MainTabBtn.BackgroundTransparency = 1
MainTabBtn.Image = loadImage("main")
MainTabBtn.ScaleType = Enum.ScaleType.Fit
MainTabBtn.ZIndex = 5
MainTabBtn.Parent = MainFrame

local OtherTabBtn = Instance.new("ImageButton")
OtherTabBtn.Size = UDim2.new(0, 130, 0, 55)
OtherTabBtn.Position = UDim2.new(0, 150, 0, 10)
OtherTabBtn.BackgroundTransparency = 1
OtherTabBtn.Image = loadImage("other")
OtherTabBtn.ScaleType = Enum.ScaleType.Fit
OtherTabBtn.ZIndex = 5
OtherTabBtn.Parent = MainFrame

-- ============================================================
-- MAIN SECTION (Desync + Disable Anims)
-- ============================================================
local MainSection = Instance.new("Frame")
MainSection.Size = UDim2.new(1, -20, 0, 280)
MainSection.Position = UDim2.new(0, 10, 0, 75)
MainSection.BackgroundTransparency = 1
MainSection.Visible = true
MainSection.ZIndex = 3
MainSection.Parent = MainFrame

-- Desync toggle
local desyncOn = false
local DesyncBtn = Instance.new("ImageButton")
DesyncBtn.Size = UDim2.new(0, 360, 0, 70)
DesyncBtn.Position = UDim2.new(0, 10, 0, 10)
DesyncBtn.BackgroundTransparency = 1
DesyncBtn.Image = loadImage("desyncOff")
DesyncBtn.ScaleType = Enum.ScaleType.Fit
DesyncBtn.ZIndex = 5
DesyncBtn.Parent = MainSection

DesyncBtn.MouseButton1Click:Connect(function()
    desyncOn = not desyncOn
    DesyncBtn.Image = loadImage(desyncOn and "desyncOn" or "desyncOff")
end)

-- Disable anims toggle
local animsOff = false
local savedTracks = {}
local AnimBtn = Instance.new("ImageButton")
AnimBtn.Size = UDim2.new(0, 400, 0, 80)
AnimBtn.Position = UDim2.new(0, 10, 0, 95)
AnimBtn.BackgroundTransparency = 1
AnimBtn.Image = loadImage("animOff")
AnimBtn.ScaleType = Enum.ScaleType.Fit
AnimBtn.ZIndex = 5
AnimBtn.Parent = MainSection

AnimBtn.MouseButton1Click:Connect(function()
    animsOff = not animsOff
    AnimBtn.Image = loadImage(animsOff and "animOn" or "animOff")
    local Animator = Humanoid:FindFirstChildOfClass("Animator")
    if animsOff then
        if Animator then
            for _, t in ipairs(Animator:GetPlayingAnimationTracks()) do
                table.insert(savedTracks, {track=t, speed=t.Speed})
                t:AdjustSpeed(0)
            end
        end
    else
        for _, s in ipairs(savedTracks) do
            pcall(function() s.track:AdjustSpeed(s.speed) end)
        end
        savedTracks = {}
    end
end)

-- ============================================================
-- OTHER SECTION (Speed + Jump)
-- ============================================================
local OtherSection = Instance.new("Frame")
OtherSection.Size = UDim2.new(1, -20, 0, 280)
OtherSection.Position = UDim2.new(0, 10, 0, 75)
OtherSection.BackgroundTransparency = 1
OtherSection.Visible = false
OtherSection.ZIndex = 3
OtherSection.Parent = MainFrame

-- Walkspeed label image + input
local WsImg = Instance.new("ImageLabel")
WsImg.Size = UDim2.new(0, 300, 0, 60)
WsImg.Position = UDim2.new(0, 10, 0, 10)
WsImg.BackgroundTransparency = 1
WsImg.Image = loadImage("walkspeed")
WsImg.ScaleType = Enum.ScaleType.Fit
WsImg.ZIndex = 5
WsImg.Parent = OtherSection

local WalkInput = Instance.new("TextBox")
WalkInput.Size = UDim2.new(0, 100, 0, 44)
WalkInput.Position = UDim2.new(0, 330, 0, 13)
WalkInput.BackgroundColor3 = Color3.fromRGB(55, 58, 90)
WalkInput.TextColor3 = Color3.fromRGB(255, 255, 255)
WalkInput.PlaceholderText = "Speed"
WalkInput.PlaceholderColor3 = Color3.fromRGB(150, 150, 180)
WalkInput.Text = tostring(Humanoid.WalkSpeed)
WalkInput.Font = Enum.Font.GothamBold
WalkInput.TextSize = 18
WalkInput.ClearTextOnFocus = false
WalkInput.ZIndex = 6
WalkInput.Parent = OtherSection
Instance.new("UICorner", WalkInput).CornerRadius = UDim.new(0, 10)

WalkInput.FocusLost:Connect(function(enter)
    if enter then
        local v = tonumber(WalkInput.Text)
        if v then Humanoid.WalkSpeed = v end
    end
end)

-- Jumppower label image + input
local JpImg = Instance.new("ImageLabel")
JpImg.Size = UDim2.new(0, 300, 0, 60)
JpImg.Position = UDim2.new(0, 10, 0, 90)
JpImg.BackgroundTransparency = 1
JpImg.Image = loadImage("jumppower")
JpImg.ScaleType = Enum.ScaleType.Fit
JpImg.ZIndex = 5
JpImg.Parent = OtherSection

local JumpInput = Instance.new("TextBox")
JumpInput.Size = UDim2.new(0, 100, 0, 44)
JumpInput.Position = UDim2.new(0, 330, 0, 93)
JumpInput.BackgroundColor3 = Color3.fromRGB(55, 58, 90)
JumpInput.TextColor3 = Color3.fromRGB(255, 255, 255)
JumpInput.PlaceholderText = "Power"
JumpInput.PlaceholderColor3 = Color3.fromRGB(150, 150, 180)
JumpInput.Text = tostring(Humanoid.JumpPower)
JumpInput.Font = Enum.Font.GothamBold
JumpInput.TextSize = 18
JumpInput.ClearTextOnFocus = false
JumpInput.ZIndex = 6
JumpInput.Parent = OtherSection
Instance.new("UICorner", JumpInput).CornerRadius = UDim.new(0, 10)

JumpInput.FocusLost:Connect(function(enter)
    if enter then
        local v = tonumber(JumpInput.Text)
        if v then Humanoid.JumpPower = v end
    end
end)

-- ============================================================
-- TAB SWITCHING
-- ============================================================
local function switchSection(sec)
    MainSection.Visible = sec == "main"
    OtherSection.Visible = sec == "other"
    MainTabBtn.ImageTransparency = sec == "main" and 0 or 0.4
    OtherTabBtn.ImageTransparency = sec == "other" and 0 or 0.4
end

MainTabBtn.MouseButton1Click:Connect(function() switchSection("main") end)
OtherTabBtn.MouseButton1Click:Connect(function() switchSection("other") end)
switchSection("main")

-- ============================================================
-- MENU TOGGLE (show/hide GUI)
-- ============================================================
local guiVisible = false
MenuToggle.MouseButton1Click:Connect(function()
    guiVisible = not guiVisible
    MainFrame.Visible = guiVisible
end)

-- ============================================================
-- RESPAWN
-- ============================================================
LocalPlayer.CharacterAdded:Connect(function(c)
    Character = c
    Humanoid = c:WaitForChild("Humanoid")
    WalkInput.Text = tostring(Humanoid.WalkSpeed)
    JumpInput.Text = tostring(Humanoid.JumpPower)
    desyncOn = false
    animsOff = false
    savedTracks = {}
    DesyncBtn.Image = loadImage("desyncOff")
    AnimBtn.Image = loadImage("animOff")
end)

print("[Tsurla Hub] Loaded!")
