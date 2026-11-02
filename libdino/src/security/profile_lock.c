#ifndef _GNU_SOURCE
#define _GNU_SOURCE
#endif
#ifdef _WIN32
#ifndef _WIN32_WINNT
#define _WIN32_WINNT 0x0600
#endif
#endif

#include "profile_lock.h"

#include <gio/gio.h>
#include <glib/gstdio.h>
#include <errno.h>
#include <string.h>

#ifdef G_OS_WIN32
#include <windows.h>
#include <glib/gwin32.h>
#else
#include <fcntl.h>
#include <stdlib.h>
#include <sys/file.h>
#include <sys/stat.h>
#include <unistd.h>
#endif

/* Deliberately process-owned, including during application shutdown. Keeping
 * the files outside the profile also protects restore/reset directory swaps.
 * There is no unlink/release API: unlinking a locked file permits a new inode
 * to be locked independently while the original process still writes its DB. */
static GMutex profile_locks_mutex;
static GHashTable *profile_locks;

typedef struct {
#ifdef G_OS_WIN32
    HANDLE handle;
#else
    int fd;
#endif
} ProfileLockHandle;

static void
strip_trailing_separators(gchar *path)
{
    gsize length = strlen(path);
    while (length > 1 && G_IS_DIR_SEPARATOR(path[length - 1]))
        path[--length] = '\0';
}

static void
set_errno_error(GError **error, const gchar *operation, int saved_errno)
{
    g_set_error(error, G_IO_ERROR, g_io_error_from_errno(saved_errno),
                "%s: %s", operation, g_strerror(saved_errno));
}

static gboolean
ensure_parent(const gchar *path, GError **error)
{
    gchar *parent = g_path_get_dirname(path);
    gboolean success = TRUE;
    if (g_mkdir_with_parents(parent, 0700) < 0) {
        set_errno_error(error, "Cannot create profile parent directory", errno);
        success = FALSE;
    }
    g_free(parent);
    return success;
}

#ifdef G_OS_WIN32

static void
set_windows_error(GError **error, const gchar *operation, DWORD code)
{
    gchar *message = g_win32_error_message(code);
    GIOErrorEnum kind = (code == ERROR_SHARING_VIOLATION || code == ERROR_LOCK_VIOLATION)
        ? G_IO_ERROR_BUSY : G_IO_ERROR_FAILED;
    g_set_error(error, G_IO_ERROR, kind, "%s (%lu): %s", operation,
                (unsigned long) code, message);
    g_free(message);
}

static gboolean
valid_handle(HANDLE handle)
{
    return handle != NULL && handle != INVALID_HANDLE_VALUE;
}

/* Opening the directory follows junctions/symlinks. GetFullPathName alone, or
 * GLib's lexical canonicalization, would not identify the physical profile. */
static gchar *
physical_windows_directory(const gchar *path, DWORD *open_error, GError **error)
{
    gunichar2 *wide_path = g_utf8_to_utf16(path, -1, NULL, NULL, error);
    if (wide_path == NULL)
        return NULL;
    HANDLE handle = CreateFileW((LPCWSTR) wide_path, FILE_READ_ATTRIBUTES,
        FILE_SHARE_READ | FILE_SHARE_WRITE | FILE_SHARE_DELETE, NULL,
        OPEN_EXISTING, FILE_FLAG_BACKUP_SEMANTICS, NULL);
    DWORD handle_error = GetLastError();
    g_free(wide_path);
    if (!valid_handle(handle)) {
        *open_error = handle_error;
        return NULL;
    }
    BY_HANDLE_FILE_INFORMATION information;
    if (!GetFileInformationByHandle(handle, &information)) {
        DWORD code = GetLastError();
        CloseHandle(handle);
        set_windows_error(error, "Cannot inspect profile directory", code);
        return NULL;
    }
    if (!(information.dwFileAttributes & FILE_ATTRIBUTE_DIRECTORY)) {
        CloseHandle(handle);
        g_set_error_literal(error, G_IO_ERROR, G_IO_ERROR_NOT_DIRECTORY,
                            "Profile path is not a directory");
        return NULL;
    }
    DWORD size = GetFinalPathNameByHandleW(handle, NULL, 0,
                                         FILE_NAME_NORMALIZED | VOLUME_NAME_DOS);
    if (size == 0) {
        DWORD code = GetLastError();
        CloseHandle(handle);
        set_windows_error(error, "Cannot resolve physical profile directory", code);
        return NULL;
    }
    WCHAR *buffer = g_new(WCHAR, (gsize) size + 1);
    DWORD length = GetFinalPathNameByHandleW(handle, buffer, size + 1,
                                            FILE_NAME_NORMALIZED | VOLUME_NAME_DOS);
    DWORD code = GetLastError();
    CloseHandle(handle);
    if (length == 0 || length > size) {
        g_free(buffer);
        set_windows_error(error, "Cannot resolve physical profile directory",
                          length > size ? ERROR_INSUFFICIENT_BUFFER : code);
        return NULL;
    }
    gchar *result = g_utf16_to_utf8((gunichar2 *) buffer, length, NULL, NULL, error);
    g_free(buffer);
    return result;
}

static gchar *
resolve_profile(const gchar *path, GError **error)
{
    DWORD code = ERROR_SUCCESS;
    gchar *physical = physical_windows_directory(path, &code, error);
    if (physical != NULL || (error != NULL && *error != NULL))
        return physical;
    if (code != ERROR_FILE_NOT_FOUND && code != ERROR_PATH_NOT_FOUND) {
        set_windows_error(error, "Cannot open profile directory", code);
        return NULL;
    }

    /* A dangling junction must not silently receive a different alias lock.
     * Existing junctions resolve through the directory handle above. Refuse
     * unresolved reparse points rather than guessing their physical target. */
    gunichar2 *wide_path = g_utf8_to_utf16(path, -1, NULL, NULL, error);
    if (wide_path == NULL)
        return NULL;
    DWORD attributes = GetFileAttributesW((LPCWSTR) wide_path);
    HANDLE link = CreateFileW((LPCWSTR) wide_path, FILE_READ_ATTRIBUTES,
        FILE_SHARE_READ | FILE_SHARE_WRITE | FILE_SHARE_DELETE, NULL,
        OPEN_EXISTING, FILE_FLAG_BACKUP_SEMANTICS | FILE_FLAG_OPEN_REPARSE_POINT, NULL);
    DWORD link_error = GetLastError();
    g_free(wide_path);
    if (valid_handle(link)) {
        BY_HANDLE_FILE_INFORMATION information;
        if (!GetFileInformationByHandle(link, &information)) {
            DWORD information_error = GetLastError();
            CloseHandle(link);
            set_windows_error(error, "Cannot inspect profile reparse point", information_error);
            return NULL;
        }
        attributes = information.dwFileAttributes;
        CloseHandle(link);
    } else if (link_error != ERROR_FILE_NOT_FOUND && link_error != ERROR_PATH_NOT_FOUND) {
        set_windows_error(error, "Cannot inspect missing profile directory", link_error);
        return NULL;
    }
    if (attributes != INVALID_FILE_ATTRIBUTES && (attributes & FILE_ATTRIBUTE_REPARSE_POINT)) {
        g_set_error_literal(error, G_IO_ERROR, G_IO_ERROR_FAILED,
                            "Cannot resolve the target of the profile reparse point");
        return NULL;
    }
    if (!ensure_parent(path, error))
        return NULL;
    gchar *parent = g_path_get_dirname(path);
    physical = physical_windows_directory(parent, &code, error);
    g_free(parent);
    if (physical == NULL) {
        if (error == NULL || *error == NULL)
            set_windows_error(error, "Cannot resolve profile parent directory", code);
        return NULL;
    }
    gchar *basename = g_path_get_basename(path);
    gchar *result = g_build_filename(physical, basename, NULL);
    g_free(physical);
    g_free(basename);
    return result;
}

static ProfileLockHandle *
open_profile_lock(const gchar *path, GError **error)
{
    gunichar2 *wide_path = g_utf8_to_utf16(path, -1, NULL, NULL, error);
    if (wide_path == NULL)
        return NULL;
    /* No sharing, no inheritable SECURITY_ATTRIBUTES. Unlike a Local\\ mutex,
     * the file handle excludes other Windows logon sessions as well. */
    HANDLE handle = CreateFileW((LPCWSTR) wide_path, GENERIC_READ | GENERIC_WRITE,
        0, NULL, OPEN_ALWAYS, FILE_ATTRIBUTE_NORMAL | FILE_FLAG_OPEN_REPARSE_POINT, NULL);
    DWORD handle_error = GetLastError();
    g_free(wide_path);
    if (!valid_handle(handle)) {
        set_windows_error(error, "Cannot acquire exclusive profile lock", handle_error);
        return NULL;
    }
    BY_HANDLE_FILE_INFORMATION information;
    if (!GetFileInformationByHandle(handle, &information)) {
        DWORD code = GetLastError();
        CloseHandle(handle);
        set_windows_error(error, "Cannot inspect profile lock file", code);
        return NULL;
    }
    if (information.dwFileAttributes & (FILE_ATTRIBUTE_DIRECTORY | FILE_ATTRIBUTE_REPARSE_POINT)) {
        CloseHandle(handle);
        g_set_error_literal(error, G_IO_ERROR, G_IO_ERROR_FAILED,
                            "Profile lock must be a regular file, not a reparse point");
        return NULL;
    }
    ProfileLockHandle *result = g_new(ProfileLockHandle, 1);
    result->handle = handle;
    return result;
}

static void
close_failed_lock(ProfileLockHandle *lock)
{
    CloseHandle(lock->handle);
    g_free(lock);
}

#else

static gchar *
resolve_profile(const gchar *path, GError **error)
{
    gchar *candidate = g_strdup(path);
    for (guint depth = 0; depth < 40; depth++) {
        gchar *physical = realpath(candidate, NULL);
        if (physical != NULL) {
            struct stat info;
            if (stat(physical, &info) < 0) {
                set_errno_error(error, "Cannot inspect profile directory", errno);
                free(physical);
                break;
            }
            if (!S_ISDIR(info.st_mode)) {
                g_set_error_literal(error, G_IO_ERROR, G_IO_ERROR_NOT_DIRECTORY,
                                    "Profile path is not a directory");
                free(physical);
                break;
            }
            gchar *result = g_strdup(physical);
            free(physical);
            g_free(candidate);
            return result;
        }
        int saved_errno = errno;
        if (saved_errno != ENOENT) {
            set_errno_error(error, "Cannot resolve profile directory", saved_errno);
            break;
        }
        struct stat info;
        if (lstat(candidate, &info) == 0) {
            if (S_ISLNK(info.st_mode)) {
                /* A restored profile may temporarily be absent. Resolve the
                 * final symlink ourselves so an alias still uses the same lock
                 * beside its missing physical target. Never create the profile. */
                gchar *target = g_file_read_link(candidate, error);
                if (target == NULL)
                    break;
                gchar *parent = g_path_get_dirname(candidate);
                gchar *next = g_path_is_absolute(target)
                    ? g_strdup(target) : g_build_filename(parent, target, NULL);
                g_free(parent);
                g_free(target);
                g_free(candidate);
                candidate = next;
                strip_trailing_separators(candidate);
                continue;
            }
            g_set_error_literal(error, G_IO_ERROR, G_IO_ERROR_FAILED,
                                "Profile directory changed while resolving it");
            break;
        }
        if (errno != ENOENT) {
            set_errno_error(error, "Cannot inspect missing profile directory", errno);
            break;
        }
        if (!ensure_parent(candidate, error))
            break;
        gchar *parent = g_path_get_dirname(candidate);
        physical = realpath(parent, NULL);
        g_free(parent);
        if (physical == NULL) {
            set_errno_error(error, "Cannot resolve profile parent directory", errno);
            break;
        }
        gchar *basename = g_path_get_basename(candidate);
        gchar *result = g_build_filename(physical, basename, NULL);
        free(physical);
        g_free(basename);
        g_free(candidate);
        return result;
    }
    g_free(candidate);
    if (error == NULL || *error == NULL)
        g_set_error_literal(error, G_IO_ERROR, G_IO_ERROR_TOO_MANY_LINKS,
                            "Too many profile symlinks");
    return NULL;
}

static ProfileLockHandle *
open_profile_lock(const gchar *path, GError **error)
{
    int fd = open(path, O_RDWR | O_CREAT | O_CLOEXEC | O_NOFOLLOW, 0600);
    if (fd < 0) {
        set_errno_error(error, "Cannot open profile lock file", errno);
        return NULL;
    }
    struct stat info;
    if (fstat(fd, &info) < 0) {
        int code = errno;
        close(fd);
        set_errno_error(error, "Cannot inspect profile lock file", code);
        return NULL;
    }
    if (!S_ISREG(info.st_mode)) {
        close(fd);
        g_set_error_literal(error, G_IO_ERROR, G_IO_ERROR_FAILED,
                            "Profile lock must be a regular file");
        return NULL;
    }
    int status;
    do {
        status = flock(fd, LOCK_EX | LOCK_NB);
    } while (status < 0 && errno == EINTR);
    if (status < 0) {
        int code = errno;
        close(fd);
        if (code == EWOULDBLOCK || code == EAGAIN)
            g_set_error_literal(error, G_IO_ERROR, G_IO_ERROR_BUSY,
                                "Another process is already using this profile");
        else
            set_errno_error(error, "Cannot acquire exclusive profile lock", code);
        return NULL;
    }
    ProfileLockHandle *result = g_new(ProfileLockHandle, 1);
    result->fd = fd;
    return result;
}

static void
close_failed_lock(ProfileLockHandle *lock)
{
    close(lock->fd);
    g_free(lock);
}

#endif

gchar *
dino_profile_lock_acquire_native(const gchar *storage_dir, GError **error)
{
    g_return_val_if_fail(error == NULL || *error == NULL, NULL);
    if (storage_dir == NULL || *storage_dir == '\0') {
        g_set_error_literal(error, G_IO_ERROR, G_IO_ERROR_INVALID_ARGUMENT,
                            "Profile directory must not be empty");
        return NULL;
    }
    gchar *basename = g_path_get_basename(storage_dir);
    gboolean invalid = g_str_equal(basename, ".") || g_str_equal(basename, "..")
        || g_str_equal(basename, G_DIR_SEPARATOR_S);
    g_free(basename);
    if (invalid) {
        g_set_error_literal(error, G_IO_ERROR, G_IO_ERROR_INVALID_ARGUMENT,
                            "Profile directory must name a profile, not a parent or root");
        return NULL;
    }

    gchar *requested = g_strdup(storage_dir);
    strip_trailing_separators(requested);
    g_mutex_lock(&profile_locks_mutex);
    gchar *physical = resolve_profile(requested, error);
    if (physical == NULL) {
        g_free(requested);
        g_mutex_unlock(&profile_locks_mutex);
        return NULL;
    }
    if (profile_locks != NULL && g_hash_table_contains(profile_locks, physical)) {
        g_free(requested);
        g_mutex_unlock(&profile_locks_mutex);
        return physical;
    }
    gchar *lock_path = g_strconcat(physical, ".lock", NULL);
    ProfileLockHandle *lock = open_profile_lock(lock_path, error);
    g_free(lock_path);
    if (lock == NULL) {
        g_free(requested);
        g_free(physical);
        g_mutex_unlock(&profile_locks_mutex);
        return NULL;
    }

    /* Fail closed if a symlink/parent was replaced while acquiring the lock.
     * Normal first-start directory creation and locked restore swaps retain the
     * same physical pathname. No database or key files have been touched yet. */
    gchar *confirmed = resolve_profile(requested, error);
    g_free(requested);
    if (confirmed == NULL || !g_str_equal(physical, confirmed)) {
        if (confirmed != NULL)
            g_set_error_literal(error, G_IO_ERROR, G_IO_ERROR_FAILED,
                                "Profile directory changed while acquiring its lock");
        g_free(confirmed);
        g_free(physical);
        close_failed_lock(lock);
        g_mutex_unlock(&profile_locks_mutex);
        return NULL;
    }
    g_free(confirmed);
    if (profile_locks == NULL)
        profile_locks = g_hash_table_new_full(g_str_hash, g_str_equal, g_free, NULL);
    g_hash_table_insert(profile_locks, g_strdup(physical), lock);
    g_mutex_unlock(&profile_locks_mutex);
    return physical;
}
