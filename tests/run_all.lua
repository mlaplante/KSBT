------------------------------------------------------------------------
-- TrueStrike Test Suite Entry Point
-- Run from the tests/ directory: lua run_all.lua
------------------------------------------------------------------------

-- Prepend tests/ dir to package path so require() finds local modules
local scriptDir = debug.getinfo(1, "S").source:match("@(.+/)")
    or "./"
package.path = scriptDir .. "?.lua;" .. package.path

-- Bootstrap WoW API stubs (must happen before loading any probe modules)
dofile(scriptDir .. "wow_stub.lua")

print("TrueStrike Test Suite")
print(string.rep("=", 40))

-- Load runner as global so test files can require() it
local T = require("runner")

-- Run test suites
dofile(scriptDir .. "test_outgoing.lua")
dofile(scriptDir .. "test_incoming.lua")

-- Print summary and exit with appropriate code
T.summary()
