#pragma once

#include <gio/gio.h>

G_BEGIN_DECLS

#define DINO_TYPE_DNS_RESOLVER (dino_dns_resolver_get_type())
G_DECLARE_FINAL_TYPE(DinoDnsResolver, dino_dns_resolver, DINO, DNS_RESOLVER, GObject)

typedef enum {
    DINO_DNS_SECURE,
    DINO_DNS_INSECURE,
    DINO_DNS_BOGUS
} DinoDnsValidation;

typedef struct {
    DinoDnsValidation validation;
    gboolean nxdomain;
    gint64 expires_at; /* monotonic microseconds; never persist across processes */
    gchar *canonical_name;
    GPtrArray *records; /* GBytes containing libunbound's DNS RDATA */
} DinoDnsAnswer;

void dino_dns_answer_free(DinoDnsAnswer *answer);

/* An immutable, isolated validation/cache context. Forwarders MUST be explicit
 * numeric addresses, optionally followed by @port. No recursive fallback.
 * The caller owns the account/route lifetime and must close it on changes.
 * All methods run on the creating thread and its thread-default main context.
 * trust_anchors is zone-format DS/DNSKEY text, not a file path.
 */
DinoDnsResolver *dino_dns_resolver_new(const gchar *const *forwarders,
                                     const gchar *trust_anchors,
                                     gboolean tcp_only, GError **error);
void dino_dns_resolver_resolve_async(DinoDnsResolver *self, const gchar *name,
                                    guint16 rrtype, guint timeout_ms,
                                    GCancellable *cancellable,
                                    GAsyncReadyCallback callback, gpointer user_data);
DinoDnsAnswer *dino_dns_resolver_resolve_finish(DinoDnsResolver *self,
                                              GAsyncResult *result, GError **error);
void dino_dns_resolver_close(DinoDnsResolver *self);

/* Reads configuration only. Does not resolve names, change system DNS, or pick
 * a public fallback. Returns an error for an empty/unreadable configuration.
 */
gchar **dino_dns_system_forwarders(GError **error);
const gchar *dino_dns_root_trust_anchors(void);

G_END_DECLS
