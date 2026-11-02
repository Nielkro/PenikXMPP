/* SPDX-License-Identifier: GPL-3.0-or-later */
#include "owned_process.h"
#include <glib/gstdio.h>
#include <stdio.h>
#include <string.h>
#ifdef G_OS_WIN32
#include <windows.h>
#else
#include <errno.h>
#include <signal.h>
#include <unistd.h>
#endif

static gchar *executable;

typedef struct {
    GMainLoop *loop;
    gboolean success;
    gboolean timed_out;
    GError *error;
    gboolean whole_tree;
} WaitResult;

static gboolean
timeout_wait(gpointer data)
{
    WaitResult *result = data;
    result->timed_out = TRUE;
    g_main_loop_quit(result->loop);
    return G_SOURCE_REMOVE;
}

static void
wait_finished(GObject *source, GAsyncResult *async_result, gpointer data)
{
    WaitResult *result = data;
    if (result->whole_tree)
        result->success = dino_tor_owned_process_stop_and_wait_finish(DINO_TOR_OWNED_PROCESS(source), async_result, &result->error);
    else
        result->success = dino_tor_owned_process_wait_finish(DINO_TOR_OWNED_PROCESS(source), async_result, &result->error);
    g_main_loop_quit(result->loop);
}

static gboolean
wait_for_owner(DinoTorOwnedProcess *owner, gboolean whole_tree,
               GCancellable *cancellable, GError **error)
{
    WaitResult result = { 0 };
    result.loop = g_main_loop_new(NULL, FALSE);
    result.whole_tree = whole_tree;
    guint timeout = g_timeout_add(4000, timeout_wait, &result);
    if (whole_tree) dino_tor_owned_process_stop_and_wait_async(owner, cancellable, wait_finished, &result);
    else dino_tor_owned_process_wait_async(owner, cancellable, wait_finished, &result);
    g_main_loop_run(result.loop);
    if (!result.timed_out) g_source_remove(timeout);
    g_assert_false(result.timed_out);
    g_main_loop_unref(result.loop);
    if (result.error != NULL) g_propagate_error(error, result.error);
    return result.success;
}

static DinoTorOwnedProcess *
spawn_fixture(const gchar *role, const gchar *argument, const gchar *cwd)
{
    const gchar *argv[] = { executable, role, argument, NULL };
    GError *error = NULL;
    DinoTorOwnedProcess *owner = dino_tor_owned_process_spawn(argv, cwd, &error);
    g_assert_no_error(error);
    g_assert_nonnull(owner);
    return owner;
}

static guint64
read_leaf_pid(DinoTorOwnedProcess *owner)
{
    GError *error = NULL;
    GDataInputStream *stream = g_data_input_stream_new(dino_tor_owned_process_get_stdout_pipe(owner));
    g_data_input_stream_set_newline_type(stream, G_DATA_STREAM_NEWLINE_TYPE_ANY);
    gchar *line = g_data_input_stream_read_line(stream, NULL, NULL, &error);
    g_assert_no_error(error);
    g_assert_nonnull(line);
    guint64 pid = g_ascii_strtoull(line, NULL, 10);
    g_assert_cmpuint(pid, >, 0);
    g_free(line);
    g_object_unref(stream);
    return pid;
}

static gboolean
process_is_alive(guint64 pid)
{
#ifdef G_OS_WIN32
    HANDLE process = OpenProcess(SYNCHRONIZE, FALSE, (DWORD) pid);
    if (process == NULL) return FALSE;
    gboolean alive = WaitForSingleObject(process, 0) == WAIT_TIMEOUT;
    CloseHandle(process);
    return alive;
#else
    gchar *path = g_strdup_printf("/proc/%" G_GUINT64_FORMAT "/stat", pid);
    gchar *stat = NULL;
    gboolean present = g_file_get_contents(path, &stat, NULL, NULL);
    g_free(path);
    if (!present) return FALSE;
    gchar *end = strrchr(stat, ')');
    gboolean alive = end != NULL && end[1] == ' ' && end[2] != 'Z' && end[2] != 'X';
    g_free(stat);
    return alive;
#endif
}

static void
test_exit_and_unicode_pipes(void)
{
    GError *error = NULL;
    gchar *directory = g_dir_make_tmp("dinox owned Unicode ä-XXXXXX", &error);
    g_assert_no_error(error);
    const gchar *argument = "ä space \\\" quoted \\";
    DinoTorOwnedProcess *owner = spawn_fixture("--fixture-echo", argument, directory);
    g_assert_true(wait_for_owner(owner, FALSE, NULL, &error));
    g_assert_no_error(error);
    g_assert_cmpint(dino_tor_owned_process_get_exit_status(owner), ==, 7);
    GDataInputStream *output = g_data_input_stream_new(dino_tor_owned_process_get_stdout_pipe(owner));
    g_data_input_stream_set_newline_type(output, G_DATA_STREAM_NEWLINE_TYPE_ANY);
    gchar *line = g_data_input_stream_read_line(output, NULL, NULL, &error);
    g_assert_no_error(error);
    g_assert_cmpstr(line, ==, argument);
    g_free(line);
    line = g_data_input_stream_read_line(output, NULL, NULL, &error);
    g_assert_no_error(error);
    g_assert_cmpstr(line, ==, directory);
    g_free(line);
    g_object_unref(output);
    GDataInputStream *errors = g_data_input_stream_new(dino_tor_owned_process_get_stderr_pipe(owner));
    g_data_input_stream_set_newline_type(errors, G_DATA_STREAM_NEWLINE_TYPE_ANY);
    line = g_data_input_stream_read_line(errors, NULL, NULL, &error);
    g_assert_no_error(error);
    g_assert_cmpstr(line, ==, "fixture stderr");
    g_free(line);
    g_object_unref(errors);
    g_assert_true(wait_for_owner(owner, TRUE, NULL, &error));
    g_assert_no_error(error);
    g_assert_true(dino_tor_owned_process_is_tree_drained(owner));
    g_object_unref(owner);
    g_assert_cmpint(g_rmdir(directory), ==, 0);
    g_free(directory);
}

static void
test_stubborn_tree_and_unrelated_process(void)
{
    GError *error = NULL;
    const gchar *other_argv[] = { executable, "--fixture-leaf", NULL };
    GSubprocess *other = g_subprocess_newv(other_argv, G_SUBPROCESS_FLAGS_STDOUT_SILENCE | G_SUBPROCESS_FLAGS_STDERR_SILENCE, &error);
    g_assert_no_error(error);
    DinoTorOwnedProcess *owner = spawn_fixture("--fixture-tree", NULL, NULL);
    guint64 leaf = read_leaf_pid(owner);
    g_assert_true(process_is_alive(leaf));
    dino_tor_owned_process_request_stop(owner);
    dino_tor_owned_process_request_stop(owner);
    g_assert_true(wait_for_owner(owner, TRUE, NULL, &error));
    g_assert_no_error(error);
    g_assert_true(dino_tor_owned_process_is_tree_drained(owner));
    g_assert_false(process_is_alive(leaf));
    g_assert_nonnull(g_subprocess_get_identifier(other));
    g_subprocess_force_exit(other);
    g_assert_true(g_subprocess_wait(other, NULL, &error));
    g_assert_no_error(error);
    g_object_unref(other);
    g_object_unref(owner);
}

static void
test_parent_exit_retires_transport(void)
{
    GError *error = NULL;
    DinoTorOwnedProcess *owner = spawn_fixture("--fixture-orphan", NULL, NULL);
    guint64 leaf = read_leaf_pid(owner);
    g_assert_true(wait_for_owner(owner, FALSE, NULL, &error));
    g_assert_no_error(error);
    g_assert_cmpint(dino_tor_owned_process_get_exit_status(owner), ==, 0);
    g_assert_true(wait_for_owner(owner, TRUE, NULL, &error));
    g_assert_no_error(error);
    g_assert_false(process_is_alive(leaf));
    g_assert_true(dino_tor_owned_process_is_tree_drained(owner));
    g_object_unref(owner);
}

static void
test_cancelled_wait_keeps_owner_cleanup(void)
{
    GError *error = NULL;
    DinoTorOwnedProcess *owner = spawn_fixture("--fixture-tree", NULL, NULL);
    guint64 leaf = read_leaf_pid(owner);
    GCancellable *cancellable = g_cancellable_new();
    g_cancellable_cancel(cancellable);
    g_assert_false(wait_for_owner(owner, FALSE, cancellable, &error));
    g_assert_error(error, G_IO_ERROR, G_IO_ERROR_CANCELLED);
    g_clear_error(&error);
    g_assert_true(process_is_alive(leaf));
    g_assert_true(wait_for_owner(owner, TRUE, NULL, &error));
    g_assert_no_error(error);
    g_assert_false(process_is_alive(leaf));
    g_object_unref(cancellable);
    g_object_unref(owner);
}

static void
test_spawn_failure_is_closed(void)
{
    GError *error = NULL;
    const gchar *argv[] = { "/missing/dinox-owned-process", NULL };
    DinoTorOwnedProcess *owner = dino_tor_owned_process_spawn(argv, NULL, &error);
    g_assert_null(owner);
    g_assert_nonnull(error);
    g_clear_error(&error);
}

typedef struct {
    GMainLoop *loop;
    guint finished;
} ConcurrentWait;

static void
concurrent_parent_finished(GObject *source, GAsyncResult *result, gpointer data)
{
    ConcurrentWait *wait = data;
    GError *error = NULL;
    g_assert_true(dino_tor_owned_process_wait_finish(DINO_TOR_OWNED_PROCESS(source), result, &error));
    g_assert_no_error(error);
    if (++wait->finished == 2) g_main_loop_quit(wait->loop);
}

static void
concurrent_tree_finished(GObject *source, GAsyncResult *result, gpointer data)
{
    ConcurrentWait *wait = data;
    GError *error = NULL;
    g_assert_true(dino_tor_owned_process_stop_and_wait_finish(DINO_TOR_OWNED_PROCESS(source), result, &error));
    g_assert_no_error(error);
    g_assert_true(dino_tor_owned_process_is_tree_drained(DINO_TOR_OWNED_PROCESS(source)));
    if (++wait->finished == 2) g_main_loop_quit(wait->loop);
}

static void
test_concurrent_monitor_and_stop(void)
{
    DinoTorOwnedProcess *owner = spawn_fixture("--fixture-tree", NULL, NULL);
    guint64 leaf = read_leaf_pid(owner);
    ConcurrentWait wait = { g_main_loop_new(NULL, FALSE), 0 };
    dino_tor_owned_process_wait_async(owner, NULL, concurrent_parent_finished, &wait);
    dino_tor_owned_process_stop_and_wait_async(owner, NULL, concurrent_tree_finished, &wait);
    g_main_loop_run(wait.loop);
    g_assert_cmpuint(wait.finished, ==, 2);
    g_assert_false(process_is_alive(leaf));
    g_main_loop_unref(wait.loop);
    g_object_unref(owner);
}

static void
test_last_owner_release_stops_tree(void)
{
    DinoTorOwnedProcess *owner = spawn_fixture("--fixture-tree", NULL, NULL);
    guint64 leaf = read_leaf_pid(owner);
    g_object_unref(owner);
    g_assert_false(process_is_alive(leaf));
}

int
main(int argc, char **argv)
{
#ifdef G_OS_WIN32
    /* The CRT narrow argv can use the system code page. The production
     * launcher uses CreateProcessW, so test its actual Unicode arguments. */
    argv = g_win32_get_command_line();
    argc = (gint) g_strv_length(argv);
#endif
    executable = g_canonicalize_filename(argv[0], NULL);
    if (argc >= 2 && g_str_equal(argv[1], "--fixture-echo")) {
        puts(argc >= 3 ? argv[2] : "");
        gchar *cwd = g_get_current_dir();
        puts(cwd);
        g_free(cwd);
        fputs("fixture stderr\n", stderr);
        g_free(executable);
        return 7;
    }
    if (argc >= 2 && (g_str_equal(argv[1], "--fixture-tree") ||
                     g_str_equal(argv[1], "--fixture-orphan") ||
                     g_str_equal(argv[1], "--fixture-leaf"))) {
#ifndef G_OS_WIN32
        signal(SIGTERM, SIG_IGN);
#endif
        if (!g_str_equal(argv[1], "--fixture-leaf")) {
            GError *error = NULL;
            GPid child;
            gchar *child_argv[] = { executable, "--fixture-leaf", NULL };
            gboolean spawned = g_spawn_async(NULL, child_argv, NULL,
                G_SPAWN_DO_NOT_REAP_CHILD | G_SPAWN_STDOUT_TO_DEV_NULL | G_SPAWN_STDERR_TO_DEV_NULL,
                NULL, NULL, &child, &error);
            g_assert_no_error(error);
            g_assert_true(spawned);
#ifdef G_OS_WIN32
            printf("%lu\n", (gulong) GetProcessId(child));
#else
            printf("%d\n", (gint) child);
#endif
            fflush(stdout);
            if (g_str_equal(argv[1], "--fixture-orphan")) return 0;
        }
        for (;;) g_usleep(100 * G_TIME_SPAN_MILLISECOND);
    }
    g_test_init(&argc, &argv, NULL);
    g_test_add_func("/TorOwnedProcess/exit_unicode_cwd_pipes_and_status", test_exit_and_unicode_pipes);
    g_test_add_func("/TorOwnedProcess/stubborn_tree_drain_preserves_unrelated_process", test_stubborn_tree_and_unrelated_process);
    g_test_add_func("/TorOwnedProcess/parent_exit_retires_transport", test_parent_exit_retires_transport);
    g_test_add_func("/TorOwnedProcess/cancelled_wait_still_allows_tree_cleanup", test_cancelled_wait_keeps_owner_cleanup);
    g_test_add_func("/TorOwnedProcess/spawn_failure_is_closed", test_spawn_failure_is_closed);
    g_test_add_func("/TorOwnedProcess/concurrent_monitor_and_stop_share_exit_state", test_concurrent_monitor_and_stop);
    g_test_add_func("/TorOwnedProcess/last_owner_release_stops_tree", test_last_owner_release_stops_tree);
    gint result = g_test_run();
    g_free(executable);
    return result;
}
