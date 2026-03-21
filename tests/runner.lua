------------------------------------------------------------------------
-- Minimal test runner for Kroth Scrolling Battle Text unit tests.
-- Usage: local T = require("runner")
--        T.test("my test", function() T.eq(1, 1) end)
--        T.summary()
------------------------------------------------------------------------

local M = {}
M._passed = 0
M._failed = 0
M._suite  = ""

function M.suite(name)
    M._suite = name
    print("\n-- " .. name .. " --")
end

function M.test(name, fn)
    local ok, err = pcall(fn)
    if ok then
        M._passed = M._passed + 1
        io.write("  [PASS] " .. name .. "\n")
    else
        M._failed = M._failed + 1
        io.write("  [FAIL] " .. name .. "\n")
        io.write("         " .. tostring(err) .. "\n")
    end
end

-- Assert a == b
function M.eq(a, b, msg)
    if a ~= b then
        error((msg or "expected equal") .. ": got " .. tostring(a) .. ", want " .. tostring(b), 2)
    end
end

-- Assert a ~= b
function M.neq(a, b, msg)
    if a == b then
        error((msg or "expected not equal") .. ": both = " .. tostring(a), 2)
    end
end

-- Assert value is truthy
function M.ok(v, msg)
    if not v then
        error(msg or "expected truthy value", 2)
    end
end

-- Assert string contains substring
function M.contains(str, sub, msg)
    if type(str) ~= "string" or not str:find(sub, 1, true) then
        error((msg or "expected to contain") .. ": '" .. tostring(str) .. "' does not contain '" .. tostring(sub) .. "'", 2)
    end
end

-- Assert string does not contain substring
function M.not_contains(str, sub, msg)
    if type(str) == "string" and str:find(sub, 1, true) then
        error((msg or "expected NOT to contain") .. ": '" .. tostring(str) .. "' contains '" .. tostring(sub) .. "'", 2)
    end
end

-- Assert count == n
function M.count(tbl, n, msg)
    local len = #tbl
    if len ~= n then
        error((msg or "expected count") .. ": got " .. tostring(len) .. ", want " .. tostring(n), 2)
    end
end

function M.summary()
    print(string.format("\n%d passed, %d failed", M._passed, M._failed))
    if M._failed > 0 then os.exit(1) end
end

return M
