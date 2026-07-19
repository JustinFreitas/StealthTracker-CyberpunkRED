--[[
    StealthTracker for Cyberpunk RED ruleset
    Adapted from the 5E version by Justin Freitas
--]]

ALL = "all"
AWARE = "aware"
DEXTERITY = "dexterity"
EFFECTS = "effects"
FORCE_DISPLAY = true
GENACTROLL = "genactroll"
HIDDEN = "hidden"
LOCALIZED_DEXTERITY = "DEX"
LOCALIZED_DEXTERITY_LOWER = LOCALIZED_DEXTERITY:lower()
LOCALIZED_STEALTH = "Stealth"
LOCALIZED_STEALTH_ABV = "S"
LOCALIZED_STEALTH_LOWER = LOCALIZED_STEALTH:lower()
NONE = "none"
OFF = "off"
ON = "on"
OOB_MSGTYPE_UPDATESTEALTH = "updatestealth"
OOB_MSGTYPE_ATTACKFROMSTEALTH = "attackfromstealth"
SECRET = true
ST_NO_RANGE_HINT = "No range to target (are both tokens on the map?)"
ST_STEALTH_DISABLED_OUT_OF_FORMAT = "Stealth processing disabled when out of %s."
STEALTHTRACKER_ALLOW_OUT_OF = "STEALTHTRACKER_ALLOW_OUT_OF"
STEALTHTRACKER_AWARE = "STEALTHTRACKER_AWARE"
STEALTHTRACKER_EXPIRE_EFFECT = "STEALTHTRACKER_EXPIRE_EFFECT"
STEALTHTRACKER_FACTION_FILTER = "STEALTHTRACKER_FACTION_FILTER"
STEALTHTRACKER_FRAME_STYLE = "STEALTHTRACKER_FRAME_STYLE"
STEALTHTRACKER_INIT_CLEAR = "STEALTHTRACKER_INIT_CLEAR"
STEALTHTRACKER_SHOW_AFTER_STEALTH = "STEALTHTRACKER_SHOW_AFTER_STEALTH"
STEALTHTRACKER_SHOW_EYE = "STEALTHTRACKER_SHOW_EYE"
STEALTHTRACKER_VERBOSE = "STEALTHTRACKER_VERBOSE"
STEALTHTRACKER_VISIBLE = "STEALTHTRACKER_VISIBLE"
STEALTHTRACKER_VISIBILITY = "STEALTHTRACKER_VISIBILITY"
TURN = "turn"
UNAWARE = "unaware"
UNIDENTIFIED = "(unidentified)"
USER_ISHOST = false
VISIBLE = "visible"

-- Configuration table for stealth effects to apply to observers
STEALTH_EFFECT_MODIFIERS = {}

local ActionSkill_onRoll_Original, CombatManager_onDrop, CombatManager_requestActivation
local bStealthTrackerInitialized = false

-- Dedupe of observed roll resolutions, so the same logical roll (identified by the ruleset's
-- rRoll.sUniqueValue, which is stable across crit re-rolls and per-target copies) is only
-- processed once per kind/target - e.g. if the extension is accidentally enabled twice.
local aProcessedRollKeys = {}
local nProcessedRollKeyCount = 0

local function getRollProcessingKey(sKind, rTarget, rRoll)
	if not rRoll or not rRoll.sUniqueValue then return nil end
	local sTargetPath = ""
	if rTarget then
		local nodeTargetCT = ActorManager.getCTNode(rTarget)
		sTargetPath = (nodeTargetCT and nodeTargetCT.getPath()) or rTarget.sCTNode or ""
	end
	return sKind .. "|" .. tostring(rRoll.sUniqueValue) .. "|" .. sTargetPath
end

local function markRollProcessed(sKey)
	-- Bound the table so it can't grow without limit over a long session.
	if nProcessedRollKeyCount > 500 then
		aProcessedRollKeys = {}
		nProcessedRollKeyCount = 0
	end
	aProcessedRollKeys[sKey] = true
	nProcessedRollKeyCount = nProcessedRollKeyCount + 1
end

-- Helper to safely check if a string is blank
local function isBlankSafe(s)
    if StringManager.isBlank then
        return StringManager.isBlank(s)
    end
    if type(s) ~= "string" then
        return false
    end
    return (string.gsub(s, "%s+", "") == "")
end

-- Helper to check if a roll is a primary skill/attack roll that will explode or fumble in Cyberpunk RED
local function isExplodingOrFumblingRoll(rRoll)
	if not rRoll then return false end
	local sType = rRoll.sType
	if sType == "critRoll" or sType == "critSkillRoll" then
		return false
	end
	if rRoll.aDice and #rRoll.aDice > 0 then
		local firstDie = rRoll.aDice[1]
		if firstDie then
			if firstDie.result == 10 then
				return true
			end
			if firstDie.result == 1 then
				-- Solo Fumble Recovery cancels the fumble: the ruleset tags the roll's desc (before
				-- our post-resolve observer runs) and never throws a continuation die, so the roll
				-- is final and must be processed now rather than waiting for a continuation.
				if rRoll.sDesc and rRoll.sDesc:match("%[Fumble recovery%]") then
					return false
				end
				return true
			end
		end
	end
	return false
end

-- Helper to parse the previous roll and combine it with the critical roll
local function getCombinedRoll(rRoll)
	if not rRoll then return nil end
	local sType = rRoll.sType
	if sType == "critRoll" or sType == "critSkillRoll" then
		if rRoll.sPrevRoll and rRoll.sPrevRoll ~= "" then
			local status, combinedRoll = pcall(Json.parse, rRoll.sPrevRoll)
			if status and combinedRoll then
				combinedRoll.aDice = { combinedRoll.aDice[1], rRoll.aDice[1] }
				combinedRoll.sDesc = combinedRoll.sDesc .. rRoll.sDesc
				return combinedRoll
			end
		end
	end
	return rRoll
end

-- Helper to dynamically resolve stat values from character/NPC nodes (Cyberpunk RED compatible)
local function getStatValueSafe(nodeActor, sStatName)
    if not nodeActor then return 0 end
    local sNameLower = sStatName:lower()
    
    -- Check common direct paths (Cyberpunk RED INT/DEX properties use intCurrent, dexCurrent, etc.)
    local paths = {
        sNameLower .. "Current",
        sNameLower .. "Base",
        sNameLower,
        "stats." .. sNameLower .. "Current",
        "stats." .. sNameLower .. "Base",
        "stats." .. sNameLower .. ".value",
        "stats." .. sNameLower,
        sNameLower .. ".value",
        sStatName,
        "stats." .. sStatName .. ".value",
        "stats." .. sStatName,
        sStatName .. ".value"
    }
    for _, path in ipairs(paths) do
        local val = DB.getValue(nodeActor, path)
        if type(val) == "number" then
            return val
        end
    end
    
    -- Try to find in stats children dynamically
    local nodeStats = nodeActor.getChild("stats")
    if nodeStats then
        for _, nodeStat in pairs(nodeStats.getChildren()) do
            local sNodeName = nodeStat.getName():lower()
            if sNodeName == sNameLower or sNodeName:match(sNameLower) or DB.getValue(nodeStat, "name", ""):lower() == sNameLower then
                local val = DB.getValue(nodeStat, "value") or DB.getValue(nodeStat, "total") or DB.getValue(nodeStat, "current")
                if type(val) == "number" then
                    return val
                end
            end
        end
    end
    
    return 0
end

-- Helper to dynamically resolve skill values from character/NPC nodes (Cyberpunk RED compatible)
local function getSkillValueSafe(nodeActor, sSkillName)
    if not nodeActor then return 0 end
    local sSkillLower = sSkillName:lower()
    
    -- Check direct fields first
    local val = DB.getValue(nodeActor, sSkillLower) or DB.getValue(nodeActor, sSkillName)
    if type(val) == "number" then
         return val
    end
    
    -- Search skills or skilllist children (CPRed uses skillsCol)
    local listNodes = { "skillsCol", "skilllist", "skills" }
    for _, listName in ipairs(listNodes) do
        local nodeSkills = nodeActor.getChild(listName)
        if nodeSkills then
            for _, nodeSkillGroup in pairs(nodeSkills.getChildren()) do
                -- CPRed PC character sheets list sub-skills (listSkillSpecifics)
                local subLists = { "listSkillSpecifics", "listSubSkillSpecifics" }
                local bHasChildren = false
                for _, subListName in ipairs(subLists) do
                    local nodeSub = nodeSkillGroup.getChild(subListName)
                    if nodeSub then
                        bHasChildren = true
                        for _, nodeSubSkill in pairs(nodeSub.getChildren()) do
                            local sName = DB.getValue(nodeSubSkill, "skillName", ""):gsub("%(x2%)", ""):gsub("%s+", ""):lower()
                            if sName == sSkillLower or sName:match(sSkillLower) then
                                local rank = DB.getValue(nodeSubSkill, "skillBase") or DB.getValue(nodeSubSkill, "level") or DB.getValue(nodeSubSkill, "rank") or DB.getValue(nodeSubSkill, "value") or DB.getValue(nodeSubSkill, "total")
                                if type(rank) == "number" then
                                    return rank
                                end
                            end
                        end
                    end
                end

                -- NPC skills lists or simple flat skills lists
                if not bHasChildren then
                    local sName = DB.getValue(nodeSkillGroup, "skillName", ""):gsub("%(x2%)", ""):gsub("%s+", ""):lower()
                    if sName == "" then sName = DB.getValue(nodeSkillGroup, "name", ""):lower() end
                    if sName == sSkillLower or sName:match(sSkillLower) then
                        local rank = DB.getValue(nodeSkillGroup, "skillBase") or DB.getValue(nodeSkillGroup, "level") or DB.getValue(nodeSkillGroup, "rank") or DB.getValue(nodeSkillGroup, "value") or DB.getValue(nodeSkillGroup, "total")
                        if type(rank) == "number" then
                            return rank
                        end
                    end
                end
            end
        end
    end
    return 0
end

-- Helper to parse flat numeric modifiers from Combat Tracker effects
local function getNumericModifierFromEffects(nodeCT, sKeyword)
    if not nodeCT then return 0 end
    local nMod = 0
    local nodeEffects = nodeCT.getChild("effects")
    if nodeEffects then
        local sKeywordLower = sKeyword:lower()
        -- Match patterns like "keyword: +2", "keyword: -1", "keyword +2", "keyword -1"
        local patterns = {
            "^%s*" .. sKeywordLower .. "%s*:%s*([+-]?%d+)%s*$",
            "^%s*" .. sKeywordLower .. "%s*([+-]%d+)%s*$",
        }
        for _, nodeEffect in pairs(nodeEffects.getChildren()) do
            local sLabel = DB.getValue(nodeEffect, "label", ""):lower()
            local aComponents = EffectManager.parseEffect and EffectManager.parseEffect(sLabel) or { sLabel }
            for _, component in ipairs(aComponents) do
                for _, pattern in ipairs(patterns) do
                    local sMatch = string.match(component, pattern)
                    if sMatch then
                        nMod = nMod + (tonumber(sMatch) or 0)
                    end
                end
            end
        end
    end
    return nMod
end

-- Direct fallback to search effects on CT node directly if ruleset manager is missing
local function hasEffectFallback(nodeCT, sEffect)
    if not nodeCT then return false end
    local nodeEffects = nodeCT.getChild("effects")
    if nodeEffects then
        local sSearch = sEffect:lower()
        for _, nodeEffect in pairs(nodeEffects.getChildren()) do
            local sLabel = DB.getValue(nodeEffect, "label", ""):lower()
            if sLabel == sSearch or sLabel:match(sSearch) then
                return true
            end
        end
    end
    return false
end

-- Helper to safely check for effects (ruleset agnostic)
local function hasEffectSafe(rActor, sEffect, rTarget, bTargetedOnly)
    local nodeCT = ActorManager.getCTNode(rActor)
    if EffectManager.hasEffect then
        local status, result = pcall(EffectManager.hasEffect, rActor, sEffect, rTarget, bTargetedOnly)
        if status then return result end
    end
    return hasEffectFallback(nodeCT, sEffect)
end

-- Helper to safely get an actor from a node/string
local function getActorSafe(v)
    if ActorManager.getActor then
        return ActorManager.getActor(v)
    end
    return ActorManager.resolveActor(v)
end

-- Helper to safely get an actor's type and node
local function getTypeAndNodeSafe(v)
    if ActorManager.getTypeAndNode then
        return ActorManager.getTypeAndNode(v)
    end
    return ActorManager.getActorTypeAndNode(v)
end

-- Helper to safely capture the ruleset's existing result handler
local function getResultHandlerSafe(sType)
    if ActionsManager.getResultHandler then
        return ActionsManager.getResultHandler(sType)
    end
    local aHandlers = ActionsManager.aRollHandlers or ActionsManager.aHandlers
    if type(aHandlers) == "table" and type(aHandlers[sType]) == "table" then
        return aHandlers[sType].fResultHandler
    end
    return nil
end

function onInit()
	-- Guard against onInit() running more than once in the same session (e.g. a script/extension
	-- reload during development), which would chain our observers onto themselves and produce
	-- duplicate processing.
	if bStealthTrackerInitialized then return end
	bStealthTrackerInitialized = true

	LOCALIZED_DEXTERITY = "DEX"
	LOCALIZED_DEXTERITY_LOWER = LOCALIZED_DEXTERITY:lower()
	LOCALIZED_STEALTH = "Stealth"
	LOCALIZED_STEALTH_ABV = "S"
	LOCALIZED_STEALTH_LOWER = LOCALIZED_STEALTH:lower()
	USER_ISHOST = User.isHost()

    -- Initiation hook (for forcing secret rolls)
    if ActionSkill then
        ActionSkill_onRoll_Original = ActionSkill.onRoll
        ActionSkill.onRoll = onInitiateSkill
    end

    -- Roll types actually registered by the CyberpunkRED ruleset (CommonRolls.lua). Note "attack"
    -- resolves to the same underlying ruleset function as "skillroll"/"classroll" - this ruleset has
    -- no distinct attack handler.
    local aRollTypes = { "skillroll", "classroll", "classrollAttack", "attack", "critRoll", "critSkillRoll" }

	-- Host only registrations
	if USER_ISHOST then
        local option_entry_cycler = "option_entry_cycler"
        local option_header = "option_header_STEALTHTRACKER"
        local option_val_none = "option_val_none_STEALTHTRACKER"
        local option_val_off = "option_val_off"
        local option_val_on = "option_val_on"
        local both = "both"
        local standard = "standard"

        OptionsManager.registerOption2(STEALTHTRACKER_ALLOW_OUT_OF, false, option_header, "option_label_STEALTHTRACKER_ALLOW_OUT_OF", option_entry_cycler,
            { baselabel = option_val_none, baseval = NONE, labels = "option_val_turn_STEALTHTRACKER|option_val_turn_and_combat_STEALTHTRACKER", values = "turn|" .. ALL, default = ALL })
        OptionsManager.registerOption2(STEALTHTRACKER_EXPIRE_EFFECT, false, option_header, "option_label_STEALTHTRACKER_EXPIRE_EFFECT", option_entry_cycler,
            { baselabel = "option_val_attack_and_round_STEALTHTRACKER", baseval = ALL, labels = "option_val_attack_STEALTHTRACKER|" .. option_val_none, values = "attack|" .. NONE, default = "attack" })
        OptionsManager.registerOption2(STEALTHTRACKER_FACTION_FILTER, false, option_header, "option_label_STEALTHTRACKER_FACTION_FILTER", option_entry_cycler,
            { labels = option_val_off, values = OFF, baselabel = "option_val_on", baseval = ON, default = ON })
        OptionsManager.registerOption2(STEALTHTRACKER_VISIBILITY, false, option_header, "option_label_STEALTHTRACKER_VISIBILITY", option_entry_cycler,
            { baselabel = "option_val_chat_and_effects_STEALTHTRACKER", baseval = ALL, labels = "option_val_effects_STEALTHTRACKER|" .. option_val_none, values = EFFECTS .. "|" .. NONE, default = EFFECTS })
        OptionsManager.registerOption2(STEALTHTRACKER_VERBOSE, false, option_header, "option_label_STEALTHTRACKER_VERBOSE", option_entry_cycler,
            { baselabel = "option_val_standard", baseval = standard, labels = "option_val_max|" .. option_val_off, values = "max|" .. OFF, default = standard })
        OptionsManager.registerOption2(STEALTHTRACKER_AWARE, false, option_header, "option_label_STEALTHTRACKER_AWARE", option_entry_cycler,
            { baselabel = "option_val_both_STEALTHTRACKER", baseval = both, labels = "option_val_none_STEALTHTRACKER|option_val_aware_STEALTHTRACKER|option_val_unaware_STEALTHTRACKER", values = NONE .. "|" .. AWARE .. "|" .. UNAWARE, default = both })
        OptionsManager.registerOption2(STEALTHTRACKER_VISIBLE, false, option_header, "option_label_STEALTHTRACKER_VISIBLE", option_entry_cycler,
            { baselabel = "option_val_hidden_STEALTHTRACKER", baseval = HIDDEN, labels = "option_val_none_STEALTHTRACKER|option_val_visible_STEALTHTRACKER|option_val_both_STEALTHTRACKER", values = NONE .. "|" .. VISIBLE .. "|" .. both, default = HIDDEN })
        OptionsManager.registerOption2(STEALTHTRACKER_INIT_CLEAR, false, option_header, "option_label_STEALTHTRACKER_INIT_CLEAR", option_entry_cycler,
            { labels = option_val_off, values = OFF, baselabel = "option_val_on", baseval = ON, default = ON })
        OptionsManager.registerOption2(STEALTHTRACKER_SHOW_AFTER_STEALTH, false, option_header, "option_label_STEALTHTRACKER_SHOW_AFTER_STEALTH", option_entry_cycler,
            { labels = option_val_off, values = OFF, baselabel = "option_val_on", baseval = ON, default = ON })
        OptionsManager.registerOption2(STEALTHTRACKER_FRAME_STYLE, false, option_header, "option_label_STEALTHTRACKER_FRAME_STYLE", option_entry_cycler,
            { baselabel = option_val_none, baseval = NONE, labels = "option_val_chat_STEALTHTRACKER|option_val_story_STEALTHTRACKER|option_val_whisper_STEALTHTRACKER", values = "chat|story|whisper", default = NONE })
        OptionsManager.registerOption2(STEALTHTRACKER_SHOW_EYE, false, option_header, "option_label_STEALTHTRACKER_SHOW_EYE", option_entry_cycler,
            { labels = option_val_on, values = ON, baselabel = "option_val_off", baseval = OFF, default = OFF })

        CombatManager.setCustomCombatReset(onCombatResetEvent)
		if CombatDropManager then
			CombatManager_onDrop = CombatDropManager.onLegacyDropEvent
			CombatDropManager.onLegacyDropEvent = onDrop
		else
			CombatManager_onDrop = CombatManager.onDrop
			CombatManager.onDrop = onDrop
		end

        CombatManager_requestActivation = CombatManager.requestActivation
        CombatManager.requestActivation = requestActivation

		OOBManager.registerOOBMsgHandler(OOB_MSGTYPE_UPDATESTEALTH, handleUpdateStealth)
		OOBManager.registerOOBMsgHandler(OOB_MSGTYPE_ATTACKFROMSTEALTH, handleAttackFromStealth)

		Comm.registerSlashHandler("stealth", processChatCommand)
	end

	-- Observe roll resolution AFTER the ruleset's own result handler has run, via CoreRPG's
	-- GameManager "onActionPostResolve" layered hook (called by ActionsManager.resolveAction for
	-- every roll type). We deliberately do NOT replace the registered result handlers: replacing
	-- them puts this extension inside the resolution path, where any capture or ordering problem
	-- (e.g. two copies of the extension enabled at once) either recurses (stack overflow) or
	-- swallows the entire roll so nothing ever reaches chat.
	if GameManager and GameManager.setMultiKeyFunction and GameManager.getMultiKeyFunction then
		for _, sType in ipairs(aRollTypes) do
			local fObserver
			if sType:lower():match("attack") then
				fObserver = onRollAttack
			else
				fObserver = onRollSkill
			end
			-- Chain any function already occupying this single-slot hook, and pcall our observer
			-- so a StealthTracker bug can never disturb the ruleset's roll resolution.
			local fPrevious = GameManager.getMultiKeyFunction("onActionPostResolve", sType)
			GameManager.setMultiKeyFunction("onActionPostResolve", sType, function(rSource, rTarget, rRoll)
				if fPrevious then
					pcall(fPrevious, rSource, rTarget, rRoll)
				end
				pcall(fObserver, rSource, rTarget, rRoll)
			end)
		end
	else
		-- Fallback for CoreRPG versions without the GameManager layered hooks: wrap the ruleset's
		-- registered result handlers. Refuse to treat one of our own wrappers as the "original"
		-- handler so a bad capture can never recurse or silently swallow rolls.
		local aOwnWrappers = {}
		local fSkillFallback = getResultHandlerSafe("skillroll") or getResultHandlerSafe("classroll")
		local fAttackFallback = getResultHandlerSafe("attack")
		for _, sType in ipairs(aRollTypes) do
			local bAttack = sType:lower():match("attack") ~= nil
			local fObserver = bAttack and onRollAttack or onRollSkill
			local fOriginal = getResultHandlerSafe(sType)
			if not fOriginal then
				fOriginal = bAttack and fAttackFallback or fSkillFallback
			end
			if fOriginal and aOwnWrappers[fOriginal] then
				if Debug and Debug.console then
					Debug.console("StealthTracker: refused self-capture of result handler for roll type: " .. sType)
				end
				fOriginal = nil
			end
			local fWrapper = function(rSource, rTarget, rRoll)
				if fOriginal then
					fOriginal(rSource, rTarget, rRoll)
				end
				pcall(fObserver, rSource, rTarget, rRoll)
			end
			aOwnWrappers[fWrapper] = true
			ActionsManager.registerResultHandler(sType, fWrapper)
		end
	end

	if ActionGeneral then
		ActionsManager.registerPostRollHandler(GENACTROLL, onGenericActionPostRoll)
	end
end

function booleanToNumber(bValue)
	return bValue and 1 or 0
end

function checkAllowOutOfCombat()
	return OptionsManager.isOption(STEALTHTRACKER_ALLOW_OUT_OF, ALL)
end

function checkAllowOutOfTurn()
	return OptionsManager.isOption(STEALTHTRACKER_ALLOW_OUT_OF, TURN) or checkAllowOutOfCombat()
end

function checkAndDisplayAllowOutOfCombatAndTurnChecks(vActor)
	if checkAndDisplayCTInactiveAndOutsideOfCombatStealthDisallowed() then return false end

	local nodeCT = ActorManager.getCTNode(vActor)
	if CombatManager.getActiveCT() ~= nodeCT and not checkAllowOutOfTurn() then
		if checkVerbosityMax() then
			displayChatMessage(string.format(ST_STEALTH_DISABLED_OUT_OF_FORMAT, TURN), SECRET)
		end
		return false
	end
	return true
end

function checkAndDisplayCTInactiveAndOutsideOfCombatStealthDisallowed()
	if not CombatManager.getActiveCT() and not checkAllowOutOfCombat() then
		if checkVerbosityMax() then
			displayChatMessage(string.format(ST_STEALTH_DISABLED_OUT_OF_FORMAT, "combat"), SECRET)
		end
		return true
	end
	return false
end

function checkExpireActionAndRound()
	return OptionsManager.isOption(STEALTHTRACKER_EXPIRE_EFFECT, ALL)
end

function checkExpireNone()
	return OptionsManager.isOption(STEALTHTRACKER_EXPIRE_EFFECT, NONE)
end

function checkFactionFilter()
	return OptionsManager.isOption(STEALTHTRACKER_FACTION_FILTER, ON)
end

function checkShowEye()
    return OptionsManager.getOption(STEALTHTRACKER_SHOW_EYE) == ON
end

function checkVerbosityMax()
	return OptionsManager.getOption(STEALTHTRACKER_VERBOSE) == "max"
end

function checkVerbosityOff()
	return OptionsManager.getOption(STEALTHTRACKER_VERBOSE) == OFF
end

function deleteAllStealthEffects(nodeCT)
	if not nodeCT then return end
	for _, nodeEffect in pairs(DB.getChildren(nodeCT, EFFECTS)) do
		if getStealthValueFromEffectNode(nodeEffect) then
			nodeEffect.delete()
		end
	end
end

function displayChatMessage(sFormattedText, bSecret)
	if sFormattedText == nil then return end
	-- Framed chat modes render via a FormattedText control that parses the text as XML - escape
	-- any raw "<" so message text can never break it ("&lt;" renders as "<").
	local sSafeText = sFormattedText:gsub("<", "&lt;")
	local msg = {font = "msgfont", icon = "stealth_icon", secret = checkShowEye(), text = sSafeText}
	-- Per the Comm refdoc, mode should be "set only if you want to specify a chat mode".
	local sMode = getMode()
	if sMode ~= "" then
		msg.mode = sMode
	end
	if bSecret then
		Comm.addChatMessage(msg)
	else
		Comm.deliverChatMessage(msg)
	end
end

function displayDebilitatingConditionChatMessage(vActor, sCondition, bForce)
	if not bForce and checkVerbosityOff() then return end
	local sText = string.format("%s is %s, skipping StealthTracker processing.", ActorManager.getDisplayName(vActor), sCondition)
	displayChatMessage(sText, SECRET)
end

function displayProcessAttackFromStealth(rSource, rTarget)
	local nodeSourceCT = ActorManager.getCTNode(rSource)
	if not nodeSourceCT then return end

	local sCTNodePath = nodeSourceCT.getPath()
	if not USER_ISHOST then
		local nodeTargetCT = rTarget and ActorManager.getCTNode(rTarget)
		notifyAttackFromStealth(sCTNodePath, (nodeTargetCT and nodeTargetCT.getPath()) or "")
		return
	end

	if checkAndDisplayCTInactiveAndOutsideOfCombatStealthDisallowed() then return end

	local sCondition = getActorDebilitatingCondition(nodeSourceCT)
	if sCondition then
		displayDebilitatingConditionChatMessage(nodeSourceCT, sCondition)
		return
	end

	local aOutput = {}
	if rTarget then
		local rHiddenTarget = isTargetHiddenFromSource(rSource, rTarget)
		if rHiddenTarget and rHiddenTarget.hidden then
			local sMsgText = string.format("Target hidden. Attack possible? (%s %s: %d, %s Perception: %d).",
											ActorManager.getDisplayName(rTarget),
											LOCALIZED_STEALTH_ABV,
											rHiddenTarget.stealth,
											ActorManager.getDisplayName(rSource),
											rHiddenTarget.sourcePP)
			table.insert(aOutput, sMsgText)
		end

		local nStealthSource = getStealthNumberFromEffects(nodeSourceCT)
		if nStealthSource then
			getFormattedPerformAttackFromStealth(rSource, rTarget, nStealthSource, aOutput)
		end
	else
		if checkVerbosityMax() then
			insertFormattedTextWithSeparatorIfNonEmpty(aOutput, "No attack target!")
		end
		getFormattedStealthDataFromCT(nodeSourceCT, aOutput)
	end

	expireStealthEffectOnCTNode(rSource, aOutput)
	displayTableIfNonEmpty(aOutput)
end

function displayProcessStealthUpdateForSkillHandlers(rSource, rRoll)
	local nodeSourceCT = ActorManager.getCTNode(rSource)
	if nodeSourceCT and ActionsManager.doesRollHaveDice(rRoll) then
		local sCTNodePath = nodeSourceCT.getPath()
		local nStealthTotal = ActionsManager.total(rRoll)
		if USER_ISHOST then
			if checkAndDisplayAllowOutOfCombatAndTurnChecks(sCTNodePath) then
				setNodeWithStealthValue(sCTNodePath, nStealthTotal)
                if OptionsManager.getOption(STEALTHTRACKER_SHOW_AFTER_STEALTH) == ON then
                    displayStealthCheckInformationWithConditionAndVerboseChecks(nodeSourceCT, FORCE_DISPLAY)
                end
			end
		elseif isPlayerStealthInfoDisabled() and not checkVerbosityOff() then
			local output = string.format("The DM has StealthTracker info set to hidden. Use the dice tower to make your %s roll.", LOCALIZED_STEALTH)
			displayChatMessage(output, false)
		else
			notifyUpdateStealth(sCTNodePath, nStealthTotal)
		end
	end
end

-- Intercept active perception rolls and compare them to tracked stealth values on the Combat Tracker
function displayProcessActivePerception(rSource, rRoll)
	local nodeSourceCT = ActorManager.getCTNode(rSource)
	if not nodeSourceCT then return end

	local nPerceptionRollTotal = ActionsManager.total(rRoll)
	local aOutput = {}
	local sSourceDisplayName = ActorManager.getDisplayName(rSource)
	
	local lCombatTrackerActors = CombatManager.getSortedCombatantList()
	for _, nodeCT in ipairs(lCombatTrackerActors) do
		if isValidCTNode(nodeCT) and nodeCT ~= nodeSourceCT then
			local nStealthTarget = getStealthNumberFromEffects(nodeCT)
			if nStealthTarget then
				local sTargetName = ActorManager.getDisplayName(nodeCT)
				-- NOTE: No angle brackets in chat text. Chat entries rendered with a frame style go
				-- through a FormattedText control that parses the text as XML, and a raw "<" throws
				-- "FormattedText SetValue XML Error: Name cannot begin with the ' ' character".
				if nPerceptionRollTotal >= nStealthTarget then
					table.insert(aOutput, string.format("%s SPOTTED %s! (Perception roll %d vs Stealth %d)", sSourceDisplayName:upper(), sTargetName, nPerceptionRollTotal, nStealthTarget))
				else
					table.insert(aOutput, string.format("%s did not spot %s. (Perception roll %d vs Stealth %d)", sSourceDisplayName, sTargetName, nPerceptionRollTotal, nStealthTarget))
				end
			end
		end
	end
	
	displayTableIfNonEmpty(aOutput, FORCE_DISPLAY)
end

function displayStealthCheckInformationWithConditionAndVerboseChecks(nodeCT, bForce)
	local sCondition = getActorDebilitatingCondition(nodeCT)
	if sCondition then
		displayDebilitatingConditionChatMessage(nodeCT, sCondition, bForce)
		return
	end

	local aOutput = {}
	getFormattedStealthDataFromCT(nodeCT, aOutput)
	displayTableIfNonEmpty(aOutput, bForce)
end

function displayTableIfNonEmpty(aTable, bForce)
	if not bForce and checkVerbosityOff() then return end
	aTable = validateTableOrNew(aTable)
	if #aTable > 0 then
		local sDisplay = table.concat(aTable, "\r")
		displayChatMessage(sDisplay, SECRET)
	end
end

function displayTowerRoll()
	if checkVerbosityOff() then return end
	displayChatMessage("An attack was rolled in the tower. Attacks should be rolled in the open for proper StealthTracker processing.", USER_ISHOST)
end

function doesTargetPerceiveAttackerFromStealth(nAttackerStealth, rTarget)
	if nAttackerStealth == nil or not rTarget then return false end
	local nPPTarget = getPassivePerceptionNumber(rTarget)
	return nPPTarget ~= nil and nPPTarget >= nAttackerStealth
end

function ensureStealthSkillExistsOnNpc(nodeCT)
	if not nodeCT then return end

	local rCurrentActor = getActorSafe(nodeCT)
	if not rCurrentActor or not isNpc(rCurrentActor) then return end

	-- Check if Stealth skill is already defined on NPC
	local bHasStealth = false

	-- 1. Scan skillsCol children directly for existing Stealth node
	local rSkillsNode = nodeCT.getChild("skillsCol")
	if rSkillsNode then
		for _, nodeSkill in pairs(rSkillsNode.getChildren()) do
			local sName = DB.getValue(nodeSkill, "skillName", ""):lower()
			if sName == "stealth" then
				bHasStealth = true
				break
			end
		end
	end

	-- 2. Fallback to Reusable helper
	if not bHasStealth and Reusable and Reusable.getNPCSkillBaseFor then
		local nBase, nLvl = Reusable.getNPCSkillBaseFor(nodeCT, "Stealth")
		if nBase then
			bHasStealth = true
		end
	end

	if not bHasStealth then
		if rSkillsNode then
			-- Official Cyberpunk RED NPC skills node
			local nodeNewSkill = rSkillsNode.createChild()
			DB.setValue(nodeNewSkill, "skillName", "string", "Stealth")
			local nDex = getStatValueSafe(nodeCT, "dexCurrent") or getStatValueSafe(nodeCT, "dexterity") or getStatValueSafe(nodeCT, "dex")
			DB.setValue(nodeNewSkill, "skillBase", "number", nDex)
			DB.setValue(nodeNewSkill, "skillLvl", "number", 0)
			DB.setValue(nodeNewSkill, "isVisible", "number", 1)
		else
			-- Fallback to list/string based formats
			local rSkillsStringNode = nodeCT.getChild("skills")
			if rSkillsStringNode then
				if rSkillsStringNode.getType() == "string" then
					local sSkills = rSkillsStringNode.getText()
					if not sSkills:match(LOCALIZED_STEALTH .. " [+-]%d") then
						local nDex = getStatValueSafe(nodeCT, "dexterity") or getStatValueSafe(nodeCT, "dex")
						local sStealthWithMod = LOCALIZED_STEALTH .. " " .. (nDex >= 0 and "+" or "") .. nDex
						local sNewSkillsValue = sStealthWithMod .. ", " .. sSkills
						rSkillsStringNode.setValue(sNewSkillsValue:gsub("^%s*(.-),%s*$", "%1"))
					end
				elseif rSkillsStringNode.getType() == "node" then
					local bFound = false
					for _, nodeSkill in pairs(rSkillsStringNode.getChildren()) do
						local sName = DB.getValue(nodeSkill, "name", ""):lower()
						if sName == "stealth" then
							bFound = true
							break
						end
					end
					if not bFound then
						local nodeNewSkill = rSkillsStringNode.createChild()
						DB.setValue(nodeNewSkill, "name", "string", "Stealth")
						local nDex = getStatValueSafe(nodeCT, "dexterity") or getStatValueSafe(nodeCT, "dex")
						DB.setValue(nodeNewSkill, "value", "number", nDex)
					end
				end
			end
		end
	end
end

function expireStealthEffectOnCTNode(rActor, aOutput)
	if not rActor then return end
	local nodeCT = ActorManager.getCTNode(rActor)
	if not nodeCT then return end

	local nodeLastEffectWithStealth
	for _, nodeEffect in pairs(DB.getChildren(nodeCT, EFFECTS)) do
		local sExtractedStealth = getStealthValueFromEffectNode(nodeEffect)
		if sExtractedStealth then
			nodeLastEffectWithStealth = nodeEffect
		end
	end

	if nodeLastEffectWithStealth then
		if checkExpireNone() then
			if checkVerbosityMax() then
				local sText = string.format("%s took an action from stealth that should expire the effect.", ActorManager.getDisplayName(rActor))
				insertFormattedTextWithSeparatorIfNonEmpty(aOutput, sText)
			end
		else
			EffectManager.expireEffect(nodeCT, nodeLastEffectWithStealth, 0)
		end
	end
end

function getActorDebilitatingCondition(vActor)
	local rActor = getActorSafe(vActor)
	if not rActor then return nil end

	local aConditions = {
		"dead",
		"unconscious",
		"stunned"
	}

	for _, sCondition in ipairs(aConditions) do
		if hasEffectSafe(rActor, sCondition) then return sCondition end
	end
	return nil
end

-- Base Perception check calculation (Cyberpunk RED compatible)
function getPassivePerceptionNumber(vActor)
	local nodeCreature = ActorManager.getCreatureNode(vActor)
	if not nodeCreature then return 5 end

	local nSkillBase = 0
	-- Try to use the official ruleset's Reusable library first!
	if Reusable and Reusable.getPCSkillBaseFor and Reusable.getNPCSkillBaseFor then
		local sNodeType = ActorManager.getRecordType(vActor)
		if sNodeType == "pc" then
			nSkillBase = Reusable.getPCSkillBaseFor(nodeCreature, "Perception") or 0
		else
			local val, _ = Reusable.getNPCSkillBaseFor(nodeCreature, "Perception")
			nSkillBase = val or 0
		end
	else
		-- Fallback to our robust database scanner
		local nInt = getStatValueSafe(nodeCreature, "intelligence") or getStatValueSafe(nodeCreature, "int")
		local nPerception = getSkillValueSafe(nodeCreature, "perception")
		nSkillBase = nInt + nPerception
	end

	-- Base detection threshold is 5 + SkillBase (Stat + Skill Level)
	local nPP = 5 + nSkillBase

    return modifyPassivePerceptionForActorEffects(nodeCreature, nPP)
end

function getFormattedAndClearAllStealthTrackerDataFromCTIfAllowed(aOutput, bForce)
	aOutput = validateTableOrNew(aOutput)
	if checkAllowOutOfCombat() and not bForce then
		insertFormattedTextWithSeparatorIfNonEmpty(aOutput, "Out of combat Stealth is allowed in the options. Leaving CT stealth effects after reset.")
		return
	end

	for _, nodeCT in pairs(DB.getChildren(CombatManager.CT_LIST)) do
		deleteAllStealthEffects(nodeCT)
	end

	insertFormattedTextWithSeparatorIfNonEmpty(aOutput, "All Stealth effects deleted on combat reset.")
end

function getFormattedPerformAttackFromStealth(rSource, rTarget, nStealthSource, aOutput)
	if not rSource or not rTarget or nStealthSource == nil then return end

	aOutput = validateTableOrNew(aOutput)
	local sMsgText
    local rTargetHidden = isTargetHiddenFromSource(rSource, rTarget)
	if rTargetHidden and not rTargetHidden.hidden then
		local sStats = string.format("(%s %s: %d, %s Perception: %d)",
									 ActorManager.getDisplayName(rSource),
									 LOCALIZED_STEALTH_ABV,
									 nStealthSource,
									 ActorManager.getDisplayName(rTarget),
									 getPassivePerceptionNumber(rTarget))
		if not doesTargetPerceiveAttackerFromStealth(nStealthSource, rTarget) then
			sMsgText = string.format("Attacker is hidden (Ambush). Target cannot dodge? %s", sStats)
		elseif checkVerbosityMax() then
			sMsgText = string.format("Attacker not hidden. %s", sStats)
		else
			sMsgText = nil
		end

		if sMsgText then
			insertFormattedTextWithSeparatorIfNonEmpty(aOutput, sMsgText)
		end
	end
end

function getFormattedStealthDataFromCT(nodeCTSource, aOutput)
    local rStealthData = {}
    rStealthData.visible = {}
    rStealthData.hidden = {}
    rStealthData.aware = {}
    rStealthData.unaware = {}

    if not nodeCTSource then return rStealthData end

	local rCurrentActor = getActorSafe(nodeCTSource)
	if not rCurrentActor then return rStealthData end

    local sCTSourceDisplayName = ActorManager.getDisplayName(rCurrentActor)
    if isBlankSafe(sCTSourceDisplayName) or isUnidentifiedNpc(nodeCTSource) then
        sCTSourceDisplayName = getUnidentifiedName(nodeCTSource)
    end

    local nStealthSource = getStealthNumberFromEffects(nodeCTSource)
	local lCombatTrackerActors = CombatManager.getSortedCombatantList()
	for _, nodeCT in ipairs(lCombatTrackerActors) do
        if isValidCTNode(nodeCT) then
            local rIterationActor = getActorSafe(nodeCT)
            if rIterationActor then
                local sIterationActorDisplayName = ActorManager.getDisplayName(rIterationActor)
                if isBlankSafe(sIterationActorDisplayName) or isUnidentifiedNpc(nodeCT) then
                    sIterationActorDisplayName = getUnidentifiedName(nodeCT)
                end

                local sDebilitatingCondition = getActorDebilitatingCondition(rIterationActor)
                if rCurrentActor.sCTNode ~= rIterationActor.sCTNode and
                   (not checkFactionFilter() or isDifferentFaction(nodeCTSource, nodeCT)) then
                    local rHiddenTarget = isTargetHiddenFromSource(rCurrentActor, rIterationActor)
                    if rHiddenTarget and sDebilitatingCondition == nil then
                        local sText = string.format("%s - %s: %d", sIterationActorDisplayName, LOCALIZED_STEALTH, rHiddenTarget.stealth)
                        if rHiddenTarget.hidden then
                            table.insert(rStealthData.hidden, sText)
                        else
                            table.insert(rStealthData.visible, sText)
                        end
                    end

                    if nStealthSource ~= nil then
                        local sText = string.format("%s", sIterationActorDisplayName)
                        local sPPText = string.format(" - Perception: %d", getPassivePerceptionNumber(rIterationActor))
                        local sConditionFormat = " - Condition: %s"
                        if doesTargetPerceiveAttackerFromStealth(nStealthSource, rIterationActor) then
                            if sDebilitatingCondition == nil then
                                table.insert(rStealthData.aware, sText .. sPPText)
                            else
                                local sConditionText = string.format(sConditionFormat, sDebilitatingCondition)
                                table.insert(rStealthData.unaware, sText .. sPPText .. sConditionText)
                            end
                        else
                            if sDebilitatingCondition == nil then
                                table.insert(rStealthData.unaware, sText .. sPPText)
                            else
                                local sConditionText = string.format(sConditionFormat, sDebilitatingCondition)
                                table.insert(rStealthData.unaware, sText .. sConditionText)
                            end
                        end
                    end
                end
            end
        end
    end

    aOutput = validateTableOrNew(aOutput)
    if OptionsManager.getOption(STEALTHTRACKER_VISIBLE) ~= NONE then
        if OptionsManager.getOption(STEALTHTRACKER_VISIBLE) ~= VISIBLE then
            if #rStealthData.hidden > 0 then
                local sText = string.format("%s (Perception: %d) does not perceive:\r%s",
                                             sCTSourceDisplayName,
                                             getPassivePerceptionNumber(rCurrentActor),
                                             table.concat(rStealthData.hidden, "\r"))
                insertFormattedTextWithSeparatorIfNonEmpty(aOutput, sText)
            else
                if checkVerbosityMax() then
                    local sText = string.format("There are no actors hidden from %s.", sCTSourceDisplayName)
                    insertFormattedTextWithSeparatorIfNonEmpty(aOutput, sText)
                end
            end
        end

        if OptionsManager.getOption(STEALTHTRACKER_VISIBLE) ~= HIDDEN then
            if #rStealthData.visible > 0 then
                local sText = string.format("%s (Perception: %d) sees:\r%s",
                                             sCTSourceDisplayName,
                                             getPassivePerceptionNumber(rCurrentActor),
                                             table.concat(rStealthData.visible, "\r"))
                insertFormattedTextWithSeparatorIfNonEmpty(aOutput, sText)
            else
                if checkVerbosityMax() then
                    local sText = string.format("There are no hiding actors visible to %s.", sCTSourceDisplayName)
                    insertFormattedTextWithSeparatorIfNonEmpty(aOutput, sText)
                end
            end
        end
    end

    if nStealthSource ~= nil and OptionsManager.getOption(STEALTHTRACKER_AWARE) ~= NONE then
        if OptionsManager.getOption(STEALTHTRACKER_AWARE) ~= UNAWARE then
            if #rStealthData.aware > 0 then
                local sText = string.format("%s (%s: %d) is seen by:\r%s",
                                            sCTSourceDisplayName,
                                            LOCALIZED_STEALTH,
                                            nStealthSource,
                                            table.concat(rStealthData.aware, "\r"))
                insertFormattedTextWithSeparatorIfNonEmpty(aOutput, sText)
            else
                if checkVerbosityMax() then
                    local sText = string.format("There are no actors that can see %s.", sCTSourceDisplayName)
                    insertFormattedTextWithSeparatorIfNonEmpty(aOutput, sText)
                end
            end
        end

        if OptionsManager.getOption(STEALTHTRACKER_AWARE) ~= AWARE then
            if #rStealthData.unaware > 0 then
                local sText = string.format("%s (%s: %d) is hidden from:\r%s",
                                            sCTSourceDisplayName,
                                            LOCALIZED_STEALTH,
                                            nStealthSource,
                                            table.concat(rStealthData.unaware, "\r"))
                insertFormattedTextWithSeparatorIfNonEmpty(aOutput, sText)
            else
                if checkVerbosityMax() then
                    local sText = string.format("There are no actors unaware of %s.", sCTSourceDisplayName)
                    insertFormattedTextWithSeparatorIfNonEmpty(aOutput, sText)
                end
            end
        end
    end

    return rStealthData
end

function getMode()
    local sFrameStyle = OptionsManager.getOption(STEALTHTRACKER_FRAME_STYLE)
    if sFrameStyle == NONE then sFrameStyle = "" end
    return sFrameStyle
end

function getStealthNumberFromEffects(nodeCT)
	if not nodeCT then return nil end
	local nStealth
	local aEffects = DB.getChildren(nodeCT, EFFECTS)
	for _, nodeEffect in pairs(aEffects) do
		local sExtractedStealth = getStealthValueFromEffectNode(nodeEffect)
		if sExtractedStealth then
			nStealth = tonumber(sExtractedStealth)
		end
	end
	return nStealth
end

function getStealthValueFromEffectNode(nodeEffect)
	if not nodeEffect then return end
	local sEffectLabel = DB.getValue(nodeEffect, "label", ""):lower()
	local sExtractedStealth
	local aEffectComponents = EffectManager.parseEffect and EffectManager.parseEffect(sEffectLabel) or { sEffectLabel }
	local pattern = "^%s*" .. LOCALIZED_STEALTH_LOWER .. ":%s*(%-?%d+)%s*$"
	for _, component in ipairs(aEffectComponents) do
		local sMatch = string.match(component, pattern)
		if sMatch then
			sExtractedStealth = sMatch
		end
	end
	return sExtractedStealth
end

function getUnidentifiedName(nodeRecord)
    local unidentifiedName = DB.getValue(nodeRecord, "nonid_name", UNIDENTIFIED)
    if isBlankSafe(unidentifiedName) then unidentifiedName = UNIDENTIFIED end
    return unidentifiedName
end

function handleAttackFromStealth(msgOOB)
	displayProcessAttackFromStealth(getActorSafe(msgOOB.sSourceCTNode), getActorSafe(msgOOB.sTargetCTNode))
end

function handleUpdateStealth(msgOOB)
	if not msgOOB or msgOOB.nStealthTotal == nil or msgOOB.sCTNodeId == nil or not msgOOB.user then return end
	local nStealthTotal = tonumber(msgOOB.nStealthTotal)
	if nStealthTotal == nil then return end

	if checkAndDisplayAllowOutOfCombatAndTurnChecks(msgOOB.sCTNodeId) then
		setNodeWithStealthValue(msgOOB.sCTNodeId, nStealthTotal)
	end
end

function hasValidType(nodeCTActor)
    local sNpcType = DB.getText(nodeCTActor, "type", ""):lower()
	return sNpcType ~= ""
        and not sNpcType:match("^%s*trap%s*$")
        and not sNpcType:match("^%s*object%s*$")
        and not isStealthTrackerDisabledForActor(nodeCTActor)
end

function insertBlankSeparatorIfNotEmpty(aTable)
	if #aTable > 0 then table.insert(aTable, "") end
end

function insertFormattedTextWithSeparatorIfNonEmpty(aTable, sFormattedText)
	insertBlankSeparatorIfNotEmpty(aTable)
	table.insert(aTable, sFormattedText)
end

function isDifferentFaction(vSource, vTarget)
	return ActorManager.getFaction(vSource) ~= ActorManager.getFaction(vTarget)
end

function isFriend(vActor)
	return vActor and ActorManager.getFaction(vActor) == "friend"
end

function isNpc(vActor)
	return ActorManager.getRecordType(vActor) == "npc"
end

function isPlayerStealthInfoDisabled()
	return OptionsManager.getOption(STEALTHTRACKER_VISIBILITY) == NONE
end

function isStealthSkillRoll(sRollData)
	if not sRollData then return false end
	local sLower = sRollData:lower()
	return sLower:match("stealth") ~= nil
end

function isDexterityCheckRoll(sRollData)
	if not sRollData then return false end
	local sLower = sRollData:lower()
	return sLower:match("dexterity") ~= nil or sLower:match("dex") ~= nil
end

function isPerceptionSkillRoll(sRollData)
	if not sRollData then return false end
	local sLower = sRollData:lower()
	-- Anchor to the "[Skill] " tag so "perception" must be the skill name itself, not a substring
	-- of another skill like "Human Perception".
	return sLower:match("%[skill%]%s*perception") ~= nil
end

-- Ranged (or thrown) attacks resolve against a static DV looked up by token range; melee resolves
-- via the contested Evasion flow instead and never carries a range-based DV.
function isRangedAttackRoll(rRoll)
	if not rRoll then return false end
	local sType = tostring(rRoll.sType or ""):lower()
	if not sType:match("attack") then return false end
	if tonumber(rRoll.nIsThrown or 0) == 1 then return true end
	if rRoll.sWeaponPath and DB.findNode then
		local nodeWeapon = DB.findNode(rRoll.sWeaponPath)
		if nodeWeapon and DB.getValue(nodeWeapon, "gearType", "") == "item_ranged" then
			return true
		end
	end
	return false
end

function isStealthTrackerDisabledForActor(nodeCTActor)
	if not nodeCTActor then return false end
	local sSenses = DB.getText(nodeCTActor, "senses", ""):lower()
	local sNotes = DB.getText(nodeCTActor, "notes", ""):lower()
	local sDesc = DB.getText(nodeCTActor, "description", ""):lower()
	return sSenses:match("no stealthtracker") or sNotes:match("no stealthtracker") or sDesc:match("no stealthtracker")
end

function isTargetHiddenFromSource(rSource, rTarget)
	if not rSource or not rTarget then return end

	local rTargetCTNode = ActorManager.getCTNode(rTarget)
	if not rTargetCTNode then return end

    local data = nil
    local nPPSource = getPassivePerceptionNumber(rSource)
	local nStealthTarget = getStealthNumberFromEffects(rTargetCTNode)
	if nStealthTarget ~= nil and nPPSource ~= nil then
        data = {
            source = rSource,
            sourcePP = nPPSource,
            target = rTarget,
            stealth = nStealthTarget
        }

		if nPPSource < nStealthTarget then
            data.hidden = true
        else
            data.hidden = false
		end
	end
	return data
end

function isUnidentifiedNpc(nodeRecord)
    return isNpc(nodeRecord) and DB.getValue(nodeRecord, "isidentified", 1) == 0
end

function isValidCTNode(nodeCT)
	if not nodeCT then return false end
	if isStealthTrackerDisabledForActor(nodeCT) then return false end

	local sRecordType = ActorManager.getRecordType(nodeCT)
	if sRecordType == "pc" or sRecordType == "npc" then
		return true
	end
	return isFriend(nodeCT)
end

function modifyPassivePerceptionForActorEffects(nodeCreature, nPP)
    local nodeCT = ActorManager.getCTNode(nodeCreature)
    local nEffectMod = getNumericModifierFromEffects(nodeCT, "perception") + getNumericModifierFromEffects(nodeCT, "intelligence") + getNumericModifierFromEffects(nodeCT, "int")
    return nPP + nEffectMod
end

function notifyAttackFromStealth(sSourceCTNode, sTargetCTNode)
	if sSourceCTNode == nil or sTargetCTNode == nil then return end
	local msgOOB = {}
	msgOOB.type = OOB_MSGTYPE_ATTACKFROMSTEALTH
	msgOOB.sSourceCTNode = sSourceCTNode
	msgOOB.sTargetCTNode = sTargetCTNode
	Comm.deliverOOBMessage(msgOOB, "")
end

function notifyUpdateStealth(sCTNodeId, nStealthTotal)
	if sCTNodeId == nil or nStealthTotal == nil then return end
	local msgOOB = {}
	msgOOB.type = OOB_MSGTYPE_UPDATESTEALTH
	msgOOB.user = User.getUsername()
	msgOOB.sCTNodeId = sCTNodeId
	msgOOB.nStealthTotal = nStealthTotal
	Comm.deliverOOBMessage(msgOOB, "")
end

function onCombatResetEvent()
    if OptionsManager.getOption(STEALTHTRACKER_INIT_CLEAR) == ON then
        local aOutput = {}
        getFormattedAndClearAllStealthTrackerDataFromCTIfAllowed(aOutput)
        displayTableIfNonEmpty(aOutput, FORCE_DISPLAY)
    end
end

function onDrop(nodetype, nodename, draginfo)
	local rSource = ActionsManager.decodeActors(draginfo)
	local rTarget = getActorSafe(nodename)
	onDropEvent(rSource, rTarget, draginfo)
    if type(CombatManager_onDrop) == "function" then
	    CombatManager_onDrop(nodetype, nodename, draginfo)
    end
end

function onDropEvent(rSource, rTarget, draginfo)
	if rSource or not USER_ISHOST or not rTarget or not rTarget.sCTNode or not draginfo then return end

	local sDragInfoData = draginfo.getStringData()
	if sDragInfoData == nil or sDragInfoData == "" then return end

	local nStealthValue = draginfo.getNumberData()
	if nStealthValue and (isStealthSkillRoll(sDragInfoData) or isDexterityCheckRoll(sDragInfoData)) then
		setNodeWithStealthValue(rTarget.sCTNode, nStealthValue)
	end
end

function onGenericActionPostRoll(rSource, rRoll)
	if rRoll and ActionsManager.doesRollHaveDice(rRoll) and rRoll.sType == GENACTROLL and rRoll.sGenericAction == "Hide" then
		displayProcessStealthUpdateForSkillHandlers(rSource, rRoll)
	end
end

function onInitiateSkill(rSource, rTarget, rRoll)
	local bProcessStealth = rSource and rRoll and isStealthSkillRoll(rRoll.sDesc)
	if bProcessStealth then
		if isPlayerStealthInfoDisabled() or (isNpc(rSource) and CombatManager.isCTHidden(rSource)) then
			rRoll.bSecret = true
		end
	end
    if type(ActionSkill_onRoll_Original) == "function" then
	    ActionSkill_onRoll_Original(rSource, rTarget, rRoll)
    end
end

-- Shared attack processing, called with the FINAL roll for a logical attack: the initial roll for
-- normal attacks, or the combined roll when a crit continuation lands.
function processAttackRoll(rSource, rTarget, rRoll)
	local sKey = getRollProcessingKey("attack", rTarget, rRoll)
	if sKey then
		if aProcessedRollKeys[sKey] then return end
		markRollProcessed(sKey)
	end

	if not rTarget and rRoll and rRoll.bSecret then
		displayTowerRoll()
	end

	-- Ranged attacks resolve against a DV derived from token range; if the ruleset couldn't
	-- determine a range (rRoll.nTarget stays nil), it silently prints the bare roll with no
	-- Hit/Miss line - surface a hint so it doesn't read as a broken roll.
	if rTarget and rRoll and rRoll.nTarget == nil and isRangedAttackRoll(rRoll) then
		displayChatMessage(ST_NO_RANGE_HINT, SECRET)
	end

	displayProcessAttackFromStealth(rSource, rTarget)
end

-- Post-resolve observer for attack-type rolls. Runs AFTER the ruleset's own result handler has
-- fully resolved the roll and produced its chat output - it never calls or replaces that handler.
function onRollAttack(rSource, rTarget, rRoll)
	-- An initial exploding (10) or fumbling (1) attack roll is not final - the ruleset throws a
	-- crit continuation (critRoll) that carries the combined result, and processing happens there
	-- (see onRollSkill). Processing both would emit duplicate stealth messages per crit attack.
	if isExplodingOrFumblingRoll(rRoll) then return end

	processAttackRoll(rSource, rTarget, rRoll)
end

-- Post-resolve observer for skill-type rolls (including the crit continuation rolls). Runs AFTER
-- the ruleset's own result handler - it never calls or replaces that handler.
function onRollSkill(rSource, rTarget, rRoll)
	local rProcessedRoll = getCombinedRoll(rRoll)
	if not rSource or not rProcessedRoll or not ActionsManager.doesRollHaveDice(rProcessedRoll) then return end

	-- A crit continuation of an ATTACK arrives as "critRoll" with the original attack roll in
	-- sPrevRoll; the combined roll is the attack's final result, so process it as an attack here
	-- (the initial exploding/fumbling attack roll was skipped in onRollAttack).
	local sProcessedType = tostring(rProcessedRoll.sType or ""):lower()
	if sProcessedType:match("attack") then
		processAttackRoll(rSource, rTarget, rProcessedRoll)
		return
	end

	-- An initial exploding (10) or fumbling (1) roll is not final - the crit continuation roll
	-- (critRoll/critSkillRoll) carries the combined result and is processed instead.
	if isExplodingOrFumblingRoll(rRoll) then return end

	local bStealth = isStealthSkillRoll(rProcessedRoll.sDesc)
	local bPerception = not bStealth and isPerceptionSkillRoll(rProcessedRoll.sDesc)
	if not bStealth and not bPerception then return end

	-- Key off the combined roll: crit continuation rolls don't carry sUniqueValue themselves, but
	-- their sPrevRoll JSON preserves the original roll's value.
	local sKey = getRollProcessingKey("skill", rTarget, rProcessedRoll)
	if sKey then
		if aProcessedRollKeys[sKey] then return end
		markRollProcessed(sKey)
	end

	if bStealth then
		displayProcessStealthUpdateForSkillHandlers(rSource, rProcessedRoll)
	else
		displayProcessActivePerception(rSource, rProcessedRoll)
	end
end

function processChatCommand(_, sParams)
	local sFailedSubcommand = processHostOnlySubcommands(sParams)
	if sFailedSubcommand then
		displayChatMessage("Unrecognized subcommand: " .. sFailedSubcommand, SECRET)
	end
end

function processHostOnlySubcommands(sSubcommand)
	if sSubcommand == "" then
		local nodeActiveCT = CombatManager.getActiveCT()
		if not nodeActiveCT then
			displayChatMessage("No active Combat Tracker actor.", SECRET)
		else
			displayStealthCheckInformationWithConditionAndVerboseChecks(nodeActiveCT, FORCE_DISPLAY)
		end
		return
	end

	if sSubcommand == "clear" then
		local aOutput = {}
		getFormattedAndClearAllStealthTrackerDataFromCTIfAllowed(aOutput, true)
		displayTableIfNonEmpty(aOutput, FORCE_DISPLAY)
		return
	end

	return sSubcommand
end

function requestActivation(nodeEntry, bSkipBell)
    if type(CombatManager_requestActivation) == "function" then
        CombatManager_requestActivation(nodeEntry, bSkipBell)
    end
    if not isValidCTNode(nodeEntry) then return end

    ensureStealthSkillExistsOnNpc(nodeEntry)
	displayStealthCheckInformationWithConditionAndVerboseChecks(nodeEntry, false)
end

function setNodeWithStealthValue(sCTNode, nStealthTotal)
	if sCTNode == nil or nStealthTotal == nil then return end

	local nodeCT = ActorManager.getCTNode(sCTNode)
	if not nodeCT then return end

	deleteAllStealthEffects(nodeCT)

	local sEffectName = string.format("%s: %d", LOCALIZED_STEALTH, nStealthTotal)
	local nCurrentActorInit = DB.getValue(nodeCT, "initresult", 0)
	local nEffectExpirationInit = nCurrentActorInit - .1
	local nEffectDuration = 0
	if checkExpireActionAndRound() then
		nEffectDuration = 2
	end

	local nEffectGMOnly = booleanToNumber(isPlayerStealthInfoDisabled() or (isNpc(nodeCT) and not isFriend(nodeCT)))
	local rEffect = {
		sName = sEffectName,
		nInit = nEffectExpirationInit,
		nDuration = nEffectDuration,
		nGMOnly = nEffectGMOnly
	}

	EffectManager.addEffect("", "", nodeCT, rEffect, true)
end

function validateTableOrNew(aTable)
	if aTable and type(aTable) == "table" then
		return aTable
	else
		return {}
	end
end
