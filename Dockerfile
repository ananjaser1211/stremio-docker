# ======================
# Stage 1: Base OS Layer
# ======================
FROM debian:bookworm as base

ENV DEBIAN_FRONTEND=noninteractive

RUN echo "deb http://deb.debian.org/debian bookworm main contrib non-free non-free-firmware" > /etc/apt/sources.list && \
    apt-get update && \
    apt-get upgrade -y && \
    apt-get install -y --no-install-recommends \
        curl wget git gnupg2 ca-certificates && \
    apt-get clean && rm -rf /var/lib/apt/lists/*


# ===================================
# Stage 2: Build Dependencies Layer
# ===================================
FROM base as build-deps

RUN apt-get update && \
    apt-get install -y --no-install-recommends \
        build-essential yasm pkg-config nasm libtool autoconf automake cmake \
        python3 python3-pip meson ninja-build \
        libass-dev libfreetype6-dev libvorbis-dev libvpx-dev \
        libxcb1-dev libxcb-shm0-dev libxcb-xfixes0-dev libnuma-dev \
        libopus-dev libx264-dev libx265-dev libdrm-dev libomxil-bellagio-dev \
        libmp3lame-dev libtheora-dev libdav1d-dev \
        git wget curl && \
    apt-get clean && rm -rf /var/lib/apt/lists/*

# ==================================
# Stage 3: Intel iGPU Drivers Layer
# ==================================
FROM base as intel-drivers

RUN apt-get update && apt-get install -y --no-install-recommends \
        intel-media-va-driver-non-free \
        i965-va-driver \
        intel-gpu-tools \
        vainfo && \
    apt-get clean && rm -rf /var/lib/apt/lists/*


# ================================
# Stage 4: FFmpeg Compilation
# ================================
FROM build-deps as ffmpeg

WORKDIR /build

# 1. Additional Dependencies
RUN apt-get update && apt-get install -y --no-install-recommends \
        cmake libnuma-dev libtool m4 autoconf libva-dev and libdrm-dev && \
    apt-get clean && rm -rf /var/lib/apt/lists/*

# 2. Build and install fdk-aac
RUN git clone --depth 1 https://github.com/mstorsjo/fdk-aac.git && \
    cd fdk-aac && \
    autoreconf -fiv && \
    ./configure --prefix=/usr/local && \
    make -j$(nproc) && \
    make install && \
    ldconfig

# 3. Build and install x265
RUN git clone --branch stable --depth 1 https://bitbucket.org/multicoreware/x265_git && \
    cd x265_git/build/linux && \
    cmake -G "Unix Makefiles" -DCMAKE_INSTALL_PREFIX=/usr/local ../../source && \
    make -j$(nproc) && \
    make install

# Clone and build ffmpeg
WORKDIR /opt/ffmpeg

RUN git clone --depth 1 --branch v4.4.1-4 https://github.com/jellyfin/jellyfin-ffmpeg/ . && \
    ./configure --prefix=/usr \
        --pkg-config-flags="--static" \
        --extra-cflags="-I/usr/include" \
        --extra-ldflags="-L/usr/lib" \
        --extra-libs="-lpthread -lm" \
        --bindir=/usr/bin \
        --enable-gpl --enable-nonfree \
        --enable-libx264 --enable-libx265 --enable-libvpx --enable-libopus \
        --enable-libass --enable-libfreetype --enable-libmp3lame \
        --enable-libvorbis --enable-libtheora --enable-libdav1d \
        --enable-vaapi --enable-hwaccel=h264_vaapi \
        --enable-hwaccel=hevc_vaapi && \
    make -j"$(nproc)" && make install


# ========================
# Stage 5: Node Environment
# ========================
FROM node:18-bookworm as node-env

# Install yarn classic
RUN corepack enable && corepack prepare yarn@1.22.21 --activate

# ========================
# Stage 6: App Build Layer
# ========================
FROM node-env as builder

WORKDIR /srv

ARG BRANCH=development

# Clone repo and patch localStorage
RUN git clone --depth 1 --branch "$BRANCH" https://github.com/Stremio/stremio-web.git

WORKDIR /srv/stremio-web

COPY ./load_localStorage.js ./src/load_localStorage.js
RUN sed -i "/entry: {/a \\        loader: './src/load_localStorage.js'," webpack.config.js

RUN yarn install --no-audit --no-optional --mutex network --no-progress --ignore-scripts && \
    yarn build

# Fetch stremio shell resources
RUN wget $(wget -O- https://raw.githubusercontent.com/Stremio/stremio-shell/master/server-url.txt) && \
    wget -mkEpnp -nH \
        "https://app.strem.io/" \
        "https://app.strem.io/worker.js" \
        "https://app.strem.io/images/stremio.png" \
        "https://app.strem.io/images/empty.png" \
        -P build/shell/ || true


# ================================
# Stage 7: Final Runtime Container
# ================================
FROM node-env as final

WORKDIR /srv/stremio-server

# Copy Intel GPU drivers
COPY --from=intel-drivers /usr/lib/x86_64-linux-gnu/dri /usr/lib/x86_64-linux-gnu/dri
COPY --from=intel-drivers /usr/bin/vainfo /usr/bin/vainfo

# Copy compiled FFmpeg binaries
COPY --from=ffmpeg /usr/lib /usr/lib
COPY --from=ffmpeg /usr/bin/ffmpeg /usr/bin/ffmpeg
COPY --from=ffmpeg /usr/bin/ffprobe /usr/bin/ffprobe

# Copy all shared libs used by ffmpeg
COPY --from=ffmpeg /usr/local/lib/libx265* /usr/lib/
COPY --from=ffmpeg /usr/lib/x86_64-linux-gnu/libx264.so.* /usr/lib/x86_64-linux-gnu/
COPY --from=ffmpeg /usr/lib/x86_64-linux-gnu/libvpx.so.*   /usr/lib/x86_64-linux-gnu/
COPY --from=ffmpeg /usr/lib/x86_64-linux-gnu/libdav1d.so.* /usr/lib/x86_64-linux-gnu/
COPY --from=ffmpeg /usr/lib/x86_64-linux-gnu/libxvidcore.so.* /usr/lib/x86_64-linux-gnu/

# Copy additional
COPY --from=ffmpeg /usr/lib/x86_64-linux-gnu/*.so* /usr/lib/x86_64-linux-gnu/

# Copy frontend app build
COPY --from=builder /srv/stremio-web/build ./build
COPY --from=builder /srv/stremio-web/server.js ./

# Custom scripts and config
COPY ./stremio-web-service-run.sh ./
COPY ./certificate.js ./
COPY ./restart_if_idle.sh ./
COPY ./localStorage.json ./

# Additional Config
ENV FFMPEG_BIN=
ENV FFPROBE_BIN=
# default https://app.strem.io/shell-v4.4/
ENV WEBUI_LOCATION=
ENV WEBUI_INTERNAL_PORT=
ENV OPEN=
ENV HLS_DEBUG=
ENV DEBUG=
ENV DEBUG_MIME=
ENV DEBUG_FD=
ENV FFMPEG_DEBUG=
ENV FFSPLIT_DEBUG=
ENV NODE_DEBUG=
ENV NODE_ENV=production
ENV HTTPS_CERT_ENDPOINT=
ENV DISABLE_CACHING=
# disable or enable
ENV READABLE_STREAM=
# remote or local
ENV HLSV2_REMOTE=

# Custom application path for storing server settings, certificates, etc
# You can change this but server.js always saves cache to /root/.stremio-server/
ENV APP_PATH=
ENV NO_CORS=1
ENV CASTING_DISABLED=

# Do not change the above ENVs.

# Set this to your lan or public ip.
ENV IPADDRESS=
# Set this to your domain name
ENV DOMAIN=
# Set this to the path to your certificate file
ENV CERT_FILE=

# Server url
ENV SERVER_URL=

RUN chmod +x stremio-web-service-run.sh restart_if_idle.sh

# Install HTTP server globally
RUN npm install -g http-server

ENV NODE_ENV=production
ENV LIBVA_DRIVER_NAME=i965
ENV DISPLAY=:0
ENV LD_LIBRARY_PATH="/usr/lib:$LD_LIBRARY_PATH"

VOLUME ["/root/.stremio-server"]

EXPOSE 8080 11470 12470

CMD ["./stremio-web-service-run.sh"]
