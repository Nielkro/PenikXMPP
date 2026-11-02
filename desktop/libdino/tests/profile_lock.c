#ifndef _GNU_SOURCE
#define _GNU_SOURCE
#endif

#include "security/profile_lock.h"
#include <gio/gio.h>
#include <glib/gstdio.h>
#include <stdio.h>
#include <string.h>

#ifdef G_OS_WIN32
#include <windows.h>
#include <glib/gwin32.h>
#else
#include <unistd.h>
#endif

/* These are OS-lock tests, not a second implementation or an in-process mock.
 * All acquisitions happen in separate executables, without user DB/key access. */
static gchar *self_executable;

typedef struct {
    GSubprocess *process;
    GDataInputStream *output;
    gchar *first_line;
} Child;

static gchar *
read_line(Child *child)
{
    GError *error = NULL;
    gchar *line = g_data_input_stream_read_line(child->output, NULL, NULL, &error);
    g_assert_no_error(error);
    g_assert_nonnull(line);
    return line;
}

static Child *
spawn_child(const gchar *directory, const gchar *mode)
{
    GError *error = NULL;
    Child *child = g_new0(Child, 1);
    child->process = g_subprocess_new(G_SUBPROCESS_FLAGS_STDIN_PIPE |
                                     G_SUBPROCESS_FLAGS_STDOUT_PIPE |
                                     G_SUBPROCESS_FLAGS_STDERR_PIPE, &error,
                                     self_executable, "--child", directory, mode, NULL);
    g_assert_no_error(error);
    g_assert_nonnull(child->process);
    child->output = g_data_input_stream_new(g_subprocess_get_stdout_pipe(child->process));
    g_data_input_stream_set_newline_type(child->output, G_DATA_STREAM_NEWLINE_TYPE_ANY);
    child->first_line = read_line(child);
    return child;
}

static void
finish_child(Child *child, gboolean success)
{
    GError *error = NULL;
    g_assert_true(g_output_stream_close(g_subprocess_get_stdin_pipe(child->process), NULL, &error));
    g_assert_no_error(error);
    g_assert_true(g_subprocess_wait(child->process, NULL, &error));
    g_assert_no_error(error);
    g_assert_cmpint(g_subprocess_get_successful(child->process), ==, success);
    g_clear_object(&child->output);
    g_clear_object(&child->process);
    g_free(child->first_line);
    g_free(child);
}

static void
assert_blocked(const gchar *directory)
{
    Child *child = spawn_child(directory, "once");
    gchar *expected = g_strdup_printf("ERROR:%d", G_IO_ERROR_BUSY);
    g_assert_cmpstr(child->first_line, ==, expected);
    g_free(expected);
    finish_child(child, FALSE);
}

static void
assert_available(const gchar *directory)
{
    Child *child = spawn_child(directory, "once");
    g_assert_cmpstr(child->first_line, ==, "LOCKED");
    finish_child(child, TRUE);
}

static gchar *
new_root(void)
{
    GError *error = NULL;
    gchar *root = g_dir_make_tmp("dinox-profile-lock-XXXXXX", &error);
    g_assert_no_error(error);
    return root;
}

static void
remove_file_tree(GFile *file)
{
    GError *error = NULL;
    GFileInfo *info = g_file_query_info(file, G_FILE_ATTRIBUTE_STANDARD_TYPE,
                                      G_FILE_QUERY_INFO_NOFOLLOW_SYMLINKS, NULL, &error);
    g_assert_no_error(error);
    if (g_file_info_get_file_type(info) == G_FILE_TYPE_DIRECTORY) {
        GFileEnumerator *enumerator = g_file_enumerate_children(file,
            G_FILE_ATTRIBUTE_STANDARD_NAME, G_FILE_QUERY_INFO_NOFOLLOW_SYMLINKS, NULL, &error);
        g_assert_no_error(error);
        GFileInfo *entry;
        while ((entry = g_file_enumerator_next_file(enumerator, NULL, &error)) != NULL) {
            GFile *child = g_file_get_child(file, g_file_info_get_name(entry));
            remove_file_tree(child);
            g_object_unref(child);
            g_object_unref(entry);
        }
        g_assert_no_error(error);
        g_object_unref(enumerator);
    }
    g_object_unref(info);
    g_assert_true(g_file_delete(file, NULL, &error));
    g_assert_no_error(error);
}

static void
remove_root(gchar *root)
{
    GFile *file = g_file_new_for_path(root);
    remove_file_tree(file);
    g_object_unref(file);
    g_free(root);
}

static gboolean
make_link(const gchar *alias, const gchar *target)
{
    GError *error = NULL;
    GFile *file = g_file_new_for_path(alias);
    gboolean success = g_file_make_symbolic_link(file, target, NULL, &error);
    g_object_unref(file);
#ifdef G_OS_WIN32
    if (!success) {
        /* Windows installations may require Developer Mode or administrator
         * rights for symlinks; the remaining process/Unicode tests still run. */
        g_test_skip(error->message);
        g_clear_error(&error);
        return FALSE;
    }
#endif
    g_assert_no_error(error);
    g_assert_true(success);
    return success;
}

static void
test_exclusion_and_normal_exit(void)
{
    gchar *root = new_root();
    gchar *profile = g_build_filename(root, "first-start", "dinox", NULL);
    gchar *with_separator = g_strconcat(profile, G_DIR_SEPARATOR_S, NULL);
    gchar *lock_file = g_strconcat(profile, ".lock", NULL);
    Child *owner = spawn_child(with_separator, "hold");
    g_assert_cmpstr(owner->first_line, ==, "LOCKED");
    g_assert_false(g_file_test(profile, G_FILE_TEST_EXISTS));
    g_assert_true(g_file_test(lock_file, G_FILE_TEST_IS_REGULAR));
    assert_blocked(profile);
    finish_child(owner, TRUE);
    g_assert_true(g_file_test(lock_file, G_FILE_TEST_IS_REGULAR));
    assert_available(profile);
    g_assert_false(g_file_test(profile, G_FILE_TEST_EXISTS));
    g_free(profile);
    g_free(with_separator);
    g_free(lock_file);
    remove_root(root);
}

static void
test_crash_releases_stale_file(void)
{
    gchar *root = new_root();
    gchar *profile = g_build_filename(root, "dinox", NULL);
    Child *owner = spawn_child(profile, "hold");
    g_assert_cmpstr(owner->first_line, ==, "LOCKED");
    g_subprocess_force_exit(owner->process);
    /* force_exit is asynchronous. Keep stdin open until the forced death,
     * otherwise finish_child's EOF can let the child exit normally first. */
    GError *error = NULL;
    g_assert_true(g_subprocess_wait(owner->process, NULL, &error));
    g_assert_no_error(error);
    finish_child(owner, FALSE);
    assert_available(profile);
    g_free(profile);
    remove_root(root);
}

static void
test_different_and_unicode_profiles(void)
{
    gchar *root = new_root();
    gchar *first = g_build_filename(root, "DinoX-ä-聊天", NULL);
    gchar *second = g_build_filename(root, "other-profile", NULL);
    Child *owner = spawn_child(first, "hold");
    Child *other = spawn_child(second, "hold");
    g_assert_cmpstr(owner->first_line, ==, "LOCKED");
    g_assert_cmpstr(other->first_line, ==, "LOCKED");
    assert_blocked(first);
    assert_blocked(second);
    finish_child(other, TRUE);
    finish_child(owner, TRUE);
    g_free(first);
    g_free(second);
    remove_root(root);
}

static void
test_existing_profile_alias(void)
{
    gchar *root = new_root();
    gchar *profile = g_build_filename(root, "physical", NULL);
    gchar *alias = g_build_filename(root, "alias", NULL);
    g_assert_cmpint(g_mkdir(profile, 0700), ==, 0);
    if (make_link(alias, profile)) {
        Child *owner = spawn_child(profile, "hold");
        g_assert_cmpstr(owner->first_line, ==, "LOCKED");
        assert_blocked(alias);
        finish_child(owner, TRUE);
        assert_available(alias);
    }
    g_free(alias);
    g_free(profile);
    remove_root(root);
}

static void
test_missing_profile_parent_alias(void)
{
    gchar *root = new_root();
    gchar *parent = g_build_filename(root, "physical-parent", NULL);
    gchar *alias = g_build_filename(root, "parent-alias", NULL);
    gchar *profile = g_build_filename(parent, "dinox", NULL);
    gchar *aliased_profile = g_build_filename(alias, "dinox", NULL);
    g_assert_cmpint(g_mkdir(parent, 0700), ==, 0);
    if (make_link(alias, parent)) {
        Child *owner = spawn_child(profile, "hold");
        g_assert_cmpstr(owner->first_line, ==, "LOCKED");
        assert_blocked(aliased_profile);
        g_assert_false(g_file_test(profile, G_FILE_TEST_EXISTS));
        finish_child(owner, TRUE);
    }
    g_free(parent);
    g_free(alias);
    g_free(profile);
    g_free(aliased_profile);
    remove_root(root);
}

static void
test_missing_profile_final_alias(void)
{
    gchar *root = new_root();
    gchar *profile = g_build_filename(root, "physical-parent", "dinox", NULL);
    gchar *alias = g_build_filename(root, "profile-alias", NULL);
    if (make_link(alias, profile)) {
        Child *owner = spawn_child(profile, "hold");
        g_assert_cmpstr(owner->first_line, ==, "LOCKED");
#ifdef G_OS_WIN32
        /* A dangling Windows reparse point must fail closed, even when its
         * target cannot be resolved with a directory handle. */
        Child *other = spawn_child(alias, "once");
        g_assert_true(g_str_has_prefix(other->first_line, "ERROR:"));
        finish_child(other, FALSE);
#else
        assert_blocked(alias);
#endif
        finish_child(owner, TRUE);
        g_assert_false(g_file_test(profile, G_FILE_TEST_EXISTS));
    }
    g_free(alias);
    g_free(profile);
    remove_root(root);
}

static void
test_profile_replacement_cannot_bypass_lock(void)
{
    gchar *root = new_root();
    gchar *profile = g_build_filename(root, "dinox", NULL);
    gchar *old_profile = g_build_filename(root, "old-profile", NULL);
    g_assert_cmpint(g_mkdir(profile, 0700), ==, 0);
    Child *owner = spawn_child(profile, "hold");
    g_assert_cmpstr(owner->first_line, ==, "LOCKED");
    g_assert_cmpint(g_rename(profile, old_profile), ==, 0);
    /* The crash-recovery interval with no active directory is also protected. */
    assert_blocked(profile);
    g_assert_false(g_file_test(profile, G_FILE_TEST_EXISTS));
    g_assert_cmpint(g_mkdir(profile, 0700), ==, 0);
    assert_blocked(profile);
    finish_child(owner, TRUE);
    assert_available(profile);
    g_free(profile);
    g_free(old_profile);
    remove_root(root);
}

static void
test_file_instead_of_profile_fails_closed(void)
{
    GError *error = NULL;
    gchar *root = new_root();
    gchar *profile = g_build_filename(root, "dinox", NULL);
    g_assert_true(g_file_set_contents(profile, "not-a-directory", -1, &error));
    g_assert_no_error(error);
    Child *child = spawn_child(profile, "once");
    gchar *expected = g_strdup_printf("ERROR:%d", G_IO_ERROR_NOT_DIRECTORY);
    g_assert_cmpstr(child->first_line, ==, expected);
    finish_child(child, FALSE);
    g_free(expected);
    g_free(profile);
    remove_root(root);
}

static void
test_lock_symlink_fails_closed(void)
{
    GError *error = NULL;
    gchar *root = new_root();
    gchar *profile = g_build_filename(root, "dinox", NULL);
    gchar *lock_file = g_strconcat(profile, ".lock", NULL);
    gchar *target = g_build_filename(root, "some-other-file", NULL);
    g_assert_true(g_file_set_contents(target, "unchanged", -1, &error));
    g_assert_no_error(error);
    if (make_link(lock_file, target)) {
        Child *child = spawn_child(profile, "once");
        g_assert_true(g_str_has_prefix(child->first_line, "ERROR:"));
        finish_child(child, FALSE);
        gchar *contents = NULL;
        g_assert_true(g_file_get_contents(target, &contents, NULL, &error));
        g_assert_no_error(error);
        g_assert_cmpstr(contents, ==, "unchanged");
        g_free(contents);
    }
    g_free(profile);
    g_free(lock_file);
    g_free(target);
    remove_root(root);
}

static void
test_exec_child_does_not_inherit_lock(void)
{
    gchar *root = new_root();
    gchar *profile = g_build_filename(root, "dinox", NULL);
    Child *owner = spawn_child(profile, "inherit");
    g_assert_cmpstr(owner->first_line, ==, "LOCKED");
    gchar *line = read_line(owner);
    g_assert_cmpstr(line, ==, "LINGER");
    g_free(line);
    GError *error = NULL;
    g_assert_true(g_subprocess_wait_check(owner->process, NULL, &error));
    g_assert_no_error(error);
    /* The original lock owner is gone, but its actual exec/CreateProcess child
     * is still alive. The spawn path deliberately inherits all eligible handles
     * rather than relying on GLib's normal close-descriptors behavior. */
    assert_available(profile);
    g_assert_true(g_output_stream_close(g_subprocess_get_stdin_pipe(owner->process), NULL, &error));
    g_assert_no_error(error);
    line = read_line(owner);
    g_assert_cmpstr(line, ==, "DONE");
    g_free(line);
    finish_child(owner, TRUE);
    g_free(profile);
    remove_root(root);
}

static gboolean
spawn_inheriting_linger(void)
{
#ifdef G_OS_WIN32
    gchar *command = g_strdup_printf("\"%s\" --linger", self_executable);
    gunichar2 *wide_command = g_utf8_to_utf16(command, -1, NULL, NULL, NULL);
    g_free(command);
    if (wide_command == NULL)
        return FALSE;
    STARTUPINFOW startup = {0};
    PROCESS_INFORMATION process = {0};
    startup.cb = sizeof(startup);
    startup.dwFlags = STARTF_USESTDHANDLES;
    startup.hStdInput = GetStdHandle(STD_INPUT_HANDLE);
    startup.hStdOutput = GetStdHandle(STD_OUTPUT_HANDLE);
    startup.hStdError = GetStdHandle(STD_ERROR_HANDLE);
    SetHandleInformation(startup.hStdInput, HANDLE_FLAG_INHERIT, HANDLE_FLAG_INHERIT);
    SetHandleInformation(startup.hStdOutput, HANDLE_FLAG_INHERIT, HANDLE_FLAG_INHERIT);
    SetHandleInformation(startup.hStdError, HANDLE_FLAG_INHERIT, HANDLE_FLAG_INHERIT);
    gboolean success = CreateProcessW(NULL, (LPWSTR) wide_command, NULL, NULL, TRUE,
                                     0, NULL, NULL, &startup, &process);
    g_free(wide_command);
    if (success) {
        CloseHandle(process.hThread);
        CloseHandle(process.hProcess);
    }
    return success;
#else
    pid_t pid = fork();
    if (pid == 0) {
        execl(self_executable, self_executable, "--linger", (char *) NULL);
        _exit(127);
    }
    return pid > 0;
#endif
}

int
main(int argc, char **argv)
{
#ifdef G_OS_WIN32
    /* Match the production application's GetCommandLineW-backed UTF-8 args;
     * MinGW's CRT argv can lose Unicode before our native UTF-16 conversion. */
    g_auto(GStrv) utf8_argv = g_win32_get_command_line();
    argv = utf8_argv;
    argc = (int) g_strv_length(argv);
#endif
    self_executable = g_canonicalize_filename(argv[0], NULL);
    if (argc == 2 && g_str_equal(argv[1], "--linger")) {
        puts("LINGER");
        fflush(stdout);
        (void) fgetc(stdin);
        puts("DONE");
        fflush(stdout);
        g_free(self_executable);
        return 0;
    }
    if (argc == 4 && g_str_equal(argv[1], "--child")) {
        GError *error = NULL;
        gchar *physical = dino_profile_lock_acquire_native(argv[2], &error);
        if (physical == NULL) {
            g_assert_nonnull(error);
            g_assert_cmpuint(error->domain, ==, G_IO_ERROR);
            printf("ERROR:%d\n", error->code);
            fflush(stdout);
            g_clear_error(&error);
            g_free(self_executable);
            return 2;
        }
        /* Repeated acquisition is idempotent in the owner process. Freeing all
         * returned values cannot release its process-owned native handle. */
        gchar *again = dino_profile_lock_acquire_native(argv[2], &error);
        g_assert_no_error(error);
        g_assert_cmpstr(physical, ==, again);
        g_free(physical);
        g_free(again);
        puts("LOCKED");
        fflush(stdout);
        if (g_str_equal(argv[3], "hold"))
            (void) fgetc(stdin);
        else if (g_str_equal(argv[3], "inherit") && !spawn_inheriting_linger())
            return 3;
        g_free(self_executable);
        return 0;
    }

    g_test_init(&argc, &argv, NULL);
    g_test_add_func("/ProfileLock/separate_process_exclusion_and_normal_exit", test_exclusion_and_normal_exit);
    g_test_add_func("/ProfileLock/crash_releases_stale_file", test_crash_releases_stale_file);
    g_test_add_func("/ProfileLock/independent_unicode_profiles", test_different_and_unicode_profiles);
    g_test_add_func("/ProfileLock/existing_profile_symlink", test_existing_profile_alias);
    g_test_add_func("/ProfileLock/missing_profile_parent_symlink", test_missing_profile_parent_alias);
    g_test_add_func("/ProfileLock/missing_profile_final_symlink", test_missing_profile_final_alias);
    g_test_add_func("/ProfileLock/profile_swap_preserves_exclusion", test_profile_replacement_cannot_bypass_lock);
    g_test_add_func("/ProfileLock/non_directory_fails_closed", test_file_instead_of_profile_fails_closed);
    g_test_add_func("/ProfileLock/lock_symlink_fails_closed", test_lock_symlink_fails_closed);
    g_test_add_func("/ProfileLock/exec_does_not_inherit", test_exec_child_does_not_inherit_lock);
    int result = g_test_run();
    g_free(self_executable);
    return result;
}
