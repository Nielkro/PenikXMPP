#pragma once
#include <gio/gio.h>

G_BEGIN_DECLS

/* TLSA RDATA and certificate-chain entries are GBytes. Supports DANE-TA(2),
 * DANE-EE(3), and PKIX-EE(1); usage 0 remains unsupported. Selectors 0/1 and
 * matching types 0/1/2 are supported. Unsupported records never count as a match.
 * These functions do NOT establish DNS authenticity: the caller must only pass
 * an authenticated endpoint's SECURE TLSA RRset and its earliest evidence TTL.
 */
gboolean dino_dane_records_usable(GPtrArray *records);
gboolean dino_dane_verify(GPtrArray *records, GPtrArray *chain,
                          const gchar *const *reference_names,
                          gboolean pkix_valid, gint64 expires_at, GError **error);

G_END_DECLS
