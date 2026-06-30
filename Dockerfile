FROM debian:trixie-slim

LABEL org.opencontainers.image.title="SCUM Dedicated Server"
LABEL org.opencontainers.image.description="SCUM dedicated server on Debian Trixie with Wine 11.0"
LABEL org.opencontainers.image.source="https://github.com/EvilOlaf/scum"
LABEL org.opencontainers.image.base.name="debian:trixie-slim"

SHELL ["/bin/bash", "-o", "pipefail", "-c"]

ENV DEBIAN_FRONTEND=noninteractive
ENV LANG=en_US.UTF-8
ENV LANGUAGE=en_US:en
ENV LC_ALL=en_US.UTF-8
ENV WINEDEBUG=-all
ENV WINEARCH=win64
ENV WINEPREFIX=/opt/wine64
ENV XDG_RUNTIME_DIR=/tmp
ENV PATH=/opt/steamcmd:/usr/local/sbin:/usr/local/bin:/usr/sbin:/usr/bin:/sbin:/bin

WORKDIR /opt

RUN apt-get update \
    && apt-get install -y --no-install-recommends \
        ca-certificates \
        cabextract \
        curl \
        gnupg \
        locales \
        procps \
        tini \
        unzip \
        wget \
        winbind \
        x11-utils \
        xauth \
        xvfb \
    && sed -i '/en_US.UTF-8/s/^# //g' /etc/locale.gen \
    && locale-gen \
    && rm -rf /var/lib/apt/lists/*

RUN install -d -m 0755 /etc/apt/keyrings \
    && wget -qO- https://dl.winehq.org/wine-builds/winehq.key | gpg --dearmor -o /etc/apt/keyrings/winehq-archive.key \
    && wget -qO /etc/apt/sources.list.d/winehq-trixie.sources https://dl.winehq.org/wine-builds/debian/dists/trixie/winehq-trixie.sources \
    && dpkg --add-architecture i386 \
    && apt-get update \
    && apt-get install -y --install-recommends \
        winehq-stable=11.0.0.0~trixie-1 \
    && rm -rf /var/lib/apt/lists/*

RUN install -d -m 0755 /opt/steamcmd /opt/scumserver

COPY start-server.sh /usr/local/bin/start-server.sh

RUN chmod +x /usr/local/bin/start-server.sh

VOLUME ["/opt/scumserver", "/opt/steamcmd"]

ENV GAMEPORT=7777
ENV QUERYPORT=27015
ENV MAXPLAYERS=32
ENV ADDITIONALFLAGS=
ENV GAME_UPDATE=true
ENV RESTART_SCHEDULE=4,10,16,22
ENV MEMORY_THRESHOLD_PERCENT=95
ENV MEMORY_CHECK_INTERVAL=60

ENTRYPOINT ["/usr/bin/tini", "--", "/usr/local/bin/start-server.sh"]
