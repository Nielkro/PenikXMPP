# Feeds in DinoX

## Deutsch

Öffne **Hauptmenü → Feeds**, drücke **Strg+Umschalt+F** oder wähle
**Chatmenü → Feed-Beitrag teilen…**.
Feeds und seine Unterdialoge öffnen sich innerhalb des DinoX-Hauptfensters und
passen sich dessen Breite an. Wähle oben das Konto. Das Konto bestimmt sowohl den Versand als auch den
Tor-/SOCKS5-Verbindungsweg für Web-Feeds. Es muss verbunden sein.

### Einen Beitrag im Chat teilen

1. Unter **Web-Feeds** die RSS- oder Atom-Adresse eingeben und **Beiträge laden**
   anklicken, beispielsweise `https://git.dinox.im/dinoxim/monocles-chat/releases.rss`.
2. Beim gewünschten Beitrag **Vorschau und Teilen…** öffnen.
3. Den Zielchat auswählen, Text und angezeigte Verschlüsselung prüfen und
   oben **Senden** anklicken.

Der Text lässt sich vor dem Versand bearbeiten. Titel, gekürzter Inhalt und
Beitragslink werden als normale Nachricht gesendet. Empfänger brauchen keine
Feed-Erweiterung. Unterstützt werden direkte Chats sowie beigetretene Gruppen,
in denen das Konto schreiben darf. Die bestehende OMEMO-/OpenPGP-Verarbeitung
bleibt zuständig; ein fehlender Schlüssel führt nicht zu unverschlüsseltem Versand.

### Neue Beiträge automatisch senden

Das **Prüfintervall (Minuten)** steht direkt unter **Automatisch in Chats senden**
auf der Seite **Web-Feeds**, auch bevor ein Feed geladen wurde. Nach dem Laden
**Neue Beiträge automatisch senden…** wählen, Zielchat und Prüfabstand mit
**Aktivieren** bestätigen. Vorhandene Beiträge werden dabei übersprungen.
Wählbar sind 5 bis 1440 Minuten (24 Stunden); Vorgabe sind 30 Minuten.
DinoX sendet höchstens fünf neue Beiträge pro Prüfung. Weitere warten auf
die nächste Prüfung. Bearbeitungen unter derselben Beitrags-ID werden nicht
erneut gesendet.

**DinoX muss geöffnet sein.** Bei ausgeschaltetem Rechner gibt es keine Prüfung.
Nach dem Neustart können nur Beiträge nachgeholt werden, die noch im Feed stehen.
Solange das Konto offline ist oder eine Gruppe verlassen hat beziehungsweise dort
nicht schreiben darf, erfolgt kein automatischer Versand. DinoX tritt dafür keiner Gruppe bei.
Normales Benachrichtigungs-Stummschalten verhindert den Versand nicht.

Unter **Abonnements** sind automatischer Chatversand und XMPP-Abos getrennt.
Beim Chatversand werden Zielchat, letzte Prüfung und das Intervall angezeigt.
Ein neues Intervall mit **Intervall speichern** übernehmen; der letzte Prüfzeitpunkt,
die bereits bekannten Beiträge und eine Pause bleiben erhalten.
Abos lassen sich dort lesen, pausieren, fortsetzen oder entfernen.
Ein Wechsel der Chatverschlüsselung pausiert das Abo. **Mit aktueller
Chatverschlüsselung fortsetzen** bestätigt die neuen Einstellungen ausdrücklich.
Bereits in den Chat eingereihte Nachrichten werden nicht doppelt angelegt.
Fehlgeschlagene Nachrichten bleiben dort sichtbar und können über den normalen
Chatablauf erneut gesendet werden. Das Entfernen eines Abos nimmt bereits
gesendete oder eingereihte Nachrichten nicht zurück.

### XMPP-Feeds lesen und veröffentlichen

Unter **XMPP-Feeds lesen** die XMPP-Adresse des Herausgebers ohne Ressourcenangabe eintragen. Für einen
persönlichen Feed bleibt der Knoten `urn:xmpp:microblog:0` unverändert. Für einen
allgemeinen PubSub-Feed dessen Dienstadresse und den Knotennamen unter
**Erweiterte Feed-Einstellungen** verwenden.
**XMPP-Feed lesen** lädt bis zu 100 aktuelle Beiträge; **Abonnieren** bestellt
Serverbenachrichtigungen. Je nach Server und Zugriffsschutz kann eine Zustimmung
oder eine bestehende Anwesenheitsfreigabe erforderlich sein. Entfernen eines
XMPP-Abos wird erst nach Serverbestätigung als erfolgreich behandelt.
Für XMPP-Abos gibt es kein Prüfintervall: Ein geöffneter abonnierter Feed reagiert
auf Änderungsmeldungen des Servers. Andere Feeds werden beim nächsten Laden
abgerufen. Beiträge werden dadurch nicht automatisch als Chatnachrichten versendet.

Unter **Mein XMPP-Feed → Beitrag in meinem Feed schreiben…** veröffentlicht man im persönlichen Feed des
oben gewählten Kontos. Ohne Häkchen bei **Öffentlicher Feed** ist der Zugriff für
Kontakte vorgesehen, denen du deinen Online-Status freigegeben hast. Mit
Häkchen ist er öffentlich. Unter **Kontaktfreigabe prüfen oder erteilen** erklärt
der Dialog die nötigen Schritte. Prüfen kannst du die Freigabe im Kontaktchat
unter **Unterhaltungsdetails → Info → Kontaktfreigaben**. Zum Erteilen nimmst du
die Anfrage des Kontakts nach deinem Online-Status an; beim Hinzufügen gibt es
auch **Meinen Online-Status ebenfalls freigeben**. Die Leseberechtigung gilt
auch, wenn du offline bist. Die gewählte Sichtbarkeit gilt für den gesamten Feed. Hat ein vorhandener
Feed eine andere Sichtbarkeit, lehnt DinoX den Vorgang ab, statt ältere Beiträge
unbemerkt öffentlich zu machen. Der Server muss die XEP-0472-Konfiguration
einschließlich dauerhafter Einträge und `max_items=max` unterstützen; ein Fehler
wird angezeigt und nicht als erfolgreiche Veröffentlichung ausgegeben.
Der erste veröffentlichte Beitrag legt den Feed an. Davor ist „Feed nicht gefunden“
ein erwarteter Zustand. Der Server speichert die Beiträge, sie bleiben also auch
bei geschlossenem DinoX lesbar. Leser benötigen die XMPP-Adresse des Herausgebers,
einen Client mit Feed-Unterstützung und passende Zugriffsrechte. DinoX zeigt derzeit
keine Liste der eigenen Abonnenten. Web-Feeds werden nicht automatisch in den eigenen
XMPP-Feed kopiert.

**In meinem Feed antworten…** veröffentlicht eine Antwort im eigenen Feed mit
einem Verweis auf den ursprünglichen XMPP-Beitrag. Das ist keine private
Chatantwort. Eigene Beiträge können nach Bestätigung entfernt werden.

**XMPP-Feed-Beiträge sind nicht Ende-zu-Ende-verschlüsselt.** Der Server kann sie
lesen; Kontaktzugriff ist eine serverseitige Zugriffsregel, kein OMEMO-Schutz.
Für vertrauliche Inhalte den Beitrag stattdessen in einem verschlüsselten Chat teilen.

## English

Open **Main menu → Feeds**, press **Ctrl+Shift+F**, or choose
**Chat menu → Share a feed article…** and select
the account. Feeds and its action dialogs stay within the main DinoX window and
adapt to its width; confirmation actions remain in the header. Its existing Tor/SOCKS5 route is used for web requests. It must be
connected; a missing proxy never triggers a direct retry.

- **Web feeds:** enter an RSS/Atom URL, load articles, open **Preview and share…**,
  select the destination, review/edit the text and send. These are ordinary
  messages using the destination chat's encryption; recipients need no feed support.
- **Automatically post new articles…:** select a fixed account/chat and an interval
  (5–1440 minutes, default 30). The interval is visible on the Web feeds page before
  loading. Existing articles are skipped. At most five new
  articles are queued per check. More wait until the next check. Changes to an
  existing article ID are not reposted. DinoX must remain running. Catch-up after
  downtime is limited to articles still present in the source feed.
- **Subscriptions:** web posting and XMPP subscriptions have separate sections.
  Web subscriptions show the destination, last check and an editable interval;
  **Save interval** preserves deduplication, last check and paused state.
  Read, pause, resume or remove subscriptions. Changing the
  destination's encryption pauses automatic posting until explicitly resumed.
  Offline accounts and rooms that have been left or cannot be written to are
  not used. Chat notification muting does not disable posting. Queue deduplication
  survives restart; delivery failures remain visible in the chat. Removing a
  subscription does not retract existing or queued messages.
- **Read XMPP feeds:** use a publisher's bare account/service JID and node. The
  node is under **Advanced feed settings**. Personal feeds normally
  use `urn:xmpp:microblog:0`. Read up to 100 recent entries and subscribe to server
  notifications; access or owner approval may be required. There is no polling
  interval: an open subscribed feed refreshes on server events; otherwise reload
  it when needed. This does not send posts to chats automatically.
- **My XMPP feed:** publishing the first post creates a feed on the selected
  account's server, if supported. The server stores posts for readers even when
  DinoX is closed. Share the account's XMPP address with readers who have a
  feed-capable client and access. DinoX does not list your subscribers, and does
  not copy web feeds into your own feed. Replies are posts in your own feed
  referencing the original XMPP item. Confirm before deleting your own post.

Native social posts are **not end-to-end encrypted**. Contacts-only visibility
means server-side access for contacts you have allowed to see your online status,
including while you are offline. **Check or grant contact access** in the composer
explains where to check this permission and how to approve a contact's request. Public
visibility allows anyone to read. Existing visibility is never changed by the
composer: choose its current policy or the operation fails. Servers must accept
the required XEP-0472 node configuration. No successful publication is claimed
without an acknowledgement. A retry retains the post ID to avoid duplicates when
an acknowledgement is lost.

## Implementation and limits

- RSS 1.0, RSS 2.0, Atom, `content:encoded`, XML character encodings, Unicode,
  conditional HTTP requests and bounded redirects are supported. Feed responses
  are limited to 2 MiB and web feeds to 200 entries per response. Article text is
  shortened for sharing and remains editable. HTML is converted to text; images,
  scripts, styles and other external resources are not loaded.
- Shortening preserves complete Unicode grapheme clusters, including combining
  accents, emoji modifiers/ZWJ sequences and flags. The decoder recognizes
  UTF-8, UTF-16LE/BE and UTF-32LE/BE BOMs and XML byte-order signatures, as well
  as declared legacy encodings such as Windows-1251. Malformed/truncated input
  and embedded NUL bytes are rejected; outgoing chat/social text must be valid
  UTF-8 before it enters the queue or publish operation.
- Subscriptions and deduplication keys are in the existing encrypted profile
  database. Account deletion removes its subscriptions. Conversation deletion
  removes automatic subscriptions targeting it. There is no separate plaintext cache.
- XEP-0472 base/microblog reading and text publishing use existing XEP-0060 IQ
  support. Payload-less events, item retractions and node deletion invalidate an
  open feed view. Reopening retrieves current entries. Replies use Atom threading
  and preserve the difference between Atom IDs and PubSub item IDs.
- Gallery publishing, a complete offline social timeline, JSON Feed, legacy
  XEP-0277 comment-node management and a server daemon are outside this feature.
- Linux and Windows use the same Vala/GLib/libsoup/GTK implementation. No new
  library, DLL, container image or package dependency is introduced. A new
  application build is required on each platform.

Specification: [XEP-0472, experimental version 0.2.1](https://xmpp.org/extensions/xep-0472.html).
Unicode boundaries use the existing Pango runtime's
[grapheme cursor positions](https://docs.gtk.org/Pango/struct.LogAttr.html).
The core declares its direct Pango dependency; this is already supplied by GTK
in the Linux and Windows packages and requires no additional runtime download.
Encoding detection follows the relevant byte signatures in
[XML 1.0 appendix F](https://www.w3.org/TR/xml/#sec-guessing).
An implementation and local protocol tests are not evidence of live interoperability
with a particular Monocles or Movim release. See [the implementation plan](FEEDS_IMPLEMENTATION_PLAN.md)
for the actual validation record.
