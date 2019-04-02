# Copyright (c) 2019 Status Research & Development GmbH. Licensed under
# either of:
# - Apache License, version 2.0
# - MIT license
# at your option. This file may not be copied, modified, or distributed except
# according to those terms.

# we don't want an error here, so we can explain things later, in the sanity-checks target
-include ../../common.mk

ENV_SCRIPT := "../../env.sh"

TOOLS := beacon_node validator_keygen bench_bls_sig_agggregation state_sim
TOOLS_DIRS := beacon_chain benchmarks research

.PHONY: all sanity-checks deps test $(TOOLS) clean_eth2_network_simulation_files eth2_network_simulation clean-testnet0 testnet0-nocleaning testnet0 clean-testnet1 testnet1-nocleaning testnet1 clean

all: | $(TOOLS)

$(SILENT_TARGET_PREFIX).SILENT:

sanity-checks:
	@ [[ "$$PWD" =~ /vendor/nim-beacon-chain$ && -e ../../Makefile && -e ../../common.mk ]] || \
		{ echo -e "This Makefile can only be used from the corresponding Git submodule in the Nimbus repository.\nDetailed instructions available in README.md or online at https://github.com/status-im/nim-beacon-chain/#building-and-testing"; exit 1; }

deps: | sanity-checks
	@+ $(MAKE) --silent -C ../../ deps

build:
	mkdir $@

test: | build deps
	../../nimble.sh test $(NIM_PARAMS)

$(TOOLS): | build deps
	for D in $(TOOLS_DIRS); do [ -e "$${D}/$@.nim" ] && TOOL_DIR="$${D}" && break; done && \
		echo -e $(BUILD_MSG) "build/$@" && \
		$(ENV_SCRIPT) nim c $(NIM_PARAMS) -o:build/$@ "$${TOOL_DIR}/$@.nim"

clean_eth2_network_simulation_files:
	rm -rf tests/simulation/data

eth2_network_simulation: | beacon_node validator_keygen clean_eth2_network_simulation_files
	SKIP_BUILDS=1 GIT_ROOT="$$PWD" BUILD_OUTPUTS_DIR="./build" tests/simulation/start.sh

clean-testnet0:
	rm -rf ~/.cache/nimbus/BeaconNode/testnet0

testnet0: | build deps
	../../env.sh scripts/build_testnet_node.sh testnet0

clean-testnet1:
	rm -rf ~/.cache/nimbus/BeaconNode/testnet1

testnet1: | build deps
	../../env.sh scripts/build_testnet_node.sh testnet1

clean:
	rm -rf build/* nimcache
