-- Tsurla Hub - Brawl Stars Style GUI
-- Functionality coming later, GUI only

local Players = game:GetService("Players")
local UserInputService = game:GetService("UserInputService")
local TweenService = game:GetService("TweenService")
local LocalPlayer = Players.LocalPlayer

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

-- Preload images
local imageNames = {"background","main","menu","walkspeed","jumppower","other","desyncOn","desyncOff","animOn","animOff"}
for _, name in ipairs(imageNames) do
    task.spawn(function() loadImage(name) end)
end
task.wait(2)

-- Remove old
pcall(function()
    if LocalPlayer.PlayerGui:FindFirstChild("TsurlaHub") then
        LocalPlayer.PlayerGui.TsurlaHub:Destroy()
    end
end)

-- ============================================================
-- SCREEN GUI
-- ============================================================
local ScreenGui = Instance.new("ScreenGui")
ScreenGui.Name = "TsurlaHub"
ScreenGui.ResetOnSpawn = false
ScreenGui.DisplayOrder = 999
ScreenGui.Parent = LocalPlayer.PlayerGui

-- ============================================================
-- MAIN FRAME - Brawl Stars dark panel
-- ============================================================
local MainFrame = Instance.new("Frame")
MainFrame.Name = "MainFrame"
MainFrame.Size = UDim2.new(0, 480, 0, 440)
MainFrame.Position = UDim2.new(0.5, -240, 0.5, -220)
MainFrame.BackgroundColor3 = Color3.fromRGB(20, 22, 35)
MainFrame.BorderSizePixel = 0
MainFrame.Parent = ScreenGui

local MainCorner = Instance.new("UICorner")
MainCorner.CornerRadius = UDim.new(0, 18)
MainCorner.Parent = MainFrame

-- Outer glow border
local Stroke = Instance.new("UIStroke")
Stroke.Color = Color3.fromRGB(80, 90, 140)
Stroke.Thickness = 2.5
Stroke.Parent = MainFrame

-- Inner top accent bar (BS style orange/yellow top)
local TopBar = Instance.new("Frame")
TopBar.Size = UDim2.new(1, 0, 0, 52)
TopBar.Position = UDim2.new(0, 0, 0, 0)
TopBar.BackgroundColor3 = Color3.fromRGB(35, 38, 58)
TopBar.BorderSizePixel = 0
TopBar.ZIndex = 2
TopBar.Parent = MainFrame
Instance.new("UICorner", TopBar).CornerRadius = UDim.new(0, 18)

-- TopBar bottom fill fix
local TopBarFix = Instance.new("Frame")
TopBarFix.Size = UDim2.new(1, 0, 0, 18)
TopBarFix.Position = UDim2.new(0, 0, 1, -18)
TopBarFix.BackgroundColor3 = Color3.fromRGB(35, 38, 58)
TopBarFix.BorderSizePixel = 0
TopBarFix.ZIndex = 2
TopBarFix.Parent = TopBar

-- Orange accent line under topbar
local AccentLine = Instance.new("Frame")
AccentLine.Size = UDim2.new(1, -30, 0, 3)
AccentLine.Position = UDim2.new(0, 15, 0, 50)
AccentLine.BackgroundColor3 = Color3.fromRGB(255, 165, 0)
AccentLine.BorderSizePixel = 0
AccentLine.ZIndex = 3
AccentLine.Parent = MainFrame
Instance.new("UICorner", AccentLine).CornerRadius = UDim.new(1, 0)

-- Title
local Title = Instance.new("TextLabel")
Title.Size = UDim2.new(1, -90, 1, 0)
Title.Position = UDim2.new(0, 15, 0, 0)
Title.BackgroundTransparency = 1
Title.Text = "Tsurla Hub"
Title.TextColor3 = Color3.fromRGB(255, 255, 255)
Title.Font = Enum.Font.GothamBlack
Title.TextSize = 22
Title.TextXAlignment = Enum.TextXAlignment.Left
Title.ZIndex = 3
Title.Parent = TopBar

-- Subtitle
local SubTitle = Instance.new("TextLabel")
SubTitle.Size = UDim2.new(1, -90, 0, 16)
SubTitle.Position = UDim2.new(0, 15, 0, 30)
SubTitle.BackgroundTransparency = 1
SubTitle.Text = "t.me/tsurla"
SubTitle.TextColor3 = Color3.fromRGB(140, 150, 200)
SubTitle.Font = Enum.Font.Gotham
SubTitle.TextSize = 12
SubTitle.TextXAlignment = Enum.TextXAlignment.Left
SubTitle.ZIndex = 3
SubTitle.Parent = TopBar

-- Close Button (BS style - red circle with X)
local CloseBtn = Instance.new("TextButton")
CloseBtn.Size = UDim2.new(0, 36, 0, 36)
CloseBtn.Position = UDim2.new(1, -44, 0, 8)
CloseBtn.BackgroundColor3 = Color3.fromRGB(220, 60, 60)
CloseBtn.TextColor3 = Color3.fromRGB(255, 255, 255)
CloseBtn.Text = "✕"
CloseBtn.Font = Enum.Font.GothamBlack
CloseBtn.TextSize = 18
CloseBtn.ZIndex = 10
CloseBtn.Parent = MainFrame
Instance.new("UICorner", CloseBtn).CornerRadius = UDim.new(1, 0)

local CloseStroke = Instance.new("UIStroke")
CloseStroke.Color = Color3.fromRGB(255, 100, 100)
CloseStroke.Thickness = 2
CloseStroke.Parent = CloseBtn

CloseBtn.MouseButton1Click:Connect(function()
    TweenService:Create(MainFrame, TweenInfo.new(0.2), {Size = UDim2.new(0,0,0,0), Position = UDim2.new(0.5,0,0.5,0)}):Play()
    task.wait(0.2)
    ScreenGui:Destroy()
end)

-- ============================================================
-- DRAG
-- ============================================================
local dragging, dragInput, dragStart, startPos
TopBar.InputBegan:Connect(function(input)
    if input.UserInputType == Enum.UserInputType.MouseButton1 or input.UserInputType == Enum.UserInputType.Touch then
        dragging = true
        dragStart = input.Position
        startPos = MainFrame.Position
        input.Changed:Connect(function()
            if input.UserInputState == Enum.UserInputState.End then dragging = false end
        end)
    end
end)
TopBar.InputChanged:Connect(function(input)
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
-- TAB BAR
-- ============================================================
local TabBar = Instance.new("Frame")
TabBar.Size = UDim2.new(1, -20, 0, 42)
TabBar.Position = UDim2.new(0, 10, 0, 60)
TabBar.BackgroundColor3 = Color3.fromRGB(28, 30, 48)
TabBar.BorderSizePixel = 0
TabBar.ZIndex = 3
TabBar.Parent = MainFrame
Instance.new("UICorner", TabBar).CornerRadius = UDim.new(0, 10)

local TabLayout = Instance.new("UIListLayout")
TabLayout.FillDirection = Enum.FillDirection.Horizontal
TabLayout.SortOrder = Enum.SortOrder.LayoutOrder
TabLayout.Padding = UDim.new(0, 4)
TabLayout.VerticalAlignment = Enum.VerticalAlignment.Center
TabLayout.HorizontalAlignment = Enum.HorizontalAlignment.Center
TabLayout.Parent = TabBar

local function makeTab(labelText, order)
    local btn = Instance.new("TextButton")
    btn.Size = UDim2.new(0, 120, 0, 34)
    btn.BackgroundColor3 = Color3.fromRGB(45, 48, 72)
    btn.TextColor3 = Color3.fromRGB(180, 185, 220)
    btn.Text = labelText
    btn.Font = Enum.Font.GothamBold
    btn.TextSize = 14
    btn.ZIndex = 4
    btn.LayoutOrder = order
    btn.Parent = TabBar
    Instance.new("UICorner", btn).CornerRadius = UDim.new(0, 8)
    return btn
end

local MainTabBtn = makeTab("⚡  Main", 1)
local MenuTabBtn = makeTab("☰  Menu", 2)

-- ============================================================
-- SCROLL / CONTENT AREA
-- ============================================================
local ContentArea = Instance.new("Frame")
ContentArea.Size = UDim2.new(1, -20, 1, -120)
ContentArea.Position = UDim2.new(0, 10, 0, 112)
ContentArea.BackgroundTransparency = 1
ContentArea.ClipsDescendants = true
ContentArea.ZIndex = 3
ContentArea.Parent = MainFrame

-- MAIN CONTENT
local MainContent = Instance.new("Frame")
MainContent.Size = UDim2.new(1, 0, 1, 0)
MainContent.BackgroundTransparency = 1
MainContent.Visible = true
MainContent.ZIndex = 3
MainContent.Parent = ContentArea

local MainLayout = Instance.new("UIListLayout")
MainLayout.SortOrder = Enum.SortOrder.LayoutOrder
MainLayout.Padding = UDim.new(0, 10)
MainLayout.Parent = MainContent

-- MENU CONTENT
local MenuContent = Instance.new("Frame")
MenuContent.Size = UDim2.new(1, 0, 1, 0)
MenuContent.BackgroundTransparency = 1
MenuContent.Visible = false
MenuContent.ZIndex = 3
MenuContent.Parent = ContentArea

local MenuLayout = Instance.new("UIListLayout")
MenuLayout.SortOrder = Enum.SortOrder.LayoutOrder
MenuLayout.Padding = UDim.new(0, 10)
MenuLayout.Parent = MenuContent

-- ============================================================
-- BS STYLE ROW BUILDER
-- ============================================================
local function makeRow(parent, order)
    local row = Instance.new("Frame")
    row.Size = UDim2.new(1, 0, 0, 62)
    row.BackgroundColor3 = Color3.fromRGB(30, 33, 52)
    row.BorderSizePixel = 0
    row.ZIndex = 4
    row.LayoutOrder = order
    row.Parent = parent
    Instance.new("UICorner", row).CornerRadius = UDim.new(0, 12)
    local stroke = Instance.new("UIStroke")
    stroke.Color = Color3.fromRGB(55, 60, 90)
    stroke.Thickness = 1.5
    stroke.Parent = row
    return row
end

local function makeLabel(parent, text, posX, posY, sizeX, sizeY, size, color)
    local lbl = Instance.new("TextLabel")
    lbl.Size = UDim2.new(0, sizeX, 0, sizeY)
    lbl.Position = UDim2.new(0, posX, 0, posY)
    lbl.BackgroundTransparency = 1
    lbl.Text = text
    lbl.TextColor3 = color or Color3.fromRGB(220, 225, 255)
    lbl.Font = Enum.Font.GothamBold
    lbl.TextSize = size or 15
    lbl.TextXAlignment = Enum.TextXAlignment.Left
    lbl.ZIndex = 5
    lbl.Parent = parent
    return lbl
end

local function makeInput(parent, placeholder, posX, posY, w, h)
    local box = Instance.new("TextBox")
    box.Size = UDim2.new(0, w, 0, h)
    box.Position = UDim2.new(0, posX, 0, posY)
    box.BackgroundColor3 = Color3.fromRGB(20, 22, 38)
    box.TextColor3 = Color3.fromRGB(255, 200, 80)
    box.PlaceholderText = placeholder
    box.PlaceholderColor3 = Color3.fromRGB(100, 105, 140)
    box.Font = Enum.Font.GothamBold
    box.TextSize = 16
    box.ClearTextOnFocus = false
    box.ZIndex = 5
    box.Parent = parent
    Instance.new("UICorner", box).CornerRadius = UDim.new(0, 8)
    local s = Instance.new("UIStroke")
    s.Color = Color3.fromRGB(255, 165, 0)
    s.Thickness = 1.5
    s.Parent = box
    return box
end

local function makeToggleBtn(parent, onText, offText, posX, posY, w, h)
    local btn = Instance.new("TextButton")
    btn.Size = UDim2.new(0, w, 0, h)
    btn.Position = UDim2.new(0, posX, 0, posY)
    btn.BackgroundColor3 = Color3.fromRGB(60, 65, 100)
    btn.TextColor3 = Color3.fromRGB(255, 255, 255)
    btn.Text = offText
    btn.Font = Enum.Font.GothamBold
    btn.TextSize = 13
    btn.ZIndex = 5
    btn.Parent = parent
    Instance.new("UICorner", btn).CornerRadius = UDim.new(0, 10)
    local s = Instance.new("UIStroke")
    s.Color = Color3.fromRGB(80, 85, 130)
    s.Thickness = 1.5
    s.Parent = btn
    btn.MouseButton1Click:Connect(function()
        local on = btn:GetAttribute("On") or false
        on = not on
        btn:SetAttribute("On", on)
        if on then
            btn.BackgroundColor3 = Color3.fromRGB(50, 180, 80)
            s.Color = Color3.fromRGB(80, 220, 110)
            btn.Text = onText
        else
            btn.BackgroundColor3 = Color3.fromRGB(60, 65, 100)
            s.Color = Color3.fromRGB(80, 85, 130)
            btn.Text = offText
        end
    end)
    return btn
end

-- ============================================================
-- IMAGE LABEL ROW (uses your PNG images)
-- ============================================================
local function makeImgRow(parent, imgName, order)
    local row = makeRow(parent, order)
    local img = Instance.new("ImageLabel")
    img.Size = UDim2.new(0, 260, 0, 50)
    img.Position = UDim2.new(0, 6, 0, 6)
    img.BackgroundTransparency = 1
    img.Image = loadImage(imgName)
    img.ScaleType = Enum.ScaleType.Fit
    img.ZIndex = 5
    img.Parent = row
    return row, img
end

-- ============================================================
-- MAIN CONTENT ROWS
-- ============================================================

-- Walkspeed row
local wsRow = makeRow(MainContent, 1)
makeLabel(wsRow, "🏃  Walk Speed", 14, 10, 180, 20, 14, Color3.fromRGB(180, 185, 220))
local wsImg = Instance.new("ImageLabel")
wsImg.Size = UDim2.new(0, 180, 0, 38)
wsImg.Position = UDim2.new(0, 8, 0, 12)
wsImg.BackgroundTransparency = 1
wsImg.Image = loadImage("walkspeed")
wsImg.ScaleType = Enum.ScaleType.Fit
wsImg.ZIndex = 5
wsImg.Parent = wsRow
local WalkInput = makeInput(wsRow, "16", 300, 11, 120, 40)
WalkInput.Text = "16"

-- Jumppower row
local jpRow = makeRow(MainContent, 2)
local jpImg = Instance.new("ImageLabel")
jpImg.Size = UDim2.new(0, 180, 0, 38)
jpImg.Position = UDim2.new(0, 8, 0, 12)
jpImg.BackgroundTransparency = 1
jpImg.Image = loadImage("jumppower")
jpImg.ScaleType = Enum.ScaleType.Fit
jpImg.ZIndex = 5
jpImg.Parent = jpRow
local JumpInput = makeInput(jpRow, "50", 300, 11, 120, 40)
JumpInput.Text = "50"

-- Other row
local otRow = makeRow(MainContent, 3)
local otImg = Instance.new("ImageLabel")
otImg.Size = UDim2.new(0, 140, 0, 44)
otImg.Position = UDim2.new(0, 8, 0, 9)
otImg.BackgroundTransparency = 1
otImg.Image = loadImage("other")
otImg.ScaleType = Enum.ScaleType.Fit
otImg.ZIndex = 5
otImg.Parent = otRow

-- ============================================================
-- MENU CONTENT ROWS
-- ============================================================

-- Desync row
local dsRow = makeRow(MenuContent, 1)
local dsImg = Instance.new("ImageLabel")
dsImg.Size = UDim2.new(0, 220, 0, 44)
dsImg.Position = UDim2.new(0, 8, 0, 9)
dsImg.BackgroundTransparency = 1
dsImg.Image = loadImage("desyncOff")
dsImg.ScaleType = Enum.ScaleType.Fit
dsImg.ZIndex = 5
dsImg.Parent = dsRow
local dsToggle = makeToggleBtn(dsRow, "● ON", "● OFF", 340, 14, 90, 34)
dsToggle.MouseButton1Click:Connect(function()
    local on = dsToggle:GetAttribute("On") or false
    dsImg.Image = loadImage(on and "desyncOn" or "desyncOff")
end)

-- Anim row
local anRow = makeRow(MenuContent, 2)
local anImg = Instance.new("ImageLabel")
anImg.Size = UDim2.new(0, 260, 0, 50)
anImg.Position = UDim2.new(0, 6, 0, 6)
anImg.BackgroundTransparency = 1
anImg.Image = loadImage("animOff")
anImg.ScaleType = Enum.ScaleType.Fit
anImg.ZIndex = 5
anImg.Parent = anRow
local anToggle = makeToggleBtn(anRow, "● ON", "● OFF", 340, 14, 90, 34)
anToggle.MouseButton1Click:Connect(function()
    local on = anToggle:GetAttribute("On") or false
    anImg.Image = loadImage(on and "animOn" or "animOff")
end)

-- ============================================================
-- TAB SWITCH
-- ============================================================
local activeColor = Color3.fromRGB(255, 165, 0)
local inactiveColor = Color3.fromRGB(45, 48, 72)
local activeText = Color3.fromRGB(255, 255, 255)
local inactiveText = Color3.fromRGB(130, 135, 170)

local function switchTab(tab)
    MainContent.Visible = tab == "main"
    MenuContent.Visible = tab == "menu"
    MainTabBtn.BackgroundColor3 = tab == "main" and activeColor or inactiveColor
    MainTabBtn.TextColor3 = tab == "main" and activeText or inactiveText
    MenuTabBtn.BackgroundColor3 = tab == "menu" and activeColor or inactiveColor
    MenuTabBtn.TextColor3 = tab == "menu" and activeText or inactiveText
end

MainTabBtn.MouseButton1Click:Connect(function() switchTab("main") end)
MenuTabBtn.MouseButton1Click:Connect(function() switchTab("menu") end)
switchTab("main")

-- ============================================================
-- OPEN ANIMATION
-- ============================================================
MainFrame.Size = UDim2.new(0, 0, 0, 0)
MainFrame.Position = UDim2.new(0.5, 0, 0.5, 0)
TweenService:Create(MainFrame, TweenInfo.new(0.25, Enum.EasingStyle.Back), {
    Size = UDim2.new(0, 480, 0, 440),
    Position = UDim2.new(0.5, -240, 0.5, -220)
}):Play()

print("[Tsurla Hub] Loaded!")
