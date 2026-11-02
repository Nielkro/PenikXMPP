FROM catthehacker/ubuntu:act-24.04@sha256:3220992391c1182a0cfe4c64453511772c54f4c39e960d26a5e327960675982e

ARG DINOX_UBUNTU_APT_SNAPSHOT

ENV CI=true \
    DINOX_CI=true \
    DINOX_CI_JOBS=2 \
    MAKEFLAGS=-j2 \
    CMAKE_BUILD_PARALLEL_LEVEL=2 \
    DEBIAN_FRONTEND=noninteractive \
    DINOX_CUSTOM_DEPENDENCY_PREFIX=/opt/dinox-deps \
    DINOX_CUSTOM_DEPENDENCY_LICENSE_ROOT=/opt/dinox-deps/share/dinox/custom-dependency-licenses \
    DINOX_CUSTOM_DEPENDENCY_SOURCE_ROOT=/opt/dinox-deps/share/dinox/corresponding-sources \
    DINOX_DISTRIBUTION_SOURCE_ROOT=/opt/dinox-deps/share/dinox/distribution-sources \
    DINOX_PACKAGE_BUILDER_BASE_IMAGE=catthehacker/ubuntu:act-24.04@sha256:3220992391c1182a0cfe4c64453511772c54f4c39e960d26a5e327960675982e \
    DINOX_UBUNTU_APT_SNAPSHOT=${DINOX_UBUNTU_APT_SNAPSHOT} \
    DINOX_RECORDER_FFMPEG_ROOT=/opt/dinox-deps/libexec/dinox-recorder-ffmpeg \
    PATH=/opt/dinox-deps/bin:${PATH} \
    PKG_CONFIG_PATH=/opt/dinox-deps/lib/pkgconfig \
    CMAKE_PREFIX_PATH=/opt/dinox-deps \
    LD_LIBRARY_PATH=/opt/dinox-deps/lib

RUN set -eux; \
    case "$DINOX_UBUNTU_APT_SNAPSHOT" in \
        [0-9][0-9][0-9][0-9][0-9][0-9][0-9][0-9]T[0-9][0-9][0-9][0-9][0-9][0-9]Z) ;; \
        *) echo "invalid or missing DINOX_UBUNTU_APT_SNAPSHOT" >&2; exit 1 ;; \
    esac; \
    rm -f /etc/apt/sources.list; \
    find /etc/apt/sources.list.d -maxdepth 1 -type f \
        \( -name '*.list' -o -name '*.sources' \) \
        ! -name ubuntu.sources \
        -print -delete; \
    test "$(find /etc/apt -maxdepth 2 -type f \
        \( -name '*.list' -o -name '*.sources' \) | wc -l)" -eq 1; \
    test -f /etc/apt/sources.list.d/ubuntu.sources; \
    test "$(grep -Fxc 'URIs: http://archive.ubuntu.com/ubuntu/' \
        /etc/apt/sources.list.d/ubuntu.sources)" -eq 1; \
    test "$(grep -Fxc 'URIs: http://security.ubuntu.com/ubuntu/' \
        /etc/apt/sources.list.d/ubuntu.sources)" -eq 1; \
    test "$(grep -Fxc 'Suites: noble noble-updates noble-backports' \
        /etc/apt/sources.list.d/ubuntu.sources)" -eq 1; \
    test "$(grep -Fxc 'Suites: noble-security' \
        /etc/apt/sources.list.d/ubuntu.sources)" -eq 1; \
    test "$(grep -Fxc 'Components: main universe restricted multiverse' \
        /etc/apt/sources.list.d/ubuntu.sources)" -eq 2; \
    test "$(grep -Fxc 'Signed-By: /usr/share/keyrings/ubuntu-archive-keyring.gpg' \
        /etc/apt/sources.list.d/ubuntu.sources)" -eq 2; \
    ! grep -Eq '^Enabled:[[:space:]]*(no|false|0)([[:space:]]|$)' \
        /etc/apt/sources.list.d/ubuntu.sources; \
    sed -i -E 's/^Types:[[:space:]]+deb$/Types: deb deb-src/' /etc/apt/sources.list.d/ubuntu.sources; \
    test "$(grep -Fxc 'Types: deb deb-src' \
        /etc/apt/sources.list.d/ubuntu.sources)" -eq 2; \
    sed -i "/^Signed-By: \\/usr\\/share\\/keyrings\\/ubuntu-archive-keyring.gpg$/a Snapshot: $DINOX_UBUNTU_APT_SNAPSHOT" \
        /etc/apt/sources.list.d/ubuntu.sources; \
    test "$(grep -Ec '^(Types|URIs|Suites|Components|Signed-By|Snapshot):' \
        /etc/apt/sources.list.d/ubuntu.sources)" -eq 12; \
    test "$(grep -Fxc "Snapshot: $DINOX_UBUNTU_APT_SNAPSHOT" \
        /etc/apt/sources.list.d/ubuntu.sources)" -eq 2; \
    apt-get update; \
    apt-get upgrade -y; \
    apt-get install -y --no-install-recommends \
        appstream \
        autoconf \
        automake \
        build-essential \
        ca-certificates \
        ccache \
        cmake \
        curl \
        desktop-file-utils \
        dpkg-dev \
        dirmngr \
        ffmpeg \
        file \
        gettext \
        git \
        gpg \
        gpg-agent \
        gpgconf \
        golang-go \
        heif-gdk-pixbuf \
        libadwaita-1-dev \
        libcanberra-dev \
        libevent-dev \
        libfuse2 \
        libgcrypt20-dev \
        libgee-0.8-dev \
        libgeoclue-2-dev \
        libgnutls28-dev \
        libgpgme-dev \
        libgstreamer-plugins-bad1.0-dev \
        libgstreamer-plugins-base1.0-dev \
        libgstreamer1.0-dev \
        libgtk-4-dev \
        libheif-plugin-dav1d \
        libjson-glib-dev \
        libnotify-dev \
        libqrencode-dev \
        libreadline-dev \
        libsecret-1-dev \
        libsoup-3.0-dev \
        libsqlite3-dev \
        libsrtp2-dev \
        libssl-dev \
        libtool \
        libunbound-dev \
        libunwind-dev \
        libva-dev \
        libva-drm2 \
        libva-x11-2 \
        libxml2-utils \
        meson \
        nasm \
        ninja-build \
        nodejs \
        patch \
        patchelf \
        pkg-config \
        python3 \
        tar \
        tcl \
        valac \
        webp-pixbuf-loader \
        wget \
        xz-utils \
        zstd \
        gstreamer1.0-alsa \
        gstreamer1.0-libav \
        gstreamer1.0-pipewire \
        gstreamer1.0-plugins-bad \
        gstreamer1.0-plugins-good \
        gstreamer1.0-plugins-ugly \
        gstreamer1.0-tools \
        gstreamer1.0-vaapi; \
    gnupg_source_package="$(dpkg-query -W -f='${source:Package}' gpg)"; \
    gnupg_source_version="$(dpkg-query -W -f='${source:Version}' gpg)"; \
    test "$gnupg_source_package" = gnupg2; \
    gnupg_source_dir="$DINOX_DISTRIBUTION_SOURCE_ROOT/gnupg2"; \
    install -d -m 0755 "$gnupg_source_dir"; \
    chown _apt:root "$gnupg_source_dir"; \
    cd "$gnupg_source_dir"; \
    apt-get source --download-only "gnupg2=$gnupg_source_version"; \
    chown -R root:root "$gnupg_source_dir"; \
    test "$(find . -maxdepth 1 -type f -name '*.dsc' | wc -l)" -eq 1; \
    test "$(find . -maxdepth 1 -type f \
        \( -name '*.tar.gz' -o -name '*.tar.bz2' -o -name '*.tar.lzma' -o -name '*.tar.xz' -o -name '*.tar.zst' \) \
        | wc -l)" -ge 1; \
    gnupg_dsc="$(find . -maxdepth 1 -type f -name '*.dsc' -print -quit)"; \
    awk '\
        /^Checksums-Sha256:/ { in_checksums = 1; next } \
        in_checksums && /^ / { print $1 "  " $3; next } \
        in_checksums { exit } \
    ' "$gnupg_dsc" | sha256sum -c -; \
    gnupg_check_dir="$(mktemp -d)"; \
    dpkg-source --no-check -x "$gnupg_dsc" "$gnupg_check_dir/gnupg2" >/dev/null; \
    rm -rf "$gnupg_check_dir"; \
    find . -maxdepth 1 -type f ! -name SHA256SUMS ! -name METADATA -printf '%f\0' \
        | sort -z \
        | xargs -0 sha256sum > SHA256SUMS; \
    { \
        echo 'component=gnupg2'; \
        echo "source_package=$gnupg_source_package"; \
        echo "version=$gnupg_source_version"; \
        echo 'binary_packages=gpg,gpgconf,gpg-agent,dirmngr'; \
        echo 'gpg_connect_agent_package=gpgconf'; \
        echo 'source_format=debian-source-package'; \
    } > METADATA; \
    cd /; \
    apt-cache showsrc gnupg2 \
        | grep -Fx "Version: $gnupg_source_version"

WORKDIR /tmp/dinox-builder-src
COPY scripts/scan_unicode.py scripts/scan_unicode.py
COPY scripts/ci-build-deps.sh scripts/ci-build-deps.sh
COPY scripts/verify-ci-deps.sh scripts/verify-ci-deps.sh
COPY scripts/verify-package-builder-image.sh scripts/verify-package-builder-image.sh
COPY ci/images/linux-package-builder-dinox/Dockerfile ci/images/linux-package-builder-dinox/Dockerfile

RUN set -eux; \
    git init -q; \
    git add scripts ci; \
    chmod +x scripts/ci-build-deps.sh scripts/verify-ci-deps.sh scripts/verify-package-builder-image.sh; \
    distribution_source_backup="$(mktemp -d /tmp/dinox-distribution-sources.XXXXXX)"; \
    cp -a "$DINOX_DISTRIBUTION_SOURCE_ROOT/." "$distribution_source_backup/"; \
    ./scripts/ci-build-deps.sh; \
    install -d -m 0755 "$DINOX_DISTRIBUTION_SOURCE_ROOT"; \
    cp -a "$distribution_source_backup/." "$DINOX_DISTRIBUTION_SOURCE_ROOT/"; \
    rm -rf "$distribution_source_backup"; \
    bash scripts/verify-ci-deps.sh; \
    mkdir -p /usr/local/share/dinox; \
    { \
        echo "DINOX_PACKAGE_BUILDER_SCHEMA=1"; \
        echo "DINOX_PACKAGE_BUILDER_BASE_IMAGE=$DINOX_PACKAGE_BUILDER_BASE_IMAGE"; \
        echo "DINOX_PACKAGE_BUILDER_BUILT_AT=$(date -u +%Y-%m-%dT%H:%M:%SZ)"; \
        echo "DINOX_UBUNTU_APT_SNAPSHOT=$DINOX_UBUNTU_APT_SNAPSHOT"; \
        echo "DINOX_CI_BUILD_DEPS_SHA256=$(sha256sum scripts/ci-build-deps.sh | awk '{print $1}')"; \
        echo "DINOX_VERIFY_CI_DEPS_SHA256=$(sha256sum scripts/verify-ci-deps.sh | awk '{print $1}')"; \
        echo "DINOX_VERIFY_PACKAGE_BUILDER_SHA256=$(sha256sum scripts/verify-package-builder-image.sh | awk '{print $1}')"; \
        echo "DINOX_LINUX_PACKAGE_BUILDER_DOCKERFILE_SHA256=$(sha256sum ci/images/linux-package-builder-dinox/Dockerfile | awk '{print $1}')"; \
    } > /usr/local/share/dinox/package-builder-manifest.env; \
    dpkg-query -W -f='${binary:Package}\t${Version}\n' | sort > /usr/local/share/dinox/package-builder-apt-packages.txt; \
    install -m 0755 scripts/verify-ci-deps.sh /usr/local/bin/verify-dinox-ci-deps; \
    install -m 0755 scripts/verify-package-builder-image.sh /usr/local/bin/verify-dinox-package-builder-image; \
    cd /; \
    rm -rf /tmp/dinox-builder-src /root/.cache/go-build /root/go/pkg/mod/cache/download; \
    apt-get clean

RUN set -eux; \
    verify-dinox-ci-deps; \
    test -s /usr/local/share/dinox/package-builder-manifest.env; \
    test -s /usr/local/share/dinox/package-builder-apt-packages.txt; \
    test "$(grep -Fxc "DINOX_PACKAGE_BUILDER_BASE_IMAGE=$DINOX_PACKAGE_BUILDER_BASE_IMAGE" \
        /usr/local/share/dinox/package-builder-manifest.env)" -eq 1; \
    test "$(find /etc/apt -maxdepth 2 -type f \
        \( -name '*.list' -o -name '*.sources' \) | wc -l)" -eq 1; \
    test -f /etc/apt/sources.list.d/ubuntu.sources; \
    test "$(grep -Fxc "Snapshot: $DINOX_UBUNTU_APT_SNAPSHOT" \
        /etc/apt/sources.list.d/ubuntu.sources)" -eq 2; \
    meson --version; \
    ninja --version; \
    valac --version; \
    pkg-config --modversion gtk4 libadwaita-1 gstreamer-1.0 libomemo-c libmosquitto; \
    gpg --version | grep -E '^gpg \(GnuPG\) 2\.4\.'; \
    gpgconf --version | grep -E '^gpgconf \(GnuPG\) 2\.4\.'; \
    gpg-agent --version | grep -E '^gpg-agent \(GnuPG\) 2\.4\.'; \
    dirmngr --version | grep -E '^dirmngr \(GnuPG\) 2\.4\.'; \
    gpg-connect-agent --version | grep -E '^gpg-connect-agent \(GnuPG\) 2\.4\.'; \
    test -s "$DINOX_DISTRIBUTION_SOURCE_ROOT/gnupg2/METADATA"; \
    test -s "$DINOX_DISTRIBUTION_SOURCE_ROOT/gnupg2/SHA256SUMS"; \
    cd "$DINOX_DISTRIBUTION_SOURCE_ROOT/gnupg2"; \
    sha256sum -c SHA256SUMS; \
    apt-cache showsrc gnupg2 | grep -E '^Version: ' >/dev/null; \
    patchelf --version; \
    node --version; \
    python3 --version
