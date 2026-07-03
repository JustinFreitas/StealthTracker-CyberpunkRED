const fs = require('fs');
const path = require('path');
const assert = require('assert');
const { LuaFactory } = require('wasmoon');

async function runTests() {
    console.log("Setting up Lua VM via wasmoon...");
    const luaFactory = new LuaFactory();
    const lua = await luaFactory.createEngine();

    // 1. Mock the FGU Global Environment in the Lua State
    console.log("Mocking FGU environment globals...");
    
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

        function ActorManager.getCreatureNode(v) return v end
        function ActorManager.getRecordType(v) return v.recordType or "pc" end
        function ActorManager.getCTNode(v) return v end

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

        -- Mock OptionsManager
        function OptionsManager.getOption(key) return "off" end
        function OptionsManager.isOption(key, val) return false end
        
        -- Mock register callbacks to avoid crashes on load
        function ActionsManager.registerResultHandler() end
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

    // --- TEST 1: booleanToNumber ---
    await runAssert("booleanToNumber(true)", 1, "return booleanToNumber(true)");
    await runAssert("booleanToNumber(false)", 0, "return booleanToNumber(false)");

    // --- TEST 2: checkAllowOutOfCombat ---
    await runAssert("checkAllowOutOfCombat() default", false, "return checkAllowOutOfCombat()");

    // --- TEST 3: checkAllowOutOfCombat custom options ---
    await lua.doString(`
        function OptionsManager.isOption(key, val)
            if key == "STEALTHTRACKER_ALLOW_OUT_OF" and val == "all" then return true end
            return false
        end
    `);
    await runAssert("checkAllowOutOfCombat() enabled", true, "return checkAllowOutOfCombat()");

    // --- TEST 4: getPassivePerceptionNumber (with fallback DB scan)
    // Setup mock character node (intelligence = 6, perception = 4)
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
    
    // Run the calculation (Base 5 + INT 6 + PERC Base 4 = 15)
    await runAssert("getPassivePerceptionNumber(mockPC)", 15, "return getPassivePerceptionNumber(mockPCNode)");

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
