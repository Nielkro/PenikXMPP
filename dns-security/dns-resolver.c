#include "dns-resolver.h"
#include <unbound.h>
#include <string.h>

#ifdef G_OS_WIN32
#include <winsock2.h>
#include <ws2tcpip.h>
#include <iphlpapi.h>
#endif

#define MAX_PENDING 32
#define MAX_QUERIES 128
#define MAX_RECORDS 256

typedef struct {
    DinoDnsResolver *owner; /* task owns the reference */
    GTask *task;
    int id;
    gint64 deadline;
} Pending;

struct _DinoDnsResolver {
    GObject parent_instance;
    struct ub_ctx *ctx;
    GMainContext *main_context;
    GThread *owner_thread;
    GPtrArray *pending;
    GSource *pump; /* borrowed while attached */
    guint queries;
    gboolean processing;
    gboolean closing;
};

G_DEFINE_TYPE(DinoDnsResolver, dino_dns_resolver, G_TYPE_OBJECT)

void dino_dns_answer_free(DinoDnsAnswer *answer) {
    if (!answer) return;
    g_free(answer->canonical_name);
    g_ptr_array_unref(answer->records);
    g_free(answer);
}

static void pending_free(Pending *pending) {
    g_object_unref(pending->task);
    g_free(pending);
}

static void fail_pending(DinoDnsResolver *self, GIOErrorEnum code, const gchar *message) {
    /* Delete first: libunbound must no longer be able to call pending pointers.
     * This also handles a rare ub_cancel failure without a dangling callback. */
    if (self->ctx) {
        ub_ctx_delete(self->ctx);
        self->ctx = NULL;
    }
    while (self->pending->len) {
        Pending *pending = g_ptr_array_steal_index_fast(self->pending, 0);
        g_task_return_new_error(pending->task, G_IO_ERROR, code, "%s", message);
        pending_free(pending);
    }
}

void dino_dns_resolver_close(DinoDnsResolver *self) {
    g_return_if_fail(DINO_IS_DNS_RESOLVER(self));
    g_return_if_fail(g_thread_self() == self->owner_thread);
    self->closing = TRUE;
    // A Vala async continuation can call close() inside ub_process's callback.
    // Do not delete the context until libunbound has returned to our pump.
    if (self->processing) return;
    g_autoptr(DinoDnsResolver) keep_alive = g_object_ref(self);
    if (self->pump) {
        GSource *pump = self->pump;
        self->pump = NULL;
        g_source_destroy(pump);
    }
    fail_pending(self, G_IO_ERROR_CANCELLED, "DNS validation context closed");
}

static void dino_dns_resolver_finalize(GObject *object) {
    DinoDnsResolver *self = DINO_DNS_RESOLVER(object);
    g_assert(self->pump == NULL && self->pending->len == 0);
    if (self->ctx) ub_ctx_delete(self->ctx);
    g_ptr_array_unref(self->pending);
    g_main_context_unref(self->main_context);
    G_OBJECT_CLASS(dino_dns_resolver_parent_class)->finalize(object);
}

static void dino_dns_resolver_class_init(DinoDnsResolverClass *klass) {
    G_OBJECT_CLASS(klass)->finalize = dino_dns_resolver_finalize;
}

static void dino_dns_resolver_init(DinoDnsResolver *self) {
    self->pending = g_ptr_array_new();
    self->main_context = g_main_context_ref_thread_default();
    self->owner_thread = g_thread_self();
}

static gboolean unbound_ok(int result, GError **error) {
    if (!result) return TRUE;
    g_set_error(error, G_IO_ERROR, G_IO_ERROR_FAILED,
                "DNS validator configuration failed: %s", ub_strerror(result));
    return FALSE;
}

static gboolean valid_forwarder(const gchar *text) {
    g_auto(GStrv) parts = g_strsplit(text, "@", -1);
    if (!parts[0] || !*parts[0] || (parts[1] && parts[2])) return FALSE;
    g_auto(GStrv) scoped = g_strsplit(parts[0], "%", -1);
    if (scoped[1] && (!*scoped[1] || scoped[2])) return FALSE;
    g_autoptr(GInetAddress) address = g_inet_address_new_from_string(scoped[0]);
    if (!address || g_inet_address_get_is_any(address) ||
            g_inet_address_get_is_multicast(address)) return FALSE;
    if (scoped[1]) {
        if (g_inet_address_get_family(address) != G_SOCKET_FAMILY_IPV6) return FALSE;
        for (const gchar *p = scoped[1]; *p; p++) {
            if (!(g_ascii_isalnum(*p) || *p == '_' || *p == '-' || *p == '.')) return FALSE;
        }
    }
    if (parts[1]) {
        if (!*parts[1]) return FALSE;
        for (const gchar *p = parts[1]; *p; p++) if (!g_ascii_isdigit(*p)) return FALSE;
        guint64 port = g_ascii_strtoull(parts[1], NULL, 10);
        if (port == 0 || port > 65535) return FALSE;
    }
    return TRUE;
}

DinoDnsResolver *dino_dns_resolver_new(const gchar *const *forwarders,
                                     const gchar *trust_anchors,
                                     gboolean tcp_only, GError **error) {
    if (!forwarders || !forwarders[0] || !trust_anchors || !*trust_anchors) {
        g_set_error_literal(error, G_IO_ERROR, G_IO_ERROR_INVALID_ARGUMENT,
                            "DNS validation requires forwarders and trust anchors");
        return NULL;
    }
    g_autoptr(DinoDnsResolver) self = g_object_new(DINO_TYPE_DNS_RESOLVER, NULL);
    self->ctx = ub_ctx_create();
    if (!self->ctx) {
        g_set_error_literal(error, G_IO_ERROR, G_IO_ERROR_FAILED, "Cannot create DNS validator");
        return NULL;
    }
    /* Do not read unbound.conf, environment overrides, hosts or OS DNS here.
     * The explicit forward-only root zone covers EVERY validation subquery.
     * ub_ctx_set_fwd creates forward-first=no. */
    const gchar *options[][2] = {
        { "module-config:", "validator iterator" },
        { "val-permissive-mode:", "no" },
        { "harden-dnssec-stripped:", "yes" },
        { "serve-expired:", "no" },
        { "trust-anchor-signaling:", "no" },
        { "qname-minimisation:", "no" },
        { "do-not-query-localhost:", "no" },
        { "msg-cache-size:", "1m" },
        { "rrset-cache-size:", "2m" },
        { "key-cache-size:", "1m" },
        { "neg-cache-size:", "256k" },
        { "outgoing-range:", "32" },
        { "num-queries-per-thread:", "64" },
        { "do-udp:", tcp_only ? "no" : "yes" },
        { "tcp-upstream:", tcp_only ? "yes" : "no" }
    };
    for (guint i = 0; i < G_N_ELEMENTS(options); i++) {
        if (!unbound_ok(ub_ctx_set_option(self->ctx, options[i][0], options[i][1]), error)) {
            g_prefix_error(error, "%s ", options[i][0]);
            return NULL;
        }
    }
    for (guint i = 0; forwarders[i]; i++) {
        if (i >= 16 || !valid_forwarder(forwarders[i])) {
            g_set_error_literal(error, G_IO_ERROR, G_IO_ERROR_INVALID_ARGUMENT,
                                "DNS forwarders must be numeric addresses with an optional port");
            return NULL;
        }
        if (!unbound_ok(ub_ctx_set_fwd(self->ctx, forwarders[i]), error)) return NULL;
    }
    /* ub_ctx_set_fwd() initializes the root forward zone with first=0.
     * forward-first is a per-zone parser option, not a libunbound ctx option. */
    g_auto(GStrv) anchors = g_strsplit(trust_anchors, "\n", -1);
    guint count = 0;
    for (guint i = 0; anchors[i]; i++) {
        gchar *line = g_strstrip(anchors[i]);
        if (!*line || *line == '#') continue;
        if (!unbound_ok(ub_ctx_add_ta(self->ctx, line), error)) return NULL;
        count++;
    }
    if (!count) {
        g_set_error_literal(error, G_IO_ERROR, G_IO_ERROR_INVALID_ARGUMENT, "No DNS trust anchors");
        return NULL;
    }
    if (!unbound_ok(ub_ctx_async(self->ctx, 1), error)) return NULL;
    return g_steal_pointer(&self);
}

static void resolved(void *data, int code, struct ub_result *result) {
    Pending *pending = data;
    DinoDnsResolver *self = pending->owner;
    g_ptr_array_remove_fast(self->pending, pending);
    if (self->closing) {
        g_task_return_new_error(pending->task, G_IO_ERROR, G_IO_ERROR_CANCELLED, "DNS validation context closed");
    } else if (g_task_return_error_if_cancelled(pending->task)) {
        /* Cancellation wins even if the worker just completed. */
    } else if (g_get_monotonic_time() >= pending->deadline) {
        g_task_return_new_error(pending->task, G_IO_ERROR, G_IO_ERROR_TIMED_OUT, "DNS validation timed out");
    } else if (code || !result) {
        g_task_return_new_error(pending->task, G_IO_ERROR, G_IO_ERROR_FAILED,
                               "DNS validation failed: %s", ub_strerror(code));
    } else if (!result->bogus && result->rcode != 0 && result->rcode != 3) {
        /* SERVFAIL, REFUSED etc. are NOT an unsigned answer. */
        g_task_return_new_error(pending->task, G_IO_ERROR, G_IO_ERROR_FAILED,
                               "DNS server returned failure code %d", result->rcode);
    } else {
        DinoDnsAnswer *answer = g_new0(DinoDnsAnswer, 1);
        answer->validation = result->bogus ? DINO_DNS_BOGUS :
                             result->secure ? DINO_DNS_SECURE : DINO_DNS_INSECURE;
        answer->nxdomain = result->nxdomain;
        answer->expires_at = g_get_monotonic_time() + (gint64) MAX(0, result->ttl) * G_USEC_PER_SEC;
        answer->canonical_name = g_strdup(result->canonname);
        answer->records = g_ptr_array_new_with_free_func((GDestroyNotify) g_bytes_unref);
        gboolean valid = TRUE;
        /* Do not expose data from a bogus answer, including a forged TTL. */
        if (!result->bogus && result->data) {
            for (guint i = 0; result->data[i]; i++) {
                if (i >= MAX_RECORDS || !result->len || result->len[i] < 0 || result->len[i] > 65535) {
                    valid = FALSE;
                    break;
                }
                g_ptr_array_add(answer->records, g_bytes_new(result->data[i], (gsize) result->len[i]));
            }
        }
        if (result->bogus) answer->expires_at = 0;
        if (valid) g_task_return_pointer(pending->task, answer, (GDestroyNotify) dino_dns_answer_free);
        else {
            dino_dns_answer_free(answer);
            g_task_return_new_error(pending->task, G_IO_ERROR, G_IO_ERROR_INVALID_DATA, "Invalid or excessive DNS records");
        }
    }
    if (result) ub_resolve_free(result);
    pending_free(pending);
}

static gboolean pump_results(gpointer data) {
    DinoDnsResolver *self = data;
    g_autoptr(DinoDnsResolver) keep_alive = g_object_ref(self);
    /* Only active while requests exist. Validation itself runs in unbound's
     * worker; a bounded tick avoids Unix-fd assumptions in native Windows GLib. */
    if (self->ctx && ub_poll(self->ctx)) {
        self->processing = TRUE;
        int code = ub_process(self->ctx);
        self->processing = FALSE;
        if (self->closing) fail_pending(self, G_IO_ERROR_CANCELLED, "DNS validation context closed");
        else if (code) fail_pending(self, G_IO_ERROR_FAILED, "DNS validator worker failed");
    }
    for (guint i = 0; i < self->pending->len;) {
        Pending *pending = g_ptr_array_index(self->pending, i);
        GCancellable *cancel = g_task_get_cancellable(pending->task);
        gboolean cancelled = cancel && g_cancellable_is_cancelled(cancel);
        if (!cancelled && g_get_monotonic_time() < pending->deadline) { i++; continue; }
        if (ub_cancel(self->ctx, pending->id)) {
            fail_pending(self, G_IO_ERROR_FAILED, "DNS validator could not cancel a request");
            break;
        }
        g_ptr_array_remove_index_fast(self->pending, i);
        g_task_return_new_error(pending->task, G_IO_ERROR,
                               cancelled ? G_IO_ERROR_CANCELLED : G_IO_ERROR_TIMED_OUT,
                               "%s", cancelled ? "DNS validation cancelled" : "DNS validation timed out");
        pending_free(pending);
    }
    if (self->pending->len) return G_SOURCE_CONTINUE;
    self->pump = NULL;
    return G_SOURCE_REMOVE;
}

static gboolean valid_name(const gchar *name) {
    if (!name || !*name || strlen(name) > 253) return FALSE;
    guint label = 0;
    for (const gchar *p = name; *p; p++) {
        if (*p == '.') {
            if (!label) return FALSE;
            label = 0;
        } else {
            if (!(g_ascii_isalnum(*p) || *p == '-' || *p == '_') || ++label > 63) return FALSE;
        }
    }
    return TRUE; /* absolute trailing dot is allowed; names are not searched */
}

void dino_dns_resolver_resolve_async(DinoDnsResolver *self, const gchar *name,
                                    guint16 rrtype, guint timeout_ms,
                                    GCancellable *cancellable,
                                    GAsyncReadyCallback callback, gpointer user_data) {
    g_return_if_fail(DINO_IS_DNS_RESOLVER(self));
    g_return_if_fail(g_thread_self() == self->owner_thread);
    GTask *task = g_task_new(self, cancellable, callback, user_data);
    g_task_set_source_tag(task, dino_dns_resolver_resolve_async);
    if (g_task_return_error_if_cancelled(task)) { g_object_unref(task); return; }
    if (!self->ctx || self->closing || !valid_name(name) || !rrtype || timeout_ms == 0 || timeout_ms > 30000 ||
            self->pending->len >= MAX_PENDING || self->queries >= MAX_QUERIES) {
        g_task_return_new_error(task, G_IO_ERROR, self->ctx && !self->closing ? G_IO_ERROR_INVALID_ARGUMENT : G_IO_ERROR_CLOSED,
                               "DNS context closed or request outside permitted bounds");
        g_object_unref(task);
        return;
    }
    Pending *pending = g_new0(Pending, 1);
    pending->owner = self;
    pending->task = task;
    pending->deadline = g_get_monotonic_time() + (gint64) timeout_ms * 1000;
    int code = ub_resolve_async(self->ctx, name, rrtype, 1, pending, resolved, &pending->id);
    if (code) {
        g_task_return_new_error(task, G_IO_ERROR, G_IO_ERROR_FAILED, "DNS query failed: %s", ub_strerror(code));
        pending_free(pending);
        return;
    }
    self->queries++;
    g_ptr_array_add(self->pending, pending);
    if (!self->pump) {
        self->pump = g_timeout_source_new(20);
        g_source_set_callback(self->pump, pump_results, g_object_ref(self), g_object_unref);
        g_source_attach(self->pump, self->main_context);
        g_source_unref(self->pump);
    }
}

DinoDnsAnswer *dino_dns_resolver_resolve_finish(DinoDnsResolver *self, GAsyncResult *result, GError **error) {
    g_return_val_if_fail(g_task_is_valid(result, self), NULL);
    g_return_val_if_fail(g_async_result_is_tagged(result, dino_dns_resolver_resolve_async), NULL);
    return g_task_propagate_pointer(G_TASK(result), error);
}

gchar **dino_dns_system_forwarders(GError **error) {
    g_autoptr(GPtrArray) addresses = g_ptr_array_new_with_free_func(g_free);
#ifdef G_OS_WIN32
    /* Include IPv6 DNS and link-local interface scopes. GetNetworkParams only
     * exposes IPv4; MSYS2's resolv.conf is not the native Windows configuration. */
    ULONG size = 16384;
    DWORD rc = ERROR_BUFFER_OVERFLOW;
    g_autofree IP_ADAPTER_ADDRESSES *adapters = NULL;
    for (guint attempt = 0; attempt < 3 && rc == ERROR_BUFFER_OVERFLOW; attempt++) {
        if (size > 16 * 1024 * 1024) break;
        g_free(g_steal_pointer(&adapters));
        adapters = g_malloc0(size);
        rc = GetAdaptersAddresses(AF_UNSPEC, GAA_FLAG_SKIP_ANYCAST | GAA_FLAG_SKIP_MULTICAST |
                                  GAA_FLAG_SKIP_UNICAST | GAA_FLAG_SKIP_FRIENDLY_NAME,
                                  NULL, adapters, &size);
    }
    if (rc != ERROR_SUCCESS) {
        g_set_error(error, G_IO_ERROR, G_IO_ERROR_FAILED, "Cannot read Windows DNS configuration (%lu)", (unsigned long) rc);
        return NULL;
    }
    for (IP_ADAPTER_ADDRESSES *adapter = adapters; adapter; adapter = adapter->Next) {
        if (adapter->OperStatus != IfOperStatusUp) continue;
        for (IP_ADAPTER_DNS_SERVER_ADDRESS *dns = adapter->FirstDnsServerAddress; dns; dns = dns->Next) {
            const struct sockaddr *sa = dns->Address.lpSockaddr;
            if (!sa) continue;
            g_autoptr(GInetAddress) address = NULL;
            guint32 scope = 0;
            if (sa->sa_family == AF_INET) {
                const struct sockaddr_in *v4 = (const struct sockaddr_in *) sa;
                address = g_inet_address_new_from_bytes((const guint8 *) &v4->sin_addr, G_SOCKET_FAMILY_IPV4);
            } else if (sa->sa_family == AF_INET6) {
                const struct sockaddr_in6 *v6 = (const struct sockaddr_in6 *) sa;
                address = g_inet_address_new_from_bytes((const guint8 *) &v6->sin6_addr, G_SOCKET_FAMILY_IPV6);
                scope = v6->sin6_scope_id;
            }
            if (!address) continue;
            g_autofree gchar *ip = g_inet_address_to_string(address);
            g_autofree gchar *text = scope ? g_strdup_printf("%s%%%u", ip, scope) : g_strdup(ip);
            if (valid_forwarder(text) && !g_ptr_array_find_with_equal_func(addresses, text, (GEqualFunc) g_str_equal, NULL)) {
                g_ptr_array_add(addresses, g_strdup(text));
            }
        }
    }
#else
    g_autofree gchar *contents = NULL;
    if (!g_file_get_contents("/etc/resolv.conf", &contents, NULL, error)) return NULL;
    g_auto(GStrv) lines = g_strsplit(contents, "\n", -1);
    for (guint i = 0; lines[i]; i++) {
        g_auto(GStrv) fields = g_strsplit_set(g_strstrip(lines[i]), " \t", -1);
        if (g_strcmp0(fields[0], "nameserver") != 0) continue;
        for (guint j = 1; fields[j]; j++) {
            if (!*fields[j]) continue;
            if (valid_forwarder(fields[j])) g_ptr_array_add(addresses, g_strdup(fields[j]));
            break;
        }
    }
#endif
    if (addresses->len == 0) {
        g_set_error_literal(error, G_IO_ERROR, G_IO_ERROR_NOT_FOUND, "No system DNS forwarder configured");
        return NULL;
    }
    g_ptr_array_add(addresses, NULL);
    return (gchar **) g_ptr_array_free(g_steal_pointer(&addresses), FALSE);
}

const gchar *dino_dns_root_trust_anchors(void) {
    /* IANA root-anchors.xml, retrieved over HTTPS 2026-10-21. Keys 20326 and
     * 38696 have no validUntil. The retired 19036 key is intentionally absent.
     * Updates are reviewed source/package changes, never unauthenticated DNS. */
    return ". IN DS 20326 8 2 E06D44B80B8F1D39A95C0B0D7C65D08458E880409BBC683457104237C7F8EC8D\n"
           ". IN DS 38696 8 2 683D2D0ACB8C9B712A1948B27F741219298D0A450D612C483AF444A4C0FB2B16\n";
}
