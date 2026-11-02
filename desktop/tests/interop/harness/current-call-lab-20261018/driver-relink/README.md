# Current driver from the existing builder image — source only

This is a separate source derivation. **No build or account/media process has
started from it.** The original compiler recipe, frozen inputs, profiles, keys,
observers and overlays remain unchanged.

The actual fresh server preflight found the historical compiler container gone.
One explicitly authorized, read-only/net-none stopped probe of the existing exact
builder image found none of the old 61 /work comparison files. The probe never
ran and was removed by exact container ID. Its receipt and hash are recorded in
the new input manifest. The compiler tools and public package headers were
observed in that same existing image. No image was downloaded or rebuilt.

Recreating the historical compiler container is unnecessary. This derivation
keeps the 90 current pinned inputs and adds seven existing project headers/VAPIs:
public Core52, Qlite and Crypto headers, dino_i18n.h, and the Qlite/OMEMO VAPI
search inputs. These add exactly 959,792 bytes, for **97 files / 150,642,762
bytes**. The 35 selected translation units and all observer/media semantics are
unchanged. The historical original IQ VAPI is a comparison artifact, not a
current compiler dependency.

The runner now creates the one isolated job directly from the already present
image sha256:bfcc7b8942a7656a90b2ab40b73c9d29f1843b0df681b6994f89a67132b62391
with --pull=never. It does not commit a container or create/remove a snapshot
image. The compiler reads its complete pinned project-header closure from
inputs/current, with no dependence on an old /work tree. The seven original
read-only payload DSOs were freshly verified byte-for-byte on the server.

The existing limits and acceptance requirements remain: 2 CPUs, 4 GiB RAM,
MemorySwap equal to Memory, 128 PIDs, UID/GID 1000, Nice 19, network none,
read-only retained payload, no profile mounts, 1200-second compiler budget,
1260-second outer wait, required symbols, exact intended DSO resolution and
ldd -r, expected no-argument exit 2, protected input hashes and exact owned
container cleanup. There is no Core, IQ, OMEMO, SDK, APK, JNI or native-library
build and no automatic retry.

The complete runtime ELF set is the same five previously reviewed binaries.
Project cheader_filename references are checked against the pinned include
closure. System and native package headers continue to come from the exact
builder image; actual compilation and loader compatibility remain unproven until
the separately authorized job succeeds.

Root must review this changed source recipe before packaging or execution.
Additionally, **all PQ Android clients must be confirmed off before the server
compiler starts**, followed by a fresh capacity/owned-process check. The current
Android absence guard intentionally excludes running native compiler names.
This directory introduces no deployment or call action.

The single-fingerprint SessionPublic observer is unchanged. Duplicate or multiple
AV fingerprint nodes remain unproven individually; a future video-media result
must not be labelled a blanket authentication PASS.
