#include "openssl-context.h"
#include <mosquitto.h>
#include <openssl/pem.h>
#include <openssl/x509.h>
#include <string.h>

static int connack;
static void connected(struct mosquitto *mosq, void *data, int rc)
{
    (void)mosq; (void)data;
    connack = rc == 0 ? 1 : -1;
}

typedef struct {
    GCancellable *cancel;
    gint64 expiry;
    gboolean cancel_instead;
    gboolean seen;
} AfterCertificate;

static void change_after_certificate(int writing, int version, int content_type,
    const void *buffer, size_t length, SSL *ssl, void *data)
{
    (void)version;
    if (writing || content_type != SSL3_RT_HANDSHAKE || !length ||
            ((const unsigned char *)buffer)[0] != SSL3_MT_FINISHED) return;
    AfterCertificate *change = data;
    g_assert_false(change->seen);
    // The peer's Finished arrives after our certificate check but before the
    // production HANDSHAKE_DONE guard. Do not guess this phase with a timer
    // started before connect: a loaded VM may not have checked the cert yet.
    g_assert_cmpint(dino_dane_tls_context_result(SSL_get_SSL_CTX(ssl)), ==, 2);
    change->seen = TRUE;
    if (change->cancel_instead) {
        g_cancellable_cancel(change->cancel);
    } else {
        while (g_get_monotonic_time() < change->expiry) g_usleep(10000);
    }
}

int main(void)
{
    mosquitto_lib_init();
    const char *ca = g_getenv("DINOX_TEST_CA");
    gchar *pem = NULL;
    gsize pem_len;
    g_assert_true(g_file_get_contents(ca, &pem, &pem_len, NULL));
    BIO *bio = BIO_new_mem_buf(pem, (int)pem_len);
    X509 *cert = PEM_read_bio_X509(bio, NULL, NULL, NULL);
    g_assert_nonnull(cert);
    guint8 digest[EVP_MAX_MD_SIZE];
    unsigned int len;
    g_assert_cmpint(X509_digest(cert, EVP_sha256(), digest, &len), ==, 1);
    X509_free(cert); BIO_free(bio); g_free(pem);
    const char *cases[] = { "match", "mismatch", "pkix", "pkix-wrong-name",
        "normal", "normal-untrusted", "expired", "cancelled", "expires-during", "expires-after-certificate", "cancel-after-certificate", NULL };
    for (int i = 0; cases[i]; i++) {
        const char *name = cases[i];
        gboolean normal = g_str_has_prefix(name, "normal");
        gboolean pkix = g_str_has_prefix(name, "pkix");
        gboolean success = !strcmp(name,"match") || !strcmp(name,"pkix") || !strcmp(name,"normal");
        GPtrArray *records = g_ptr_array_new_with_free_func((GDestroyNotify)g_bytes_unref);
        guint8 record[35] = { pkix ? 1 : 3, 0, 1 };
        memcpy(record + 3, digest, 32);
        if (!strcmp(name, "mismatch")) record[3] ^= 1;
        g_ptr_array_add(records, g_bytes_new(record, sizeof(record)));
        GCancellable *cancel = g_cancellable_new();
        if (!strcmp(name, "cancelled")) g_cancellable_cancel(cancel);
        gint64 expiry = g_get_monotonic_time() + 10 * G_USEC_PER_SEC;
        if (!strcmp(name, "expired")) expiry = 0;
        if (!strcmp(name, "expires-during")) expiry = g_get_monotonic_time() + 50000;
        gboolean slow_finish = g_str_has_suffix(name, "after-certificate");
        AfterCertificate change = { cancel, expiry,
            !strcmp(name, "cancel-after-certificate"), FALSE };
        const char *host = !strcmp(name, "pkix-wrong-name") ? "wrong.invalid" : "mqtt.invalid";
        GError *error = NULL;
        SSL_CTX *ctx = dino_dane_tls_context_new(host, records, !normal, expiry, cancel,
            (pkix || !strcmp(name, "normal")) ? ca : NULL, NULL, &error);
        g_assert_no_error(error); g_assert_nonnull(ctx);
        if (slow_finish) {
            SSL_CTX_set_msg_callback(ctx, change_after_certificate);
            SSL_CTX_set_msg_callback_arg(ctx, &change);
        }
        struct mosquitto *mosq = mosquitto_new(NULL, true, NULL);
        g_assert_cmpint(mosquitto_int_option(mosq, MOSQ_OPT_SSL_CTX_WITH_DEFAULTS, 0), ==, 0);
        g_assert_cmpint(mosquitto_void_option(mosq, MOSQ_OPT_SSL_CTX, ctx), ==, 0);
        mosquitto_connect_callback_set(mosq, connected);
        mosquitto_username_pw_set(mosq, "FIXTURE-USER", "FIXTURE-SECRET");
        connack = 0;
        int rc = mosquitto_connect(mosq, "127.0.0.1", atoi(g_getenv(slow_finish ? "DINOX_TEST_SLOW_FINISH_PORT" : "DINOX_TEST_PORT")), 10);
        gint64 deadline = g_get_monotonic_time() + (slow_finish ? 15 : 4) * G_USEC_PER_SEC;
        while (!rc && !connack && g_get_monotonic_time() < deadline)
            rc = mosquitto_loop(mosq, 50, 1);
        if (slow_finish) g_assert_true(change.seen);
        g_assert_cmpint(connack == 1, ==, success);
        g_assert_cmpint(dino_dane_tls_context_result(ctx), ==,
            success ? (normal ? 1 : 2) : ((!strcmp(name,"cancelled") || !strcmp(name,"cancel-after-certificate")) ? -3 :
                (!strcmp(name,"expired") || !strcmp(name,"expires-during") || !strcmp(name,"expires-after-certificate")) ? -2 : -1));
        mosquitto_destroy(mosq);
        SSL_CTX_free(ctx);
        g_object_unref(cancel);
        g_ptr_array_unref(records);
        g_print("PASS MQTT TLS %s\n", name);
    }
    mosquitto_lib_cleanup();
    return 0;
}
