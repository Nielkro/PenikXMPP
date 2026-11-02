#!/bin/sh
set -eu
umask 077
interop_role=$1
case "$interop_role" in leon|felix) ;; *) exit 2 ;; esac
interop_base=/interop/monocles-dinox-interop-20261015
interop_commands=$interop_base/runner-profiles/$interop_role
interop_profile=$interop_base/peers/profiles/$interop_role-de
test ! -e /dev/video0
test ! -e /dev/video1
test ! -S /run/dbus/system_bus_socket
mkdir -p /tmp/interop-runtime /tmp/interop-cache /tmp/interop-config
chmod 700 /tmp/interop-runtime
export XDG_DATA_HOME=$interop_profile/data
export XDG_CACHE_HOME=$interop_profile/cache
export XDG_CONFIG_HOME=$interop_profile/config
export XDG_RUNTIME_DIR=/tmp/interop-runtime
export LD_LIBRARY_PATH=/opt/interop/payload/lib
export GIO_EXTRA_MODULES=/opt/interop/payload/gio
export GIO_USE_VFS=local
export GSETTINGS_BACKEND=memory
export DBUS_SYSTEM_BUS_ADDRESS=unix:path=/tmp/no-system-bus
export GTK_A11Y=none
export GDK_BACKEND=x11
export GSK_RENDERER=cairo
export DINOX_GOOGLE_WEBRTC_AUDIO_DEVICE=synthetic
export DINOX_GOOGLE_WEBRTC_CALL_DEBUG=0
export DINOX_WEBRTC_WORKER_PATH=/opt/interop/payload/bin/dinox-webrtc-worker
export GDK_PIXBUF_MODULE_FILE=/tmp/pixbuf-loaders.cache
/usr/lib/x86_64-linux-gnu/gdk-pixbuf-2.0/gdk-pixbuf-query-loaders \
    /opt/interop/payload/pixbuf/*.so > "$GDK_PIXBUF_MODULE_FILE"
exec timeout --signal=TERM --kill-after=20 5400 dbus-run-session -- xvfb-run -a -s '-screen 0 800x600x24 -nolisten tcp' \
    /opt/interop/payload/bin/dinox-interop "$interop_commands"
