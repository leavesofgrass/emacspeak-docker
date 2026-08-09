# emacspeak + software DECtalk speech server
#
# Stage 1 builds the community-preserved DECtalk sources (github.com/dectalk/dectalk)
# on Debian bookworm, whose gcc 12 is tolerant of this 1990s C codebase.
# Stage 2 is Debian trixie (Emacs 30), which builds emacspeak from git and the
# tcldtk.so Tcl<->libtts glue that emacspeak's dtk-soft server loads.
#
# Pin different refs with:
#   docker build --build-arg DECTALK_REF=develop --build-arg EMACSPEAK_REF=master .

FROM debian:bookworm-slim AS dectalk-build

ARG DECTALK_REF=develop

RUN apt-get update && apt-get install -y --no-install-recommends \
    build-essential autoconf automake git ca-certificates unzip \
    libpulse-dev libasound2-dev \
 && rm -rf /var/lib/apt/lists/*

RUN git clone --depth 1 --branch "${DECTALK_REF}" \
    https://github.com/dectalk/dectalk.git /build/dectalk

WORKDIR /build/dectalk/src
RUN ./autogen.sh && ./configure && make -j"$(nproc)"

# "make" installs everything into /build/dectalk/dist (lib, dic, tools, say).
# The dist tree does not carry the C headers, and emacspeak's tcldtk.c wants
# them as <dtk/ttsapi.h>, so stage them under include/dtk/.
RUN mkdir -p /build/dectalk/dist/include/dtk \
 && cp dapi/src/include/*.h /build/dectalk/dist/include/dtk/ \
 && ls /build/dectalk/dist/lib/

# ---------------------------------------------------------------------------

FROM debian:trixie-slim

ARG EMACSPEAK_REF=master

ENV DEBIAN_FRONTEND=noninteractive
# i386 libc/libstdc++ are for the Outloud engine: some Voxin builds bridge to
# a 32-bit IBM ViaVoice binary (voxind). unzip/file support install-outloud.
RUN dpkg --add-architecture i386 && apt-get update \
 && apt-get install -y --no-install-recommends \
    emacs-nox \
    git ca-certificates make gcc g++ \
    tcl tcl8.6 tcl8.6-dev tclx8.4 \
    libpulse0 pulseaudio-utils pulseaudio sox libsox-fmt-all \
    libasound2-dev libasound2-plugins alsa-utils \
    libc6:i386 libstdc++6:i386 \
    unzip file procps less nano \
 && rm -rf /var/lib/apt/lists/*

COPY --from=dectalk-build /build/dectalk/dist /opt/dectalk

# Make libtts visible to the linker and to tclsh at runtime; some builds only
# produce the per-language libtts_us.so, so create the generic name if missing.
RUN cd /opt/dectalk/lib \
 && { [ -e libtts.so ] || ln -s libtts_us.so libtts.so; } \
 && echo /opt/dectalk/lib > /etc/ld.so.conf.d/dectalk.conf \
 && ldconfig

RUN git clone --depth 1 --branch "${EMACSPEAK_REF}" \
    https://github.com/tvraman/emacspeak.git /opt/emacspeak

WORKDIR /opt/emacspeak
RUN make config && make emacspeak

# libtts falls back to <install prefix>/DECtalk.conf, i.e. /opt/dectalk/DECtalk.conf.
# Emacspeak ships a template whose dictionary paths are already absolute
# /opt/dectalk/dic/... entries.
RUN cp servers/software-dtk/DECtalk.conf /opt/dectalk/DECtalk.conf

# Build the Tcl extension the dtk-soft server loads. Command-line variables
# override the Makefile's, so repeat the flags it normally sets.
RUN make -C servers/software-dtk \
    CFLAGS="-g -O2 -fPIC -DPIC -I/usr/include/tcl8.6 -I/opt/dectalk/include" \
    LDFLAGS="-L/opt/dectalk/lib" \
 && ls -l servers/software-dtk/tcldtk.so

# Outloud (IBM ViaVoice / Eloquence) glue for the outloud server. It dlopens
# libibmeci.so at runtime, so it compiles without the proprietary engine;
# install-outloud puts the engine into the /opt/oralux volume later.
RUN make -C servers/linux-outloud && ls -l servers/linux-outloud/atcleci.so

# The outloud server speaks through ALSA; route ALSA's default PCM to
# PulseAudio so all audio leaves the container the same way.
RUN printf 'pcm.!default { type pulse }\nctl.!default { type pulse }\n' \
    > /etc/asound.conf

# libvoxin looks for the ViaVoice engine at the real /opt/IBM and its config
# at /var/opt/IBM. install-outloud keeps both trees inside the /opt/oralux
# volume (under rfs32) so they persist; these links, dangling until the
# engine is installed, splice them into the paths libvoxin probes.
RUN ln -s /opt/oralux/voxin/rfs32/opt/IBM /opt/IBM \
 && mkdir -p /var/opt \
 && ln -s /opt/oralux/voxin/rfs32/var/opt/IBM /var/opt/IBM

# Non-root user; uid 1000 keeps file ownership sane on bind mounts.
RUN useradd -m -u 1000 -s /bin/bash speak

COPY container/ /tmp/container/
RUN sed -i 's/\r$//' /tmp/container/* \
 && install -m 0755 /tmp/container/emacspeak /usr/local/bin/emacspeak \
 && install -m 0755 /tmp/container/test-speech /usr/local/bin/test-speech \
 && install -m 0755 /tmp/container/install-outloud /usr/local/bin/install-outloud \
 && install -m 0644 -D /tmp/container/init.el /home/speak/.emacs.d/init.el \
 && chown -R speak:speak /home/speak/.emacs.d \
 && rm -rf /tmp/container

ENV EMACSPEAK_DIR=/opt/emacspeak \
    DTK_PROGRAM=dtk-soft \
    PULSE_SERVER=tcp:host.docker.internal:4713 \
    LANG=C.UTF-8

USER speak
WORKDIR /home/speak
CMD ["emacspeak"]
