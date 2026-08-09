-- HealerProtection Vanilla / Turtle WoW Port
-- Ported for the 1.12.1 client (with SuperWow / ClassicAPI support)
-- Optimized version: cached lookups, removed unused temp table, fixed NEARDEATH bug, removed role detection (Force Healer bypass always on)
-- Optimization pass 2: SETOOMP getglobal only runs when actually needed, GetLang()/GetLocale() cached
-- in ToCurrentChat instead of being recomputed up to 5 times, IsPlayerInBG() cache shared with CanWriteToChat

HealerProtection = HealerProtection or {}
local HPDEBUG = false
local warning_aggro = nil
local nearoom = false
local oom = false
local aggro = false
local isdead = false
local isChanneling = false
local onceM1 = false
local onceM2 = false
local lasttarget = ""
local delayrange = GetTime()
local outsideOfGroup = false

-- ============================================================================
-- UTILS AND VANILLA 1.12 COMPATIBILITY
-- ============================================================================

-- Cleanly retrieves the number of group members
local function GetGroupMembersCount()
if GetNumGroupMembers then return GetNumGroupMembers() end
local raid = GetNumRaidMembers()
if raid > 0 then return raid end
return GetNumPartyMembers()
end

-- Checks if the player is in a battleground
local function IsPlayerInBG()
for i = 1, (MAX_BATTLEFIELD_QUEUES or 3) do
local status = GetBattlefieldStatus(i)
if status == "active" then
return true
end
end
return false
end

-- Mana resource abstraction
local function GetUnitPower(unit)
if UnitPower then return UnitPower(unit) end
return UnitMana(unit)
end

local function GetUnitPowerMax(unit)
if UnitPowerMax then return UnitPowerMax(unit) end
return UnitManaMax(unit)
end

local function GetUnitPowerType(unit)
if UnitPowerType then
local _, token = UnitPowerType(unit)
return token
end
local t = UnitManaType(unit)
if t == 0 then return "MANA" end
return "OTHER"
end

-- Safe wrapper for C_Timer.After
local function SafeAfter(delay, func)
if C_Timer and C_Timer.After then
C_Timer.After(delay, func)
else
local fAfter = CreateFrame("Frame")
local elapsed_time = 0
fAfter:SetScript("OnUpdate", function(self, elapsed)
local dt = elapsed or arg1 or 0
elapsed_time = elapsed_time + dt
if elapsed_time >= delay then
fAfter:SetScript("OnUpdate", nil)
func()
end
end)
end
end

-- Simplified aggro detection (adapts if SuperWow is installed)
local function GetThreatSituation()
if UnitThreatSituation then
return UnitThreatSituation("player")
else
if UnitExists("target") and not UnitIsFriend("player", "target") then
if UnitIsUnit("targettarget", "player") then
return 3
end
end
return 0
end
end

-- ============================================================================
-- HEALERPROTECTION FUNCTIONS
-- ============================================================================

-- Optimization: accepts an already computed channel to avoid recomputing GetCurrentChannel()
-- on every single call (PrintChat can call this up to 6 times per tick)
function HealerProtection:AllowedTo(cachedChannel)
local channel = cachedChannel or HealerProtection:GetCurrentChannel()

if HealerProtection:DBGV("printnothing", false) then
return false
end

-- SAY and YELL don't require being in a party/raid/guild to make sense
if channel == "SAY" or channel == "YELL" then
return true
end

-- GUILD requires actually being in a guild
if channel == "GUILD" then
if GetGuildInfo("player") ~= nil or HPDEBUG then
return true
end
if outsideOfGroup == false then
outsideOfGroup = true
HealerProtection:INFO("Not in a Guild")
end
return false
end

-- RAID requires actually being in a raid (being in a simple party is not enough)
if channel == "RAID" then
if GetNumRaidMembers() > 0 or HPDEBUG then
return true
end
if outsideOfGroup == false then
outsideOfGroup = true
HealerProtection:INFO("Not in a Raid")
end
return false
end

-- PARTY (and AUTO, already resolved to PARTY/RAID by GetCurrentChannel)
if GetGroupMembersCount() > 0 or HPDEBUG then
return true
end

if outsideOfGroup == false then
outsideOfGroup = true
HealerProtection:INFO("Not in a Party/Raid")
end

return false
end

function HealerProtection:GetCurrentChannel()
local _channel = "PARTY"
if HealerProtection:DBGV("channelchat", "AUTO") == "AUTO" then
if GetNumRaidMembers() > 0 then
_channel = "RAID"
elseif GetNumPartyMembers() > 0 then
_channel = "PARTY"
end
else
_channel = HealerProtection:DBGV("channelchat", "AUTO")
end

return _channel
end

function HealerProtection:InInstance()
if HPDEBUG then return true end
local is, _ = IsInInstance()
return is
end

-- Optimization: accepts an already computed inInstance to avoid a redundant call to InInstance()
-- Optimization: accepts an already computed inBG to avoid a redundant call to IsPlayerInBG()
function HealerProtection:CanWriteToChat(chan, cachedInInstance, cachedInBG)
local inInstance = cachedInInstance
if inInstance == nil then
inInstance = HealerProtection:InInstance()
end

local inBG = cachedInBG
if inBG == nil then
inBG = IsPlayerInBG()
end

if onceM1 and not inInstance and HealerProtection:DBGV("showoutsideofinstance", false) == false then
onceM1 = false
HealerProtection:MSG("Only shows Messages in Instances.")
end

if inInstance or HealerProtection:DBGV("showoutsideofinstance", false) then
if HealerProtection:DBGV("printnothing", false) == true then
if onceM2 then
onceM2 = false
HealerProtection:MSG("\"Print Nothing\" is enabled.")
end

return false
elseif inBG and HealerProtection:DBGV("showinbgs", false) == false then
return false
elseif (GetNumRaidMembers() > 0) and HealerProtection:DBGV("showinraids", true) == false then
return false
else
return true
end
end

return false
end

function HealerProtection:GetLang()
-- Optimization: GetLocale() cached once instead of being called up to 3 times below
local locale = GetLocale()
if locale == "enUS" then return locale end
if HealerProtection:DBGV("showonlyenglish", false) then return "enUS" end
if HealerProtection:DBGV("showonlytranslation", false) then return locale end
if HealerProtection:DBGV("showtranslation", true) then return "enUS," .. locale end

return "enUS"
end

function HealerProtection:ToCurrentChat(formatStr, val1text, val1val, val2text, val2val, cachedChannel, cachedInInstance, cachedInBG)
local inInstance = cachedInInstance
if inInstance == nil then
inInstance = HealerProtection:InInstance()
end

-- Optimization: computed once here and passed down to CanWriteToChat below,
-- instead of letting IsPlayerInBG() run a second time inside it.
local inBG = cachedInBG
if inBG == nil then
inBG = IsPlayerInBG()
end

local _channel = cachedChannel or HealerProtection:GetCurrentChannel()
local prefix = HealerProtection:DBGV("prefix", "[Healer Protection]")
local suffix = HealerProtection:DBGV("suffix", "")
if prefix ~= "" and prefix ~= " " then
prefix = prefix .. " "
elseif prefix == " " then
prefix = ""
end

if suffix ~= "" and suffix ~= " " then
suffix = " " .. suffix
elseif suffix == " " then
suffix = ""
end

-- Optimization: reuse of already computed inInstance / inBG, avoids extra calls
if HealerProtection:CanWriteToChat(_channel, inInstance, inBG) then
-- Optimization: GetLang() and GetLocale() cached once instead of being recomputed
-- (each re-running its own DBGV / GetLocale lookups) up to 5 times in the block below
local lang = HealerProtection:GetLang()
local locale = GetLocale()
local msg = ""
if lang == "enUS" then
if val2text then
msg = string.format(formatStr, HealerProtection:TryTrans(val1text, "enUS", val1val), HealerProtection:TryTrans(val2text, "enUS", val2val))
elseif val1text then
msg = string.format(formatStr, HealerProtection:TryTrans(val1text, "enUS", val1val))
end
elseif lang == locale then
if val2text then
msg = string.format(formatStr, HealerProtection:TryTrans(val1text, locale, val1val), HealerProtection:TryTrans(val2text, locale, val2val))
elseif val1text then
msg = string.format(formatStr, HealerProtection:TryTrans(val1text, locale, val1val))
end
else
if val2text then
msg = string.format(formatStr, HealerProtection:TryTrans(val1text, "enUS", val1val), HealerProtection:TryTrans(val2text, "enUS", val2val))
elseif val1text then
msg = string.format(formatStr, HealerProtection:TryTrans(val1text, "enUS", val1val))
end

if val2text then
msg = msg .. " [" .. string.format(formatStr, HealerProtection:TryTrans(val1text, locale, val1val), HealerProtection:TryTrans(val2text, locale, val2val)) .. "]"
elseif val1text then
msg = msg .. " [" .. string.format(formatStr, HealerProtection:TryTrans(val1text, locale, val1val)) .. "]"
end
end

local mes = prefix .. msg .. "." .. suffix
if mes ~= nil then
if SendChatMessage then
SendChatMessage(mes, _channel)
end
end
end
end

function HealerProtection:Setup()
if HealerProtection:IsSetup() then
if not InCombatLockdown() then
HPTABPC = HPTABPC or {}
HealerProtection:SetSetup(false)

warning_aggro = CreateFrame("Frame", nil, UIParent)
warning_aggro:SetFrameStrata("BACKGROUND")
warning_aggro:SetWidth(128)
warning_aggro:SetHeight(64)
warning_aggro.text = warning_aggro:CreateFontString(nil, "ARTWORK")

local font = STANDARD_TEXT_FONT or "Fonts\\FRIZQT__.TTF"
warning_aggro.text:SetFont(font, 20, "OUTLINE")
warning_aggro.text:SetPoint("CENTER", 0, 300)
warning_aggro.text:SetText(HealerProtection:Trans("LID_youhaveaggro") .. "!")
warning_aggro.text:SetTextColor(1, 0, 0, 1)
warning_aggro:SetPoint("CENTER", 0, 0)
warning_aggro:Hide()

local f = CreateFrame("Frame")
f:RegisterEvent("UI_ERROR_MESSAGE")
f:SetScript("OnEvent", function(self, event, a1)
local errMessage = a1 or arg1
if event == "UI_ERROR_MESSAGE" and errMessage == SPELL_FAILED_LINE_OF_SIGHT then
local TName = UnitName("target")
if TName and UnitIsFriend("player", "target") then
if lasttarget ~= TName or delayrange < GetTime() then
delayrange = GetTime() + 1
lasttarget = TName
if HealerProtection:DBGV("notinsight", false) then
local tex = "Target is not in the field of view (" .. TName .. ")"
if HealerProtection:DBGV("showtranslation", true) and GetLocale() ~= "enUS" then
tex = tex .. " [" .. errMessage .. " (" .. TName .. ")]"
end

HealerProtection:ToCurrentChat("%s", tex)
end
end
end
end
end)

local channeling = CreateFrame("Frame")
channeling:RegisterEvent("SPELLCAST_CHANNEL_START")
channeling:RegisterEvent("SPELLCAST_CHANNEL_STOP")
channeling:SetScript("OnEvent", function(self, event)
if event == "SPELLCAST_CHANNEL_START" then
isChanneling = true
elseif event == "SPELLCAST_CHANNEL_STOP" then
isChanneling = false
end
end)

HealerProtection:SetDbTab(HPTABPC)
HealerProtection:InitSetting()

if C_Timer and C_Timer.NewTicker then
C_Timer.NewTicker(1, function() HealerProtection:PrintChat() end)
else
local tickerFrame = CreateFrame("Frame")
local elapsed_time = 0
tickerFrame:SetScript("OnUpdate", function(self, elapsed)
local dt = elapsed or arg1 or 0
elapsed_time = elapsed_time + dt
if elapsed_time >= 1 then
elapsed_time = 0
HealerProtection:PrintChat()
end
end)
end
else
SafeAfter(0.1, function() HealerProtection:Setup() end)
end
end
end

function HealerProtection:PrintChat()
-- Optimization: OOM / NEAROOM thresholds are cached once per tick
local oomPerc = HealerProtection:DBGV("OOMPercentage", 10)
local nearOomPerc = HealerProtection:DBGV("NEAROOMPercentage", 30)

-- Optimization: getglobal("SETOOMP") now only runs when the thresholds are actually
-- misconfigured (oomPerc > nearOomPerc). With default settings (10 <= 30) that's false,
-- so before this change the getglobal lookup ran uselessly every single second, forever.
if oomPerc > nearOomPerc then
local SETOOMP = getglobal("SETOOMP")
if SETOOMP ~= nil and not InCombatLockdown() then
HPTABPC["OOMPercentage"] = nearOomPerc
SETOOMP:SetValue(HPTABPC["OOMPercentage"])
oomPerc = nearOomPerc
end
end

local inInstance = HealerProtection:InInstance()
local inBG = IsPlayerInBG()
local _channel = HealerProtection:GetCurrentChannel()
if not HealerProtection:CanWriteToChat(_channel, inInstance, inBG) then return end

if HealerProtection:IsLoaded() then
-- Role detection removed: the "Force Healer" bypass is now always active,
-- so there is no need to check the player's class/role here anymore.
-- Note: "printnothing" is already checked inside CanWriteToChat right above,
-- so if we reach this point it is guaranteed to be false -- no need to test it again.

-- Optimization: AllowedTo() only depends on the channel/group/guild/raid state,
-- none of which can change mid-tick, so it's computed once and reused below
-- instead of being called up to 6 times per tick (chat + emote x3 alerts).
local canAnnounce = HealerProtection:AllowedTo(_channel)

if not UnitIsDead("player") then
isdead = false

-- AGGRO LOGIC
if HealerProtection:DBGV("AGGRO", false) then
local status = GetThreatSituation()
if status ~= nil then
if status > 0 and not aggro then
if HealerProtection:DBGV("showaggrochat", true) and canAnnounce then
HealerProtection:ToCurrentChat("{rt8} %s", "LID_ihaveaggro", nil, nil, nil, _channel, inInstance, inBG)
end

if HealerProtection:DBGV("showaggroemote", true) and canAnnounce and not isChanneling then
DoEmote("helpme")
end

aggro = true
elseif status == 0 and aggro then
aggro = false
end
else
aggro = false
end

if warning_aggro then
if aggro then
warning_aggro:Show()
else
warning_aggro:Hide()
end
end
else
if warning_aggro then
warning_aggro:Hide()
end
end

-- MANA AND HEALTH LOGIC
local powerToken = GetUnitPowerType("player")
if powerToken == "MANA" then
local mana = GetUnitPower("player")
local manamax = GetUnitPowerMax("player")
local manaperc = HealerProtection:MathR((mana / manamax) * 100, 1)

-- OOM Alert (without percentage)
if HealerProtection:DBGV("OOM", true) then
if manaperc <= oomPerc and not oom then
oom = true
if HealerProtection:DBGV("showoomchat", true) and canAnnounce then
HealerProtection:ToCurrentChat("%s (%s)", "LID_outofmana", nil, "LID_xmana", manaperc, _channel, inInstance, inBG)
end

if HealerProtection:DBGV("showoomemote", true) and canAnnounce and not isChanneling then
DoEmote("oom")
end
elseif manaperc > oomPerc + 20 and oom then
oom = false
end
end

-- Near-OOM Alert (without percentage)
if HealerProtection:DBGV("NEAROOM", true) and not oom then
if manaperc <= nearOomPerc and not nearoom then
nearoom = true
if HealerProtection:DBGV("shownearoomchat", true) and canAnnounce then
HealerProtection:ToCurrentChat("%s (%s)", "LID_nearoutofmana", nil, "LID_xmana", manaperc, _channel, inInstance, inBG)
end

if HealerProtection:DBGV("shownearoomemote", true) and canAnnounce and not isChanneling then
DoEmote("incoming")
end
elseif manaperc > nearOomPerc + 20 and nearoom then
nearoom = false
end
end

end
elseif not isdead then
isdead = true
if HealerProtection:DBGV("deathmessage", true) then
HealerProtection:ToCurrentChat("%s", "LID_healerisdead", nil, nil, nil, _channel, inInstance, inBG)
end
end
end
end

-- ============================================================================
-- SETTINGS WINDOW AND SLASH COMMANDS (HOMEMADE FOR 1.12)
-- ============================================================================

function HealerProtection:DBGV(key, default)
if HPTABPC and HPTABPC[key] ~= nil then
return HPTABPC[key]
end
return default
end

SLASH_HEALERPROTECTION1 = "/hp"
SLASH_HEALERPROTECTION2 = "/healerprotection"
SlashCmdList["HEALERPROTECTION"] = function(msg)
if HPOptionsFrame and HPOptionsFrame:IsVisible() then
HPOptionsFrame:Hide()
else
if not HPOptionsFrame then
HealerProtection:CreateGUI()
end
HPOptionsFrame:Show()
end
end

function HealerProtection:CreateGUI()
local f = CreateFrame("Frame", "HPOptionsFrame", UIParent)
f:SetWidth(400)
f:SetHeight(755)
f:SetPoint("CENTER", UIParent, "CENTER")
f:SetBackdrop({
bgFile = "Interface\\DialogFrame\\UI-DialogBox-Background",
edgeFile = "Interface\\DialogFrame\\UI-DialogBox-Border",
tile = true, tileSize = 32, edgeSize = 32,
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

-- ------------------------------------------------------------------
-- Helpers
-- ------------------------------------------------------------------

local function CreateCheckbox(name, label, dbKey, defaultValue, xOffset, yOffset)
local cb = CreateFrame("CheckButton", "HPCB_"..name, f, "UICheckButtonTemplate")
cb:SetPoint("TOPLEFT", xOffset, yOffset)
getglobal(cb:GetName().."Text"):SetText(label)
getglobal(cb:GetName().."Text"):SetTextColor(1, 1, 1)

cb:SetScript("OnShow", function()
local val = HPTABPC[dbKey]
if val == nil then val = defaultValue end
cb:SetChecked(val and 1 or nil)
end)

cb:SetScript("OnClick", function()
local isChecked = (cb:GetChecked() == 1)
HPTABPC[dbKey] = isChecked
end)
return cb
end

-- labelFormat must contain one "%d" placeholder for the current value, e.g. "If under %d%% Health, print message"
local function CreateSlider(name, labelFormat, dbKey, defaultValue, minVal, maxVal, yOffset)
local slider = CreateFrame("Slider", "HPSL_"..name, f, "OptionsSliderTemplate")
slider:SetPoint("TOP", 0, yOffset)
slider:SetWidth(320)
slider:SetHeight(16)
slider:SetOrientation("HORIZONTAL")
slider:SetMinMaxValues(minVal, maxVal)
slider:SetValueStep(1)

getglobal(slider:GetName().."Low"):SetText(tostring(minVal))
getglobal(slider:GetName().."High"):SetText(tostring(maxVal))
local sliderLabel = getglobal(slider:GetName().."Text")

local function UpdateLabel(val)
sliderLabel:SetText(string.format(labelFormat, val))
end

slider:SetScript("OnShow", function()
local val = HPTABPC[dbKey]
if val == nil then val = defaultValue end
slider:SetValue(val)
UpdateLabel(val)
end)

slider:SetScript("OnValueChanged", function()
local val = arg1
if val == nil then val = slider:GetValue() end
val = math.floor(val + 0.5)
HPTABPC[dbKey] = val
UpdateLabel(val)
end)

return slider
end

local function CreateEditBox(name, xOffset, yOffset, width, dbKey, defaultValue)
local labelFS = f:CreateFontString(nil, "OVERLAY", "GameFontNormal")
labelFS:SetPoint("TOPLEFT", xOffset, yOffset)
labelFS:SetText(name)

local eb = CreateFrame("EditBox", "HPEB_"..name, f, "InputBoxTemplate")
eb:SetWidth(width)
eb:SetHeight(20)
eb:SetPoint("TOPLEFT", xOffset + 4, yOffset - 18)
eb:SetAutoFocus(false)

eb:SetScript("OnShow", function()
local val = HPTABPC[dbKey]
if val == nil then val = defaultValue end
eb:SetText(val)
end)

eb:SetScript("OnEnterPressed", function()
HPTABPC[dbKey] = eb:GetText()
eb:ClearFocus()
end)

eb:SetScript("OnEditFocusLost", function()
HPTABPC[dbKey] = eb:GetText()
end)

return eb
end

local function CreateChannelDropdown(xOffset, yOffset)
local labelFS = f:CreateFontString(nil, "OVERLAY", "GameFontNormal")
labelFS:SetPoint("TOPLEFT", xOffset, yOffset)
labelFS:SetText("Announce Channel")

local dropdown = CreateFrame("Frame", "HPChannelDropDown", f, "UIDropDownMenuTemplate")
dropdown:SetPoint("TOPLEFT", xOffset - 16, yOffset - 18)
UIDropDownMenu_SetWidth(120, dropdown)

local channels = { "AUTO", "SAY", "YELL", "PARTY", "RAID", "GUILD" }

local function OnClick()
local value = this.value
HPTABPC["channelchat"] = value
UIDropDownMenu_SetSelectedValue(dropdown, value)
UIDropDownMenu_SetText(value, dropdown)
end

local function Initialize()
for _, chan in ipairs(channels) do
local info = {}
info.text = chan
info.value = chan
info.func = OnClick
UIDropDownMenu_AddButton(info)
end
end

UIDropDownMenu_Initialize(dropdown, Initialize)
local current = HealerProtection:DBGV("channelchat", "AUTO")
UIDropDownMenu_SetSelectedValue(dropdown, current)
UIDropDownMenu_SetText(current, dropdown)

return dropdown
end

-- ------------------------------------------------------------------
-- Layout (mirrors the D4KiR Healer Protection panel, minus the CC
-- checkbox grid top-right and the Loss of control section at the bottom)
-- ------------------------------------------------------------------

CreateCheckbox("PrintNothing", "Print Nothing", "printnothing", false, 20, -45)
CreateCheckbox("ShowInRaid", "Show in Raids", "showinraids", true, 20, -70)
CreateCheckbox("Outside", "Show outside", "showoutsideofinstance", false, 20, -95)
CreateCheckbox("ShowInBG", "Show in Battlegrounds", "showinbgs", false, 20, -120)

CreateCheckbox("Aggro", "AGGRO", "AGGRO", false, 20, -155)
CreateCheckbox("AggroChat", "AGGRO Chat-Message", "showaggrochat", true, 40, -180)
CreateCheckbox("AggroEmote", "AGGRO Emote", "showaggroemote", true, 40, -205)
CreateCheckbox("DeathMessage", "Death message", "deathmessage", true, 20, -230)

CreateCheckbox("OOM", "Out of Mana", "OOM", true, 20, -265)
CreateCheckbox("OOMChat", "OOM Chat-Message", "showoomchat", true, 40, -290)
CreateCheckbox("OOMEmote", "OOM Emote", "showoomemote", true, 40, -315)

CreateSlider("OomPerc", "If under %d%% Mana, print message", "OOMPercentage", 10, 1, 10, -355)

CreateCheckbox("NearOOM", "Near out of Mana", "NEAROOM", true, 20, -410)
CreateCheckbox("NearOOMChat", "Near OOM Chat-Message", "shownearoomchat", true, 40, -435)
CreateCheckbox("NearOOMEmote", "Near OOM Emote", "shownearoomemote", true, 40, -460)

CreateSlider("NearOomPerc", "If under %d%% Mana, print message", "NEAROOMPercentage", 30, 11, 30, -500)

CreateChannelDropdown(20, -555)

CreateEditBox("Prefix", 20, -615, 160, "prefix", "[Healer Protection]")
CreateEditBox("Suffix", 210, -615, 160, "suffix", "")
end

-- ============================================================================
-- MAGIC PATCH: STANDALONE BOOTSTRAP AND TRANSLATIONS
-- ============================================================================

local traductions = {
["LID_youhaveaggro"] = "You have aggro",
["LID_ihaveaggro"] = "Aggro on me! Get it off!",
["LID_outofmana"] = "I am OOM!",
["LID_nearoutofmana"] = "Low Mana!",
["LID_xmana"] = "%s%% Mana",
["LID_neardeath"] = "Help, I'm dying!",
["LID_xhealth"] = "%s%% HP",
["LID_healerisdead"] = "Healer is down... Fly, you fools!"
} -- BUG FIXED: closing brace was missing in the original file, which would have caused a Lua syntax error

function HealerProtection:Trans(key)
return traductions[key] or key
end

function HealerProtection:TryTrans(key, lang, val)
local texte = traductions[key] or key
if val then
return string.format(texte, tostring(val))
end
return texte
end

function HealerProtection:IsSetup() return true end
function HealerProtection:SetSetup() end
function HealerProtection:SetDbTab() end
function HealerProtection:InitSetting() end
function HealerProtection:IsLoaded() return true end
function HealerProtection:INFO(msg) DEFAULT_CHAT_FRAME:AddMessage("|cFF00FFFF[HP Info]|r " .. msg) end
function HealerProtection:MSG(msg) DEFAULT_CHAT_FRAME:AddMessage("|cFFFFFF00[HP]|r " .. msg) end
function HealerProtection:MathR(val, dec)
dec = dec or 0
local mult = 10 ^ dec
return math.floor(val * mult + 0.5) / mult
end

local bootFrame = CreateFrame("Frame")
bootFrame:RegisterEvent("PLAYER_LOGIN")
bootFrame:SetScript("OnEvent", function()
HealerProtection:Setup()
DEFAULT_CHAT_FRAME:AddMessage("|cFF00FF00[Healer Protection]|r ready and armed! Type |cFFFFFF00/hp|r to configure the alerts.")
end)
