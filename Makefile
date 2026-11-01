CC       := clang
ARCH     := arm64
MIN_VER  := 15.0
# The oldest macOS the product supports. mincheck holds every binary in the bundle
# to it, MIN_VER above is only what the dylib and helpers are compiled for.
MINCHECK_VER := 26.0
GLASS_SDK := 26.0
AVAIL    := -Werror=unguarded-availability-new

# The Command Line Tools can't build the app (no xcstringstool or actool). When they are the
# active developer dir, point make's commands at Xcode, as scripts/build-local.sh does.
ifeq ($(origin DEVELOPER_DIR),undefined)
ifeq ($(shell xcode-select -p 2>/dev/null),/Library/Developer/CommandLineTools)
DEVELOPER_DIR := $(firstword $(wildcard /Applications/Xcode-beta.app/Contents/Developer /Applications/Xcode.app/Contents/Developer))
ifneq ($(DEVELOPER_DIR),)
export DEVELOPER_DIR
endif
endif
endif

CFLAGS   := -arch $(ARCH) -mmacosx-version-min=$(MIN_VER) $(AVAIL) \
            -std=c17 -O2 -Wall -Wextra -Wno-unused-parameter \
            -fPIC -MMD -MP \
            -Idylib -Ivendor -Ivendor/dobby/include
LDFLAGS  := -arch $(ARCH) -mmacosx-version-min=$(MIN_VER) \
            -dynamiclib -install_name @rpath/notproton.dylib

FRAMEWORKS := -framework CoreFoundation -framework CoreGraphics

DOBBY_DIR  := build/dobby
DOBBY_LIBS := $(DOBBY_DIR)/libdobby.a \
              $(DOBBY_DIR)/builtin-plugin/SymbolResolver/libdobby_symbol_resolver.a \
              $(DOBBY_DIR)/builtin-plugin/SymbolResolver/libmacho_ctx_kit.a \
              $(DOBBY_DIR)/builtin-plugin/SymbolResolver/libshared_cache_ctx_kit.a \
              $(DOBBY_DIR)/external/osbase/libosbase.a \
              $(DOBBY_DIR)/external/logging/liblogging.a

SRCS := \
	dylib/core/loader.c \
	dylib/core/macho.c \
	dylib/resolver/anchor.c \
	dylib/resolver/aob.c \
	dylib/resolver/resolver.c \
	dylib/resolver/sigdb.c \
	dylib/util/log.c \
	dylib/util/file.c \
	dylib/util/peicon.c \
	dylib/hooks/hooks.c \
	dylib/hooks/hook_compat.c \
	dylib/hooks/hook_shortcut.c \
	dylib/hooks/hook_icon.c \
	dylib/hooks/hook_shortcut_bundle.c \
	dylib/hooks/hook_webui.c \
	dylib/hooks/hook_webpatch.c \
	dylib/hooks/hook_spawn.c \
	dylib/hooks/hook_launch.c \
	dylib/hooks/hook_activate.c \
	dylib/feats/compat.c \
	dylib/feats/webui.c \
	dylib/feats/compatsvc.c \
	dylib/feats/prefixstate.c \
	dylib/feats/usershortcuts.c \
	dylib/feats/webpatch.c \
	dylib/feats/nativeplatform.c \
	dylib/feats/input_access.c \
	vendor/cJSON.c

OUT_DIR     := out
TEST_CC     := $(CC) -arch $(ARCH) -mmacosx-version-min=$(MIN_VER) -std=c17 -g \
	-Wall -Wextra -Wno-unused-parameter -Idylib

GENERATED_DIR := $(OUT_DIR)/generated
RUN_SCRIPT_H  := $(GENERATED_DIR)/compat_run.h
CFLAGS += -I$(GENERATED_DIR)

ARM64_DYLIB := $(OUT_DIR)/notproton.arm64.dylib
X86_STUB    := $(OUT_DIR)/notproton.x86_64.dylib
TARGET      := $(OUT_DIR)/notproton.dylib

OBJS := $(patsubst %.c,$(OUT_DIR)/%.o,$(SRCS))
DEPS := $(OBJS:.o=.d)

.PHONY: all clean rebuild dobby deploy dylib dylib-install sigcheck fonts fonts-install app-payload app app-zip \
        anchorcheck callscheck sigdb-fixtures webpatch-fixtures peicon-fixtures panel-behavior app-tests \
        tests-list overlay-shim overlay-shim-install overlay-shim-tests \
        overlay-shim-bench iconmaker icon \
        appinfo helpers-install ntdll-resolve detourcheck bridge runcheck compatcheck \
        compatsvc-check prefixstate-check shortcutcheck scriptcheck envcheck buildcheck settingscheck routecheck bridgecheck envpasscheck prefixnotecheck powernotecheck exitcheck anticheatcheck launchprogresscheck gamedrivecheck \
        gamefixescheck launchercheck padcheck launch-shell activatecheck stamp-check versioncheck cicheck compat-reported-check FORCE

APP_PAYLOAD := app/Sources/BridgeplayApp/Resources/payload

all: $(TARGET) $(APP_PAYLOAD)

dylib: $(TARGET)

# SwiftPM's `.copy("Resources/payload")` in Package.swift needs this directory
# to exist
$(APP_PAYLOAD):
	@mkdir -p $(APP_PAYLOAD)

TEST_PATHS := dylib/tests overlay-shim/tests app/Tests scripts/tests ntdll-patch/tests \
              native-launch/tests native-shim/tests installer/tests

tests-list:
	@for p in $(TEST_PATHS); do echo $$p; done

# A check with no inputs left is reported
SKIP = echo "==> $(1): $(2) not present, skipped"

runcheck:
	@if ! command -v shellcheck >/dev/null 2>&1; then \
		$(call SKIP,runcheck,shellcheck); exit 0; fi; \
	shellcheck dylib/feats/compat_run.sh && sh -n dylib/feats/compat_run.sh && \
	echo "==> runcheck: the run script lints and parses clean"

cicheck:
	@if [ ! -f scripts/tests/cicheck.sh ]; then $(call SKIP,cicheck,scripts/tests/cicheck.sh); exit 0; fi; \
	sh scripts/tests/cicheck.sh

# Validate batch exit statuses without starting games.
.PHONY: np-test-batch-check
np-test-batch-check:
	@sh scripts/tests/np-test-batch.sh

.PHONY: seedcheck
seedcheck:
	@if [ ! -f dylib/tests/seedcheck.sh ]; then $(call SKIP,seedcheck,dylib/tests/seedcheck.sh); exit 0; fi; \
	sh dylib/tests/seedcheck.sh dylib/feats/compat_run.sh

envcheck:
	@if [ ! -f dylib/tests/envcheck.sh ]; then $(call SKIP,envcheck,dylib/tests/envcheck.sh); exit 0; fi; \
	sh dylib/tests/envcheck.sh dylib/feats/compat_run.sh

buildcheck:
	@if [ ! -f dylib/tests/buildcheck.sh ]; then $(call SKIP,buildcheck,dylib/tests/buildcheck.sh); exit 0; fi; \
	sh dylib/tests/buildcheck.sh dylib/feats/compat_run.sh

settingscheck:
	@if [ ! -f dylib/tests/settingscheck.sh ]; then $(call SKIP,settingscheck,dylib/tests/settingscheck.sh); exit 0; fi; \
	sh dylib/tests/settingscheck.sh dylib/feats/compat_run.sh

routecheck:
	@if [ ! -f dylib/tests/routecheck.sh ]; then $(call SKIP,routecheck,dylib/tests/routecheck.sh); exit 0; fi; \
	sh dylib/tests/routecheck.sh dylib/feats/compat_run.sh

bridgecheck:
	@if [ ! -f dylib/tests/bridgecheck.sh ]; then $(call SKIP,bridgecheck,dylib/tests/bridgecheck.sh); exit 0; fi; \
	sh dylib/tests/bridgecheck.sh dylib/feats/compat_run.sh

envpasscheck:
	@if [ ! -f dylib/tests/envpasscheck.sh ]; then \
		$(call SKIP,envpasscheck,dylib/tests/envpasscheck.sh); exit 0; fi; \
	sh dylib/tests/envpasscheck.sh dylib/feats/compat_run.sh

prefixnotecheck:
	@if [ ! -f dylib/tests/prefixnotecheck.sh ]; then $(call SKIP,prefixnotecheck,dylib/tests/prefixnotecheck.sh); exit 0; fi; \
	sh dylib/tests/prefixnotecheck.sh dylib/feats/compat_run.sh

powernotecheck:
	@if [ ! -f dylib/tests/powernotecheck.sh ]; then $(call SKIP,powernotecheck,dylib/tests/powernotecheck.sh); exit 0; fi; \
	sh dylib/tests/powernotecheck.sh dylib/feats/compat_run.sh

exitcheck:
	@if [ ! -f dylib/tests/exitcheck.sh ]; then $(call SKIP,exitcheck,dylib/tests/exitcheck.sh); exit 0; fi; \
	sh dylib/tests/exitcheck.sh dylib/feats/compat_run.sh

anticheatcheck:
	@if [ ! -f dylib/tests/anticheatcheck.sh ]; then $(call SKIP,anticheatcheck,dylib/tests/anticheatcheck.sh); exit 0; fi; \
	sh dylib/tests/anticheatcheck.sh dylib/feats/compat_run.sh

launchprogresscheck:
	@if [ ! -f dylib/tests/launchprogresscheck.sh ]; then $(call SKIP,launchprogresscheck,dylib/tests/launchprogresscheck.sh); exit 0; fi; \
	sh dylib/tests/launchprogresscheck.sh dylib/feats/compat_run.sh

gamedrivecheck:
	@if [ ! -f dylib/tests/gamedrivecheck.sh ]; then $(call SKIP,gamedrivecheck,dylib/tests/gamedrivecheck.sh); exit 0; fi; \
	sh dylib/tests/gamedrivecheck.sh dylib/feats/compat_run.sh

gamefixescheck:
	@if [ ! -f dylib/tests/gamefixescheck.sh ]; then $(call SKIP,gamefixescheck,dylib/tests/gamefixescheck.sh); exit 0; fi; \
	sh dylib/tests/gamefixescheck.sh dylib/feats/compat_run.sh

# The beta stamp, the version bump and the upstream sync, on throwaway copies of the repo.
versioncheck:
	@if [ ! -f dylib/tests/versioncheck.sh ]; then $(call SKIP,versioncheck,dylib/tests/versioncheck.sh); exit 0; fi; \
	sh dylib/tests/versioncheck.sh

padcheck:
	@if [ ! -f dylib/tests/padcheck.sh ]; then $(call SKIP,padcheck,dylib/tests/padcheck.sh); exit 0; fi; \
	sh dylib/tests/padcheck.sh dylib/feats/compat_run.sh

launchercheck:
	@if [ ! -f dylib/tests/launchercheck.sh ]; then $(call SKIP,launchercheck,dylib/tests/launchercheck.sh); exit 0; fi; \
	sh dylib/tests/launchercheck.sh dylib/feats/compat_run.sh

# Runs the weekly compat refresh's commit step against local git repos
compat-reported-check:
	@if [ ! -f scripts/tests/compat-reported-commit.sh ]; then $(call SKIP,compat-reported-check,scripts/tests/compat-reported-commit.sh); exit 0; fi; \
	sh scripts/tests/compat-reported-commit.sh

# Offline test for compatible wiki pages with more than one Steam app ID.
.PHONY: compat-reported-import-check
compat-reported-import-check:
	@python3 scripts/tests/compat-reported.py

.PHONY: mincheck
mincheck:
	@if [ ! -d "$(APP_BUNDLE)" ]; then echo "==> mincheck: $(APP_BUNDLE) not present, skipped (make app builds it)"; exit 0; fi; \
	sh dylib/tests/mincheck.sh "$(APP_BUNDLE)" "$(MINCHECK_VER)" "$(GLASS_SDK)"

.PHONY: l10ncheck
l10ncheck:
	@bin=$$(cd app/.build/release 2>/dev/null && pwd -P) || \
		bin=$$(swift build --package-path app -c release --show-bin-path); \
	for target in BridgeplayApp BridgeplayInstaller; do \
		python3 dylib/tests/l10ncheck.py "app/Sources/$$target/Resources/Localization/Localizable.xcstrings" \
			"$$bin/../../Intermediates.noindex/BridgeplayApp.build/$$(basename "$$bin")" zh-Hans it || exit $$?; \
	done

# runcheck owns compat_run.sh, whose warnings wait for a change that can move
# the embedded __text baseline
SCRIPTS := $(shell git ls-files '*.sh' '*.command' 2>/dev/null | grep -v '^dylib/feats/compat_run\.sh$$')

scriptcheck:
	@if ! command -v shellcheck >/dev/null 2>&1; then \
		$(call SKIP,scriptcheck,shellcheck); exit 0; fi; \
	if [ -z "$(strip $(SCRIPTS))" ]; then $(call SKIP,scriptcheck,a git checkout); exit 0; fi; \
	for s in $(SCRIPTS); do \
		shellcheck "$$s" || exit 1; \
		case "$$(head -n 1 "$$s")" in *bash*) bash -n "$$s" ;; *) sh -n "$$s" ;; esac || exit 1; \
	done; \
	echo "==> scriptcheck: $(words $(SCRIPTS)) scripts lint and parse clean"

COMPATCHECK := $(OUT_DIR)/compatcheck

compatcheck: $(RUN_SCRIPT_H)
	@if [ ! -f dylib/tests/compatcheck.c ]; then $(call SKIP,compatcheck,dylib/tests/compatcheck.c); exit 0; fi; \
	mkdir -p $(OUT_DIR) && \
	$(TEST_CC) -I$(GENERATED_DIR) \
	  -o $(COMPATCHECK) dylib/tests/compatcheck.c && \
	$(COMPATCHECK)

PREFIXSTATE_CHECK := $(OUT_DIR)/prefixstate-check

prefixstate-check:
	@if [ ! -f dylib/tests/prefixstate-check.c ]; then $(call SKIP,prefixstate-check,dylib/tests/prefixstate-check.c); exit 0; fi; \
	mkdir -p $(OUT_DIR) && \
	$(TEST_CC) -o $(PREFIXSTATE_CHECK) dylib/tests/prefixstate-check.c && \
	$(PREFIXSTATE_CHECK)

COMPATSVC_CHECK := $(OUT_DIR)/compatsvc-check

compatsvc-check:
	@if [ ! -f dylib/tests/compatsvc-check.c ]; then $(call SKIP,compatsvc-check,dylib/tests/compatsvc-check.c); exit 0; fi; \
	mkdir -p $(OUT_DIR) && \
	$(TEST_CC) -o $(COMPATSVC_CHECK) dylib/tests/compatsvc-check.c && \
	$(COMPATSVC_CHECK)

SHORTCUT_BUNDLE_CHECK := $(OUT_DIR)/shortcut-bundle-check
SHORTCUTCHECK         := $(OUT_DIR)/shortcutcheck

shortcutcheck: $(OUT_DIR)/iconmaker
	@if [ ! -f dylib/tests/shortcutcheck.c ]; then $(call SKIP,shortcutcheck,dylib/tests/shortcutcheck.c); exit 0; fi; \
	mkdir -p $(OUT_DIR) && \
	$(TEST_CC) -o $(SHORTCUT_BUNDLE_CHECK) dylib/tests/shortcut-bundle-check.c && \
	$(SHORTCUT_BUNDLE_CHECK) && \
	$(TEST_CC) -o $(SHORTCUTCHECK) dylib/tests/shortcutcheck.c && \
	$(SHORTCUTCHECK) && \
	python3 dylib/tests/shortcut-launch.py $(OUT_DIR)/iconmaker

sigcheck:
	@if [ ! -f dylib/tests/sigcheck.py ]; then $(call SKIP,sigcheck,dylib/tests/sigcheck.py); exit 0; fi; \
	python3 dylib/tests/sigcheck.py

# Validates anchors against a real dlopen'd steamclient.dylib
ANCHORCHECK := $(OUT_DIR)/anchorcheck
ANCHORCHECK_SRCS := dylib/tests/anchorcheck.c \
	dylib/core/macho.c dylib/resolver/aob.c dylib/resolver/anchor.c \
	dylib/resolver/resolver.c dylib/resolver/sigdb.c \
	dylib/util/log.c dylib/util/file.c vendor/cJSON.c

$(ANCHORCHECK): $(ANCHORCHECK_SRCS) FORCE
	@mkdir -p $(dir $@)
	$(TEST_CC) -O1 -Ivendor \
	  -o $@ $(ANCHORCHECK_SRCS)

anchorcheck:
	@if [ ! -f dylib/tests/anchorcheck.c ]; then $(call SKIP,anchorcheck,dylib/tests/anchorcheck.c); exit 0; fi; \
	$(MAKE) -s $(ANCHORCHECK) && $(ANCHORCHECK)

CALLSCHECK := $(OUT_DIR)/callscheck
CALLSCHECK_SRCS := dylib/tests/callscheck.c $(filter-out dylib/tests/anchorcheck.c,$(ANCHORCHECK_SRCS))

$(CALLSCHECK): $(CALLSCHECK_SRCS)
	@mkdir -p $(dir $@)
	$(CC) -arch $(ARCH) -mmacosx-version-min=$(MIN_VER) -std=c17 -g -O1 \
	  -Wall -Wextra -Wno-unused-parameter -Idylib -Ivendor \
	  -fsanitize=address,undefined -fno-sanitize-recover=all \
	  -o $@ $(CALLSCHECK_SRCS)

callscheck:
	@if [ ! -f dylib/tests/callscheck.c ]; then $(call SKIP,callscheck,dylib/tests/callscheck.c); exit 0; fi; \
	$(MAKE) -s $(CALLSCHECK) && $(CALLSCHECK)

SIGDB_FIXTURES := dylib/tests/sigdb-fixtures

sigdb-fixtures:
	@if [ ! -d $(SIGDB_FIXTURES) ] || [ ! -f dylib/tests/anchorcheck.c ]; then \
		$(call SKIP,sigdb-fixtures,$(SIGDB_FIXTURES)); exit 0; fi; \
	$(MAKE) -s $(ANCHORCHECK) || exit 1; \
	fail=0; n=0; live=$(OUT_DIR)/sigdb-fixtures-live; mkdir -p $$live || exit 1; \
	for t in $(SIGDB_FIXTURES)/live/*.json; do \
		out=$$($(ANCHORCHECK) --rebase "$$t" "$$live/$${t##*/}" 2>&1); rc=$$?; \
		if [ $$rc -ne 0 ]; then \
			echo "cannot build $$t against the installed client (rc=$$rc):"; \
			echo "$$out" | tail -1; exit 1; fi; \
	done; \
	for f in $(SIGDB_FIXTURES)/*.json $$live/*.json; do \
		n=$$((n+1)); \
		want=$$(awk -v name="$${f##*/}" '$$2 == name { print $$1 }' $(SIGDB_FIXTURES)/EXPECTED); \
		out=$$($(ANCHORCHECK) "$$f" 2>&1); rc=$$?; \
		if [ $$rc -ge 128 ]; then echo "crashed (rc=$$rc): $$f"; fail=1; continue; fi; \
		if [ $$rc -eq 3 ]; then \
			echo "anchorcheck cannot run here, so none of these fixtures were checked:"; \
			echo "$$out" | tail -1; fail=1; break; fi; \
		if [ -z "$$want" ]; then \
			echo "no expected status in $(SIGDB_FIXTURES)/EXPECTED: $$f"; fail=1; continue; fi; \
		if [ "$$rc" != "$$want" ]; then \
			echo "expected $$want, got $$rc: $$f"; fail=1; fi; \
	done; \
	if [ $$fail -ne 0 ]; then exit 1; fi; \
	echo "==> $$n sigdb fixtures: none crashed, each exited as $(SIGDB_FIXTURES)/EXPECTED records"

PEICON_CHECK := $(OUT_DIR)/peicon-check

$(PEICON_CHECK): dylib/tests/peicon-check.c dylib/util/peicon.c dylib/util/peicon.h
	@mkdir -p $(dir $@)
	$(TEST_CC) -O1 -o $@ dylib/tests/peicon-check.c dylib/util/peicon.c

peicon-fixtures:
	@if [ ! -f dylib/tests/peicon-check.c ]; then \
		$(call SKIP,peicon-fixtures,dylib/tests/peicon-check.c); exit 0; fi; \
	$(MAKE) -s $(PEICON_CHECK) || exit 1; \
	tmp=$$(mktemp -d); \
	$(PEICON_CHECK) "$$tmp"; rc=$$?; \
	rm -rf "$$tmp"; \
	if [ $$rc -eq 9 ]; then \
		echo "peicon-check ran out of time, so a hostile resource tree is unbounded"; fi; \
	exit $$rc

GATECHECK         := $(OUT_DIR)/gatecheck
WEBPATCH_FIXTURES := dylib/tests/webpatch-fixtures

$(GATECHECK): dylib/tests/gatecheck.c dylib/feats/webpatch.c dylib/feats/webpatch.h
	@mkdir -p $(dir $@)
	$(TEST_CC) -O1 -o $@ dylib/tests/gatecheck.c

NATIVEPLATFORMCHECK := $(OUT_DIR)/nativeplatformcheck

$(NATIVEPLATFORMCHECK): dylib/tests/nativeplatformcheck.c dylib/feats/nativeplatform.c dylib/feats/nativeplatform.h dylib/util/file.c
	@mkdir -p $(dir $@)
	$(TEST_CC) -O1 -DHELPER_TIMEOUT_MS=1000 -o $@ dylib/tests/nativeplatformcheck.c dylib/feats/nativeplatform.c dylib/util/file.c

webpatch-fixtures:
	@if [ ! -d $(WEBPATCH_FIXTURES) ] || [ ! -f dylib/tests/gatecheck.c ]; then \
		$(call SKIP,webpatch-fixtures,$(WEBPATCH_FIXTURES)); exit 0; fi; \
	$(MAKE) -s $(GATECHECK) || exit 1; \
	$(GATECHECK) || exit 1; \
	fail=0; tmp=$$(mktemp -d); n=0; \
	for good in $(WEBPATCH_FIXTURES)/gates.*.js; do \
		n=$$(( $$n + 1 )); base=$$(basename $$good .js); \
		cat $$good $$good > $$tmp/$$base.doubled.js; \
		head -c $$(( $$(stat -f %z $$good) / 2 )) $$good > $$tmp/$$base.truncated.js; \
		for spec in "$$good:APPLIED" "$$tmp/$$base.doubled.js:REJECTED" \
		            "$$tmp/$$base.truncated.js:REJECTED"; do \
			f=$${spec%:*}; want=$${spec##*:}; \
			out=$$($(GATECHECK) "$$f" 2>&1); rc=$$?; \
			case "$$out" in *WRONG*) echo "$$out"; fail=1 ;; esac; \
			case "$$out" in *$$want*) ;; *) echo "expected $$want: $$out"; fail=1 ;; esac; \
			if [ $$rc -ne 0 ]; then fail=1; fi; \
		done; \
	done; \
	for f in $(WEBPATCH_FIXTURES)/library.*.js; do \
		out=$$($(GATECHECK) --library "$$f" $$tmp/$$(basename $$f .js).out.js 2>&1) || { echo "$$out"; fail=1; }; \
		out=$$($(GATECHECK) --library-literal "$$f" $$tmp/$$(basename $$f .js).literal.out.js 2>&1) || { echo "$$out"; fail=1; }; \
	done; \
	out=$$($(GATECHECK) --older-filter $$tmp/library.older.out.js 2>&1) || { echo "$$out"; fail=1; }; \
	if [ $$fail -eq 0 ]; then \
		if command -v node >/dev/null 2>&1; then \
			node dylib/tests/library-filter/behavior.js $$tmp/library.*.out.js || fail=1; \
		else echo "==> webpatch-fixtures: library filter skipped, node not found"; fi; \
	fi; \
	rm -rf $$tmp; \
	$(MAKE) -s $(NATIVEPLATFORMCHECK) && $(NATIVEPLATFORMCHECK) || fail=1; \
	if [ $$fail -ne 0 ]; then exit 1; fi; \
	echo "==> gate table and $$n webpatch fixtures: anchors intact, drift refused"

LAUNCH_SHELL := $(OUT_DIR)/launch-shell

launch-shell:
	@if [ ! -f dylib/tests/launch-shell.c ]; then $(call SKIP,launch-shell,dylib/tests/launch-shell.c); exit 0; fi; \
	mkdir -p $(OUT_DIR) && \
	$(TEST_CC) -O1 -o $(LAUNCH_SHELL) dylib/tests/launch-shell.c && \
	$(LAUNCH_SHELL)

ACTIVATECHECK := $(OUT_DIR)/activatecheck

activatecheck:
	@if [ ! -f dylib/tests/activatecheck.c ]; then $(call SKIP,activatecheck,dylib/tests/activatecheck.c); exit 0; fi; \
	mkdir -p $(OUT_DIR) && \
	$(TEST_CC) -O1 -o $(ACTIVATECHECK) dylib/tests/activatecheck.c -framework AppKit -lobjc && \
	$(ACTIVATECHECK)

SPAWN_ENV := $(OUT_DIR)/spawn-env

spawn-env:
	@if [ ! -f dylib/tests/spawn-env.c ]; then $(call SKIP,spawn-env,dylib/tests/spawn-env.c); exit 0; fi; \
	mkdir -p $(OUT_DIR) && \
	$(TEST_CC) -O1 -o $(SPAWN_ENV) dylib/tests/spawn-env.c && \
	$(SPAWN_ENV)

SPAWN_LIVE := dylib/tests/spawn-live

spawn-live: $(TARGET)
	@if [ ! -d $(SPAWN_LIVE) ]; then $(call SKIP,spawn-live,$(SPAWN_LIVE)); exit 0; fi; \
	tmp=$$(mktemp -d); trap 'rm -rf $$tmp' EXIT; mkdir -p $$tmp/sub; \
	$(CC) -arch $(ARCH) -mmacosx-version-min=$(MIN_VER) -std=c17 -O1 -Wall -Wextra \
	  -o $$tmp/child $(SPAWN_LIVE)/child.c || exit 1; \
	$(CC) -arch $(ARCH) -mmacosx-version-min=$(MIN_VER) -std=c17 -O1 -Wall -Wextra \
	  -o $$tmp/steam_osx $(SPAWN_LIVE)/driver.c || exit 1; \
	cp $$tmp/steam_osx $$tmp/inert; cp $$tmp/child $$tmp/steam_osx_child; \
	cp $$tmp/child $$tmp/sub/steam_osx; \
	cp $$tmp/steam_osx "$$tmp/Steam Helper"; cp $$tmp/child "$$tmp/sub/Steam Helper"; \
	fail=0; \
	for spec in "inert:child:1" "steam_osx:child:0" \
	            "steam_osx:steam_osx_child:0" "steam_osx:sub/steam_osx:1" \
	            "steam_osx:sub/Steam Helper:1" "Steam Helper:child:0" \
	            "Steam Helper:sub/Steam Helper:1" "Steam Helper:child:1:--type=renderer"; do \
		drv=$${spec%%:*}; rest=$${spec#*:}; kid=$${rest%%:*}; rest=$${rest#*:}; \
		want=$${rest%%:*}; arg=$${rest#*:}; [ "$$arg" = "$$rest" ] && arg=""; \
		got=$$(DYLD_INSERT_LIBRARIES=$$PWD/$(TARGET) "$$tmp/$$drv" "$$tmp/$$kid" $$arg 2>/dev/null \
		       | grep -c "/notproton.dylib$$") || true; \
		if [ "$$got" != "$$want" ]; then \
			echo "$$drv $$arg -> $$kid: insert present $$got, wanted $$want"; fail=1; fi; \
	done; \
	if [ $$fail -ne 0 ]; then exit 1; fi; \
	echo "==> spawn live: the hook lands, steam_osx and Steam Helper keep the insert, other children do not"

APP_TESTS := app/Tests

# SwiftPM on Xcode 27 beta (27A5218g) leaves Products/Debug/PackageFrameworks empty
# and puts Sparkle.framework one level up, while the test bundle's rpath only looks
# in PackageFrameworks, so the bundle fails to dlopen before a single test runs.
# Build the tests, then link Sparkle where the rpath expects it. Build products only.
app-tests:
	@if [ ! -d $(APP_TESTS) ]; then $(call SKIP,app-tests,$(APP_TESTS)); exit 0; fi; \
	touch app/Package.swift; cd app && swift build --build-tests && \
	bin=$$(swift build --show-bin-path) && \
	if [ -d "$$bin/PackageFrameworks" ] && [ -d "$$bin/Sparkle.framework" ] && \
		[ ! -e "$$bin/PackageFrameworks/Sparkle.framework" ]; then \
		ln -s ../Sparkle.framework "$$bin/PackageFrameworks/Sparkle.framework"; fi && \
	swift test

PANEL_TESTS := dylib/tests/panel-behavior

panel-behavior:
	@if [ ! -d $(PANEL_TESTS) ]; then $(call SKIP,panel-behavior,$(PANEL_TESTS)); exit 0; fi; \
	if ! command -v node >/dev/null 2>&1; then \
		echo "==> panel-behavior: node not found, skipped"; exit 0; fi; \
	mkdir -p $(OUT_DIR) && \
	$(TEST_CC) -O1 -o $(OUT_DIR)/panel-emit \
	  $(PANEL_TESTS)/emit.c && \
	node $(PANEL_TESTS)/behavior.js $(OUT_DIR)/panel-emit && \
	node $(PANEL_TESTS)/switching.js $(OUT_DIR)/panel-emit && \
	node $(PANEL_TESTS)/launch-options.js $(OUT_DIR)/panel-emit && \
	node $(PANEL_TESTS)/shell.js $(OUT_DIR)/panel-emit && \
	node $(PANEL_TESTS)/migration.js $(OUT_DIR)/panel-emit && \
	node $(PANEL_TESTS)/effective.js $(OUT_DIR)/panel-emit && \
	node $(PANEL_TESTS)/localization.js $(OUT_DIR)/panel-emit && \
	node $(PANEL_TESTS)/fex.js $(OUT_DIR)/panel-emit && \
	node $(PANEL_TESTS)/prefix-row.js $(OUT_DIR)/panel-emit && \
	echo "==> panel behavior: renders as expected, no stale arguments"

CX_ROOT ?= /Applications/CrossOver Preview.app

# Every shipped x86 detour payload hands the detour the register its ntdll keeps wm in,
# and resolve.py refuses a wm the shims cannot read. No capstone needed; the two tests
# that disassemble skip without it.
detourcheck:
	@if [ ! -f ntdll-patch/shimcheck.py ]; then $(call SKIP,detourcheck,ntdll-patch/shimcheck.py); exit 0; fi; \
	python3 ntdll-patch/shimcheck.py && python3 -m unittest discover -s ntdll-patch/tests

ntdll-resolve:
	@if [ ! -f ntdll-patch/resolve.py ]; then \
		$(call SKIP,ntdll-resolve,ntdll-patch/resolve.py); exit 0; fi; \
	if ! python3 -c 'import capstone' >/dev/null 2>&1; then \
		echo "==> ntdll-resolve: capstone not found, skipped (pip3 install capstone)"; exit 0; fi; \
	if [ ! -d "$(CX_ROOT)" ]; then \
		echo "==> ntdll-resolve: $(CX_ROOT) not present, skipped (set CX_ROOT)"; exit 0; fi; \
	python3 ntdll-patch/resolve.py "$(CX_ROOT)"

$(ARM64_DYLIB): $(OBJS) $(DOBBY_LIBS)
	@mkdir -p $(dir $@)
	$(CC) $(LDFLAGS) -o $@ $^ $(FRAMEWORKS) -lc++

$(X86_STUB): dylib/stub_x86_64.c
	@mkdir -p $(dir $@)
	$(CC) -arch x86_64 -mmacosx-version-min=$(MIN_VER) $(AVAIL) \
		-dynamiclib -install_name @rpath/notproton.dylib \
		-o $@ $<

$(TARGET): $(ARM64_DYLIB) $(X86_STUB)
	lipo -create $^ -output $@
	codesign -fs - $@
	@echo "==> Built: $@"

$(OUT_DIR)/%.o: %.c
	@mkdir -p $(dir $@)
	$(CC) $(CFLAGS) -c $< -o $@

$(RUN_SCRIPT_H): dylib/feats/compat_run.sh dylib/embed_script.py
	@mkdir -p $(GENERATED_DIR)
	python3 dylib/embed_script.py $< $@ RUN_SCRIPT

$(OUT_DIR)/dylib/feats/compat.o: $(RUN_SCRIPT_H)

SUPPORT_DIR        := $(HOME)/Library/Application Support/bridgeplay
OVERLAY_SHIM_SRC   := overlay-shim/overlay_shim.m
OVERLAY_SHIM_ARM   := $(OUT_DIR)/overlay-shim.arm64.dylib
OVERLAY_SHIM_X86   := $(OUT_DIR)/overlay-shim.x86_64.dylib
OVERLAY_SHIM       := $(OUT_DIR)/overlay-shim.dylib
OVERLAY_SHIM_FLAGS := -mmacosx-version-min=$(MIN_VER) $(AVAIL) -dynamiclib -O2 -Wall -Wextra \
                      -install_name @rpath/overlay-shim.dylib \
                      -framework Metal -framework QuartzCore \
                      -framework CoreGraphics -framework CoreFoundation -framework Foundation
OVERLAY_SHIM_TESTS := overlay-shim/tests
OVERLAY_SHIM_TEST_FLAGS := -mmacosx-version-min=$(MIN_VER) -O2 -Wall -Wextra \
                      -framework Metal -framework Foundation -framework QuartzCore -framework CoreGraphics

overlay-shim: $(OVERLAY_SHIM)

$(OVERLAY_SHIM): $(OVERLAY_SHIM_SRC) overlay-shim/framegen.m overlay-shim/quitkey.m
	@mkdir -p $(OUT_DIR)
	$(CC) -arch arm64 $(OVERLAY_SHIM_FLAGS) -o $(OVERLAY_SHIM_ARM) $<
	$(CC) -arch x86_64 $(OVERLAY_SHIM_FLAGS) -o $(OVERLAY_SHIM_X86) $<
	lipo -create $(OVERLAY_SHIM_ARM) $(OVERLAY_SHIM_X86) -output $@
	codesign -fs - $@
	@lipo -info $@

define install_atomically
	@mkdir -p "$$(dirname "$(2)")"
	cp -f "$(1)" "$(2).new"
	mv -f "$(2).new" "$(2)"
endef

overlay-shim-install: $(OVERLAY_SHIM)
	$(call install_atomically,$(OVERLAY_SHIM),$(SUPPORT_DIR)/overlay-shim.dylib)
	@echo "==> Installed: $(SUPPORT_DIR)/overlay-shim.dylib"

overlay-shim-tests: $(OVERLAY_SHIM)
	@if [ ! -d $(OVERLAY_SHIM_TESTS) ]; then \
		$(call SKIP,overlay-shim-tests,$(OVERLAY_SHIM_TESTS)); exit 0; fi; \
	mkdir -p $(OUT_DIR); \
	fail=0; ran=0; skipped=0; \
	for t in device bridge delivery framegen ownership; do \
		for a in arm64 x86_64; do \
			$(CC) -arch $$a $(OVERLAY_SHIM_TEST_FLAGS) -o $(OUT_DIR)/$$t.$$a \
				$(OVERLAY_SHIM_TESTS)/$$t.m || exit 1; \
			out=$$(NOTPROTON_OVERLAY_SHIM=$(OVERLAY_SHIM) $(OUT_DIR)/$$t.$$a 2>&1); rc=$$?; \
			case "$$rc" in \
			0) ran=$$((ran+1)); echo "$$out" | sed "s/^/  $$t.$$a /" ;; \
			3|126) skipped=$$((skipped+1)); \
			   echo "  $$t.$$a skipped: $$(echo "$$out" | tail -1)" ;; \
			*) echo "  $$t.$$a exited $$rc:"; echo "$$out" | sed "s/^/    /"; fail=1 ;; \
			esac; \
		done; \
	done; \
	if [ $$fail -ne 0 ]; then exit 1; fi; \
	if [ $$ran -eq 0 ]; then \
		echo "overlay shim tests: all $$skipped skipped, so nothing was checked"; exit 1; fi; \
	echo "==> overlay shim tests: $$ran passed, $$skipped skipped"

overlay-shim-bench:
	@if [ ! -f $(OVERLAY_SHIM_TESTS)/passbench.m ]; then \
		$(call SKIP,overlay-shim-bench,$(OVERLAY_SHIM_TESTS)/passbench.m); exit 0; fi; \
	mkdir -p $(OUT_DIR); \
	for a in arm64 x86_64; do \
		$(CC) -arch $$a $(OVERLAY_SHIM_TEST_FLAGS) -o $(OUT_DIR)/passbench.$$a \
			$(OVERLAY_SHIM_TESTS)/passbench.m || exit 1; \
		printf '  %-8s ' "$$a"; $(OUT_DIR)/passbench.$$a || exit 1; \
	done

ICONMAKER := $(OUT_DIR)/iconmaker

iconmaker: $(ICONMAKER)

$(ICONMAKER): helpers/iconmaker.swift helpers/iconmaker.h dylib/util/peicon.c dylib/util/peicon.h helpers/shortcuts.h helpers/shortcuts.c
	@mkdir -p $(OUT_DIR)
	$(CC) -c -arch $(ARCH) -mmacosx-version-min=$(MIN_VER) $(AVAIL) -std=c17 -O2 \
		-Wall -Wextra -o $(OUT_DIR)/peicon-host.o dylib/util/peicon.c
	$(CC) -c -arch $(ARCH) -mmacosx-version-min=$(MIN_VER) $(AVAIL) -std=c17 -O2 \
		-Wall -Wextra -o $(OUT_DIR)/shortcuts-host.o helpers/shortcuts.c
	swiftc -O -target $(ARCH)-apple-macos$(MIN_VER) \
		-framework AppKit -import-objc-header helpers/iconmaker.h \
		-o $@ helpers/iconmaker.swift $(OUT_DIR)/peicon-host.o $(OUT_DIR)/shortcuts-host.o
	@echo "==> Built $@"

APPINFO := $(OUT_DIR)/appinfo

appinfo: $(APPINFO)

$(APPINFO): helpers/appinfo.swift
	@mkdir -p $(OUT_DIR)
	swiftc -O -target $(ARCH)-apple-macos$(MIN_VER) -o $@ $<
	@echo "==> Built $@"

helpers-install: $(ICONMAKER) $(APPINFO)
	$(call install_atomically,$(ICONMAKER),$(SUPPORT_DIR)/iconmaker)
	$(call install_atomically,$(APPINFO),$(SUPPORT_DIR)/appinfo)
	@echo "==> Installed: $(SUPPORT_DIR)/{iconmaker,appinfo}"

dobby:
	@mkdir -p $(DOBBY_DIR)
	cd $(DOBBY_DIR) && cmake $(CURDIR)/vendor/dobby \
		-DCMAKE_OSX_ARCHITECTURES=arm64 \
		-DCMAKE_OSX_DEPLOYMENT_TARGET=$(MIN_VER) \
		-DDOBBY_DEBUG=OFF \
		-DDOBBY_GENERATE_SHARED=OFF \
		-G "Unix Makefiles"
	$(MAKE) -C $(DOBBY_DIR) -j$(shell sysctl -n hw.ncpu)

STEAM_APP    ?= $$(p=$$(defaults read com.bridgeplay.Bridgeplay steamAppPath 2>/dev/null); printf '%s' "$${p:-/Applications/Steam.app}")
DEPLOY_DST    = $(STEAM_APP)/Contents/MacOS/notproton.dylib
INSTALL_DST  := $(SUPPORT_DIR)/notproton.dylib

dylib-install: $(TARGET)
	$(call install_atomically,$(TARGET),$(INSTALL_DST))
	@echo "==> Installed: $(INSTALL_DST)"

sigdb-install:
	@mkdir -p "$(SUPPORT_DIR)/signatures/macos.arm64"
	cp -f signatures/macos.arm64/*.json "$(SUPPORT_DIR)/signatures/macos.arm64/"
	@echo "==> Installed: $(SUPPORT_DIR)/signatures/macos.arm64"

LAUNCHABLE_BUNDLES := $(HOME)/Desktop/Bridgeplay.app /Applications/Bridgeplay.app

# The Chinese, Japanese and Korean fonts (about 85 MB) stay out of the app: CJKFonts.swift
# downloads them from their own release, packed by scripts/package-fonts.sh.
CJK_FONTS := malgun.ttf msgothic.ttc msyh.ttf msyhbd.ttf simsun.ttc
FONT_FILES := --include='*/' --include='*.ttf' --include='*.ttc' --exclude='*'

fonts-install:
	@if [ ! -d build/fonts ]; then echo "build/fonts is missing, run: $(MAKE) fonts" >&2; exit 1; fi
	@mkdir -p "$(SUPPORT_DIR)/fonts"
	@rsync -a --delete $(FONT_FILES) build/fonts/ "$(SUPPORT_DIR)/fonts/"
	@echo "==> Installed: $(SUPPORT_DIR)/fonts"

deploy: $(TARGET) dylib-install sigdb-install fonts-install helpers-install prefix-command-install
	@if [ ! -d "$(STEAM_APP)" ]; then \
		echo "==> deploy: $(STEAM_APP) not found"; exit 1; fi
	$(call install_atomically,$(TARGET),$(DEPLOY_DST))
	@echo "==> Deployed: $(DEPLOY_DST) (restart Steam to load)"
	@# The app's build record no longer matches Steam's dylib, and the app refuses to install over
	@# a mismatch. Set it aside so the next app install sees an update instead.
	@r="$(SUPPORT_DIR)/install-build.json"; \
	if [ -f "$$r" ]; then mv -f "$$r" "$$r.before-deploy" && echo "==> Moved the app's build record to $$r.before-deploy"; fi
	@for b in $(LAUNCHABLE_BUNDLES); do \
		p=$$(find "$$b" -name notproton.dylib -type f 2>/dev/null | head -1); \
		[ -n "$$p" ] || continue; \
		cmp -s "$$p" "$(DEPLOY_DST)" && continue; \
		echo "==> warning: $$b carries a different notproton.dylib"; \
		echo "==> warning: launching it reverts this deploy, so rebuild it with 'make app'"; \
	done

WINE_BUILD := scratch/wine-build-dual

WINE_BUILD_ARM64 := scratch/wine-build-arm64

BRIDGE_FILES := \
	$(WINE_BUILD)/programs/steam.exe/x86_64-windows/steam.exe:steam.exe \
	$(WINE_BUILD)/dlls/lsteamclient/x86_64-windows/lsteamclient.dll:x86_64-windows-lsteamclient.dll \
	$(WINE_BUILD)/dlls/lsteamclient/lsteamclient.so:x86_64-unix-lsteamclient.so \
	$(WINE_BUILD_ARM64)/dlls/lsteamclient/lsteamclient.so:aarch64-unix-lsteamclient.so \
	$(WINE_BUILD)/dlls/lsteamclient/i386-windows/lsteamclient.dll:i386-windows-lsteamclient.dll

bridge:
	bridge/setup-wine-tree.sh
	WINE_BUILD="$(CURDIR)/$(WINE_BUILD_ARM64)" HOST=aarch64-apple-darwin \
		HOST_CC="clang -arch arm64" HOST_CXX="clang++ -arch arm64" bridge/setup-wine-tree.sh
	lsteamclient/build.sh
	UNIX_ARCH=arm64 WINE_BUILD="$(CURDIR)/$(WINE_BUILD_ARM64)" lsteamclient/build.sh --unix
	steam-shim/build.sh
	@echo "==> Built the bridge, now run: $(MAKE) app-payload"

fonts:
	fonts/build.sh

app-payload: $(TARGET) $(OVERLAY_SHIM) $(ICONMAKER) $(APPINFO)
	@# A signature file deleted from the repo must not ship from the last payload.
	@test -n "$(APP_PAYLOAD)" && rm -rf "$(APP_PAYLOAD)/signatures"
	@mkdir -p "$(APP_PAYLOAD)/signatures/macos.arm64"
	@mkdir -p "$(APP_PAYLOAD)/bridge"
	@# Staged by 0.7.51 and earlier; left behind they fail the PAYLOAD_SIGN_IDS check.
	@rm -rf "$(APP_PAYLOAD)/controllers" "$(APP_PAYLOAD)/game-host.dylib" "$(APP_PAYLOAD)/prepare-game-loader"
	cp -f $(TARGET) "$(APP_PAYLOAD)/notproton.dylib"
	cp -f $(OVERLAY_SHIM) "$(APP_PAYLOAD)/overlay-shim.dylib"
	cp -f $(ICONMAKER) "$(APP_PAYLOAD)/iconmaker"
	cp -f $(APPINFO) "$(APP_PAYLOAD)/appinfo"
	cp -f dylib/feats/compat_run.sh "$(APP_PAYLOAD)/run"
	cp -f signatures/macos.arm64/*.json "$(APP_PAYLOAD)/signatures/macos.arm64/"
	@rm -rf "$(APP_PAYLOAD)/gamefixes" && mkdir -p "$(APP_PAYLOAD)/gamefixes"
	@if ls gamefixes/*.conf >/dev/null 2>&1; then cp -f gamefixes/*.conf "$(APP_PAYLOAD)/gamefixes/"; fi
	cp -f installer/config/gamecontrollerdb.txt "$(APP_PAYLOAD)/gamecontrollerdb.txt"
	@set -e; for spec in $(BRIDGE_FILES); do \
		src="$${spec%%:*}"; dst="$(APP_PAYLOAD)/bridge/$${spec##*:}"; \
		if [ -f "$$src" ]; then cp -f "$$src" "$$dst"; \
		elif [ -f "$$dst" ]; then echo "==> keeping staged $${spec##*:}"; \
		else echo "$$src is missing and nothing is staged at $$dst, run: $(MAKE) bridge" >&2; exit 1; fi; \
	done
	@if [ ! -d build/fonts ]; then echo "build/fonts is missing, run: $(MAKE) fonts" >&2; exit 1; fi
	@mkdir -p "$(APP_PAYLOAD)/fonts"
	@rsync -a --delete --delete-excluded $(foreach f,$(CJK_FONTS),--exclude='/$(f)') build/fonts/ "$(APP_PAYLOAD)/fonts/"
	@stamp="$$(git log -1 --format=%ct 2>/dev/null)"; \
	if [ -z "$$stamp" ]; then echo "build-time needs a git checkout" >&2; exit 1; fi; \
	echo "$$stamp" > "$(APP_PAYLOAD)/build-time"
	@echo "==> Staged app payload in $(APP_PAYLOAD)"

APP_BUNDLE  := $(OUT_DIR)/Bridgeplay.app
APP_BUNDLE_PAYLOAD := $(APP_BUNDLE)/Contents/Resources/BridgeplayApp_BridgeplayApp.bundle/Contents/Resources/payload
APP_ZIP     := $(OUT_DIR)/Bridgeplay.zip
# dylib/version.h: Bridgeplay semver for CFBundleShortVersionString, the release counter
# for CFBundleVersion (Sparkle orders updates by it; 32 is newer than the old 1.1.9.31),
# and the NotProton release it is based on. See docs/RELEASING.md.
APP_VERSION  := $(shell sed -n 's/^\#define BRIDGEPLAY_VERSION "\(.*\)"/\1/p' dylib/version.h)
APP_BUILD    := $(shell sed -n 's/^\#define BRIDGEPLAY_BUILD \([0-9][0-9]*\)$$/\1/p' dylib/version.h)
APP_UPSTREAM := $(shell sed -n 's/^\#define NOTPROTON_VERSION "\(.*\)"/\1/p' dylib/version.h)

# The app's code signing identity. Ad hoc (-) by default, so any checkout builds; a release
# uses the maintainer's Developer ID (BRIDGEPLAY_SIGN_IDENTITY, see docs/RELEASING.md) so the
# designated requirement, and the macOS permissions keyed to it, survive updates.
APP_SIGN_ID ?= $(or $(BRIDGEPLAY_SIGN_IDENTITY),-)
# Notarization needs the hardened runtime and a secure timestamp. Only a Developer ID gets
# them: library validation needs a Team ID, which ad hoc and self-signed identities lack.
APP_SIGN_FLAGS := $(if $(findstring Developer ID Application:,$(APP_SIGN_ID)),--options runtime --timestamp)

# Every Mach-O file in the bundled payload, path:identifier. `make app` signs them with
# APP_SIGN_ID under these identifiers before the app's own signature, so a release gives
# each one a certificate-based designated requirement as well. The build rules above keep
# signing ad hoc for tests and `make deploy`. Existing com.notproton.* identifiers stay.
PAYLOAD_SIGN_IDS := \
	notproton.dylib:com.bridgeplay.notproton \
	overlay-shim.dylib:com.bridgeplay.overlay-shim \
	iconmaker:com.bridgeplay.iconmaker \
	appinfo:com.bridgeplay.appinfo \
	bridge/x86_64-unix-lsteamclient.so:com.bridgeplay.lsteamclient \
	bridge/aarch64-unix-lsteamclient.so:com.bridgeplay.lsteamclient

# The icon name must match CFBundleIconFile/CFBundleIconName in app/Info.plist.
ICON_NAME := Bridgeplay
ICON_MARK := helpers/icon/bridgeplay-mark.svg
ICONGEN   := $(OUT_DIR)/icongen
ICON_DOC  := $(OUT_DIR)/$(ICON_NAME).icon
ICON_DIR  := $(OUT_DIR)/icon
ICON_CAR  := $(ICON_DIR)/Assets.car

# Licence texts copied into Contents/Resources: GPL-3.0, NOTICE and every
# third-party licence the bundle needs (LICENSE.dobby, LICENSE.sparkle, ...).
APP_LICENSES := LICENSE $(sort $(wildcard LICENSE.*)) NOTICE
.PHONY: prefix-command-install
# Records an app bundle that is already built. Building it here would make every deploy
# build the whole app.
prefix-command-install:
	@if [ ! -x "$(APP_BUNDLE)/Contents/MacOS/BridgeplayApp" ]; then \
		echo "==> no $(APP_BUNDLE) yet, run make app for rebuilds from Steam"; exit 0; fi; \
	mkdir -p "$(SUPPORT_DIR)" && \
	printf '%s' "$(CURDIR)/$(APP_BUNDLE)/Contents/MacOS/BridgeplayApp" > "$(SUPPORT_DIR)/app-executable.new" && \
	mv -f "$(SUPPORT_DIR)/app-executable.new" "$(SUPPORT_DIR)/app-executable"

icon: $(ICON_CAR)

$(ICONGEN): helpers/icon/icongen.swift
	@mkdir -p $(OUT_DIR)
	swiftc -O -o $@ $<
	@echo "==> Built $@"

$(ICON_CAR): $(ICONGEN) $(ICON_MARK)
	rm -rf "$(ICON_DOC)" "$(ICON_DIR)"
	$(ICONGEN) "$(ICON_MARK)" "$(ICON_DOC)"
	@mkdir -p "$(ICON_DIR)"
	xcrun actool "$(ICON_DOC)" --compile "$(ICON_DIR)" --platform macosx \
		--minimum-deployment-target 15.0 --app-icon $(ICON_NAME) \
		--output-partial-info-plist "$(ICON_DIR)/partial.plist" >/dev/null
	@test -s "$(ICON_DIR)/$(ICON_NAME).icns" || { echo "actool wrote no $(ICON_NAME).icns" >&2; exit 1; }
	@echo "==> Built $@"

# A malformed beta stamp fails before the slow build starts.
stamp-check:
	@sh scripts/stamp-beta.sh check

app: stamp-check app-payload $(ICON_CAR)
	swift build --package-path app -c release
	rm -rf "$(APP_BUNDLE)"
	@mkdir -p "$(APP_BUNDLE)/Contents/MacOS" "$(APP_BUNDLE)/Contents/Resources"
	@if [ -z "$(APP_VERSION)" ] || [ -z "$(APP_BUILD)" ] || [ -z "$(APP_UPSTREAM)" ]; then \
		echo "dylib/version.h needs BRIDGEPLAY_VERSION, BRIDGEPLAY_BUILD and NOTPROTON_VERSION" >&2; exit 1; fi
	cp app/Info.plist "$(APP_BUNDLE)/Contents/Info.plist"
	/usr/libexec/PlistBuddy -c \
		"Set :CFBundleShortVersionString $(APP_VERSION)" -c \
		"Set :CFBundleVersion $(APP_BUILD)" -c \
		"Set :NotProtonVersion $(APP_UPSTREAM)" \
		"$(APP_BUNDLE)/Contents/Info.plist"
	@sh scripts/stamp-beta.sh apply "$(APP_BUNDLE)/Contents/Info.plist"
	cp "$$(swift build --package-path app -c release --show-bin-path)/BridgeplayApp" \
		"$(APP_BUNDLE)/Contents/MacOS/BridgeplayApp"
	@mkdir -p "$(APP_BUNDLE)/Contents/Frameworks"
	ditto "$$(swift build --package-path app -c release --show-bin-path)/Sparkle.framework" \
		"$(APP_BUNDLE)/Contents/Frameworks/Sparkle.framework"
	install_name_tool -add_rpath @executable_path/../Frameworks \
		"$(APP_BUNDLE)/Contents/MacOS/BridgeplayApp"
	xcrun vtool -set-build-version macos $(MIN_VER) "$$(xcrun --sdk macosx --show-sdk-version)" \
		-replace -output "$(APP_BUNDLE)/Contents/MacOS/BridgeplayApp" \
		"$(APP_BUNDLE)/Contents/MacOS/BridgeplayApp"
	cp -R "$$(swift build --package-path app -c release --show-bin-path)/BridgeplayApp_BridgeplayApp.bundle" \
		"$(APP_BUNDLE)/Contents/Resources/"
	cp -R "$$(swift build --package-path app -c release --show-bin-path)/BridgeplayApp_BridgeplayUI.bundle" \
		"$(APP_BUNDLE)/Contents/Resources/"
	cp -R "$(APP_BUNDLE)/Contents/Resources/BridgeplayApp_BridgeplayApp.bundle/Contents/Resources/"*.lproj \
		"$(APP_BUNDLE)/Contents/Resources/"
	cp "$(ICON_DIR)/Assets.car" "$(ICON_DIR)/$(ICON_NAME).icns" \
		"$(APP_BUNDLE)/Contents/Resources/"
	cp $(APP_LICENSES) "$(APP_BUNDLE)/Contents/Resources/"
	@missing=$$(cd "$(APP_PAYLOAD)" && find . -type f ! -name '.DS_Store' | sed 's|^\./||' \
		| while read -r rel; do \
			[ -s "$(CURDIR)/$(APP_BUNDLE_PAYLOAD)/$$rel" ] || echo "$$rel"; \
		done); \
	if [ -n "$$missing" ]; then \
		echo "==> the bundle is missing staged payload, so the app would ship without it:" >&2; \
		echo "$$missing" | sed 's/^/        /' >&2; \
		echo "==> rm -rf app/.build/out and build again" >&2; \
		exit 1; \
	fi
	@echo "==> Payload complete in the bundle"
	@payload="$(APP_BUNDLE_PAYLOAD)"; \
	for spec in $(PAYLOAD_SIGN_IDS); do \
		codesign -f -s "$(APP_SIGN_ID)" $(APP_SIGN_FLAGS) -i "$${spec##*:}" "$$payload/$${spec%%:*}" || exit 1; \
	done; \
	unlisted=$$(find "$$payload" -type f | while read -r f; do \
		case "$$(file -b "$$f")" in (Mach-O*) ;; (*) continue ;; esac; \
		case " $(PAYLOAD_SIGN_IDS) " in (*" $${f#"$$payload"/}:"*) ;; (*) echo "$${f#"$$payload"/}" ;; esac; \
	done); \
	if [ -n "$$unlisted" ]; then \
		echo "==> payload Mach-O files missing from PAYLOAD_SIGN_IDS in the Makefile:" >&2; \
		echo "$$unlisted" | sed 's/^/        /' >&2; \
		exit 1; \
	fi
	@# The Wine binaries and libSDL2 Bridgeplay lays into its engines are committed ad hoc
	@# and pinned. Apple notarizes only Developer ID code, so a release re-signs them under
	@# their own identifiers; SignedPin.swift matches them either way.
	@[ -z "$(APP_SIGN_FLAGS)" ] || find "$(APP_BUNDLE)/Contents/Resources" -path "$(APP_BUNDLE_PAYLOAD)" -prune \
		-o -type f -print | while read -r f; do \
		case "$$(file -b "$$f")" in (Mach-O*) ;; (*) continue ;; esac; \
		codesign -f -s "$(APP_SIGN_ID)" $(APP_SIGN_FLAGS) --preserve-metadata=identifier "$$f" || exit 1; \
	done
	@# Inside out, so Sparkle's helpers carry the same identity as the app.
	@sparkle="$(APP_BUNDLE)/Contents/Frameworks/Sparkle.framework/Versions/B"; \
	codesign -f -s "$(APP_SIGN_ID)" $(APP_SIGN_FLAGS) -i org.sparkle-project.Sparkle.Autoupdate "$$sparkle/Autoupdate" || exit 1; \
	for code in "$$sparkle"/XPCServices/*.xpc "$$sparkle/Updater.app" \
		"$(APP_BUNDLE)/Contents/Frameworks/Sparkle.framework"; do \
		codesign -f -s "$(APP_SIGN_ID)" $(APP_SIGN_FLAGS) --preserve-metadata=entitlements "$$code" || exit 1; \
	done
	codesign -f -s "$(APP_SIGN_ID)" $(APP_SIGN_FLAGS) "$(APP_BUNDLE)"
	codesign --verify --strict --deep "$(APP_BUNDLE)"
	@codesign -d -r- "$(APP_BUNDLE)" 2>&1 | sed -n 's/^#* *designated => /==> Designated requirement: /p'
	@plist="$(APP_BUNDLE)/Contents/Info.plist"; \
	echo "==> Built $(APP_BUNDLE) ($$(/usr/libexec/PlistBuddy -c 'Print :CFBundleShortVersionString' "$$plist") build $$(/usr/libexec/PlistBuddy -c 'Print :CFBundleVersion' "$$plist"), based on NotProton $(APP_UPSTREAM))"

app-zip: app
	rm -f "$(APP_ZIP)"
	ditto -c -k --keepParent "$(APP_BUNDLE)" "$(APP_ZIP)"
	@echo "==> Wrote $(APP_ZIP)"

clean:
	rm -rf $(OUT_DIR)

rebuild: clean all

-include $(DEPS)

FORCE:

# np-native: Steam launch-option wrapper for native macOS games (arm64
# preferred, Steam's DYLD_INSERT_LIBRARIES kept). Installed later to
# ~/.bridgeplay/np-native.
NP_NATIVE     := $(OUT_DIR)/np-native/np-native
NP_NATIVE_SRC := native-launch/np-native.c

.PHONY: np-native np-native-tests

np-native: $(NP_NATIVE)

$(NP_NATIVE): $(NP_NATIVE_SRC)
	@mkdir -p $(dir $@)
	$(CC) -arch arm64 -arch x86_64 -mmacosx-version-min=11.0 -std=c17 -O2 \
		-Wall -Wextra -Werror $< -framework CoreFoundation -o $@
	codesign -s - -f $@
	@echo "==> Built $@ ($$(lipo -archs $@))"

np-native-tests: $(NP_NATIVE)
	@if [ ! -f native-launch/tests/run.sh ]; then $(call SKIP,np-native-tests,native-launch/tests/run.sh); exit 0; fi; \
	sh native-launch/tests/run.sh $(NP_NATIVE)

.PHONY: native-shim-tests
native-shim-tests:
	@if [ ! -f native-shim/tests/run.sh ]; then $(call SKIP,native-shim-tests,native-shim/tests/run.sh); exit 0; fi; \
	sh native-shim/tests/run.sh

# Inventory fixtures exercise modern and legacy Steam libraries offline.
.PHONY: np-inventory-check
np-inventory-check:
	@python3 scripts/tests/np-inventory.py

# Every check .github/workflows/app.yml runs, after `make app`.
# scripts/build-local.sh --checks runs this same target, so a local release build
# and CI gate on one list. Each check runs even when an earlier one failed.
# overlay-shim-tests is left out: it needs a Metal GPU and real frame timing.
CI_CHECKS := mincheck l10ncheck \
	sigcheck callscheck np-test-batch-check webpatch-fixtures peicon-fixtures panel-behavior spawn-env \
	activatecheck compat-reported-import-check compatcheck compatsvc-check prefixstate-check shortcutcheck launch-shell envcheck \
	buildcheck settingscheck routecheck bridgecheck envpasscheck prefixnotecheck powernotecheck exitcheck anticheatcheck launchprogresscheck gamedrivecheck launchercheck \
	seedcheck gamefixescheck versioncheck cicheck padcheck detourcheck compat-reported-check np-inventory-check np-native-tests native-shim-tests \
	app-tests native-installercheck

# app.yml runs the checks that need the built app in its build job and the rest in a
# parallel job; both lists together are CI_CHECKS.
CI_CHECKS_BUILT := mincheck l10ncheck app-tests
CI_CHECKS_SOURCE := $(filter-out $(CI_CHECKS_BUILT),$(CI_CHECKS))

.PHONY: ci-checks ci-checks-built ci-checks-source
ci-checks-built:
	@$(MAKE) -s ci-checks CI_CHECKS="$(CI_CHECKS_BUILT)"
ci-checks-source:
	@$(MAKE) -s ci-checks CI_CHECKS="$(CI_CHECKS_SOURCE)"
# The checks run side by side, CHECK_JOBS at a time (CHECK_JOBS=1 runs them one by one).
# Each one's output goes to $(CHECK_LOGS)/<check>.log and is printed whole, in list order,
# once all have finished. The slowest start first.
CHECK_JOBS ?= $(shell sysctl -n hw.ncpu 2>/dev/null || echo 4)
CHECK_LOGS := $(OUT_DIR)/check-logs
CI_CHECKS_FIRST := app-tests panel-behavior launchercheck gamefixescheck
CI_CHECKS_ORDERED := $(filter $(CI_CHECKS_FIRST),$(CI_CHECKS)) $(filter-out $(CI_CHECKS_FIRST),$(CI_CHECKS))

ci-checks:
	@rm -rf $(CHECK_LOGS) && mkdir -p $(CHECK_LOGS); \
	echo "==> ci-checks: $(words $(CI_CHECKS)) checks, $(CHECK_JOBS) at a time"; \
	$(MAKE) -s -j$(CHECK_JOBS) $(addprefix ci-run/,$(CI_CHECKS_ORDERED)); \
	failed=""; \
	for t in $(CI_CHECKS); do \
		rc=1; secs=?; \
		if [ -f $(CHECK_LOGS)/$$t.rc ]; then read -r rc secs <$(CHECK_LOGS)/$$t.rc; fi; \
		echo "==> [check] make -s $$t ($${secs}s)"; \
		cat $(CHECK_LOGS)/$$t.log 2>/dev/null; \
		if [ "$$rc" != 0 ]; then echo "==> [check] $$t failed with exit $$rc"; failed="$$failed $$t"; fi; \
	done; \
	skipped=$$(cd $(CHECK_LOGS) && grep -l '^==> [^ ]*: .*skipped' $(addsuffix .log,$(CI_CHECKS)) 2>/dev/null | sed 's/\.log$$//' | tr '\n' ' '); \
	[ -z "$$skipped" ] || echo "==> ci-checks: skipped, so not passed: $$skipped"; \
	if [ -n "$$failed" ]; then echo "==> ci-checks failed:$$failed" >&2; exit 1; fi; \
	if [ -n "$$skipped" ]; then echo "==> ci-checks: none failed, $$(echo $$skipped | wc -w | tr -d ' ') skipped"; \
	else echo "==> ci-checks: all $(words $(CI_CHECKS)) checks passed"; fi

# One check for ci-checks: always succeeds, leaving the exit status and seconds in <check>.rc
ci-run/%:
	@start=$$(date +%s); rc=0; \
	$(MAKE) -s $* >$(CHECK_LOGS)/$*.log 2>&1 </dev/null || rc=$$?; \
	secs=$$(($$(date +%s) - start)); \
	echo "$$rc $$secs" >$(CHECK_LOGS)/$*.rc; \
	if [ $$rc -eq 0 ]; then echo "--> $* passed in $${secs}s"; else echo "--> $* FAILED in $${secs}s"; fi

.PHONY: native-installer native-installercheck
native-installer:
	sh scripts/package-native-installer.sh

native-installercheck:
	sh scripts/test-native-installer.sh
	sh scripts/test-installer-cleanup.sh
