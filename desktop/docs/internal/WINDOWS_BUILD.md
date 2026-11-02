# DinoX unter Windows selbst bauen

[English version](WINDOWS_BUILD_EN.md)

Am Ende dieser Anleitung hast du DinoX im Ordner `dist`. Darin liegen
`dinox.exe` und alle Dateien, die das Programm benötigt. Für die Weitergabe
kannst du daraus eine ZIP-Datei erstellen.

## Hier anfangen

| Was möchtest du tun? | Deine Schritte |
|---|---|
| Zum ersten Mal auf diesem Windows-Rechner bauen | [1](#1-msys2-einmalig-einrichten) und [2](#2-benötigte-werkzeuge-einmalig-installieren), dann [3](#3-dinox-quellcode-holen-und-version-auswählen) bis [7](#7-dinox-unter-windows-testen). |
| Den neuesten Stand von `master` neu bauen | [3A](#3a-den-aktuellen-master-neu-bauen), dann [4](#4-abhängigkeiten-vorbereiten) bis [7](#7-dinox-unter-windows-testen). Für eine ZIP zusätzlich [8](#8-zip-und-prüfsumme-erstellen). |
| Ein Windows-Paket für eine bestimmte Release-Version bauen, zum Beispiel `v2.3.3` | [3B](#3b-eine-bestimmte-release-version-bauen), dann [4](#4-abhängigkeiten-vorbereiten) bis [8](#8-zip-und-prüfsumme-erstellen). Für den Upload zusätzlich [9](#9-windows-paket-zu-einem-vorhandenen-release-hochladen). |
| Als Projektbetreuer eine ganz neue Versionsnummer veröffentlichen | [Abschnitt 10](#10-als-projektbetreuer-eine-neue-version-veröffentlichen). Dafür wird auch der Linux-Buildrechner benötigt. |

**Für den normalen Neubau ist kein Linux-Befehl nötig.** Ob du `master` oder
eine Release-Version baust, entscheidet sich in Schritt 3. Ab Schritt 4 ist
der Ablauf gleich.

Öffne im Windows-Startmenü **MSYS2 MINGW64**, als normaler Benutzer. Alle
Befehle aus Schritt 1 bis 9 gehören in dieses Fenster. PowerShell, die
Windows-Eingabeaufforderung, MSYS und UCRT64 sind hier nicht gemeint.

Kopiere immer einen vollständigen Befehlsblock einschließlich der Klammern.
Warte, bis er fertig ist, bevor du den nächsten ausführst. Bei einer
Fehlermeldung anhalten und das zugehörige Protokoll aufbewahren.
Die Klammern sorgen dafür, dass ein Fehler den Block abbricht, ohne dein
Terminal zu schließen.

Die Beispiele verwenden `$HOME/dinox`. `$HOME` wird von MINGW64 automatisch
durch deinen Benutzerordner ersetzt; du musst dort keinen Namen einsetzen.
Jeder Build-Block wechselt selbst in den richtigen Ordner. Wenn du DinoX
bewusst anderswo abgelegt hast, ersetze `$HOME/dinox` durch diesen Pfad.
Pfade mit Leerzeichen bleiben in Anführungszeichen.

## 1. MSYS2 einmalig einrichten

Voraussetzung ist Windows 10 ab Version 1903 oder Windows 11, jeweils 64 Bit
(Intel/AMD). Installiere [MSYS2](https://www.msys2.org/) nach `C:\msys64`.
Für Downloads und den Build werden Internet und genügend freier Speicherplatz
benötigt.

Auf einer **neuen Installation** in MSYS2 MINGW64 ausführen:

```bash
pacman -Syu
```

Falls MSYS2 zum Schließen des Fensters auffordert: schließen, MINGW64 erneut
öffnen und den Befehl wiederholen.

Wenn dieser Rechner DinoX schon erfolgreich baut, beginne für einen Neubau
bei Schritt 3. Auf der eingerichteten offiziellen Release-VM werden MSYS2 und
die Compiler nicht nebenbei aktualisiert; dafür gibt es eine separate Test-VM.

## 2. Benötigte Werkzeuge einmalig installieren

Dieser Schritt gehört zur erstmaligen Einrichtung. Das ist eine längere
Paketliste; kopiere den gesamten Block in MINGW64:

```bash
pacman -S --needed --noconfirm \
  git curl tar unzip base-devel \
  mingw-w64-x86_64-toolchain mingw-w64-x86_64-vala \
  mingw-w64-x86_64-meson mingw-w64-x86_64-ninja \
  mingw-w64-x86_64-pkgconf mingw-w64-x86_64-cmake \
  mingw-w64-x86_64-python mingw-w64-x86_64-gtk4 \
  mingw-w64-x86_64-python-dnspython mingw-w64-x86_64-python-cryptography \
  mingw-w64-x86_64-python-h2 \
  mingw-w64-x86_64-libadwaita mingw-w64-x86_64-glib2 \
  mingw-w64-x86_64-glib-networking mingw-w64-x86_64-gdk-pixbuf2 \
  mingw-w64-x86_64-libgee mingw-w64-x86_64-libsoup3 \
  mingw-w64-x86_64-json-glib mingw-w64-x86_64-sqlcipher \
  mingw-w64-x86_64-icu mingw-w64-x86_64-libgcrypt \
  mingw-w64-x86_64-gnupg mingw-w64-x86_64-gpgme \
  mingw-w64-x86_64-pinentry \
  mingw-w64-x86_64-gnutls mingw-w64-x86_64-qrencode \
  mingw-w64-x86_64-libsecret mingw-w64-x86_64-libyaml \
  mingw-w64-x86_64-libsrtp mingw-w64-x86_64-libnice \
  mingw-w64-x86_64-gstreamer mingw-w64-x86_64-gst-plugins-base \
  mingw-w64-x86_64-gst-plugins-good mingw-w64-x86_64-gst-plugins-bad \
  mingw-w64-x86_64-gst-plugins-ugly mingw-w64-x86_64-gst-libav \
  mingw-w64-x86_64-opus mingw-w64-x86_64-openh264 \
  mingw-w64-x86_64-libvpx mingw-w64-x86_64-protobuf-c \
  mingw-w64-x86_64-openssl mingw-w64-x86_64-libarchive mingw-w64-x86_64-librsvg \
  mingw-w64-x86_64-hicolor-icon-theme \
  mingw-w64-x86_64-adwaita-icon-theme \
  mingw-w64-x86_64-cantarell-fonts mingw-w64-x86_64-mosquitto \
  mingw-w64-x86_64-unbound \
  mingw-w64-x86_64-go
```

Die zusätzlich benötigten, genau festgelegten Versionen einzelner Bibliotheken
lädt das DinoX-Skript in Schritt 4.

## 3. DinoX-Quellcode holen und Version auswählen

Beende eine laufende DinoX-Testversion, bevor du neu baust.

Wenn der Quellcode noch nicht unter `$HOME/dinox` liegt, führe zuerst diesen
Block aus. Er lädt ihn herunter. Ist der Ordner schon vorhanden, prüft er ihn
nur und zeigt den Windows-Pfad:

```bash
(
  set -euo pipefail
  if [[ ! -e "$HOME/dinox" ]]; then
    git clone https://git.dinox.im/dinoxim/dinox.git "$HOME/dinox"
  fi
  cd "$HOME/dinox" || { echo 'FEHLER: Der DinoX-Quellordner fehlt. Zuerst Schritt 3 ausführen.' >&2; exit 1; }
  if [[ ! -e .git || ! -f scripts/build-windows-dist.sh ]]; then
    echo 'FEHLER: Dieser Ordner enthält keinen DinoX-Quellcode. Den Ordner prüfen.' >&2
    exit 1
  fi
  cygpath -w "$PWD"
)
```

Wähle anschließend **A oder B**, nicht beide. Für spätere Neubauten kannst du
direkt mit dem passenden Block beginnen.

### 3A. Den aktuellen master neu bauen

`master` ist der aktuelle Entwicklungsstand. Dieser Block holt neue Änderungen
und wechselt auf diesen Stand. Eigene Änderungen werden nicht gelöscht; in
diesem Fall hält der Block mit einer Erklärung an.

```bash
(
  set -euo pipefail
  cd "$HOME/dinox" || { echo 'FEHLER: Der DinoX-Quellordner fehlt. Zuerst Schritt 3 ausführen.' >&2; exit 1; }
  if [[ ! -e .git || ! -f scripts/build-windows-dist.sh ]]; then
    echo 'FEHLER: Dieser Ordner enthält keinen DinoX-Quellcode. Den Ordner prüfen.' >&2
    exit 1
  fi
  changes="$(git status --porcelain)"
  if [[ -n "$changes" ]]; then
    echo 'STOPP: Es gibt eigene Änderungen im Quellordner. Diese zuerst sichern oder committen.' >&2
    git status --short
    exit 1
  fi
  git config remote.origin.fetch '+refs/heads/*:refs/remotes/origin/*'
  git fetch --prune origin
  git switch master
  git branch --set-upstream-to=origin/master master
  git merge --ff-only origin/master
  if [[ "$(git rev-parse HEAD)" != "$(git rev-parse origin/master)" ]]; then
    echo 'STOPP: Der lokale master enthält zusätzliche Commits. Nichts wurde zurückgesetzt.' >&2
    exit 1
  fi
  echo 'Ausgewählter Quellstand:'
  git log -1 --format='%h %s'
)
```

Wenn am Ende „Ausgewählter Quellstand“ und eine Commit-Zeile erscheinen, geht
es mit Schritt 4 weiter. Ein Commit ist ein gespeicherter Stand des Quellcodes;
die kurze Kennung macht später erkennbar, welchen Stand du gebaut hast.

### 3B. Eine bestimmte Release-Version bauen

Ein Release-Tag wie `v2.3.3` bezeichnet den festgelegten Quellcode dieser
Version. Der Tag kann schon vorhanden sein, während Forgejo die Linux-Pakete
noch baut. Ein `git pull` wählt diesen Tag **nicht** automatisch aus.

Gib bei der Rückfrage die gewünschte Version mit `v` ein, zum Beispiel
`v2.3.3`, und drücke Enter:

```bash
(
  set -euo pipefail
  cd "$HOME/dinox" || { echo 'FEHLER: Der DinoX-Quellordner fehlt. Zuerst Schritt 3 ausführen.' >&2; exit 1; }
  if [[ ! -e .git || ! -f scripts/build-windows-dist.sh ]]; then
    echo 'FEHLER: Dieser Ordner enthält keinen DinoX-Quellcode. Den Ordner prüfen.' >&2
    exit 1
  fi
  changes="$(git status --porcelain)"
  if [[ -n "$changes" ]]; then
    echo 'STOPP: Es gibt eigene Änderungen im Quellordner. Diese zuerst sichern oder committen.' >&2
    git status --short
    exit 1
  fi
  read -r -p 'Welche Release-Version? Zum Beispiel v2.3.3: ' release_tag
  if [[ ! "$release_tag" =~ ^v[0-9]+\.[0-9]+\.[0-9]+(\.[0-9]+)?$ ]]; then
    echo 'FEHLER: Die Version mit v eingeben, zum Beispiel v2.3.3.' >&2
    exit 1
  fi
  git fetch origin "refs/tags/$release_tag:refs/tags/$release_tag"
  git switch --detach "refs/tags/$release_tag"
  version="$(tr -d '[:space:]' < VERSION)"
  if [[ "v$version" != "$release_tag" ]]; then
    echo 'FEHLER: Versionsdatei und Release-Tag passen nicht zusammen.' >&2
    exit 1
  fi
  echo 'Ausgewählter Quellstand:'
  git log -1 --format='%h %s'
)
```

Die Git-Meldung „detached HEAD“ ist hier normal: Der Quellcode bleibt auf der
gewählten Version. Danach folgen Schritte 4 bis 8 und gegebenenfalls 9.
**Abschnitt 10 ist für diesen Fall nicht nötig.**

Für ältere Releases können andere Abhängigkeiten erforderlich sein. Die
technischen Angaben dazu stehen in der `WINDOWS_BUILD.md` des gewählten Tags.
Der hier beschriebene Ablauf passt zu 2.3.3 und zum aktuellen Entwicklungsstand.

## 4. Abhängigkeiten vorbereiten

Führe diesen Schritt nach der Auswahl oder Aktualisierung des Quellcodes aus.
Das Skript lädt die von diesem Stand benötigten Dateien, prüft sie und
verwendet bereits passende Downloads wieder.

```bash
(
  set -euo pipefail
  cd "$HOME/dinox" || { echo 'FEHLER: Der DinoX-Quellordner fehlt. Zuerst Schritt 3 ausführen.' >&2; exit 1; }
  if [[ ! -e .git || ! -f scripts/build-windows-dist.sh ]]; then
    echo 'FEHLER: Dieser Ordner enthält keinen DinoX-Quellcode. Den Ordner prüfen.' >&2
    exit 1
  fi
  mkdir -p "$HOME/dinox-build-logs"
  log_file="$(mktemp "$HOME/dinox-build-logs/prepare-$(date +%Y%m%d-%H%M%S)-XXXXXX.log")"
  printf 'Protokolldatei: %s\n' "$log_file"
  CMAKE_BUILD_PARALLEL_LEVEL=2 GOMAXPROCS=2 \
    bash scripts/prepare-windows-build-deps.sh 2>&1 | tee "$log_file"
)
```

Warte auf die Rückkehr zur Eingabeaufforderung. Bei einem Fehler nicht mit
Schritt 5 weitermachen. Die Ausgabe steht zusätzlich in der angezeigten
`prepare-…log` unter `$HOME/dinox-build-logs`.
Die heruntergeladenen Bibliotheken liegen unter `$HOME/vendor-deps`.

## 5. DinoX vollständig neu bauen

DinoX muss beendet sein. Das Skript löscht selbst die alten Ordner `build`
und `dist`, kompiliert neu, führt die automatischen Tests aus und erstellt
den vollständigen Programmordner. Du musst vorher nichts von Hand löschen.

```bash
(
  set -euo pipefail
  cd "$HOME/dinox" || { echo 'FEHLER: Der DinoX-Quellordner fehlt. Zuerst Schritt 3 ausführen.' >&2; exit 1; }
  if [[ ! -e .git || ! -f scripts/build-windows-dist.sh ]]; then
    echo 'FEHLER: Dieser Ordner enthält keinen DinoX-Quellcode. Den Ordner prüfen.' >&2
    exit 1
  fi
  DINOX_BUILD_JOBS=2 bash scripts/build-windows-dist.sh
)
```

Der Build benutzt zwei parallele Compiler-Aufgaben, damit der Speicherbedarf
begrenzt bleibt. Er kann längere Zeit dauern. Solange er läuft, im selben
Quellordner keine weiteren Builds starten, nichts aktualisieren und die
gewählte Version nicht wechseln.

Die Ausgabe bleibt im Terminal sichtbar und wird zusätzlich vollständig
protokolliert. Am Anfang und am Ende steht `BUILD_LOG=…` mit dem Dateipfad.
Erfolgreich beendet ist der Build erst mit **`WINDOWS_BUILD_EXIT_CODE=0`**.
Bei einem anderen Wert zuerst den Fehler im Protokoll klären.

Das Build-Profil heißt standardmäßig `release`. Das bedeutet, dass der Code
für die Nutzung optimiert wird. Dadurch wird weder eine neue Versionsnummer
vergeben noch etwas auf Forgejo hochgeladen.

## 6. Programm und Protokolle finden

Öffne den fertigen Programmordner im Windows Explorer:

```bash
explorer.exe "$(cygpath -w "$HOME/dinox/dist")"
```

Dort liegt `dinox.exe`. **Der gesamte Ordner gehört zum Programm**, nicht nur
die EXE-Datei. Für die Nutzung dieses fertigen Ordners ist kein MSYS2 nötig.

Die Protokolle findest du so:

```bash
explorer.exe "$(cygpath -w "$HOME/dinox-build-logs")"
```

- `prepare-…log`: Vorbereitung und Downloads aus Schritt 4.
- `compile-…log`: vollständiger Build mit Tests aus Schritt 5.
- `compile-….warnings.txt`: Compilerwarnungen aus diesem gesamten Build.
- `package-…log`: ZIP-Erstellung aus Schritt 8.

Wenn du `DINOX_WINDOWS_LOG_DIR` selbst gesetzt hast, liegt das Build-Protokoll
stattdessen in diesem Ordner. Maßgeblich ist immer die Ausgabe `BUILD_LOG=…`.
Die Logs bleiben beim nächsten Neubau erhalten. `build_log.txt` im Quellordner
enthält nur einen Teil des Builds und ersetzt die vollständige `compile-…log`
nicht.

Am Ende nennt `WINDOWS_COMPILER_WARNING_COUNT=…` die Zahl der Compilerwarnungen
aus allen Build-Schritten. `BUILD_WARNINGS=…` zeigt auf die separate Warnungsliste.
Diese Zusammenfassung erscheint auch bei einem Buildfehler. Eine Meldung
„Warnings in this invocation: 0“ weiter oben gilt nur für diesen einzelnen
Build-Schritt und sagt nichts über die vorherigen Schritte aus.

## 7. DinoX unter Windows testen

Starte `dinox.exe` durch Doppelklick im Explorer. So prüfst du das fertige
Paket, ohne dass MINGW64 fehlende Dateien aus seiner Installation bereitstellt.

Prüfe vor der Weitergabe:

1. DinoX startet ohne Meldung über fehlende DLLs; Fenster, Texte, Symbole und Emoji sind sichtbar.
2. Ein Konto verbindet sich und Chats lassen sich öffnen.
3. Einstellungen, Mikrofon, Lautsprecher und Kamera lassen sich benutzen. Teste auch einen Anruf sowie Sprach- und Videonachrichten.
4. Das Symbol im Infobereich neben der Uhr öffnet und verbirgt DinoX. Benachrichtigungen führen zum passenden Chat, und ausgeschaltete Benachrichtigungstöne bleiben aus.
5. Menüs und Symbole sind im hellen, dunklen und Hochkontrast-Design sowie bei deiner Bildschirm-Skalierung lesbar.
6. DinoX lässt sich vollständig beenden.

Für eine Veröffentlichung auch die seit dem letzten Release geänderten
Funktionen prüfen. Ein zusätzlicher Start des gesamten `dist`-Ordners auf einem
Windows-Rechner ohne MSYS2 prüft, ob wirklich alle benötigten Dateien beiliegen.
Bewahre das Build-Protokoll und eine kurze Notiz zu deinen Tests auf.

Wenn du DinoX nur selbst verwenden willst, bist du hier fertig. Für eine
weitergebbare ZIP folgt Schritt 8.

## 8. ZIP und Prüfsumme erstellen

Beende DinoX nach dem Test. Zwischen Bauen und Packen weder `git pull`
ausführen noch den Quellstand wechseln. Das ZIP-Skript packt den **bereits
gebauten und getesteten** Ordner; es kompiliert nichts neu.

```bash
(
  set -euo pipefail
  cd "$HOME/dinox" || { echo 'FEHLER: Der DinoX-Quellordner fehlt. Zuerst Schritt 3 ausführen.' >&2; exit 1; }
  if [[ ! -e .git || ! -f scripts/build-windows-dist.sh ]]; then
    echo 'FEHLER: Dieser Ordner enthält keinen DinoX-Quellcode. Den Ordner prüfen.' >&2
    exit 1
  fi
  changes="$(git status --porcelain)"
  if [[ -n "$changes" ]]; then
    echo 'STOPP: Es gibt eigene Änderungen im Quellordner. Diese zuerst sichern oder committen.' >&2
    git status --short
    exit 1
  fi
  version="$(tr -d '[:space:]' < VERSION)"
  source_commit="$(git rev-parse HEAD)"
  output_dir="$HOME/dinox-packages/$version/$source_commit"
  mkdir -p "$HOME/dinox-build-logs"
  log_file="$(mktemp "$HOME/dinox-build-logs/package-$(date +%Y%m%d-%H%M%S)-XXXXXX.log")"
  printf 'Protokolldatei: %s\n' "$log_file"
  bash scripts/package-windows-dist.sh "$PWD/dist" "$output_dir" \
    2>&1 | tee "$log_file"
  cp dist/build-info.txt "$output_dir/build-info.txt"
  cd "$output_dir"
  sha256sum -c "DinoX-$version-windows-x86_64.zip.sha256"
  cygpath -w "$output_dir"
  explorer.exe "$(cygpath -w "$output_dir")"
)
```

Das Skript prüft das Programm und den Inhalt der ZIP nochmals. Bei Erfolg
erscheinen `WINDOWS_ZIP_READY=…`, `WINDOWS_ZIP_SHA256_READY=…` und eine
Prüfsummenmeldung mit `OK`. Anschließend öffnet sich der Ausgabeordner.

Für 2.3.3 liegen dort diese beiden Dateien:

```text
DinoX-2.3.3-windows-x86_64.zip
DinoX-2.3.3-windows-x86_64.zip.sha256
```

Die Versionsnummer kommt automatisch aus dem Quellcode. Der Ordner liegt unter
`$HOME/dinox-packages`, getrennt nach Version und Commit-Kennung. So werden
Pakete aus verschiedenen Quellständen nicht verwechselt. `build-info.txt`
hält zusätzlich fest, woraus das Paket gebaut wurde.

Das Skript verlangt einen unveränderten Quellordner und ein dazu passendes
Programm. Bei einem Fehler gibt es kein gültiges neues ZIP. Gleichnamige alte
ZIP- und Prüfsummendateien werden vor der Prüfung entfernt. Das ZIP darf
höchstens 512 MiB groß sein. Die Dateien anschließend nicht umbenennen oder
mit einem anderen Programm neu packen.

## 9. Windows-Paket zu einem vorhandenen Release hochladen

Dieser Abschnitt gilt, wenn der Release-Tag bereits feststeht, zum Beispiel
`v2.3.3`. Du brauchst dafür Schreibrechte am Forgejo-Projekt. Für einen eigenen
`master`-Testbuild ist dieser Schritt nicht erforderlich.

Prüfe in MINGW64 zuerst, ob das Paket wirklich aus diesem Release stammt:

```bash
(
  set -euo pipefail
  cd "$HOME/dinox" || { echo 'FEHLER: Der DinoX-Quellordner fehlt. Zuerst Schritt 3 ausführen.' >&2; exit 1; }
  if [[ ! -e .git || ! -f scripts/build-windows-dist.sh ]]; then
    echo 'FEHLER: Dieser Ordner enthält keinen DinoX-Quellcode. Den Ordner prüfen.' >&2
    exit 1
  fi
  changes="$(git status --porcelain)"
  if [[ -n "$changes" ]]; then
    echo 'STOPP: Es gibt eigene Änderungen im Quellordner. Diese zuerst sichern oder committen.' >&2
    git status --short
    exit 1
  fi
  release_tag="v$(tr -d '[:space:]' < VERSION)"
  git fetch origin "refs/tags/$release_tag:refs/tags/$release_tag"
  source_commit="$(sed -n 's/^source_commit=//p' dist/build-info.txt)"
  if [[ "$(git rev-parse "refs/tags/$release_tag^{commit}")" != "$source_commit" ]]; then
    echo 'STOPP: Dieses Windows-Paket wurde nicht aus dem gewählten Release-Tag gebaut.' >&2
    exit 1
  fi
  echo 'Windows-Paket und Release-Tag stimmen überein.'
  printf '%s: %s\n' "$release_tag" "$source_commit"
)
```

Bei „Windows-Paket und Release-Tag stimmen überein“ kannst du fortfahren:

1. Warte, bis der Linux-Bau auf Forgejo fertig und das Release veröffentlicht ist.
2. Öffne [DinoX Releases](https://git.dinox.im/dinoxim/dinox/releases) im Browser und melde dich an.
3. Öffne die passende Version und deren Bearbeitung.
4. Füge die ZIP und die zugehörige `.sha256`-Datei aus Schritt 8 als Anhänge hinzu und speichere.
5. Lade beide Dateien von der Release-Seite in einen neuen, leeren Ordner herunter.

Öffne für die abschließende Prüfung wieder MINGW64. Der folgende Block fragt
nach dem Windows-Ordner der heruntergeladenen Dateien. Den Pfad ohne äußere
Anführungszeichen eingeben; Leerzeichen sind erlaubt:

```bash
(
  set -euo pipefail
  read -r -p 'Windows-Ordner mit ZIP und Prüfsumme: ' download_dir
  cd "$(cygpath -u "$download_dir")"
  read -r -p 'Versionsnummer ohne v, zum Beispiel 2.3.3: ' version
  sha256sum -c "DinoX-$version-windows-x86_64.zip.sha256"
)
```

Bei `OK` ist der Upload geprüft. Ein Fehler bedeutet, dass die Dateien nicht
zusammenpassen oder unvollständig sind.

Der Linux-Bau startet bereits durch den Release-Tag; für den Windows-Upload
ist kein weiterer Forgejo-Baulauf nötig. Einen noch laufenden Release-Entwurf
nicht vorzeitig veröffentlichen. Das Skript `forgejo-release.sh upload` ist
für Entwürfe vorgesehen; nach der Veröffentlichung erfolgt das Ergänzen der
Windows-Dateien deshalb über die Bearbeitung im Browser.

Für deinen nächsten `master`-Neubau beginne wieder bei Schritt 3A. Der Block
wechselt selbst vom gewählten Release zurück auf `master`.

<a id="9-ein-neues-offizielles-release-veröffentlichen"></a>

## 10. Als Projektbetreuer eine neue Version veröffentlichen

Dieser Abschnitt ist nur nötig, wenn die Versionsnummer noch **nicht** als
Release-Tag vorhanden ist. Für ein Windows-Paket zu `v2.3.3` genügt 3B bis 9.

Hier wechseln sich zwei Rechner ab. A und C laufen auf dem eingerichteten
**Linux-Buildrechner mit Push-Rechten**. B läuft auf **Windows in MINGW64**.
Die Windows-Release-VM behält ihre getesteten Werkzeuge; dort ist kein erneutes
MSYS2-Update nötig.

### A. Linux: Neue Version vorbereiten

Alle vorgesehenen Änderungen und die Release-Notizen müssen bereits committet
und gepusht sein. Benötigt wird der eingerichtete
[Linux-Buildrechner](BUILD.md#linux-source-build). Der Block fragt zuerst nach
dem Quellordner auf diesem Rechner und wechselt dorthin. Den Pfad ohne äußere
Anführungszeichen eingeben, auch wenn er Leerzeichen enthält.

```bash
(
  set -euo pipefail
  read -r -p 'Vollständiger Pfad zum DinoX-Quellordner auf Linux: ' repo
  cd "$repo" || { echo "FEHLER: Der angegebene Ordner existiert nicht." >&2; exit 1; }
  if [[ ! -e .git || ! -f scripts/release.sh ]]; then
    echo "FEHLER: Das ist kein DinoX-Quellordner mit Git-Verwaltung." >&2
    exit 1
  fi
  trap 'echo "STOP: Der Schritt ist fehlgeschlagen. Nicht fortfahren." >&2' ERR
  test "$(git branch --show-current)" = master || { echo "STOPP: Zuerst den Entwicklungszweig master auswählen." >&2; exit 1; }
  changes="$(git status --porcelain)"
  test -z "$changes" || { echo "STOPP: Lokale Änderungen zuerst sichern oder committen." >&2; git status --short; exit 1; }
  git fetch origin '+refs/heads/master:refs/remotes/origin/master'
  test "$(git rev-parse HEAD)" = "$(git rev-parse origin/master)" || { echo "STOPP: Der lokale Stand und origin/master unterscheiden sich. Zuerst abgleichen." >&2; exit 1; }
  git fetch origin --tags
  bash scripts/prepare-linux-source-build-deps.sh
  vendor_root="$(cd "${DINOX_LINUX_VENDOR_ROOT:-$PWD/.vendor-deps}" && pwd -P)"
  export DINOX_LIBWEBRTC_RUNTIME_ROOT="$vendor_root/libwebrtc-m152-linux-x86_64-runtime"
  export DINOX_LOCAL_LIBOMEMO_C_ROOT="$vendor_root/linux-source-deps"
  read -r -p 'Neue Versionsnummer ohne v: ' release_version
  ./scripts/release.sh "$release_version" --prepare
  printf 'RELEASE_VERSION=%s\nRELEASE_COMMIT=%s\n' \
    "$release_version" "$(git rev-parse HEAD)"
)
```

Das Skript trägt die Version in die Projektdateien ein, baut und prüft DinoX
und erstellt einen Commit. Bestätige dessen Push mit `y`, wenn die Prüfungen
erfolgreich waren. Am Ende stehen `RELEASE_VERSION` und `RELEASE_COMMIT`.
Notiere beide Werte. Die 40-stellige Commit-Kennung bezeichnet den Quellstand,
aus dem Windows und Linux gebaut werden müssen.

Bis Schritt C keine weiteren Änderungen auf `master` einfügen. Hier wurde
noch kein Release-Tag veröffentlicht und kein Forgejo-Paketbau gestartet.

### B. Windows: Vorbereiteten Stand bauen und prüfen

DinoX beenden und MINGW64 als normaler Benutzer öffnen. Dieser Block ersetzt
für diesen Sonderfall Schritt 3A/3B. Bei der Rückfrage die vollständige
Commit-Kennung aus A einfügen:

```bash
(
  set -euo pipefail
  cd "$HOME/dinox" || { echo 'FEHLER: Der DinoX-Quellordner fehlt. Zuerst Schritt 3 ausführen.' >&2; exit 1; }
  if [[ ! -e .git || ! -f scripts/build-windows-dist.sh ]]; then
    echo 'FEHLER: Dieser Ordner enthält keinen DinoX-Quellcode. Den Ordner prüfen.' >&2
    exit 1
  fi
  changes="$(git status --porcelain)"
  if [[ -n "$changes" ]]; then
    echo 'STOPP: Es gibt eigene Änderungen im Quellordner. Diese zuerst sichern oder committen.' >&2
    git status --short
    exit 1
  fi
  repo="$PWD"
  read -r -p 'Commit-Kennung aus A (40 Zeichen): ' release_commit
  [[ "$release_commit" =~ ^[0-9a-f]{40}$ ]] || { echo "FEHLER: Die vollständige Commit-Kennung muss 40 Zeichen haben." >&2; exit 1; }
  git -C "$repo" fetch origin '+refs/heads/master:refs/remotes/origin/master'
  test "$release_commit" = "$(git -C "$repo" rev-parse origin/master)" || { echo "STOPP: master wurde seit der Release-Vorbereitung geändert. Den Quellstand zuerst klären." >&2; exit 1; }
  git -C "$repo" switch --detach "$release_commit"
  test "$(git -C "$repo" rev-parse HEAD)" = "$release_commit"
  echo 'Ausgewählter Quellstand:'
  git -C "$repo" log -1 --format='%H %s'
)
```

Jetzt **Schritt 4 bis 8 dieser Anleitung** ausführen: Abhängigkeiten vorbereiten,
sauber bauen, Protokoll prüfen, DinoX testen und ZIP erstellen. Die Meldung
„detached HEAD“ ist normal. Notiere die Tests und bewahre die Logs auf.

In der erzeugten `build-info.txt` muss `source_commit` zur Kennung aus A passen
und `source_dirty=false` stehen. Ein früherer Build vor der Versionsänderung
reicht nicht. Bei nötigen Codekorrekturen diese auf Linux erneut prüfen und
pushen, dann B mit der neuen Kennung wiederholen.

### C. Linux: Geprüfte Version freigeben

Erst nach den erfolgreichen Windows-Tests zurück auf den Linux-Buildrechner.
Der folgende Block fragt erneut nach dem Quellordner und der unter Windows
geprüften Commit-Kennung:

```bash
(
  set -euo pipefail
  read -r -p 'Vollständiger Pfad zum DinoX-Quellordner auf Linux: ' repo
  cd "$repo" || { echo "FEHLER: Der angegebene Ordner existiert nicht." >&2; exit 1; }
  if [[ ! -e .git || ! -f scripts/release.sh ]]; then
    echo "FEHLER: Das ist kein DinoX-Quellordner mit Git-Verwaltung." >&2
    exit 1
  fi
  trap 'echo "STOP: Der Schritt ist fehlgeschlagen. Nicht fortfahren." >&2' ERR
  test "$(git branch --show-current)" = master || { echo "STOPP: Zuerst den Entwicklungszweig master auswählen." >&2; exit 1; }
  changes="$(git status --porcelain)"
  test -z "$changes" || { echo "STOPP: Lokale Änderungen zuerst sichern oder committen." >&2; git status --short; exit 1; }
  read -r -p 'Unter Windows geprüfte Commit-Kennung (40 Zeichen): ' release_commit
  [[ "$release_commit" =~ ^[0-9a-f]{40}$ ]] || { echo "FEHLER: Die Commit-Kennung muss 40 Zeichen haben." >&2; exit 1; }
  test "$(git rev-parse HEAD)" = "$release_commit" || { echo "STOPP: Der Quellstand entspricht nicht dem Windows-Build." >&2; exit 1; }
  release_version="$(tr -d '[:space:]' < VERSION)"
  ./scripts/release.sh "$release_version" --finalize
)
```

Das Skript prüft den Stand und legt den Release-Tag an. Bestätige den Push mit
`y`, um den Forgejo-Bau für DEB, AppImage und Flatpak zu starten. Der Tag zeigt
auf denselben Commit wie das fertige Windows-Paket; deswegen ist allein für
diesen Schritt kein neuer Windows-Build nötig.

Der Forgejo-Lauf veröffentlicht das Release nach erfolgreichen Linux-Prüfungen.
Keinen zweiten manuellen Paketbau starten. Bei einem Fehler den betroffenen
Lauf prüfen und dessen fehlgeschlagene Jobs erneut ausführen. Danach folgt
**Schritt 9** für das Windows-ZIP und seine Prüfsumme.

Historische Sonderfälle bei abgebrochenen Releases stehen in
[RELEASE_READINESS.md](RELEASE_READINESS.md#package-build-order).

## Wenn etwas fehlschlägt

- **`fatal: not a git repository`**: Der Git-Befehl lief außerhalb des Quellordners, oder dieser enthält keine Git-Kopie. In MINGW64 mit Schritt 3 beginnen. Die vollständigen Blöcke wechseln selbst in den richtigen Ordner.
- **Eigene Änderungen im Quellordner**: Der Ablauf hält an, damit nichts verloren geht. Änderungen zuerst separat sichern oder committen; nicht mit einem erzwungenen Reset beseitigen.
- **„Zugriff verweigert“ beim Aufräumen**: DinoX vollständig beenden. Wurden `build` und `dist` früher als Administrator erzeugt, diese beiden generierten Ordner einmalig mit passenden Rechten entfernen oder deren Rechte reparieren. Danach MINGW64 normal öffnen. Nicht den Quellordner oder das Benutzerprofil löschen.
- **Administrator-Build abgelehnt**: MINGW64 schließen und ohne „Als Administrator ausführen“ neu öffnen. Das Build-Skript prüft dies vor dem Löschen der alten Build-Dateien.
- **Vorbereitung oder DLL-Prüfung fehlgeschlagen**: Das vollständige Log prüfen. Bei fehlenden Abhängigkeiten Schritt 4 wiederholen. Keine DLLs auf Verdacht ins Paket kopieren.
- **ZIP passt nicht zum Quellstand**: Nach dem Build wurde der Quellcode gewechselt oder aktualisiert. Den gewünschten Stand erneut vollständig bauen und testen, dann packen.

Für Fehlerberichte die ganze `compile-…log` aufbewahren. Vor einem Release
auch neue, ungeklärte Warnungen prüfen. Eine spätere Zeile „0 Warnungen“ in
einem kurzen Nachlauf sagt nichts über die vorherige vollständige Kompilierung
aus. Bereits untersuchte Warnungen stehen in
[WINDOWS_WARNING_TODO.md](WINDOWS_WARNING_TODO.md).

## Technische Hintergründe

[Windows-Build: technische Details](WINDOWS_BUILD_DETAILS.md) beschreibt die
Bibliotheksversionen, Unicode-Pfade, automatische Paketprüfungen, Lizenzen,
GnuPG, Tray-Anzeige und den separaten Neubau der WebRTC-Laufzeit.
Diese Informationen sind für Entwicklung und Fehleranalyse gedacht.

Gezielte Anrufdiagnose, nach einem erfolgreichen Build in MINGW64:

```bash
DINOX_GOOGLE_WEBRTC_CALL_DEBUG=1 "$HOME/dinox/dist/dinox.exe" \
  > "$HOME/dinox-build-logs/webrtc-debug.log" 2>&1
```

Weitere Hinweise stehen in [DEBUG.md](DEBUG.md).
