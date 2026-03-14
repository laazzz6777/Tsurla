-- Tsurla Hub
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
-- MENU TOGGLE (always visible)
-- ============================================================
local MenuToggle = Instance.new("ImageButton")
MenuToggle.Size = UDim2.new(0, 120, 0, 50)
MenuToggle.Position = UDim2.new(0, 10, 0, 10)
MenuToggle.BackgroundTransparency = 1
MenuToggle.Image = loadImage("menu")
MenuToggle.ScaleType = Enum.ScaleType.Fit
MenuToggle.ZIndex = 20
MenuToggle.Parent = ScreenGui

-- ============================================================
-- MAIN FRAME
-- ============================================================
local MainFrame = Instance.new("Frame")
MainFrame.Name = "MainFrame"
MainFrame.Size = UDim2.new(0, 480, 0, 380)
MainFrame.Position = UDim2.new(0.5, -240, 0.5, -190)
MainFrame.BackgroundTransparency = 1
MainFrame.Visible = false
MainFrame.Parent = ScreenGui

-- Background image
local BgImg = Instance.new("ImageLabel")
BgImg.Size = UDim2.new(1, 0, 1, 0)
BgImg.Position = UDim2.new(0, 0, 0, 0)
BgImg.BackgroundTransparency = 1
BgImg.Image = loadImage("background")
BgImg.ScaleType = Enum.ScaleType.Stretch
BgImg.ZIndex = 1
BgImg.Parent = MainFrame

-- ============================================================
-- DRAG
-- ============================================================
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

-- ============================================================
-- TAB BUTTONS (Main / Other) — pure image, no background
-- ============================================================
local MainTabBtn = Instance.new("ImageButton")
MainTabBtn.Size = UDim2.new(0, 160, 0, 58)
MainTabBtn.Position = UDim2.new(0, 8, 0, 8)
MainTabBtn.BackgroundTransparency = 1
MainTabBtn.Image = loadImage("main")
MainTabBtn.ScaleType = Enum.ScaleType.Fit
MainTabBtn.ZIndex = 5
MainTabBtn.Parent = MainFrame

local OtherTabBtn = Instance.new("ImageButton")
OtherTabBtn.Size = UDim2.new(0, 160, 0, 58)
OtherTabBtn.Position = UDim2.new(0, 175, 0, 8)
OtherTabBtn.BackgroundTransparency = 1
OtherTabBtn.Image = loadImage("other")
OtherTabBtn.ScaleType = Enum.ScaleType.Fit
OtherTabBtn.ZIndex = 5
OtherTabBtn.Parent = MainFrame

-- ============================================================
-- MAIN SECTION — Desync + Disable Anims (pure image buttons)
-- ============================================================
local MainSection = Instance.new("Frame")
MainSection.Size = UDim2.new(1, -16, 0, 290)
MainSection.Position = UDim2.new(0, 8, 0, 72)
MainSection.BackgroundTransparency = 1
MainSection.Visible = true
MainSection.ZIndex = 3
MainSection.Parent = MainFrame

-- Desync button
local desyncOn = false
local DesyncBtn = Instance.new("ImageButton")
DesyncBtn.Size = UDim2.new(0, 420, 0, 75)
DesyncBtn.Position = UDim2.new(0, 8, 0, 8)
DesyncBtn.BackgroundTransparency = 1
DesyncBtn.Image = loadImage("desyncOff")
DesyncBtn.ScaleType = Enum.ScaleType.Fit
DesyncBtn.ZIndex = 5
DesyncBtn.Parent = MainSection

DesyncBtn.MouseButton1Click:Connect(function()
    desyncOn = not desyncOn
    DesyncBtn.Image = loadImage(desyncOn and "desyncOn" or "desyncOff")
end)

-- Disable anims button
local animsOff = false
local savedTracks = {}
local AnimBtn = Instance.new("ImageButton")
AnimBtn.Size = UDim2.new(0, 420, 0, 88)
AnimBtn.Position = UDim2.new(0, 8, 0, 95)
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
-- OTHER SECTION — Walkspeed + Jumppower (image + input)
-- ============================================================
local OtherSection = Instance.new("Frame")
OtherSection.Size = UDim2.new(1, -16, 0, 290)
OtherSection.Position = UDim2.new(0, 8, 0, 72)
OtherSection.BackgroundTransparency = 1
OtherSection.Visible = false
OtherSection.ZIndex = 3
OtherSection.Parent = MainFrame

-- Walkspeed image (pure, transparent)
local WsImg = Instance.new("ImageLabel")
WsImg.Size = UDim2.new(0, 310, 0, 65)
WsImg.Position = UDim2.new(0, 8, 0, 8)
WsImg.BackgroundTransparency = 1
WsImg.Image = loadImage("walkspeed")
WsImg.ScaleType = Enum.ScaleType.Fit
WsImg.ZIndex = 5
WsImg.Parent = OtherSection

-- Walkspeed input (no border style, blends in)
local WalkInput = Instance.new("TextBox")
WalkInput.Size = UDim2.new(0, 95, 0, 42)
WalkInput.Position = UDim2.new(1, -108, 0, 16)
WalkInput.BackgroundTransparency = 1
WalkInput.TextColor3 = Color3.fromRGB(255, 255, 255)
WalkInput.PlaceholderText = "16"
WalkInput.PlaceholderColor3 = Color3.fromRGB(180, 180, 200)
WalkInput.Text = tostring(Humanoid.WalkSpeed)
WalkInput.Font = Enum.Font.GothamBlack
WalkInput.TextSize = 22
WalkInput.ClearTextOnFocus = false
WalkInput.ZIndex = 6
WalkInput.Parent = OtherSection
WalkInput.FocusLost:Connect(function(e)
    if e then local v = tonumber(WalkInput.Text) if v then Humanoid.WalkSpeed = v end end
end)

-- Jumppower image (pure, transparent)
local JpImg = Instance.new("ImageLabel")
JpImg.Size = UDim2.new(0, 310, 0, 65)
JpImg.Position = UDim2.new(0, 8, 0, 90)
JpImg.BackgroundTransparency = 1
JpImg.Image = loadImage("jumppower")
JpImg.ScaleType = Enum.ScaleType.Fit
JpImg.ZIndex = 5
JpImg.Parent = OtherSection

-- Jumppower input
local JumpInput = Instance.new("TextBox")
JumpInput.Size = UDim2.new(0, 95, 0, 42)
JumpInput.Position = UDim2.new(1, -108, 0, 98)
JumpInput.BackgroundTransparency = 1
JumpInput.TextColor3 = Color3.fromRGB(255, 255, 255)
JumpInput.PlaceholderText = "50"
JumpInput.PlaceholderColor3 = Color3.fromRGB(180, 180, 200)
JumpInput.Text = tostring(Humanoid.JumpPower)
JumpInput.Font = Enum.Font.GothamBlack
JumpInput.TextSize = 22
JumpInput.ClearTextOnFocus = false
JumpInput.ZIndex = 6
JumpInput.Parent = OtherSection
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

-- ============================================================
-- MENU TOGGLE
-- ============================================================
local guiOpen = false
MenuToggle.MouseButton1Click:Connect(function()
    guiOpen = not guiOpen
    MainFrame.Visible = guiOpen
end)

-- ============================================================
-- RESPAWN
-- ============================================================
LocalPlayer.CharacterAdded:Connect(function(c)
    Character = c; Humanoid = c:WaitForChild("Humanoid")
    WalkInput.Text = tostring(Humanoid.WalkSpeed)
    JumpInput.Text = tostring(Humanoid.JumpPower)
    desyncOn = false; animsOff = false; savedTracks = {}
    DesyncBtn.Image = loadImage("desyncOff")
    AnimBtn.Image = loadImage("animOff")
end)

print("[Tsurla Hub] Loaded!")
