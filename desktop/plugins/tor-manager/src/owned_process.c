/* SPDX-License-Identifier: GPL-3.0-or-later
 * Own one Tor process and all of its managed transports.
 */
#if defined(_WIN32)
/* Atomic job assignment requires the supported Windows 10 SDK declarations.
 * Set this unit's target before GIO can include Windows headers. */
#if !defined(_WIN32_WINNT) || _WIN32_WINNT < 0x0A00
#undef _WIN32_WINNT
#define _WIN32_WINNT 0x0A00
#endif
#if !defined(WINVER) || WINVER < _WIN32_WINNT
#undef WINVER
#define WINVER _WIN32_WINNT
#endif
#endif
#if !defined(_WIN32) && !defined(_POSIX_C_SOURCE)
#define _POSIX_C_SOURCE 200809L
#endif
#include "owned_process.h"
#include <string.h>

#ifdef G_OS_WIN32
#include <windows.h>
#include <gio/gwin32inputstream.h>
#else
#include <errno.h>
#include <signal.h>
#include <sys/wait.h>
#include <unistd.h>
#include <gio/gunixinputstream.h>
#endif

#define STOP_GRACE_US (1500 * G_TIME_SPAN_MILLISECOND)
#define STOP_DEADLINE_US (2500 * G_TIME_SPAN_MILLISECOND)
#define POLL_US (10 * G_TIME_SPAN_MILLISECOND)

struct _DinoTorOwnedProcess {
    GObject parent_instance;
    GMutex mutex;
    GCond changed;
    GThread *supervisor;
    GInputStream *stdout_pipe;
    GInputStream *stderr_pipe;
    gchar *identifier;
    gboolean parent_exited;
    gboolean parent_reaped;
    gboolean tree_drained;
    gboolean stop_deadline_reached;
    gint exit_status;
    gint64 stop_requested_us;
    gboolean killed;
    GError *failure;
#ifdef G_OS_WIN32
    HANDLE process;
    HANDLE job;
#else
    GPid pid;
#endif
};

G_DEFINE_TYPE(DinoTorOwnedProcess, dino_tor_owned_process, G_TYPE_OBJECT)

#ifdef G_OS_WIN32
static void
set_windows_error(GError **error, const gchar *operation)
{
    DWORD code = GetLastError();
    gchar *message = g_win32_error_message(code);
    g_set_error(error, G_IO_ERROR, g_io_error_from_win32_error(code),
                "%s: %s (Windows error %lu)", operation, message, (gulong) code);
    g_free(message);
}

/* Quote for the Windows CRT argv parser; no shell participates. */
static void
append_windows_argument(GString *command, const gchar *argument)
{
    guint backslashes = 0;
    g_string_append_c(command, '"');
    for (const gchar *cursor = argument; *cursor != '\0'; cursor++) {
        if (*cursor == '\\') {
            backslashes++;
            continue;
        }
        guint count = *cursor == '"' ? backslashes * 2 + 1 : backslashes;
        for (guint i = 0; i < count; i++) g_string_append_c(command, '\\');
        backslashes = 0;
        g_string_append_c(command, *cursor);
    }
    for (guint i = 0; i < backslashes * 2; i++) g_string_append_c(command, '\\');
    g_string_append_c(command, '"');
}

static gboolean
spawn_native(DinoTorOwnedProcess *self, const gchar *const *argv,
             const gchar *cwd, GError **error)
{
    SECURITY_ATTRIBUTES security = { sizeof(SECURITY_ATTRIBUTES), NULL, TRUE };
    HANDLE out_read = NULL, out_write = NULL, err_read = NULL, err_write = NULL;
    HANDLE input = INVALID_HANDLE_VALUE;
    HANDLE child_handles[3];
    JOBOBJECT_EXTENDED_LIMIT_INFORMATION limits = { 0 };
    STARTUPINFOEXW startup = { 0 };
    PROCESS_INFORMATION process = { 0 };
    SIZE_T attribute_size = 0;
    LPPROC_THREAD_ATTRIBUTE_LIST attributes = NULL;
    gboolean attributes_initialized = FALSE;
    GString *command = g_string_new(NULL);
    gunichar2 *wide_command = NULL, *wide_executable = NULL, *wide_cwd = NULL;
    gboolean created = FALSE;

    for (guint i = 0; argv[i] != NULL; i++) {
        if (i != 0) g_string_append_c(command, ' ');
        append_windows_argument(command, argv[i]);
    }
    wide_command = g_utf8_to_utf16(command->str, -1, NULL, NULL, error);
    if (wide_command == NULL) goto out;
    wide_executable = g_utf8_to_utf16(argv[0], -1, NULL, NULL, error);
    if (wide_executable == NULL) goto out;
    if (cwd != NULL) {
        wide_cwd = g_utf8_to_utf16(cwd, -1, NULL, NULL, error);
        if (wide_cwd == NULL) goto out;
    }
    self->job = CreateJobObjectW(NULL, NULL);
    if (self->job == NULL) { set_windows_error(error, "CreateJobObjectW"); goto out; }
    limits.BasicLimitInformation.LimitFlags = JOB_OBJECT_LIMIT_KILL_ON_JOB_CLOSE;
    if (!SetInformationJobObject(self->job, JobObjectExtendedLimitInformation,
                                 &limits, sizeof(limits))) {
        set_windows_error(error, "SetInformationJobObject"); goto out;
    }
    if (!CreatePipe(&out_read, &out_write, &security, 0) ||
        !CreatePipe(&err_read, &err_write, &security, 0) ||
        !SetHandleInformation(out_read, HANDLE_FLAG_INHERIT, 0) ||
        !SetHandleInformation(err_read, HANDLE_FLAG_INHERIT, 0)) {
        set_windows_error(error, "Create child output pipes"); goto out;
    }
    input = CreateFileW(L"NUL", GENERIC_READ, FILE_SHARE_READ | FILE_SHARE_WRITE,
                        &security, OPEN_EXISTING, FILE_ATTRIBUTE_NORMAL, NULL);
    if (input == INVALID_HANDLE_VALUE) { set_windows_error(error, "Open child stdin"); goto out; }
    child_handles[0] = input;
    child_handles[1] = out_write;
    child_handles[2] = err_write;
    InitializeProcThreadAttributeList(NULL, 2, 0, &attribute_size);
    if (attribute_size == 0) {
        set_windows_error(error, "Measure process attribute list"); goto out;
    }
    attributes = g_malloc0(attribute_size);
    if (!InitializeProcThreadAttributeList(attributes, 2, 0, &attribute_size)) {
        set_windows_error(error, "InitializeProcThreadAttributeList"); goto out;
    }
    attributes_initialized = TRUE;
    /* Windows 10: assignment is atomic, before Tor can launch Lyrebird.
     * Only stdio handles are inherited; the kill-on-close job stays ours. */
    if (!UpdateProcThreadAttribute(attributes, 0, PROC_THREAD_ATTRIBUTE_JOB_LIST,
                                   &self->job, sizeof(self->job), NULL, NULL) ||
        !UpdateProcThreadAttribute(attributes, 0, PROC_THREAD_ATTRIBUTE_HANDLE_LIST,
                                   child_handles, sizeof(child_handles), NULL, NULL)) {
        set_windows_error(error, "Configure process job and inherited handles"); goto out;
    }
    startup.StartupInfo.cb = sizeof(startup);
    startup.StartupInfo.dwFlags = STARTF_USESTDHANDLES;
    startup.StartupInfo.hStdInput = input;
    startup.StartupInfo.hStdOutput = out_write;
    startup.StartupInfo.hStdError = err_write;
    startup.lpAttributeList = attributes;
    if (!CreateProcessW((LPCWSTR) wide_executable, (LPWSTR) wide_command,
                         NULL, NULL, TRUE,
                         CREATE_NO_WINDOW | EXTENDED_STARTUPINFO_PRESENT,
                         NULL, (LPCWSTR) wide_cwd, &startup.StartupInfo, &process)) {
        set_windows_error(error, "CreateProcessW in Tor job"); goto out;
    }
    self->process = process.hProcess;
    self->identifier = g_strdup_printf("%lu", (gulong) process.dwProcessId);
    CloseHandle(process.hThread);
    self->stdout_pipe = g_win32_input_stream_new(out_read, TRUE);
    self->stderr_pipe = g_win32_input_stream_new(err_read, TRUE);
    out_read = err_read = NULL;
    created = TRUE;
out:
    if (attributes != NULL) {
        if (attributes_initialized) DeleteProcThreadAttributeList(attributes);
        g_free(attributes);
    }
    if (input != INVALID_HANDLE_VALUE) CloseHandle(input);
    if (out_read != NULL) CloseHandle(out_read);
    if (out_write != NULL) CloseHandle(out_write);
    if (err_read != NULL) CloseHandle(err_read);
    if (err_write != NULL) CloseHandle(err_write);
    g_free(wide_command);
    g_free(wide_executable);
    g_free(wide_cwd);
    g_string_free(command, TRUE);
    return created;
}
#else
static void
child_setup(gpointer unused)
{
    (void) unused;
    /* Called after fork, before exec. Use only async-signal-safe operations. */
    if (setsid() == -1) _exit(127);
}

static gboolean
spawn_native(DinoTorOwnedProcess *self, const gchar *const *argv,
             const gchar *cwd, GError **error)
{
    gint stdout_fd = -1, stderr_fd = -1;
    if (!g_spawn_async_with_pipes(cwd, (gchar **) argv, NULL,
                                  G_SPAWN_DO_NOT_REAP_CHILD | G_SPAWN_SEARCH_PATH,
                                  child_setup, NULL, &self->pid, NULL,
                                  &stdout_fd, &stderr_fd, error)) return FALSE;
    self->identifier = g_strdup_printf("%d", (gint) self->pid);
    self->stdout_pipe = g_unix_input_stream_new(stdout_fd, TRUE);
    self->stderr_pipe = g_unix_input_stream_new(stderr_fd, TRUE);
    return TRUE;
}
#endif

#if defined(__linux__)
/* PID 1 in a container may leave exited, reparented transports as zombies.
 * They cannot execute or be killed again. Do not wait forever for PID 1;
 * inspect only this owned group and count non-zombie members as live. */
static gboolean
group_has_live_members(GPid group)
{
    GDir *directory = g_dir_open("/proc", 0, NULL);
    if (directory == NULL) return TRUE;
    gboolean alive = FALSE;
    const gchar *entry;
    while ((entry = g_dir_read_name(directory)) != NULL) {
        if (!g_ascii_isdigit(entry[0])) continue;
        gchar *path = g_build_filename("/proc", entry, "stat", NULL);
        gchar *contents = NULL;
        gboolean read = g_file_get_contents(path, &contents, NULL, NULL);
        g_free(path);
        if (!read) continue; /* Processes can disappear during the scan. */
        gchar *end_name = strrchr(contents, ')');
        if (end_name != NULL && end_name[1] == ' ' && end_name[2] != '\0') {
            gchar state = end_name[2];
            gchar *cursor = end_name + 3;
            gchar *end = NULL;
            g_ascii_strtoll(cursor, &end, 10); /* parent PID */
            if (end != cursor) {
                cursor = end;
                gint64 process_group = g_ascii_strtoll(cursor, &end, 10);
                if (end != cursor && process_group == group && state != 'Z' && state != 'X') alive = TRUE;
            }
        }
        g_free(contents);
        if (alive) break;
    }
    g_dir_close(directory);
    return alive;
}
#endif

/* Called with the mutex held. Native identity/handles remain owned until the
 * supervisor joins, even when the Tor parent has already exited. */
static void
request_stop_locked(DinoTorOwnedProcess *self)
{
    if (self->stop_requested_us != 0 || self->tree_drained) return;
    self->stop_requested_us = g_get_monotonic_time();
#ifdef G_OS_WIN32
    if (self->job != NULL && !TerminateJobObject(self->job, 1) && self->failure == NULL)
        set_windows_error(&self->failure, "Terminate Tor job");
#else
    if (self->pid > 0 && kill(-self->pid, SIGTERM) == -1 && errno != ESRCH && self->failure == NULL)
        g_set_error(&self->failure, G_IO_ERROR, g_io_error_from_errno(errno),
                    "Terminate Tor process group: %s", g_strerror(errno));
#endif
    g_cond_broadcast(&self->changed);
}

static gpointer
supervise(gpointer data)
{
    DinoTorOwnedProcess *self = data;
    for (;;) {
        g_mutex_lock(&self->mutex);
#ifdef G_OS_WIN32
        if (!self->parent_exited && WaitForSingleObject(self->process, 0) == WAIT_OBJECT_0) {
            DWORD status = 0;
            if (GetExitCodeProcess(self->process, &status)) {
                self->exit_status = (gint) status;
                self->parent_exited = TRUE;
                self->parent_reaped = TRUE;
            } else if (self->failure == NULL) {
                set_windows_error(&self->failure, "Read Tor exit status");
            }
        }
        JOBOBJECT_BASIC_ACCOUNTING_INFORMATION accounting = { 0 };
        gboolean alive = TRUE;
        if (QueryInformationJobObject(self->job, JobObjectBasicAccountingInformation,
                                       &accounting, sizeof(accounting), NULL)) {
            alive = accounting.ActiveProcesses != 0;
        } else if (self->failure == NULL) {
            set_windows_error(&self->failure, "Query Tor job members");
        }
#else
        if (!self->parent_exited) {
            siginfo_t status = { 0 };
            gint result = waitid(P_PID, (id_t) self->pid, &status, WEXITED | WNOHANG | WNOWAIT);
            if (result == 0 && status.si_pid == self->pid) {
                self->exit_status = status.si_code == CLD_EXITED ? status.si_status : 128 + status.si_status;
                self->parent_exited = TRUE;
            } else if (result == -1 && errno != EINTR && self->failure == NULL) {
                g_set_error(&self->failure, G_IO_ERROR, g_io_error_from_errno(errno),
                            "Reap Tor parent: %s", g_strerror(errno));
                request_stop_locked(self);
            }
        }
        gboolean alive = kill(-self->pid, 0) == 0 || errno == EPERM;
#if defined(__linux__)
        if (alive && (self->parent_exited || self->stop_requested_us != 0))
            alive = group_has_live_members(self->pid);
#endif
        if (self->stop_requested_us != 0 && !self->killed &&
            g_get_monotonic_time() - self->stop_requested_us >= STOP_GRACE_US) {
            self->killed = TRUE;
            if (kill(-self->pid, SIGKILL) == -1 && errno != ESRCH && self->failure == NULL)
                g_set_error(&self->failure, G_IO_ERROR, g_io_error_from_errno(errno),
                            "Kill Tor process group: %s", g_strerror(errno));
        }
#endif
        /* Natural parent exit must also retire any remaining transports. */
        if (self->parent_exited && alive) request_stop_locked(self);
#ifndef G_OS_WIN32
        /* Keep the parent's zombie PID reserved until its group is empty.
         * Otherwise a reused numeric PGID could target an unrelated tree. */
        if (self->parent_exited && !alive && !self->parent_reaped) {
            gint status;
            pid_t result = waitpid(self->pid, &status, WNOHANG);
            if (result == self->pid) self->parent_reaped = TRUE;
            else if (result == -1 && errno != EINTR && self->failure == NULL)
                g_set_error(&self->failure, G_IO_ERROR, g_io_error_from_errno(errno),
                            "Reap retired Tor parent: %s", g_strerror(errno));
        }
#endif
        self->tree_drained = self->parent_reaped && !alive;
        if (!self->tree_drained && self->stop_requested_us != 0 &&
            g_get_monotonic_time() - self->stop_requested_us >= STOP_DEADLINE_US) {
            if (self->failure == NULL)
                g_set_error_literal(&self->failure, G_IO_ERROR, G_IO_ERROR_TIMED_OUT,
                                    "Tor process tree did not finish after forced termination");
            self->stop_deadline_reached = TRUE;
        }
        g_cond_broadcast(&self->changed);
        gboolean done = self->tree_drained;
        g_mutex_unlock(&self->mutex);
        if (done) return NULL;
        g_usleep(POLL_US);
    }
}

static void
dino_tor_owned_process_finalize(GObject *object)
{
    DinoTorOwnedProcess *self = DINO_TOR_OWNED_PROCESS(object);
    if (self->supervisor != NULL) {
        dino_tor_owned_process_request_stop(self);
        g_thread_join(self->supervisor);
    }
    g_clear_object(&self->stdout_pipe);
    g_clear_object(&self->stderr_pipe);
#ifdef G_OS_WIN32
    if (self->job != NULL) CloseHandle(self->job);
    if (self->process != NULL) CloseHandle(self->process);
#else
    if (self->pid > 0) g_spawn_close_pid(self->pid);
#endif
    g_clear_error(&self->failure);
    g_free(self->identifier);
    g_cond_clear(&self->changed);
    g_mutex_clear(&self->mutex);
    G_OBJECT_CLASS(dino_tor_owned_process_parent_class)->finalize(object);
}

static void
dino_tor_owned_process_class_init(DinoTorOwnedProcessClass *klass)
{
    G_OBJECT_CLASS(klass)->finalize = dino_tor_owned_process_finalize;
}

static void
dino_tor_owned_process_init(DinoTorOwnedProcess *self)
{
    g_mutex_init(&self->mutex);
    g_cond_init(&self->changed);
}

DinoTorOwnedProcess *
dino_tor_owned_process_spawn(const gchar *const *argv, const gchar *cwd, GError **error)
{
    g_return_val_if_fail(argv != NULL && argv[0] != NULL, NULL);
    DinoTorOwnedProcess *self = g_object_new(DINO_TYPE_TOR_OWNED_PROCESS, NULL);
    if (!spawn_native(self, argv, cwd, error)) {
        g_object_unref(self);
        return NULL;
    }
    /* The object joins this thread before freeing its state. The thread does
     * not hold a GObject ref, so dropping the last owner stops the tree too. */
    self->supervisor = g_thread_new("dinox-tor-owner", supervise, self);
    return self;
}

GInputStream *
dino_tor_owned_process_get_stdout_pipe(DinoTorOwnedProcess *self)
{
    return self->stdout_pipe;
}

GInputStream *
dino_tor_owned_process_get_stderr_pipe(DinoTorOwnedProcess *self)
{
    return self->stderr_pipe;
}

const gchar *
dino_tor_owned_process_get_identifier(DinoTorOwnedProcess *self)
{
    return self->identifier;
}

gint
dino_tor_owned_process_get_exit_status(DinoTorOwnedProcess *self)
{
    g_mutex_lock(&self->mutex);
    gint status = self->exit_status;
    g_mutex_unlock(&self->mutex);
    return status;
}

gboolean
dino_tor_owned_process_is_tree_drained(DinoTorOwnedProcess *self)
{
    g_mutex_lock(&self->mutex);
    gboolean drained = self->tree_drained;
    g_mutex_unlock(&self->mutex);
    return drained;
}

void
dino_tor_owned_process_request_stop(DinoTorOwnedProcess *self)
{
    g_mutex_lock(&self->mutex);
    request_stop_locked(self);
    g_mutex_unlock(&self->mutex);
}

static void
wait_worker(GTask *task, gpointer source_object, gpointer task_data, GCancellable *cancellable)
{
    DinoTorOwnedProcess *self = source_object;
    gboolean whole_tree = GPOINTER_TO_INT(task_data);
    g_mutex_lock(&self->mutex);
    for (;;) {
        if (cancellable != NULL && g_cancellable_is_cancelled(cancellable)) {
            g_mutex_unlock(&self->mutex);
            g_task_return_new_error(task, G_IO_ERROR, G_IO_ERROR_CANCELLED, "Tor wait was cancelled");
            return;
        }
        gboolean done = whole_tree ? self->tree_drained : self->parent_exited;
        if (self->failure != NULL && (!whole_tree || done || self->stop_deadline_reached)) {
            GError *error = g_error_copy(self->failure);
            g_mutex_unlock(&self->mutex);
            g_task_return_error(task, error);
            return;
        }
        if (done) {
            g_mutex_unlock(&self->mutex);
            g_task_return_boolean(task, TRUE);
            return;
        }
        g_cond_wait_until(&self->changed, &self->mutex, g_get_monotonic_time() + 50 * G_TIME_SPAN_MILLISECOND);
    }
}

void
dino_tor_owned_process_wait_async(DinoTorOwnedProcess *self, GCancellable *cancellable,
                                GAsyncReadyCallback callback, gpointer user_data)
{
    GTask *task = g_task_new(self, cancellable, callback, user_data);
    g_task_set_task_data(task, GINT_TO_POINTER(FALSE), NULL);
    g_task_run_in_thread(task, wait_worker);
    g_object_unref(task);
}

gboolean
dino_tor_owned_process_wait_finish(DinoTorOwnedProcess *self, GAsyncResult *result, GError **error)
{
    g_return_val_if_fail(g_task_is_valid(result, self), FALSE);
    return g_task_propagate_boolean(G_TASK(result), error);
}

void
dino_tor_owned_process_stop_and_wait_async(DinoTorOwnedProcess *self, GCancellable *cancellable,
                                         GAsyncReadyCallback callback, gpointer user_data)
{
    dino_tor_owned_process_request_stop(self);
    GTask *task = g_task_new(self, cancellable, callback, user_data);
    g_task_set_task_data(task, GINT_TO_POINTER(TRUE), NULL);
    g_task_run_in_thread(task, wait_worker);
    g_object_unref(task);
}

gboolean
dino_tor_owned_process_stop_and_wait_finish(DinoTorOwnedProcess *self,
                                          GAsyncResult *result, GError **error)
{
    g_return_val_if_fail(g_task_is_valid(result, self), FALSE);
    return g_task_propagate_boolean(G_TASK(result), error);
}
