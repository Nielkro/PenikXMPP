#include "openssl-context.h"
#include "dane-verifier.h"
#include <openssl/err.h>
#include <openssl/pem.h>
#include <openssl/x509v3.h>

/* Result: 0 pending, 1 ordinary PKIX, 2 DANE, -1 certificate failure,
 * -2 expired DNS evidence, -3 cancelled attempt. Never shared across accounts. */
typedef struct {
    char *hostname;
    GPtrArray *records;
    gboolean require_tlsa;
    gint64 expires_at;
    GCancellable *cancellable;
    gint result;
} Evidence;

static int evidence_index = -1;
static gsize index_initialized;

static void evidence_free(void *parent, void *ptr, CRYPTO_EX_DATA *ad,
                          int index, long argl, void *argp)
{
    (void)parent; (void)ad; (void)index; (void)argl; (void)argp;
    Evidence *e = ptr;
    if (!e) return;
    g_free(e->hostname);
    g_ptr_array_unref(e->records);
    g_object_unref(e->cancellable);
    g_free(e);
}

static gboolean evidence_current(Evidence *e)
{
    if (g_cancellable_is_cancelled(e->cancellable)) {
        g_atomic_int_set(&e->result, -3);
        return FALSE;
    }
    if (g_get_monotonic_time() >= e->expires_at) {
        g_atomic_int_set(&e->result, -2);
        return FALSE;
    }
    return TRUE;
}

static void handshake_info(const SSL *ssl, int where, int ret)
{
    (void)ret;
    Evidence *e = SSL_CTX_get_ex_data(SSL_get_SSL_CTX(ssl), evidence_index);
    if (!e) return;
    if (where & SSL_CB_HANDSHAKE_DONE) {
        /* A slow handshake may outlive the DNS TTL after certificate checking.
         * SSL_write must not send CONNECT in that case. */
        if (!evidence_current(e))
            SSL_set_shutdown((SSL *)ssl, SSL_SENT_SHUTDOWN | SSL_RECEIVED_SHUTDOWN);
    }
    if (!(where & SSL_CB_HANDSHAKE_START)) return;
    /* mosquitto connects to a validated numeric address and sets that as SNI.
     * Replace it before ClientHello, retaining the user-selected broker name.
     * This callback never looks up DNS or calls Vala/application code. */
    if (SSL_set_tlsext_host_name((SSL *)ssl, e->hostname) != 1)
        g_atomic_int_set(&e->result, -1);
}

static gboolean add_der(GPtrArray *chain, X509 *certificate)
{
    unsigned char *der = NULL;
    int length = i2d_X509(certificate, &der);
    if (length <= 0) return FALSE;
    g_ptr_array_add(chain, g_bytes_new(der, (gsize)length));
    OPENSSL_free(der);
    return TRUE;
}

static int verify_certificate(X509_STORE_CTX *store, void *data)
{
    Evidence *e = data;
    if (!evidence_current(e) || g_atomic_int_get(&e->result) == -1) goto reject;
    X509 *leaf = X509_STORE_CTX_get0_cert(store);
    STACK_OF(X509) *untrusted = X509_STORE_CTX_get0_untrusted(store);
    if (!leaf || (untrusted && sk_X509_num(untrusted) > 16)) goto reject;

    /* This context owns the complete verification policy: no mosquitto
     * numeric-host callback, no pin callback and no permissive verify callback.
     * PKIX validates the certificate chain AND original DNS reference name. */
    X509_VERIFY_PARAM *param = X509_STORE_CTX_get0_param(store);
    X509_VERIFY_PARAM_set_hostflags(param, X509_CHECK_FLAG_NO_PARTIAL_WILDCARDS);
    if (X509_VERIFY_PARAM_set1_host(param, e->hostname, 0) != 1) goto reject;
    gboolean pkix = X509_verify_cert(store) == 1;
    gboolean accepted = pkix;
    if (e->require_tlsa) {
        GPtrArray *chain = g_ptr_array_new_with_free_func((GDestroyNotify)g_bytes_unref);
        gboolean encoded = add_der(chain, leaf);
        for (int i = 0; encoded && untrusted && i < sk_X509_num(untrusted); i++) {
            X509 *cert = sk_X509_value(untrusted, i);
            if (X509_cmp(cert, leaf) != 0) encoded = add_der(chain, cert);
        }
        const char *names[] = { e->hostname, NULL };
        GError *error = NULL;
        accepted = encoded && dino_dane_verify(e->records, chain, names,
                                               pkix, e->expires_at, &error);
        g_clear_error(&error);
        g_ptr_array_unref(chain);
    }
    if (!evidence_current(e)) goto reject;
    if (!accepted) goto reject;
    X509_STORE_CTX_set_error(store, X509_V_OK);
    ERR_clear_error();
    g_atomic_int_set(&e->result, e->require_tlsa ? 2 : 1);
    return 1;
reject:
    if (g_atomic_int_get(&e->result) >= 0) g_atomic_int_set(&e->result, -1);
    X509_STORE_CTX_set_error(store, X509_V_ERR_APPLICATION_VERIFICATION);
    return 0;
}

/* GLib opens UTF-8 paths on Windows. OpenSSL's narrow filename APIs do not
 * reliably do so. Parse the CA bundle in memory rather than relocating it. */
static gboolean load_ca_file(SSL_CTX *ctx, const char *path, GError **error)
{
    gchar *data = NULL;
    gsize length = 0;
    if (!g_file_get_contents(path, &data, &length, error)) return FALSE;
    if (length > 16 * 1024 * 1024 || length == 0) {
        g_free(data);
        g_set_error_literal(error, G_IO_ERROR, G_IO_ERROR_INVALID_DATA, "Invalid CA bundle size");
        return FALSE;
    }
    BIO *bio = BIO_new_mem_buf(data, (int)length);
    STACK_OF(X509_INFO) *certs = bio ? PEM_X509_INFO_read_bio(bio, NULL, NULL, NULL) : NULL;
    gboolean loaded = FALSE;
    for (int i = 0; certs && i < sk_X509_INFO_num(certs); i++) {
        X509_INFO *info = sk_X509_INFO_value(certs, i);
        if (info->x509 && X509_STORE_add_cert(SSL_CTX_get_cert_store(ctx), info->x509) == 1)
            loaded = TRUE;
    }
    sk_X509_INFO_pop_free(certs, X509_INFO_free);
    BIO_free(bio);
    g_free(data);
    ERR_clear_error();
    if (!loaded) g_set_error_literal(error, G_IO_ERROR, G_IO_ERROR_INVALID_DATA, "CA bundle contains no usable certificates");
    return loaded;
}

SSL_CTX *dino_dane_tls_context_new(const char *hostname, GPtrArray *records,
    gboolean require_tlsa, gint64 expires_at, GCancellable *cancellable,
    const char *ca_file, const char *ca_directory, GError **error)
{
    g_return_val_if_fail(hostname && records && G_IS_CANCELLABLE(cancellable), NULL);
    if (g_once_init_enter(&index_initialized)) {
        evidence_index = SSL_CTX_get_ex_new_index(0, NULL, NULL, NULL, evidence_free);
        g_once_init_leave(&index_initialized, 1);
    }
    SSL_CTX *ctx = evidence_index >= 0 ? SSL_CTX_new(TLS_client_method()) : NULL;
    if (!ctx) goto failed;
    Evidence *e = g_new0(Evidence, 1);
    e->hostname = g_strdup(hostname);
    e->records = g_ptr_array_new_with_free_func((GDestroyNotify)g_bytes_unref);
    for (guint i = 0; i < records->len; i++)
        g_ptr_array_add(e->records, g_bytes_ref(g_ptr_array_index(records, i)));
    e->require_tlsa = require_tlsa;
    e->expires_at = expires_at;
    e->cancellable = g_object_ref(cancellable);
    if (SSL_CTX_set_ex_data(ctx, evidence_index, e) != 1) {
        evidence_free(NULL, e, NULL, 0, 0, NULL);
        goto failed;
    }
    if (SSL_CTX_set_min_proto_version(ctx, TLS1_2_VERSION) != 1) goto failed;
    SSL_CTX_set_options(ctx, SSL_OP_NO_COMPRESSION | SSL_OP_NO_TICKET | SSL_OP_NO_RENEGOTIATION);
    SSL_CTX_set_session_cache_mode(ctx, SSL_SESS_CACHE_OFF);
    SSL_CTX_set_verify(ctx, SSL_VERIFY_PEER, NULL);
    SSL_CTX_set_verify_depth(ctx, 16);
    SSL_CTX_set_cert_verify_callback(ctx, verify_certificate, e);
    SSL_CTX_set_info_callback(ctx, handshake_info);
    if (ca_file && !load_ca_file(ctx, ca_file, error)) { SSL_CTX_free(ctx); return NULL; }
    if (ca_directory && SSL_CTX_load_verify_dir(ctx, ca_directory) != 1) goto failed;
    /* Absence of a system CA store cannot authorize PKIX. DANE2/3 may still
     * authenticate using signed DNS evidence, independently of that store. */
    if (!ca_file && !ca_directory) SSL_CTX_set_default_verify_paths(ctx);
    ERR_clear_error();
    return ctx;
failed:
    SSL_CTX_free(ctx);
    g_set_error_literal(error, G_IO_ERROR, G_IO_ERROR_FAILED, "Could not initialize the broker TLS verifier");
    return NULL;
}

int dino_dane_tls_context_result(SSL_CTX *ctx)
{
    Evidence *e = SSL_CTX_get_ex_data(ctx, evidence_index);
    return e ? g_atomic_int_get(&e->result) : -1;
}
