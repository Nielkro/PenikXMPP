#include "dane-verifier.h"
#include <openssl/evp.h>
#include <openssl/x509v3.h>

static X509 *root, *leaf, *other_root, *expired_leaf;

static void extension(X509 *cert, X509 *issuer, int nid, const char *value) {
    X509V3_CTX context;
    X509V3_set_ctx(&context, issuer, cert, NULL, NULL, 0);
    X509_EXTENSION *ext = X509V3_EXT_conf_nid(NULL, &context, nid, (char *) value);
    g_assert_nonnull(ext);
    g_assert_cmpint(X509_add_ext(cert, ext, -1), ==, 1);
    X509_EXTENSION_free(ext);
}

static X509 *certificate(EVP_PKEY *key, X509 *issuer, EVP_PKEY *signer, gboolean ca, gboolean expired) {
    X509 *cert = X509_new();
    X509_set_version(cert, 2);
    ASN1_INTEGER_set(X509_get_serialNumber(cert), ca ? 1 : expired ? 3 : 2);
    X509_gmtime_adj(X509_getm_notBefore(cert), -7200);
    X509_gmtime_adj(X509_getm_notAfter(cert), expired ? -3600 : 86400);
    X509_set_pubkey(cert, key);
    X509_NAME *name = X509_get_subject_name(cert);
    X509_NAME_add_entry_by_txt(name, "CN", MBSTRING_ASC, (const unsigned char *) (ca ? "Fixture CA" : "good.example"), -1, -1, 0);
    X509_set_issuer_name(cert, issuer ? X509_get_subject_name(issuer) : name);
    extension(cert, issuer ? issuer : cert, NID_basic_constraints, ca ? "critical,CA:TRUE" : "critical,CA:FALSE");
    extension(cert, issuer ? issuer : cert, NID_key_usage, ca ? "critical,keyCertSign,cRLSign" : "critical,digitalSignature");
    if (!ca) {
        extension(cert, issuer, NID_ext_key_usage, "serverAuth");
        extension(cert, issuer, NID_subject_alt_name, "DNS:good.example");
    }
    g_assert_cmpint(X509_sign(cert, signer, EVP_sha256()), >, 0);
    return cert;
}

static GBytes *der(X509 *cert, guint selector) {
    unsigned char *data = NULL;
    int size = selector ? i2d_X509_PUBKEY(X509_get_X509_PUBKEY(cert), &data) : i2d_X509(cert, &data);
    g_assert_cmpint(size, >, 0);
    GBytes *bytes = g_bytes_new(data, size);
    OPENSSL_free(data);
    return bytes;
}

static GBytes *tlsa(X509 *cert, guint usage, guint selector, guint matching) {
    g_autoptr(GBytes) encoded = der(cert, selector);
    gsize length;
    const guint8 *data = g_bytes_get_data(encoded, &length);
    guint8 digest[EVP_MAX_MD_SIZE];
    unsigned int size = 0;
    if (matching) {
        g_assert_cmpint(EVP_Digest(data, length, digest, &size, matching == 1 ? EVP_sha256() : EVP_sha512(), NULL), ==, 1);
        data = digest;
        length = size;
    }
    g_autoptr(GByteArray) wire = g_byte_array_new();
    guint8 header[] = {usage, selector, matching};
    g_byte_array_append(wire, header, 3);
    g_byte_array_append(wire, data, length);
    return g_byte_array_free_to_bytes(g_steal_pointer(&wire));
}

static GPtrArray *array(void) { return g_ptr_array_new_with_free_func((GDestroyNotify) g_bytes_unref); }

static void check(GPtrArray *records, X509 *peer, X509 *extra, const gchar *identity,
                   gboolean pkix, gboolean expired, gboolean expected, GIOErrorEnum error_code) {
    g_autoptr(GPtrArray) chain = array();
    g_ptr_array_add(chain, der(peer, 0));
    if (extra) g_ptr_array_add(chain, der(extra, 0));
    const gchar *names[] = { identity, NULL };
    GError *error = NULL;
    gint64 expiry = g_get_monotonic_time() + (expired ? -G_USEC_PER_SEC : 60 * G_USEC_PER_SEC);
    gboolean verified = dino_dane_verify(records, chain, names, pkix, expiry, &error);
    g_assert_cmpint(verified, ==, expected);
    if (expected) g_assert_no_error(error);
    else g_assert_error(error, G_IO_ERROR, (gint) error_code);
    g_clear_error(&error);
}

static void leaf_matching(void) {
    for (guint selector = 0; selector <= 1; selector++) {
        for (guint matching = 0; matching <= 2; matching++) {
            g_autoptr(GPtrArray) records = array();
            g_ptr_array_add(records, tlsa(leaf, 3, selector, matching));
            check(records, leaf, NULL, "unrelated.example", FALSE, FALSE, TRUE, 0);
            check(records, other_root, NULL, "good.example", TRUE, FALSE, FALSE, G_IO_ERROR_PERMISSION_DENIED);
        }
    }
}

static void rollover(void) {
    g_autoptr(GPtrArray) records = array();
    g_ptr_array_add(records, tlsa(other_root, 3, 1, 1));
    g_ptr_array_add(records, tlsa(leaf, 3, 1, 1));
    check(records, leaf, NULL, "good.example", FALSE, FALSE, TRUE, 0);
}

static void pkix_required(void) {
    g_autoptr(GPtrArray) records = array();
    g_ptr_array_add(records, tlsa(leaf, 1, 1, 1));
    check(records, leaf, NULL, "good.example", FALSE, FALSE, FALSE, G_IO_ERROR_PERMISSION_DENIED);
    check(records, leaf, NULL, "good.example", TRUE, FALSE, TRUE, 0);
}

static void digest_agility(void) {
    g_autoptr(GPtrArray) records = array();
    g_ptr_array_add(records, tlsa(leaf, 3, 1, 1));
    g_ptr_array_add(records, tlsa(other_root, 3, 1, 2));
    check(records, leaf, NULL, "good.example", FALSE, FALSE, FALSE, G_IO_ERROR_PERMISSION_DENIED);
    g_ptr_array_add(records, tlsa(leaf, 3, 1, 2));
    check(records, leaf, NULL, "good.example", FALSE, FALSE, TRUE, 0);
}

static void full_anchor(void) {
    g_autoptr(GPtrArray) records = array();
    g_ptr_array_add(records, tlsa(root, 2, 0, 0));
    // Root deliberately absent from the presented chain.
    check(records, leaf, NULL, "good.example", FALSE, FALSE, TRUE, 0);
    check(records, leaf, NULL, "wrong.example", FALSE, FALSE, FALSE, G_IO_ERROR_PERMISSION_DENIED);
}

static void anchor_chain(void) {
    g_autoptr(GPtrArray) records = array();
    g_ptr_array_add(records, tlsa(root, 2, 1, 1));
    check(records, leaf, root, "good.example", FALSE, FALSE, TRUE, 0);
    g_ptr_array_set_size(records, 0);
    // A matching unrelated CA appended to the peer chain must not authorize it.
    g_ptr_array_add(records, tlsa(other_root, 2, 1, 1));
    check(records, leaf, other_root, "good.example", FALSE, FALSE, FALSE, G_IO_ERROR_PERMISSION_DENIED);
}

static void expiry(void) {
    g_autoptr(GPtrArray) records = array();
    g_ptr_array_add(records, tlsa(expired_leaf, 3, 1, 1));
    check(records, expired_leaf, NULL, "good.example", FALSE, FALSE, TRUE, 0);
    check(records, expired_leaf, NULL, "good.example", FALSE, TRUE, FALSE, G_IO_ERROR_TIMED_OUT);
    g_ptr_array_set_size(records, 0);
    g_ptr_array_add(records, tlsa(root, 2, 1, 1));
    check(records, expired_leaf, root, "good.example", FALSE, FALSE, FALSE, G_IO_ERROR_PERMISSION_DENIED);
}

static void unsupported(void) {
    g_autoptr(GPtrArray) records = array();
    guint8 bad[] = {3, 1, 1, 0}; // SHA-256 cannot be one octet
    g_ptr_array_add(records, g_bytes_new(bad, sizeof bad));
    g_ptr_array_add(records, tlsa(root, 0, 0, 1));
    g_assert_false(dino_dane_records_usable(records));
    check(records, leaf, root, "good.example", TRUE, FALSE, FALSE, G_IO_ERROR_NOT_SUPPORTED);
}

int main(int argc, char **argv) {
    g_test_init(&argc, &argv, NULL);
    EVP_PKEY *root_key = EVP_EC_gen("prime256v1");
    EVP_PKEY *leaf_key = EVP_EC_gen("prime256v1");
    EVP_PKEY *other_key = EVP_EC_gen("prime256v1");
    g_assert_nonnull(root_key); g_assert_nonnull(leaf_key); g_assert_nonnull(other_key);
    root = certificate(root_key, NULL, root_key, TRUE, FALSE);
    other_root = certificate(other_key, NULL, other_key, TRUE, FALSE);
    leaf = certificate(leaf_key, root, root_key, FALSE, FALSE);
    expired_leaf = certificate(leaf_key, root, root_key, FALSE, TRUE);
    g_test_add_func("/Dane/leaf-selectors-hashes", leaf_matching);
    g_test_add_func("/Dane/rollover", rollover);
    g_test_add_func("/Dane/digest-agility", digest_agility);
    g_test_add_func("/Dane/pkix-required", pkix_required);
    g_test_add_func("/Dane/full-anchor-omitted", full_anchor);
    g_test_add_func("/Dane/unrelated-anchor-rejected", anchor_chain);
    g_test_add_func("/Dane/expiry", expiry);
    g_test_add_func("/Dane/unsupported", unsupported);
    int result = g_test_run();
    X509_free(root); X509_free(other_root); X509_free(leaf); X509_free(expired_leaf);
    EVP_PKEY_free(root_key); EVP_PKEY_free(leaf_key); EVP_PKEY_free(other_key);
    return result;
}
