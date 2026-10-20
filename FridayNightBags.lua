local ADDON_NAME = ...
local VERSION = "0.1.41"
local addon = CreateFrame("Frame")
local db
local merchantSession = 0
local merchantOpen = false
local saleTimerSession
local saleReportedSession
local attempted = {}
local saleAttempts, saleSlotChanges, saleUnchanged = 0, 0, 0
local pendingSale
local metadataRetries, merchantRetries = 0, 0
local lastScanReasons = {}
local saleMissingAPI
local MAX_METADATA_RETRIES, MAX_MERCHANT_RETRIES = 30, 10
local diagnosticElapsed = 0
local diagnosticDuration = 0
local diagnosticProbes = 0
local MAX_DIAGNOSTIC_PROBES = 2400
local copyPanel, copyEdit, copyPages, copyPage = nil, nil, nil, 1
local copyTitle = "Bag diagnostic"
local showCopyPage
local layoutFrame, layoutBusy, layoutFailed, barCustomized
local bagVisibilityBefore = {}
local bagAnchorsBefore = {}
local barAnimation
local refreshOriginalLayout
local setBagBarExpanded
local iconHighlightSeen = false
local controllerSelectionGeneration = 0
local layoutMutating = false
local nativeLayoutHeight, nativeLayoutWidth, layoutExtraHeight
local addSlotsSizeBefore
local ITEM_SPACING = 5 -- Blizzard's combined-container grid spacing in build 70338.
local BAG_BAR_GAP = 8
-- Muted translucent colors, drawn inside each native slot border.
local BAG_SLOT_TINT = {
    [0] = { 0.35, 0.55, 1.00 }, -- backpack
    [1] = { 1.00, 0.42, 0.34 },
    [2] = { 1.00, 0.78, 0.32 },
    [3] = { 0.30, 0.82, 0.43 },
    [4] = { 0.25, 0.78, 0.85 },
    [5] = { 0.78, 0.46, 0.95 }, -- reagent bag
}
local bagSlotShades = setmetatable({}, { __mode = "k" })
local bagIconShades = setmetatable({}, { __mode = "k" })
local BAG_SLOT_SHADE_ALPHA = 0.30
local bagShadingVisible = false
local lastGamepadMode
local sortHookInstalled, sortHookAttempted = false, false
local sortProbeGeneration = 0
local sortProbe
local MAX_BLOCKED_RECORDS = 8
local navCaptureGeneration = 0

local function say(message)
    print("Friday Night Bags: " .. message)
end

local function shown(frame)
    if not frame then return false end
    local ok, value = pcall(function() return frame:IsShown() end)
    return ok and value or false
end

local function frameName(frame)
    if not frame then return "<unavailable>" end
    local ok, value = pcall(function() return frame:GetName() end)
    if not ok then return "<unavailable>" end
    return value or "<unnamed>"
end

local function objectType(frame)
    local ok, value = pcall(function() return frame:GetObjectType() end)
    return ok and value or nil
end

local function round(n)
    if type(n) ~= "number" then return nil end
    return math.floor(n * 10 + 0.5) / 10
end

local function geometry(frame)
    if not frame then return nil end
    local ok, left, top, width, height = pcall(function()
        return frame:GetLeft(), frame:GetTop(), frame:GetWidth(), frame:GetHeight()
    end)
    if not ok then return nil end
    return {
        left = round(left), top = round(top),
        width = round(width), height = round(height),
    }
end

local function slotRecord(frame, source)
    local ok, id = pcall(function() return frame:GetID() end)
    local record = { name = frameName(frame), id = ok and id or nil,
        shown = shown(frame) and true or false, box = geometry(frame), source = source }
    local bagOK, bagID = pcall(function()
        return frame.GetBagID and frame:GetBagID() or nil
    end)
    if bagOK then record.bagID = bagID end
    return record
end

local function gatherSlots(container)
    local slots = {}
    local seen = {}
    local inspected = 0
    local function add(frame, source)
        if not frame or seen[frame] or #slots >= 120 then return end
        seen[frame] = true
        local name = frameName(frame)
        if name == "<unavailable>" or not shown(frame) then return end
        slots[#slots + 1] = slotRecord(frame, source)
    end
    -- Retail-like containers publish their item buttons in Items. Keep a
    -- bounded fallback for this beta if its template uses named children.
    local itemsOK, items = pcall(function() return container.Items end)
    if itemsOK and type(items) == "table" then
        for _, item in ipairs(items) do add(item, "Items") end
    end
    if #slots == 0 then
        local function visit(parent, depth)
            if depth > 5 or #slots >= 120 or inspected >= 400 then return end
            local ok, children = pcall(function() return { parent:GetChildren() } end)
            if not ok then return end
            for _, child in ipairs(children) do
                inspected = inspected + 1
                if inspected > 400 then break end
                local name = frameName(child)
                if name ~= "<unavailable>" and shown(child) then
                    local kind = objectType(child)
                    local box = geometry(child)
                    if (kind == "Button" or kind == "CheckButton") and box and
                        box.width and box.height and box.width >= 24 and box.width <= 72 and
                        box.height >= 24 and box.height <= 72 then
                        add(child, "visible-button")
                    end
                    visit(child, depth + 1)
                end
            end
        end
        visit(container, 1)
    end
    return slots
end

local function primaryBagFrame()
    local named = _G.ContainerFrameCombinedBags
    if shown(named) then return named, true end
    -- Never enumerate UIParent children: this beta exposes forbidden frames.
    return nil, false
end

local function gamepadModeActive()
    if not InputUtil or type(InputUtil.IsGamepadUIEnabled) ~= "function" then return false end
    local ok, active = pcall(InputUtil.IsGamepadUIEnabled)
    return ok and active == true
end

local function gamepadVisualsEnabled()
    return db and db.originalGamepadLayout and gamepadModeActive() and not layoutFailed
end

local function useOriginalLayout()
    return gamepadVisualsEnabled() and
        not (InCombatLockdown and InCombatLockdown())
end

local function safeLayoutObject(object)
    if not object then return false end
    local ok, forbidden = pcall(function()
        return object.IsForbidden and object:IsForbidden()
    end)
    return ok and not forbidden
end

local function refreshBagTitle()
    local frame = layoutFrame or _G.ContainerFrameCombinedBags
    if safeLayoutObject(frame) and type(frame.UpdateName) == "function" then
        -- The native method restores the original title whenever this layout
        -- is inactive; the hook below changes only the active gamepad view.
        pcall(frame.UpdateName, frame)
    end
end

local function nativeOrder(a, b)
    -- Match ContainerFrameMixin's combined-bag sort, including its extended
    -- backpack slots. The mouse grid then runs bottom-right to top-left.
    if IsAccountSecured and not IsAccountSecured() then
        local extendedA, extendedB = a:IsExtended(), b:IsExtended()
        if extendedA ~= extendedB then return not extendedA end
    end
    local bagA, bagB = a:GetBagID(), b:GetBagID()
    if bagA ~= bagB then return bagA < bagB end
    return a:GetID() < b:GetID()
end

local function restoreBagBar()
    barAnimation = nil
    controllerSelectionGeneration = controllerSelectionGeneration + 1
    iconHighlightSeen = false
    if addSlotsSizeBefore and layoutFrame and
        safeLayoutObject(layoutFrame.AddSlotsButton) then
        layoutFrame.AddSlotsButton:SetSize(addSlotsSizeBefore[1], addSlotsSizeBefore[2])
        addSlotsSizeBefore = nil
    end
    if not barCustomized or not GamepadBagBar or not GamepadBagBar.GetBagButton then return end
    for bag = STARTING_BAG_INDEX or 0, ENDING_BAG_INDEX or 5 do
        local button = GamepadBagBar:GetBagButton(bag)
        if button and safeLayoutObject(button) and bagVisibilityBefore[bag] ~= nil then
            local shade = bagIconShades[button]
            if shade then shade:Hide() end
            local points = bagAnchorsBefore[bag]
            if points then
                button:ClearAllPoints()
                for _, point in ipairs(points) do
                    button:SetPoint(point[1], point[2], point[3], point[4], point[5])
                end
            end
            if bagVisibilityBefore[bag] then button:Show() else button:Hide() end
        end
    end
    bagVisibilityBefore = {}
    bagAnchorsBefore = {}
    barCustomized = false
end

local function shadeBagIcon(button, bag)
    if not safeLayoutObject(button) then return end
    pcall(function()
        local color = BAG_SLOT_TINT[bag]
        local shade = bagIconShades[button]
        if not color then
            if shade then shade:Hide() end
            return
        end
        if not shade then
            if InCombatLockdown and InCombatLockdown() then return end
            shade = button:CreateTexture(nil, "OVERLAY", nil, -8)
            shade:SetPoint("TOPLEFT", button, "TOPLEFT", 4, -4)
            shade:SetPoint("BOTTOMRIGHT", button, "BOTTOMRIGHT", -4, 4)
            bagIconShades[button] = shade
        end
        shade:SetColorTexture(color[1], color[2], color[3], BAG_SLOT_SHADE_ALPHA)
        shade:Show()
    end)
end

local function renderBagBar(progress)
    if not layoutFrame or not GamepadBagBar then return end
    -- Native grid navigation can retain a bag button after it is hidden.
    -- In the geometry test, keep every reachable bag control visible.
    if db and db.navLayout then progress = 1 end
    local extra = {}
    for bag = STARTING_BAG_INDEX or 0, ENDING_BAG_INDEX or 5 do
        if bag ~= 0 then
            local button = GamepadBagBar:GetBagButton(bag)
            if button then extra[#extra + 1] = button end
        end
    end
    for index, button in ipairs(extra) do
        if progress >= index / #extra then button:Show() else button:Hide() end
    end
end

local function stopBarAnimation()
    barAnimation = nil
end

local function selectedRevealedBag()
    if not SmartNavigation or not SmartNavigation.GetActiveFrame or
        SmartNavigation:GetActiveFrame() ~= layoutFrame or not GamepadBagBar then return false end
    if not SmartNavigation.GetCurrentButton then return false end
    local selected = SmartNavigation:GetCurrentButton()
    if not selected then return false end
    for bag = (STARTING_BAG_INDEX or 0) + 1, ENDING_BAG_INDEX or 5 do
        if selected == GamepadBagBar:GetBagButton(bag) then return true end
    end
    return false
end

local function startBarAnimation(from)
    if not layoutFrame or not shown(layoutFrame) or
        not useOriginalLayout() then return end
    local target = db.bagBarExpanded and 1 or 0
    if from == target then return end
    barAnimation = { start = from, target = target, elapsed = 0, progress = from }
    renderBagBar(from)
end

local function advanceBarAnimation(elapsed)
    if not barAnimation then return end
    if InCombatLockdown and InCombatLockdown() then
        stopBarAnimation()
        return
    end
    barAnimation.elapsed = barAnimation.elapsed + elapsed
    local fraction = math.min(barAnimation.elapsed / 0.18, 1)
    local eased = fraction * fraction * (3 - 2 * fraction)
    barAnimation.progress = barAnimation.start +
        (barAnimation.target - barAnimation.start) * eased
    renderBagBar(barAnimation.progress)
    if fraction >= 1 then stopBarAnimation() end
end

setBagBarExpanded = function(expanded)
    if InCombatLockdown and InCombatLockdown() then return false end
    if db and db.navLayout then
        stopBarAnimation()
        db.bagBarExpanded = true
        renderBagBar(1)
        return true
    end
    if not expanded and selectedRevealedBag() then return false end
    local from = barAnimation and barAnimation.progress or (db.bagBarExpanded and 1 or 0)
    stopBarAnimation()
    db.bagBarExpanded = expanded
    if barCustomized and shown(layoutFrame) then
        startBarAnimation(from)
    else
        refreshOriginalLayout()
    end
    return true
end

local function applyOriginalLayout(frame)
    if not useOriginalLayout() or not safeLayoutObject(frame) or
        not safeLayoutObject(frame.MoneyFrame) or type(frame.Items) ~= "table" or
        not AnchorUtil or not AnchorUtil.GridLayout or not AnchorUtil.CreateAnchor or
        not AnchorUtil.CreateGridLayout or not GridLayoutMixin or
        not GridLayoutMixin.Direction or not GamepadBagBar or
        not GamepadBagBar.GetBagButton then return false end

    local items, bagButtons = {}, {}
    for _, item in ipairs(frame.Items) do
        if not safeLayoutObject(item) then return false end
        local bag = item:GetBagID()
        local bagButton = GamepadBagBar:GetBagButton(bag)
        if not bagButton or bagButton.isCollapsed ~= true then
            items[#items + 1] = item
        end
    end
    local firstBag = STARTING_BAG_INDEX or 0
    local lastBag = ENDING_BAG_INDEX or 5
    if lastBag - firstBag > 20 then return false end
    for bag = firstBag, lastBag do
        local button = GamepadBagBar:GetBagButton(bag)
        if button then
            if not safeLayoutObject(button) then return false end
            bagButtons[#bagButtons + 1] = button
        end
    end
    local extraCount = #bagButtons - 1
    local width = frame:GetWidth()
    local columns = frame:GetColumns()
    if #items == 0 or type(columns) ~= "number" or columns < 2 or
        #bagButtons > columns or
        type(width) ~= "number" or width < 53 + extraCount * 42 + 38 or
        not GamepadBagBar:GetBagButton(0) then return false end
    table.sort(items, nativeOrder)
    -- Each item column needs one header control. Otherwise Blizzard's grid
    -- preserves a row number across columns with unequal header counts.
    local regularGrid = db.navLayout == true and #bagButtons == 6 and
        #items >= 7 and safeLayoutObject(frame.AddSlotsButton) and
        shown(frame.AddSlotsButton)
    -- Blizzard's four locked backpack slots are still item buttons in the
    -- native focus group. They can head four extra columns while locked.
    -- If they become usable, leave them in the ordinary item grid instead.
    local lockedHeaders = {}
    if regularGrid and db.landscapeLayout == true and IsAccountSecured and
        not IsAccountSecured() then
        for _, item in ipairs(items) do
            if item:GetBagID() == 0 and item.IsExtended and item:IsExtended() then
                lockedHeaders[#lockedHeaders + 1] = item
            end
        end
        if #lockedHeaders == 4 and #items >= 15 then
            local ordinary = {}
            for _, item in ipairs(items) do
                if item ~= lockedHeaders[1] and item ~= lockedHeaders[2] and
                    item ~= lockedHeaders[3] and item ~= lockedHeaders[4] then
                    ordinary[#ordinary + 1] = item
                end
            end
            items = ordinary
        else
            lockedHeaders = {}
        end
    end
    local landscapeGrid = #lockedHeaders == 4
    local itemColumns = regularGrid and (landscapeGrid and 11 or 7) or columns
    local itemRows = math.ceil(#items / itemColumns)
    local nativeRows = type(frame.GetRows) == "function" and frame:GetRows() or
        math.ceil((#items + #bagButtons) / columns)
    local rowDifference = itemRows - nativeRows
    if regularGrid then
        -- One native header per item column: six bags, add-slots, and
        -- optionally the four still-locked backpack slots.
        -- Anchor every item from the same footer point.
        local itemWidth, itemHeight = items[1]:GetWidth(), items[1]:GetHeight()
        if type(itemWidth) ~= "number" or type(itemHeight) ~= "number" or
            itemWidth <= 0 or itemHeight <= 0 then return false end
        local stepX, stepY = itemWidth + ITEM_SPACING, itemHeight + ITEM_SPACING
        -- Native width reserves ten item columns. Keep the seven-column
        -- background without moving or clipping the right-anchored contents.
        local compactWidth = (nativeLayoutWidth or width) -
            (columns - itemColumns) * stepX
        if compactWidth < itemColumns * itemWidth +
            (itemColumns - 1) * ITEM_SPACING + 14 then return false end
        frame:SetWidth(compactWidth)
        for index, item in ipairs(items) do
            local column = (index - 1) % itemColumns
            local row = math.floor((index - 1) / itemColumns)
            item:ClearAllPoints()
            item:SetPoint("BOTTOMRIGHT", frame.MoneyFrame, "TOPRIGHT",
                -(itemColumns - column - 1) * stepX,
                4 + (itemRows - row - 1) * stepY)
        end
    else
        if type(nativeLayoutWidth) == "number" then frame:SetWidth(nativeLayoutWidth) end
        AnchorUtil.GridLayout(items,
            AnchorUtil.CreateAnchor("BOTTOMRIGHT", frame.MoneyFrame, "TOPRIGHT", 0, 4),
            AnchorUtil.CreateGridLayout(GridLayoutMixin.Direction.BottomRightToTopLeft,
                columns, ITEM_SPACING, ITEM_SPACING))
    end
    -- Place one native control directly above each item column.
    stopBarAnimation()
    if not barCustomized then
        for bag = firstBag, lastBag do
            local button = GamepadBagBar:GetBagButton(bag)
            if button then
                bagVisibilityBefore[bag] = shown(button)
                if button.GetNumPoints and button.GetPoint then
                    local points = {}
                    local count = button:GetNumPoints()
                    if count > 8 then return false end
                    for index = 1, count do
                        points[#points + 1] = { button:GetPoint(index) }
                    end
                    bagAnchorsBefore[bag] = points
                end
            end
        end
    end
    barCustomized = true
    local extraIndex = 0
    for index, button in ipairs(bagButtons) do
        button:ClearAllPoints()
        if regularGrid then
            -- Matching widths and the same left edge avoid the subpixel X
            -- splits seen when buttons were chained from the backpack.
            button:SetPoint("BOTTOMLEFT", items[index], "TOPLEFT", 0, ITEM_SPACING)
        elseif button == GamepadBagBar:GetBagButton(0) then
            button:SetPoint("TOPLEFT", frame, "TOPLEFT", 10, -65)
        else
            button:SetPoint("TOPLEFT", frame, "TOPLEFT", 53 + extraIndex * 42, -65)
            extraIndex = extraIndex + 1
        end
        if button == GamepadBagBar:GetBagButton(0) then
            button:Show()
        end
    end
    if regularGrid then
        if not addSlotsSizeBefore then
            addSlotsSizeBefore = { frame.AddSlotsButton:GetWidth(),
                frame.AddSlotsButton:GetHeight() }
        end
        frame.AddSlotsButton:ClearAllPoints()
        frame.AddSlotsButton:SetSize(items[7]:GetWidth(), items[7]:GetHeight())
        frame.AddSlotsButton:SetPoint("BOTTOMLEFT", items[7], "TOPLEFT", 0, ITEM_SPACING)
        if landscapeGrid then
            for index, locked in ipairs(lockedHeaders) do
                locked:ClearAllPoints()
                locked:SetPoint("BOTTOMLEFT", items[index + 7], "TOPLEFT", 0,
                    ITEM_SPACING)
            end
        end
    end
    for bag = firstBag, lastBag do
        local button = GamepadBagBar:GetBagButton(bag)
        if button then shadeBagIcon(button, bag) end
    end
    renderBagBar(db.bagBarExpanded and 1 or 0)
    if regularGrid then
        if type(nativeLayoutHeight) == "number" then
            -- Preserve the existing header allowance for the portrait and
            -- bag strip while accounting for any extra item row.
            frame:SetHeight(nativeLayoutHeight + 36 + rowDifference *
                (items[1]:GetHeight() + ITEM_SPACING))
            layoutExtraHeight = 36 + rowDifference *
                (items[1]:GetHeight() + ITEM_SPACING)
        end
        return true
    end
    -- The item grid is anchored to the money frame, while the bag controls
    -- are anchored to the top. Reserve only the height their actual geometry
    -- needs. Count hidden bag buttons too: the strip can expand on focus.
    local extra = 36 + rowDifference * (items[1]:GetHeight() + ITEM_SPACING)
    local measured = pcall(function()
        if type(nativeLayoutHeight) ~= "number" then return end
        local highestItem, lowestBag
        for _, item in ipairs(items) do
            local top = item:GetTop()
            if type(top) ~= "number" then return end
            highestItem = math.max(highestItem or top, top)
        end
        local addSlots = frame.AddSlotsButton
        if addSlots and shown(addSlots) then
            local top = addSlots:GetTop()
            if type(top) ~= "number" then return end
            highestItem = math.max(highestItem, top)
        end
        for _, button in ipairs(bagButtons) do
            local bottom = button:GetBottom()
            if type(bottom) ~= "number" then
                local top, height = frame:GetTop(), button:GetHeight()
                if type(top) ~= "number" or type(height) ~= "number" then return end
                bottom = top - 65 - height
            end
            lowestBag = math.min(lowestBag or bottom, bottom)
        end
        if highestItem and lowestBag then
            local nativeGap = lowestBag - highestItem - (layoutExtraHeight or 0)
            extra = math.max(0, math.ceil(BAG_BAR_GAP - nativeGap))
        end
    end)
    if not measured then extra = 36 + rowDifference * (items[1]:GetHeight() + ITEM_SPACING) end
    if type(nativeLayoutHeight) == "number" then
        frame:SetHeight(nativeLayoutHeight + extra)
        layoutExtraHeight = extra
    end
    return true
end

local function updateBagSlotShading(frame, enabled)
    if not safeLayoutObject(frame) or type(frame.Items) ~= "table" then return end
    bagShadingVisible = false
    for _, item in ipairs(frame.Items) do
        if safeLayoutObject(item) then
            -- Blizzard's BACKGROUND texture was not visible in this client,
            -- even on empty slots. This inset OVERLAY sits above empty-slot
            -- art but below quest/focus overlays, with borders left clear.
            -- Keep one noninteractive region per pooled button and always
            -- read its current bag ID when Blizzard reassigns that button.
            pcall(function()
                local shade = bagSlotShades[item]
                local color = enabled and BAG_SLOT_TINT[item:GetBagID()]
                if not color then
                    if shade then shade:Hide() end
                    return
                end
                if not shade then
                    if InCombatLockdown and InCombatLockdown() then return end
                    shade = item:CreateTexture(nil, "OVERLAY", nil, -8)
                    shade:SetPoint("TOPLEFT", item, "TOPLEFT", 4, -4)
                    shade:SetPoint("BOTTOMRIGHT", item, "BOTTOMRIGHT", -4, 4)
                    bagSlotShades[item] = shade
                end
                shade:SetColorTexture(color[1], color[2], color[3], BAG_SLOT_SHADE_ALPHA)
                shade:Show()
                bagShadingVisible = true
            end)
        end
    end
end

refreshOriginalLayout = function()
    if not layoutFrame or not shown(layoutFrame) or
        (InCombatLockdown and InCombatLockdown()) or layoutBusy then return end
    -- With the custom layout off, leave native bag updates alone after any
    -- previously customized controls have been restored.
    if not gamepadVisualsEnabled() and not barCustomized and not bagShadingVisible then return end
    layoutBusy = true
    local ok = pcall(function()
        layoutFrame:UpdateFrameSize()
        layoutFrame:UpdateItemLayout()
        if UpdateContainerFrameAnchors then UpdateContainerFrameAnchors() end
    end)
    layoutBusy = false
    refreshBagTitle()
    if not ok then say("Layout refresh failed; native bags remain available.") end
end

local function installLayoutHooks()
    if layoutFrame then return end
    -- A disabled layout must not attach to Blizzard's combined bag at login.
    -- Turning the layout on later calls this function from the slash command.
    if not gamepadVisualsEnabled() then return end
    local frame = _G.ContainerFrameCombinedBags
    if not safeLayoutObject(frame) or not hooksecurefunc or
        type(frame.UpdateFrameSize) ~= "function" or
        type(frame.UpdateItemLayout) ~= "function" then return end
    local ok = pcall(function()
        hooksecurefunc(frame, "UpdateFrameSize", function(self)
            if useOriginalLayout() and safeLayoutObject(self) then
                local sized = pcall(function()
                    nativeLayoutHeight = self:GetHeight()
                    nativeLayoutWidth = self:GetWidth()
                    -- Keep the proven allowance until the following item
                    -- layout supplies positions for a measured adjustment.
                    self:SetHeight(nativeLayoutHeight + 36)
                    layoutExtraHeight = 36
                end)
                if not sized then
                    layoutFailed = true
                    say("Original gamepad layout could not be sized; using native layout.")
                end
            end
        end)
        hooksecurefunc(frame, "UpdateItemLayout", function(self)
            if layoutMutating then return end
            if not gamepadVisualsEnabled() and not barCustomized and
                not bagShadingVisible then return end
            updateBagSlotShading(self, gamepadVisualsEnabled())
            if not useOriginalLayout() then
                if not (InCombatLockdown and InCombatLockdown()) then
                    pcall(restoreBagBar)
                end
                return
            end
            layoutMutating = true
            local ok, applied = pcall(applyOriginalLayout, self)
            layoutMutating = false
            if not ok or not applied then
                layoutFailed = true
                updateBagSlotShading(self, false)
                refreshBagTitle()
                say("Original gamepad layout could not be applied; reverting to native layout.")
                pcall(restoreBagBar)
                -- The native method runs first. Restore its anchors and size if
                -- our post-layout pass failed partway through.
                refreshOriginalLayout()
            end
        end)
    end)
    if ok then layoutFrame = frame end
    if ok and type(frame.UpdateName) == "function" and
        type(frame.SetTitle) == "function" then
        pcall(hooksecurefunc, frame, "UpdateName", function(self)
            if gamepadVisualsEnabled() and safeLayoutObject(self) then
                pcall(self.SetTitle, self, "Friday Night Bags")
            end
        end)
        if shown(frame) then refreshBagTitle() end
    end
    if ok and frame.HookScript then
        frame:HookScript("OnShow", function()
            controllerSelectionGeneration = controllerSelectionGeneration + 1
            iconHighlightSeen = false
            stopBarAnimation()
            if db then db.bagBarExpanded = db.navLayout == true end
        end)
    end
end

local function capture()
    if not db or not db.diagnostic or not db.diagnostic.armed then return end
    local mode = "1" -- Diagnostics are armed only in gamepad UI mode.
    if mode ~= "0" and mode ~= "1" then return end
    if db.diagnostic.views[mode] then return end
    local combined, confirmedName = primaryBagFrame()
    if not shown(combined) then return end

    local frames = {}
    local seen = {}
    local function add(frame)
        if not frame or seen[frame] or not shown(frame) or #frames >= 40 then return end
        seen[frame] = true
        local name = frameName(frame)
        if name == "<unavailable>" then return end
        frames[#frames + 1] = { name = name, box = geometry(frame) }
    end
    add(combined)
    for index = 1, 20 do add(_G["ContainerFrame" .. index]) end
    db.diagnostic.views[mode] = {
        mode = mode, build = select(2, GetBuildInfo()),
        primaryFrameName = frameName(combined), knownCombinedFrameName = confirmedName,
        primaryBox = geometry(combined),
        slots = gatherSlots(combined), frames = frames,
        focusNote = "No documented controller-focus getter verified for this beta; visual focus is not inferred.",
    }
    say((mode == "1" and "Gamepad" or "Mouse") .. " bag view captured (" ..
        #db.diagnostic.views[mode].slots .. " slot frames).")
    db.diagnostic.armed = false
    say("Gamepad view saved. Use /fnbag export to copy it.")
end

local function itemIdFrom(text)
    return tonumber((text or ""):match("item:(%d+)")) or tonumber((text or ""):match("^%s*(%d+)%s*$"))
end

local function itemSignature(info)
    if not info or not info.itemID then return nil end
    return tostring(info.itemID) .. ":" .. tostring(info.stackCount or 0) .. ":" ..
        tostring(info.hyperlink or "")
end

local function missingSaleAPI()
    if type(C_Container) ~= "table" then return "C_Container" end
    for _, name in ipairs({ "GetContainerNumSlots", "GetContainerItemInfo", "UseContainerItem" }) do
        if type(C_Container[name]) ~= "function" then return "C_Container." .. name end
    end
    if type(C_Item) ~= "table" or type(C_Item.GetItemInfo) ~= "function" then
        return "C_Item.GetItemInfo"
    end
    return nil
end

local function eligible(bag, slot)
    if missingSaleAPI() then return nil, "api" end
    local info = C_Container.GetContainerItemInfo(bag, slot)
    if not info then return nil, "empty" end
    if not info.itemID then return nil, "metadata" end
    if info.isLocked then return nil, "locked" end
    if db.keep[info.itemID] then return nil, "kept" end
    if info.quality ~= nil and info.quality ~= 0 then return nil, "other" end
    local name, link, quality, _, _, _, _, _, _, _, sellPrice = C_Item.GetItemInfo(info.hyperlink or info.itemID)
    if not name or not link or quality == nil or sellPrice == nil then return nil, "metadata" end
    if quality ~= 0 then return nil, "other" end
    if type(sellPrice) ~= "number" or sellPrice <= 0 then return nil, "price" end
    local resolvedID = tonumber(link:match("item:(%d+)"))
    if resolvedID ~= info.itemID then return nil, "identity" end
    return itemSignature(info), "eligible"
end

local function saleSummary(session, reason, pending)
    if session ~= merchantSession or saleReportedSession == session then return end
    saleReportedSession = session
    local nativeCount
    if C_MerchantFrame and C_MerchantFrame.GetNumJunkItems then
        local ok, count = pcall(C_MerchantFrame.GetNumJunkItems)
        if ok and type(count) == "number" then nativeCount = count end
    end
    db.lastMerchantScan = {
        version = VERSION, calls = saleAttempts,
        slotsChanged = saleSlotChanges, slotsUnchanged = saleUnchanged,
        reason = reason or (pending and "metadata" or "complete"),
        nativeJunkCount = nativeCount, scanReasons = lastScanReasons,
        missingFunction = saleMissingAPI,
    }
    if saleAttempts > 0 then
        say("Gray-junk sale calls: " .. saleAttempts .. "; bag slots changed: " ..
            saleSlotChanges .. "; unchanged: " .. saleUnchanged ..
            ". Check the vendor receipt if a slot changed.")
    elseif reason == "merchant" then
        say("Vendor scan stopped because the merchant window was not visible.")
    elseif reason == "buyback" then
        say("Vendor scan paused on the buyback tab; no item was sold.")
    elseif reason == "api" then
        say("Vendor scan stopped: " .. (saleMissingAPI or "required API") .. " unavailable.")
    elseif reason == "call_error" then
        say("Vendor sale call failed; no further items were attempted.")
    elseif pending then
        say("No sale requested: item information was still unavailable. Other items were left untouched.")
    else
        say("No eligible priced gray junk found" ..
            (nativeCount and (" (game reports " .. nativeCount .. " junk item(s))") or "") .. ".")
    end
end

local function scheduleSale(session, delay)
    if not gamepadModeActive() then merchantOpen = false; return end
    if saleTimerSession == session then return end
    if not C_Timer or type(C_Timer.After) ~= "function" then
        saleMissingAPI = "C_Timer.After"
        saleSummary(session, "api")
        return
    end
    saleTimerSession = session
    C_Timer.After(delay or 0.2, function()
        if saleTimerSession == session then saleTimerSession = nil end
        if not gamepadModeActive() then merchantOpen = false; return end
        if session ~= merchantSession or not merchantOpen or not db or
            not db.autoSellGray then return end
        saleMissingAPI = missingSaleAPI()
        if saleMissingAPI then saleSummary(session, "api"); return end
        if not shown(_G.MerchantFrame) then
            merchantRetries = merchantRetries + 1
            if merchantRetries <= MAX_MERCHANT_RETRIES then scheduleSale(session, 0.5)
            else saleSummary(session, "merchant") end
            return
        end
        if _G.MerchantFrame.selectedTab == 2 then
            saleSummary(session, "buyback")
            return
        end
        if pendingSale then
            local current = C_Container.GetContainerItemInfo(pendingSale.bag, pendingSale.slot)
            if itemSignature(current) == pendingSale.signature and pendingSale.checks < 5 then
                pendingSale.checks = pendingSale.checks + 1
                scheduleSale(session, 0.4)
                return
            end
            if itemSignature(current) == pendingSale.signature then
                saleUnchanged = saleUnchanged + 1
            else
                saleSlotChanges = saleSlotChanges + 1
            end
            pendingSale = nil
        end
        local pendingInfo = false
        lastScanReasons = {}
        for bag = 0, 5 do -- Bag 5 is the reagent bag in this Forever beta.
            local count = C_Container.GetContainerNumSlots(bag) or 0
            for slot = 1, count do
                local key = tostring(bag) .. ":" .. tostring(slot)
                local signature, reason = eligible(bag, slot)
                if reason ~= "empty" then
                    lastScanReasons[reason] = (lastScanReasons[reason] or 0) + 1
                end
                if reason == "metadata" then pendingInfo = true end
                if reason == "api" then
                    saleMissingAPI = missingSaleAPI()
                    saleSummary(session, "api")
                    return
                end
                if signature and attempted[key] ~= signature then
                    -- Revalidate immediately before using the slot. No cached slot queue is used.
                    if eligible(bag, slot) == signature then
                        if not gamepadModeActive() then return end
                        attempted[key] = signature
                        -- Match Blizzard's item-button sale call on this beta.
                        local bankType
                        if _G.BankFrame and BankFrame.GetActiveBankType then
                            local bankOK, value = pcall(BankFrame.GetActiveBankType, BankFrame)
                            if bankOK then bankType = value end
                        end
                        local ok = pcall(C_Container.UseContainerItem, bag, slot,
                            nil, bankType, false)
                        if not ok then
                            saleSummary(session, "call_error")
                            merchantOpen = false
                            return
                        end
                        saleAttempts = saleAttempts + 1
                        pendingSale = { bag = bag, slot = slot, signature = signature, checks = 0 }
                        scheduleSale(session, 0.4)
                        return
                    end
                end
            end
        end
        if pendingInfo and metadataRetries < MAX_METADATA_RETRIES then
            metadataRetries = metadataRetries + 1
            scheduleSale(session, 0.5)
        else
            saleSummary(session, nil, pendingInfo)
        end
    end)
end

local function sortClock()
    return GetTime and GetTime() or 0
end

local SORT_FLAG_NAMES = {
    "ClassEquipment", "ClassConsumables", "ClassProfessionGoods",
    "ClassJunk", "ClassQuestItems", "ClassReagents", "DisableAutoSort",
}

local function sortVisualSlots()
    local positions = {}
    local frame = _G.ContainerFrameCombinedBags
    if not shown(frame) or type(frame.Items) ~= "table" then return positions end
    for _, button in ipairs(frame.Items) do
        local ok, bag, slot, x, y = pcall(function()
            return button:GetBagID(), button:GetID(), button:GetLeft(), button:GetTop()
        end)
        if ok and type(bag) == "number" and type(slot) == "number" then
            positions[bag .. ":" .. slot] = { x = round(x), y = round(y) }
        end
    end
    return positions
end

local function sortSnapshot()
    local snapshot = { at = sortClock(), build = select(2, GetBuildInfo()),
        bags = {}, slots = {}, visibleCombined = shown(_G.ContainerFrameCombinedBags) }
    local positions = sortVisualSlots()
    if C_Container and C_Container.GetSortBagsRightToLeft then
        local ok, value = pcall(C_Container.GetSortBagsRightToLeft)
        if ok then snapshot.rightToLeft = value end
    end
    for bag = 0, 5 do
        local bagRecord = { id = bag, flags = {} }
        local ok, count = pcall(function() return C_Container.GetContainerNumSlots(bag) end)
        if not ok or type(count) ~= "number" then
            bagRecord.error = "slot-count-unavailable"
            count = 0
        end
        bagRecord.size = count
        if C_Container and C_Container.GetContainerNumFreeSlots then
            local freeOK, free, family = pcall(C_Container.GetContainerNumFreeSlots, bag)
            if freeOK then bagRecord.free, bagRecord.family = free, family end
        end
        if bag == 0 and C_Container and C_Container.GetBackpackAutosortDisabled then
            local flagOK, value = pcall(C_Container.GetBackpackAutosortDisabled)
            if flagOK then bagRecord.flags.DisableAutoSort = value end
        elseif Enum and Enum.BagSlotFlags and C_Container and C_Container.GetBagSlotFlag then
            for _, flagName in ipairs(SORT_FLAG_NAMES) do
                local flag = Enum.BagSlotFlags[flagName]
                if flag then
                    local flagOK, value = pcall(C_Container.GetBagSlotFlag, bag, flag)
                    if flagOK and value then bagRecord.flags[flagName] = true end
                end
            end
        end
        snapshot.bags[#snapshot.bags + 1] = bagRecord
        for slot = 1, count do
            local record = { bag = bag, slot = slot }
            local itemOK, info = pcall(C_Container.GetContainerItemInfo, bag, slot)
            if not itemOK then
                record.error = "item-info-unavailable"
            elseif info and info.itemID then
                record.id = info.itemID
                record.stack = info.stackCount
                record.quality = info.quality
                record.link = info.hyperlink
                record.name = info.itemName
                record.locked = info.isLocked
                if C_Item and C_Item.GetItemInfo then
                    local metaOK, name, link, quality, _, _, itemType =
                        pcall(C_Item.GetItemInfo, info.hyperlink or info.itemID)
                    if metaOK then
                        record.name = record.name or name
                        record.link = record.link or link
                        if record.quality == nil then record.quality = quality end
                        record.type = itemType
                    end
                end
                if C_Item and C_Item.GetItemInfoInstant then
                    local classOK, _, _, _, _, _, classID, subClassID =
                        pcall(C_Item.GetItemInfoInstant, info.hyperlink or info.itemID)
                    if classOK then record.classID, record.subClassID = classID, subClassID end
                end
                if C_Container.GetContainerItemQuestInfo then
                    local questOK, quest = pcall(C_Container.GetContainerItemQuestInfo, bag, slot)
                    if questOK and quest then record.quest = quest.isQuestItem end
                end
            end
            local position = positions[bag .. ":" .. slot]
            if position then record.x, record.y = position.x, position.y end
            snapshot.slots[#snapshot.slots + 1] = record
        end
    end
    return snapshot
end

local function sortDigest(snapshot)
    local fields = {}
    for _, bag in ipairs(snapshot.bags) do
        fields[#fields + 1] = tostring(bag.id) .. ":" .. tostring(bag.size)
    end
    for _, slot in ipairs(snapshot.slots) do
        fields[#fields + 1] = tostring(slot.bag) .. ":" .. tostring(slot.slot) .. ":" ..
            tostring(slot.id or 0) .. ":" .. tostring(slot.stack or 0) .. ":" ..
            tostring(slot.link or "")
    end
    return table.concat(fields, "|")
end

local function finishSortProbe(status, snapshot)
    if not sortProbe or sortProbe.state ~= "sorting" then return end
    sortProbe.after = snapshot
    sortProbe.status = status
    sortProbe.finishedAt = sortClock()
    sortProbe.state = "complete"
    local changed = 0
    for index, before in ipairs(sortProbe.before.slots) do
        local after = snapshot.slots[index]
        if not after or before.bag ~= after.bag or before.slot ~= after.slot or
            before.id ~= after.id or before.stack ~= after.stack or
            before.link ~= after.link then changed = changed + 1 end
    end
    if #snapshot.slots > #sortProbe.before.slots then
        changed = changed + #snapshot.slots - #sortProbe.before.slots
    end
    sortProbe.changedSlots = changed
    say("Native sort captured (" .. changed .. " changed bag slots, " ..
        sortProbe.bagUpdates .. " bag updates). Use /fnbag sortexport to copy the comparison.")
end

local function pollSortProbe(generation)
    if not gamepadModeActive() then return end
    if generation ~= sortProbeGeneration or not sortProbe or sortProbe.state ~= "sorting" then return end
    local snapshot = sortSnapshot()
    local digest = sortDigest(snapshot)
    local now = sortClock()
    if digest == sortProbe.lastDigest and now - sortProbe.lastBagUpdateAt >= 0.8 then
        sortProbe.stableSamples = sortProbe.stableSamples + 1
    else
        sortProbe.stableSamples = 0
    end
    sortProbe.lastDigest = digest
    if now - sortProbe.sortStartedAt >= 2 and sortProbe.stableSamples >= 2 then
        finishSortProbe(digest == sortDigest(sortProbe.before) and "no-change" or "stable", snapshot)
    elseif now - sortProbe.sortStartedAt >= 12 then
        finishSortProbe("timed-out-partial", snapshot)
    else
        C_Timer.After(0.5, function() pollSortProbe(generation) end)
    end
end

local function onNativeSort()
    if not gamepadModeActive() then return end
    if not sortProbe or sortProbe.state == "complete" or sortProbe.state == "cancelled" then return end
    local now = sortClock()
    if sortProbe.state == "sorting" then
        sortProbe.repeatSorts = sortProbe.repeatSorts + 1
    else
        sortProbe.state = "sorting"
        sortProbe.lastDigest = sortDigest(sortProbe.before)
        sortProbe.bagUpdates = 0
        sortProbe.repeatSorts = 0
    end
    sortProbe.sortStartedAt = now
    sortProbe.lastBagUpdateAt = now
    sortProbe.stableSamples = 0
    if sortProbe.repeatSorts == 0 then
        local generation = sortProbeGeneration
        C_Timer.After(0.5, function() pollSortProbe(generation) end)
    end
end

local function installSortHook()
    if not gamepadModeActive() or sortHookInstalled or sortHookAttempted or not C_Container or
        type(C_Container.SortBags) ~= "function" or not hooksecurefunc then return end
    sortHookAttempted = true
    local ok = pcall(hooksecurefunc, C_Container, "SortBags", onNativeSort)
    sortHookInstalled = ok
end

local function init()
    FridayNightBagsDB = FridayNightBagsDB or {}
    db = FridayNightBagsDB
    if db.autoSellGray == nil then db.autoSellGray = true end
    if db.originalGamepadLayout == nil then db.originalGamepadLayout = true end
    -- Retire the prior panel-state experiment, including saved "on" values.
    db.navigationFix = false
    if db.navLayout == nil then db.navLayout = true end
    if db.landscapeLayout == nil then db.landscapeLayout = false end
    -- Older list prototypes may have saved this value. Grid is the only view.
    db.viewMode = "grid"
    -- The strip is transient UI state; a reload or mode change starts closed.
    db.bagBarExpanded = false
    if type(db.keep) ~= "table" then db.keep = {} end
    if type(db.diagnostic) ~= "table" then db.diagnostic = {} end
    if type(db.diagnostic.views) ~= "table" then db.diagnostic.views = {} end
    if type(db.blockedActions) ~= "table" then db.blockedActions = {} end
    if type(db.sortProbe) == "table" then
        sortProbe = db.sortProbe
        if sortProbe.state == "sorting" or sortProbe.state == "await_sort" then
            sortProbe.state = "interrupted"
            sortProbe.status = "interrupted-by-reload"
        end
    end
    -- A previous login may have left a capture armed. Require an explicit
    -- command in this session so a failure cannot repeat at login.
    db.diagnostic.armed = false
    lastGamepadMode = gamepadModeActive()
    if lastGamepadMode then
        say("Gray-junk auto-sale is " .. (db.autoSellGray and "ON" or "OFF") ..
            ". /fnbag off disables it; /fnbag keep <item link or ID> protects an item type.")
        installLayoutHooks()
        installSortHook()
    end
end

local function eventText(value)
    local ok, result = pcall(function()
        if type(value) ~= "string" then return "<unavailable>" end
        return value:gsub("[%c]", " "):sub(1, 160)
    end)
    return ok and result or "<unavailable>"
end

local function recordBlockedAction(event, attributedAddon, blockedFunction)
    if not db or not gamepadModeActive() then return end
    local timestamp
    if type(time) == "function" then
        local ok, value = pcall(time)
        if ok and type(value) == "number" then timestamp = value end
    end
    local record = {
        version = VERSION, event = event, timestamp = timestamp,
        addon = eventText(attributedAddon),
        blockedFunction = eventText(blockedFunction),
    }
    local records = db.blockedActions
    records[#records + 1] = record
    while #records > MAX_BLOCKED_RECORDS do table.remove(records, 1) end
    say(event .. ": " .. record.addon .. " -> " .. record.blockedFunction ..
        ". Saved for logout.")
end

local function field(value)
    if value == nil then return "" end
    return tostring(value):gsub("[\t\r\n]", " ")
end

local function row(...)
    local values = {}
    for index = 1, select("#", ...) do values[index] = field(select(index, ...)) end
    return table.concat(values, "\t")
end

local function boxFields(box)
    box = box or {}
    return box.left, box.top, box.width, box.height
end

local function formatView(view)
    local lines = { row("FNBAG", "1", view.mode, view.build, view.primaryFrameName,
        view.knownCombinedFrameName) }
    lines[#lines + 1] = row("PRIMARY", boxFields(view.primaryBox))
    for _, frame in ipairs(view.frames or {}) do
        lines[#lines + 1] = row("FRAME", frame.name, boxFields(frame.box))
    end
    for _, slot in ipairs(view.slots or {}) do
        lines[#lines + 1] = row("CELL", slot.source, slot.name, slot.id, slot.bagID, slot.shown,
            boxFields(slot.box))
    end
    lines[#lines + 1] = row("FOCUS", view.focusNote)
    return table.concat(lines, "\n")
end

local function formatSortSnapshot(snapshot, label, probe)
    local lines = { row("FNBAGSORT", "1", label, snapshot.build, probe.status,
        probe.changedSlots, probe.bagUpdates, probe.repeatSorts, probe.preSortUpdates) }
    lines[#lines + 1] = row("NOTE", "Native C_Container.SortBags; physical bag/slot snapshots. UI x/y optional. Quiet-window capture is not an engine completion signal.")
    lines[#lines + 1] = row("SETTING", "rightToLeft", snapshot.rightToLeft,
        "combinedVisible", snapshot.visibleCombined)
    for _, bag in ipairs(snapshot.bags or {}) do
        local flags = {}
        for name, enabled in pairs(bag.flags or {}) do
            if enabled then flags[#flags + 1] = name end
        end
        table.sort(flags)
        lines[#lines + 1] = row("BAG", bag.id, bag.size, bag.free, bag.family,
            table.concat(flags, ","), bag.error)
    end
    for _, slot in ipairs(snapshot.slots or {}) do
        local category = slot.quest and "Quest" or
            (slot.quality == 0 and "Junk" or slot.type)
        lines[#lines + 1] = row("SLOT", slot.bag, slot.slot, slot.id, slot.stack,
            slot.quality, category, slot.classID, slot.subClassID, slot.locked,
            slot.x, slot.y, slot.name, slot.link, slot.error)
    end
    return table.concat(lines, "\n")
end

local function exportSortProbe()
    local probe = db.sortProbe
    if type(probe) ~= "table" or not probe.before then
        say("No native sort capture yet. Open bags and use /fnbag sortdiag first.")
        return
    end
    copyPages = { formatSortSnapshot(probe.before, "before", probe) }
    if probe.after then
        copyPages[#copyPages + 1] = formatSortSnapshot(probe.after, "after", probe)
    end
    copyTitle = "Native sort diagnostic"
    copyPage = 1
    showCopyPage()
end

showCopyPage = function()
    if not copyPages or #copyPages == 0 then return end
    if InCombatLockdown and InCombatLockdown() and not copyPanel then
        say("Copy window can be opened after combat; the export is saved for logout.")
        return
    end
    if not copyPanel then
        copyPanel = CreateFrame("Frame", "FridayNightBagsCopyExport", UIParent, "BasicFrameTemplateWithInset")
        copyPanel:SetSize(720, 510)
        copyPanel:SetPoint("CENTER")
        copyPanel.title = copyPanel:CreateFontString(nil, "OVERLAY", "GameFontHighlight")
        copyPanel.title:SetPoint("TOP", 0, -10)
        local scroll = CreateFrame("ScrollFrame", nil, copyPanel, "UIPanelScrollFrameTemplate")
        scroll:SetPoint("TOPLEFT", 18, -55)
        scroll:SetPoint("BOTTOMRIGHT", -34, 43)
        copyEdit = CreateFrame("EditBox", nil, scroll)
        copyEdit:SetMultiLine(true)
        copyEdit:SetFontObject(GameFontHighlightSmall)
        copyEdit:SetSize(655, 400)
        copyEdit:SetAutoFocus(false)
        copyEdit:SetPoint("TOPLEFT", scroll, "TOPLEFT", 0, 0)
        copyEdit:SetScript("OnEscapePressed", function() copyPanel:Hide() end)
        scroll:SetScrollChild(copyEdit)
        local function pageButton(text, x, delta)
            local button = CreateFrame("Button", nil, copyPanel, "UIPanelButtonTemplate")
            button:SetSize(85, 25)
            button:SetPoint("BOTTOMLEFT", x, 12)
            button:SetText(text)
            button:SetScript("OnClick", function()
                copyPage = math.max(1, math.min(#copyPages, copyPage + delta))
                showCopyPage()
            end)
            return button
        end
        copyPanel.previous = pageButton("Previous", 20, -1)
        copyPanel.next = pageButton("Next", 110, 1)
        copyPanel.help = copyPanel:CreateFontString(nil, "OVERLAY", "GameFontHighlightSmall")
        copyPanel.help:SetPoint("BOTTOMLEFT", 210, 18)
        copyPanel.help:SetText("Click text, Ctrl+A, Ctrl+C; copy both pages if shown.")
        copyPanel.scroll = scroll
    end
    local data = copyPages[copyPage]
    copyPanel.title:SetText(copyTitle .. " " .. copyPage .. "/" .. #copyPages)
    copyPanel:Show()
    copyEdit:SetText(data)
    copyPanel.scroll:SetVerticalScroll(0)
    local ok, readBack = pcall(copyEdit.GetText, copyEdit)
    if not ok or readBack ~= data then
        say("Copy box could not hold the full page; use SavedVariables after logout.")
    end
end

local function exportDiagnostic()
    FridayNightBagsExport = {
        version = VERSION, views = db.diagnostic.views,
        note = "Native frame geometry and visible item buttons; no controller-focus API inferred.",
    }
    copyPages = {}
    copyTitle = "Bag diagnostic"
    for _, mode in ipairs({ "1" }) do
        local view = db.diagnostic.views[mode]
        if view then copyPages[#copyPages + 1] = formatView(view) end
    end
    copyPage = 1
    say("Gamepad export prepared (view=" ..
        tostring(db.diagnostic.views["1"] ~= nil) .. ").")
    if #copyPages > 0 then showCopyPage()
    else say("No views captured yet. Open the combined bag in each mode.") end
end

-- One-shot read-only snapshot of Blizzard's current SmartNavigation grid.
-- Function-valued direction overrides are reported but never invoked.
local function navGet(object, key)
    local ok, value = pcall(function() return object and object[key] end)
    return ok and value or nil
end

local function navCall(object, method)
    local ok, a, b, c, d = pcall(function()
        local fn = object and object[method]
        if type(fn) == "function" then return fn(object) end
    end)
    if ok then return a, b, c, d end
end

local function navText(value)
    local ok, result = pcall(function()
        return value == nil and "?" or tostring(value):gsub("[%c]", " "):sub(1, 100)
    end)
    return ok and result or "<restricted>"
end

local function navNumber(value)
    local ok, result = pcall(function()
        return type(value) == "number" and string.format("%.6f", value) or "?"
    end)
    return ok and result or "<restricted>"
end

local function navFlag(value)
    local ok, result = pcall(function()
        if value == true then return "true" end
        if value == false then return "false" end
        return "?"
    end)
    return ok and result or "<restricted>"
end

local function navName(frame)
    if not frame then return "<none>" end
    local name = navCall(frame, "GetName")
    return name and navText(name) or
        ("<unnamed:" .. navText(navCall(frame, "GetObjectType")) .. ">")
end

local function navControlLine(label, column, index, frame, selected)
    local name = navName(frame)
    if navFlag(navCall(frame, "IsForbidden")) == "true" then
        return row(label, column, index, name, "forbidden")
    end
    local cx, cy = navCall(frame, "GetCenter")
    local left, bottom, width, height = navCall(frame, "GetRect")
    local sl, sb, sw, sh = navCall(frame, "GetScaledRect")
    local ok, sx, sy = pcall(function()
        if type(sl) == "number" and type(sb) == "number" and
            type(sw) == "number" and type(sh) == "number" then
            return sl + sw / 2, sb + sh / 2
        end
    end)
    if not ok then sx, sy = nil, nil end
    return row(label, column, index, name,
        "selected=" .. navFlag(selected),
        "visible=" .. navFlag(navCall(frame, "IsVisible")),
        "shown=" .. navFlag(navCall(frame, "IsShown")),
        "enabled=" .. navFlag(navCall(frame, "IsEnabled")),
        "rectValid=" .. navFlag(navCall(frame, "IsRectValid")),
        "center=" .. navNumber(cx) .. "," .. navNumber(cy),
        "scaledCenter=" .. navNumber(sx) .. "," .. navNumber(sy),
        "rect=" .. navNumber(left) .. "," .. navNumber(bottom) .. "," ..
            navNumber(width) .. "," .. navNumber(height),
        "scaledRect=" .. navNumber(sl) .. "," .. navNumber(sb) .. "," ..
            navNumber(sw) .. "," .. navNumber(sh),
        "bag=" .. navText(navCall(frame, "GetBagID")),
        "idOrSlot=" .. navText(navCall(frame, "GetID")))
end

local function navReport()
    local build = "?"
    if type(GetBuildInfo) == "function" then
        local ok, value = pcall(function() return select(2, GetBuildInfo()) end)
        if ok then build = navText(value) end
    end
    local lines = { row("FNBNAV", "1", VERSION, build,
        "gamepad=" .. navFlag(gamepadModeActive())) }
    local nav = _G.SmartNavigation
    if not nav then
        lines[#lines + 1] = row("STATUS", "SmartNavigation unavailable")
        return table.concat(lines, "\n"), 0, "SmartNavigation unavailable"
    end
    local info = navGet(nav, "activeInfo")
    local selected = navGet(nav, "currentButton")
    local combined = _G.ContainerFrameCombinedBags
    lines[#lines + 1] = row("PANEL", "active=" .. navName(navGet(info, "frame")),
        "combined=" .. navName(combined),
        "combinedShown=" .. navFlag(navCall(combined, "IsShown")),
        "useGrid=" .. navFlag(navGet(info, "useGrid")),
        "wrapping=" .. navFlag(navGet(info, "isWrapping")),
        "focusedKey=" .. navText(navGet(info, "focusedKey")),
        "selected=" .. navName(selected))
    if not info then
        lines[#lines + 1] = row("STATUS", "No active SmartNavigation panel at capture")
        return table.concat(lines, "\n"), 0, "no active panel"
    end

    local portrait
    if GamepadBagBar and type(GamepadBagBar.GetBagButton) == "function" then
        local ok, value = pcall(GamepadBagBar.GetBagButton, GamepadBagBar, 0)
        if ok then portrait = value end
    end
    lines[#lines + 1] = navControlLine("PORTRAIT", "", "", portrait, portrait == selected)
    local down = SMART_NAV_INPUT_DIRECTION and SMART_NAV_INPUT_DIRECTION.DOWN
    local overrides = navGet(navGet(portrait, "smartNavData"), "navigationOverrides")
    local target = navGet(overrides, navGet(down, "dirKey"))
    if target == nil then
        lines[#lines + 1] = row("PORTRAIT_DOWN", "no direct override found")
    elseif type(target) == "function" then
        lines[#lines + 1] = row("PORTRAIT_DOWN", "function override; not invoked")
    elseif target == true or navFlag(navGet(target, "shouldIgnoreInputNavOverride")) == "true" then
        lines[#lines + 1] = row("PORTRAIT_DOWN", "input ignored by override")
    else
        local valid, x, y
        if type(nav.IsButtonValid) == "function" then
            local ok, v, vx, vy = pcall(nav.IsButtonValid, nav, target)
            if ok then valid, x, y = v, vx, vy end
        end
        lines[#lines + 1] = row("PORTRAIT_DOWN", "target=" .. navName(target),
            "valid=" .. navFlag(valid),
            "validScaledCenter=" .. navNumber(x) .. "," .. navNumber(y))
        lines[#lines + 1] = navControlLine("DOWN_TARGET", "", "", target, target == selected)
    end

    local groups = navGet(info, "buttonGroups")
    local focused = navGet(groups, "focusedGroup")
    local group = focused or navGet(groups, "mainGroup")
    local buttons, grid = navGet(group, "buttons"), navGet(info, "grid")
    local inGrid, columns, count = {}, 0, 0
    if type(grid) == "table" then
        for columnIndex, column in ipairs(grid) do
            if columnIndex > 80 then lines[#lines + 1] = row("TRUNCATED", "columns"); break end
            columns = columns + 1
            lines[#lines + 1] = row("COLUMN", columnIndex, "length=" .. navText(#column))
            for rowIndex, button in ipairs(column) do
                if count >= 500 then lines[#lines + 1] = row("TRUNCATED", "grid controls"); break end
                count = count + 1
                inGrid[button] = true
                lines[#lines + 1] = navControlLine("GRID", columnIndex, rowIndex,
                    button, button == selected)
            end
            if count >= 500 then break end
        end
    else
        lines[#lines + 1] = row("GRID", "unavailable")
    end
    lines[#lines + 1] = row("GRID_SUMMARY", "columns=" .. columns,
        "controls=" .. count, "group=" .. (focused and "focused" or "main"))
    if type(buttons) == "table" then
        lines[#lines + 1] = row("GROUP_SUMMARY", "registered=" .. navText(#buttons))
        for index, button in ipairs(buttons) do
            if index > 500 then lines[#lines + 1] = row("TRUNCATED", "registered controls"); break end
            if not inGrid[button] then
                lines[#lines + 1] = navControlLine("NOT_IN_GRID", "", index,
                    button, button == selected)
            end
        end
    else
        lines[#lines + 1] = row("GROUP", "registered controls unavailable")
    end
    return table.concat(lines, "\n"), columns, "captured"
end

local function exportNavReport()
    if not db or type(db.navProbe) ~= "string" then
        say("No navigation capture yet. Use /fnb nav while bags are open.")
        return
    end
    if InCombatLockdown and InCombatLockdown() then
        say("Navigation capture saved. Use /fnb navexport after combat.")
        return
    end
    copyPages, copyTitle, copyPage = {}, "Navigation diagnostic", 1
    local page, length = {}, 0
    for line in (db.navProbe .. "\n"):gmatch("(.-)\n") do
        if length + #line > 5500 and #page > 0 then
            copyPages[#copyPages + 1] = table.concat(page, "\n")
            page, length = {}, 0
        end
        page[#page + 1], length = line, length + #line + 1
    end
    if #page > 0 then copyPages[#copyPages + 1] = table.concat(page, "\n") end
    if not pcall(showCopyPage) then
        say("Copy window unavailable. Navigation capture is saved for /reload or logout.")
    end
end

addon:RegisterEvent("ADDON_LOADED")
addon:RegisterEvent("PLAYER_LOGIN")
addon:RegisterEvent("PLAYER_REGEN_ENABLED")
addon:RegisterEvent("MERCHANT_SHOW")
addon:RegisterEvent("MERCHANT_CLOSED")
addon:RegisterEvent("BAG_UPDATE_DELAYED")
addon:RegisterEvent("ADDON_ACTION_BLOCKED")
addon:RegisterEvent("ADDON_ACTION_FORBIDDEN")
addon:SetScript("OnEvent", function(_, event, name, blockedFunction)
    if event == "ADDON_ACTION_BLOCKED" or event == "ADDON_ACTION_FORBIDDEN" then
        recordBlockedAction(event, name, blockedFunction)
    elseif event == "ADDON_LOADED" then
        if name == ADDON_NAME then
            init()
        elseif db and gamepadModeActive() then
            -- The Blizzard combined frame may be loaded on demand.
            installLayoutHooks()
            installSortHook()
        end
    elseif event == "PLAYER_LOGIN" then
        if gamepadModeActive() then
            installLayoutHooks()
            installSortHook()
        end
    elseif event == "PLAYER_REGEN_ENABLED" then
        if gamepadModeActive() then
            installLayoutHooks()
            installSortHook()
        end
    elseif event == "MERCHANT_SHOW" then
        merchantSession = merchantSession + 1
        merchantOpen = gamepadModeActive()
        attempted = {}
        saleReportedSession = nil
        saleAttempts, saleSlotChanges, saleUnchanged = 0, 0, 0
        metadataRetries, merchantRetries = 0, 0
        pendingSale, lastScanReasons = nil, {}
        saleMissingAPI = nil
        if merchantOpen and db and db.autoSellGray then scheduleSale(merchantSession) end
    elseif event == "MERCHANT_CLOSED" then
        merchantSession = merchantSession + 1
        merchantOpen = false
    elseif event == "BAG_UPDATE_DELAYED" then
        if gamepadModeActive() and sortProbe and sortProbe.state == "await_sort" then
            sortProbe.preSortUpdates = sortProbe.preSortUpdates + 1
        elseif gamepadModeActive() and sortProbe and sortProbe.state == "sorting" then
            sortProbe.bagUpdates = sortProbe.bagUpdates + 1
            sortProbe.lastBagUpdateAt = sortClock()
            sortProbe.stableSamples = 0
        end
        if gamepadModeActive() and merchantOpen and db and db.autoSellGray then
            scheduleSale(merchantSession)
        end
    end
end)

addon:SetScript("OnUpdate", function(_, elapsed)
    local mode = gamepadModeActive()
    if lastGamepadMode ~= mode then
        lastGamepadMode = mode
        if not mode then
            merchantSession = merchantSession + 1
            merchantOpen = false
            pendingSale = nil
            sortProbeGeneration = sortProbeGeneration + 1
            if db and db.diagnostic then db.diagnostic.armed = false end
            if sortProbe and (sortProbe.state == "await_sort" or
                sortProbe.state == "sorting") then
                sortProbe.state = "cancelled"
                sortProbe.status = "mode-changed"
            end
        elseif not (InCombatLockdown and InCombatLockdown()) then
            installLayoutHooks()
            installSortHook()
        end
        refreshBagTitle()
    end
    if not mode then return end
    if layoutFrame and not shown(layoutFrame) and db and
        (barAnimation or db.bagBarExpanded or iconHighlightSeen) then
        -- Closing the panel only changes addon-owned state. Leave native
        -- control teardown entirely to Blizzard's OnHide handlers.
        controllerSelectionGeneration = controllerSelectionGeneration + 1
        iconHighlightSeen = false
        stopBarAnimation()
        db.bagBarExpanded = false
    end
    advanceBarAnimation(elapsed)
    if layoutFrame and shown(layoutFrame) and not layoutBusy and
        not layoutMutating and useOriginalLayout() and GamepadBagBar and
        GamepadBagBar.GetBagButton then
        local icon = GamepadBagBar:GetBagButton(0)
        if icon and safeLayoutObject(icon) then
            local selected = SmartNavigation and SmartNavigation.GetActiveFrame and
                SmartNavigation.GetCurrentButton and
                SmartNavigation:GetActiveFrame() == layoutFrame and
                SmartNavigation:GetCurrentButton() == icon
            local mouseOver = icon.IsMouseOver and icon:IsMouseOver()
            local highlighted = selected or mouseOver or false
            if highlighted ~= iconHighlightSeen then
                iconHighlightSeen = highlighted
                if highlighted then
                    -- Observe entry after native focus/hover handling. No
                    -- selection callback or replacement click script.
                    setBagBarExpanded(not db.bagBarExpanded)
                end
            end
        end
    end
    if not db or not db.diagnostic or not db.diagnostic.armed then return end
    diagnosticDuration = diagnosticDuration + elapsed
    if diagnosticDuration > 600 then
        db.diagnostic.armed = false
        say("Diagnostic timed out. Use /fnbag diag to start a fresh capture.")
        return
    end
    diagnosticElapsed = diagnosticElapsed + elapsed
    if diagnosticElapsed < 0.25 then return end
    diagnosticElapsed = 0
    diagnosticProbes = diagnosticProbes + 1
    if diagnosticProbes > MAX_DIAGNOSTIC_PROBES then
        db.diagnostic.armed = false
        say("Diagnostic timed out. Use /fnbag diag to start a fresh capture.")
        return
    end
    capture()
end)

SLASH_FRIDAYNIGHTBAGS1 = "/fnbag"
SLASH_FRIDAYNIGHTBAGS2 = "/fnb"
SlashCmdList.FRIDAYNIGHTBAGS = function(input)
    if not db then return end
    local command, rest = (input or ""):match("^%s*(%S*)%s*(.-)%s*$")
    command = command:lower()
    if not gamepadModeActive() and command ~= "on" and command ~= "off" and
        command ~= "keep" and command ~= "unkeep" and command ~= "list" and
        command ~= "layout" and command ~= "nav" and command ~= "navexport" and
        command ~= "navfix" and command ~= "navlayout" and
        command ~= "landscape" then
        say("Friday Night Bags actions are available only in gamepad UI mode.")
        return
    end
    if command == "on" then
        db.autoSellGray = true
        say("Gray-junk auto-sale ON; it runs when a merchant opens.")
        if merchantOpen and gamepadModeActive() then scheduleSale(merchantSession) end
    elseif command == "off" then
        db.autoSellGray = false
        merchantSession = merchantSession + 1
        say("Gray-junk auto-sale OFF.")
    elseif command == "keep" or command == "unkeep" then
        local id = itemIdFrom(rest)
        if not id then say("Provide an item link or numeric item ID."); return end
        db.keep[id] = command == "keep" or nil
        say("Item " .. id .. (command == "keep" and " protected." or " removed from keep-list."))
    elseif command == "list" then
        local ids = {}
        for id, active in pairs(db.keep) do if active then ids[#ids + 1] = id end end
        table.sort(ids)
        say(#ids == 0 and "Keep-list empty." or ("Protected item IDs: " .. table.concat(ids, ", ")))
    elseif command == "sort" then
        if InCombatLockdown and InCombatLockdown() then say("Sort after combat."); return end
        if C_Container and C_Container.SortBags then
            if not sortHookInstalled then onNativeSort() end
            C_Container.SortBags()
            say("Native bag sort requested.")
        else
            say("Native bag sorting is unavailable in this build.")
        end
    elseif command == "sortdiag" then
        if rest == "cancel" then
            sortProbeGeneration = sortProbeGeneration + 1
            if sortProbe and (sortProbe.state == "await_sort" or sortProbe.state == "sorting") then
                sortProbe.state = "cancelled"
                sortProbe.status = "cancelled"
                say("Native sort capture cancelled.")
            else
                say("No native sort capture is active.")
            end
        elseif rest == "" then
            if InCombatLockdown and InCombatLockdown() then
                say("Start the native sort capture after combat.")
                return
            end
            if not C_Container or not C_Container.GetContainerNumSlots or
                not C_Container.GetContainerItemInfo or not C_Container.SortBags or
                not C_Timer or not C_Timer.After or not GetTime then
                say("Native sort capture requires container, timer, and time APIs.")
                return
            end
            sortProbeGeneration = sortProbeGeneration + 1
            sortProbe = { state = "await_sort", status = "armed",
                before = sortSnapshot(), armedAt = sortClock(), preSortUpdates = 0 }
            db.sortProbe = sortProbe
            installSortHook()
            if sortHookInstalled then
                say("Native sort capture armed. Press the usual Organize/Cleanup Bags control once.")
            else
                say("Native control detection is unavailable. Use /fnbag sort once to capture the sort.")
            end
        else
            say("Use /fnbag sortdiag or /fnbag sortdiag cancel.")
        end
    elseif command == "sortexport" then
        exportSortProbe()
    elseif command == "layout" then
        if rest == "on" or rest == "off" then
            db.originalGamepadLayout = rest == "on"
            if rest == "off" then
                db.bagBarExpanded = false
                controllerSelectionGeneration = controllerSelectionGeneration + 1
                iconHighlightSeen = false
            end
            if rest == "on" then layoutFailed = nil end
            if gamepadModeActive() then
                installLayoutHooks()
                refreshOriginalLayout()
            end
            refreshBagTitle()
            say("Original-style gamepad layout " .. (db.originalGamepadLayout and "ON" or "OFF") ..
                ". /fnbag layout off restores Blizzard's layout.")
        else
            say("Use /fnbag layout on or /fnbag layout off.")
        end
    elseif command == "view" then
        db.viewMode = "grid"
        say("The combined bag now uses the grid view only.")
    elseif command == "bags" then
        if rest ~= "" and rest ~= "open" and rest ~= "close" then
            say("Use /fnbag bags, /fnbag bags open, or /fnbag bags close.")
            return
        end
        if InCombatLockdown and InCombatLockdown() then
            say("Change the bag bar after combat.")
            return
        end
        if not db.originalGamepadLayout then
            say("Enable the original-style layout first with /fnbag layout on.")
            return
        end
        if db.navLayout then
            say("Equipped bags stay visible in the geometry layout. /fnb navlayout off restores the collapsible strip.")
            return
        end
        setBagBarExpanded(rest == "open" or (rest == "" and not db.bagBarExpanded))
        say("Equipped-bag bar " .. (db.bagBarExpanded and "expanded." or "collapsed."))
    elseif command == "diag" then
        local mode = "1"
        db.diagnostic.views[mode] = nil
        db.diagnostic.armed = true
        diagnosticElapsed = 0
        diagnosticDuration = 0
        diagnosticProbes = 0
        FridayNightBagsExport = nil
        capture()
        if db.diagnostic.armed then say("Diagnostic armed for this UI mode. Open the combined bag once.") end
    elseif command == "export" then
        exportDiagnostic()
    elseif command == "nav" then
        if not C_Timer or type(C_Timer.After) ~= "function" then
            say("Navigation capture needs the timer API in this build.")
            return
        end
        navCaptureGeneration = navCaptureGeneration + 1
        local generation = navCaptureGeneration
        db.navProbe = nil
        say("Navigation capture in 3 seconds. Close chat and focus the open bags.")
        C_Timer.After(3, function()
            if generation ~= navCaptureGeneration or not db then return end
            local ok, report, columns, status = pcall(navReport)
            if not ok then
                db.navProbe = row("FNBNAV", "1", VERSION, "capture failed", navText(report))
                say("Navigation capture failed; report saved. Use /fnb navexport.")
                return
            end
            db.navProbe = report
            say("Navigation " .. status .. " (" .. columns ..
                " columns). Copy window opening; /fnb navexport reopens it.")
            exportNavReport()
        end)
    elseif command == "navexport" then
        exportNavReport()
    elseif command == "navfix" then
        say("Panel-state navigation experiment retired; Blizzard grid and wrapping stay native. Use /fnb navlayout on/off for the geometry test.")
    elseif command == "navlayout" then
        if rest == "on" or rest == "off" then
            db.navLayout = rest == "on"
            if gamepadModeActive() then
                installLayoutHooks()
                refreshOriginalLayout()
            end
        elseif rest ~= "" and rest ~= "status" then
            say("Use /fnb navlayout on, /fnb navlayout off, or /fnb navlayout status.")
            return
        end
        say("Geometry-only navigation layout " .. (db.navLayout and "ON" or "OFF") ..
            ". Blizzard navigation settings are untouched.")
    elseif command == "landscape" then
        if rest == "on" or rest == "off" then
            db.landscapeLayout = rest == "on"
            if gamepadModeActive() then
                installLayoutHooks()
                refreshOriginalLayout()
            end
        elseif rest ~= "" and rest ~= "status" then
            say("Use /fnb landscape on, /fnb landscape off, or /fnb landscape status.")
            return
        end
        local eligible = IsAccountSecured and not IsAccountSecured()
        say("Landscape experiment " .. (db.landscapeLayout and "ON" or "OFF") ..
            (eligible and "; uses eleven columns when four locked slots are present."
                or "; account secured, using seven columns."))
    else
        say("Gray-junk auto-sale " .. (db.autoSellGray and "ON" or "OFF") ..
            ". Commands: on, off, keep <item link/ID>, unkeep <item link/ID>, list, sort, sortdiag, sortexport, layout on/off, navlayout on/off, landscape on/off, bags, diag, export, nav, navexport.")
    end
end
