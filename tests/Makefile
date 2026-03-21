LUA ?= lua

.PHONY: test install check

## Run all tests (requires lua >= 5.3)
test:
	cd $(dir $(abspath $(lastword $(MAKEFILE_LIST)))) && $(LUA) run_all.lua

## Install lua via Homebrew (macOS)
install:
	brew install lua

## Check lua version
check:
	$(LUA) -v
