using Gee;
using Xmpp.Xep;

namespace Dino.Plugins.GoogleWebrtc {

internal interface EngineMujiCodecProbeSource : Object {
    public signal void description_ready(
        JingleRtp.LibwebrtcJingleDescription description);
    public signal void failed(string message);

    public abstract void start() throws Error;
    public abstract void close();
}

internal class EngineSessionMujiCodecProbe : Object, EngineMujiCodecProbeSource {
    private EngineSessionOwner? session;
    private ulong description_handler = 0;
    private ulong error_handler = 0;

    public EngineSessionMujiCodecProbe(EngineSessionOwner session) {
        this.session = session;
        description_handler = session.local_description_ready.connect((description) => {
            description_ready(description);
        });
        error_handler = session.native_error.connect((_status, message) => {
            failed(message);
        });
    }

    public void start() throws Error {
        if (session == null) {
            throw new EngineError.CLOSED("MUJI codec probe is closed");
        }
        ((!) session).create_offer();
    }

    public void close() {
        if (session == null) return;
        EngineSessionOwner current = (!) session;
        session = null;
        if (description_handler != 0 &&
                SignalHandler.is_connected(current, description_handler)) {
            current.disconnect(description_handler);
        }
        if (error_handler != 0 && SignalHandler.is_connected(current, error_handler)) {
            current.disconnect(error_handler);
        }
        description_handler = 0;
        error_handler = 0;
        current.close();
    }

    ~EngineSessionMujiCodecProbe() {
        close();
    }
}

/** Runs the asynchronous native offer probe with deterministic cleanup. */
internal class EngineMujiCodecProbeRunner : Object {
    public static async Gee.List<JingleRtp.PayloadType> run(
            EngineMujiCodecProbeSource probe,
            string media,
            uint timeout_ms = 5000) throws Error {
        var promise = new Promise<Gee.List<JingleRtp.PayloadType>>();
        bool completed = false;
        ulong description_handler = probe.description_ready.connect((description) => {
            if (completed) return;
            Gee.List<JingleRtp.PayloadType> payloads = payloads_for_media(
                description, media);
            completed = true;
            if (payloads.is_empty) {
                promise.set_exception(new EngineError.PROTOCOL(
                    "Google/libwebrtc did not expose MUJI %s codecs".printf(media)));
            } else {
                promise.set_value(payloads);
            }
        });
        ulong error_handler = probe.failed.connect((message) => {
            if (completed) return;
            completed = true;
            promise.set_exception(new EngineError.NATIVE(message));
        });
        uint timeout_id = 0;
        timeout_id = Timeout.add(timeout_ms, () => {
            // A GLib source removes itself after this callback. Clear the id
            // first so finally never attempts to remove an expired source.
            timeout_id = 0;
            if (completed) return Source.REMOVE;
            completed = true;
            promise.set_exception(new IOError.TIMED_OUT(
                "Timed out probing Google/libwebrtc MUJI codecs"));
            return Source.REMOVE;
        });

        try {
            probe.start();
            return yield promise.future.wait_async();
        } finally {
            if (timeout_id != 0) {
                Source.remove(timeout_id);
                timeout_id = 0;
            }
            if (SignalHandler.is_connected(probe, description_handler)) {
                probe.disconnect(description_handler);
            }
            if (SignalHandler.is_connected(probe, error_handler)) {
                probe.disconnect(error_handler);
            }
            probe.close();
        }
    }

    private static Gee.List<JingleRtp.PayloadType> payloads_for_media(
            JingleRtp.LibwebrtcJingleDescription description,
            string media) {
        foreach (JingleRtp.SdpMediaSection section in description.session.media_sections) {
            if (section.media == media) {
                var ret = new ArrayList<JingleRtp.PayloadType>(
                    JingleRtp.PayloadType.equals_func);
                foreach (JingleRtp.PayloadType payload in section.payload_types) {
                    JingleRtp.PayloadType advertised = payload.clone();
                    // Start new MUJI conferences without optional receiver RTT
                    // feedback. Existing peer maps and direct calls keep their
                    // negotiated capabilities; never mutate the native offer.
                    for (int i = advertised.rtcp_fbs.size - 1; i >= 0; i--) {
                        if (advertised.rtcp_fbs[i].type_ == "rrtr") {
                            advertised.rtcp_fbs.remove_at(i);
                        }
                    }
                    ret.add(advertised);
                }
                return ret;
            }
        }
        return new ArrayList<JingleRtp.PayloadType>(JingleRtp.PayloadType.equals_func);
    }
}

}
