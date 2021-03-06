AutoBuffsDruid = LibStub("AceAddon-3.0"):NewAddon("AutoBuffsDruid", "AceConsole-3.0", "AceEvent-3.0")
local ab = AutoBuffsDruid
local rc = LibStub("LibRangeCheck-2.0")
local ldb = LibStub:GetLibrary("LibDataBroker-1.1")
local L = LibStub("AceLocale-3.0"):GetLocale("AutoBuffsDruid")
local abdb -- the ab Ace3 db that holds our saved variables

--[[ ==========================================================================
~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~
===============================================================================


Nyctef's druid buffing - tries to be intelligent about GotW/MotW. 
(at least, closer to my liking than ZOMGBuffs, which is otherwise great)
Output is posted as an LDB feed, which shows the next target and spell
to be cast, and the raid survey as a tooltip.

The main decision-making function is near the bottom and heavily highlighted.

TODO: Checking for low player mana, ghost, rested states etc.
      remembering Thorns on a certain target.
      Change MOTW rebuff time if solo or partying
        probably done, needs testing.

      long term - make it faster (not really a problem it seems but worth trying)
        a few tables are repeatedly recreated for instance

The automatic reagent purchase is fairly separate from the rest of the code.

===============================================================================
~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~
===============================================================================
]]


-- (these are WotLK spells and reagents, will probably need updating in 4.0)
local MOTW, _, MOTWicon, MOTWcost, _, _,  _, _, MOTWrange = GetSpellInfo(48469) -- "Mark of the Wild" 
local GOTW, _, GOTWicon, GOTWcost, _,  _, _, _, GOTWrange = GetSpellInfo(48470) -- "Gift of the Wild"
local THORNS,_,THORNSicon,THORNScost, _,_,_,_,THORNSrange = GetSpellInfo(53307) -- "Thorns" 

local GOTWreagents, _, _, _, _, _, _,GOTWreagentstacksize = GetItemInfo(44605) -- "Wild Spineleaf"
local rebirthreagents,_,_,_,_,_,_,rebirthreagentstacksize = GetItemInfo(44614) -- "Starleaf Seed"

local FOOD  = (GetSpellInfo(433)) -- "Food"
local DRINK = (GetSpellInfo(430)) -- "Drink"

local options = {
  name = "AutoBuffsDruid",
  handler = AutoBuffsDruid,
  type = 'group',
  args = {
    GOTW = {
      type = "range", min = 0, max = 100, step = 1, bigStep = 20,
      name = "GotW reagent level",
      desc = "How many GotW reagents to keep",
      get = function(info) return abdb.GOTWreagentlevel end,
      set = function(info, value) abdb.GOTWreagentlevel = value end,
    },
    rebirth = {
      type = "range", min = 0, max = 100, step = 1, bigStep = 20,
      name = "Rebirth reagent level",
      desc = "How many rebirth reagents to keep",
      get = function(info) return abdb.rebirthreagentlevel end,
      set = function(info, value) abdb.rebirthreagentlevel = value end,
    },
    updateperiod = {
      type = "range", min = 0.1, max = 20, step = 0.1, bigStep = 0.5,
      name = "Update period",
      desc = "The maximum time between raid checks (out of combat) (seconds)",
      get = function(info) return abdb.updateperiod end,
      set = function(info, value) abdb.updateperiod = value end,
    },
    rebufftime = {
      type = "range", min = 0, max = 1800, step = 10, bigStep = 60,
      name = "Rebuff time",
      desc = "Rebuffs if only a certain (short) duration is remaining (seconds)",
      get = function(info) return abdb.rebufftime end,
      set = function(info, value) abdb.rebufftime = value end,
    },
    solorebufftime = {
      type = "toggle",
      name = "Solo rebuff time",
      desc = "Use the rebuff time option when soloing",
      get = function(info) return abdb.solorebufftime end,
      set = function(info, value) abdb.solorebufftime = value end,
    },
  },
}

local defaults = {
  profile = {
        GOTW = 40, rebirth = 20, updateperiod = 0.5, rebufftime = 600, solorebufftime = false
  }
}

--[[
  Initialise some Ace3 and LDB stuff
]]
function ab:OnInitialize()
  local _, class = UnitClass("player")
  if class ~= "DRUID" then return end

  -- Ace3 UI stuff:
  LibStub("AceConfig-3.0"):RegisterOptionsTable("AutoBuffsDruid", options)
  ab:RegisterChatCommand("autobuffsdruid", "ChatCommand")
  ab:RegisterChatCommand("abd", "ChatCommand")
  ab.optionsFrame = LibStub("AceConfigDialog-3.0"):AddToBlizOptions("AutoBuffsDruid", "AutoBuffsDruid")

  abdb = LibStub("AceDB-3.0"):New("AutoBuffsDruidDB", defaults, "Default")
  abdb = abdb.profile

  ab.ChatCommand = function(input)
    -- if we aren't given any options, then just open the UI panel.
    if not input --[[or trim(input) == ""]] then
        InterfaceOptionsFrame_OpenToCategory(self.optionsFrame)
    else
        LibStub("AceConfigCmd-3.0").HandleCommand(WelcomeHome, "wh", "WelcomeHome", input)
    end
  end

  -- LDB stuff next:
  ab.dataobj = ldb:NewDataObject("AutoBuffsDruid", {type = "data source", text = "", icon = MOTWicon})
  ab.ldbframe = CreateFrame("frame")
  
  ab.ldbframe:SetScript("OnUpdate", 
    function(self, elapsed)
      -- if we've gone without a check for more than updateperiod seconds, then update
      ab.elapsed = ab.elapsed + elapsed
      if ab.elapsed > abdb.updateperiod then
       ab:Update()
      end
      spell, unitid = ab.GetSpell(), ab.GetTarget()
      if (not spell) or (spell == "") then
        ab.dataobj.text = "None"
      else
     	  ab.dataobj.text = GetUnitName(unitid, false) .. ": " .. ab:Abbreviate(spell)
      end
    end
  )
  
  function ab.dataobj:OnTooltipShow()
  	self:AddLine("AutoBuffsDruid:")
    self:AddLine("")
    for k, v in pairs(ab:ListPlayers()) do
      self:AddLine(L[k] .. ": " .. v)
    end
  end
  
  function ab.dataobj:OnEnter()
  	GameTooltip:SetOwner(self, "ANCHOR_NONE")
  	GameTooltip:SetPoint("TOPLEFT", self, "BOTTOMLEFT")
  	GameTooltip:ClearLines()
  	dataobj.OnTooltipShow(GameTooltip)
  	GameTooltip:Show()  
  end

  function GameTooltip:OnLeave()
    GameTooltip:Hide()
  end
end

function ab:OnEnable()

  local _, class = UnitClass("player")
  if class ~= "DRUID" then return end

  ab.elapsed = 0 -- time since last check (seconds)
  -- events to check on
  ab:RegisterEvent("PLAYER_ENTERING_WORLD", "Update")
  ab:RegisterEvent("PLAYER_ALIVE", "Update")
  ab:RegisterEvent("PlAYER_UNGHOST", "Update")
  ab:RegisterEvent("UNIT_AURA", "Update")

  ab:RegisterEvent("COMBAT_LOG_EVENT_UNFILTERED", "Thorns")

  -- Automatic reagents
  ab:RegisterEvent("MERCHANT_SHOW", "Reagents");

  -- disable tracking during combat to try and avoid UNIT_AURA event overload
  -- we can't change what the button does during combat anyway so it's a bit useless.
  -- (hence the [nocombat] macro condition)
  ab:RegisterEvent("PLAYER_REGEN_ENABLED", function() ab:RegisterEvent("UNIT_AURA", "Update") end)
  ab:RegisterEvent("PLAYER_REGEN_DISABLED", function() ab:UnregisterEvent("UNIT_AURA", "Update") end)

	ab.frame = CreateFrame("Button", "TestButton", nil, "SecureUnitButtonTemplate")
  -- we use a macro for the [nocombat] condition.
	ab.frame:SetAttribute("type", "macro")
  ab.frame:SetAttribute("spell", MOTW) -- this doesn't do anything except store the name for our own use
	ab.frame:SetAttribute("macrotext", "/cast [nocombat]" .. MOTW)
	ab.frame:RegisterForClicks("AnyDown",  "AnyUp")
	ab.frame:HookScript("OnClick", 
	  function(self, button) 
      -- we've overridden the current binding, so we run that once we've buffed.
	    pcall(RunBinding, GetBindingAction(button))
	  end
  )
	
	SetOverrideBindingClick(ab.frame, true, "MOUSEWHEELUP", "TestButton", "MOUSEWHEELUP")

  ab.thornstable = {}

end

--[[ 
  simple functions to modify what the secure button does.
  the "spell" attribute isn't used by the button, but records what spell 
  is being used, for GetSpell().
]]
function ab:SetSpell(spell)
  --print("SetSpell: " .. (spell or "nil"))
	ab.frame:SetAttribute("spell", spell)
  ab.UpdateMacro()
end
function ab:SetTarget(unitid)
  ab.frame:SetAttribute("unit", unitid)
  ab.UpdateMacro()
end
function ab:GetSpell() return ab.frame:GetAttribute("spell") end
function ab:GetTarget() return ab.frame:GetAttribute("unit") end

function ab:UpdateMacro()
  spell, unitid = ab:GetSpell(), ab:GetTarget()
  ab.frame:SetAttribute("macrotext", spell and unitid and (spell ~= "") and 
                        "/cast [target="..unitid..",nocombat] "..spell or "")
  --print([[Setting macrotext to "]] .. (ab.frame:GetAttribute("macrotext") or "None") .. [[" ]])
end

--[[
  Called when the addon is disabled
]]
function ab:OnDisable()
  ab:UnregisterEvent("PLAYER_ENTERING_WORLD", "Update")
  ab:UnregisterEvent("PLAYER_ALIVE", "Update")
  ab:UnregisterEvent("PlAYER_UNGHOST", "Update")
  ab:UnregisterEvent("UNIT_AURA", "Update")
end

--[[-------------------------------


Event code


--]]-------------------------------

--[[
  Update the spell and target based on the current raid status.
]]
function ab:Update()

  if not abdb then return end

  ab.elapsed = 0 -- refresh update timer

  local playerstate = ab:PlayerState()

  if playerstate then
    ab:SetSpell("")
    ab:SetTarget(L[playerstate])
  else
    local spell, unitid = ab:CheckRaid()
    
    if spell then
      ab:SetSpell(spell)
      ab:SetTarget(unitid)
    else
      ab:SetSpell("")
      ab:SetTarget("")
    end
  end

end

--[[
  Remember when we cast Thorns on a player
]]
function ab:Thorns(event, ...)
  local timestamp, type, sourceGUID, sourceName, sourceFlags, destGUID, destName, destFlags = select(1, ...)  

  if type=="SPELL_AURA_APPLIED" and sourceName == (UnitName('player')) then

    local spellId, spellName, spellSchool = select(9, ...)

    if spellName == THORNS then
      DEFAULT_CHAT_FRAME:AddMessage("Thorns on "..destName)
      ab.thornstable[destName] = "buffed"
    end
  end

  if type=="SPELL_AURA_REMOVED" then

    local spellId, spellName, spellSchool = select(9, ...)

    if spellName == THORNS then
      DEFAULT_CHAT_FRAME:AddMessage("Thorns on "..destName.." removed")
      if ab.thornstable[destName] then 
        ab.thornstable[destName] = "needsbuffing" 
      end
    end
  end
end

--[[
  Check for and buy reagents at a merchant
]]
function ab:Reagents()

  if not abdb then return end

  local numGOTWreagents, numrebirthreagents = 0, 0

  -- run through each bag and check how many we have of each reagent type
  for bag = 4, 0, -1 do
		local size = GetContainerNumSlots(bag);
		
		if size > 0 then
			for slot = 1,size,1 do					
				if GetContainerItemLink(bag, slot) ~= nil then
					local _,itemCount = GetContainerItemInfo(bag, slot);
					
					if (GetItemInfo(GetContainerItemLink(bag, slot))) == GOTWreagents then
  					numGOTWreagents = numGOTWreagents + itemCount;
          elseif (GetItemInfo(GetContainerItemLink(bag, slot))) == rebirthreagents then
            numrebirthreagents = numrebirthreagents + itemCount          
          end
        end
      end
    end
  end
  
  -- if we have enough reagents then finish now.
  if numrebirthreagents >= abdb.rebirth and numGOTWreagents >= abdb.GOTW then return end

  -- Does the vendor have what we want?
  local vendorhasGOTWreagents, vendorhasrebirthreagents = false, false
  local GOTWreagentindex, rebirthreagentindex = -1, -1

	for i= 0,GetMerchantNumItems() do
		local itemName = GetMerchantItemInfo(i);
		
		if itemName == GOTWreagents then
			vendorhasGOTWreagents = true
      GOTWreagentindex = i
    elseif itemname == rebirthreagents then
      vendorhasrebirthreagents = true
      rebirthreagentindex = i
    end
	end

  if not(vendorhasGOTWreagents or vendorhasrebirthreagents) then return end

  -- And now, the shopping bit. 
  if vendorhasGOTWreagents and abdb.GOTW > numGOTWreagents then
    ab:BuyItem(GOTWreagentindex, abdb.GOTW - numGOTWreagents, GOTWreagentstacksize)
    print("AutoBuffsDruid: Bought "..(abdb.GOTW - numGOTWreagents).." "..GOTWreagents)
  end
  if vendorhasrebirthreagents and abdb.rebirth > numrebirthreagents then
    ab:BuyItem(rebirthreagentindex, abdb.rebirth - numrebirthreagents, rebirthreagentstacksize)
    print("AutoBuffsDruid: Bought "..(abdb.rebirth - numrebirthreagents).." "..rebirthreagents)
  end

end

--[[
  We buy `stacks` stacks of items and then finish with a final purchase of `ones`, 
  since we can only buy at most a stack in one go.
]]
function ab:BuyItem(index, numtobuy, stacksize)

  local stacks, ones = math.floor(numtobuy/stacksize), numtobuy%stacksize
  for i = 1,stacks do
    BuyMerchantItem(index, stacksize)
  end
  BuyMerchantItem(index, ones)

end
--[[--------------------------------


logic code (Decides what to do in a given situation)


--]]--------------------------------

--[[ 
  these functions help decide if we are partying, soloing etc
]]
function ab:Soloing()
  return GetNumRaidMembers() == 0 and GetNumPartyMembers() == 0
end
function ab:Partying()
  return GetNumRaidMembers() == 0 and GetNumPartyMembers() > 0
end
function ab:Raiding()
  return GetNumRaidMembers() > 0
end
  
function ab:PlayerState()

  if ab:HasBuff("player", DRINK) then
    return "quaffing"
  elseif ab:HasBuff("player", FOOD) then
    return "nomming"
  elseif UnitIsDead("player") then
    return "deadjim"
  elseif UnitIsGhost("player") then 
    return "oooooooh"
  elseif UnitOnTaxi("player") then
    return "taxiiing"
  elseif IsMounted() then
    return "riding"
  elseif IsResting() then
    return "sleeping"
  elseif IsStealthed() then
    return "sneaky"
  else
    return nil
  end

end

--[[
  Does a MOTW on the first person that needs it
]]
function ab:DoMOTW()

  if not abdb then return end

  -- first get a list of players to check based on our current situation
  local playerlist = ab:CreatePlayerList()

  -- now loop through the players we have and check them for buffs.
  for _,unitid in ipairs(playerlist) do
    -- check the player isn't too far away
    local _, maxrange = rc:getRange(unitid)

    MOTWtimeleft = ab:HasMOTW(unitid)

   -- print (".."..MOTWrange.."..")

    if (not MOTWtimeleft 
        or MOTWtimeleft < abdb.rebufftime and not ab:Soloing()
        or not abdb.solorebufftime and ab:Soloing() and not MOTWtimeleft) 
        and 
        (maxrange and MOTWrange and maxrange <= MOTWrange) then
      return "Mark of the Wild", unitid
    end
  end
end

--[[
  Check if a player has a buff on them, and, if so, return the time 
  left in seconds on the buff.
]]
function ab:HasBuff(unitid, thebuff)

  local buff, _, _, _, _, _, expirytime = UnitBuff(unitid, thebuff)

  return (buff and expirytime - GetTime()) or nil

end

--[[
  Check for MOTW or GOTW on a player
]]
function ab:HasMOTW(unitid)

  return ab:HasBuff(unitid, MOTW) or ab:HasBuff(unitid, GOTW)

end

--[[
  Create a player list to iterate over.
]]
function ab:CreatePlayerList()

  local playerlist = {}
  if GetNumRaidMembers() > 0 then -- in a raid
    for i = 1,GetNumRaidMembers() do
      table.insert(playerlist, "raid"..i)
    end
  elseif GetNumPartyMembers() > 0 then -- in a party 
    for i = 1,GetNumPartyMembers() do
      table.insert(playerlist, "party"..i)
    end
    table.insert(playerlist, "player") -- the player isn't included in the partyN list 
  else
    table.insert(playerlist, "player") -- solo
  end

  return playerlist

end

--[[
  Check the state of a player to see if they can be buffed
]]
function ab:CheckState(unitid)

  local MOTWtimeleft = ab:HasMOTW(unitid) 
  local minrange, maxrange = rc:getRange(unitid)

  if (MOTWtimeleft and MOTWtimeleft > abdb.rebufftime)
     or (MOTWtimeleft and not abdb.solorebufftime) then
    return "buffed"
  elseif not UnitIsConnected(unitid) then
    return "fakedc"
  elseif UnitIsDeadOrGhost(unitid) then
    return "deadjim"
  elseif (not maxrange) or (MOTWrange and maxrange > MOTWrange) or (not UnitIsVisible(unitid)) then
    return "farfaraway"
  else
    return "wantsbuffing"
  end

end

--[[
  A quick version of the above function used for thorns
]]
function ab:CanBeBuffed(unitid)

  local minrange, maxrange = rc:getRange(unitid)
  if not UnitIsConnected(unitid) or 
    UnitIsDeadOrGhost(unitid) or
    not maxrange or 
    THORNSrange and maxrange > THORNSrange or 
    not UnitIsVisible(unitid) then
    return false
  else
    return true
  end
end

--[[
  Create a survey of players in the raid to help decide
  whether to MOTW one or throw out a GOTW
]]
function ab:ListPlayers()

  local playerlist = ab:CreatePlayerList()
  local statelist = {
    buffed = 0,
    fakedc = 0, 
    deadjim = 0,
    farfaraway = 0,
    wantsbuffing = 0
  }

  for _, unitid in ipairs(playerlist) do
    local state = ab:CheckState(unitid)
    statelist[state] = statelist[state] + 1
  end

  return statelist

end


--[[===========================================================================




  CheckRaid: returns the recommended action and a target if MOTW.
  The action is "Gift of the Wild" or "Mark of the Wild", and target
  is a UnitID (eg "player", "party1", "raid20" etc). Nil for do nothing.



=============================================================================]]
function ab:CheckRaid()

  survey = ab:ListPlayers()
  numplayers = (GetNumRaidMembers() > 0 and GetNumRaidMembers())  -- raid
            or (GetNumPartyMembers() > 0 and GetNumPartyMembers())  -- party
            or ( 1 ) -- solo

  if survey.wantsbuffing == 0 then 
    -- check thorns next
    for unit,isbuffed in pairs(ab.thornstable) do
      if isbuffed == "needsbuffing" and ab:CanBeBuffed(unit) then 
        return THORNS, unit            
      end
    end
  elseif survey.fakedc + survey.deadjim + survey.farfaraway == 0 then
    if survey.wantsbuffing < 5 then
      return ab:DoMOTW()
    else
      return GOTW, "player"
    end
  elseif survey.fakedc + survey.deadjim + survey.farfaraway < 3 then
    if survey.wantsbuffing < 5 then
      return ab:DoMOTW()
    else
      return GOTW, "player"
    end
  end

  for unit,isbuffed in pairs(ab.thornstable) do
    if isbuffed == "needsbuffing" and ab:CanBeBuffed(unit) then 
      return THORNS, unit            
    end
  end
 
end


--[[----------------------------------

  some util functions

--]]----------------------------------

--[[
  Return an acronym for the input text
]]
function ab:Abbreviate(input)

  if input:len() < 7 then return input end

  -- replace every space-separated word with its first letter
  return (string.gsub(input, "(%a)%a*%s*", "%1"))

end

--[[
  Remove whitespace from the ends of a string
]]
function trim(input)

  return (string.gsub(input, "^%s*(.-)%s*$", "%1"))

end


