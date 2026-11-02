/*
 * Copyright (C) 2026 Ralf Peter <dinox@handwerker.jetzt>
 *
 * This program is free software: you can redistribute it and/or modify
 * it under the terms of the GNU General Public License as published by
 * the Free Software Foundation, either version 3 of the License, or
 * (at your option) any later version.
 *
 * Windows backup/restore uses wide filesystem names and UTF-8 PAX headers.
 * Do not use archive_entry_pathname(): under MSVCRT an unrepresentable name
 * can return NULL even when the process has a UTF-8 manifest.
 */
#define WIN32_LEAN_AND_MEAN
#include <windows.h>
#include <archive.h>
#include <archive_entry.h>
#include <fcntl.h>
#include <io.h>
#include <locale.h>
#include <stdint.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <wchar.h>

static int archive_error(const char *operation, struct archive *archive) {
    const char *detail = archive_error_string(archive);
    fprintf(stderr, "%s: %s\n", operation, detail != NULL ? detail : "archive failure");
    return 1;
}

static int fixed_error(const char *message) {
    fprintf(stderr, "%s\n", message);
    return 1;
}

static int reserved_component(const wchar_t *start, size_t length) {
    wchar_t base[16];
    size_t n = 0;
    while (n < length && start[n] != L'.' && n + 1 < sizeof(base) / sizeof(base[0])) {
        wchar_t c = start[n];
        base[n] = c >= L'a' && c <= L'z' ? c - L'a' + L'A' : c;
        n++;
    }
    if (n < length && start[n] != L'.') return 0;
    base[n] = L'\0';
    if (wcscmp(base, L"CON") == 0 || wcscmp(base, L"PRN") == 0 ||
        wcscmp(base, L"AUX") == 0 || wcscmp(base, L"NUL") == 0 ||
        wcscmp(base, L"CONIN$") == 0 || wcscmp(base, L"CONOUT$") == 0 ||
        wcscmp(base, L"CLOCK$") == 0) return 1;
    if (n == 4 && (wcsncmp(base, L"COM", 3) == 0 || wcsncmp(base, L"LPT", 3) == 0)) {
        wchar_t c = base[3];
        return (c >= L'1' && c <= L'9') || c == 0x00b9 || c == 0x00b2 || c == 0x00b3;
    }
    return 0;
}

/* Restrict every archive entry to canonical Windows names below dinox/.
 * Reject aliases before libarchive's Windows writer can normalize them. */
static int safe_path(const wchar_t *path, int is_directory) {
    size_t length;
    size_t begin = 0;
    if (path == NULL) return 0;
    length = wcslen(path);
    if (length == 0 || length > 32700) return 0;
    if (path[length - 1] == L'/') {
        if (!is_directory) return 0;
        length--;
    }
    if (length < 5 || wcsncmp(path, L"dinox", 5) != 0 ||
        (length > 5 && path[5] != L'/')) return 0;
    if (length == 5 && !is_directory) return 0;
    while (begin < length) {
        size_t end = begin;
        while (end < length && path[end] != L'/') {
            wchar_t c = path[end];
            if (c < 32 || c == L'\\' || c == L':' || c == L'<' || c == L'>' ||
                c == L'"' || c == L'|' || c == L'?' || c == L'*') return 0;
            end++;
        }
        size_t count = end - begin;
        if (count == 0 || count > 255 || path[end - 1] == L'.' || path[end - 1] == L' ' ||
            reserved_component(path + begin, count)) return 0;
        begin = end + 1;
        if (begin == length) return 0; /* repeated final slash */
    }
    return 1;
}

static wchar_t *utf8_path(const char *text) {
    int count;
    wchar_t *result;
    if (text == NULL) return NULL;
    count = MultiByteToWideChar(CP_UTF8, MB_ERR_INVALID_CHARS, text, -1, NULL, 0);
    if (count <= 0 || count > 32702) return NULL;
    result = malloc((size_t)count * sizeof(*result));
    if (result == NULL) return NULL;
    if (MultiByteToWideChar(CP_UTF8, MB_ERR_INVALID_CHARS, text, -1, result, count) != count) {
        free(result);
        return NULL;
    }
    return result;
}

static int supported_type(struct archive_entry *entry) {
    int type = archive_entry_filetype(entry);
    if (type != AE_IFREG && type != AE_IFDIR) return 0;
    if (archive_entry_symlink_w(entry) != NULL || archive_entry_symlink_utf8(entry) != NULL ||
        archive_entry_hardlink_is_set(entry)) return 0;
    return type != AE_IFREG || archive_entry_size(entry) >= 0;
}

/* archive_read_data fills sparse holes, preserving offsets without using
 * archive_write_data_block on a sequential PAX writer. */
static int copy_data(struct archive *reader, struct archive *writer, int64_t expected_size) {
    unsigned char buffer[64 * 1024];
    uint64_t total = 0;
    for (;;) {
        la_ssize_t count = archive_read_data(reader, buffer, sizeof(buffer));
        if (count < 0) return archive_error("read entry data", reader);
        if (count == 0) return total == (uint64_t)expected_size ? 0 : fixed_error("entry data is incomplete");
        if ((uint64_t)count > (uint64_t)expected_size - total)
            return fixed_error("entry data exceeds its declared size");
        size_t offset = 0;
        while (offset < (size_t)count) {
            la_ssize_t wrote = archive_write_data(writer, buffer + offset, (size_t)count - offset);
            if (wrote <= 0 || (size_t)wrote > (size_t)count - offset)
                return archive_error("write entry data", writer);
            offset += (size_t)wrote;
        }
        total += (uint64_t)count;
    }
}

static int create_archive(void) {
    struct archive *disk = NULL;
    struct archive *writer = NULL;
    struct archive_entry *entry = NULL;
    int result = 1;
    int status;
    DWORD attributes = GetFileAttributesW(L"dinox");
    if (attributes == INVALID_FILE_ATTRIBUTES || !(attributes & FILE_ATTRIBUTE_DIRECTORY) ||
        (attributes & FILE_ATTRIBUTE_REPARSE_POINT))
        return fixed_error("create requires a real dinox directory in the working directory");
    disk = archive_read_disk_new();
    writer = archive_write_new();
    entry = archive_entry_new();
    if (disk == NULL || writer == NULL || entry == NULL) {
        fixed_error("cannot allocate archive objects");
        goto done;
    }
    if (archive_read_disk_set_symlink_physical(disk) != ARCHIVE_OK ||
        archive_read_disk_open_w(disk, L"dinox") != ARCHIVE_OK) {
        archive_error("open source directory", disk);
        goto done;
    }
    if (archive_write_set_format_pax_restricted(writer) != ARCHIVE_OK ||
        archive_write_set_format_option(writer, "pax", "hdrcharset", "UTF-8") != ARCHIVE_OK ||
        archive_write_add_filter_gzip(writer) != ARCHIVE_OK ||
        archive_write_open_fd(writer, _fileno(stdout)) != ARCHIVE_OK) {
        archive_error("open PAX gzip writer", writer);
        goto done;
    }
    for (;;) {
        archive_entry_clear(entry);
        status = archive_read_next_header2(disk, entry);
        if (status == ARCHIVE_EOF) break;
        if (status != ARCHIVE_OK) {
            archive_error("read source entry", disk);
            goto done;
        }
        const wchar_t *path = archive_entry_pathname_w(entry);
        const wchar_t *source = archive_entry_sourcepath_w(entry);
        int is_directory = archive_entry_filetype(entry) == AE_IFDIR;
        if (!supported_type(entry) || !safe_path(path, is_directory) || source == NULL ||
            (!is_directory && archive_entry_nlink(entry) > 1)) {
            fixed_error("source contains an unsupported name, link, or special file");
            goto done;
        }
        attributes = GetFileAttributesW(source);
        if (attributes == INVALID_FILE_ATTRIBUTES || (attributes & FILE_ATTRIBUTE_REPARSE_POINT)) {
            fixed_error("source entry is inaccessible or a reparse point");
            goto done;
        }
        /* Validate UTF-8 representability without the broken native-MBS accessor. */
        if (archive_entry_pathname_utf8(entry) == NULL) {
            fixed_error("source entry name cannot be represented as UTF-8");
            goto done;
        }
        if (archive_read_disk_can_descend(disk) && archive_read_disk_descend(disk) != ARCHIVE_OK) {
            archive_error("descend source directory", disk);
            goto done;
        }
        if (archive_write_header(writer, entry) != ARCHIVE_OK) {
            archive_error("write PAX entry header", writer);
            goto done;
        }
        if (copy_data(disk, writer, is_directory ? 0 : archive_entry_size(entry)) != 0) goto done;
        if (archive_write_finish_entry(writer) != ARCHIVE_OK) {
            archive_error("finish PAX entry", writer);
            goto done;
        }
    }
    if (archive_read_close(disk) != ARCHIVE_OK) {
        archive_error("close source archive", disk);
        goto done;
    }
    if (archive_write_close(writer) != ARCHIVE_OK) {
        archive_error("close PAX gzip archive", writer);
        goto done;
    }
    result = 0;
done:
    archive_entry_free(entry);
    if (writer != NULL) {
        if (result != 0) archive_write_fail(writer);
        if (archive_write_free(writer) != ARCHIVE_OK) result = fixed_error("free archive writer failed");
    }
    if (disk != NULL && archive_read_free(disk) != ARCHIVE_OK) result = fixed_error("free source reader failed");
    return result;
}

static int empty_working_directory(void) {
    WIN32_FIND_DATAW data;
    HANDLE search = FindFirstFileW(L"*", &data);
    if (search == INVALID_HANDLE_VALUE) return GetLastError() == ERROR_FILE_NOT_FOUND;
    int empty = 1;
    do {
        if (wcscmp(data.cFileName, L".") != 0 && wcscmp(data.cFileName, L"..") != 0) {
            empty = 0;
            break;
        }
    } while (FindNextFileW(search, &data));
    if (empty && GetLastError() != ERROR_NO_MORE_FILES) empty = 0;
    FindClose(search);
    return empty;
}

/* A later entry may collide with an earlier one even in fresh staging:
 * NTFS resolves case variants and short-name aliases to the same object.
 * Never overwrite an existing file, and preserve the spelling of every
 * existing parent directory. Implicit directories may receive metadata. */
static int safe_destination(const wchar_t *path, int is_directory) {
    size_t length = wcslen(path);
    wchar_t *prefix = malloc((length + 1) * sizeof(*prefix));
    int safe = 0;
    if (prefix == NULL) return 0;
    wcscpy(prefix, path);
    if (length > 0 && prefix[length - 1] == L'/') prefix[--length] = L'\0';
    size_t begin = 0;
    for (size_t i = 0; i <= length; i++) {
        if (prefix[i] != L'/' && i != length) continue;
        wchar_t separator = prefix[i];
        prefix[i] = L'\0';
        DWORD attributes = GetFileAttributesW(prefix);
        if (attributes != INVALID_FILE_ATTRIBUTES) {
            WIN32_FIND_DATAW data;
            HANDLE search;
            if ((attributes & FILE_ATTRIBUTE_REPARSE_POINT) ||
                !(attributes & FILE_ATTRIBUTE_DIRECTORY) ||
                (i == length && !is_directory)) goto done;
            search = FindFirstFileW(prefix, &data);
            if (search == INVALID_HANDLE_VALUE) goto done;
            int same_name = wcscmp(data.cFileName, prefix + begin) == 0;
            FindClose(search);
            if (!same_name) goto done;
        } else {
            DWORD error = GetLastError();
            if (error != ERROR_FILE_NOT_FOUND && error != ERROR_PATH_NOT_FOUND) goto done;
        }
        prefix[i] = separator;
        begin = i + 1;
    }
    safe = 1;
done:
    free(prefix);
    return safe;
}

static int extract_archive(void) {
    struct archive *reader = NULL;
    struct archive *disk = NULL;
    struct archive_entry *entry = NULL;
    int result = 1;
    int status;
    size_t entries = 0;
    if (!empty_working_directory()) return fixed_error("extract requires an empty working directory");
    reader = archive_read_new();
    disk = archive_write_disk_new();
    if (reader == NULL || disk == NULL) {
        fixed_error("cannot allocate archive objects");
        goto done;
    }
    if (archive_read_support_filter_gzip(reader) != ARCHIVE_OK ||
        archive_read_support_format_tar(reader) != ARCHIVE_OK ||
        archive_read_set_format_option(reader, "tar", "hdrcharset", "UTF-8") != ARCHIVE_OK ||
        archive_read_open_fd(reader, _fileno(stdin), 64 * 1024) != ARCHIVE_OK) {
        archive_error("open tar gzip reader", reader);
        goto done;
    }
    if (archive_write_disk_set_options(disk,
            ARCHIVE_EXTRACT_TIME | ARCHIVE_EXTRACT_PERM |
            ARCHIVE_EXTRACT_SECURE_NOABSOLUTEPATHS | ARCHIVE_EXTRACT_SECURE_NODOTDOT |
            ARCHIVE_EXTRACT_SECURE_SYMLINKS) != ARCHIVE_OK) {
        archive_error("configure secure extraction", disk);
        goto done;
    }
    while ((status = archive_read_next_header(reader, &entry)) != ARCHIVE_EOF) {
        if (status != ARCHIVE_OK) {
            archive_error("read archived entry", reader);
            goto done;
        }
        if (archive_filter_code(reader, 0) != ARCHIVE_FILTER_GZIP) {
            fixed_error("input must be a gzip-compressed tar archive");
            goto done;
        }
        wchar_t *path = utf8_path(archive_entry_pathname_utf8(entry));
        int is_directory = archive_entry_filetype(entry) == AE_IFDIR;
        if (!supported_type(entry) || !safe_path(path, is_directory)) {
            free(path);
            fixed_error("archive contains an unsafe name, link, or special file");
            goto done;
        }
        if (!safe_destination(path, is_directory)) {
            free(path);
            fixed_error("archive entry collides with an existing file or directory name");
            goto done;
        }
        archive_entry_copy_pathname_w(entry, path);
        free(path);
        if (archive_write_header(disk, entry) != ARCHIVE_OK) {
            archive_error("create restored entry", disk);
            goto done;
        }
        if (copy_data(reader, disk, is_directory ? 0 : archive_entry_size(entry)) != 0) goto done;
        if (archive_write_finish_entry(disk) != ARCHIVE_OK) {
            archive_error("finish restored entry", disk);
            goto done;
        }
        entries++;
    }
    if (entries == 0) {
        fixed_error("archive contains no DinoX entries");
        goto done;
    }
    if (archive_read_close(reader) != ARCHIVE_OK) {
        archive_error("close tar gzip reader", reader);
        goto done;
    }
    if (archive_write_close(disk) != ARCHIVE_OK) {
        archive_error("close restored files", disk);
        goto done;
    }
    result = 0;
done:
    if (disk != NULL) {
        /* write_disk must close open files and pending directory fixups even
         * on failure. The caller discards this fresh staging tree on failure. */
        if (archive_write_free(disk) != ARCHIVE_OK) result = fixed_error("free extraction writer failed");
    }
    if (reader != NULL && archive_read_free(reader) != ARCHIVE_OK) result = fixed_error("free archive reader failed");
    return result;
}

int main(int argc, char **argv) {
    if (argc == 2 && strcmp(argv[1], "--version") == 0) {
        printf("DinoX backup archive helper 1 (%s)\n", archive_version_string());
        return 0;
    }
    if (argc != 2 || (strcmp(argv[1], "create") != 0 && strcmp(argv[1], "extract") != 0))
        return fixed_error("usage: dinox-backup-tar.exe create|extract");
    if (setlocale(LC_ALL, "C") == NULL) return fixed_error("cannot select controlled C locale");
    if (_setmode(_fileno(stdin), _O_BINARY) < 0 || _setmode(_fileno(stdout), _O_BINARY) < 0)
        return fixed_error("cannot select binary standard streams");
    return strcmp(argv[1], "create") == 0 ? create_archive() : extract_archive();
}
