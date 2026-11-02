ARG DEBIAN_13_BASE="debian:13@sha256:fac46bff2e02f51425b6e33b0e1169f55dfb053d83511ca28aa50c09fd5ed7a4"

FROM ${DEBIAN_13_BASE} AS host-abi

COPY packages.txt /tmp/dinox-appimage-host-abi-packages.txt

# Download and extract only the explicitly declared desktop ABI payloads.
# Deliberately do not install their dependency closure: non-host libraries must
# still come from the AppImage and are validated by package-runtime-matrix.sh.
RUN set -eux; \
    mkdir -p /tmp/debs /opt/dinox-appimage-host-abi; \
    chmod 1777 /tmp/debs; \
    apt-get update; \
    packages="$(sed -e '/^[[:space:]]*#/d' -e '/^[[:space:]]*$/d' \
        /tmp/dinox-appimage-host-abi-packages.txt | tr '\n' ' ')"; \
    cd /tmp/debs; \
    apt-get download ${packages}; \
    for package in ./*.deb; do \
        dpkg-deb --extract "${package}" /opt/dinox-appimage-host-abi; \
    done; \
    rm -rf /var/lib/apt/lists/* /tmp/debs

FROM ${DEBIAN_13_BASE}

LABEL org.opencontainers.image.title="DinoX AppImage runtime gate" \
      org.opencontainers.image.description="Minimal Debian 13 desktop host ABI for the offline DinoX AppImage smoke gate"

COPY --from=host-abi /opt/dinox-appimage-host-abi/ /
COPY --from=host-abi /tmp/dinox-appimage-host-abi-packages.txt \
    /usr/share/dinox-appimage-runtime-gate/HOST_ABI_PACKAGES
COPY run-gate.sh /usr/local/bin/dinox-appimage-runtime-gate

RUN chmod 0755 /usr/local/bin/dinox-appimage-runtime-gate

USER 65534:65534

ENTRYPOINT ["/usr/local/bin/dinox-appimage-runtime-gate"]
