using Gee;

using Xmpp;
using Dino.Entities;

namespace Dino {

/** One immutable, server-authoritative XEP-0490 publication candidate. */
internal class DisplayedStatePublication : Object {
    public Jid chat { get; private set; }
    public StableStanzaReference reference { get; private set; }
    public int64 local_time { get; private set; }
    public int message_id { get; private set; }

    public DisplayedStatePublication(Jid chat,
            StableStanzaReference reference, Entities.Message message) {
        this.chat = chat;
        this.reference = reference;
        this.local_time = message.local_time != null
            ? ((!) message.local_time).to_unix() : 0;
        this.message_id = message.id;
    }

    public bool is_at_least_as_new_as(DisplayedStatePublication other) {
        if (local_time != other.local_time) {
            return local_time > other.local_time;
        }
        return message_id >= other.message_id;
    }
}

/** Latest-wins queue keyed by the XEP-0490 PEP item id. */
internal class DisplayedStatePublicationQueue : Object {
    private HashMap<string, DisplayedStatePublication> pending =
        new HashMap<string, DisplayedStatePublication>();

    public int size { get { return pending.size; } }

    public void offer(DisplayedStatePublication candidate) {
        string item_id = candidate.chat.to_string();
        DisplayedStatePublication? current = pending[item_id];
        if (current == null ||
                candidate.is_at_least_as_new_as((!) current)) {
            pending[item_id] = candidate;
        }
    }

    public DisplayedStatePublication? take_next() {
        MapIterator<string, DisplayedStatePublication> iterator =
            pending.map_iterator();
        if (!iterator.next()) return null;

        DisplayedStatePublication publication = iterator.get_value();
        iterator.unset();
        return publication;
    }

    public void clear() {
        pending.clear();
    }
}

/**
 * Owns all XEP-0333/XEP-0490 protocol bindings and asynchronous XEP-0490
 * operations for one account. It never creates per-conversation workers.
 */
internal class DisplayedStateSyncOwner : Object {
    public signal void contact_marker_received(Account account, Jid sender,
        string message_id, MessageStanza stanza);
    public signal void device_item_received(Account account,
        Xep.MessageDisplayedSynchronization.DisplayedItem item);
    public signal void catchup_ready(Account account,
        Gee.List<Xep.MessageDisplayedSynchronization.DisplayedItem> items);

    private StreamInteractor stream_interactor;
    private Account account;
    private Xep.ChatMarkers.Module chat_markers;
    private Xep.MessageDisplayedSynchronization.Module device_sync;
    private Presence.Module presence;
    private ulong chat_marker_handler_id;
    private ulong device_item_handler_id;
    private ulong initial_presence_handler_id;

    private XmppStream? active_stream;
    private XmppStream? initial_presence_stream;
    private uint generation = 0;
    private bool stream_ready = false;
    private bool fresh_stream = false;
    private bool history_settled = false;
    private bool catchup_started = false;
    private bool catchup_finished = false;
    private bool catchup_emitted = false;
    private Gee.List<Xep.MessageDisplayedSynchronization.DisplayedItem>
        catchup_items = new ArrayList<
            Xep.MessageDisplayedSynchronization.DisplayedItem>();
    private Cancellable? catchup_cancellable;

    private DisplayedStatePublicationQueue publications =
        new DisplayedStatePublicationQueue();
    private DisplayedStatePublication? in_flight_publication;
    private Cancellable? publication_cancellable;
    private bool publication_blocked_for_stream = false;
    private bool device_sync_enabled = true;
    private bool server_assist_discovery_started = false;
    private bool server_assist_supported = false;

    public DisplayedStateSyncOwner(StreamInteractor stream_interactor,
            Account account) {
        this.stream_interactor = stream_interactor;
        this.account = account;
        chat_markers = stream_interactor.module_manager.get_module<
            Xep.ChatMarkers.Module>(account, Xep.ChatMarkers.Module.IDENTITY);
        device_sync = stream_interactor.module_manager.get_module<
            Xep.MessageDisplayedSynchronization.Module>(account,
                Xep.MessageDisplayedSynchronization.Module.IDENTITY);
        presence = stream_interactor.module_manager.get_module<Presence.Module>(
            account, Presence.Module.IDENTITY);

        chat_marker_handler_id = chat_markers.displayed_received.connect(
                (stream, sender, message_id, stanza) => {
            if (is_current_stream(stream)) {
                contact_marker_received(account, sender, message_id, stanza);
            }
        });
        device_item_handler_id = device_sync.displayed_received.connect(
                (stream, item) => {
            if (device_sync_enabled && is_current_stream(stream)) {
                device_item_received(account, item);
            }
        });
        initial_presence_handler_id = presence.initial_presence_sent.connect(
                (stream, stanza) => {
            note_initial_presence(stream);
        });
    }

    /** Fence the previous transport as soon as a replacement is attached. */
    public void prepare_stream(XmppStream stream) {
        if (active_stream == stream) return;

        if (in_flight_publication != null) {
            publications.offer((!) in_flight_publication);
        }

        generation++;
        cancel_in_flight_operations();
        active_stream = stream;
        initial_presence_stream = null;
        stream_ready = false;
        fresh_stream = false;
        history_settled = false;
        reset_catchup_state();
        publication_blocked_for_stream = false;
        reset_server_assist_state();
    }

    public void begin_fresh_stream(XmppStream stream) {
        if (active_stream != stream) prepare_stream(stream);
        stream_ready = true;
        fresh_stream = true;
        start_server_assist_discovery();
        maybe_start_catchup();
        start_next_publication();
    }

    public void begin_resumed_stream(XmppStream stream) {
        if (active_stream != stream) prepare_stream(stream);
        stream_ready = true;
        fresh_stream = false;
        start_server_assist_discovery();
        start_next_publication();
    }

    public void mark_history_settled(XmppStream stream) {
        if (!is_current_stream(stream)) return;
        history_settled = true;
        if (fresh_stream) maybe_emit_catchup();
    }

    public void set_device_sync_enabled(bool enabled) {
        if (device_sync_enabled == enabled) return;

        device_sync_enabled = enabled;
        generation++;
        cancel_in_flight_operations();
        reset_catchup_state();
        publication_blocked_for_stream = false;
        publications.clear();
        reset_server_assist_state();

        if (enabled) {
            start_server_assist_discovery();
            maybe_start_catchup();
            start_next_publication();
        }
    }

    public void queue_publication(Jid chat,
            StableStanzaReference reference, Entities.Message message) {
        if (!device_sync_enabled) return;
        publications.offer(new DisplayedStatePublication(chat, reference,
            message));
        start_next_publication();
    }

    public bool can_use_server_assist(XmppStream stream) {
        return device_sync_enabled && server_assist_supported &&
            is_current_stream(stream);
    }

    private void start_server_assist_discovery() {
        if (!device_sync_enabled || !stream_ready ||
                server_assist_discovery_started || active_stream == null ||
                !is_current_stream((!) active_stream)) {
            return;
        }

        XmppStream stream = (!) active_stream;
        uint operation_generation = generation;
        server_assist_discovery_started = true;
        device_sync.supports_server_assist.begin(stream, (_, result) => {
            bool supported = device_sync.supports_server_assist.end(result);
            if (operation_generation != generation ||
                    !is_current_stream(stream)) {
                return;
            }
            server_assist_supported = supported;
        });
    }

    private void note_initial_presence(XmppStream stream) {
        if (active_stream != stream) return;
        initial_presence_stream = stream;
        maybe_start_catchup();
    }

    private void maybe_start_catchup() {
        if (!device_sync_enabled || !stream_ready || !fresh_stream ||
                catchup_started ||
                active_stream == null || initial_presence_stream !=
                    active_stream || !is_current_stream((!) active_stream)) {
            return;
        }

        XmppStream stream = (!) active_stream;
        uint operation_generation = generation;
        Cancellable cancellable = new Cancellable();
        catchup_cancellable = cancellable;
        catchup_started = true;
        device_sync.fetch_all.begin(stream, cancellable, (_, result) => {
            Xep.MessageDisplayedSynchronization.FetchResult fetch_result =
                device_sync.fetch_all.end(result);
            if (!operation_is_current(stream, operation_generation,
                    cancellable)) {
                return;
            }

            catchup_cancellable = null;
            catchup_finished = true;
            if (fetch_result.ok) catchup_items = fetch_result.items;
            maybe_emit_catchup();
        });
    }

    private void maybe_emit_catchup() {
        if (!history_settled || !catchup_finished || catchup_emitted) return;
        catchup_emitted = true;
        catchup_ready(account, catchup_items);
    }

    private void start_next_publication() {
        if (!device_sync_enabled || !stream_ready ||
                publication_blocked_for_stream ||
                in_flight_publication != null || active_stream == null ||
                !is_current_stream((!) active_stream)) {
            return;
        }

        DisplayedStatePublication? next = publications.take_next();
        if (next == null) return;

        XmppStream stream = (!) active_stream;
        uint operation_generation = generation;
        Cancellable cancellable = new Cancellable();
        DisplayedStatePublication publication = (!) next;
        in_flight_publication = publication;
        publication_cancellable = cancellable;
        device_sync.publish_displayed.begin(stream, publication.chat,
                publication.reference.id, publication.reference.by,
                cancellable, (_, result) => {
            Xep.MessageDisplayedSynchronization.PublishResult publish_result =
                device_sync.publish_displayed.end(result);
            if (!operation_is_current(stream, operation_generation,
                    cancellable) || in_flight_publication != publication) {
                return;
            }

            in_flight_publication = null;
            publication_cancellable = null;
            if (!publish_result.ok) {
                // Retain one latest item per chat for the next stream. This
                // avoids a retry loop while preserving offline local reads.
                publications.offer(publication);
                publication_blocked_for_stream = true;
                return;
            }
            start_next_publication();
        });
    }

    private bool is_current_stream(XmppStream stream) {
        return active_stream == stream &&
            stream_interactor.get_stream(account) == stream;
    }

    private bool operation_is_current(XmppStream stream,
            uint operation_generation, Cancellable cancellable) {
        return operation_generation == generation &&
            !cancellable.is_cancelled() && is_current_stream(stream);
    }

    private void cancel_in_flight_operations() {
        if (catchup_cancellable != null) {
            ((!) catchup_cancellable).cancel();
        }
        if (publication_cancellable != null) {
            ((!) publication_cancellable).cancel();
        }
        catchup_cancellable = null;
        publication_cancellable = null;
        in_flight_publication = null;
    }

    private void reset_catchup_state() {
        catchup_started = false;
        catchup_finished = false;
        catchup_emitted = false;
        catchup_items = new ArrayList<
            Xep.MessageDisplayedSynchronization.DisplayedItem>();
    }

    private void reset_server_assist_state() {
        server_assist_discovery_started = false;
        server_assist_supported = false;
    }

    public void shutdown() {
        generation++;
        cancel_in_flight_operations();
        publications.clear();
        active_stream = null;

        if (chat_marker_handler_id != 0 && SignalHandler.is_connected(
                chat_markers, chat_marker_handler_id)) {
            SignalHandler.disconnect(chat_markers, chat_marker_handler_id);
        }
        if (device_item_handler_id != 0 && SignalHandler.is_connected(
                device_sync, device_item_handler_id)) {
            SignalHandler.disconnect(device_sync, device_item_handler_id);
        }
        if (initial_presence_handler_id != 0 && SignalHandler.is_connected(
                presence, initial_presence_handler_id)) {
            SignalHandler.disconnect(presence, initial_presence_handler_id);
        }
        chat_marker_handler_id = 0;
        device_item_handler_id = 0;
        initial_presence_handler_id = 0;
    }
}

}
