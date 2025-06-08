-- KillTracker Addon for WoW 1.12
-- Tracks monster kills by zone with collapsible UI

local KillTracker = {}
KillTracker.frame = nil
KillTracker.data = {}
KillTracker.expandedZones = {}
KillTracker.lastXP = 0
KillTracker.pendingXPGain = 0
KillTracker.debugMode = false
KillTracker.recentTarget = nil -- Store recent target even after it dies
KillTracker.recentTargetTime = 0
KillTracker.minimapButton = nil

-- Create event frame first
local eventFrame = CreateFrame("Frame", "KillTrackerEventFrame")

-- Initialize saved variables
function KillTracker:OnLoad()
    -- Register events on our event frame
    eventFrame:RegisterEvent("ADDON_LOADED")
    eventFrame:RegisterEvent("PLAYER_TARGET_CHANGED")
    eventFrame:RegisterEvent("PLAYER_ENTERING_WORLD")
    
    -- Create slash command
    SLASH_KILLTRACKER1 = "/killtracker"
    SLASH_KILLTRACKER2 = "/kt"
    SlashCmdList["KILLTRACKER"] = function(msg)
        if msg == "debug" then
            KillTracker.debugMode = not KillTracker.debugMode
            local status = KillTracker.debugMode and "enabled" or "disabled"
            DEFAULT_CHAT_FRAME:AddMessage("KillTracker Debug Mode: " .. status, 1, 0.5, 0)
        elseif msg == "reload" then
            KillTracker:ReloadUI()
        else
            KillTracker:ToggleFrame()
        end
    end
end

-- Reload the UI
function KillTracker:ReloadUI()
    if KillTracker.frame then
        KillTracker.frame:Hide()
        KillTracker.frame = nil
        KillTracker.scrollFrame = nil
        KillTracker.contentFrame = nil
    end
    if KillTracker.minimapButton then
        KillTracker.minimapButton:Hide()
        KillTracker.minimapButton = nil
    end
    KillTracker:CreateFrame()
    KillTracker:CreateMinimapButton()
    DEFAULT_CHAT_FRAME:AddMessage("KillTracker UI reloaded!", 0, 1, 0)
end

-- Event handler
function KillTracker:OnEvent(event, arg1)
    if event == "ADDON_LOADED" and arg1 == "KillTracker" then
        -- Load saved data
        if not KillTrackerDB then
            KillTrackerDB = {}
        end
        KillTracker.data = KillTrackerDB
        
        DEFAULT_CHAT_FRAME:AddMessage("KillTracker loaded! Use /killtracker or /kt to open. Use /kt debug to toggle debug mode. Click minimap icon to toggle!", 0, 1, 0)
        
    elseif event == "PLAYER_ENTERING_WORLD" then
        -- Initialize UI after entering world
        if not KillTracker.frame then
            KillTracker:CreateFrame()
        end
        
        -- Create minimap button
        if not KillTracker.minimapButton then
            KillTracker:CreateMinimapButton()
        end
        
        -- Initialize XP tracking
        KillTracker.lastXP = UnitXP("player")
        if KillTracker.debugMode then
            DEFAULT_CHAT_FRAME:AddMessage("DEBUG: Initial XP set to " .. KillTracker.lastXP, 0.5, 0.5, 1)
        end
        
        -- Start monitoring combat
        KillTracker:StartCombatMonitoring()
        
    elseif event == "PLAYER_TARGET_CHANGED" then
        -- Store current target for kill tracking
        if UnitExists("target") and UnitCanAttack("player", "target") and not UnitIsPlayer("target") then
            KillTracker.currentTarget = UnitName("target")
            KillTracker.targetWasAlive = not UnitIsDead("target")
            -- Also store as recent target
            KillTracker.recentTarget = KillTracker.currentTarget
            KillTracker.recentTargetTime = GetTime()
            if KillTracker.debugMode then
                DEFAULT_CHAT_FRAME:AddMessage("DEBUG: Target changed to " .. KillTracker.currentTarget .. " (alive: " .. tostring(KillTracker.targetWasAlive) .. ")", 0.5, 0.5, 1)
            end
        else
            if KillTracker.debugMode and KillTracker.currentTarget then
                DEFAULT_CHAT_FRAME:AddMessage("DEBUG: Target cleared from " .. (KillTracker.currentTarget or "nil"), 0.5, 0.5, 1)
            end
            -- Don't clear recent target immediately - keep it for a few seconds
            if KillTracker.currentTarget then
                KillTracker.recentTarget = KillTracker.currentTarget
                KillTracker.recentTargetTime = GetTime()
            end
            KillTracker.currentTarget = nil
            KillTracker.targetWasAlive = false
        end
        
    elseif event == "PLAYER_REGEN_DISABLED" then
        -- Entering combat
        KillTracker.recentCombat = true
        if KillTracker.debugMode then
            DEFAULT_CHAT_FRAME:AddMessage("DEBUG: Entering combat", 0.5, 0.5, 1)
        end
        
    elseif event == "PLAYER_REGEN_ENABLED" then
        -- Leaving combat - check for kills
        if KillTracker.debugMode then
            DEFAULT_CHAT_FRAME:AddMessage("DEBUG: Leaving combat, checking for kills", 0.5, 0.5, 1)
        end
        KillTracker:CheckForKill()
        -- Clear combat flag after a delay
        KillTracker.combatEndTime = GetTime()
        
    elseif event == "PLAYER_XP_UPDATE" or event == "CHAT_MSG_COMBAT_XP_GAIN" then
        -- XP gained, calculate the amount and likely from a kill
        local currentXP = UnitXP("player")
        local xpGained = currentXP - KillTracker.lastXP
        
        if KillTracker.debugMode then
            DEFAULT_CHAT_FRAME:AddMessage("DEBUG: XP Event - Previous: " .. KillTracker.lastXP .. ", Current: " .. currentXP .. ", Gained: " .. xpGained, 0.5, 0.5, 1)
        end
        
        -- Handle XP rollover at level up
        if xpGained < 0 then
            local maxXP = UnitXPMax("player")
            local oldGained = xpGained
            xpGained = (maxXP - KillTracker.lastXP) + currentXP
            if KillTracker.debugMode then
                DEFAULT_CHAT_FRAME:AddMessage("DEBUG: Level up detected! Adjusted XP from " .. oldGained .. " to " .. xpGained, 0.5, 0.5, 1)
            end
        end
        
        KillTracker.lastXP = currentXP
        KillTracker.pendingXPGain = xpGained
        
        if KillTracker.debugMode then
            DEFAULT_CHAT_FRAME:AddMessage("DEBUG: Target info - Current: " .. (KillTracker.currentTarget or "nil") .. ", Recent: " .. (KillTracker.recentTarget or "nil") .. ", WasAlive: " .. tostring(KillTracker.targetWasAlive) .. ", XP > 0: " .. tostring(xpGained > 0), 0.5, 0.5, 1)
        end
        
        -- Check if we can attribute this XP gain to a recent kill
        local targetToRecord = nil
        if KillTracker.currentTarget and KillTracker.targetWasAlive and xpGained > 0 then
            targetToRecord = KillTracker.currentTarget
        elseif KillTracker.recentTarget and xpGained > 0 and (GetTime() - KillTracker.recentTargetTime) < 3 then
            -- Use recent target if XP gained within 3 seconds of losing target
            targetToRecord = KillTracker.recentTarget
            if KillTracker.debugMode then
                DEFAULT_CHAT_FRAME:AddMessage("DEBUG: Using recent target " .. targetToRecord .. " (time since lost: " .. string.format("%.1f", GetTime() - KillTracker.recentTargetTime) .. "s)", 0.5, 0.5, 1)
            end
        end
        
        if targetToRecord then
            local mobName = targetToRecord
            local zoneName = GetZoneText()
            
            if KillTracker.debugMode then
                DEFAULT_CHAT_FRAME:AddMessage("DEBUG: Recording kill - Mob: " .. mobName .. ", Zone: " .. zoneName .. ", XP: " .. xpGained, 0.5, 0.5, 1)
            end
            
            if mobName and zoneName and zoneName ~= "" then
                KillTracker:RecordKill(mobName, zoneName, xpGained)
                KillTracker.currentTarget = nil
                KillTracker.targetWasAlive = false
                -- Clear recent target after successful recording
                KillTracker.recentTarget = nil
            end
        elseif KillTracker.debugMode and xpGained > 0 then
            DEFAULT_CHAT_FRAME:AddMessage("DEBUG: XP gained but not recording - no valid target (current: " .. tostring(KillTracker.currentTarget ~= nil) .. ", recent: " .. tostring(KillTracker.recentTarget ~= nil) .. ", time: " .. (KillTracker.recentTarget and string.format("%.1f", GetTime() - KillTracker.recentTargetTime) or "n/a") .. ")", 0.5, 0.5, 1)
        end
        
        -- Clear recent combat flag after 3 seconds
        if KillTracker.combatEndTime and GetTime() - KillTracker.combatEndTime > 3 then
            KillTracker.recentCombat = false
        end
    end
end

-- Start monitoring for kills using multiple methods
function KillTracker:StartCombatMonitoring()
    -- Register additional events for better kill detection
    eventFrame:RegisterEvent("PLAYER_REGEN_DISABLED") -- Entering combat
    eventFrame:RegisterEvent("PLAYER_REGEN_ENABLED")  -- Leaving combat
    eventFrame:RegisterEvent("PLAYER_XP_UPDATE")      -- XP gain
    eventFrame:RegisterEvent("CHAT_MSG_COMBAT_XP_GAIN") -- XP messages
    
    -- Also use OnUpdate as backup
    if not KillTracker.monitorFrame then
        KillTracker.monitorFrame = CreateFrame("Frame")
        KillTracker.lastUpdateTime = 0
        KillTracker.monitorFrame:SetScript("OnUpdate", function()
            local currentTime = GetTime()
            if currentTime - KillTracker.lastUpdateTime > 0.1 then -- Check every 0.1 seconds
                KillTracker:CheckForKill()
                KillTracker.lastUpdateTime = currentTime
            end
        end)
    end
end

-- Check if we killed something
function KillTracker:CheckForKill()
    if KillTracker.currentTarget and KillTracker.targetWasAlive then
        if UnitExists("target") then
            if UnitIsDead("target") and not UnitIsPlayer("target") then
                local mobName = KillTracker.currentTarget
                local zoneName = GetZoneText()
                
                if KillTracker.debugMode then
                    DEFAULT_CHAT_FRAME:AddMessage("DEBUG: OnUpdate detected kill - Mob: " .. mobName .. ", Zone: " .. zoneName .. ", PendingXP: " .. (KillTracker.pendingXPGain or 0), 0.5, 0.5, 1)
                end
                
                if mobName and zoneName and zoneName ~= "" then
                    KillTracker:RecordKill(mobName, zoneName, KillTracker.pendingXPGain or 0)
                    KillTracker.currentTarget = nil
                    KillTracker.targetWasAlive = false
                end
            end
        else
            -- Target no longer exists, might have been killed
            if KillTracker.currentTarget then
                local mobName = KillTracker.currentTarget
                local zoneName = GetZoneText()
                
                if KillTracker.debugMode then
                    DEFAULT_CHAT_FRAME:AddMessage("DEBUG: Target disappeared - Mob: " .. mobName .. ", RecentCombat: " .. tostring(KillTracker.recentCombat), 0.5, 0.5, 1)
                end
                
                if mobName and zoneName and zoneName ~= "" then
                    -- Only record if we were recently in combat
                    if KillTracker.recentCombat then
                        KillTracker:RecordKill(mobName, zoneName, KillTracker.pendingXPGain or 0)
                    end
                end
                KillTracker.currentTarget = nil
                KillTracker.targetWasAlive = false
            end
        end
    end
end

-- Record a kill
function KillTracker:RecordKill(mobName, zoneName, xpGained)
    xpGained = xpGained or 0
    
    if KillTracker.debugMode then
        DEFAULT_CHAT_FRAME:AddMessage("DEBUG: RecordKill called - Mob: " .. (mobName or "nil") .. ", Zone: " .. (zoneName or "nil") .. ", XP: " .. xpGained, 1, 0, 1)
    end
    
    if not KillTracker.data[zoneName] then
        KillTracker.data[zoneName] = {}
        if KillTracker.debugMode then
            DEFAULT_CHAT_FRAME:AddMessage("DEBUG: Created new zone entry for " .. zoneName, 1, 0, 1)
        end
    end
    
    if not KillTracker.data[zoneName][mobName] then
        KillTracker.data[zoneName][mobName] = {
            kills = 0,
            totalXP = 0
        }
        if KillTracker.debugMode then
            DEFAULT_CHAT_FRAME:AddMessage("DEBUG: Created new mob entry for " .. mobName, 1, 0, 1)
        end
    end
    
    local oldKills = KillTracker.data[zoneName][mobName].kills
    local oldXP = KillTracker.data[zoneName][mobName].totalXP
    
    KillTracker.data[zoneName][mobName].kills = KillTracker.data[zoneName][mobName].kills + 1
    KillTracker.data[zoneName][mobName].totalXP = KillTracker.data[zoneName][mobName].totalXP + xpGained
    
    if KillTracker.debugMode then
        DEFAULT_CHAT_FRAME:AddMessage("DEBUG: Updated data - Kills: " .. oldKills .. " -> " .. KillTracker.data[zoneName][mobName].kills .. ", XP: " .. oldXP .. " -> " .. KillTracker.data[zoneName][mobName].totalXP, 1, 0, 1)
    end
    
    -- Print kill notification with XP
    local killCount = KillTracker.data[zoneName][mobName].kills
    local totalXP = KillTracker.data[zoneName][mobName].totalXP
    local avgXP = 0
    if killCount > 0 then
        avgXP = totalXP / killCount
    end
    
    DEFAULT_CHAT_FRAME:AddMessage("KillTracker: " .. mobName .. " killed in " .. zoneName .. " (Kills: " .. killCount .. ", XP: +" .. xpGained .. ", Avg: " .. string.format("%.1f", avgXP) .. ")", 1, 1, 0)
    
    -- Update UI if it's open
    if KillTracker.frame and KillTracker.frame:IsVisible() then
        if KillTracker.debugMode then
            DEFAULT_CHAT_FRAME:AddMessage("DEBUG: Updating UI display", 1, 0, 1)
        end
        KillTracker:UpdateDisplay()
    end
    
    -- Save data
    KillTrackerDB = KillTracker.data
    if KillTracker.debugMode then
        DEFAULT_CHAT_FRAME:AddMessage("DEBUG: Saved data to KillTrackerDB", 1, 0, 1)
    end
    
    -- Clear target tracking
    KillTracker.currentTarget = nil
    KillTracker.targetWasAlive = false
    KillTracker.pendingXPGain = 0
end

-- Create minimap button
function KillTracker:CreateMinimapButton()
    local button = CreateFrame("Button", "KillTrackerMinimapButton", Minimap)
    button:SetWidth(20)  -- CHANGED: Reduced from 32 to 20
    button:SetHeight(20) -- CHANGED: Reduced from 32 to 20
    button:SetFrameStrata("MEDIUM")
    button:SetFrameLevel(8)
    
    -- Set button textures
    button:SetNormalTexture("Interface\\Icons\\INV_Misc_Book_09")
    button:SetPushedTexture("Interface\\Icons\\INV_Misc_Book_09")
    button:SetHighlightTexture("Interface\\Minimap\\UI-Minimap-ZoomButton-Highlight")
    
    -- CHANGED: Make the textures fit the smaller button with texture cropping
    local normalTexture = button:GetNormalTexture()
    if normalTexture then
        normalTexture:SetTexCoord(0.1, 0.9, 0.1, 0.9) -- Crop edges for cleaner look
    end

    local pushedTexture = button:GetPushedTexture()
    if pushedTexture then
        pushedTexture:SetTexCoord(0.1, 0.9, 0.1, 0.9)
    end
    
    -- CHANGED: Position on minimap edge instead of corner (45 degrees - top-right)
    local angle = math.rad(30)
    local x = math.cos(angle) * 80
    local y = math.sin(angle) * 80
    button:SetPoint("CENTER", "Minimap", "CENTER", x, y)
    
    -- Make it draggable around the minimap
    button:EnableMouse(true)
    button:SetMovable(true)
    button:RegisterForDrag("LeftButton")
    
    local isDragging = false
    
    button:SetScript("OnDragStart", function()
        isDragging = true
        this:SetScript("OnUpdate", KillTracker.UpdateMinimapButtonPosition)
    end)
    
    button:SetScript("OnDragStop", function()
        isDragging = false
        this:SetScript("OnUpdate", nil)
    end)
    
    -- Click handler
    button:SetScript("OnClick", function()
        if not isDragging then
            KillTracker:ToggleFrame()
        end
    end)
    
    -- Tooltip
    button:SetScript("OnEnter", function()
        GameTooltip:SetOwner(this, "ANCHOR_LEFT")
        GameTooltip:SetText("Kill Tracker", 1, 1, 1)
        GameTooltip:AddLine("Left-click: Open/Close tracker", 0.8, 0.8, 0.8)
        GameTooltip:AddLine("Drag: Move button around minimap", 0.8, 0.8, 0.8)
        GameTooltip:Show()
    end)
    
    button:SetScript("OnLeave", function()
        GameTooltip:Hide()
    end)
    
    KillTracker.minimapButton = button
end

-- Update minimap button position when dragging
function KillTracker.UpdateMinimapButtonPosition()
    local button = KillTracker.minimapButton
    if not button then return end
    
    local mx, my = Minimap:GetCenter()
    local px, py = GetCursorPosition()
    local scale = UIParent:GetEffectiveScale()
    
    px, py = px / scale, py / scale
    
    local angle = math.atan2(py - my, px - mx)
    local x = math.cos(angle) * 80 -- Distance from center
    local y = math.sin(angle) * 80
    
    button:ClearAllPoints()
    button:SetPoint("CENTER", "Minimap", "CENTER", x, y)
end

function KillTracker:CreateFrame()
    -- Destroy old frame if it exists
    if KillTracker.frame then
        KillTracker.frame:Hide()
        KillTracker.frame = nil
    end
    
    local frame = CreateFrame("Frame", "KillTrackerFrame", UIParent)
    frame:SetWidth(400)
    frame:SetHeight(500)
    frame:SetPoint("CENTER", "UIParent", "CENTER", 0, 0)
    frame:SetBackdrop({
        bgFile = "Interface\\DialogFrame\\UI-DialogBox-Background",
        edgeFile = "Interface\\DialogFrame\\UI-DialogBox-Border",
        tile = true,
        tileSize = 32,
        edgeSize = 32,
        insets = { left = 11, right = 12, top = 12, bottom = 11 }
    })
    frame:SetBackdropColor(0, 0, 0, 1)
    frame:EnableMouse(true)
    frame:SetMovable(true)
    frame:RegisterForDrag("LeftButton")
    frame:SetScript("OnDragStart", function()
        this:StartMoving()
    end)
    frame:SetScript("OnDragStop", function()
        this:StopMovingOrSizing()
    end)
    frame:Hide()
    
    -- Title
    local title = frame:CreateFontString(nil, "OVERLAY", "GameFontNormalLarge")
    title:SetPoint("TOP", frame, "TOP", 0, -15)
    title:SetText("Kill Tracker")
    
    -- Close button (top right)
    local closeButton = CreateFrame("Button", nil, frame, "UIPanelCloseButton")
    closeButton:SetPoint("TOPRIGHT", frame, "TOPRIGHT", -5, -5)
    
    -- Clear button (bottom left) - MOVED FROM TOP RIGHT
    local clearButton = CreateFrame("Button", nil, frame, "UIPanelButtonTemplate")
    clearButton:SetWidth(60)
    clearButton:SetHeight(22)
    clearButton:SetPoint("BOTTOMLEFT", frame, "BOTTOMLEFT", 15, 10)
    clearButton:SetText("Clear")
    clearButton:SetScript("OnClick", function()
        KillTracker:ClearData()
    end)
    
    -- Resize button (bottom right corner)
    local resizeButton = CreateFrame("Button", nil, frame)
    resizeButton:SetWidth(16)
    resizeButton:SetHeight(16)
    resizeButton:SetPoint("BOTTOMRIGHT", frame, "BOTTOMRIGHT", -8, 8)
    resizeButton:SetHighlightTexture("Interface\\Buttons\\UI-Panel-MinimizeButton-Highlight")
    resizeButton:EnableMouse(true)
    resizeButton:RegisterForDrag("LeftButton")
    
    -- Simple resize texture (using a standard button texture)
    resizeButton:SetNormalTexture("Interface\\Buttons\\UI-SpellbookIcon-NextPage-Up")
    
    -- Resize functionality
    local isResizing = false
    local startMouseX, startMouseY, startWidth, startHeight
    
    resizeButton:SetScript("OnDragStart", function()
        isResizing = true
        startMouseX, startMouseY = GetCursorPosition()
        startWidth = frame:GetWidth()
        startHeight = frame:GetHeight()
        
        -- Set up resize update
        frame:SetScript("OnUpdate", function()
            if isResizing then
                local mouseX, mouseY = GetCursorPosition()
                local deltaX = mouseX - startMouseX
                local deltaY = startMouseY - mouseY -- Invert Y
                
                local newWidth = math.max(300, math.min(800, startWidth + deltaX))
                local newHeight = math.max(250, math.min(800, startHeight + deltaY))
                
                frame:SetWidth(newWidth)
                frame:SetHeight(newHeight)
            end
        end)
    end)
    
    resizeButton:SetScript("OnDragStop", function()
        isResizing = false
        frame:SetScript("OnUpdate", nil)
        KillTracker:UpdateScrollFrameSize()
    end)
    
    -- Scroll frame - leave space for clear button at bottom
    local scrollFrame = CreateFrame("ScrollFrame", "KillTrackerScrollFrame", frame, "UIPanelScrollFrameTemplate")
    scrollFrame:SetPoint("TOPLEFT", frame, "TOPLEFT", 20, -40)
    scrollFrame:SetPoint("BOTTOMRIGHT", frame, "BOTTOMRIGHT", -40, 40) -- Space for clear button
    
    -- Content frame
    local contentFrame = CreateFrame("Frame", "KillTrackerContentFrame", scrollFrame)
    contentFrame:SetWidth(320)
    contentFrame:SetHeight(1)
    scrollFrame:SetScrollChild(contentFrame)
    
    KillTracker.frame = frame
    KillTracker.scrollFrame = scrollFrame
    KillTracker.contentFrame = contentFrame
    KillTracker.resizeButton = resizeButton
    KillTracker.clearButton = clearButton
end

-- Clear all data
function KillTracker:ClearData()
    KillTracker.data = {}
    KillTrackerDB = {}
    KillTracker:UpdateDisplay()
    DEFAULT_CHAT_FRAME:AddMessage("KillTracker: All data cleared!", 1, 0.5, 0.5)
end

-- Update scroll frame size when window is resized
function KillTracker:UpdateScrollFrameSize()
    if KillTracker.scrollFrame and KillTracker.contentFrame then
        -- Update content frame width to match new scroll frame width
        local scrollWidth = KillTracker.scrollFrame:GetWidth()
        if scrollWidth and scrollWidth > 0 then
            KillTracker.contentFrame:SetWidth(scrollWidth - 20) -- Account for scroll bar
            
            -- Refresh display to reposition elements
            if KillTracker.frame and KillTracker.frame:IsVisible() then
                KillTracker:UpdateDisplay()
            end
        end
    end
end

-- Update the display
function KillTracker:UpdateDisplay()
    if not KillTracker.contentFrame then
        return
    end
    
    -- Clear existing content completely
    local children = {KillTracker.contentFrame:GetChildren()}
    for i = 1, table.getn(children) do
        children[i]:Hide()
        children[i]:SetParent(nil)
    end
    
    -- Clear all font strings too
    local regions = {KillTracker.contentFrame:GetRegions()}
    for i = 1, table.getn(regions) do
        if regions[i]:GetObjectType() == "FontString" then
            regions[i]:Hide()
            regions[i]:SetParent(nil)
        end
    end
    
    local yOffset = 0
    local totalHeight = 0
    
    -- Check if we have any data
    local hasData = false
    for _ in pairs(KillTracker.data) do
        hasData = true
        break
    end
    
    if not hasData then
        local noDataText = KillTracker.contentFrame:CreateFontString(nil, "OVERLAY", "GameFontNormal")
        noDataText:SetPoint("TOP", KillTracker.contentFrame, "TOP", 0, -20)
        noDataText:SetText("No kills recorded yet.")
        noDataText:SetTextColor(0.7, 0.7, 0.7)
        KillTracker.contentFrame:SetHeight(50)
        return
    end
    
    -- Sort zones alphabetically
    local sortedZones = {}
    for zoneName in pairs(KillTracker.data) do
        table.insert(sortedZones, zoneName)
    end
    table.sort(sortedZones)
    
    -- Create zone headers and mob lists
    for i = 1, table.getn(sortedZones) do
        local zoneName = sortedZones[i]
        local zoneData = KillTracker.data[zoneName]
        
        -- Calculate total kills and XP for this zone
        local totalKills = 0
        local totalXP = 0
        for mobName, mobData in pairs(zoneData) do
            -- Handle old data format (numbers) and new data format (tables)
            if type(mobData) == "number" then
                totalKills = totalKills + mobData
                -- Convert old format to new format
                KillTracker.data[zoneName][mobName] = {
                    kills = mobData,
                    totalXP = 0
                }
            else
                totalKills = totalKills + mobData.kills
                totalXP = totalXP + mobData.totalXP
            end
        end
        
        -- Zone header button
        local zoneButton = CreateFrame("Button", "KillTrackerZone"..i, KillTracker.contentFrame)
        zoneButton:SetWidth(20)
        zoneButton:SetHeight(20)
        zoneButton:SetPoint("TOPLEFT", KillTracker.contentFrame, "TOPLEFT", 0, -yOffset)
        
        -- Set button texture based on expanded state
        if KillTracker.expandedZones[zoneName] then
            zoneButton:SetNormalTexture("Interface\\Buttons\\UI-MinusButton-Up")
        else
            zoneButton:SetNormalTexture("Interface\\Buttons\\UI-PlusButton-Up")
        end
        zoneButton:SetHighlightTexture("Interface\\Buttons\\UI-PlusButton-Hilight")
        
        -- Zone text
        local zoneText = zoneButton:CreateFontString(nil, "OVERLAY", "GameFontNormal")
        zoneText:SetPoint("LEFT", zoneButton, "RIGHT", 5, 0)
        zoneText:SetText(zoneName .. " (" .. totalKills .. " kills, " .. totalXP .. " XP)")
        
        -- Store zone name for the button click
        zoneButton.zoneName = zoneName
        
        -- Toggle zone expansion
        zoneButton:SetScript("OnClick", function()
            local zone = this.zoneName
            KillTracker.expandedZones[zone] = not KillTracker.expandedZones[zone]
            KillTracker:UpdateDisplay()
        end)
        
        yOffset = yOffset + 25
        totalHeight = totalHeight + 25
        
        -- Show mob details if zone is expanded
        if KillTracker.expandedZones[zoneName] then
            -- Sort mobs by kill count (descending)
            local sortedMobs = {}
            for mobName, mobData in pairs(zoneData) do
                -- Handle both old and new data formats
                if type(mobData) == "number" then
                    table.insert(sortedMobs, {name = mobName, kills = mobData, totalXP = 0})
                else
                    table.insert(sortedMobs, {name = mobName, kills = mobData.kills, totalXP = mobData.totalXP})
                end
            end
            table.sort(sortedMobs, function(a, b) return a.kills > b.kills end)
            
            -- Display each mob
            for j = 1, table.getn(sortedMobs) do
                local mobData = sortedMobs[j]
                local avgXP = 0
                if mobData.kills > 0 then
                    avgXP = mobData.totalXP / mobData.kills
                end
                
                local mobText = KillTracker.contentFrame:CreateFontString(nil, "OVERLAY", "GameFontNormalSmall")
                mobText:SetPoint("TOPLEFT", KillTracker.contentFrame, "TOPLEFT", 25, -yOffset)
                mobText:SetText(mobData.name .. ": " .. mobData.kills .. " kills, " .. mobData.totalXP .. " XP (avg: " .. string.format("%.1f", avgXP) .. ")")
                mobText:SetTextColor(0.8, 0.8, 0.8)
                
                yOffset = yOffset + 15
                totalHeight = totalHeight + 15
            end
            
            yOffset = yOffset + 5 -- Add some spacing after expanded zone
            totalHeight = totalHeight + 5
        end
    end
    
    -- Update content frame height
    KillTracker.contentFrame:SetHeight(math.max(totalHeight, 1))
end

-- Toggle frame visibility
function KillTracker:ToggleFrame()
    if not KillTracker.frame then
        KillTracker:CreateFrame()
    end
    
    if KillTracker.frame:IsVisible() then
        KillTracker.frame:Hide()
    else
        KillTracker:UpdateDisplay()
        KillTracker.frame:Show()
    end
end

-- Set up event handling
eventFrame:SetScript("OnEvent", function()
    KillTracker:OnEvent(event, arg1)
end)

-- Initialize the addon
KillTracker:OnLoad()