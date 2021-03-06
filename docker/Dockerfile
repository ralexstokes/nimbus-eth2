FROM debian:bullseye-slim AS build

SHELL ["/bin/bash", "-c"]

RUN apt-get -qq update \
 && apt-get -qq -y install build-essential libpcre3-dev git &>/dev/null \
 && apt-get -qq clean \
 && rm -rf /var/lib/apt/lists/* /tmp/* /var/tmp/*

# let Docker cache this between Git revision and testnet version changes
RUN cd /root \
 && git clone https://github.com/status-im/nim-beacon-chain.git \
 && cd nim-beacon-chain \
 && make -j$(nproc) update

# Please note that the commands above have the goal of caching the
# compilation of Nim, but don't depend on the current git revision.
# This means that the cache can become outdated over time and you'll
# start seeing Nim being compiled on every run. If this happens, just
# prune your docker cache to get a fresh up-to-date version of Nim.
ARG GIT_REVISION
ARG NETWORK_NIM_FLAGS
ARG MARCH_NIM_FLAGS

RUN cd /root/nim-beacon-chain \
 && git fetch \
 && git reset --hard ${GIT_REVISION} \
 && make -j$(nproc) update \
 && make LOG_LEVEL=TRACE NIMFLAGS="-d:insecure -d:testnet_servers_image ${NETWORK_NIM_FLAGS} ${MARCH_NIM_FLAGS}" nimbus_beacon_node

# --------------------------------- #
# Starting new image to reduce size #
# --------------------------------- #
FROM debian:bullseye-slim as deploy

SHELL ["/bin/bash", "-c"]

RUN apt-get -qq update \
 && apt-get -qq -y install libpcre3 psmisc &>/dev/null \
 && apt-get -qq clean \
 && rm -rf /var/lib/apt/lists/* /tmp/* /var/tmp/*

# "COPY" creates new image layers, so we cram all we can into one command
COPY --from=build /root/nim-beacon-chain/build/nimbus_beacon_node /usr/bin/

MAINTAINER Zahary Karadjov <zahary@status.im>
LABEL description="Nimbus installation that can act as an ETH2 network bootstrap node."

STOPSIGNAL SIGINT

ENTRYPOINT ["/usr/bin/nimbus_beacon_node"]

