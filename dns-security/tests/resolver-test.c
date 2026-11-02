#include "dns-resolver.h"

typedef struct {
    GMainLoop *loop;
    DinoDnsAnswer *answer;
    GError *error;
} Request;

static void complete(GObject *source, GAsyncResult *result, gpointer data) {
    Request *request = data;
    request->answer = dino_dns_resolver_resolve_finish(DINO_DNS_RESOLVER(source), result, &request->error);
    g_main_loop_quit(request->loop);
}

static DinoDnsResolver *resolver(void) {
    const gchar *forwarders[] = { g_getenv("DINOX_TEST_DNS_FORWARDER"), NULL };
    GError *error = NULL;
    DinoDnsResolver *result = dino_dns_resolver_new(forwarders, g_getenv("DINOX_TEST_DNS_ANCHOR"), TRUE, &error);
    g_assert_no_error(error);
    g_assert_nonnull(result);
    return result;
}

static Request query(DinoDnsResolver *resolver, const gchar *name, guint16 type, guint timeout) {
    Request request = { .loop = g_main_loop_new(NULL, FALSE) };
    dino_dns_resolver_resolve_async(resolver, name, type, timeout, NULL, complete, &request);
    g_main_loop_run(request.loop);
    g_main_loop_unref(request.loop);
    request.loop = NULL;
    return request;
}

static void invalid_configuration(void) {
    const gchar *bad[] = { "resolver.example", NULL };
    GError *error = NULL;
    g_assert_null(dino_dns_resolver_new(NULL, dino_dns_root_trust_anchors(), TRUE, &error));
    g_assert_error(error, G_IO_ERROR, G_IO_ERROR_INVALID_ARGUMENT);
    g_clear_error(&error);
    g_assert_null(dino_dns_resolver_new(bad, dino_dns_root_trust_anchors(), TRUE, &error));
    g_assert_error(error, G_IO_ERROR, G_IO_ERROR_INVALID_ARGUMENT);
    g_clear_error(&error);
    const gchar *scoped[] = { "fe80::1%1@53", "::1@53", NULL };
    g_autoptr(DinoDnsResolver) ipv6 = dino_dns_resolver_new(scoped, dino_dns_root_trust_anchors(), TRUE, &error);
    g_assert_no_error(error);
    g_assert_nonnull(ipv6);
}

static void isolated_caches(void) {
    g_autoptr(DinoDnsResolver) good = resolver();
    Request first = query(good, "good.dinox-test.", 1, 2500);
    g_assert_no_error(first.error);
    g_assert_cmpint(first.answer->validation, ==, DINO_DNS_SECURE);
    dino_dns_answer_free(first.answer);

    g_autofree gchar *anchor = g_strdup(g_getenv("DINOX_TEST_DNS_ANCHOR"));
    gsize last = strlen(anchor) - 1;
    anchor[last] = anchor[last] == '0' ? '1' : '0';
    const gchar *forwarders[] = { g_getenv("DINOX_TEST_DNS_FORWARDER"), NULL };
    GError *error = NULL;
    g_autoptr(DinoDnsResolver) different_trust = dino_dns_resolver_new(forwarders, anchor, TRUE, &error);
    g_assert_no_error(error);
    Request second = query(different_trust, "good.dinox-test.", 1, 2500);
    g_assert_no_error(second.error);
    g_assert_cmpint(second.answer->validation, ==, DINO_DNS_BOGUS);
    dino_dns_answer_free(second.answer);
    // Cancelling a second context cannot close the first or replace its cache.
    dino_dns_resolver_close(different_trust);
    first = query(good, "good.dinox-test.", 1, 2500);
    g_assert_no_error(first.error);
    g_assert_cmpint(first.answer->validation, ==, DINO_DNS_SECURE);
    dino_dns_answer_free(first.answer);
}

static void secure_address(void) {
    g_autoptr(DinoDnsResolver) context = resolver();
    Request request = query(context, "good.dinox-test.", 1, 2500);
    g_assert_no_error(request.error);
    g_assert_cmpint(request.answer->validation, ==, DINO_DNS_SECURE);
    g_assert_cmpuint(request.answer->records->len, ==, 1);
    g_assert_cmpint(request.answer->expires_at, >, g_get_monotonic_time());
    GBytes *data = g_ptr_array_index(request.answer->records, 0);
    g_assert_cmpuint(g_bytes_get_size(data), ==, 4);
    dino_dns_answer_free(request.answer);
}

static void secure_tlsa(void) {
    g_autoptr(DinoDnsResolver) context = resolver();
    Request request = query(context, "_5222._tcp.good.dinox-test.", 52, 2500);
    g_assert_no_error(request.error);
    g_assert_cmpint(request.answer->validation, ==, DINO_DNS_SECURE);
    g_assert_cmpuint(request.answer->records->len, ==, 1);
    GBytes *data = g_ptr_array_index(request.answer->records, 0);
    g_assert_cmpuint(g_bytes_get_size(data), ==, 35);
    dino_dns_answer_free(request.answer);
}

static void secure_absence(void) {
    g_autoptr(DinoDnsResolver) context = resolver();
    Request request = query(context, "good.dinox-test.", 28, 2500);
    g_assert_no_error(request.error);
    g_assert_cmpint(request.answer->validation, ==, DINO_DNS_SECURE);
    g_assert_false(request.answer->nxdomain);
    g_assert_cmpuint(request.answer->records->len, ==, 0);
    dino_dns_answer_free(request.answer);
}

static void bogus(const gchar *name) {
    g_autoptr(DinoDnsResolver) context = resolver();
    Request request = query(context, name, 1, 2500);
    g_assert_no_error(request.error);
    g_assert_cmpint(request.answer->validation, ==, DINO_DNS_BOGUS);
    g_assert_cmpuint(request.answer->records->len, ==, 0);
    g_assert_cmpint(request.answer->expires_at, ==, 0);
    dino_dns_answer_free(request.answer);
}

static void broken_signature(void) { bogus("broken.dinox-test."); }
static void forged_ad(void) { bogus("forged.dinox-test."); }
static void forged_alias(void) { bogus("forged-alias.dinox-test."); }

static void secure_alias(void) {
    g_autoptr(DinoDnsResolver) context = resolver();
    Request request = query(context, "alias.dinox-test.", 1, 2500);
    g_assert_no_error(request.error);
    g_assert_cmpint(request.answer->validation, ==, DINO_DNS_SECURE);
    g_assert_cmpstr(request.answer->canonical_name, ==, "good.dinox-test.");
    g_assert_cmpuint(request.answer->records->len, ==, 1);
    dino_dns_answer_free(request.answer);
}

static void outage(void) {
    g_autoptr(DinoDnsResolver) context = resolver();
    Request request = query(context, "timeout.dinox-test.", 1, 200);
    g_assert_null(request.answer);
    g_assert_error(request.error, G_IO_ERROR, G_IO_ERROR_TIMED_OUT);
    g_clear_error(&request.error);
    /* The deadline ends this request, not a separate context's working lookup. */
    secure_address();
}

static void servfail(void) {
    g_autoptr(DinoDnsResolver) context = resolver();
    Request request = query(context, "servfail.dinox-test.", 1, 1000);
    g_assert_null(request.answer);
    g_assert_nonnull(request.error);
    g_assert_true(g_error_matches(request.error, G_IO_ERROR, G_IO_ERROR_FAILED) ||
                  g_error_matches(request.error, G_IO_ERROR, G_IO_ERROR_TIMED_OUT));
    g_clear_error(&request.error);
}

static void cancel_or_close(gboolean close_context) {
    g_autoptr(DinoDnsResolver) context = resolver();
    g_autoptr(GCancellable) cancel = g_cancellable_new();
    Request request = { .loop = g_main_loop_new(NULL, FALSE) };
    dino_dns_resolver_resolve_async(context, "timeout.dinox-test.", 1, 2000, cancel, complete, &request);
    if (close_context) dino_dns_resolver_close(context);
    else g_cancellable_cancel(cancel);
    g_main_loop_run(request.loop);
    g_assert_null(request.answer);
    g_assert_error(request.error, G_IO_ERROR, G_IO_ERROR_CANCELLED);
    g_clear_error(&request.error);
    g_main_loop_unref(request.loop);
    if (close_context) {
        request = query(context, "good.dinox-test.", 1, 1000);
        g_assert_error(request.error, G_IO_ERROR, G_IO_ERROR_CLOSED);
        g_clear_error(&request.error);
    }
}
static void cancelled(void) { cancel_or_close(FALSE); }
static void closed(void) { cancel_or_close(TRUE); }

int main(int argc, char **argv) {
    g_test_init(&argc, &argv, NULL);
    g_test_add_func("/DnsResolver/configuration", invalid_configuration);
    g_test_add_func("/DnsResolver/secure-address", secure_address);
    g_test_add_func("/DnsResolver/secure-tlsa", secure_tlsa);
    g_test_add_func("/DnsResolver/secure-absence", secure_absence);
    g_test_add_func("/DnsResolver/broken-signature", broken_signature);
    g_test_add_func("/DnsResolver/forged-ad", forged_ad);
    g_test_add_func("/DnsResolver/secure-alias", secure_alias);
    g_test_add_func("/DnsResolver/forged-alias", forged_alias);
    g_test_add_func("/DnsResolver/outage", outage);
    g_test_add_func("/DnsResolver/servfail", servfail);
    g_test_add_func("/DnsResolver/cancelled", cancelled);
    g_test_add_func("/DnsResolver/closed", closed);
    g_test_add_func("/DnsResolver/isolated-caches", isolated_caches);
    return g_test_run();
}
