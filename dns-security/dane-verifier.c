#include "dane-verifier.h"
#include <openssl/crypto.h>
#include <openssl/err.h>
#include <openssl/evp.h>
#include <openssl/x509.h>
#include <openssl/x509v3.h>

static const guint8 *record_data(GBytes *record, gsize *length) {
    const guint8 *data = g_bytes_get_data(record, length);
    if (*length < 4 || *length > 65535 || data[0] < 1 || data[0] > 3 || data[1] > 1 || data[2] > 2) return NULL;
    if ((data[2] == 1 && *length != 35) || (data[2] == 2 && *length != 67)) return NULL;
    return data;
}

gboolean dino_dane_records_usable(GPtrArray *records) {
    if (!records || records->len > 256) return FALSE;
    for (guint i = 0; i < records->len; i++) {
        gsize length;
        if (record_data(g_ptr_array_index(records, i), &length)) return TRUE;
    }
    return FALSE;
}

static X509 *parse_certificate(const guint8 *data, gsize length) {
    if (!length || length > 65535) return NULL;
    const unsigned char *cursor = data;
    X509 *certificate = d2i_X509(NULL, &cursor, (long) length);
    if (certificate && cursor != data + length) {
        X509_free(certificate);
        certificate = NULL;
    }
    return certificate;
}

static gboolean matches(X509 *certificate, const guint8 *record, gsize length) {
    unsigned char *encoded = NULL;
    int count = record[1] == 0 ? i2d_X509(certificate, &encoded) :
                               i2d_X509_PUBKEY(X509_get_X509_PUBKEY(certificate), &encoded);
    if (count <= 0) { OPENSSL_free(encoded); return FALSE; }
    gboolean match = FALSE;
    if (record[2] == 0) {
        match = length - 3 == (gsize) count && CRYPTO_memcmp(record + 3, encoded, count) == 0;
    } else {
        unsigned char digest[EVP_MAX_MD_SIZE];
        unsigned int digest_length = 0;
        if (EVP_Digest(encoded, count, digest, &digest_length,
                       record[2] == 1 ? EVP_sha256() : EVP_sha512(), NULL) == 1) {
            match = length - 3 == digest_length && CRYPTO_memcmp(record + 3, digest, digest_length) == 0;
        }
    }
    OPENSSL_free(encoded);
    return match;
}

static gboolean chain_to_anchor(STACK_OF(X509) *chain, X509 *anchor,
                                 const gchar *const *reference_names) {
    X509 *leaf = sk_X509_value(chain, 0);
    gboolean identity_matches = FALSE;
    // DANE-TA still requires a reference identity (RFC 7671 section 5.2).
    if (reference_names) {
        for (guint i = 0; reference_names[i] && i < 8; i++) {
            if (X509_check_host(leaf, reference_names[i], 0,
                                X509_CHECK_FLAG_NO_PARTIAL_WILDCARDS, NULL) == 1) {
                identity_matches = TRUE;
                break;
            }
        }
    }
    if (!identity_matches || X509_check_ca(anchor) <= 0) return FALSE;
    X509_STORE *store = X509_STORE_new();
    X509_STORE_CTX *context = X509_STORE_CTX_new();
    STACK_OF(X509) *untrusted = sk_X509_new_null();
    gboolean valid = FALSE;
    if (!store || !context || !untrusted) goto out;
    for (int i = 1; i < sk_X509_num(chain); i++) {
        if (!sk_X509_push(untrusted, sk_X509_value(chain, i))) goto out;
    }
    if (X509_STORE_add_cert(store, anchor) != 1 ||
            X509_STORE_set_flags(store, X509_V_FLAG_PARTIAL_CHAIN | X509_V_FLAG_TRUSTED_FIRST) != 1 ||
            X509_STORE_CTX_init(context, store, leaf, untrusted) != 1 ||
            X509_STORE_CTX_set_purpose(context, X509_PURPOSE_SSL_SERVER) != 1) goto out;
    X509_VERIFY_PARAM_set_depth(X509_STORE_CTX_get0_param(context), 16);
    valid = X509_verify_cert(context) == 1;
out:
    sk_X509_free(untrusted); // borrowed entries
    X509_STORE_CTX_free(context);
    X509_STORE_free(store);
    return valid;
}

gboolean dino_dane_verify(GPtrArray *records, GPtrArray *certificates,
                          const gchar *const *reference_names,
                          gboolean pkix_valid, gint64 expires_at, GError **error) {
    if (expires_at <= g_get_monotonic_time()) {
        g_set_error_literal(error, G_IO_ERROR, G_IO_ERROR_TIMED_OUT, "DNSSEC evidence expired before TLS verification");
        return FALSE;
    }
    if (!dino_dane_records_usable(records)) {
        g_set_error_literal(error, G_IO_ERROR, G_IO_ERROR_NOT_SUPPORTED, "No usable TLSA record");
        return FALSE;
    }
    if (!certificates || !certificates->len || certificates->len > 16) {
        g_set_error_literal(error, G_IO_ERROR, G_IO_ERROR_INVALID_DATA, "Missing or excessive TLS certificate chain");
        return FALSE;
    }
    STACK_OF(X509) *chain = sk_X509_new_null();
    gboolean verified = FALSE;
    if (!chain) goto out;
    for (guint i = 0; i < certificates->len; i++) {
        gsize length;
        const guint8 *data = g_bytes_get_data(g_ptr_array_index(certificates, i), &length);
        X509 *certificate = parse_certificate(data, length);
        if (!certificate) goto out;
        if (!sk_X509_push(chain, certificate)) { X509_free(certificate); goto out; }
    }
    for (guint i = 0; i < records->len && !verified; i++) {
        gsize length;
        const guint8 *record = record_data(g_ptr_array_index(records, i), &length);
        if (!record) continue;
        // RFC 7671 section 9: prefer the strongest supported digest within
        // each usage/selector pair. Full-value associations remain independent.
        if (record[2] == 1) {
            gboolean stronger = FALSE;
            for (guint j = 0; j < records->len; j++) {
                gsize other_length;
                const guint8 *other = record_data(g_ptr_array_index(records, j), &other_length);
                if (other && other[0] == record[0] && other[1] == record[1] && other[2] == 2) stronger = TRUE;
            }
            if (stronger) continue;
        }
        if (record[0] == 3 || record[0] == 1) {
            // DANE-EE authenticates the live leaf key; ordinary CA/name/time
            // checks are not its trust basis. PKIX-EE additionally requires PKIX.
            verified = (record[0] == 3 || pkix_valid) && matches(sk_X509_value(chain, 0), record, length);
        } else if (record[1] == 0 && record[2] == 0) {
            // A full DANE trust anchor can be omitted from the peer's chain.
            X509 *anchor = parse_certificate(record + 3, length - 3);
            if (anchor) {
                verified = chain_to_anchor(chain, anchor, reference_names);
                X509_free(anchor);
            }
        } else {
            for (int j = 1; j < sk_X509_num(chain) && !verified; j++) {
                X509 *anchor = sk_X509_value(chain, j);
                if (matches(anchor, record, length)) verified = chain_to_anchor(chain, anchor, reference_names);
            }
        }
    }
out:
    sk_X509_pop_free(chain, X509_free);
    ERR_clear_error();
    if (!verified) g_set_error_literal(error, G_IO_ERROR, G_IO_ERROR_PERMISSION_DENIED,
                                       "TLS certificate does not satisfy the authenticated TLSA records");
    return verified;
}
