-- HealerProtection v1.1
-- Turtle WoW / Vanilla 1.12.1
--
-- Goals of this version:
-- * Native Vanilla-safe event handling (Lua 5.0 / 1.12 style globals).
-- * No hard dependency on ClassicAPI, SuperWoW or Nampower.
-- * Event-driven mana / health / death checks.
-- * Lightweight polling only for aggro, because Vanilla has no reliable threat event.
-- * Restored Near Death alerts.
-- * Centralized chat/channel validation.
-- * Removed dead bootstrap, translation and combat-lockdown code.

HealerProtection = HealerProtection or {}

local HP = HealerProtection
local DB = nil

local state = {
    oom = false,
    nearoom = false,
    neardeath = false,
    dead = false,
    aggro = false,
    channeling = false,
}

local warningAggro = nil
local lastLosTarget = ""
local nextLosMessage = 0

local DEFAULTS = {
    printnothing = false,
    showinraids = true,
    showoutsideofinstance = false,
    showinbgs = false,

    AGGRO = false,
    showaggrochat = true,
    showaggroemote = true,

    deathmessage = true,

    OOM = true,
    showoomchat = true,
    showoomemote = true,
    OOMPercentage = 10,

    NEAROOM = true,
    shownearoomchat = true,
    shownearoomemote = true,
    NEAROOMPercentage = 30,

    NEARDEATH = true,
    showneardeathchat = true,
    showneardeathemote = true,
    NEARDEATHPercentage = 30,

    notinsight = false,

    channelchat = "AUTO",
    prefix = "[Healer Protection]",
    suffix = "",
}

local TEXT = {
    aggro_warning = "You have aggro!",
    aggro_chat = "Aggro on me! Get it off!",
    oom = "I am OOM!",
    low_mana = "Low Mana!",
    low_health = "Help, I'm dying!",
    dead = "Healer is down... Fly, you fools!",
    los = "Target is not in line of sight",
}

-- ============================================================================
-- SMALL HELPERS
-- ============================================================================

local function Clamp(value, low, high)
    value = tonumber(value) or low
    if value < low then return low end
    if value > high then return high end
    return value
end

local function GetRaidCount()
    if GetNumRaidMembers then
        return GetNumRaidMembers() or 0
    end
    return 0
end

local function GetPartyCount()
    if GetNumPartyMembers then
        return GetNumPartyMembers() or 0
    end
    return 0
end

local function IsInBattleground()
    if not GetBattlefieldStatus then
        return false
    end

    local maxQueues = MAX_BATTLEFIELD_QUEUES or 3
    local i
    for i = 1, maxQueues do
        local status = GetBattlefieldStatus(i)
        if status == "active" then
            return true
        end
    end
    return false
end

local function IsInsideInstance()
    if not IsInInstance then
        -- Turtle WoW normally exposes IsInInstance(). If another 1.12 client
        -- does not, fail open rather than silently disabling the addon.
        return true
    end

    local inside = IsInInstance()
    return inside and true or false
end

local function GetMana()
    if UnitPower and UnitPowerMax then
        return UnitPower("player") or 0, UnitPowerMax("player") or 0
    end
    return UnitMana("player") or 0, UnitManaMax("player") or 0
end

local function PlayerUsesMana()
    if UnitPowerType then
        local _, token = UnitPowerType("player")
        return token == "MANA"
    end

    if UnitManaType then
        return UnitManaType("player") == 0
    end

    return true
end

local function Percent(value, maximum)
    if not maximum or maximum <= 0 then
        return 0
    end
    return math.floor((value * 1000 / maximum) + 0.5) / 10
end

local function IsChannelAllowed(channel)
    if channel == "SAY" or channel == "YELL" then
        return true
    end

    if channel == "GUILD" then
        return GetGuildInfo and GetGuildInfo("player") ~= nil
    end

    if channel == "RAID" then
        return GetRaidCount() > 0
    end

    if channel == "PARTY" then
        return GetPartyCount() > 0 or GetRaidCount() > 0
    end

    return false
end

function HP:GetCurrentChannel()
    local channel = DB.channelchat or "AUTO"

    if channel ~= "AUTO" then
        return channel
    end

    if GetRaidCount() > 0 then
        return "RAID"
    end

    if GetPartyCount() > 0 then
        return "PARTY"
    end

    -- AUTO deliberately resolves to PARTY while solo. The centralized
    -- validation below prevents invalid SendChatMessage calls.
    return "PARTY"
end

function HP:CanAnnounce(channel)
    if DB.printnothing then
        return false
    end

    if not IsChannelAllowed(channel) then
        return false
    end

    if not DB.showoutsideofinstance and not IsInsideInstance() then
        return false
    end

    if not DB.showinbgs and IsInBattleground() then
        return false
    end

    if not DB.showinraids and GetRaidCount() > 0 then
        return false
    end

    return true
end

local function CleanAffix(text, before)
    if not text or text == "" or text == " " then
        return ""
    end
    if before then
        return text .. " "
    end
    return " " .. text
end

function HP:Announce(message)
    if not message or message == "" then
        return false
    end

    local channel = self:GetCurrentChannel()
    if not self:CanAnnounce(channel) then
        return false
    end

    local prefix = CleanAffix(DB.prefix, true)
    local suffix = CleanAffix(DB.suffix, false)

    SendChatMessage(prefix .. message .. suffix, channel)
    return true
end

local function DoSafeEmote(emote)
    if not state.channeling and DoEmote then
        DoEmote(emote)
    end
end

-- ============================================================================
-- ALERT LOGIC
-- ============================================================================

function HP:CheckMana()
    if not PlayerUsesMana() then
        state.oom = false
        state.nearoom = false
        return
    end

    local mana, maxMana = GetMana()
    if maxMana <= 0 then
        return
    end

    local pct = Percent(mana, maxMana)
    local oomAt = Clamp(DB.OOMPercentage, 1, 99)
    local nearAt = Clamp(DB.NEAROOMPercentage, oomAt + 1, 99)

    -- OOM has priority. Mark near-OOM as already crossed so recovering from
    -- OOM does not immediately spam a second "Low Mana" warning.
    if DB.OOM and pct <= oomAt then
        if not state.oom then
            state.oom = true
            state.nearoom = true

            if DB.showoomchat then
                self:Announce(TEXT.oom .. " (" .. tostring(pct) .. "% Mana)")
            end
            if DB.showoomemote and self:CanAnnounce(self:GetCurrentChannel()) then
                DoSafeEmote("oom")
            end
        end
    elseif state.oom and pct > oomAt + 10 then
        state.oom = false
    end

    if DB.NEAROOM and not state.oom and pct <= nearAt and pct > oomAt then
        if not state.nearoom then
            state.nearoom = true

            if DB.shownearoomchat then
                self:Announce(TEXT.low_mana .. " (" .. tostring(pct) .. "% Mana)")
            end
            if DB.shownearoomemote and self:CanAnnounce(self:GetCurrentChannel()) then
                DoSafeEmote("incoming")
            end
        end
    elseif state.nearoom and pct > nearAt + 10 then
        state.nearoom = false
    end
end

function HP:CheckHealth()
    if UnitIsDead("player") then
        return
    end

    local health = UnitHealth("player") or 0
    local maxHealth = UnitHealthMax("player") or 0
    if maxHealth <= 0 then
        return
    end

    local pct = Percent(health, maxHealth)
    local threshold = Clamp(DB.NEARDEATHPercentage, 1, 99)

    if DB.NEARDEATH and pct <= threshold then
        if not state.neardeath then
            state.neardeath = true

            if DB.showneardeathchat then
                self:Announce(TEXT.low_health .. " (" .. tostring(pct) .. "% HP)")
            end
            if DB.showneardeathemote and self:CanAnnounce(self:GetCurrentChannel()) then
                DoSafeEmote("helpme")
            end
        end
    elseif state.neardeath and pct > threshold + 15 then
        state.neardeath = false
    end
end

function HP:HandleDeath()
    if state.dead then
        return
    end

    state.dead = true
    state.neardeath = false
    state.aggro = false

    if warningAggro then
        warningAggro:Hide()
    end

    if DB.deathmessage then
        self:Announce(TEXT.dead)
    end
end

function HP:HandleAlive()
    state.dead = false
    self:CheckHealth()
    self:CheckMana()
end

-- ============================================================================
-- AGGRO
-- ============================================================================

local function UnitTargetsPlayer(unit)
    if not UnitExists(unit) then
        return false
    end
    if UnitIsFriend("player", unit) then
        return false
    end

    local targetOfTarget = unit .. "target"
    return UnitExists(targetOfTarget) and UnitIsUnit(targetOfTarget, "player")
end

local function GetAggroState()
    -- Use a real threat API if the client/API extension supplies one.
    if UnitThreatSituation then
        local status = UnitThreatSituation("player")
        if status and status > 0 then
            return true
        end
    end

    -- Native Vanilla fallback: inspect the player's current hostile target.
    if UnitTargetsPlayer("target") then
        return true
    end

    -- Improve the old target-only fallback without any dependency:
    -- inspect hostile targets currently selected by party/raid members.
    local raidCount = GetRaidCount()
    local i

    if raidCount > 0 then
        for i = 1, raidCount do
            if UnitTargetsPlayer("raid" .. i .. "target") then
                return true
            end
        end
    else
        local partyCount = GetPartyCount()
        for i = 1, partyCount do
            if UnitTargetsPlayer("party" .. i .. "target") then
                return true
            end
        end
    end

    return false
end

function HP:CheckAggro()
    if not DB.AGGRO or UnitIsDead("player") then
        if state.aggro then
            state.aggro = false
            if warningAggro then warningAggro:Hide() end
        end
        return
    end

    local hasAggro = GetAggroState()

    if hasAggro and not state.aggro then
        state.aggro = true

        if DB.showaggrochat then
            self:Announce("{rt8} " .. TEXT.aggro_chat)
        end
        if DB.showaggroemote and self:CanAnnounce(self:GetCurrentChannel()) then
            DoSafeEmote("helpme")
        end

        if warningAggro then
            warningAggro:Show()
        end
    elseif not hasAggro and state.aggro then
        state.aggro = false
        if warningAggro then
            warningAggro:Hide()
        end
    end
end

-- ============================================================================
-- UI / SETTINGS
-- ============================================================================

function HP:CreateGUI()
    if HPOptionsFrame then
        return HPOptionsFrame
    end

    local f = CreateFrame("Frame", "HPOptionsFrame", UIParent)
    f:SetWidth(430)
    f:SetHeight(850)
    f:SetPoint("CENTER", UIParent, "CENTER")
    f:SetBackdrop({
        bgFile = "Interface\\DialogFrame\\UI-DialogBox-Background",
        edgeFile = "Interface\\DialogFrame\\UI-DialogBox-Border",
        tile = true,
        tileSize = 32,
        edgeSize = 32,
        insets = { left = 11, right = 12, top = 12, bottom = 11 }
    })
    f:SetMovable(true)
    f:EnableMouse(true)
    f:RegisterForDrag("LeftButton")
    f:SetScript("OnDragStart", function() f:StartMoving() end)
    f:SetScript("OnDragStop", function() f:StopMovingOrSizing() end)
    f:SetFrameStrata("DIALOG")
    f:Hide()

    f.title = f:CreateFontString(nil, "OVERLAY", "GameFontNormalLarge")
    f.title:SetPoint("TOP", 0, -18)
    f.title:SetText("Healer Protection - Settings")

    local btnClose = CreateFrame("Button", nil, f, "UIPanelButtonTemplate")
    btnClose:SetWidth(100)
    btnClose:SetHeight(24)
    btnClose:SetPoint("BOTTOM", 0, 16)
    btnClose:SetText("Close")
    btnClose:SetScript("OnClick", function() f:Hide() end)

    local function CreateCheckbox(name, label, key, x, y)
        local cb = CreateFrame("CheckButton", "HPCB_" .. name, f, "UICheckButtonTemplate")
        cb:SetPoint("TOPLEFT", x, y)
        getglobal(cb:GetName() .. "Text"):SetText(label)
        getglobal(cb:GetName() .. "Text"):SetTextColor(1, 1, 1)

        cb:SetScript("OnShow", function()
            cb:SetChecked(DB[key] and 1 or nil)
        end)

        cb:SetScript("OnClick", function()
            DB[key] = cb:GetChecked() == 1
            if key == "AGGRO" and not DB.AGGRO then
                state.aggro = false
                if warningAggro then warningAggro:Hide() end
            end
        end)

        return cb
    end

    local function CreateSlider(name, labelFormat, key, minValue, maxValue, y)
        local slider = CreateFrame("Slider", "HPSL_" .. name, f, "OptionsSliderTemplate")
        slider:SetPoint("TOP", 0, y)
        slider:SetWidth(330)
        slider:SetHeight(16)
        slider:SetOrientation("HORIZONTAL")
        slider:SetMinMaxValues(minValue, maxValue)
        slider:SetValueStep(1)

        getglobal(slider:GetName() .. "Low"):SetText(tostring(minValue))
        getglobal(slider:GetName() .. "High"):SetText(tostring(maxValue))

        local label = getglobal(slider:GetName() .. "Text")

        local function UpdateLabel(value)
            label:SetText(string.format(labelFormat, value))
        end

        slider:SetScript("OnShow", function()
            slider:SetValue(DB[key])
            UpdateLabel(DB[key])
        end)

        slider:SetScript("OnValueChanged", function()
            local value = arg1
            if value == nil then value = slider:GetValue() end
            value = math.floor(value + 0.5)
            DB[key] = value
            UpdateLabel(value)
        end)

        return slider
    end

    local function CreateEditBox(labelText, globalName, x, y, width, key)
        local label = f:CreateFontString(nil, "OVERLAY", "GameFontNormal")
        label:SetPoint("TOPLEFT", x, y)
        label:SetText(labelText)

        local eb = CreateFrame("EditBox", globalName, f, "InputBoxTemplate")
        eb:SetWidth(width)
        eb:SetHeight(20)
        eb:SetPoint("TOPLEFT", x + 4, y - 18)
        eb:SetAutoFocus(false)

        eb:SetScript("OnShow", function()
            eb:SetText(DB[key] or "")
        end)

        local function Save()
            DB[key] = eb:GetText() or ""
        end

        eb:SetScript("OnEnterPressed", function()
            Save()
            eb:ClearFocus()
        end)
        eb:SetScript("OnEditFocusLost", Save)

        return eb
    end

    local function CreateChannelDropdown(x, y)
        local label = f:CreateFontString(nil, "OVERLAY", "GameFontNormal")
        label:SetPoint("TOPLEFT", x, y)
        label:SetText("Announce Channel")

        local dropdown = CreateFrame("Frame", "HPChannelDropDown", f, "UIDropDownMenuTemplate")
        dropdown:SetPoint("TOPLEFT", x - 16, y - 18)
        UIDropDownMenu_SetWidth(120, dropdown)

        local channels = { "AUTO", "SAY", "YELL", "PARTY", "RAID", "GUILD" }

        local function OnClick()
            DB.channelchat = this.value
            UIDropDownMenu_SetSelectedValue(dropdown, this.value)
            UIDropDownMenu_SetText(this.value, dropdown)
        end

        local function Initialize()
            local i
            for i = 1, table.getn(channels) do
                local info = {}
                info.text = channels[i]
                info.value = channels[i]
                info.func = OnClick
                UIDropDownMenu_AddButton(info)
            end
        end

        UIDropDownMenu_Initialize(dropdown, Initialize)
        UIDropDownMenu_SetSelectedValue(dropdown, DB.channelchat)
        UIDropDownMenu_SetText(DB.channelchat, dropdown)

        return dropdown
    end

    CreateCheckbox("PrintNothing", "Print Nothing", "printnothing", 20, -45)
    CreateCheckbox("ShowInRaid", "Show in Raids", "showinraids", 20, -70)
    CreateCheckbox("Outside", "Show outside instances", "showoutsideofinstance", 20, -95)
    CreateCheckbox("ShowInBG", "Show in Battlegrounds", "showinbgs", 20, -120)
    CreateCheckbox("LineOfSight", "Line-of-sight chat warning", "notinsight", 20, -145)

    CreateCheckbox("Aggro", "AGGRO", "AGGRO", 20, -180)
    CreateCheckbox("AggroChat", "AGGRO Chat-Message", "showaggrochat", 40, -205)
    CreateCheckbox("AggroEmote", "AGGRO Emote", "showaggroemote", 40, -230)
    CreateCheckbox("DeathMessage", "Death message", "deathmessage", 20, -255)

    CreateCheckbox("OOM", "Out of Mana", "OOM", 20, -290)
    CreateCheckbox("OOMChat", "OOM Chat-Message", "showoomchat", 40, -315)
    CreateCheckbox("OOMEmote", "OOM Emote", "showoomemote", 40, -340)
    CreateSlider("OomPerc", "If under %d%% Mana, OOM alert", "OOMPercentage", 1, 20, -380)

    CreateCheckbox("NearOOM", "Near out of Mana", "NEAROOM", 20, -430)
    CreateCheckbox("NearOOMChat", "Near OOM Chat-Message", "shownearoomchat", 40, -455)
    CreateCheckbox("NearOOMEmote", "Near OOM Emote", "shownearoomemote", 40, -480)
    CreateSlider("NearOomPerc", "If under %d%% Mana, low-mana alert", "NEAROOMPercentage", 5, 50, -520)

    CreateCheckbox("NearDeath", "Near Death", "NEARDEATH", 20, -570)
    CreateCheckbox("NearDeathChat", "Near Death Chat-Message", "showneardeathchat", 40, -595)
    CreateCheckbox("NearDeathEmote", "Near Death Emote", "showneardeathemote", 40, -620)
    CreateSlider("NearDeathPerc", "If under %d%% Health, danger alert", "NEARDEATHPercentage", 5, 60, -660)

    CreateChannelDropdown(20, -710)

    CreateEditBox("Prefix", "HPEB_Prefix", 20, -770, 175, "prefix")
    CreateEditBox("Suffix", "HPEB_Suffix", 220, -770, 175, "suffix")

    return f
end

SLASH_HEALERPROTECTION1 = "/hp"
SLASH_HEALERPROTECTION2 = "/healerprotection"
SlashCmdList["HEALERPROTECTION"] = function()
    if not HPOptionsFrame then
        HP:CreateGUI()
    end

    if HPOptionsFrame:IsVisible() then
        HPOptionsFrame:Hide()
    else
        HPOptionsFrame:Show()
    end
end

-- ============================================================================
-- INITIALIZATION / EVENTS
-- ============================================================================

local function InitializeDatabase()
    HPTABPC = HPTABPC or {}
    DB = HPTABPC

    local key, value
    for key, value in pairs(DEFAULTS) do
        if DB[key] == nil then
            DB[key] = value
        end
    end

    DB.OOMPercentage = Clamp(DB.OOMPercentage, 1, 20)
    DB.NEAROOMPercentage = Clamp(DB.NEAROOMPercentage, 5, 50)
    if DB.NEAROOMPercentage <= DB.OOMPercentage then
        DB.NEAROOMPercentage = math.min(50, DB.OOMPercentage + 10)
    end
    DB.NEARDEATHPercentage = Clamp(DB.NEARDEATHPercentage, 5, 60)
end

local function CreateAggroWarning()
    warningAggro = CreateFrame("Frame", nil, UIParent)
    warningAggro:SetFrameStrata("HIGH")
    warningAggro:SetWidth(220)
    warningAggro:SetHeight(40)
    warningAggro:SetPoint("CENTER", UIParent, "CENTER", 0, 300)

    warningAggro.text = warningAggro:CreateFontString(nil, "OVERLAY")
    local font = STANDARD_TEXT_FONT or "Fonts\\FRIZQT__.TTF"
    warningAggro.text:SetFont(font, 20, "OUTLINE")
    warningAggro.text:SetPoint("CENTER", warningAggro, "CENTER", 0, 0)
    warningAggro.text:SetText(TEXT.aggro_warning)
    warningAggro.text:SetTextColor(1, 0, 0, 1)
    warningAggro:Hide()
end

local eventFrame = CreateFrame("Frame")
eventFrame:RegisterEvent("PLAYER_LOGIN")
eventFrame:RegisterEvent("PLAYER_DEAD")
eventFrame:RegisterEvent("PLAYER_ALIVE")
eventFrame:RegisterEvent("PLAYER_UNGHOST")
eventFrame:RegisterEvent("UNIT_MANA")
eventFrame:RegisterEvent("UNIT_MAXMANA")
eventFrame:RegisterEvent("UNIT_HEALTH")
eventFrame:RegisterEvent("UNIT_MAXHEALTH")
eventFrame:RegisterEvent("SPELLCAST_CHANNEL_START")
eventFrame:RegisterEvent("SPELLCAST_CHANNEL_STOP")
eventFrame:RegisterEvent("SPELLCAST_STOP")
eventFrame:RegisterEvent("UI_ERROR_MESSAGE")

eventFrame:SetScript("OnEvent", function()
    local e = event
    local a1 = arg1

    if e == "PLAYER_LOGIN" then
        InitializeDatabase()
        CreateAggroWarning()
        HP:CheckMana()
        HP:CheckHealth()
        DEFAULT_CHAT_FRAME:AddMessage("|cFF00FF00[Healer Protection]|r v1.1 ready. Type |cFFFFFF00/hp|r to configure.")
        return
    end

    if not DB then
        return
    end

    if e == "PLAYER_DEAD" then
        HP:HandleDeath()
        return
    end

    if e == "PLAYER_ALIVE" or e == "PLAYER_UNGHOST" then
        HP:HandleAlive()
        return
    end

    if e == "UNIT_MANA" or e == "UNIT_MAXMANA" then
        if a1 == "player" then
            HP:CheckMana()
        end
        return
    end

    if e == "UNIT_HEALTH" or e == "UNIT_MAXHEALTH" then
        if a1 == "player" then
            HP:CheckHealth()
        end
        return
    end

    if e == "SPELLCAST_CHANNEL_START" then
        state.channeling = true
        return
    end

    if e == "SPELLCAST_CHANNEL_STOP" or e == "SPELLCAST_STOP" then
        state.channeling = false
        return
    end

    if e == "UI_ERROR_MESSAGE" and DB.notinsight then
        local errMessage = a1
        if errMessage and SPELL_FAILED_LINE_OF_SIGHT and errMessage == SPELL_FAILED_LINE_OF_SIGHT then
            local targetName = UnitName("target")
            if targetName and UnitIsFriend("player", "target") then
                local now = GetTime()
                if targetName ~= lastLosTarget or now >= nextLosMessage then
                    lastLosTarget = targetName
                    nextLosMessage = now + 1
                    HP:Announce(TEXT.los .. " (" .. targetName .. ")")
                end
            end
        end
    end
end)

-- Aggro is the only feature that requires polling on Vanilla.
-- Keep the OnUpdate handler extremely cheap and return immediately when disabled.
local aggroFrame = CreateFrame("Frame")
local aggroElapsed = 0
aggroFrame:SetScript("OnUpdate", function()
    if not DB or not DB.AGGRO then
        return
    end

    aggroElapsed = aggroElapsed + (arg1 or 0)
    if aggroElapsed < 0.75 then
        return
    end

    aggroElapsed = 0
    HP:CheckAggro()
end)
