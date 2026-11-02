/*
 * Windows notification sound plugin — GStreamer backend.
 *
 * This is the Windows counterpart of plugin.vala (which uses libcanberra
 * on Linux).  The Linux file is NEVER compiled on Windows and vice-versa;
 * the meson.build picks the correct source file per platform.
 *
 * Sounds are bundled as GResource WAV files and played via GStreamer
 * playbin.  Each "channel" has its own playbin so multiple sounds can
 * overlap (e.g. message ding while a call is ringing).
 *
 * Copyright (C) 2026 Ralf Peter <dinox@handwerker.jetzt>
 */

using Dino.Entities;
using Gee;
using Xmpp;

namespace Dino.Plugins.NotificationSound {

public class Plugin : RootInterface, Object {

    public Dino.Application app;

    private const string SOUND_PREFIX = "resource:///im/dinox/dinox/sounds/";

    /* GStreamer playbin elements — one per channel for concurrent playback */
    private Gst.Element? playbin_message;
    private Gst.Element? playbin_ringtone;
    private Gst.Element? playbin_ringback;

    /* Incoming call ringtone state */
    private uint ringtone_timeout_id = 0;
    private Call? ringing_call = null;
    private ulong ringing_state_handler = 0;

    /* Outgoing call ringback state */
    private uint ringback_timeout_id = 0;
    private Call? ringback_call = null;
    private ulong ringback_state_handler = 0;

    public void registered(Dino.Application app) {
        this.app = app;

        app.stream_interactor.get_module<NotificationEvents>(NotificationEvents.IDENTITY).notify_content_item.connect(on_notify_content_item);
        app.stream_interactor.get_module<Calls>(Calls.IDENTITY).call_incoming.connect(on_call_incoming);
        app.stream_interactor.get_module<Calls>(Calls.IDENTITY).call_outgoing.connect(on_call_outgoing);
        app.stream_interactor.get_module<Calls>(Calls.IDENTITY).call_terminated.connect(on_call_terminated);
    }

    /* ── GStreamer helpers ──────────────────────────────────────────── */

    private void gst_play(ref Gst.Element? pb, string sound_file) {
        gst_stop(ref pb);
        pb = Gst.ElementFactory.make("playbin", null);
        if (pb == null) {
            warning("NotificationSound: failed to create GStreamer playbin");
            return;
        }
        pb.set("uri", SOUND_PREFIX + sound_file);
        var ret = pb.set_state(Gst.State.PLAYING);
        if (ret == Gst.StateChangeReturn.FAILURE) {
            warning("NotificationSound: failed to play '%s' (state change FAILURE)", sound_file);
            pb.set_state(Gst.State.NULL);
            pb = null;
        }
    }

    private void gst_stop(ref Gst.Element? pb) {
        if (pb != null) {
            pb.set_state(Gst.State.NULL);
            pb = null;
        }
    }

    /* ── Message notification ──────────────────────────────────────── */

    private void on_notify_content_item(ContentItem item, Conversation conversation) {
        if (!app.settings.notification_sounds) return;
        gst_play(ref playbin_message, "message.wav");
    }

    /* ── Incoming call ringtone (looping via timeout) ──────────────── */

    private void on_call_incoming(Call call, CallState state, Conversation conversation, bool video, bool multiparty) {
        stop_ringtone();

        ringing_call = call;
        play_ringtone();
        /* incoming-call.wav is 2.0s long — repeat every 2s for seamless loop */
        ringtone_timeout_id = GLib.Timeout.add_seconds(2, () => {
            if (ringing_call == null || ringing_call.state != Call.State.RINGING) {
                stop_ringtone();
                return GLib.Source.REMOVE;
            }
            play_ringtone();
            return GLib.Source.CONTINUE;
        });

        ringing_state_handler = call.notify["state"].connect(() => {
            if (call.state != Call.State.RINGING) {
                stop_ringtone();
            }
        });
    }

    private void play_ringtone() {
        gst_play(ref playbin_ringtone, "incoming-call.wav");
    }

    private void stop_ringtone() {
        if (ringtone_timeout_id != 0) {
            GLib.Source.remove(ringtone_timeout_id);
            ringtone_timeout_id = 0;
        }
        gst_stop(ref playbin_ringtone);
        if (ringing_call != null && ringing_state_handler != 0) {
            ringing_call.disconnect(ringing_state_handler);
            ringing_state_handler = 0;
        }
        ringing_call = null;
    }

    /* ── Outgoing call ringback tone (looping via timeout) ─────────── */

    private void on_call_outgoing(Call call, CallState state, Conversation conversation) {
        stop_ringback();

        ringback_call = call;
        play_ringback();
        ringback_timeout_id = GLib.Timeout.add_seconds(3, () => {
            if (ringback_call == null || ringback_call.state != Call.State.RINGING) {
                stop_ringback();
                return GLib.Source.REMOVE;
            }
            play_ringback();
            return GLib.Source.CONTINUE;
        });

        ringback_state_handler = call.notify["state"].connect(() => {
            if (call.state != Call.State.RINGING) {
                stop_ringback();
            }
        });
    }

    private void play_ringback() {
        gst_play(ref playbin_ringback, "outgoing-ringback.wav");
    }

    private void stop_ringback() {
        if (ringback_timeout_id != 0) {
            GLib.Source.remove(ringback_timeout_id);
            ringback_timeout_id = 0;
        }
        gst_stop(ref playbin_ringback);
        if (ringback_call != null && ringback_state_handler != 0) {
            ringback_call.disconnect(ringback_state_handler);
            ringback_state_handler = 0;
        }
        ringback_call = null;
    }

    /* ── Common ──────────────────────────────────────────────────── */

    private void on_call_terminated(Call call, string? reason_name, string? reason_text) {
        if (ringing_call != null && ringing_call == call) {
            stop_ringtone();
        }
        if (ringback_call != null && ringback_call == call) {
            stop_ringback();
        }
    }

    public void shutdown() {
        stop_ringtone();
        stop_ringback();
        gst_stop(ref playbin_message);
    }

    public void rekey_database(string new_key) throws Error {
        // No own database
    }

    public void checkpoint_database() {
        // No own database
    }
}

}
