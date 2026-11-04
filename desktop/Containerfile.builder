FROM git.dinox.im/dinoxim/linux-package-builder-dinox@sha256:5804b93b0bb1ca900470873e1de128f4e4e6ec634d5768f90399e3f756509230
USER root
RUN sed -i '/^Snapshot:/d' /etc/apt/sources.list.d/ubuntu.sources \
    && apt-get update && apt-get install -y --no-install-recommends \
    libpulse-dev \
    libasound2-dev \
    libvorbis-dev \
    libtdb-dev \
    gvfs \
    dconf-gsettings-backend \
    glib-networking \
    libgtk-4-media-gstreamer \
    gstreamer1.0-plugins-good \
    gstreamer1.0-plugins-bad \
    gstreamer1.0-plugins-ugly \
    gstreamer1.0-libav \
    gstreamer1.0-pipewire \
    gstreamer1.0-alsa \
    gstreamer1.0-pulseaudio \
    libheif-plugin-dav1d \
    libheif-plugin-libde265 \
    && rm -rf /var/lib/apt/lists/*
