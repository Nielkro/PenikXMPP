ARG BASE_IMAGE=ghcr.io/flathub-infra/flatpak-github-actions:gnome-50
FROM ${BASE_IMAGE}

ARG GNOME_RUNTIME_VERSION=50
ARG FREEDESKTOP_RUNTIME_VERSION=25.08

ENV FLATPAK_SYSTEM_DIR=/var/lib/flatpak

RUN set -eux; \
    if command -v apt-get >/dev/null 2>&1; then \
        apt-get update; \
        apt-get install -y --no-install-recommends \
            ca-certificates \
            ccache \
            curl \
            git \
            nodejs \
            python3 \
            xz-utils \
            zstd; \
        rm -rf /var/lib/apt/lists/*; \
    elif command -v dnf >/dev/null 2>&1; then \
        dnf install -y ca-certificates ccache curl git nodejs python3 xz zstd; \
        dnf clean all; \
    elif command -v microdnf >/dev/null 2>&1; then \
        microdnf install -y ca-certificates ccache curl git nodejs python3 xz zstd; \
        microdnf clean all; \
    elif command -v apk >/dev/null 2>&1; then \
        apk add --no-cache ca-certificates ccache curl git nodejs python3 xz zstd; \
    fi; \
    command -v flatpak; \
    command -v flatpak-builder; \
    command -v node; \
    command -v python3; \
    flatpak remote-add --system --if-not-exists flathub https://flathub.org/repo/flathub.flatpakrepo

RUN set -eux; \
    flatpak install --system -y flathub \
        runtime/org.gnome.Platform/x86_64/${GNOME_RUNTIME_VERSION} \
        runtime/org.gnome.Sdk/x86_64/${GNOME_RUNTIME_VERSION} \
        runtime/org.gnome.Sdk.Locale/x86_64/${GNOME_RUNTIME_VERSION} \
        runtime/org.freedesktop.Platform.GL.default/x86_64/${FREEDESKTOP_RUNTIME_VERSION} \
        runtime/org.freedesktop.Platform.GL.default/x86_64/${FREEDESKTOP_RUNTIME_VERSION}-extra \
        runtime/org.freedesktop.Platform.codecs-extra/x86_64/${FREEDESKTOP_RUNTIME_VERSION}-extra \
        runtime/org.freedesktop.Sdk.Extension.golang/x86_64/${FREEDESKTOP_RUNTIME_VERSION}; \
    flatpak list --system --columns=application,branch,arch
