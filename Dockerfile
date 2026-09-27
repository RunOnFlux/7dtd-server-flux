# 7 Days to Die dedicated server image for Flux.
#
# Written from scratch. The game's native Linux server (Steam app 294420), installed and updated
# with SteamCMD on every start, under a supervisor that saves the world on stop, restarts in
# place, restarts on a schedule, backs the world up, writes serverconfig.xml from the environment
# (so each marketplace tier can set its own values), and enforces the rules consoles need to join
# (FLUX_CROSSPLAY). See README.md.
FROM steamcmd/steamcmd:ubuntu-24

ARG DEBIAN_FRONTEND=noninteractive
ARG FLUX_IMAGE_VERSION=dev

RUN apt-get update -y && \
    apt-get install -y --no-install-recommends \
        ca-certificates curl procps tzdata python3-minimal && \
    apt-get clean && rm -rf /var/lib/apt/lists/*

COPY scripts/flux-lib.sh scripts/flux-entrypoint.sh scripts/flux-scheduler.sh \
     scripts/flux-serverconfig.py scripts/flux-telnet.py scripts/flux-unpack.py /opt/flux/
RUN chmod 0755 /opt/flux/*.sh /opt/flux/*.py && \
    ln -s /opt/flux/flux-telnet.py /usr/local/bin/flux-telnet

# SteamCMD's self-update, done once here instead of on every container start; the weekly
# rebuild keeps it current.
RUN steamcmd +quit >/dev/null 2>&1; test -d /root/.local/share/Steam

ENV FLUX_IMAGE_VERSION=${FLUX_IMAGE_VERSION}

VOLUME ["/mnt/7dtd/server", "/mnt/7dtd/data", "/mnt/7dtd/mods"]

# 26900 TCP/UDP is the game port, 26901-26902 UDP the ones next to it. The telnet console (8081)
# is for the supervisor and stays unpublished.
EXPOSE 26900/tcp 26900/udp 26901/udp 26902/udp

# A first start downloads about 17 GB, so the grace is generous. FluxOS does not act on health;
# this is for anyone running the image by hand.
HEALTHCHECK --interval=60s --timeout=10s --start-period=60m --retries=3 \
    CMD pgrep -f 7DaysToDieServer.x86_64 >/dev/null || exit 1

ENTRYPOINT []
CMD ["/opt/flux/flux-entrypoint.sh"]
