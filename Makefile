APP      := hera
APP_SRC  := src/$(APP).app.src
COOKIE   := grisp
BOARDS   ?= grisp-001316 grisp-001300 grisp-002075 grisp-001021 grisp-001024
# Address of this machine as seen by the boards (NetworkManager hotspot)
HOST_IP  ?= 10.42.0.1
PORT     ?= 8000

# Must match -sname in grisp/grisp2/common/deploy/files/grisp.ini.mustache
NODE     ?= board
NODES    = $(foreach B,$(BOARDS),$(NODE)@$(B))
VERSION  = $(shell sed -n 's/.*{vsn, *"\([^"]*\)"}.*/\1/p' $(APP_SRC))
PACKAGE  = _grisp/update/grisp2.$(APP).$(VERSION).tar
REL_DIR  = releases/$(APP)/$(VERSION)
URL      = http://$(HOST_IP):$(PORT)/$(APP)/$(VERSION)
FLEET    = escript scripts/grisp_fleet.escript $(COOKIE)

.PHONY: release bump pack push reboot validate info sim sim-all sim-list

# Bump the patch version, build the update package, push it and reboot the boards
release: bump pack push reboot

# Increment the last version digit in both the .app.src and rebar.config
bump:
	@old=$(VERSION); new=$${old%.*}.$$(( $${old##*.} + 1 )); \
	sed -i "s/{vsn, *\"$$old\"}/{vsn, \"$$new\"}/" $(APP_SRC); \
	sed -i "s/\({release, *{[^,]*, *\)\"$$old\"/\1\"$$new\"/" rebar.config; \
	echo "Version $$old -> $$new"; \
	grep -q "\"$$new\"" rebar.config || { echo "rebar.config not updated"; exit 1; }

# Build the software update package and unpack it where the HTTP server serves it
pack:
	rebar3 grisp pack --quiet
	mkdir -p $(REL_DIR)
	tar -C $(REL_DIR) -xf $(PACKAGE)

# Serve releases/ over HTTP while every board downloads the current version
push:
	@test -f $(REL_DIR)/MANIFEST.sealed || { echo "No package in $(REL_DIR), run make pack"; exit 1; }
	@if curl -sf -o /dev/null $(URL)/MANIFEST.sealed; then \
		echo "Reusing HTTP server already running on port $(PORT)"; \
	else \
		python3 -m http.server -d releases $(PORT) >/dev/null 2>&1 & srv=$$!; \
		trap "kill $$srv 2>/dev/null" EXIT; sleep 1; \
		kill -0 $$srv 2>/dev/null || { echo "Port $(PORT) busy, cannot serve $(URL)"; exit 1; }; \
	fi; \
	echo "Pushing $(URL)"; \
	$(FLEET) update $(URL) -- $(NODES)

reboot:
	$(FLEET) reboot -- $(NODES)

validate:
	$(FLEET) validate -- $(NODES)

info:
	$(FLEET) info -- $(NODES)

# Simulated experiments (sim/README.md), e.g.
#   make sim SCENARIO=circle SEED=1 MODE=live COMMENT="first live try"
# Each call is a new numbered experiment in data/sim/.
SCENARIO ?= circle
SEED     ?= 1
MODE     ?= offline
SIM_OPTS  = $(if $(TAG),--tag "$(TAG)") $(if $(COMMENT),--comment "$(COMMENT)")

sim:
	python3 sim/run.py --scenario $(SCENARIO) --seed $(SEED) --mode $(MODE) $(SIM_OPTS)

# Every scenario offline with seeds 1-3, plus live with seed 1
sim-all:
	python3 sim/run.py --all --mode both $(SIM_OPTS)

# List the experiments, with their first note
sim-list:
	python3 sim/experiments.py list
