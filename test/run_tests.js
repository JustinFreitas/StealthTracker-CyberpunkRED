const fs = require('fs');
const path = require('path');
const assert = require('assert');
const { LuaFactory } = require('wasmoon');

async function runTests() {
    console.log("Setting up Lua VM via wasmoon...");
    const luaFactory = new LuaFactory();
    const lua = await luaFactory.createEngine();

    // Bind jsonParse JS helper for the Lua VM
    lua.global.set('jsonParse', (str) => {
        try {
            return JSON.parse(str);
        } catch (e) {
            return null;
        }
    });

    // Stub global tables and methods
    await lua.doString(`
        ActorManager = {}
        DB = {}
        OptionsManager = {}
        Comm = {}
        Interface = {}
        User = {}
        ActionsManager = {}
        EffectManager = {}
        OOBManager = {}
        StringManager = {}
        Json = { parse = jsonParse }

        -- Mock StringManager behavior
        function StringManager.isBlank(s)
            return s == nil or s == "" or s:gsub("%s+", "") == ""
        end

        -- Helper to create a mock databasenode
        function createMockNode(data)
            local node = {}
            node.data = data or {}
            
            function node.getPath() return "mock.path" end
            function node.getName() return "mockname" end
            
            function node.getChild(path)
                -- Support dot-separated paths
                local val = node.data
                for part in string.gmatch(path, "[^%.]+") do
                    if type(val) == "table" then
                        val = val[part]
                    else
                        return nil
                    end
                end
                
                if val == nil then return nil end
                if type(val) == "table" then
                    return createMockNode(val)
                else
                    -- Leaf node
                    local leaf = {}
                    function leaf.getType() return type(val) == "number" and "number" or "string" end
                    function leaf.getValue() return val end
                    function leaf.getText() return val end
                    return leaf
                end
            end
            
            function node.getType() return "node" end
            function node.getChildren()
                local children = {}
                for k, v in pairs(node.data) do
                    if type(v) == "table" then
                        children[k] = createMockNode(v)
                    else
                        local leaf = {}
                        function leaf.getType() return type(v) == "number" and "number" or "string" end
                        function leaf.getValue() return v end
                        function leaf.getText() return v end
                        children[k] = leaf
                    end
                end
                return children
            end
            
            return node
        end

        -- Mock ActorManager APIs
        function ActorManager.getCreatureNode(v) return v end
        function ActorManager.getActor(v) return v end
        function ActorManager.getRecordType(v)
            if type(v) == "table" and type(v.getChild) == "function" then
                local nodeType = v.getChild("recordType")
                if nodeType then return nodeType.getValue() end
            end
            if type(v) == "table" and v.recordType then return v.recordType end
            return "pc"
        end
        function ActorManager.getCTNode(v) return v end
        function ActorManager.getFaction(v)
            if type(v) == "table" and type(v.getChild) == "function" then
                local nodeFaction = v.getChild("faction")
                if nodeFaction then return nodeFaction.getValue() end
            end
            if type(v) == "table" and v.faction then return v.faction end
            return "friend"
        end
        function ActorManager.getDisplayName(v) return v.displayName or "MockActor" end

        -- Mock DB APIs
        function DB.getValue(node, path, default)
            if type(node) == "table" and type(node.getChild) == "function" then
                local child = node.getChild(path)
                if child then return child.getValue() end
            end
            if type(node) == "table" and node[path] ~= nil then
                return node[path]
            end
            return default
        end
        
        function DB.getText(node, path, default)
            return DB.getValue(node, path, default) or ""
        end

        -- Mock OptionsManager
        function OptionsManager.getOption(key) return "off" end
        function OptionsManager.isOption(key, val) return false end
        
        -- Mock register callbacks to avoid crashes on load. registerResultHandler/getResultHandler
        -- share a real backing table (not no-ops) so tests can verify that onInit() leaves the
        -- ruleset's registered result handlers untouched (see GROUP N below).
        ActionsManager.aHandlers = {}
        function ActionsManager.registerResultHandler(sType, fHandler)
            ActionsManager.aHandlers[sType] = fHandler
        end
        function ActionsManager.getResultHandler(sType)
            return ActionsManager.aHandlers[sType]
        end
        function ActionsManager.registerPostRollHandler() end
        function OOBManager.registerOOBMsgHandler() end
        function Comm.registerSlashHandler() end

        -- Simulate the CyberpunkRED ruleset registering its own result handlers (CommonRolls.lua
        -- routes "attack"/"skillroll"/"classroll"/"classrollAttack" to the same function).
        function mockRulesetOnSkillRoll() end
        function mockRulesetOnCritRoll() end
        ActionsManager.registerResultHandler("skillroll", mockRulesetOnSkillRoll)
        ActionsManager.registerResultHandler("classroll", mockRulesetOnSkillRoll)
        ActionsManager.registerResultHandler("classrollAttack", mockRulesetOnSkillRoll)
        ActionsManager.registerResultHandler("attack", mockRulesetOnSkillRoll)
        ActionsManager.registerResultHandler("critRoll", mockRulesetOnCritRoll)
        ActionsManager.registerResultHandler("critSkillRoll", mockRulesetOnCritRoll)

        -- Mock the CoreRPG GameManager layered hook registry (single slot per key/subkey), which
        -- ActionsManager.resolveAction invokes as onActionPostResolve after the result handler.
        GameManager = {}
        GameManager.aMultiKey = {}
        function GameManager.setMultiKeyFunction(sKey, sSubKey, fn)
            GameManager.aMultiKey[sKey] = GameManager.aMultiKey[sKey] or {}
            GameManager.aMultiKey[sKey][sSubKey or ""] = fn
        end
        function GameManager.getMultiKeyFunction(sKey, sSubKey)
            return GameManager.aMultiKey[sKey] and GameManager.aMultiKey[sKey][sSubKey or ""]
        end
    `);

    // 2. Load the actual StealthTracker script
    console.log("Loading scripts/stealthtracker.lua into VM...");
    const luaCodePath = path.join(__dirname, '../scripts/stealthtracker.lua');
    const luaCode = fs.readFileSync(luaCodePath, 'utf8');
    
    await lua.doString(luaCode);
    console.log("StealthTracker loaded successfully inside VM.\n");

    // 3. Define and run test assertions
    console.log("Running Unit Tests...");
    let testsPassed = 0;
    let testsFailed = 0;

    async function runAssert(fnName, expected, luaCodeToRun) {
        try {
            const result = await lua.doString(luaCodeToRun);
            assert.strictEqual(result, expected);
            console.log(`  ✓ PASS: ${fnName} -> got ${result}`);
            testsPassed++;
        } catch (err) {
            console.error(`  ✗ FAIL: ${fnName} -> expected ${expected}, got error or mismatch: ${err.message}`);
            testsFailed++;
        }
    }

    // --- GROUP A: Core Math & Conversions ---
    await runAssert("booleanToNumber(true)", 1, "return booleanToNumber(true)");
    await runAssert("booleanToNumber(false)", 0, "return booleanToNumber(false)");

    // --- GROUP B: Settings & Flags ---
    await runAssert("checkAllowOutOfCombat() default", false, "return checkAllowOutOfCombat()");
    await lua.doString(`
        function OptionsManager.isOption(key, val)
            if key == "STEALTHTRACKER_ALLOW_OUT_OF" and val == "all" then return true end
            return false
        end
    `);
    await runAssert("checkAllowOutOfCombat() enabled", true, "return checkAllowOutOfCombat()");
    
    // Reset isOption stub
    await lua.doString(`function OptionsManager.isOption() return false end`);

    // --- GROUP C: Roll Type Identification ---
    await runAssert("isStealthSkillRoll('Stealth Check')", true, "return isStealthSkillRoll('Stealth Check')");
    await runAssert("isStealthSkillRoll('Perception')", false, "return isStealthSkillRoll('Perception')");
    
    await runAssert("isDexterityCheckRoll('Dex check')", true, "return isDexterityCheckRoll('Dex check')");
    await runAssert("isDexterityCheckRoll('Intelligence')", false, "return isDexterityCheckRoll('Intelligence')");
    
    await runAssert("isPerceptionSkillRoll('[Skill] Perception(5)')", true, "return isPerceptionSkillRoll('[Skill] Perception(5)')");
    await runAssert("isPerceptionSkillRoll('Stealth')", false, "return isPerceptionSkillRoll('Stealth')");
    // Regression: "Human Perception" is a distinct CPR skill and must NOT be treated as "Perception".
    await runAssert("isPerceptionSkillRoll('[Skill] Human Perception(3)') excludes Human Perception", false, "return isPerceptionSkillRoll('[Skill] Human Perception(3)')");

    // --- GROUP D: Character / Actor Checks ---
    await lua.doString(`
        mockPC = createMockNode({ recordType = "pc", faction = "friend" })
        mockNPC = createMockNode({ recordType = "npc", faction = "foe" })
    `);
    await runAssert("isNpc(mockNPC)", true, "return isNpc(mockNPC)");
    await runAssert("isNpc(mockPC)", false, "return isNpc(mockPC)");
    
    await runAssert("isFriend(mockPC)", true, "return isFriend(mockPC)");
    await runAssert("isFriend(mockNPC)", false, "return isFriend(mockNPC)");

    await runAssert("isDifferentFaction(mockPC, mockNPC)", true, "return isDifferentFaction(mockPC, mockNPC)");
    await runAssert("isDifferentFaction(mockPC, mockPC)", false, "return isDifferentFaction(mockPC, mockPC)");

    // --- GROUP E: Unidentified NPC Names ---
    await lua.doString(`
        nodeUnidentified = createMockNode({
            recordType = "npc",
            isidentified = 0,
            nonid_name = "Scary Cyborg"
        })
        nodeIdentified = createMockNode({
            recordType = "npc",
            isidentified = 1,
            nonid_name = "Scary Cyborg"
        })
    `);
    await runAssert("isUnidentifiedNpc(nodeUnidentified)", true, "return isUnidentifiedNpc(nodeUnidentified)");
    await runAssert("isUnidentifiedNpc(nodeIdentified)", false, "return isUnidentifiedNpc(nodeIdentified)");
    await runAssert("getUnidentifiedName(nodeUnidentified)", "Scary Cyborg", "return getUnidentifiedName(nodeUnidentified)");

    // --- GROUP F: Effect Exclusions & Stealth values ---
    await lua.doString(`
        -- Mock EffectManager helper
        EffectManager.parseEffect = function(label) return { label } end

        nodeEffectStealth = createMockNode({ label = "Stealth: 14" })
        nodeEffectOther = createMockNode({ label = "ATK: +2" })
    `);
    await runAssert("getStealthValueFromEffectNode('Stealth: 14')", "14", "return getStealthValueFromEffectNode(nodeEffectStealth)");
    await runAssert("getStealthValueFromEffectNode('ATK: +2')", null, "return getStealthValueFromEffectNode(nodeEffectOther)");

    // --- GROUP G: Passive Perception Math ---
    await lua.doString(`
        mockPCNode = createMockNode({
            stats = {
                intelligence = {
                    value = 6
                }
            },
            skillsCol = {
                perception = {
                    skillName = "Perception",
                    skillBase = 4,
                    skillLvl = 4
                }
            }
        })
    `);
    await runAssert("getPassivePerceptionNumber(mockPC)", 15, "return getPassivePerceptionNumber(mockPCNode)");

    // --- GROUP H: Combat Tracker Node Validity ---
    await lua.doString(`
        nodeValidPC = createMockNode({ recordType = "pc", faction = "friend" })
        nodeValidNPC = createMockNode({ recordType = "npc", faction = "foe" })
        nodeInvalidType = createMockNode({ recordType = "hazard", faction = "neutral" })
    `);
    await runAssert("isValidCTNode(nodeValidPC)", true, "return isValidCTNode(nodeValidPC)");
    await runAssert("isValidCTNode(nodeValidNPC)", true, "return isValidCTNode(nodeValidNPC)");
    await runAssert("isValidCTNode(nodeInvalidType)", false, "return isValidCTNode(nodeInvalidType)");

    // --- GROUP I: doesTargetPerceiveAttackerFromStealth (Condition Coverage) ---
    // Target perception calculated = 15 (Base 5 + INT 6 + PERC 4)
    await lua.doString(`
        mockTarget = mockPCNode
    `);
    // Case 1: Attacker Stealth is 14 (lower than target perception 15) -> returns true (spotted)
    await runAssert("doesTargetPerceiveAttackerFromStealth(14) [spotted]", true, "return doesTargetPerceiveAttackerFromStealth(14, mockTarget)");
    // Case 2: Attacker Stealth is 15 (equal to target perception 15) -> returns true (spotted)
    await runAssert("doesTargetPerceiveAttackerFromStealth(15) [spotted]", true, "return doesTargetPerceiveAttackerFromStealth(15, mockTarget)");
    // Case 3: Attacker Stealth is 16 (higher than target perception 15) -> returns false (hidden)
    await runAssert("doesTargetPerceiveAttackerFromStealth(16) [hidden]", false, "return doesTargetPerceiveAttackerFromStealth(16, mockTarget)");

    // --- GROUP J: getActorDebilitatingCondition (Condition Coverage) ---
    await lua.doString(`
        -- Mock helper to scan effects table
        function EffectManager.hasEffect(rActor, sEffect)
            if rActor.data and rActor.data.effects then
                for _, eff in ipairs(rActor.data.effects) do
                    if eff == sEffect then return true end
                end
            end
            return false
        end

        actorDead = createMockNode({ recordType = "npc", effects = { "dead" } })
        actorUnconscious = createMockNode({ recordType = "npc", effects = { "unconscious" } })
        actorStunned = createMockNode({ recordType = "npc", effects = { "stunned" } })
        actorHealthy = createMockNode({ recordType = "npc", effects = {} })
    `);
    await runAssert("getActorDebilitatingCondition(dead)", "dead", "return getActorDebilitatingCondition(actorDead)");
    await runAssert("getActorDebilitatingCondition(unconscious)", "unconscious", "return getActorDebilitatingCondition(actorUnconscious)");
    await runAssert("getActorDebilitatingCondition(stunned)", "stunned", "return getActorDebilitatingCondition(actorStunned)");
    await runAssert("getActorDebilitatingCondition(healthy)", null, "return getActorDebilitatingCondition(actorHealthy)");

    // --- GROUP K: isStealthTrackerDisabledForActor (Condition Coverage) ---
    await lua.doString(`
        actorDisabled = createMockNode({ senses = "No StealthTracker, Low-Light Vision" })
        actorDisabledNotes = createMockNode({ notes = "Some gm notes, no stealthtracker here" })
        actorDisabledDesc = createMockNode({ description = "Drone unit (No StealthTracker)" })
        actorEnabledSenses = createMockNode({ senses = "Infrared Vision" })
    `);
    await runAssert("isStealthTrackerDisabledForActor(disabled senses)", "no stealthtracker", "return isStealthTrackerDisabledForActor(actorDisabled)")
    await runAssert("isStealthTrackerDisabledForActor(disabled notes)", "no stealthtracker", "return isStealthTrackerDisabledForActor(actorDisabledNotes)")
    await runAssert("isStealthTrackerDisabledForActor(disabled desc)", "no stealthtracker", "return isStealthTrackerDisabledForActor(actorDisabledDesc)")
    await runAssert("isStealthTrackerDisabledForActor(enabled)", null, "return isStealthTrackerDisabledForActor(actorEnabledSenses)");

    // --- GROUP L: isValidCTNode with Disabled Senses/Notes/Desc (Condition Coverage) ---
    await lua.doString(`
        actorPCDisabled = createMockNode({ recordType = "pc", senses = "No StealthTracker" })
        actorNPCDisabled = createMockNode({ recordType = "npc", notes = "No StealthTracker" })
    `);
    await runAssert("isValidCTNode(PC disabled)", false, "return isValidCTNode(actorPCDisabled)");
    await runAssert("isValidCTNode(NPC disabled)", false, "return isValidCTNode(actorNPCDisabled)");

    // --- GROUP M: Exploding Critical Success Roll ('critRoll') ---
    await lua.doString(`
        User.isHost = function() return false end
        ActionsManager.doesRollHaveDice = function(rRoll) return true end
        ActionsManager.total = function(rRoll)
            local nTotal = 0
            if rRoll.aDice then
                for _, d in ipairs(rRoll.aDice) do
                    nTotal = nTotal + d.result
                end
            end
            nTotal = nTotal + (rRoll.nMod or 0)
            return nTotal
        end

        DB.getChildren = function(node, path)
            if node and type(node.getChild) == "function" then
                local childNode = node.getChild(path)
                if childNode and type(childNode.getChildren) == "function" then
                    return childNode.getChildren()
                end
            end
            return {}
        end

        CombatManager = {}
        CombatManager.getActiveCT = function() return mockActiveCT end

        local origGetCTNode = ActorManager.getCTNode
        ActorManager.getCTNode = function(v)
            if v == "mock.path" then
                return mockActiveCT
            end
            return origGetCTNode(v)
        end

        lastEffectAdded = nil
        EffectManager.addEffect = function(sUser, sIdentity, nodeCT, rEffect, bShowMsg)
            lastEffectAdded = rEffect
        end

        -- Simulate another extension already occupying the "attack" onActionPostResolve slot, to
        -- verify onInit() chains it rather than clobbering it.
        prevPostResolveCalls = 0
        GameManager.setMultiKeyFunction("onActionPostResolve", "attack", function()
            prevPostResolveCalls = prevPostResolveCalls + 1
        end)

        -- Run onInit to register the post-resolve observers
        onInit()
    `);

    await runAssert(
        "onRollSkill skips primary roll of 10",
        null,
        `
            USER_ISHOST = true
            local rSource = createMockNode({ recordType = "pc" })
            mockActiveCT = rSource
            lastEffectAdded = nil
            local rRoll = {
                sType = "skillroll",
                sDesc = "Stealth Check",
                aDice = { { type = "d10", result = 10 } }
            }
            onRollSkill(rSource, nil, rRoll)
            return lastEffectAdded and lastEffectAdded.sName
        `
    );

    await runAssert(
        "onRollSkill processes exploding critRoll correctly",
        "Stealth: 16",
        `
            USER_ISHOST = true
            local rSource = createMockNode({ recordType = "pc" })
            mockActiveCT = rSource
            lastEffectAdded = nil
            local rRoll = {
                sType = "critRoll",
                sDesc = "+ 1d10 [Critical Success]",
                sPrevRoll = '{"sType":"skillroll","sDesc":"Stealth Check","aDice":[{"type":"d10","result":10}],"nMod":0}',
                aDice = { { type = "d10", result = 6 } }
            }
            onRollSkill(rSource, nil, rRoll)
            return lastEffectAdded and lastEffectAdded.sName
        `
    );

    // --- GROUP N: v1.0.5 Observer Architecture Regression Suite ---
    // Regression tests for a real reported bug: the extension used to REPLACE the ruleset's
    // registered result handlers and call a captured "original". Any capture problem (e.g. two
    // copies of the extension enabled at once) made the captured "original" the extension's own
    // wrapper - infinite recursion (stack overflow) in v1.0.3, and in v1.0.4 the re-entrancy guard
    // returned early instead, so attack rolls resolved to NOTHING (no chat output at all).
    // v1.0.5 observes rolls via GameManager's onActionPostResolve hook and must leave the ruleset's
    // result handlers completely untouched.
    //
    // Also covers the FormattedText regression: chat text containing a raw "<" (e.g. the old
    // "(Perception roll 4 < Stealth 12)" message) breaks the FormattedText control with
    // "XML Error: Name cannot begin with the ' ' character, hexadecimal value 0x20".
    //
    // All sub-checks run in a SINGLE doString round trip: the wasmoon engine degrades after ~50
    // doString calls (global-environment lookups start failing with "attempt to index a nil value
    // (upvalue '_ENV')"), so batching is required, not just a nicety.
    await runAssert(
        "v1.0.5 observer suite (handlers untouched, observers installed, idempotent init, routing, chaining, dedupe, chat XML safety) - failures",
        "",
        `
            local aFailures = {}
            local function check(sName, bCondition)
                if not bCondition then table.insert(aFailures, sName) end
            end

            -- 1. onInit() must leave all ruleset result handlers untouched.
            check("handlers-untouched",
                ActionsManager.aHandlers["attack"] == mockRulesetOnSkillRoll
                and ActionsManager.aHandlers["classrollAttack"] == mockRulesetOnSkillRoll
                and ActionsManager.aHandlers["skillroll"] == mockRulesetOnSkillRoll
                and ActionsManager.aHandlers["classroll"] == mockRulesetOnSkillRoll
                and ActionsManager.aHandlers["critRoll"] == mockRulesetOnCritRoll
                and ActionsManager.aHandlers["critSkillRoll"] == mockRulesetOnCritRoll)

            -- 2. onActionPostResolve observers installed for all six roll types.
            local bAllInstalled = true
            for _, sType in ipairs({ "skillroll", "classroll", "classrollAttack", "attack", "critRoll", "critSkillRoll" }) do
                if type(GameManager.getMultiKeyFunction("onActionPostResolve", sType)) ~= "function" then
                    bAllInstalled = false
                end
            end
            check("observers-installed", bAllInstalled)

            -- 3. A second onInit() call is a no-op (init guard) - observers not re-chained.
            local fBefore = GameManager.getMultiKeyFunction("onActionPostResolve", "attack")
            onInit()
            check("double-init-noop", fBefore == GameManager.getMultiKeyFunction("onActionPostResolve", "attack"))

            -- 4. Observer routing/chaining/dedupe. Routing is verified behaviorally (the observers
            -- are wrapped in registration closures, so function identity can't be compared): the
            -- observers look up the display* globals at call time, so overriding those globals
            -- detects which observer ran.
            local nAttackObserved = 0
            local fRealDisplayAttack = displayProcessAttackFromStealth
            displayProcessAttackFromStealth = function() nAttackObserved = nAttackObserved + 1 end

            local fAttackSlot = GameManager.getMultiKeyFunction("onActionPostResolve", "attack")
            local fClassAttackSlot = GameManager.getMultiKeyFunction("onActionPostResolve", "classrollAttack")
            local rSource = createMockNode({ recordType = "pc" })

            -- "classrollAttack" (capital A) must route to the attack observer - a previous
            -- case-sensitive match silently misrouted it.
            fClassAttackSlot(rSource, nil, { sType = "classrollAttack", sUniqueValue = "u100", aDice = { { type = "d10", result = 5 } } })
            check("classrollAttack-routes-to-attack-observer", nAttackObserved == 1)

            -- Same logical roll observed twice (e.g. extension enabled twice) processes once.
            fAttackSlot(rSource, nil, { sType = "attack", sUniqueValue = "u101", aDice = { { type = "d10", result = 5 } } })
            fAttackSlot(rSource, nil, { sType = "attack", sUniqueValue = "u101", aDice = { { type = "d10", result = 5 } } })
            check("attack-dedupe", nAttackObserved == 2)

            -- The pre-existing "attack" hook (registered before onInit) must still be called.
            check("pre-existing-hook-chained", prevPostResolveCalls == 2)

            -- Crit attacks emit ONE message per logical attack: the initial exploding roll is
            -- skipped, and the combined crit continuation ("critRoll" carrying the attack in
            -- sPrevRoll) is processed exactly once, deduped on the original sUniqueValue.
            fAttackSlot(rSource, nil, { sType = "attack", sUniqueValue = "u103", aDice = { { type = "d10", result = 10 } } })
            check("exploding-attack-initial-skipped", nAttackObserved == 2)
            local fCritSlot = GameManager.getMultiKeyFunction("onActionPostResolve", "critRoll")
            local rCritContinuation = {
                sType = "critRoll",
                sDesc = "+ 1d10 [Critical Success]",
                aDice = { { type = "d10", result = 6 } },
                sPrevRoll = '{"sType":"attack","sDesc":"[Attack] Weapon: Assault Rifle","aDice":[{"type":"d10","result":10}],"nMod":0,"sUniqueValue":"u103"}'
            }
            fCritSlot(rSource, nil, rCritContinuation)
            check("crit-attack-combined-processed-once", nAttackObserved == 3)
            fCritSlot(rSource, nil, rCritContinuation)
            check("crit-attack-combined-deduped", nAttackObserved == 3)

            -- Solo Fumble Recovery: a natural 1 tagged "[Fumble recovery]" by the ruleset gets no
            -- continuation die, so it is final and must be processed now; an untagged natural 1
            -- still waits for the fumble continuation.
            fAttackSlot(rSource, nil, { sType = "attack", sUniqueValue = "u107", sDesc = "[Attack] X\\r\\n[Fumble recovery]", aDice = { { type = "d10", result = 1 } } })
            check("fumble-recovery-attack-processed", nAttackObserved == 4)
            fAttackSlot(rSource, nil, { sType = "attack", sUniqueValue = "u108", aDice = { { type = "d10", result = 1 } } })
            check("plain-fumble-attack-skipped", nAttackObserved == 4)

            -- No-range hint: ranged/thrown attacks that resolved without a DV (rRoll.nTarget nil,
            -- e.g. tokens not on a map) emit a hint; attacks with a DV, and melee, do not.
            local aHints = {}
            local fRealDisplayChatMessage = displayChatMessage
            displayChatMessage = function(sText) table.insert(aHints, sText) end
            local rTargetNode = createMockNode({ recordType = "npc" })
            fAttackSlot(rSource, rTargetNode, { sType = "attack", sUniqueValue = "u104", nIsThrown = 1, aDice = { { type = "d10", result = 5 } } })
            check("no-range-hint-emitted", #aHints == 1 and aHints[1] == ST_NO_RANGE_HINT)
            fAttackSlot(rSource, rTargetNode, { sType = "attack", sUniqueValue = "u105", nIsThrown = 1, nTarget = 16, aDice = { { type = "d10", result = 5 } } })
            check("no-hint-when-dv-known", #aHints == 1)
            fAttackSlot(rSource, rTargetNode, { sType = "attack", sUniqueValue = "u106", aDice = { { type = "d10", result = 5 } } })
            check("no-hint-for-melee", #aHints == 1)
            displayChatMessage = fRealDisplayChatMessage

            displayProcessAttackFromStealth = fRealDisplayAttack

            -- 5. Skill observer routes skillroll to stealth processing.
            local nSkillObserved = 0
            local fRealDisplayStealthUpdate = displayProcessStealthUpdateForSkillHandlers
            displayProcessStealthUpdateForSkillHandlers = function() nSkillObserved = nSkillObserved + 1 end
            local fSkillSlot = GameManager.getMultiKeyFunction("onActionPostResolve", "skillroll")
            fSkillSlot(rSource, nil, { sType = "skillroll", sDesc = "Stealth Check", sUniqueValue = "u102", aDice = { { type = "d10", result = 5 } } })
            check("skillroll-routes-to-skill-observer", nSkillObserved == 1)
            displayProcessStealthUpdateForSkillHandlers = fRealDisplayStealthUpdate

            -- 6. displayChatMessage escapes "<" and omits empty mode.
            local lastChatMessage = nil
            local fRealAddChatMessage = Comm.addChatMessage
            Comm.addChatMessage = function(msg) lastChatMessage = msg end
            local fRealGetOption = OptionsManager.getOption
            OptionsManager.getOption = function(key)
                if key == "STEALTHTRACKER_FRAME_STYLE" then return "none" end
                return "off"
            end
            displayChatMessage("a < b", true)
            check("chat-escapes-lt", lastChatMessage ~= nil and lastChatMessage.text == "a &lt; b")
            check("chat-omits-empty-mode", lastChatMessage ~= nil and lastChatMessage.mode == nil)

            -- 7. displayChatMessage sets mode when a frame style is chosen.
            OptionsManager.getOption = function(key)
                if key == "STEALTHTRACKER_FRAME_STYLE" then return "story" end
                return "off"
            end
            displayChatMessage("hello", true)
            check("chat-sets-chosen-mode", lastChatMessage ~= nil and lastChatMessage.mode == "story")
            Comm.addChatMessage = fRealAddChatMessage
            OptionsManager.getOption = fRealGetOption

            return table.concat(aFailures, ",")
        `
    );

    // --- GROUP Q: Static source checks ---
    // No chat-bound string may contain a raw "<" (breaks FormattedText rendering, see GROUP P).
    function runStaticAssert(name, condition) {
        if (condition) {
            console.log(`  ✓ PASS: ${name}`);
            testsPassed++;
        } else {
            console.error(`  ✗ FAIL: ${name}`);
            testsFailed++;
        }
    }
    const luaStringLiterals = luaCode.match(/"(?:[^"\\]|\\.)*"/g) || [];
    // Exempt '"<"' itself - it's the gsub pattern used to escape chat text.
    const literalsWithRawLt = luaStringLiterals.filter(s => s.includes("<") && !s.includes("&lt;") && s !== '"<"');
    runStaticAssert(
        `no Lua string literal contains a raw '<' (found: ${literalsWithRawLt.join(", ") || "none"})`,
        literalsWithRawLt.length === 0
    );
    runStaticAssert(
        "perception comparison messages use 'vs' wording",
        luaCode.includes("(Perception roll %d vs Stealth %d)") &&
        !luaCode.includes("(Perception roll %d >= Stealth %d)") &&
        !luaCode.includes("(Perception roll %d < Stealth %d)")
    );

    // 4. Print Summary
    console.log(`\nTest Summary: ${testsPassed} passed, ${testsFailed} failed.`);
    
    if (testsFailed > 0) {
        process.exit(1);
    }
}

runTests().catch(err => {
    console.error("Test execution failed: ", err);
    process.exit(1);
});
