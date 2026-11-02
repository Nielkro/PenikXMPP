#include "security/profile_restore_sync.h"
#include <gio/gio.h>
#include <glib/gstdio.h>
#include <errno.h>

#ifndef G_OS_WIN32
#include <sys/stat.h>
#include <unistd.h>

/* Linked with --wrap=fsync only in this standalone test executable. Verify the
 * actual production syscall path and propagate an injected disk error without
 * adding a production environment switch or replacing the file operations. */
static guint file_syncs;
static guint directory_syncs;
static gboolean fail_next_sync;
int __real_fsync(int fd);
int __wrap_fsync(int fd);

int
__wrap_fsync(int fd)
{
    struct stat info;
    g_assert_cmpint(fstat(fd, &info), ==, 0);
    if (S_ISREG(info.st_mode)) file_syncs++;
    if (S_ISDIR(info.st_mode)) directory_syncs++;
    if (fail_next_sync) {
        fail_next_sync = FALSE;
        errno = EIO;
        return -1;
    }
    return __real_fsync(fd);
}
#endif

typedef struct {
    gchar *root;
    gchar *stage;
    gchar *nested;
    gchar *database;
    gchar *key;
} Fixture;

static Fixture *
fixture_new(void)
{
    GError *error = NULL;
    Fixture *fixture = g_new0(Fixture, 1);
    fixture->root = g_dir_make_tmp("dinox-restore-sync-XXXXXX", &error);
    g_assert_no_error(error);
    fixture->stage = g_build_filename(fixture->root, "staged-profile", NULL);
    fixture->nested = g_build_filename(fixture->stage, "nested", NULL);
    fixture->database = g_build_filename(fixture->stage, "dino.db", NULL);
    fixture->key = g_build_filename(fixture->nested, "Schlüssel.key", NULL);
    g_assert_cmpint(g_mkdir_with_parents(fixture->nested, 0700), ==, 0);
    g_assert_true(g_file_set_contents(fixture->database, "new database", -1, &error));
    g_assert_no_error(error);
    g_assert_true(g_file_set_contents(fixture->key, "test-only key", -1, &error));
    g_assert_no_error(error);
    return fixture;
}

static void
remove_tree(GFile *file)
{
    GError *error = NULL;
    GFileInfo *info = g_file_query_info(file, G_FILE_ATTRIBUTE_STANDARD_TYPE,
                                      G_FILE_QUERY_INFO_NOFOLLOW_SYMLINKS, NULL, &error);
    g_assert_no_error(error);
    if (g_file_info_get_file_type(info) == G_FILE_TYPE_DIRECTORY) {
        GFileEnumerator *children = g_file_enumerate_children(file, G_FILE_ATTRIBUTE_STANDARD_NAME,
            G_FILE_QUERY_INFO_NOFOLLOW_SYMLINKS, NULL, &error);
        g_assert_no_error(error);
        GFileInfo *child_info;
        while ((child_info = g_file_enumerator_next_file(children, NULL, &error)) != NULL) {
            GFile *child = g_file_get_child(file, g_file_info_get_name(child_info));
            remove_tree(child);
            g_object_unref(child);
            g_object_unref(child_info);
        }
        g_assert_no_error(error);
        g_object_unref(children);
    }
    g_object_unref(info);
    g_assert_true(g_file_delete(file, NULL, &error));
    g_assert_no_error(error);
}

static void
fixture_free(Fixture *fixture)
{
    GFile *root = g_file_new_for_path(fixture->root);
    remove_tree(root);
    g_object_unref(root);
    g_free(fixture->root);
    g_free(fixture->stage);
    g_free(fixture->nested);
    g_free(fixture->database);
    g_free(fixture->key);
    g_free(fixture);
}

static void
test_flushes_payload_and_directories(void)
{
    Fixture *fixture = fixture_new();
    GError *error = NULL;
#ifndef G_OS_WIN32
    file_syncs = directory_syncs = 0;
#endif
    dino_profile_restore_sync_tree(fixture->stage, &error);
    g_assert_no_error(error);
#ifndef G_OS_WIN32
    g_assert_cmpuint(file_syncs, ==, 2);
    g_assert_cmpuint(directory_syncs, ==, 3);
#endif
    gchar *contents = NULL;
    g_assert_true(g_file_get_contents(fixture->key, &contents, NULL, &error));
    g_assert_no_error(error);
    g_assert_cmpstr(contents, ==, "test-only key");
    g_free(contents);
    fixture_free(fixture);
}

static void
test_rename_is_checked_and_durable(void)
{
    Fixture *fixture = fixture_new();
    gchar *destination = g_build_filename(fixture->root, "installed-profile", NULL);
    GError *error = NULL;
#ifndef G_OS_WIN32
    directory_syncs = 0;
#endif
    dino_profile_restore_rename_directory(fixture->stage, destination, &error);
    g_assert_no_error(error);
    g_assert_false(g_file_test(fixture->stage, G_FILE_TEST_EXISTS));
    g_assert_true(g_file_test(destination, G_FILE_TEST_IS_DIR));
#ifndef G_OS_WIN32
    g_assert_cmpuint(directory_syncs, ==, 1);
#endif
    g_assert_cmpint(g_mkdir(fixture->stage, 0700), ==, 0);
    dino_profile_restore_rename_directory(fixture->stage, destination, &error);
    g_assert_error(error, G_IO_ERROR, G_IO_ERROR_EXISTS);
    g_clear_error(&error);
    g_assert_true(g_file_test(fixture->stage, G_FILE_TEST_IS_DIR));
    gchar *database = g_build_filename(destination, "dino.db", NULL);
    g_assert_true(g_file_test(database, G_FILE_TEST_IS_REGULAR));
    g_free(database);
    g_free(destination);
    fixture_free(fixture);
}

static void
test_symlinks_are_not_followed(void)
{
    Fixture *fixture = fixture_new();
    gchar *alias = g_build_filename(fixture->stage, "alias", NULL);
    GFile *file = g_file_new_for_path(alias);
    GError *error = NULL;
    gboolean linked = g_file_make_symbolic_link(file, fixture->key, NULL, &error);
    g_object_unref(file);
#ifdef G_OS_WIN32
    if (!linked) {
        g_test_skip(error->message);
        g_clear_error(&error);
        g_free(alias);
        fixture_free(fixture);
        return;
    }
#endif
    g_assert_no_error(error);
    g_assert_true(linked);
    dino_profile_restore_sync_tree(fixture->stage, &error);
    g_assert_nonnull(error);
    g_clear_error(&error);
    g_assert_true(g_file_test(fixture->key, G_FILE_TEST_IS_REGULAR));
    g_free(alias);
    fixture_free(fixture);
}

static void
test_single_file_flush(void)
{
    Fixture *fixture = fixture_new();
    GError *error = NULL;
#ifndef G_OS_WIN32
    file_syncs = directory_syncs = 0;
#endif
    dino_profile_restore_sync_file(fixture->database, &error);
    g_assert_no_error(error);
#ifndef G_OS_WIN32
    g_assert_cmpuint(file_syncs, ==, 1);
    g_assert_cmpuint(directory_syncs, ==, 0);
#endif
    dino_profile_restore_sync_file(fixture->stage, &error);
    g_assert_error(error, G_IO_ERROR, G_IO_ERROR_INVALID_DATA);
    g_clear_error(&error);
    fixture_free(fixture);
}

static void
test_namespace_sync_has_explicit_platform_result(void)
{
    Fixture *fixture = fixture_new();
    GError *error = NULL;
#ifndef G_OS_WIN32
    directory_syncs = 0;
#endif
    dino_profile_restore_sync_directory(fixture->stage, &error);
#ifdef G_OS_WIN32
    g_assert_error(error, G_IO_ERROR, G_IO_ERROR_NOT_SUPPORTED);
    g_clear_error(&error);
#else
    g_assert_no_error(error);
    g_assert_cmpuint(directory_syncs, ==, 1);
#endif
    dino_profile_restore_sync_parent(fixture->database, &error);
#ifdef G_OS_WIN32
    g_assert_error(error, G_IO_ERROR, G_IO_ERROR_NOT_SUPPORTED);
    g_clear_error(&error);
#else
    g_assert_no_error(error);
    g_assert_cmpuint(directory_syncs, ==, 2);
#endif
    fixture_free(fixture);
}

#ifndef G_OS_WIN32
static void
test_hardlinks_are_rejected(void)
{
    Fixture *fixture = fixture_new();
    gchar *alias = g_build_filename(fixture->root, "other-key-owner", NULL);
    g_assert_cmpint(link(fixture->key, alias), ==, 0);
    GError *error = NULL;
    dino_profile_restore_sync_tree(fixture->stage, &error);
    g_assert_error(error, G_IO_ERROR, G_IO_ERROR_INVALID_DATA);
    g_clear_error(&error);
    g_assert_true(g_file_test(fixture->key, G_FILE_TEST_IS_REGULAR));
    g_free(alias);
    fixture_free(fixture);
}

static void
test_sync_error_is_propagated(void)
{
    Fixture *fixture = fixture_new();
    GError *error = NULL;
    fail_next_sync = TRUE;
    dino_profile_restore_sync_tree(fixture->stage, &error);
    g_assert_nonnull(error);
    g_clear_error(&error);
    g_assert_false(fail_next_sync);
    g_assert_true(g_file_test(fixture->database, G_FILE_TEST_IS_REGULAR));
    g_assert_true(g_file_test(fixture->key, G_FILE_TEST_IS_REGULAR));
    dino_profile_restore_sync_tree(fixture->stage, &error);
    g_assert_no_error(error);
    fixture_free(fixture);
}

static void
test_deleted_parent_and_retry_are_synchronized(void)
{
    Fixture *fixture = fixture_new();
    GError *error = NULL;
    g_assert_cmpint(g_unlink(fixture->key), ==, 0);
    directory_syncs = 0;
    dino_profile_restore_sync_parent(fixture->key, &error);
    g_assert_no_error(error);
    g_assert_cmpuint(directory_syncs, ==, 1);
    g_assert_cmpint(g_rmdir(fixture->nested), ==, 0);
    /* Simulate retry after unlink/rmdir succeeded but the prior parent fsync
     * failed. Synchronize the nearest surviving ancestor without recreating it. */
    dino_profile_restore_sync_parent(fixture->key, &error);
    g_assert_no_error(error);
    g_assert_cmpuint(directory_syncs, ==, 2);
    g_assert_false(g_file_test(fixture->nested, G_FILE_TEST_EXISTS));
    fail_next_sync = TRUE;
    dino_profile_restore_sync_parent(fixture->database, &error);
    g_assert_nonnull(error);
    g_clear_error(&error);
    g_assert_false(fail_next_sync);
    dino_profile_restore_sync_parent(fixture->database, &error);
    g_assert_no_error(error);
    fixture_free(fixture);
}
#endif

int
main(int argc, char **argv)
{
    g_test_init(&argc, &argv, NULL);
    g_test_add_func("/ProfileRestoreSync/payload_and_directories_are_flushed", test_flushes_payload_and_directories);
    g_test_add_func("/ProfileRestoreSync/rename_is_checked_and_durable", test_rename_is_checked_and_durable);
    g_test_add_func("/ProfileRestoreSync/symlinks_are_not_followed", test_symlinks_are_not_followed);
    g_test_add_func("/ProfileRestoreSync/single_file_flush", test_single_file_flush);
    g_test_add_func("/ProfileRestoreSync/namespace_sync_platform_result", test_namespace_sync_has_explicit_platform_result);
#ifndef G_OS_WIN32
    g_test_add_func("/ProfileRestoreSync/hardlinks_are_rejected", test_hardlinks_are_rejected);
    g_test_add_func("/ProfileRestoreSync/sync_failure_propagates", test_sync_error_is_propagated);
    g_test_add_func("/ProfileRestoreSync/deleted_parent_retry_is_synchronized", test_deleted_parent_and_retry_are_synchronized);
#endif
    return g_test_run();
}
