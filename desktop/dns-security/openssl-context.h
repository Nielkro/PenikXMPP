#pragma once
#include <gio/gio.h>
#include <openssl/ssl.h>

/* One context per attempt. libmosquitto takes its own SSL_CTX reference.
 * DNS evidence is immutable; only the result is atomic because verification
 * may execute in the connect worker or the application's event loop. */
SSL_CTX *dino_dane_tls_context_new(const char *hostname, GPtrArray *records,
    gboolean require_tlsa, gint64 expires_at, GCancellable *cancellable,
    const char *ca_file, const char *ca_directory, GError **error);
int dino_dane_tls_context_result(SSL_CTX *context);
