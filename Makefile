BOLD  := \033[1m
CYAN  := \033[36m
GREEN := \033[32m
RESET := \033[0m

.DEFAULT_GOAL := help

DIST := .local/dist
APP := $(DIST)/Etui.app
VERSION := $(shell /usr/libexec/PlistBuddy -c 'Print CFBundleShortVersionString' Info.plist)
DMG := $(DIST)/Etui-$(VERSION).dmg
TARGET := /Applications/Etui.app
TESTING_MACROS := $(shell dirname $(shell xcrun --find swift))/../lib/swift/host/plugins/testing/libTestingMacros.dylib
IDENTITY = $(shell security find-identity -v -p codesigning 2>/dev/null | awk -F '"' '/Apple Development: / { print $$2; exit }')

IME := $(DIST)/Pinyin.app
IME_TARGET := $(HOME)/Library/Input Methods/Pinyin.app
RIME := .local/librime-1.17.0
RIME_ASSET := rime-33e7814-macOS-universal.tar.bz2
RIME_SHA256 := 11d8dc663c6ec06d5ccb6111ba664a9e7b631b703ac6acd07cffbac664021850
ICE_REV := 3aea6d3694fb3d94ec663641f021f788822897ad
ICE := .local/rime-ice-$(ICE_REV)

# ── Build ────────────────────────────────────────────────────────────────────

.PHONY: build check

build: ## Release build of Etui and Pinyin
	swift build -c release

check: ## Run tests
	swift test -Xswiftc -load-plugin-library -Xswiftc "$(TESTING_MACROS)"
	@printf '\n$(GREEN)  ✓ All checks passed$(RESET)\n\n'

# ── App ──────────────────────────────────────────────────────────────────────

.PHONY: app dmg install uninstall

app: build ## Package .local/dist/Etui.app
	rm -rf "$(APP)"
	mkdir -p "$(APP)/Contents/MacOS" "$(APP)/Contents/Resources"
	cp Info.plist "$(APP)/Contents/Info.plist"
	cp Resources/AppIcon.icns "$(APP)/Contents/Resources/AppIcon.icns"
	cp .build/release/Etui "$(APP)/Contents/MacOS/Etui"
	cp .build/release/Etui "$(APP)/Contents/MacOS/DisplayGuardian"
	@identity="$(IDENTITY)"; \
	echo "Etui: signing as $${identity:-adhoc, accessibility grant resets on every install}"; \
	codesign --force --sign "$${identity:--}" "$(APP)/Contents/MacOS/DisplayGuardian" && \
	codesign --force --sign "$${identity:--}" "$(APP)"
	@printf '$(GREEN)  ✓ %s$(RESET)\n' "$(APP)"

dmg: app ## Package .local/dist/Etui-<version>.dmg
	rm -rf "$(DIST)/stage" "$(DMG)"
	mkdir -p "$(DIST)/stage"
	cp -R "$(APP)" "$(DIST)/stage/"
	ln -s /Applications "$(DIST)/stage/Applications"
	diskutil image create from --format UDZO --volumeName Etui "$(DIST)/stage" "$(DMG)"
	@printf '$(GREEN)  ✓ %s$(RESET)\n' "$(DMG)"

install: app ## Replace /Applications/Etui.app and launch it
	-pkill -f "$(TARGET)/Contents/MacOS/Etui"
	rm -rf "$(TARGET)"
	cp -R "$(APP)" "$(TARGET)"
	open "$(TARGET)"

uninstall: ## Quit and remove /Applications/Etui.app
	-pkill -f "$(TARGET)/Contents/MacOS/Etui"
	rm -rf "$(TARGET)"

# ── Input Method ─────────────────────────────────────────────────────────────

.PHONY: ime install-ime uninstall-ime

$(RIME)/dist/lib/librime.1.dylib:
	mkdir -p $(RIME)
	curl -fsSL -o $(RIME)/$(RIME_ASSET) https://github.com/rime/librime/releases/download/1.17.0/$(RIME_ASSET)
	echo "$(RIME_SHA256)  $(RIME)/$(RIME_ASSET)" | shasum -a 256 -c -
	tar -xjf $(RIME)/$(RIME_ASSET) -C $(RIME)

$(ICE)/rime_ice.schema.yaml:
	rm -rf $(ICE)
	git init -q $(ICE)
	git -C $(ICE) fetch -q --depth 1 https://github.com/iDvel/rime-ice $(ICE_REV)
	git -C $(ICE) checkout -q FETCH_HEAD

ime: build $(RIME)/dist/lib/librime.1.dylib $(ICE)/rime_ice.schema.yaml ## Package .local/dist/Pinyin.app with prebuilt dictionaries
	rm -rf "$(IME)" "$(DIST)/rime-user"
	mkdir -p "$(IME)/Contents/MacOS" "$(IME)/Contents/Resources" "$(IME)/Contents/Frameworks"
	cp Resources/Pinyin/Info.plist "$(IME)/Contents/Info.plist"
	cp -R Resources/Pinyin/Pinyin.pdf Resources/Pinyin/*.lproj "$(IME)/Contents/Resources/"
	cp .build/release/Pinyin "$(IME)/Contents/MacOS/Pinyin"
	cp -RL $(RIME)/dist/lib/librime.1.dylib $(RIME)/dist/lib/rime-plugins "$(IME)/Contents/Frameworks/"
	rsync -a --exclude .git $(ICE)/ "$(IME)/Contents/SharedSupport/"
	cp Resources/Pinyin/*.yaml "$(IME)/Contents/SharedSupport/"
	DYLD_LIBRARY_PATH=$(RIME)/dist/lib $(RIME)/dist/bin/rime_deployer --build "$(DIST)/rime-user" \
		"$(IME)/Contents/SharedSupport" "$(IME)/Contents/SharedSupport/build" 2> "$(DIST)/rime-deploy.log"
	rm -rf "$(DIST)/rime-user" "$(IME)/Contents/SharedSupport/cn_dicts" "$(IME)/Contents/SharedSupport/en_dicts" \
		"$(IME)/Contents/SharedSupport/"*.dict.yaml
	@identity="$(IDENTITY)"; \
	echo "Pinyin: signing as $${identity:-adhoc}"; \
	codesign --force --sign "$${identity:--}" "$(IME)/Contents/Frameworks/librime.1.dylib" "$(IME)/Contents/Frameworks/rime-plugins/"*.dylib && \
	codesign --force --sign "$${identity:--}" "$(IME)"
	@printf '$(GREEN)  ✓ %s$(RESET)\n' "$(IME)"

install-ime: ime ## Replace ~/Library/Input Methods/Pinyin.app and register it
	-pkill -f "$(IME_TARGET)/Contents/MacOS/Pinyin"
	rm -rf "$(IME_TARGET)"
	mkdir -p "$(HOME)/Library/Input Methods"
	cp -R "$(IME)" "$(IME_TARGET)"
	"$(IME_TARGET)/Contents/MacOS/Pinyin" --register

uninstall-ime: ## Quit and remove the installed Pinyin.app
	-pkill -f "$(IME_TARGET)/Contents/MacOS/Pinyin"
	rm -rf "$(IME_TARGET)"

# ── Maintenance ──────────────────────────────────────────────────────────────

.PHONY: clean

clean: ## Remove .build and .local/dist
	rm -rf .build "$(DIST)"

# ── Help ─────────────────────────────────────────────────────────────────────

.PHONY: help

help: ## Show available targets
	@awk 'BEGIN {FS = ":.*## "; printf "\n$(BOLD)Etui$(RESET) — macOS launcher, clipboard, tiler, translator, and screenshots\n"} \
		/^# ── / {n = $$0; gsub(/(^# ── | (─)+$$)/, "", n); printf "\n$(BOLD)%s$(RESET)\n", n} \
		/^[a-zA-Z_-]+:.*## / {printf "  $(CYAN)make %-14s$(RESET) %s\n", $$1, $$2} \
		END {printf "\n"}' $(MAKEFILE_LIST)
