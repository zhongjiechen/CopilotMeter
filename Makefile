SHELL := /bin/bash
APP_NAME := CopilotMeter
BUILD_DIR := build
APP_BUNDLE := $(BUILD_DIR)/$(APP_NAME).app

.PHONY: build app run debug clean install uninstall reset-cache icon

build:
	@arch -arm64 swift build -c release --arch arm64

icon:
	@bash Scripts/generate-icon.sh

app:
	@bash Scripts/build-app.sh

run: app
	@open "$(APP_BUNDLE)"

debug:
	@arch -arm64 swift build --arch arm64

clean:
	@rm -rf .build $(BUILD_DIR)

install: app
	@rm -rf "/Applications/$(APP_NAME).app"
	@cp -R "$(APP_BUNDLE)" "/Applications/"
	@echo "Installed to /Applications/$(APP_NAME).app"

uninstall:
	@rm -rf "/Applications/$(APP_NAME).app"
	@echo "Uninstalled"

reset-cache:
	@rm -f "$$HOME/Library/Application Support/CopilotMeter/cache.db"*
	@echo "Cache cleared"
