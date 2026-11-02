#ifndef _GNU_SOURCE
#define _GNU_SOURCE
#endif

#include "profile_restore_sync.h"
#include <gio/gio.h>
#include <glib/gstdio.h>
#include <errno.h>
#include <stdlib.h>

#ifdef G_OS_WIN32
#include <windows.h>
#include <glib/gwin32.h>
#else
#include <dirent.h>
#include <fcntl.h>
#include <sys/stat.h>
#include <unistd.h>
#endif

#ifndef G_OS_WIN32
static gboolean
sync_error(GError **error, const gchar *operation, int code)
{
    g_set_error(error, G_IO_ERROR, g_io_error_from_errno(code),
                "%s: %s", operation, g_strerror(code));
    return FALSE;
}
#endif

static gboolean
invalid_tree(GError **error)
{
    g_set_error_literal(error, G_IO_ERROR, G_IO_ERROR_INVALID_DATA,
        "Restore data must contain only real directories and singly linked regular files");
    return FALSE;
}

static gboolean
validate_directory(const gchar *path, gboolean allow_missing, GError **error)
{
    GFile *file = g_file_new_for_path(path);
    GError *query_error = NULL;
    GFileInfo *info = g_file_query_info(file,
        G_FILE_ATTRIBUTE_STANDARD_TYPE "," G_FILE_ATTRIBUTE_STANDARD_IS_SYMLINK,
        G_FILE_QUERY_INFO_NOFOLLOW_SYMLINKS, NULL, &query_error);
    g_object_unref(file);
    if (info == NULL) {
        if (allow_missing && g_error_matches(query_error, G_IO_ERROR, G_IO_ERROR_NOT_FOUND)) {
            g_clear_error(&query_error);
            return TRUE;
        }
        g_propagate_error(error, query_error);
        return FALSE;
    }
    gboolean valid = !allow_missing && !g_file_info_get_is_symlink(info)
        && g_file_info_get_file_type(info) == G_FILE_TYPE_DIRECTORY;
    g_object_unref(info);
    if (!valid) {
        if (allow_missing)
            g_set_error_literal(error, G_IO_ERROR, G_IO_ERROR_EXISTS,
                                "Restore rename destination already exists");
        else
            invalid_tree(error);
    }
    return valid;
}

#ifdef G_OS_WIN32

static gboolean
windows_error(GError **error, const gchar *operation, DWORD code)
{
    gchar *message = g_win32_error_message(code);
    g_set_error(error, G_IO_ERROR, G_IO_ERROR_FAILED, "%s (%lu): %s",
                operation, (unsigned long) code, message);
    g_free(message);
    return FALSE;
}

static gboolean
sync_windows_tree(const gchar *path, guint depth, gboolean regular_only, GError **error)
{
    if (depth > 65)
        return invalid_tree(error);
    gunichar2 *wide_path = g_utf8_to_utf16(path, -1, NULL, NULL, error);
    if (wide_path == NULL)
        return FALSE;
    DWORD attributes = GetFileAttributesW((LPCWSTR) wide_path);
    if (attributes == INVALID_FILE_ATTRIBUTES) {
        DWORD code = GetLastError();
        g_free(wide_path);
        return windows_error(error, "Cannot inspect restore data", code);
    }
    gboolean directory = (attributes & FILE_ATTRIBUTE_DIRECTORY) != 0;
    if ((attributes & FILE_ATTRIBUTE_REPARSE_POINT) || (regular_only && directory)) {
        g_free(wide_path);
        return invalid_tree(error);
    }
    /* FlushFileBuffers needs GENERIC_WRITE. Do not silently skip a read-only
     * payload: failure leaves the previous profile and pending restore intact. */
    HANDLE handle = CreateFileW((LPCWSTR) wide_path,
        directory ? FILE_READ_ATTRIBUTES : (GENERIC_READ | GENERIC_WRITE),
        FILE_SHARE_READ, NULL, OPEN_EXISTING,
        FILE_FLAG_OPEN_REPARSE_POINT | FILE_FLAG_BACKUP_SEMANTICS, NULL);
    DWORD code = GetLastError();
    g_free(wide_path);
    if (handle == NULL || handle == INVALID_HANDLE_VALUE)
        return windows_error(error, "Cannot open restore data for synchronization", code);
    BY_HANDLE_FILE_INFORMATION info;
    if (!GetFileInformationByHandle(handle, &info)) {
        code = GetLastError();
        CloseHandle(handle);
        return windows_error(error, "Cannot verify restore data handle", code);
    }
    if ((info.dwFileAttributes & FILE_ATTRIBUTE_REPARSE_POINT) ||
        (((info.dwFileAttributes & FILE_ATTRIBUTE_DIRECTORY) != 0) != directory) ||
        (!directory && (GetFileType(handle) != FILE_TYPE_DISK || info.nNumberOfLinks != 1))) {
        CloseHandle(handle);
        return invalid_tree(error);
    }
    gboolean success = TRUE;
    if (directory) {
        GDir *children = g_dir_open(path, 0, error);
        if (children == NULL) {
            CloseHandle(handle);
            return FALSE;
        }
        const gchar *name;
        while ((name = g_dir_read_name(children)) != NULL) {
            gchar *child = g_build_filename(path, name, NULL);
            success = sync_windows_tree(child, depth + 1, FALSE, error);
            g_free(child);
            if (!success)
                break;
        }
        g_dir_close(children);
        /* Win32 has no equivalent documented directory-fsync operation.
         * The offline swaps below use MOVEFILE_WRITE_THROUGH; every payload
         * handle has been explicitly flushed before any old profile is moved. */
    } else if (!FlushFileBuffers(handle)) {
        success = windows_error(error, "Cannot flush restored file", GetLastError());
    }
    CloseHandle(handle);
    return success;
}

#else

static gboolean
sync_fd(int fd, GError **error)
{
    int result;
    do {
        result = fsync(fd);
    } while (result < 0 && errno == EINTR);
    return result == 0 || sync_error(error, "Cannot synchronize restore data", errno);
}

static gboolean
sync_directory_fd(int fd, guint depth, GError **error)
{
    if (depth > 65)
        return invalid_tree(error);
    int enumeration_fd = fcntl(fd, F_DUPFD_CLOEXEC, 0);
    if (enumeration_fd < 0)
        return sync_error(error, "Cannot enumerate restore directory", errno);
    DIR *children = fdopendir(enumeration_fd);
    if (children == NULL) {
        int code = errno;
        close(enumeration_fd);
        return sync_error(error, "Cannot enumerate restore directory", code);
    }
    gboolean success = TRUE;
    struct dirent *entry;
    errno = 0;
    while ((entry = readdir(children)) != NULL) {
        if (g_str_equal(entry->d_name, ".") || g_str_equal(entry->d_name, ".."))
            continue;
        struct stat expected;
        if (fstatat(fd, entry->d_name, &expected, AT_SYMLINK_NOFOLLOW) < 0) {
            success = sync_error(error, "Cannot inspect restored entry", errno);
            break;
        }
        if ((!S_ISDIR(expected.st_mode) && !S_ISREG(expected.st_mode)) ||
            (S_ISREG(expected.st_mode) && expected.st_nlink != 1)) {
            success = invalid_tree(error);
            break;
        }
        /* O_NONBLOCK prevents a substituted FIFO from blocking before fstat;
         * NOFOLLOW and descriptor-relative traversal never dereference links. */
        int child = openat(fd, entry->d_name, O_RDONLY | O_CLOEXEC | O_NOFOLLOW | O_NONBLOCK);
        if (child < 0) {
            success = sync_error(error, "Cannot open restored entry", errno);
            break;
        }
        struct stat info;
        if (fstat(child, &info) < 0) {
            success = sync_error(error, "Cannot inspect restored entry", errno);
        } else if (info.st_dev != expected.st_dev || info.st_ino != expected.st_ino) {
            success = invalid_tree(error);
        } else if (S_ISDIR(info.st_mode)) {
            success = sync_directory_fd(child, depth + 1, error);
        } else if (S_ISREG(info.st_mode) && info.st_nlink == 1) {
            success = sync_fd(child, error);
        } else {
            success = invalid_tree(error);
        }
        close(child);
        if (!success)
            break;
        errno = 0;
    }
    if (success && errno != 0)
        success = sync_error(error, "Cannot finish restore directory enumeration", errno);
    closedir(children);
    return success && sync_fd(fd, error);
}

static gboolean
sync_directory(const gchar *path, GError **error)
{
    int fd = open(path, O_RDONLY | O_DIRECTORY | O_CLOEXEC | O_NOFOLLOW);
    if (fd < 0)
        return sync_error(error, "Cannot open directory for synchronization", errno);
    gboolean success = sync_fd(fd, error);
    close(fd);
    return success;
}

static gboolean
sync_parent(const gchar *path, GError **error)
{
    gchar *parent = g_path_get_dirname(path);
    /* A previous interrupted deletion may have removed the parent as well.
     * Confirm that absence at the nearest surviving ancestor. Resolve existing
     * parent aliases physically; the deleted leaf itself is never followed. */
    while (TRUE) {
        gchar *physical = realpath(parent, NULL);
        if (physical != NULL) {
            gboolean success = sync_directory(physical, error);
            free(physical);
            g_free(parent);
            return success;
        }
        int code = errno;
        if (code != ENOENT) {
            g_free(parent);
            return sync_error(error, "Cannot resolve deleted entry parent", code);
        }
        gchar *ancestor = g_path_get_dirname(parent);
        if (g_str_equal(ancestor, parent)) {
            g_free(ancestor);
            g_free(parent);
            return sync_error(error, "Cannot find deleted entry parent", code);
        }
        g_free(parent);
        parent = ancestor;
    }
}

#endif

static gboolean
require_absolute_path(const gchar *path, GError **error)
{
    if (path == NULL || !g_path_is_absolute(path)) {
        g_set_error_literal(error, G_IO_ERROR, G_IO_ERROR_INVALID_ARGUMENT,
                            "Filesystem synchronization needs an absolute local path");
        return FALSE;
    }
    return TRUE;
}

void
dino_profile_restore_sync_directory(const gchar *path, GError **error)
{
    g_return_if_fail(error == NULL || *error == NULL);
    if (!require_absolute_path(path, error))
        return;
#ifdef G_OS_WIN32
    g_set_error_literal(error, G_IO_ERROR, G_IO_ERROR_NOT_SUPPORTED,
                        "Win32 does not provide a directory-fsync guarantee without a volume flush");
#else
    sync_directory(path, error);
#endif
}

void
dino_profile_restore_sync_parent(const gchar *path, GError **error)
{
    g_return_if_fail(error == NULL || *error == NULL);
    if (!require_absolute_path(path, error))
        return;
#ifdef G_OS_WIN32
    g_set_error_literal(error, G_IO_ERROR, G_IO_ERROR_NOT_SUPPORTED,
                        "Win32 does not provide a directory-fsync guarantee without a volume flush");
#else
    sync_parent(path, error);
#endif
}

void
dino_profile_restore_sync_file(const gchar *path, GError **error)
{
    g_return_if_fail(error == NULL || *error == NULL);
    if (!require_absolute_path(path, error))
        return;
#ifdef G_OS_WIN32
    sync_windows_tree(path, 0, TRUE, error);
#else
    struct stat expected;
    if (lstat(path, &expected) < 0) {
        sync_error(error, "Cannot inspect file for synchronization", errno);
        return;
    }
    if (!S_ISREG(expected.st_mode) || expected.st_nlink != 1) {
        invalid_tree(error);
        return;
    }
    int fd = open(path, O_RDONLY | O_CLOEXEC | O_NOFOLLOW | O_NONBLOCK);
    if (fd < 0) {
        sync_error(error, "Cannot open file for synchronization", errno);
        return;
    }
    struct stat info;
    if (fstat(fd, &info) < 0)
        sync_error(error, "Cannot inspect file for synchronization", errno);
    else if (!S_ISREG(info.st_mode) || info.st_nlink != 1 ||
             info.st_dev != expected.st_dev || info.st_ino != expected.st_ino)
        invalid_tree(error);
    else
        sync_fd(fd, error);
    close(fd);
#endif
}

void
dino_profile_restore_sync_tree(const gchar *path, GError **error)
{
    g_return_if_fail(error == NULL || *error == NULL);
    if (path == NULL || !g_path_is_absolute(path)) {
        g_set_error_literal(error, G_IO_ERROR, G_IO_ERROR_INVALID_ARGUMENT,
                            "Restore synchronization needs an absolute physical path");
        return;
    }
    if (!validate_directory(path, FALSE, error))
        return;
#ifdef G_OS_WIN32
    sync_windows_tree(path, 0, FALSE, error);
#else
    int fd = open(path, O_RDONLY | O_DIRECTORY | O_CLOEXEC | O_NOFOLLOW);
    if (fd < 0) {
        sync_error(error, "Cannot open restore root for synchronization", errno);
        return;
    }
    gboolean success = sync_directory_fd(fd, 0, error);
    close(fd);
    if (success)
        sync_parent(path, error);
#endif
}

void
dino_profile_restore_rename_directory(const gchar *source,
                                     const gchar *destination, GError **error)
{
    g_return_if_fail(error == NULL || *error == NULL);
    if (source == NULL || destination == NULL || !g_path_is_absolute(source) ||
        !g_path_is_absolute(destination)) {
        g_set_error_literal(error, G_IO_ERROR, G_IO_ERROR_INVALID_ARGUMENT,
                            "Restore rename needs absolute physical paths");
        return;
    }
    if (!validate_directory(source, FALSE, error) || !validate_directory(destination, TRUE, error))
        return;
#ifdef G_OS_WIN32
    gunichar2 *wide_source = g_utf8_to_utf16(source, -1, NULL, NULL, error);
    if (wide_source == NULL)
        return;
    gunichar2 *wide_destination = g_utf8_to_utf16(destination, -1, NULL, NULL, error);
    if (wide_destination == NULL) {
        g_free(wide_source);
        return;
    }
    /* No COPY_ALLOWED/REPLACE_EXISTING: unexpected mounts or a present target
     * must fail, without copying into or overwriting any live profile. */
    if (!MoveFileExW((LPCWSTR) wide_source, (LPCWSTR) wide_destination, MOVEFILE_WRITE_THROUGH))
        windows_error(error, "Cannot durably rename restore directory", GetLastError());
    g_free(wide_source);
    g_free(wide_destination);
#else
    if (g_rename(source, destination) != 0) {
        sync_error(error, "Cannot rename restore directory", errno);
        return;
    }
    if (!sync_parent(source, error))
        return;
    gchar *source_parent = g_path_get_dirname(source);
    gchar *destination_parent = g_path_get_dirname(destination);
    if (!g_str_equal(source_parent, destination_parent))
        sync_parent(destination, error);
    g_free(source_parent);
    g_free(destination_parent);
#endif
}
