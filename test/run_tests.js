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
        -- share a real backing table (not no-ops) so tests can verify onInit()'s handler-capture
        -- behavior, including the double-init self-reference regression (see GROUP N below).
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

        -- Run onInit to register everything and populate aOriginalResultHandlers
        onInit()

        -- Mock ruleset original handler for critRoll
        aOriginalResultHandlers["critRoll"] = function(rSource, rTarget, rRoll)
            rRoll.nMod = 10 -- original roll of 10
        end
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

    // --- GROUP N: onInit() Idempotency (Stack Overflow Regression) ---
    // Regression test for a real reported bug: a second onInit() call (e.g. from a script/extension
    // reload without restarting FGU) used to re-capture the extension's own onRollAttack/onRollSkill
    // wrappers as the "original" ruleset handler in aOriginalResultHandlers, so every subsequent
    // roll dispatched to e.g. onRollAttack, which called "the original" (itself) and recursed
    // forever, overflowing the Lua stack. onInit() was already called once above (GROUP M setup).
    await runAssert(
        "aOriginalResultHandlers['attack'] unchanged after a second onInit() call",
        true,
        `
            local before = aOriginalResultHandlers["attack"]
            onInit() -- second call; must be a no-op due to the init guard
            local after = aOriginalResultHandlers["attack"]
            return before == after
        `
    );
    await runAssert(
        "aOriginalResultHandlers['attack'] is never onRollAttack itself",
        true,
        "return aOriginalResultHandlers[\"attack\"] ~= onRollAttack"
    );
    await runAssert(
        "aOriginalResultHandlers['skillroll'] is never onRollSkill itself",
        true,
        "return aOriginalResultHandlers[\"skillroll\"] ~= onRollSkill"
    );

    // --- GROUP O: Attack Roll Type Dispatch Routing (case-sensitivity regression) ---
    // "classrollAttack" (capital A) must route to onRollAttack, not onRollSkill - a previous
    // case-sensitive pattern match ("attack" vs "Attack") silently misrouted it. Checked in a single
    // round trip (rather than one doString per assertion) to avoid wasmoon cross-call flakiness
    // observed when repeatedly comparing function references pulled from ActionsManager.aHandlers.
    await runAssert(
        "attack roll types route to the correct handler (classrollAttack/attack -> onRollAttack, skillroll -> onRollSkill)",
        true,
        `
            return ActionsManager.aHandlers["classrollAttack"] == onRollAttack
                and ActionsManager.aHandlers["attack"] == onRollAttack
                and ActionsManager.aHandlers["skillroll"] == onRollSkill
        `
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
