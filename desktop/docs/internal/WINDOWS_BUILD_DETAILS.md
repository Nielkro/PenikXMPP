# Technische Details zum Windows-Build

Die [Schritt-für-Schritt-Anleitung](WINDOWS_BUILD.md) beschreibt den normalen Ablauf.
Hier stehen die Hintergründe für Entwicklung und Fehleranalyse.

## Zusätzliche Build-Optionen

Der normale Build aus Schritt 5 verwendet das Profil `release` mit `-O2`
und ohne Debug-Symbole. Entwickler können für eine Fehlersuche stattdessen
`DINOX_WINDOWS_BUILD_TYPE=debugoptimized` setzen. Beide Profile unterstützen
die Diagnose-Schalter der Anwendung.

Für einen anderen Logordner kann der Build-Befehl aus Schritt 5 so aussehen:

```bash
DINOX_WINDOWS_LOG_DIR="$HOME/Meine Buildlogs" DINOX_BUILD_JOBS=2 \
  bash "$HOME/dinox/scripts/build-windows-dist.sh"
```

Der Logordner muss außerhalb des DinoX-Quellordners liegen. Ein vollständiger
Neubau löscht `build/` und `dist/`. Die Protokolle im separaten Logordner
bleiben erhalten.

## Architektur

- DinoX und das Plugin `google-webrtc.dll` werden in MSYS2/MinGW64 gebaut.
- Die native Google/libwebrtc-M152-Runtime enthält
  `dinox-google-webrtc.dll`, den isolierten `dinox-webrtc-worker.exe` und die
  nativen Smoke-Tests. Der Windows-Build lädt diese geprüfte Runtime aus dem
  öffentlichen Forgejo-Release `vendor-deps`.
- Zwischen DinoX und libwebrtc liegt die stabile DinoX-C-ABI. Ein Absturz des
  separaten Workers beendet nicht den Hauptprozess.
- Google/libwebrtc erfasst Mikrofon- und Kameradaten für Anrufe sowie Sprach-
  und Videonachrichten. Windows Media Foundation kodiert und muxt M4A/MP4.
- GStreamer demuxt und dekodiert Mediendateien für Wiedergabe, Vorschaubilder
  und Metadaten. Der Chat-Audioplayer übergibt dekodiertes PCM über eine
  Appsink-Brücke an den gewählten Nachrichtenlautsprecher von Google/libwebrtc.
  GStreamer ist weder Anruf-Backend noch Windows-Aufnahme-Muxer.
- `dinox-backup-tar.exe` wird aus DinoX-Quellen gegen natives libarchive gebaut.
  Es erstellt und entpackt Backups mit Unicode-Dateipfaden und -Archivnamen.
  Das portable Paket enthält das Hilfsprogramm und seine DLL-Abhängigkeiten.
  Es unterstützt normale Dateien und Verzeichnisse; Links, Sonderdateien und
  unter Windows nicht darstellbare Namen führen zu einem Fehler und werden
  nicht stillschweigend ausgelassen.

## DinoX-eigener GnuPG-Schlüsselring und native Tray-Anzeige

Das portable Paket bringt die vollständige GnuPG-Laufzeit in `dist/bin/` mit.
DinoX bevorzugt diese Programme gegenüber einer separat installierten
GnuPG-Version; der MSYS2-Rückfall im Build-Verzeichnis dient nur der Entwicklung.
Das Plugin erstellt und verwendet `<DinoX-Profil>/openpgp/gnupg`, setzt
`GNUPGHOME` nur für seinen Prozess und übergibt dieses Home ausdrücklich an
GnuPG. Der normale GnuPG-Schlüsselring des Windows-Benutzers wird weder
automatisch importiert noch verändert. Die Kontozuordnung liegt in der
DinoX-Profildatenbank: Mehrere XMPP-Konten teilen den Anwendungsschlüsselring,
aber die Schlüsselauswahl eines Kontos aktiviert ihn nicht für andere Konten.
Passphrase-Abfragen erfolgen in DinoX. Beim Beenden werden nur die Agenten
dieses Anwendungshomes gestoppt.

Windows verwendet `Shell_NotifyIcon` und ein natives Popup-Menü; für diese
Tray-Anzeige ist kein D-Bus erforderlich. Das Menü übernimmt DinoX' Hell-/
Dunkelmodus, zeigt farbige Statuspunkte und Aktionssymbole, skaliert mit der
Monitor-DPI und stellt Namen sowie Radio-/Auswahlzustände der Windows-
Barrierefreiheit bereit. Im Hochkontrastmodus übernimmt Windows die native
Darstellung. Für das Zeichnen wird die Windows-System-Importbibliothek
`gdi32` verlinkt; es sind weder eine zusätzliche Grafik-Runtime noch eine
gebündelte `gdi32.dll` nötig. Benachrichtigungen behalten ihre eigenen
Klickdaten je Warteschlangeneintrag und sind stumm, weil DinoX' vorhandenes
Benachrichtigungston-Plugin den Ton übernimmt.

## Abhängigkeiten und automatische Prüfungen


DNSSEC/DANE benötigt `mingw-w64-x86_64-unbound` (mindestens 1.19).
Der Vorbereitungsschritt baut zusätzlich ein privates GIO/GnuTLS-Modul aus
geprüften glib-networking-2.80.1-Quellen. Der mitgelieferte Patch erlaubt das
Lesen der CA-Datei unter Windows-Benutzernamen mit Unicode-Zeichen. Die
Zertifikatsprüfung bleibt unverändert. Das Modul, der Patch und die Lizenzbelege
liegen unter `vendor-deps`; `build-windows-dist.sh` und `update_dist.sh` prüfen
und übernehmen diese Dateien. Das installierte MSYS2-Modul wird nicht ersetzt.
Ein vollständiger, unveränderter Cache wird wiederverwendet.

Die drei Python-Testpakete aus der Paketliste werden nur auf dem Build-Rechner
benötigt. Der vollständige Builder führt damit die acht DNSSEC/DANE-Prüfgruppen
aus: unter anderem HTTP/1.1 und HTTP/2 über SOCKS5, MQTT-Abbruch und
Kontentrennung sowie XMPP-TLS mit einem kyrillischen CA-Dateipfad. Er verwendet
dabei das private GIO-Modul. Testprogramme, Testschlüssel und Python-Pakete
werden nicht in `dist/` übernommen.

Der Builder führt außerdem die SASL/TLS-Abstufungstests, Kontentrennung und
die Avatar/PubSub/OMEMO-Abbruchtests aus.
Dafür werden getrennte Testprofile und lokale Testserver verwendet. Persönliche
Konten und echte XMPP-Anmeldungen sind nicht erforderlich. Ein erfolgreicher
Build ersetzt keinen interaktiven Audio-/Video- oder Tor/Lyrebird-Test.

Die fünf UI-Prüfungen zum Anmeldeschutz benötigen einen angemeldeten
Windows-Desktop. Im MSYS2-Terminal dort kann der gesamte Builder mit
`DINOX_WINDOWS_UI_TESTS=1` gestartet werden; alternativ nach dem Build:

```bash
meson test -C "$HOME/dinox/build" --no-rebuild --print-errorlogs 'Login protection UI runtime'
```

Der SSH-Dienst hat keine normale Desktop-Sitzung. Mit GTK 4.22.4 stürzt dort
bereits die Initialisierung dieses UI-Tests ab, während dieselbe Testdatei im
Desktop alle fünf Fälle besteht. Daher meldet der normale SSH-Bau diese
zusätzliche GUI-Prüfung ausdrücklich als übersprungen, nicht als bestanden.

## Festgelegte Versionen der Abhängigkeiten

Der Helfer lädt die vom Repository erwarteten Artefakte, prüft ihre
Vertrauensanker und bereitet exakt diese Build-Baseline vor:

- Pango `1.56.4-3` als vollständigen zusammengehörigen DLL-Satz; die
  betroffenen Pango-1.57/1.58-Pakete sind wegen der
  Win32-Farb-Emoji-Regression nicht freigegeben,
- Tor `0.4.9.12` (signiertes MSYS2-Paket, über Forgejo `vendor-deps` bezogen),
- `libomemo-c` `0.5.1`,
- Lyrebird `0.8.1`,
- die Google/libwebrtc-M152-Runtime für Windows x86_64 (ABI 40, IPC 10,
  Video-Ring 6), einschließlich separatem Vision-Worker, beiden festen
  Offline-Modellen, Manifest und Original-Lizenztexten.

Die Vendor-Dateien liegen anschließend unter `$HOME/vendor-deps`, insbesondere:

```text
$HOME/vendor-deps/lyrebird-0.8.1/lyrebird.exe
$HOME/vendor-deps/libwebrtc-m152-windows-x86_64/
$HOME/vendor-deps/windows-license-material/
$HOME/vendor-deps/windows-msys2-source-cache/
```

M152 ist auf Branch `7977` und Quellcommit
`6f37672d358475cd17544121a12494da454d85fb` gepinnt.
Der SDK-Stand und die Codecquellen sind unverändert. Die neue
Runtime ergänzt DinoX-Effekte und den separaten Inferenz-Worker. Im fertigen
`dist/` bleiben `dinox-vision-worker.exe`, `dinox-vision-models/`,
`dinox-vision-licenses/` und die Vision-Manifest-/Prüfsummendateien neben der
WebRTC-DLL; keine Modelle werden während eines Anrufs heruntergeladen.
Der Builder muss die nativen und portablen Smoke-Tests unter Windows
ausführen; ein Server-Crossbuild oder eine statische Manifestprüfung ersetzt
das nicht. Reale Geräteprüfungen und interaktive Anruftests sind eigene
Release-Gates.

Die libwebrtc-Runtime stammt aus dem öffentlichen Forgejo-Release
[`vendor-deps`](https://git.dinox.im/dinoxim/dinox/releases/tag/vendor-deps).
Das Skript prüft die im Repository gepinnten Hashes und bricht bei fehlenden,
abweichenden oder nicht ausführbaren Komponenten ab. Ersetze einzelne Dateien
nicht manuell durch Dateien aus einer anderen MSYS2- oder DinoX-Version.
Für den in Lyrebird eingebetteten Go-Compilerstand lädt es den exakt passenden
offiziellen Go-Quellcode anhand der von `go.dev` veröffentlichten
SHA-256-Summe und übernimmt daraus `LICENSE` und `PATENTS`. Quellarchive und
Signaturen bleiben außerhalb von `dist/` im Vendor-Cache.

GStreamer bleibt für Demux, Dekodierung, Wiedergabe, Vorschaubilder und
Metadaten installiert. Der portable Ordner darf keine GStreamer-Livecall-
Plugins für RTP, WebRTC, DTLS, SRTP oder NICE als DinoX-Anruf-Stack enthalten.

### Benutzernamen mit Unicode-Zeichen und Leerzeichen

Verwende auch bei Pfaden wie `C:/msys64/home/Игорь/dinox` oder
`C:/msys64/home/Игорь Петров/dinox` den [vollständigen Build-Befehl aus Schritt 5](WINDOWS_BUILD.md#5-dinox-vollständig-neu-bauen). Das Skript
aktiviert für seine Python-Helfer UTF-8 und erzeugt automatisch
`build/windows-compiler-native.ini`. Diese Datei bindet
[`windows-compiler-paths.py`](../../scripts/windows-compiler-paths.py) vor die
vorhandenen MinGW-Compiler. Der Helfer macht erkannte absolute Unicode-
Dateipfade auf demselben Laufwerk relativ zum jeweiligen Arbeitsverzeichnis.
Auch Mesons und CMakes eigene Compilerprüfungen verwenden diesen Aufruf.
Die internen Vala- und Linkpfade werden unter Windows ebenfalls relativ
zum Build-Verzeichnis angegeben.

Auch die Runtime- und Paketprüfungen rufen MinGW-Werkzeuge wie `objdump`,
`nm` und `strings` aus dem jeweiligen Verzeichnis mit relativen Dateinamen
auf. Die kleinen C-Testhelfer der Paketprüfung werden ebenfalls mit relativen
Quell- und Ausgabepfaden gebaut. Die Signaturprüfung verwendet den Rückgabecode
von `gpgv`, unabhängig von der Zeichenkodierung seiner Diagnoseausgabe.

Die Einrichtung erfolgt ausschließlich im Windows-Bauskript. Zusätzliche
Compiler, Pakete oder DLLs sind dafür nicht erforderlich. Die erzeugte
Native-Datei gehört zu diesem Checkout und wird beim sauberen Build neu
erstellt; kopiere sie nicht aus einem anderen Build. Ein manuelles
`meson setup build` übernimmt diese Einrichtung nicht.

Falls ein alter Build bei einem Pfad wie `C:/msys64/home/Игорь/...` mit
`cannot find` scheitert oder während der CMake-Compilerprüfung hängen bleibt,
beende zuerst diesen Build und seine zugehörigen Unterprozesse. Aktualisiere
danach den Checkout gemäß [Schritt 3 der Anleitung](WINDOWS_BUILD.md#3-dinox-quellcode-holen-und-version-auswählen) und wiederhole [Schritt 5](WINDOWS_BUILD.md#5-dinox-vollständig-neu-bauen). Behalte das
vorherige vollständige Log zur Diagnose.

Dies ist der einzige unterstützte Befehl für einen vollständigen Windows-
Entwicklungs- oder Release-Build. Das Skript:

- entfernt zuerst alte Verzeichnisse `build/` und `dist/`,
- prüft die gepinnten Pango-, Tor-, Lyrebird- und Google/libwebrtc-
  Komponenten und baut gegen das vorbereitete `libomemo-c` `0.5.1`,
- führt die nativen Google/libwebrtc-Smoke-Tests aus,
- richtet die Unicode-sicheren Compileraufrufe für Meson und CMake ein,
- konfiguriert das feste Produktionsprofil und baut alle Targets,
- führt die nativen Archivtests aus, einschließlich unabhängiger GNU-/PAX-
  Archive, Unicode-Dateinamen und der Ablehnung unsicherer Archiveinträge,
- erzeugt ein vollständig neues `dist/`,
- ordnet jede paketierte PE-Datei anhand ihres SHA-256-Werts exakt DinoX,
  Google/libwebrtc, Lyrebird, `libomemo-c` oder einem installierten
  MSYS2-Paket zu,
- inventarisiert zusätzlich die kopierten Themes, Fonts, Schemas,
  Laufzeitübersetzungen, Tor-Daten und CA-Zertifikate über den exakten
  MSYS2-Dateibesitzer,
- liest die tatsächlich in Lyrebird eingebettete Go-Version und alle
  eingebetteten Module aus dem fertigen Binary, gleicht sie mit dem gepinnten
  Vendor-Quellbaum ab und ordnet jedem Modul seine Lizenztexte zu,
- kopiert echte Lizenz-, Copyright-, Notice- und Patenttexte. Falls ein
  MSYS2-Binärpaket keinen Text installiert, wird sein signiertes,
  versionsgenaues Source-Only-Paket geprüft und nur dessen Lizenzmaterial in
  `dist/` übernommen; das große Quellpaket bleibt im Vendor-Cache,
- prüft die portable PE-DLL-Abhängigkeitsschließung, erforderliche Plugins,
  Programme, portable Cache-Vorlagen, Daten und das vollständige
  Lizenzinventar,
- verwirft ein unvollständiges `dist/`, sobald ein Gate fehlschlägt.

### Verpflichtender Dist-Checker

`build-windows-dist.sh` ruft am Ende automatisch den folgenden vollständigen
Checker auf:

```bash
bash "$HOME/dinox/scripts/check-windows-dist.sh" "$HOME/dinox/dist"
```

Das ist keine optionale Abschlussprüfung. Der Windows-Build ist erst
erfolgreich, wenn dieser Checker bestanden wurde. Er:

- lädt alle neun paketierten DinoX-Plugins, ruft deren `register_plugin()`
  tatsächlich auf und prüft den zurückgegebenen DinoX-Plugin-Typ,
- verlangt exakt alle in den drei `LINGUAS`-Dateien geführten Kataloge:
  derzeit jeweils 30 für DinoX, OMEMO und OpenPGP, insgesamt 90 `.mo`-Dateien;
  Englisch kommt aus den Quelltexten und benötigt keinen eigenen Katalog,
- startet zusätzlich deutsche und russische Übersetzungs-Smokes aus dem
  portablen Paket und wiederholt den echten Programmstart aus einem temporären
  Installationspfad sowie mit einem isolierten Benutzerprofil, die beide
  Leerzeichen und Unicode-Zeichen enthalten,
- prüft erforderliche GTK-/GStreamer-Laufzeitdaten, GnuPG einschließlich
  `gpg-agent` und `dirmngr`, die portable DLL-Schließung sowie die vollständigen
  Datei- und Lizenzinventare.

Der Checker verlangt außerdem das UTF-8-Prozessmanifest des gebauten
Archivhelfers und startet ihn mit dem portablen DLL-Suchpfad. Der Unicode-
Laufzeittest der eigentlichen Anwendung erstellt und entpackt ein Archiv mit
einem Unicode-Dateinamen und vergleicht den wiederhergestellten Inhalt.

Angeboten werden nur vollständig gepflegte Sprachen. Die inhaltliche Abdeckung
aller drei Domains gegen die aktuelle Quelle prüft
`python3 "$HOME/dinox/scripts/check_translations.py" --syntax-only`; diese Prüfung läuft auch
vor Commits und in CI. Der Dist-Checker prüft zusätzlich, dass die aus
`LINGUAS` erwarteten, von Meson mit `msgfmt` erzeugten Kataloge tatsächlich im
Paket liegen und nicht leer sind. Er ersetzt die Quellprüfung nicht. Für eine
nicht unterstützte Sprachwahl verwendet DinoX Englisch.

Schlägt der Checker fehl, schlägt der gesamte Build fehl und
`build-windows-dist.sh` entfernt das unvollständige `dist/`. Der oben gezeigte
Befehl kann einen vorhandenen Baum erneut prüfen, ersetzt aber niemals den
kanonischen Komplettbuild.

Ein Fehler des deutschen oder russischen Laufzeit-Smokes ist deshalb kein
ignorierbarer Übersetzungswarnhinweis. Er bedeutet, dass das portable Paket in
einem unterstützten Installations- oder Benutzerprofilpfad nicht zuverlässig
funktioniert. Verwende oder verteile den entfernten beziehungsweise
unvollständigen `dist/`-Baum in diesem Fall nicht.

Ein bloßes `meson setup --reconfigure`, ein einzelnes Ninja-Target oder eine
manuell nach `dist/` kopierte EXE ist kein gültiger Windows-Testbuild.

Das Produktionsprofil aktiviert Google/libwebrtc, OMEMO, OpenPGP, ICE,
HTTP-Dateien, MQTT und Benachrichtigungstöne. Der alte GStreamer-RTP-
Anruf-Stack und `webrtc-audio-processing` bleiben deaktiviert.

## Inhalt und Prüfung des portablen Pakets

Zu den automatischen Paket-Gates gehören unter anderem:

```text
dist/dinox.exe
dist/build-info.txt
dist/dinox-google-webrtc.dll
dist/dinox-webrtc-worker.exe
dist/dinox-vision-worker.exe
dist/dinox-vision-models/{selfie_segmenter_landscape-v1,blaze_face_short_range-v1}.tflite
dist/dinox-vision-licenses/
dist/dinox-vision-runtime-manifest.json
dist/dinox-vision-SHA256SUMS
dist/plugins/google-webrtc.dll
dist/plugins/omemo.dll
dist/plugins/openpgp.dll
dist/plugins/http-files.dll
dist/plugins/ice.dll
dist/plugins/mqtt.dll
dist/plugins/notification-sound.dll
dist/plugins/bot-features.dll
dist/plugins/libtor-manager.dll
dist/bin/{gpg,gpg-agent,gpgconf,gpg-connect-agent,dirmngr,pinentry-w32}.exe
dist/bin/{tor,lyrebird,openssl,dinox-backup-tar,gpgme-w32spawn}.exe
dist/{gspawn-win64-helper,gspawn-win64-helper-console,gpgme-w32spawn}.exe
dist/share/licenses/dinox/google-libwebrtc/{LICENSE,LICENSE.md,PATENTS,manifest.json}
dist/share/licenses/dinox/dinox/{LICENSE,NOTICE,AUTHORS}
dist/share/licenses/dinox/WINDOWS-PE-INVENTORY.tsv
dist/share/licenses/dinox/WINDOWS-ASSET-INVENTORY.tsv
dist/share/licenses/dinox/WINDOWS-STATIC-COMPONENTS.tsv
dist/share/licenses/dinox/WINDOWS-LICENSE-FILES.tsv
dist/share/licenses/dinox/THIRD_PARTY_NOTICES.md
```

Die Gates starten paketierte Hilfsprogramme mit einem bereinigten Suchpfad
und prüfen, dass keine Abhängigkeit unbemerkt aus `/mingw64` oder `build/`
geladen werden muss. Für GnuPG werden `gpg-agent` und `dirmngr` in einem
isolierten temporären Home gestartet, `dirmngr` wird angesprochen und beide
werden wieder beendet. Das Lizenz-Gate verlangt 100 Prozent Abdeckung aller
PE-Dateien und der gebündelten fremden Laufzeitdaten, prüft ihre Hashes, lehnt
fehlende echte Lizenztexte ab und verbietet Quellarchive, Paketarchive oder
Build-Caches im gesamten portablen Baum. Der Lizenzbaum ist auf 16 MiB
begrenzt. Der GdkPixbuf-Loadercache enthält nur einen portablen Platzhalter;
DinoX materialisiert ihn beim Start mit dem tatsächlichen Entpackpfad im
Benutzer-Cache. Verbotene Legacy-Call-Komponenten lassen den Build ebenfalls
fehlschlagen.

## Nur für Runtime-Maintainer: libwebrtc-Runtime neu erstellen

Normale Entwickler und Endnutzer benötigen diesen Abschnitt nicht. Sie
beziehen die öffentliche, geprüfte Runtime mit
`scripts/prepare-windows-build-deps.sh`.

Eine neue native Runtime wird auf dem dafür eingerichteten Linux-Buildrechner
mit dem gepinnten WebRTC-M152-Checkout und dem vorhandenen
Chromium-MSVC/SDK-Toolchain-Cache gebaut. Der Abhängigkeiten-Helper bezieht die
geprüfte M152-Runtime; der vollständige Windows-Anwendungsbuild und reale
Anruftests bleiben eigene Abnahmeschritte. Für neue Kandidaten ein eigenes
Artefaktverzeichnis verwenden und ältere veröffentlichte Artefakte erhalten.

```bash
cd /path/to/dinox || exit 1
scripts/build-libwebrtc-windows-runtime.sh \
  --webrtc-src /path/to/webrtc/src \
  --toolchain-cache /path/to/toolchain-cache \
  --runtime-root /path/to/libwebrtc-m152-windows-x86_64-runtime \
  --build-out /path/to/webrtc/src/out/m152-win-x64 \
  --ffmpeg-root /path/to/ffmpeg-windows-hardware \
  --codec-sources /path/to/webrtc-m152-codec-sources-6f37672d3584-sha256-2b17c14cc13b.tar.gz \
  --vision-runtime /path/to/windows-vision-package/runtime-staging \
  --jobs 2 --skip-sync
```

Das Skript prüft Pin, ABI, PE-Dateien und Manifest und erzeugt anschließend
ZIP und SHA-256-Datei. Der Chromium-MSVC/SDK-Toolchain-Cache wird niemals an
Endnutzer verteilt. Das Codec-Quellarchiv ist erforderlich; seine Prüfsumme
wird mit dem veröffentlichten Wert verglichen. Der genaue native Pin,
die Codec-Konfiguration und die Prüfungen vor der Veröffentlichung stehen
in [Runtime-Paketierung](GOOGLE_WEBRTC_RELEASE_PACKAGING.md). Diesen Builder
nicht gleichzeitig mit einem anderen Job für dasselbe WebRTC-Buildverzeichnis
ausführen.

Die kleine Hardware-Abhängigkeit entsteht zuvor mit
`scripts/build-libwebrtc-windows-codec-dependency.sh`: Media Foundation für
Hardware-Encoding und D3D11VA für Hardware-Decoding. Fehlt die jeweilige
Fähigkeit oder scheitert der Treiber, übernimmt automatisch der entsprechende
WebRTC-Softwarecodec. Die Runtime enthält Originalquellen und den genauen Patch;
das portable Paket enthält Lizenztexte, Patch und `CODEC-SOURCES.md` mit
öffentlichen Quell-URLs und Prüfsummen.

Der zusätzliche Vision-Bau verwendet dieselben gepinnten Toolchains und baut
nur die eigenen Inferenzziele. Das vollständige WebRTC-SDK muss dafür nicht
neu gebaut werden. Die Vorbereitung und das zugehörige kleine Quellarchiv sind
in [Runtime-Paketierung](GOOGLE_WEBRTC_RELEASE_PACKAGING.md#inference-sources-and-licenses)
beschrieben; das geprüfte Vision-`runtime-staging` ist für den obigen Befehl
erforderlich.
