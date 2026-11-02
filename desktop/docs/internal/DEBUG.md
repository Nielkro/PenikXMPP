# Debugging DinoX

This guide describes the diagnostic paths that exist in the current DinoX
source tree. Use it together with [BUILD.md](BUILD.md),
[WINDOWS_BUILD.md](WINDOWS_BUILD.md), and [TESTING.md](TESTING.md).

Start with the narrowest useful log domain. Broad logging makes reproduction
slower and can hide the relevant event.

> **Privacy:** Logs can contain JIDs, room names, server addresses, message and
> file metadata, certificate fingerprints, MQTT topics, and Tor bridge
> configuration. `--print-xmpp all` can additionally expose complete XMPP
> stanzas. Redact a log before sharing it. Never publish passwords, MQTT
> credentials, database keys, private OpenPGP material, or `omemo.key`.

## Quick start

GLib log domains in `G_MESSAGES_DEBUG` are separated by **spaces**. Commas and
colons do not enable multiple domains.

### Linux source build

The current source-build executable is `build/main/dinox`:

```bash
G_MESSAGES_DEBUG="dino libdino xmpp-vala" \
  ./build/main/dinox 2>&1 | tee /tmp/dinox.log
```

### Installed Debian package

```bash
G_MESSAGES_DEBUG="dino libdino xmpp-vala" \
  dinox 2>&1 | tee /tmp/dinox.log
```

### Flatpak

```bash
flatpak run \
  --env=G_MESSAGES_DEBUG='dino libdino xmpp-vala' \
  im.dinox.dinox 2>&1 | tee /tmp/dinox-flatpak.log
```

### AppImage

```bash
G_MESSAGES_DEBUG="dino libdino xmpp-vala" \
  ./DinoX-*.AppImage 2>&1 | tee /tmp/dinox-appimage.log
```

### Windows

Run the packaged executable from the complete `dist` tree. A file copied out
of `dist` will normally be missing required DLLs and helper programs.

Command Prompt:

```bat
cd C:\path\to\dinox
set "G_MESSAGES_DEBUG=dino libdino xmpp-vala"
dist\dinox.exe > dinox.log 2>&1
```

MSYS2 shell:

```bash
cd /path/to/dinox
G_MESSAGES_DEBUG="dino libdino xmpp-vala" \
  ./dist/dinox.exe > dinox.log 2>&1
```

PowerShell:

```powershell
Set-Location C:\path\to\dinox
$env:G_MESSAGES_DEBUG = 'dino libdino xmpp-vala'
.\dist\dinox.exe *> dinox.log
```

## Recommended triage

1. Record the exact reproduction steps and the DinoX version.
2. Reproduce once with normal output captured by `tee` or redirection.
3. Add only the subsystem domain or focused switch needed for the problem.
4. Keep the complete raw log. Filter a copy or the terminal view afterwards.
5. Compare a package with `build/main/dinox` only when a package/runtime
   difference is suspected.
6. Escalate to `G_MESSAGES_DEBUG=all`, high `GST_DEBUG`, or fatal warnings only
   when targeted logging was insufficient.

Do not pipe the application directly into `grep` without first preserving its
complete output. The included launchers always save the unfiltered log.

## GLib log domains

These are current DinoX log domains:

| Domain | Area |
| --- | --- |
| `dino` | Main application and UI |
| `libdino` | Core services, accounts, connections, MUC, files |
| `xmpp-vala` | XMPP stream and protocol modules |
| `qlite` | Database layer |
| `crypto-vala` | Shared cryptographic code |
| `OMEMO` | OMEMO plugin |
| `OpenPGP` | OpenPGP plugin |
| `google-webrtc` | Google/libwebrtc integration |
| `ice` | ICE used outside the production call engine, including transfer paths |
| `mqtt` | MQTT plugin, subscriptions, publishing, and bridges |
| `bot-features` | Botmother and bot integrations |
| `tor-manager` | Managed Tor process |
| `dino-proxy` | Proxy selection and routing |

Examples:

```bash
G_MESSAGES_DEBUG="OMEMO libdino xmpp-vala" ./build/main/dinox
G_MESSAGES_DEBUG="mqtt" ./build/main/dinox
G_MESSAGES_DEBUG="OpenPGP crypto-vala libdino" ./build/main/dinox
```

`rtp` belongs to the retired legacy RTP plugin. It is not the production call
engine in current Google/libwebrtc builds.

## Current focused diagnostic switches

Unless stated otherwise, enable a switch with the value `1` before starting
DinoX.

| Variable | Purpose |
| --- | --- |
| `DINOX_GOOGLE_WEBRTC_CALL_DEBUG` | Call signaling, state, RTP counters, RTT, jitter, and bitrate diagnostics |
| `DINOX_GOOGLE_WEBRTC_RTC_EVENT_LOG_DIR` | With call debug set to `1`, writes native RTP/RTCP event logs to an existing private directory; maximum 4 MiB per connection |
| `DINOX_GOOGLE_WEBRTC_LIFECYCLE_DEBUG` | Native context and worker lifetime diagnostics |
| `DINOX_GOOGLE_WEBRTC_DEVICE_DEBUG` | Microphone, speaker, and camera device diagnostics |
| `DINOX_GOOGLE_WEBRTC_DEVICE_DEBUG_FILE` | Writes device/worker diagnostics to the given file |
| `DINOX_WEBRTC_RECORDER_DEBUG` | Native audio/video-message recorder diagnostics |
| `DINOX_WEBRTC_VP8_DECODER_DEBUG` | Linux VP8 decoder capability and selection diagnostics |
| `DINOX_WEBRTC_HW_CODEC_DEBUG` | Hardware-codec selection and Linux VP8 qualification results, including hardware/software decode timings |
| `DINOX_WEBRTC_DISABLE_VP8_HW_DECODER` | Linux comparison run using the software VP8 decoder |
| `DINOX_UI_TIMING` | UI timing output; the code tests whether the variable is present |
| `DINOX_MUC_AVATAR_STATS` | Aggregated large-MUC avatar statistics |
| `DINOX_MUC_OCCUPANT_SHADOW_STATS` | Initial MUC occupant snapshot validation statistics |
| `DINOX_GST_STARTUP_DIAGNOSTICS` | Windows-only, intrusive GStreamer factory/plugin inventory |
| `DINOX_GST_WARMUP` | Windows-only, experimental Media Foundation/audio-source/encoder/muxer warm-up |
| `DINOX_LOG_FILE` | Windows-only path for stderr/GLib output, especially when starting `dinox.exe` from Explorer |
| `DINOX_ENABLE_WINRT_TOASTS` | Windows-only opt-in for testing native WinRT toasts and their action buttons |

`DINOX_GST_STARTUP_DIAGNOSTICS` and `DINOX_GST_WARMUP` do not debug the call
engine. Both can load many plugin and Windows media DLLs during startup. The
diagnostic inventory can delay the first UI frame; the warm-up can contend on
plugin/registry locks and make startup look unresponsive despite using a
worker thread. Enable either only for one controlled comparison run.

For Flatpak, pass focused switches through `--env`:

```bash
flatpak run \
  --env=G_MESSAGES_DEBUG='libdino xmpp-vala' \
  --env=DINOX_UI_TIMING=1 \
  im.dinox.dinox
```

For Debian packages and AppImages, prefix the launcher as in the quick-start
examples. On Windows, use `set "NAME=value"` in Command Prompt or
`$env:NAME = 'value'` in PowerShell.

The normal Windows notification path uses taskbar balloon notifications. To
test the still opt-in WinRT toast bridge, including call and voice-request
action buttons, start one controlled run from Command Prompt:

```bat
cd C:\path\to\dinox
set "DINOX_ENABLE_WINRT_TOASTS=1"
set "DINOX_LOG_FILE=%CD%\dinox-winrt.log"
dist\dinox.exe
```

`DINOX_LOG_FILE` is also useful for an Explorer launch, where no visible
console captures stderr. WinRT initialization failure automatically falls
back to balloon notifications; the log states which path was selected.

The MQTT plugin also accepts configuration overrides:

```text
DINOX_MQTT_HOST
DINOX_MQTT_PORT
DINOX_MQTT_TLS
DINOX_MQTT_USER
DINOX_MQTT_PASS
DINOX_MQTT_TOPICS
```

They are not general debug switches. In particular, do not paste
`DINOX_MQTT_PASS` into issue reports or commands that will remain in shell
history.

## Helper scripts

For a local source build:

```bash
scripts/run-dinox-debug.sh
scripts/scan-dinox-latest-log.sh
scripts/stop-dinox.sh
```

`run-dinox-debug.sh` starts `build/main/dinox`, records the PID, and writes a
new log below `logs/`. Its default domains are:

```text
dino libdino xmpp-vala
```

Override them with a space-separated list:

```bash
G_MESSAGES_DEBUG="dino libdino xmpp-vala mqtt" \
  scripts/run-dinox-debug.sh --restart
```

For an interactive terminal session:

```bash
scripts/run_debug.sh
scripts/run_debug.sh --filter mqtt
G_MESSAGES_DEBUG="google-webrtc libdino" scripts/run_debug.sh
```

`scripts/run_debug.sh --fatal` converts GLib/GTK warnings into an intentional
abort. Use it only for a focused reproduction, preferably under a debugger.
It is not a normal launch mode.

## XMPP, login, and TLS

Start with:

```bash
G_MESSAGES_DEBUG="libdino xmpp-vala dino-proxy" \
  ./build/main/dinox 2>&1 | tee /tmp/dinox-xmpp.log
```

Useful signals include SASL/SCRAM failures, channel binding, stream errors,
certificate pinning, proxy selection, IQ timeouts, and reconnect attempts.

For a protocol problem, DinoX can print selected XMPP traffic:

```bash
./build/main/dinox --print-xmpp all 2>&1 | tee /tmp/dinox-xmpp-stanzas.log
```

The argument is a stream description accepted by DinoX. `all` is the broadest
and most sensitive form. Use it only for a short controlled reproduction and
inspect every line before sharing.

Available command-line basics:

```bash
./build/main/dinox --help
./build/main/dinox --version
./build/main/dinox --print-xmpp all
```

## Google/libwebrtc calls

Current audio/video calls and their microphone/camera capture run through the
isolated Google/libwebrtc worker. GStreamer call debugging and the old `rtp`
domain do not describe this path.

Linux:

```bash
G_MESSAGES_DEBUG="google-webrtc libdino xmpp-vala" \
DINOX_GOOGLE_WEBRTC_CALL_DEBUG=1 \
DINOX_GOOGLE_WEBRTC_LIFECYCLE_DEBUG=1 \
  ./build/main/dinox 2>&1 | tee /tmp/dinox-call.log
```

Add device tracing only when the problem concerns a microphone, speaker, or
camera:

```bash
G_MESSAGES_DEBUG="google-webrtc libdino" \
DINOX_GOOGLE_WEBRTC_DEVICE_DEBUG=1 \
DINOX_GOOGLE_WEBRTC_DEVICE_DEBUG_FILE=/tmp/dinox-webrtc-device.log \
  ./build/main/dinox 2>&1 | tee /tmp/dinox-call.log
```

Windows Command Prompt:

```bat
cd C:\path\to\dinox
set "G_MESSAGES_DEBUG=google-webrtc libdino xmpp-vala"
set "DINOX_GOOGLE_WEBRTC_CALL_DEBUG=1"
set "DINOX_GOOGLE_WEBRTC_DEVICE_DEBUG=1"
set "DINOX_GOOGLE_WEBRTC_DEVICE_DEBUG_FILE=%CD%\webrtc-device.log"
dist\dinox.exe > call.log 2>&1
```

On Windows the worker is deliberately started without a console and with
restricted inherited handles. Parent-process redirection may therefore not
contain every worker diagnostic. Use
`DINOX_GOOGLE_WEBRTC_DEVICE_DEBUG_FILE` when worker/device output matters.

Do not enable every call switch for routine use. Lifecycle and device logs can
be verbose.

## Audio/video messages and playback

The media paths have separate ownership:

- Google/libwebrtc captures audio/video for calls and media messages.
- Linux media-message output is encoded/muxed through FFmpeg.
- Windows media-message output uses Media Foundation.
- GStreamer handles media demux/decode/playback, thumbnails, metadata, decoded
  PCM, and the MQTT alert sink.

Recorder/capture problem:

```bash
G_MESSAGES_DEBUG="google-webrtc libdino" \
DINOX_WEBRTC_RECORDER_DEBUG=1 \
  ./build/main/dinox 2>&1 | tee /tmp/dinox-recorder.log
```

Linux VP8 decode selection:

The VA-API profile is a preliminary capability check. On first VP8 decoder
creation in a worker, DinoX also decodes embedded synthetic key/delta sequences
at 640×480 and 1280×720 through hardware and software. It checks usable I420
output, dimensions, RTP timestamps and sampled pixels, and compares full decode
and transfer latency after warm-up. Hardware must not be clearly slower than
software in either workload. Results are cached for that worker/device setting;
this does not create a permanent GPU blacklist or change H.264 encoding.

The first-use test runs on libwebrtc's decode queue. Capability queries do not
start it, and concurrent decoder creation uses software while it is pending.
The elapsed-work budget is one second, checked between native operations; it
cannot interrupt a driver call that hangs. A passing short test does not
certify every resolution or diagnose a remote sender's low frame rate.

```bash
DINOX_WEBRTC_VP8_DECODER_DEBUG=1 \
  ./build/main/dinox 2>&1 | tee /tmp/dinox-vp8.log
```

Native bandwidth-feedback traces are opt-in. Create a private directory, set
`DINOX_GOOGLE_WEBRTC_CALL_DEBUG=1` and
`DINOX_GOOGLE_WEBRTC_RTC_EVENT_LOG_DIR` to that directory before starting DinoX.
Each connection writes an exclusively created file, stops at 4 MiB, and flushes
when the connection closes. Keep these connection/RTP/RTCP metadata files private.

Comparison without hardware VP8 decoding:

```bash
DINOX_WEBRTC_VP8_DECODER_DEBUG=1 \
DINOX_WEBRTC_DISABLE_VP8_HW_DECODER=1 \
  ./build/main/dinox 2>&1 | tee /tmp/dinox-vp8-software.log
```

For playback/decode failures, start with a moderate GStreamer level:

```bash
GST_DEBUG=3 ./build/main/dinox 2>&1 | tee /tmp/dinox-playback.log
```

Raise `GST_DEBUG` only for a short reproduction. It can create very large
logs. The AppImage intentionally does not bundle the GStreamer NICE,
DTLS/SRTP, or WebRTC plugins, because production calls use libwebrtc. It also
does not promise an embedded `gst-inspect-1.0`; inspect the package with the
project runtime checks rather than assuming that command is present.

## MQTT

MQTT diagnostics use the `mqtt` GLib domain:

```bash
G_MESSAGES_DEBUG="mqtt" \
  ./build/main/dinox 2>&1 | tee /tmp/dinox-mqtt.log
```

This includes connection, subscription, publish, matching, and bridge
delivery decisions. Reproduce with the exact account, rule state, topic, and
QoS involved. MQTT `#` is the multi-level wildcard; a bridge or subscription
still has to be enabled and associated with the intended account.

If configuration overrides are necessary, prefer a temporary protected
wrapper or prompt over putting the password on the command line. Remove
credentials before sharing the environment or log.

## MUC, bookmarks, avatars, and UI timing

Start with core XMPP and MUC output:

```bash
G_MESSAGES_DEBUG="libdino xmpp-vala" \
DINOX_UI_TIMING=1 \
DINOX_MUC_AVATAR_STATS=1 \
DINOX_MUC_OCCUPANT_SHADOW_STATS=1 \
  ./build/main/dinox 2>&1 | tee /tmp/dinox-muc.log
```

Use the statistics switches only for the reproduction. Record whether the
issue occurred on initial join, reconnect, room switch, leave, permanent
leave, or after a live room-configuration change.

## OMEMO

An OMEMO v1 failure with `reason=own-one-time-prekey-missing` means that the
received session handshake references a private one-time key that this profile
no longer has. It does not by itself prove a database migration failure.
Consumed one-time keys are deleted deliberately; the persistent high-water
mark prevents reusing their numbers, but cannot restore their secret bytes.
Record the source commit/package, account and device IDs, referenced pre-key
IDs, and whether the message was live or archived before changing a profile.

DinoX reconciles its own advertised bundle at connection startup and after
committed one-time-key consumption. A peer may still retain an older broken
session. For live direct chats and joined private, non-anonymous MUCs, DinoX
can send a bounded session-repair key transport to an already trusted device.
Group recovery requires a current server-disclosed real JID and unchanged
room, occupant, visibility, stream and trust state throughout the operation.
It preserves the device identity and archived receive sessions. It does not
repair the already failed message or respond to archived, delayed, public,
anonymous or unresolved group messages. OMEMO 2 remains a separate path.

```bash
G_MESSAGES_DEBUG="OMEMO libdino xmpp-vala" \
  ./build/main/dinox 2>&1 | tee /tmp/dinox-omemo.log
```

Record whether this was a new or existing profile, the first message after
startup, a 1:1 chat or private MUC, and whether another device changed its
device list. Do not publish bundle keys, database material, or complete
stanzas without careful redaction.

## OpenPGP and GPG helpers

```bash
G_MESSAGES_DEBUG="OpenPGP crypto-vala libdino xmpp-vala" \
  ./build/main/dinox 2>&1 | tee /tmp/dinox-openpgp.log
```

DinoX uses an application-scoped GnuPG home:

```text
<DinoX data directory>/openpgp/gnupg
```

It is not the user's default `~/.gnupg`. The relevant helpers include `gpg`,
`gpgconf`, `gpg-agent`, and `dirmngr`. Windows packages carry them below
`dist/bin`.

Do not kill or remove GPG helper processes while DinoX is running. After
exiting DinoX, non-mutating process and component checks include:

```bash
pgrep -af 'gpg-agent|dirmngr|gpg'
gpgconf --list-components
```

When inspecting the application keyring, pass its real home explicitly and do
not export or share private keys:

```bash
gpg --homedir /path/to/dinox/openpgp/gnupg --list-keys
```

## GTK, GDK, GObject, and accessibility

Capture the complete warning and the interaction immediately before it:

```bash
G_MESSAGES_DEBUG="dino libdino" \
  ./build/main/dinox 2>&1 | tee /tmp/dinox-gtk.log
```

Assertions such as `gtk_at_context_set_accessible_role`,
`gdk_surface_get_device_position`, `gtk_widget_is_ancestor`, or “has no
handler with id” can indicate a widget or signal lifecycle error. Do not
classify them as harmless without a reproducible investigation.

Check the session accessibility bus on Linux:

```bash
gdbus call --session \
  --dest org.a11y.Bus \
  --object-path /org/a11y/bus \
  --method org.a11y.Bus.GetAddress
test -S "$XDG_RUNTIME_DIR/at-spi/bus_0"
systemctl --user status at-spi-dbus-bus.service
```

The packaged Debian and AppImage launchers first verify the address returned by
`org.a11y.Bus` with a bounded direct D-Bus call. A socket file alone is not
treated as proof that the AT-SPI bus is reachable. They also support a one-shot,
opt-in repair of a stale bus:

```bash
DINOX_REPAIR_A11Y_BUS=1 dinox
DINOX_REPAIR_A11Y_BUS=1 ./DinoX-*.AppImage
```

Use that only after confirming an AT-SPI bus problem. The hard repair targets
only the current user's AT-SPI launcher, private D-Bus daemon, and registry
process before reactivation. Set `DINOX_DISABLE_A11Y_BUS_REPAIR=1` to disable
the packaged launcher's bounded health check.

Do not use `NO_AT_BRIDGE=1` as a general fix. It disables accessibility
integration and can hide the actual fault.

An isolated “Unable to connect to the accessibility bus” message can result
from the desktop session rather than DinoX, but the surrounding lifecycle and
UI behavior still determine whether it is relevant.

## Database locations and safe inspection

DinoX state is stored below its platform data directory:

| Platform | Usual data directory |
| --- | --- |
| Native Linux | `$XDG_DATA_HOME/dinox`, or `~/.local/share/dinox` when unset |
| Flatpak | `~/.var/app/im.dinox.dinox/data/dinox` |
| Windows | `%LOCALAPPDATA%\dinox` |

Relevant state includes `dino.db`, `pgp.db`, `bot_registry.db`, `mqtt.db`,
`omemo.db`, possible `-wal` and `-shm` files, `omemo.key`, and the
`openpgp/gnupg` directory.

Before any inspection:

1. Exit DinoX completely.
2. Verify that no DinoX process is still running.
3. Copy the **entire** data directory, including WAL/SHM files, `omemo.key`,
   and the OpenPGP home.
4. Work only on the copy.

Example for native Linux:

```bash
data_dir="${XDG_DATA_HOME:-${HOME}/.local/share}/dinox"
backup_dir="${data_dir}.debug-copy-$(date +%Y%m%d-%H%M%S)"
cp -a -- "$data_dir" "$backup_dir"
printf 'Inspection copy: %s\n' "$backup_dir"
```

Never run repair, recovery, migration, `UPDATE`, `DELETE`, or `VACUUM`
commands against a live or only copy of a database.

The databases are SQLCipher databases. `dino.db`, `pgp.db`,
`bot_registry.db`, and `mqtt.db` use the application's database password.
Fresh `omemo.db` profiles use the separate `omemo.key`; libsecret is retained
for migration of older profiles. Do not put either secret into a shell command
or issue report.

For read-only schema inspection, launch SQLCipher read-only on a copied
database with history disabled, enter `PRAGMA key='…';` interactively, and use
only `SELECT` or `.schema`:

```bash
SQLITE_HISTORY=/dev/null sqlcipher -readonly /path/to/debug-copy/dino.db
```

Inside SQLCipher:

```sql
PRAGMA key='enter the key interactively';
PRAGMA query_only = ON;
.tables
SELECT name, type FROM sqlite_master ORDER BY type, name;
SELECT int_val FROM _meta WHERE name = 'version';
.quit
```

Qlite records its schema version in `_meta` under `name='version'`;
`PRAGMA user_version` is not the DinoX schema version. Table layouts can
change between releases, so use the schema of the copied database instead of
old write queries from issue comments.

## Crashes and freezes

### Linux source build under GDB

```bash
gdb --batch \
  -ex 'set pagination off' \
  -ex run \
  -ex 'thread apply all bt full' \
  --args ./build/main/dinox \
  2>&1 | tee /tmp/dinox-gdb.log
```

To stop exactly on a GLib/GTK warning:

```bash
G_DEBUG=fatal-warnings \
gdb --args ./build/main/dinox
```

This intentionally aborts the process at the warning. Use a disposable
reproduction and collect a backtrace before restarting normally.

For a systemd-coredump:

```bash
coredumpctl info dinox
coredumpctl gdb dinox
```

For a frozen process, attaching GDB pauses it while the stacks are collected:

```bash
pid="$(pidof dinox)"
gdb --batch \
  -ex 'set pagination off' \
  -ex 'thread apply all bt full' \
  -ex detach \
  -p "$pid" 2>&1 | tee /tmp/dinox-freeze-backtrace.log
```

Desktop ptrace restrictions can require additional local permission. Do not
weaken system-wide ptrace policy merely to collect a casual log.

### Windows source package under GDB

From an MSYS2 shell in the repository:

```bash
cd /path/to/dinox
gdb --batch \
  -ex 'set pagination off' \
  -ex run \
  -ex 'thread apply all bt full' \
  --args ./dist/dinox.exe \
  > dinox-gdb.log 2>&1
```

Keep the working directory and complete `dist` tree intact so that DLLs and
helper executables can be found.

## Package-specific checks

- Reproduce package issues with the package launcher first. It can set up
  runtime paths and accessibility repair that a copied binary does not.
- Flatpak state is isolated below `~/.var/app/im.dinox.dinox`.
- AppImage and Debian package wrappers recognize
  `DINOX_REPAIR_A11Y_BUS`/`DINOX_DISABLE_A11Y_BUS_REPAIR`.
- Windows runtime testing must use `dist/dinox.exe` with the DLLs and
  `dist/bin` helpers generated by `scripts/update_dist.sh`.
- GStreamer diagnostics concern playback/decode and notifications, not the
  Google/libwebrtc call engine.

## Reporting a bug

Include:

1. DinoX version or exact commit (`dinox --version` or
   `./build/main/dinox --version`).
2. Operating system and version.
3. Installation method: source build, Debian package, Flatpak, AppImage, or
   Windows ZIP.
4. Exact reproduction steps and whether it happens after startup, reconnect,
   suspend, or a room/account switch.
5. The smallest relevant unfiltered log and, for crashes/freezes, a backtrace.
6. For media/device bugs, the selected devices and whether the problem is in a
   call, recording, or playback.

Redact all secrets and private identifiers before submitting an issue at
<https://git.dinox.im/dinoxim/dinox/issues>.
