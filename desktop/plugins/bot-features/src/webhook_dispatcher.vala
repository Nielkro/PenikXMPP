namespace Dino.Plugins.BotFeatures {

public class WebhookDispatcher : Object {

    private Soup.Session session;
    private Cancellable cancellable = new Cancellable();
    private bool stopped = false;
    private Gee.ArrayList<RetryDelay> retry_delays = new Gee.ArrayList<RetryDelay>();
    private const int MAX_RETRIES = 3;
    private const int TIMEOUT_SECONDS = 10;

    public WebhookDispatcher() {
        session = new Soup.Session();
        session.timeout = TIMEOUT_SECONDS;
    }

    public void shutdown() {
        if (stopped) return;
        stopped = true;
        cancellable.cancel();
        session.abort();
        // Resume suspended coroutines after removing their timers. Each one
        // observes stopped before it can issue another delivery attempt.
        RetryDelay[] pending = new RetryDelay[retry_delays.size];
        int pending_index = 0;
        foreach (RetryDelay delay in retry_delays) {
            pending[pending_index++] = delay;
        }
        retry_delays.clear();
        foreach (RetryDelay delay in pending) {
            if (delay.source_id != 0) {
                Source.remove(delay.source_id);
                delay.source_id = 0;
            }
            SourceFunc? resume = (owned) delay.resume;
            if (resume != null) resume();
        }
    }

    // Dispatch a webhook POST with HMAC-SHA256 signature
    public void dispatch(string url, string secret, string payload) {
        if (stopped) return;
        dispatch_async.begin(url, secret, payload);
    }

    public static string sanitize_url_for_log(string? url) {
        if (url == null) return "(null)";
        string s = url;
        int hash = s.index_of("#");
        if (hash >= 0) s = s.substring(0, hash) + "#...";
        int q = s.index_of("?");
        if (q >= 0 && q < s.length) {
            s = s.substring(0, q) + "?...";
        }
        return s;
    }

    private async void dispatch_async(string url, string secret, string payload) {
        if (stopped) return;
        string signature = TokenManager.hmac_sha256(secret, payload);
        string safe_url = sanitize_url_for_log(url);

        for (int attempt = 0; attempt < MAX_RETRIES; attempt++) {
            if (stopped) return;
            try {
                var msg = new Soup.Message("POST", url);
                msg.set_request_body_from_bytes("application/json",
                    new Bytes(payload.data));
                msg.get_request_headers().append("X-Bot-Signature", "sha256=" + signature);
                msg.get_request_headers().append("X-Bot-Delivery", GLib.Uuid.string_random());
                msg.get_request_headers().append("User-Agent", "DinoX-BotAPI/1.0");

                yield session.send_and_read_async(msg, GLib.Priority.DEFAULT, cancellable);
                if (stopped) return;

                uint status = msg.get_status();
                if (status >= 200 && status < 300) {
                    return; // Success
                }

                warning("Webhook dispatch to %s returned status %u (attempt %d/%d)",
                    safe_url, status, attempt + 1, MAX_RETRIES);

                // BUG-21 fix: Don't retry client errors (4xx) — they will never succeed
                if (status >= 400 && status < 500) {
                    warning("Webhook: Client error %u, not retrying", status);
                    return;
                }

            } catch (Error e) {
                if (stopped) return;
                warning("Webhook dispatch to %s failed: %s (attempt %d/%d)",
                    safe_url, e.message, attempt + 1, MAX_RETRIES);
            }

            // Wait before retry (exponential backoff: 1s, 2s, 4s)
            if (attempt < MAX_RETRIES - 1) {
                yield delay_ms(1000 * (1 << attempt));
                if (stopped) return;
            }
        }

        warning("Webhook dispatch to %s failed after %d attempts", safe_url, MAX_RETRIES);
    }

    private class RetryDelay : Object {
        public uint source_id;
        public SourceFunc? resume;
    }

    private async void delay_ms(int ms) {
        if (stopped) return;
        var delay = new RetryDelay();
        delay.resume = () => {
            delay_ms.callback();
            return Source.REMOVE;
        };
        retry_delays.add(delay);
        delay.source_id = Timeout.add(ms, () => {
            delay.source_id = 0;
            retry_delays.remove(delay);
            SourceFunc? resume = (owned) delay.resume;
            if (resume != null) resume();
            return Source.REMOVE;
        });
        yield;
    }
}

}
