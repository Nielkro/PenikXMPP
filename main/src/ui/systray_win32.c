/*
 * Win32 Shell_NotifyIcon systray helper for DinoX.
 *
 * Creates a hidden message-only window to receive WM_APP tray callbacks,
 * uses Shell_NotifyIconW for the notification-area icon, and
 * CreatePopupMenu / TrackPopupMenu for the right-click context menu.
 *
 * All Win32 calls use the wide (W) variants.  UTF-8 ↔ UTF-16 conversion
 * is done via GLib's g_utf8_to_utf16().
 *
 * Thread safety: all functions must be called from the GTK main thread
 * (which owns the GDK Win32 display and message pump).
 */

#include "systray_win32.h"

#ifdef _WIN32

#include <windows.h>
#include <shellapi.h>
#include <objbase.h>
#include <oleacc.h>
#include <stdarg.h>
#include <stdio.h>
#include <stdlib.h>   /* _set_invalid_parameter_handler */
#include <glib/gstdio.h>

/* Ensure definitions for older MinGW-w64 / SDK headers. */
#ifndef NOTIFYICON_VERSION_4
#define NOTIFYICON_VERSION_4  4
#endif
#ifndef NIN_SELECT
#define NIN_SELECT      (WM_USER + 0)
#endif
#ifndef NIN_KEYSELECT
#define NIN_KEYSELECT   (WM_USER + 1)
#endif
#ifndef NIF_SHOWTIP
#define NIF_SHOWTIP     0x00000080
#endif

#define WM_TRAYICON  (WM_APP + 1)
#define MAX_MENU_ITEMS 32
#define SYSTRAY_BUILD_ID "2026-10-12-v10"

/* Menu icons are drawn with GDI at the current monitor DPI. Owner-drawn
 * names are exposed through MSAAMENUINFO; high contrast uses native items. */

/* ---- state ---- */
static HWND            msg_hwnd   = NULL;
static NOTIFYICONDATAW nid        = {0};
static HMENU           popup_menu = NULL;
static gboolean        initialised = FALSE;

static SystrayWin32Callback user_callback = NULL;
static gpointer             user_data_ptr = NULL;

typedef struct {
    gchar *title, *body, *key;
    int icon_type;
    SystrayWin32BalloonCallback callback;
    gpointer data;
    GDestroyNotify destroy;
    gboolean shown, cancelled;
} Balloon;
static GQueue balloon_queue = G_QUEUE_INIT;
static Balloon *active_balloon = NULL;
static guint balloon_pump_source = 0;
#define MAX_QUEUED_BALLOONS 64

typedef struct {
    MSAAMENUINFO accessible; /* Must be first: native screen-reader name. */
    wchar_t *text;
    int icon;
    gboolean separator, checked;
} TrayMenuItem;
static TrayMenuItem *menu_items[MAX_MENU_ITEMS] = {0};
static gchar **menu_labels = NULL;
static gint menu_icons[MAX_MENU_ITEMS] = {0};
static guint32 menu_checks = 0;
static gboolean menu_dark = FALSE, menu_website = FALSE, menu_open = FALSE, menu_dirty = FALSE;
static gboolean menu_high_contrast = FALSE;
static UINT menu_dpi = 96;
static int menu_max_width = 420;
static HFONT menu_font = NULL;
static HBRUSH menu_background = NULL;

static UINT            WM_TASKBARCREATED = 0;
static int             saved_icon_resource_id = 1;
static gboolean        using_version_4 = FALSE;
static FILE           *tray_log_file = NULL;

static HANDLE          single_instance_mutex = NULL;
static DWORD           last_context_menu_tick = 0;

#define WM_ACTIVATE_INSTANCE  (WM_APP + 2)

/* ---- debug log → %TEMP%/dinox_systray.log ---- */
static void
tray_log (const char *fmt, ...)
{
    va_list ap;
    va_start (ap, fmt);

    if (tray_log_file == NULL) {
        /* Prefer %TEMP% (native Windows path) over g_get_tmp_dir()
         * which returns MSYS2-style /tmp on MinGW builds. */
        const char *tmp = g_getenv ("TEMP");
        if (tmp == NULL || tmp[0] == '\0')
            tmp = g_getenv ("TMP");
        if (tmp == NULL || tmp[0] == '\0')
            tmp = g_get_tmp_dir ();
        char *path = g_build_filename (tmp, "dinox_systray.log", NULL);
        tray_log_file = g_fopen (path, "w");
        g_free (path);
        if (tray_log_file) {
            fprintf (tray_log_file, "=== DinoX Systray Debug Log ===\n");
            fprintf (tray_log_file, "Build: %s\n\n", SYSTRAY_BUILD_ID);
        }
    }
    if (tray_log_file) {
        va_list copy;
        va_copy (copy, ap);
        vfprintf (tray_log_file, fmt, copy);
        va_end (copy);
        fprintf (tray_log_file, "\n");
        fflush (tray_log_file);
    }

    g_logv ("Systray", G_LOG_LEVEL_MESSAGE, fmt, ap);
    va_end (ap);
}

static void
tray_log_file_only (const char *fmt, ...)
{
    va_list ap;
    va_start (ap, fmt);

    if (tray_log_file == NULL) {
        const char *tmp = g_getenv ("TEMP");
        if (tmp == NULL || tmp[0] == '\0')
            tmp = g_getenv ("TMP");
        if (tmp == NULL || tmp[0] == '\0')
            tmp = g_get_tmp_dir ();
        char *path = g_build_filename (tmp, "dinox_systray.log", NULL);
        tray_log_file = g_fopen (path, "w");
        g_free (path);
        if (tray_log_file) {
            fprintf (tray_log_file, "=== DinoX Systray Debug Log ===\n");
            fprintf (tray_log_file, "Build: %s\n\n", SYSTRAY_BUILD_ID);
        }
    }
    if (tray_log_file) {
        vfprintf (tray_log_file, fmt, ap);
        fprintf (tray_log_file, "\n");
        fflush (tray_log_file);
    }

    va_end (ap);
}

/* ---- suppress taskbar Jump List "launch" entry ---- */
/*
 * Windows shows a "DinoX" launch entry in the taskbar right-click menu by
 * default.  Since left-clicking the taskbar button already toggles the
 * window, the extra entry is redundant and confusing.  Setting an empty
 * custom jump list via ICustomDestinationList removes it while keeping the
 * "Pin to taskbar" and "Close window" entries intact.
 *
 * Additionally, SetCurrentProcessExplicitAppUserModelID is called so
 * that Windows associates the correct App ID with our process — this is
 * required for the jump-list suppression to stick and prevents Windows
 * from auto-generating a launch shortcut based on the executable path.
 */

/* SetCurrentProcessExplicitAppUserModelID (shell32.dll) */
typedef HRESULT (WINAPI *pfn_SetAppUserModelID)(PCWSTR);

/* ICustomDestinationList {6332DEBF-87B5-4670-90C0-5E57B408A49E} */
static const IID IID_ICustomDestinationList = {
    0x6332DEBF, 0x87B5, 0x4670,
    { 0x90, 0xC0, 0x5E, 0x57, 0xB4, 0x08, 0xA4, 0x9E }
};
/* CLSID_DestinationList {77F10CF0-3DB5-4966-B520-B7C54FD35ED6} */
static const CLSID CLSID_DestinationList = {
    0x77F10CF0, 0x3DB5, 0x4966,
    { 0xB5, 0x20, 0xB7, 0xC5, 0x4F, 0xD3, 0x5E, 0xD6 }
};

static void
suppress_jumplist (void)
{
    HRESULT hr;
    void *cdl = NULL;

    /* 1) Set explicit AppUserModelID so Windows associates our process
     *    with a stable ID instead of auto-generating one from the exe path. */
    HMODULE shell32 = GetModuleHandleW (L"shell32.dll");
    if (shell32) {
        pfn_SetAppUserModelID pSetID = (pfn_SetAppUserModelID)
            GetProcAddress (shell32, "SetCurrentProcessExplicitAppUserModelID");
        if (pSetID) {
            hr = pSetID (L"im.dinox.dinox");
            tray_log ("suppress_jumplist: SetAppUserModelID %s (0x%08lx)",
                      SUCCEEDED (hr) ? "OK" : "FAILED", (unsigned long) hr);
        }
    }

    /* 2) Delete any existing jump list, then commit an empty one. */
    hr = CoInitializeEx (NULL, COINIT_APARTMENTTHREADED);
    gboolean did_coinit = SUCCEEDED (hr);

    hr = CoCreateInstance (&CLSID_DestinationList, NULL, CLSCTX_INPROC_SERVER,
                           &IID_ICustomDestinationList, &cdl);
    if (FAILED (hr) || cdl == NULL) {
        tray_log ("suppress_jumplist: CoCreateInstance failed (0x%08lx)", (unsigned long) hr);
        if (did_coinit) CoUninitialize ();
        return;
    }

    /* ICustomDestinationList vtable layout (IUnknown + interface):
     * 0: QueryInterface  1: AddRef  2: Release
     * 3: SetAppID  4: BeginList  5: AppendCategory
     * 6: AppendKnownCategory  7: AddUserTasks  8: CommitList
     * 9: GetRemovedDestinations  10: DeleteList  11: AbortList */

    typedef HRESULT (STDMETHODCALLTYPE *pfn_SetAppID)(void *, LPCWSTR);
    typedef HRESULT (STDMETHODCALLTYPE *pfn_BeginList)(void *, UINT *, const IID *, void **);
    typedef HRESULT (STDMETHODCALLTYPE *pfn_CommitList)(void *);
    typedef HRESULT (STDMETHODCALLTYPE *pfn_DeleteList)(void *, LPCWSTR);
    typedef ULONG   (STDMETHODCALLTYPE *pfn_Release)(void *);

    void **vtbl = *(void ***)cdl;

    /* SetAppID on the destination list object */
    hr = ((pfn_SetAppID)vtbl[3])(cdl, L"im.dinox.dinox");
    tray_log ("suppress_jumplist: CDL.SetAppID %s (0x%08lx)",
              SUCCEEDED (hr) ? "OK" : "FAILED", (unsigned long) hr);

    /* DeleteList — removes the entire custom jump list for our AppID. */
    hr = ((pfn_DeleteList)vtbl[10])(cdl, L"im.dinox.dinox");
    tray_log ("suppress_jumplist: DeleteList %s (0x%08lx)",
              SUCCEEDED (hr) ? "OK" : "FAILED", (unsigned long) hr);

    /* Also do BeginList + CommitList with zero entries (belt and suspenders). */
    UINT min_slots = 0;
    void *removed = NULL;
    /* IID_IObjectArray {92CA9DCD-5622-4BBA-A805-5E9F541BD8C9} */
    static const IID IID_IObjectArray = {
        0x92CA9DCD, 0x5622, 0x4BBA,
        { 0xA8, 0x05, 0x5E, 0x9F, 0x54, 0x1B, 0xD8, 0xC9 }
    };

    hr = ((pfn_BeginList)vtbl[4])(cdl, &min_slots, &IID_IObjectArray, &removed);
    if (SUCCEEDED (hr)) {
        hr = ((pfn_CommitList)vtbl[8])(cdl);
        tray_log ("suppress_jumplist: CommitList %s (0x%08lx)",
                  SUCCEEDED (hr) ? "OK" : "FAILED", (unsigned long) hr);
        /* Release the removed-destinations array */
        if (removed) {
            void **rv = *(void ***)removed;
            ((pfn_Release)rv[2])(removed);
        }
    } else {
        tray_log ("suppress_jumplist: BeginList failed (0x%08lx)", (unsigned long) hr);
    }

    ((pfn_Release)vtbl[2])(cdl);
    if (did_coinit) CoUninitialize ();
}

/* ---- forward ---- */
static LRESULT CALLBACK wnd_proc (HWND, UINT, WPARAM, LPARAM);

/* ---- helpers ---- */
static wchar_t *
utf8_to_wchar (const gchar *s)
{
    if (s == NULL) return NULL;
    glong len = 0;
    gunichar2 *w = g_utf8_to_utf16 (s, -1, NULL, &len, NULL);
    return (wchar_t *) w;
}

/* Shell fields have fixed UTF-16 capacities, not Unicode-character limits.
 * Leave room for NUL without splitting an emoji's surrogate pair. */
static void
copy_shell_text (wchar_t *destination, gsize capacity, const gchar *utf8)
{
    if (capacity == 0) return;
    memset (destination, 0, capacity * sizeof *destination);
    wchar_t *wide = utf8_to_wchar (utf8);
    if (wide == NULL) return;
    gsize count = MIN (wcslen (wide), capacity - 1);
    if (count > 0 && wide[count - 1] >= 0xd800 && wide[count - 1] <= 0xdbff)
        count--;
    memcpy (destination, wide, count * sizeof *destination);
    g_free (wide);
}

static gboolean
set_hkcu_reg_string (const wchar_t *subkey,
                     const wchar_t *name,
                     const wchar_t *value)
{
    HKEY key;
    LONG res = RegCreateKeyExW (HKEY_CURRENT_USER, subkey, 0, NULL, 0,
                                KEY_WRITE, NULL, &key, NULL);
    if (res != ERROR_SUCCESS) {
        tray_log ("register_xmpp: RegCreateKeyExW failed for %ls (0x%lx)",
                  subkey, (unsigned long) res);
        return FALSE;
    }

    res = RegSetValueExW (key, name, 0, REG_SZ, (const BYTE *) value,
                          (DWORD) ((wcslen (value) + 1) * sizeof (wchar_t)));
    RegCloseKey (key);
    if (res != ERROR_SUCCESS) {
        tray_log ("register_xmpp: RegSetValueExW failed for %ls (0x%lx)",
                  subkey, (unsigned long) res);
        return FALSE;
    }
    return TRUE;
}

/* ---- public API ---- */

gboolean
systray_win32_check_single_instance (void)
{
    single_instance_mutex = CreateMutexW (NULL, FALSE,
                                          L"DinoX_SingleInstance_Mutex");
    if (GetLastError () == ERROR_ALREADY_EXISTS) {
        /* Another instance is already running.  The caller may need to write
         * startup payload first, so activation is a separate API. */
        if (single_instance_mutex) {
            CloseHandle (single_instance_mutex);
            single_instance_mutex = NULL;
        }
        return FALSE;   /* caller should exit */
    }
    tray_log ("Single-instance mutex acquired — we are the primary");
    return TRUE;   /* we are the primary instance */
}

gboolean
systray_win32_activate_existing_instance (void)
{
    HWND existing = FindWindowW (L"DinoXSystrayMsg", NULL);
    if (existing == NULL) {
        tray_log ("activate_existing_instance: no tray message window found");
        return FALSE;
    }
    PostMessageW (existing, WM_ACTIVATE_INSTANCE, 0, 0);
    tray_log ("activate_existing_instance: sent activate to hwnd=%p",
              (void *) existing);
    return TRUE;
}

gboolean
systray_win32_register_xmpp_protocol_handler (const gchar *exe_path_utf8)
{
    wchar_t *exe_path = utf8_to_wchar (exe_path_utf8);
    if (exe_path == NULL || exe_path[0] == L'\0') {
        g_free (exe_path);
        return FALSE;
    }

    size_t command_len = wcslen (exe_path) + 8; /* quotes, space, "%1", NUL */
    wchar_t *command = g_new0 (wchar_t, command_len);
    _snwprintf (command, command_len, L"\"%ls\" \"%%1\"", exe_path);
    command[command_len - 1] = L'\0';

    size_t icon_len = wcslen (exe_path) + 4; /* quotes, NUL */
    wchar_t *icon = g_new0 (wchar_t, icon_len);
    _snwprintf (icon, icon_len, L"\"%ls\"", exe_path);
    icon[icon_len - 1] = L'\0';

    gboolean ok = TRUE;
    ok = set_hkcu_reg_string (L"Software\\Classes\\xmpp", NULL, L"URL:XMPP Protocol") && ok;
    ok = set_hkcu_reg_string (L"Software\\Classes\\xmpp", L"URL Protocol", L"") && ok;
    ok = set_hkcu_reg_string (L"Software\\Classes\\xmpp\\DefaultIcon", NULL, icon) && ok;
    ok = set_hkcu_reg_string (L"Software\\Classes\\xmpp\\shell\\open\\command", NULL, command) && ok;

    tray_log ("register_xmpp: %s", ok ? "OK" : "FAILED");
    g_free (icon);
    g_free (command);
    g_free (exe_path);
    return ok;
}

gboolean
systray_win32_open_file (const gchar *path_utf8)
{
    wchar_t *path = utf8_to_wchar (path_utf8);
    if (path == NULL || path[0] == L'\0') {
        g_free (path);
        return FALSE;
    }

    HINSTANCE res = ShellExecuteW (NULL, L"open", path, NULL, NULL, SW_SHOWNORMAL);
    gboolean ok = ((INT_PTR) res) > 32;
    if (!ok) {
        tray_log ("open_file: ShellExecuteW failed for path, code=%ld", (long) (INT_PTR) res);
    }

    g_free (path);
    return ok;
}

gboolean
systray_win32_foreground_window_is_external (void)
{
    HWND foreground = GetForegroundWindow ();
    DWORD process_id = 0;

    if (foreground == NULL)
        return FALSE;

    GetWindowThreadProcessId (foreground, &process_id);
    return process_id != 0 && process_id != GetCurrentProcessId ();
}

gboolean
systray_win32_init (const gchar          *tooltip_utf8,
                    int                   icon_resource_id,
                    SystrayWin32Callback  callback,
                    gpointer              user_data)
{
    if (initialised) return TRUE;

    user_callback  = callback;
    user_data_ptr  = user_data;

    /* Register a minimal window class for the tray callback window. */
    WNDCLASSEXW wc = {0};
    wc.cbSize        = sizeof (wc);
    wc.lpfnWndProc   = wnd_proc;
    wc.hInstance      = GetModuleHandleW (NULL);
    wc.lpszClassName  = L"DinoXSystrayMsg";
    RegisterClassExW (&wc);

    /* Use a normal hidden window (not HWND_MESSAGE) for better compatibility
     * with Windows 10/11 message dispatch.  WS_EX_TOOLWINDOW prevents a
     * taskbar entry; the 0×0 size keeps it invisible. */
    msg_hwnd = CreateWindowExW (WS_EX_TOOLWINDOW,
                                L"DinoXSystrayMsg", L"DinoX Tray",
                                WS_POPUP, 0, 0, 0, 0,
                                NULL, NULL,
                                GetModuleHandleW (NULL), NULL);
    if (msg_hwnd == NULL) {
        tray_log ("CreateWindowExW failed (error %lu)", GetLastError ());
        return FALSE;
    }

    saved_icon_resource_id = icon_resource_id;

    /* Register "TaskbarCreated" message — Explorer sends this after restart. */
    WM_TASKBARCREATED = RegisterWindowMessageW (L"TaskbarCreated");

    /* Load icon at the correct small-icon size for the notification area. */
    int cx = GetSystemMetrics (SM_CXSMICON);
    int cy = GetSystemMetrics (SM_CYSMICON);
    HICON icon = (HICON) LoadImageW (GetModuleHandleW (NULL),
                                      MAKEINTRESOURCEW (icon_resource_id),
                                      IMAGE_ICON, cx, cy, LR_DEFAULTCOLOR);
    if (icon == NULL) {
        /* Fallback: load at default size. */
        icon = LoadIconW (GetModuleHandleW (NULL),
                          MAKEINTRESOURCEW (icon_resource_id));
    }
    if (icon == NULL) {
        /* Last resort: standard application icon. */
        icon = LoadIconW (NULL, MAKEINTRESOURCEW (32512));
    }
    tray_log ("Icon loaded: %p (resource %d, size %dx%d)",
              (void *) icon, icon_resource_id, cx, cy);

    /* Set up NOTIFYICONDATAW. */
    memset (&nid, 0, sizeof (nid));
    nid.cbSize           = sizeof (nid);
    nid.hWnd             = msg_hwnd;
    nid.uID              = 1;
    nid.uFlags           = NIF_ICON | NIF_MESSAGE | NIF_TIP;
    nid.uCallbackMessage = WM_TRAYICON;
    nid.hIcon            = icon;

    copy_shell_text (nid.szTip, G_N_ELEMENTS (nid.szTip), tooltip_utf8);

    if (!Shell_NotifyIconW (NIM_ADD, &nid)) {
        tray_log ("Shell_NotifyIconW(NIM_ADD) FAILED (error %lu)", GetLastError ());
        DestroyWindow (msg_hwnd);
        msg_hwnd = NULL;
        return FALSE;
    }

    /* Try NOTIFYICON_VERSION_4 (Windows Vista+), fall back to v3. */
    nid.uVersion = NOTIFYICON_VERSION_4;
    if (Shell_NotifyIconW (NIM_SETVERSION, &nid)) {
        using_version_4 = TRUE;
        tray_log ("Using NOTIFYICON_VERSION_4");
        /* V4 requires NIF_SHOWTIP for tooltip to appear. */
        nid.uFlags |= NIF_SHOWTIP;
        Shell_NotifyIconW (NIM_MODIFY, &nid);
    } else {
        nid.uVersion = NOTIFYICON_VERSION;
        Shell_NotifyIconW (NIM_SETVERSION, &nid);
        using_version_4 = FALSE;
        tray_log ("Using NOTIFYICON_VERSION (v3 fallback)");
    }

    initialised = TRUE;
    tray_log ("=== Tray icon created ===");
    tray_log ("  hwnd       = %p", (void *) msg_hwnd);
    tray_log ("  version    = %s", using_version_4 ? "V4" : "V3");
    tray_log ("  build      = %s", SYSTRAY_BUILD_ID);
    tray_log ("  WM_CLOSE   = protected (return 0)");
    tray_log ("  RBUTTONUP  = handled in ALL modes");
    tray_log ("  mutex      = %p", (void *) single_instance_mutex);
    tray_log ("========================");

    /* Remove the "DinoX" launch entry from the taskbar right-click menu.
     * Left-click already toggles the window, so the extra item is redundant. */
    suppress_jumplist ();

    /* Create an empty popup menu (will be filled by set_menu). */
    popup_menu = CreatePopupMenu ();

    return TRUE;
}

static int menu_px (int value) { return MulDiv (value, (int) menu_dpi, 96); }
static COLORREF menu_bg (void) {
    if (menu_website) return menu_dark ? RGB (26, 41, 34) : RGB (255, 255, 255);
    return menu_dark ? RGB (34, 35, 39) : RGB (250, 250, 252);
}
static COLORREF menu_fg (void) {
    if (menu_website) return menu_dark ? RGB (236, 241, 233) : RGB (32, 55, 47);
    return menu_dark ? RGB (242, 243, 245) : RGB (35, 38, 43);
}

static gboolean
high_contrast_enabled (void)
{
    HIGHCONTRASTW hc = {0};
    hc.cbSize = sizeof hc;
    return SystemParametersInfoW (SPI_GETHIGHCONTRAST, sizeof hc, &hc, 0)
        && (hc.dwFlags & HCF_HIGHCONTRASTON) != 0;
}

static void
clear_menu_items (void)
{
    for (int i = 0; i < MAX_MENU_ITEMS; i++) {
        if (menu_items[i]) {
            g_free (menu_items[i]->text);
            g_free (menu_items[i]);
            menu_items[i] = NULL;
        }
    }
}

static void
rebuild_native_menu (void)
{
    if (menu_open) { menu_dirty = TRUE; return; }
    if (popup_menu) DestroyMenu (popup_menu);
    popup_menu = CreatePopupMenu ();
    clear_menu_items ();
    if (menu_background) { DeleteObject (menu_background); menu_background = NULL; }
    if (!popup_menu) return;
    menu_high_contrast = high_contrast_enabled ();
    if (!menu_high_contrast) {
        menu_background = CreateSolidBrush (menu_bg ());
        MENUINFO info = {0};
        info.cbSize = sizeof info;
        info.fMask = MIM_BACKGROUND;
        info.hbrBack = menu_background;
        SetMenuInfo (popup_menu, &info);
    }
    if (!menu_labels) return;
    for (int i = 0; menu_labels[i] && i < MAX_MENU_ITEMS; i++) {
        TrayMenuItem *item = g_new0 (TrayMenuItem, 1);
        item->text = utf8_to_wchar (menu_labels[i]);
        if (!item->text) item->text = utf8_to_wchar ("");
        item->accessible.dwMSAASignature = MSAA_MENU_SIG;
        item->accessible.cchWText = (DWORD) wcslen (item->text);
        item->accessible.pszWText = item->text;
        item->icon = menu_icons[i];
        item->separator = item->text[0] == L'\0';
        item->checked = (menu_checks & (1u << i)) != 0;
        menu_items[i] = item;
        MENUITEMINFOW mi = {0};
        mi.cbSize = sizeof mi;
        mi.fMask = MIIM_ID | MIIM_FTYPE | MIIM_STATE | MIIM_DATA;
        mi.wID = (UINT) i + 1;
        mi.fType = item->separator ? MFT_SEPARATOR : MFT_STRING;
        if (!menu_high_contrast) mi.fType |= MFT_OWNERDRAW;
        if (item->icon >= 2 && item->icon <= 5) mi.fType |= MFT_RADIOCHECK;
        mi.fState = item->checked ? MFS_CHECKED : MFS_UNCHECKED;
        mi.dwItemData = (ULONG_PTR) item;
        // Keep the plain name even for custom drawing and accessibility.
        mi.fMask |= MIIM_STRING;
        wchar_t *native_text = NULL;
        if (menu_high_contrast) {
            gsize length = wcslen (item->text), out = 0;
            native_text = g_new (wchar_t, length * 2 + 1);
            for (gsize n = 0; n < length; n++) {
                if (item->text[n] == L'&') native_text[out++] = L'&';
                native_text[out++] = item->text[n];
            }
            native_text[out] = 0;
        }
        mi.dwTypeData = native_text ? native_text : item->text;
        InsertMenuItemW (popup_menu, (UINT) i, TRUE, &mi);
        g_free (native_text);
    }
    menu_dirty = FALSE;
}

void
systray_win32_set_menu (gchar **labels, const gint *icons, guint32 checked_mask)
{
    g_strfreev (menu_labels);
    menu_labels = labels ? g_strdupv (labels) : NULL;
    memset (menu_icons, 0, sizeof menu_icons);
    if (icons && labels) {
        for (int i = 0; labels[i] && i < MAX_MENU_ITEMS; i++) menu_icons[i] = icons[i];
    }
    menu_checks = checked_mask;
    if (initialised) rebuild_native_menu ();
}

void
systray_win32_set_menu_theme (gboolean dark, gboolean website)
{
    menu_dark = dark;
    menu_website = website;
    if (initialised) rebuild_native_menu ();
}

static void
configure_menu_monitor (POINT anchor)
{
    HMONITOR monitor = MonitorFromPoint (anchor, MONITOR_DEFAULTTONEAREST);
    // Resolve optional DPI APIs without raising the minimum Windows version.
    HMODULE shcore = LoadLibraryW (L"shcore.dll");
    typedef HRESULT (WINAPI *MonitorDpiFunc)(HMONITOR, int, UINT*, UINT*);
    MonitorDpiFunc get_monitor_dpi = NULL;
    FARPROC proc = shcore ? GetProcAddress (shcore, "GetDpiForMonitor") : NULL;
    if (proc) memcpy (&get_monitor_dpi, &proc, sizeof get_monitor_dpi);
    UINT x = 96, y = 96;
    if (get_monitor_dpi && FAILED (get_monitor_dpi (monitor, 0, &x, &y))) x = 96;
    if (shcore) FreeLibrary (shcore);
    menu_dpi = MAX (x, 96u);
    MONITORINFO mon = {0}; mon.cbSize = sizeof mon;
    menu_max_width = menu_px (420);
    if (GetMonitorInfoW (monitor, &mon)) {
        menu_max_width = MIN (menu_max_width,
            MAX (menu_px (120), (int) (mon.rcWork.right - mon.rcWork.left) - menu_px (24)));
    }
    NONCLIENTMETRICSW metrics = {0}; metrics.cbSize = sizeof metrics;
    typedef BOOL (WINAPI *ParametersDpiFunc)(UINT, UINT, PVOID, UINT, UINT);
    ParametersDpiFunc parameters_dpi = NULL;
    proc = GetProcAddress (GetModuleHandleW (L"user32.dll"), "SystemParametersInfoForDpi");
    if (proc) memcpy (&parameters_dpi, &proc, sizeof parameters_dpi);
    if (!parameters_dpi || !parameters_dpi (SPI_GETNONCLIENTMETRICS,
            sizeof metrics, &metrics, 0, menu_dpi)) {
        if (SystemParametersInfoW (SPI_GETNONCLIENTMETRICS, sizeof metrics, &metrics, 0)) {
            HDC dc = GetDC (NULL);
            int system_dpi = dc ? GetDeviceCaps (dc, LOGPIXELSY) : 96;
            if (dc) ReleaseDC (NULL, dc);
            metrics.lfMenuFont.lfHeight = MulDiv (metrics.lfMenuFont.lfHeight,
                (int) menu_dpi, MAX (system_dpi, 1));
        } else {
            metrics.lfMenuFont.lfHeight = -menu_px (14);
            wcscpy (metrics.lfMenuFont.lfFaceName, L"Segoe UI");
        }
    }
    if (menu_font) DeleteObject (menu_font);
    menu_font = CreateFontIndirectW (&metrics.lfMenuFont);
    rebuild_native_menu ();
}

static void
stroke_line (HDC dc, int x1, int y1, int x2, int y2)
{
    MoveToEx (dc, x1, y1, NULL); LineTo (dc, x2, y2);
}

static void
paint_menu_icon (HDC dc, TrayMenuItem *item, int x, int y, COLORREF foreground)
{
    int z = menu_px (16), q = MAX (1, menu_px (2));
    HPEN pen = CreatePen (PS_SOLID, q, foreground);
    HGDIOBJ old_pen = SelectObject (dc, pen);
    HGDIOBJ old_brush = SelectObject (dc, GetStockObject (NULL_BRUSH));
    if (item->icon >= 2 && item->icon <= 5) {
        COLORREF colors[] = {RGB(37,171,112), RGB(222,154,38), RGB(219,72,83), RGB(135,143,155)};
        HBRUSH fill = CreateSolidBrush (colors[item->icon - 2]);
        SelectObject (dc, fill);
        Ellipse (dc, x + q, y + q, x + z - q, y + z - q);
        SelectObject (dc, old_brush); DeleteObject (fill);
    } else if (item->icon == 1) { // Main window
        RoundRect (dc, x, y, x + z, y + z, q, q);
        stroke_line (dc, x, y + q * 2, x + z, y + q * 2);
    } else if (item->icon == 6) { // Status message
        RoundRect (dc, x, y, x + z, y + z - q * 2, q * 2, q * 2);
        stroke_line (dc, x + q * 2, y + z - q * 2, x + q, y + z);
        stroke_line (dc, x + q, y + z, x + q * 4, y + z - q * 2);
    } else if (item->icon == 7) { // Speaker and outward sound waves
        POINT horn[] = {{x,y+menu_px(6)},{x+menu_px(3),y+menu_px(6)},
            {x+menu_px(7),y+menu_px(2)},{x+menu_px(7),y+menu_px(14)},
            {x+menu_px(3),y+menu_px(10)},{x,y+menu_px(10)}};
        Polygon (dc, horn, G_N_ELEMENTS (horn));
        POINT small[] = {{x+menu_px(13),y+menu_px(6)}, {x+menu_px(13),y+menu_px(10)}, {x+menu_px(10),y+menu_px(11)}};
        MoveToEx (dc, x+menu_px(10), y+menu_px(5), NULL); PolyBezierTo (dc, small, G_N_ELEMENTS (small));
        POINT large[] = {{x+menu_px(17),y+menu_px(4)}, {x+menu_px(17),y+menu_px(12)}, {x+menu_px(12),y+menu_px(14)}};
        MoveToEx (dc, x+menu_px(12), y+menu_px(2), NULL); PolyBezierTo (dc, large, G_N_ELEMENTS (large));
    } else if (item->icon == 8) { // Bell: curved crown, flared rim and clapper
        POINT left[] = {{x+menu_px(4),y+menu_px(2)}, {x+menu_px(4),y+menu_px(4)}, {x+menu_px(4),y+menu_px(9)}};
        MoveToEx (dc, x+menu_px(8), y+menu_px(2), NULL); PolyBezierTo (dc, left, G_N_ELEMENTS (left));
        LineTo (dc, x+menu_px(2), y+menu_px(12)); LineTo (dc, x+menu_px(14), y+menu_px(12));
        LineTo (dc, x+menu_px(12), y+menu_px(9));
        POINT right[] = {{x+menu_px(12),y+menu_px(4)}, {x+menu_px(12),y+menu_px(2)}, {x+menu_px(8),y+menu_px(2)}};
        PolyBezierTo (dc, right, G_N_ELEMENTS (right));
        stroke_line (dc, x+menu_px(8), y, x+menu_px(8), y+menu_px(2));
        stroke_line (dc, x+menu_px(6), y+menu_px(15), x+menu_px(10), y+menu_px(15));
    } else if (item->icon == 9) { // Settings: three adjustment controls
        for (int i = 0; i < 3; i++) {
            int yy = y + q + i * q * 3;
            stroke_line (dc, x, yy, x + z, yy);
            int xx = x + q * (i == 1 ? 5 : 2);
            Rectangle (dc, xx, yy - q, xx + q * 2, yy + q);
        }
    } else if (item->icon == 10) { // Power
        Arc (dc, x + q, y + q, x + z - q, y + z - q,
            x + q * 3, y + q, x + q * 5, y + q);
        stroke_line (dc, x + z / 2, y, x + z / 2, y + z / 2);
    }
    SelectObject (dc, old_brush); SelectObject (dc, old_pen); DeleteObject (pen);
}

static gboolean
measure_menu_item (MEASUREITEMSTRUCT *measure)
{
    if (!measure || measure->CtlType != ODT_MENU || !measure->itemData) return FALSE;
    TrayMenuItem *item = (TrayMenuItem *) measure->itemData;
    HDC dc = GetDC (msg_hwnd);
    HGDIOBJ font = menu_font ? SelectObject (dc, menu_font) : NULL;
    RECT extent = {0};
    DrawTextW (dc, item->text, -1, &extent, DT_CALCRECT | DT_SINGLELINE | DT_NOPREFIX);
    if (font) SelectObject (dc, font);
    ReleaseDC (msg_hwnd, dc);
    measure->itemWidth = (UINT) MIN (menu_max_width, MAX (menu_px (220), extent.right + menu_px (88)));
    measure->itemHeight = (UINT) (item->separator ? menu_px (10) : MAX (menu_px (34), extent.bottom + menu_px (12)));
    return TRUE;
}

static gboolean
paint_menu_item (DRAWITEMSTRUCT *draw)
{
    if (!draw || draw->CtlType != ODT_MENU || !draw->itemData) return FALSE;
    TrayMenuItem *item = (TrayMenuItem *) draw->itemData;
    int saved = SaveDC (draw->hDC);
    IntersectClipRect (draw->hDC, draw->rcItem.left, draw->rcItem.top, draw->rcItem.right, draw->rcItem.bottom);
    gboolean selected = (draw->itemState & ODS_SELECTED) != 0;
    COLORREF background = selected ? (menu_dark ? RGB(37,109,88) : RGB(207,235,222)) : menu_bg ();
    if (selected && menu_website) background = menu_dark ? RGB(188,216,195) : RGB(49,94,77);
    HBRUSH brush = CreateSolidBrush (background);
    FillRect (draw->hDC, &draw->rcItem, brush); DeleteObject (brush);
    COLORREF foreground = menu_fg ();
    if (selected && menu_website) foreground = menu_dark ? RGB(17,37,27) : RGB(255,255,255);
    if (draw->itemState & ODS_DISABLED) foreground = menu_dark ? RGB(147,150,157) : RGB(113,116,122);
    else if (item->icon == 10 && !selected) foreground = menu_dark ? RGB(255,120,128) : RGB(182,39,50);
    int center_y = (draw->rcItem.top + draw->rcItem.bottom) / 2;
    if (item->separator) {
        HPEN line = CreatePen (PS_SOLID, 1, menu_dark ? RGB(63,65,71) : RGB(219,222,226));
        HGDIOBJ old = SelectObject (draw->hDC, line);
        stroke_line (draw->hDC, draw->rcItem.left + menu_px (12), center_y, draw->rcItem.right - menu_px (12), center_y);
        SelectObject (draw->hDC, old); DeleteObject (line);
    } else {
        paint_menu_icon (draw->hDC, item, draw->rcItem.left + menu_px (14), center_y - menu_px (8), foreground);
        if (menu_font) SelectObject (draw->hDC, menu_font);
        SetBkMode (draw->hDC, TRANSPARENT); SetTextColor (draw->hDC, foreground);
        RECT text = draw->rcItem;
        text.left += menu_px (44); text.right -= menu_px (32);
        DrawTextW (draw->hDC, item->text, -1, &text, DT_SINGLELINE | DT_VCENTER | DT_END_ELLIPSIS | DT_NOPREFIX);
        if (item->checked) {
            HPEN tick = CreatePen (PS_SOLID, MAX (1, menu_px (2)), foreground);
            SelectObject (draw->hDC, tick); SelectObject (draw->hDC, GetStockObject (NULL_BRUSH));
            int x = draw->rcItem.right - menu_px (20);
            if (item->icon >= 2 && item->icon <= 5) {
                HBRUSH dot = CreateSolidBrush (foreground); SelectObject (draw->hDC, dot);
                Ellipse (draw->hDC, x, center_y - menu_px (3), x + menu_px (6), center_y + menu_px (3));
                SelectObject (draw->hDC, GetStockObject (NULL_BRUSH)); DeleteObject (dot);
            } else {
                stroke_line (draw->hDC, x - menu_px (3), center_y, x, center_y + menu_px (3));
                stroke_line (draw->hDC, x, center_y + menu_px (3), x + menu_px (6), center_y - menu_px (4));
            }
            SelectObject (draw->hDC, GetStockObject (BLACK_PEN)); DeleteObject (tick);
        }
        if (draw->itemState & ODS_FOCUS) {
            RECT focus = draw->rcItem; InflateRect (&focus, -menu_px (3), -menu_px (3));
            DrawFocusRect (draw->hDC, &focus);
        }
    }
    RestoreDC (draw->hDC, saved);
    return TRUE;
}

void
systray_win32_set_tooltip (const gchar *tooltip_utf8)
{
    if (!initialised) return;

    copy_shell_text (nid.szTip, G_N_ELEMENTS (nid.szTip), tooltip_utf8);
    nid.uFlags = NIF_TIP;
    Shell_NotifyIconW (NIM_MODIFY, &nid);
}

static void
balloon_free (Balloon *balloon)
{
    if (!balloon) return;
    GDestroyNotify destroy = balloon->destroy;
    gpointer data = balloon->data;
    balloon->destroy = NULL; balloon->data = NULL; balloon->callback = NULL;
    if (destroy) destroy (data);
    g_free (balloon->title); g_free (balloon->body); g_free (balloon->key); g_free (balloon);
}

static void queue_balloon_pump (void);

static gboolean
pump_balloon (gpointer unused)
{
    (void) unused;
    balloon_pump_source = 0;
    if (!initialised || active_balloon || g_queue_is_empty (&balloon_queue)) return G_SOURCE_REMOVE;
    active_balloon = g_queue_pop_head (&balloon_queue);
    // Keep only one native balloon outstanding. Windows callbacks have no item ID.
    Balloon *balloon = active_balloon;
    nid.uFlags = NIF_INFO;
    copy_shell_text (nid.szInfoTitle, G_N_ELEMENTS (nid.szInfoTitle), balloon->title);
    copy_shell_text (nid.szInfo, G_N_ELEMENTS (nid.szInfo), balloon->body);
    nid.dwInfoFlags = (DWORD) balloon->icon_type | NIIF_NOSOUND;
    if (!Shell_NotifyIconW (NIM_MODIFY, &nid) && active_balloon == balloon) {
        active_balloon = NULL;
        balloon_free (balloon);
        queue_balloon_pump ();
    }
    return G_SOURCE_REMOVE;
}

static void
queue_balloon_pump (void)
{
    if (initialised && !active_balloon && !balloon_pump_source && !g_queue_is_empty (&balloon_queue))
        balloon_pump_source = g_idle_add (pump_balloon, NULL);
}

static void
finish_balloon (gboolean clicked)
{
    Balloon *balloon = active_balloon;
    if (!balloon) return;
    active_balloon = NULL;
    // Detach before the callback: a click may retract notifications or quit.
    if (clicked && balloon->shown && !balloon->cancelled && balloon->callback) balloon->callback (balloon->data);
    balloon_free (balloon);
    queue_balloon_pump ();
}

void
systray_win32_show_balloon (const gchar *title_utf8, const gchar *body_utf8,
                            int icon_type, SystrayWin32BalloonCallback callback,
                            gpointer data, GDestroyNotify destroy, const gchar *key)
{
    if (!initialised || !body_utf8 || !*body_utf8) {
        if (destroy) destroy (data);
        return;
    }
    // Detach obsolete items before calling external destroy handlers. They
    // may re-enter this API, retract other items, or shut down the tray.
    GQueue obsolete = G_QUEUE_INIT;
    for (GList *node = balloon_queue.head; node;) {
        GList *next = node->next;
        Balloon *old = node->data;
        if (key && g_strcmp0 (key, old->key) == 0) {
            g_queue_unlink (&balloon_queue, node); g_queue_push_tail_link (&obsolete, node);
        }
        node = next;
    }
    while (g_queue_get_length (&balloon_queue) >= MAX_QUEUED_BALLOONS)
        g_queue_push_tail (&obsolete, g_queue_pop_head (&balloon_queue));
    while (!g_queue_is_empty (&obsolete)) balloon_free (g_queue_pop_head (&obsolete));
    if (!initialised) { if (destroy) destroy (data); return; }
    Balloon *balloon = g_new0 (Balloon, 1);
    balloon->title = g_strdup (title_utf8 ? title_utf8 : "");
    balloon->body = g_strdup (body_utf8); balloon->key = g_strdup (key);
    balloon->icon_type = icon_type >= 0 && icon_type <= 3 ? icon_type : 1;
    balloon->callback = callback; balloon->data = data; balloon->destroy = destroy;
    g_queue_push_tail (&balloon_queue, balloon);
    queue_balloon_pump ();
}

static gboolean
balloon_matches (Balloon *balloon, const gchar *key, gboolean prefix)
{
    return !key || (balloon->key && (prefix ? g_str_has_prefix (balloon->key, key) : g_str_equal (balloon->key, key)));
}

void
systray_win32_hide_balloon (const gchar *key, gboolean prefix)
{
    GQueue removed = G_QUEUE_INIT;
    for (GList *node = balloon_queue.head; node;) {
        GList *next = node->next;
        if (balloon_matches (node->data, key, prefix)) {
            g_queue_unlink (&balloon_queue, node); g_queue_push_tail_link (&removed, node);
        }
        node = next;
    }
    while (!g_queue_is_empty (&removed)) balloon_free (g_queue_pop_head (&removed));
    if (active_balloon && balloon_matches (active_balloon, key, prefix)) {
        Balloon *balloon = active_balloon;
        GDestroyNotify destroy = balloon->destroy;
        gpointer data = balloon->data;
        balloon->cancelled = TRUE;
        balloon->destroy = NULL; balloon->callback = NULL; balloon->data = NULL;
        if (destroy) destroy (data);
        if (active_balloon != balloon || !initialised) return;
        // Keep a tombstone until the native terminal event. Starting another
        // balloon here would make a delayed HIDE/TIMEOUT clear its callback.
        nid.uFlags = NIF_INFO; nid.szInfo[0] = 0; nid.szInfoTitle[0] = 0;
        Shell_NotifyIconW (NIM_MODIFY, &nid);
    }
}

void
systray_win32_cleanup (void)
{
    if (!initialised) return;
    tray_log ("Cleanup: removing tray icon");
    initialised = FALSE;
    if (balloon_pump_source) { g_source_remove (balloon_pump_source); balloon_pump_source = 0; }
    Balloon *balloon = active_balloon; active_balloon = NULL;
    GQueue pending = balloon_queue; g_queue_init (&balloon_queue);
    balloon_free (balloon);
    while (!g_queue_is_empty (&pending)) balloon_free (g_queue_pop_head (&pending));

    Shell_NotifyIconW (NIM_DELETE, &nid);

    if (popup_menu) {
        DestroyMenu (popup_menu);
        popup_menu = NULL;
    }
    clear_menu_items ();
    g_strfreev (menu_labels); menu_labels = NULL;
    if (menu_font) { DeleteObject (menu_font); menu_font = NULL; }
    if (menu_background) { DeleteObject (menu_background); menu_background = NULL; }
    if (msg_hwnd) {
        DestroyWindow (msg_hwnd);
        msg_hwnd = NULL;
    }
    if (single_instance_mutex) {
        ReleaseMutex (single_instance_mutex);
        CloseHandle (single_instance_mutex);
        single_instance_mutex = NULL;
    }

    user_callback  = NULL;
    user_data_ptr  = NULL;

    if (tray_log_file) {
        fprintf (tray_log_file, "=== Log closed ===\n");
        fclose (tray_log_file);
        tray_log_file = NULL;
    }
}

/* ---- Window procedure ---- */

static void
show_context_menu (HWND hwnd, gboolean at_icon)
{
    if (popup_menu == NULL) return;
    POINT pt = {0, 0}; GetCursorPos (&pt);
    if (at_icon) {
        NOTIFYICONIDENTIFIER identifier = {0};
        identifier.cbSize = sizeof identifier; identifier.hWnd = hwnd; identifier.uID = nid.uID;
        RECT icon_rect;
        if (SUCCEEDED (Shell_NotifyIconGetRect (&identifier, &icon_rect))) {
            pt.x = (icon_rect.left + icon_rect.right) / 2; pt.y = icon_rect.top;
        }
    }
    configure_menu_monitor (pt);
    SetForegroundWindow (hwnd);
    menu_open = TRUE;
    int cmd = (int) TrackPopupMenu (popup_menu,
        TPM_RETURNCMD | TPM_NONOTIFY | TPM_RIGHTBUTTON | TPM_BOTTOMALIGN | TPM_WORKAREA,
        pt.x, pt.y, 0, hwnd, NULL);
    menu_open = FALSE;
    PostMessageW (hwnd, WM_NULL, 0, 0);
    Shell_NotifyIconW (NIM_SETFOCUS, &nid);
    if (menu_dirty) rebuild_native_menu ();
    if (cmd > 0 && user_callback) user_callback (cmd - 1, user_data_ptr);
}

static LRESULT CALLBACK
wnd_proc (HWND hwnd, UINT msg, WPARAM wParam, LPARAM lParam)
{
    if (msg == WM_MEASUREITEM && measure_menu_item ((MEASUREITEMSTRUCT *) lParam)) return TRUE;
    if (msg == WM_DRAWITEM && paint_menu_item ((DRAWITEMSTRUCT *) lParam)) return TRUE;
    if (msg == WM_MENUCHAR && (HMENU) lParam == popup_menu) {
        // First-letter navigation supplements the native arrow/Enter/Escape keys.
        gunichar character = g_unichar_tolower ((gunichar) LOWORD (wParam));
        int current = -1, first = -1;
        for (int i = 0; i < GetMenuItemCount (popup_menu); i++) {
            if (GetMenuState (popup_menu, i, MF_BYPOSITION) & MF_HILITE) current = i;
        }
        for (int step = 1; step <= GetMenuItemCount (popup_menu); step++) {
            int index = (current + step) % GetMenuItemCount (popup_menu);
            TrayMenuItem *item = menu_items[index];
            if (item && !item->separator && g_unichar_tolower ((gunichar) item->text[0]) == character) { first = index; break; }
        }
        if (first >= 0) return MAKELRESULT (first, MNC_SELECT);
        return MAKELRESULT (0, MNC_IGNORE);
    }

    /* Explorer restarted — re-create our tray icon. */
    if (WM_TASKBARCREATED != 0 && msg == WM_TASKBARCREATED) {
        if (!initialised) return 0;
        // Explorer lost the old balloon and may never deliver its terminal
        // callback. Drop its action before restoring the icon and next item.
        Balloon *lost = active_balloon; active_balloon = NULL;
        balloon_free (lost);
        if (!initialised) return 0;
        tray_log ("TaskbarCreated — re-adding tray icon");
        nid.uFlags = NIF_ICON | NIF_MESSAGE | NIF_TIP;
        if (using_version_4)
            nid.uFlags |= NIF_SHOWTIP;
        Shell_NotifyIconW (NIM_ADD, &nid);
        nid.uVersion = using_version_4 ? NOTIFYICON_VERSION_4
                                       : NOTIFYICON_VERSION;
        Shell_NotifyIconW (NIM_SETVERSION, &nid);
        queue_balloon_pump ();
        return 0;
    }

    /* Don't let Windows destroy our tray callback window.
     * The shell's "Fenster schliessen" or system shutdown may send
     * WM_CLOSE to all top-level windows of the process. */
    if (msg == WM_CLOSE) {
        tray_log ("WM_CLOSE received on msg_hwnd — ignoring (tray stays alive)");
        return 0;
    }

    /* Windows is shutting down / user is logging off.
     * Tell our Vala-side to quit gracefully (menu_id = -3). */
    if (msg == WM_QUERYENDSESSION) {
        tray_log ("WM_QUERYENDSESSION — allowing shutdown");
        return TRUE;  /* "yes, we can quit" */
    }
    if (msg == WM_ENDSESSION && wParam) {
        tray_log ("WM_ENDSESSION — graceful shutdown");
        if (user_callback)
            user_callback (-3, user_data_ptr);   /* -3 = system shutdown */
        return 0;
    }

    /* Second instance asked us to show the window (single-instance). */
    if (msg == WM_ACTIVATE_INSTANCE) {
        tray_log ("WM_ACTIVATE_INSTANCE — showing window from second instance");
        if (user_callback)
            user_callback (-2, user_data_ptr);   /* -2 = always show */
        return 0;
    }

    if (msg == WM_TRAYICON) {
        UINT event = LOWORD (lParam);

        /* Only log meaningful events, skip WM_MOUSEMOVE (0x0200) spam */
        if (event != WM_MOUSEMOVE) {
            tray_log ("WM_TRAYICON event=0x%04x wParam=0x%08lx lParam=0x%08lx",
                      event, (unsigned long) wParam, (unsigned long) lParam);
        }

        switch (event) {

        /* ---- Left-click / keyboard select (V4 primary) ---- */
        case NIN_SELECT:
        case NIN_KEYSELECT:
            tray_log ("Left-click (NIN_SELECT / NIN_KEYSELECT)");
            if (user_callback)
                user_callback (-1, user_data_ptr);
            break;

        case WM_LBUTTONUP:
            /* V3 fallback — V4 sends NIN_SELECT instead. */
            if (!using_version_4) {
                tray_log ("Left-click (WM_LBUTTONUP, v3)");
                if (user_callback)
                    user_callback (-1, user_data_ptr);
            }
            break;

        /* ---- Balloon notifications ---- */
        case NIN_BALLOONSHOW:
            if (active_balloon) active_balloon->shown = TRUE;
            break;
        case NIN_BALLOONUSERCLICK:
            if (active_balloon && active_balloon->shown) finish_balloon (TRUE);
            break;
        case NIN_BALLOONTIMEOUT:
            if (active_balloon && (active_balloon->shown || active_balloon->cancelled)) finish_balloon (FALSE);
            break;
        case NIN_BALLOONHIDE:
            // HIDE may be sent for a suppressed notification without SHOW.
            finish_balloon (FALSE);
            break;

        /* ---- Right-click / context menu ---- */
        case WM_CONTEXTMENU:
            tray_log ("Right-click (WM_CONTEXTMENU)");
            {
                DWORD now = GetTickCount ();
                if (now - last_context_menu_tick > 400) {
                    last_context_menu_tick = now;
                    show_context_menu (hwnd, TRUE);
                }
            }
            break;

        case WM_RBUTTONUP:
            /* Handle in ALL modes — Windows 10/11 may send WM_RBUTTONUP
             * even in V4, or fail to deliver WM_CONTEXTMENU entirely
             * (shell intercepts right-click for its own menu). */
            tray_log ("Right-click (WM_RBUTTONUP)");
            {
                DWORD now = GetTickCount ();
                if (now - last_context_menu_tick > 400) {
                    last_context_menu_tick = now;
                    show_context_menu (hwnd, FALSE);
                }
            }
            break;

        default:
            break;
        }
        return 0;
    }

    return DefWindowProcW (hwnd, msg, wParam, lParam);
}

/* ---- Attach to parent console (for CMD/MSYS2 log output) ---- */
/*
 * With -mwindows the EXE is GUI subsystem → no console on double-click.
 * But when launched from CMD or MSYS2, we want stdout/stderr to go to
 * that terminal.  AttachConsole(ATTACH_PARENT_PROCESS) connects us to
 * the parent's console; then we reopen the C stdio streams to CONOUT$.
 *
 * When there IS no parent console (Explorer double-click), we allocate
 * a hidden console.  This is critical: without a console, every child
 * process that is itself a console application (gpg.exe, gpg-agent.exe,
 * openssl.exe, etc.) will cause Windows to create a NEW visible console
 * window — producing the "flashing CMD" effect.  With a hidden console
 * attached to our process, all children (and grandchildren) inherit it
 * transparently, and no visible windows appear.
 */

/* Check if a standard handle is already redirected to a pipe or file.
 * When the user runs  ./dinox.exe 2>&1 | tee log  the shell sets up
 * stdout/stderr as pipes BEFORE our process starts.  If we blindly
 * freopen("CONOUT$") we destroy that pipe and the log stays empty.
 * Likewise for  ./dinox.exe > file  (FILE_TYPE_DISK).
 * In mintty (MSYS2) stdout is also a pipe (pty emulation) — same rule. */
static gboolean
std_handle_is_redirected (DWORD nStdHandle)
{
    HANDLE h = GetStdHandle (nStdHandle);
    if (h == NULL || h == INVALID_HANDLE_VALUE)
        return FALSE;
    DWORD type = GetFileType (h);
    return (type == FILE_TYPE_PIPE || type == FILE_TYPE_DISK);
}

void
systray_win32_attach_parent_console (void)
{
    /* DINOX_LOG_FILE: if set, redirect stderr (GLib debug messages)
     * to the specified file instead of CONOUT$/NUL.  Usage:
     *   DINOX_LOG_FILE=dinox-debug.log ./dinox.exe            */
    const char *log_file = g_getenv ("DINOX_LOG_FILE");

    /* Preserve existing shell redirections (pipes, files).  Only
     * redirect streams that are not already connected. */
    gboolean stdout_piped = std_handle_is_redirected (STD_OUTPUT_HANDLE);
    gboolean stderr_piped = std_handle_is_redirected (STD_ERROR_HANDLE);

    if (AttachConsole (ATTACH_PARENT_PROCESS)) {
        if (!stdout_piped)
            freopen ("CONOUT$", "w", stdout);
        if (log_file && *log_file)
            freopen (log_file, "w", stderr);
        else if (!stderr_piped)
            freopen ("CONOUT$", "w", stderr);
        freopen ("CONIN$",  "r", stdin);
        tray_log ("AttachConsole(PARENT) succeeded — stdout_piped=%d stderr_piped=%d",
                  stdout_piped, stderr_piped);
    } else {
        /* No parent console (Explorer / desktop shortcut launch).
         * Allocate our own console and immediately hide it so that
         * child processes inherit a console handle instead of Windows
         * creating a new visible CMD window for each one. */
        AllocConsole ();
        HWND console_hwnd = GetConsoleWindow ();
        if (console_hwnd)
            ShowWindow (console_hwnd, SW_HIDE);

        if (!stdout_piped)
            freopen ("NUL", "w", stdout);
        if (log_file && *log_file)
            freopen (log_file, "w", stderr);
        else if (!stderr_piped)
            freopen ("NUL", "w", stderr);
        freopen ("NUL", "r", stdin);
        tray_log ("Allocated hidden console — stdout_piped=%d stderr_piped=%d",
                  stdout_piped, stderr_piped);
    }
}

gchar *
systray_win32_get_system_directory (void)
{
    WCHAR directory[MAX_PATH + 1];
    UINT length = GetSystemDirectoryW (
        directory, (UINT) G_N_ELEMENTS (directory));

    if (length == 0 || length >= (UINT) G_N_ELEMENTS (directory))
        return NULL;
    return g_utf16_to_utf8 ((const gunichar2 *) directory,
                            (glong) length, NULL, NULL, NULL);
}

/* ---- Set process-level AppUserModelID ---- */
/*
 * Must be called BEFORE any windows are created (so before Gtk.init()).
 * This tells Windows which app identity to use for taskbar grouping and
 * jump list operations.  Without it, Windows generates one from the exe
 * path and our suppress_jumplist() may not target the right ID.
 */
void
systray_win32_set_app_id (const gchar *app_id_utf8)
{
    if (app_id_utf8 == NULL) return;
    HMODULE shell32 = GetModuleHandleW (L"shell32.dll");
    if (!shell32) shell32 = LoadLibraryW (L"shell32.dll");
    if (shell32) {
        pfn_SetAppUserModelID pSetID = (pfn_SetAppUserModelID)
            GetProcAddress (shell32, "SetCurrentProcessExplicitAppUserModelID");
        if (pSetID) {
            wchar_t *wid = utf8_to_wchar (app_id_utf8);
            HRESULT hr = pSetID (wid);
            tray_log ("SetAppUserModelID('%s') %s (0x%08lx)",
                      app_id_utf8,
                      SUCCEEDED (hr) ? "OK" : "FAILED",
                      (unsigned long) hr);
            g_free (wid);
        }
    }
}

/* ---- Suppress CRT invalid-parameter assertions ---- */
/*
 * GStreamer's MediaFoundation plugin spawns worker threads that probe
 * hardware encoders/decoders.  When a device is not available, the MF API
 * sometimes calls CRT functions with invalid parameters.
 *
 * On MinGW64 (MSVCRT runtime), _set_invalid_parameter_handler is process-
 * wide (not thread-local like on UCRT/MSVC).  GLib's g_win32_push/pop_
 * invalid_parameter_handler therefore has a TOCTOU race: if any thread
 * (e.g. MediaFoundation worker) calls _set_invalid_parameter_handler
 * between GLib's push and pop, the pop assertion fires:
 *
 *   GLib-CRITICAL (recursed) **: g_win32_pop_invalid_parameter_handler:
 *   assertion 'handler->pushed_handler == popped_handler' failed
 *
 * The "(recursed)" means the g_critical fires while another g_log is
 * already active on the same thread.  GLib's hardcoded fallback handler
 * for recursive messages calls MessageBoxW() directly — no GLib API
 * (g_log_set_handler, g_log_set_writer_func, etc.) can intercept this.
 *
 * The normal fix is limited to _set_invalid_parameter_handler.  The older
 * IAT patch remains available only behind DINOX_ENABLE_GLIB_MESSAGEBOX_PATCH=1
 * because patching GLib's import table during startup is too fragile for the
 * default Windows path.
 */
static void
silent_invalid_parameter_handler (
    const wchar_t *expression,
    const wchar_t *function,
    const wchar_t *file,
    unsigned int   line,
    uintptr_t      reserved)
{
    /* intentionally empty — suppress the CRT assertion dialog */
}

/* --- IAT patching to suppress GLib's recursive CRT handler dialog --- */

typedef int (WINAPI *MessageBoxW_fn)(HWND, LPCWSTR, LPCWSTR, UINT);
static MessageBoxW_fn Real_MessageBoxW = NULL;

static int WINAPI
filtered_message_box_w (HWND hWnd, LPCWSTR lpText,
                        LPCWSTR lpCaption, UINT uType)
{
    /* Suppress only the GLib CRT handler mismatch dialog */
    if (lpText && wcsstr (lpText, L"pop_invalid_parameter_handler"))
    {
        tray_log ("Suppressed GLib CRT handler assertion dialog");
        return IDOK;
    }
    return Real_MessageBoxW (hWnd, lpText, lpCaption, uType);
}

/*
 * Walk the Import Address Table (IAT) of the given module and replace
 * the entry for MessageBoxW (from user32.dll) with our filtered version.
 */
static void
patch_module_iat_messagebox (HMODULE module)
{
    if (!module) return;

    BYTE *base = (BYTE *) module;
    PIMAGE_DOS_HEADER dos = (PIMAGE_DOS_HEADER) base;
    if (dos->e_magic != IMAGE_DOS_SIGNATURE) return;

    PIMAGE_NT_HEADERS nt = (PIMAGE_NT_HEADERS) (base + dos->e_lfanew);
    if (nt->Signature != IMAGE_NT_SIGNATURE) return;

    DWORD import_rva =
        nt->OptionalHeader.DataDirectory[IMAGE_DIRECTORY_ENTRY_IMPORT].VirtualAddress;
    if (!import_rva) return;

    PIMAGE_IMPORT_DESCRIPTOR imp = (PIMAGE_IMPORT_DESCRIPTOR) (base + import_rva);

    for (; imp->Name; imp++)
    {
        const char *dll = (const char *) (base + imp->Name);
        if (_stricmp (dll, "user32.dll") != 0)
            continue;

        PIMAGE_THUNK_DATA orig  = (PIMAGE_THUNK_DATA) (base + imp->OriginalFirstThunk);
        PIMAGE_THUNK_DATA thunk = (PIMAGE_THUNK_DATA) (base + imp->FirstThunk);

        for (; orig->u1.AddressOfData; orig++, thunk++)
        {
            if (IMAGE_SNAP_BY_ORDINAL (orig->u1.Ordinal))
                continue;

            PIMAGE_IMPORT_BY_NAME name =
                (PIMAGE_IMPORT_BY_NAME) (base + orig->u1.AddressOfData);

            if (strcmp ((const char *) name->Name, "MessageBoxW") == 0)
            {
                Real_MessageBoxW = (MessageBoxW_fn) thunk->u1.Function;

                DWORD old_protect;
                if (VirtualProtect (&thunk->u1.Function, sizeof (FARPROC),
                                    PAGE_READWRITE, &old_protect))
                {
                    thunk->u1.Function = (ULONG_PTR) filtered_message_box_w;
                    VirtualProtect (&thunk->u1.Function, sizeof (FARPROC),
                                    old_protect, &old_protect);
                    tray_log ("Patched MessageBoxW in GLib IAT");
                }
                return;
            }
        }
    }
    tray_log ("WARNING: MessageBoxW not found in module IAT");
}

void
systray_win32_suppress_crt_assertions (void)
{
    _set_invalid_parameter_handler (silent_invalid_parameter_handler);

    const char *enable_iat_patch = g_getenv ("DINOX_ENABLE_GLIB_MESSAGEBOX_PATCH");
    if (enable_iat_patch != NULL && strcmp (enable_iat_patch, "1") == 0) {
        Real_MessageBoxW = (MessageBoxW_fn) GetProcAddress (
            GetModuleHandleW (L"user32.dll"), "MessageBoxW");

        HMODULE glib = GetModuleHandleW (L"libglib-2.0-0.dll");
        if (glib)
            patch_module_iat_messagebox (glib);
        else
            tray_log ("WARNING: libglib-2.0-0.dll not loaded yet");
    }

    tray_log_file_only ("CRT invalid-parameter handler suppressed%s",
                        (enable_iat_patch != NULL && strcmp (enable_iat_patch, "1") == 0)
                        ? " with GLib MessageBox IAT patch" : "");
}

#else /* !_WIN32 — stubs for Linux builds (never called) */

gboolean systray_win32_check_single_instance (void) { return TRUE; }
gboolean systray_win32_activate_existing_instance (void) { return FALSE; }
gboolean systray_win32_init (const gchar *t, int r, SystrayWin32Callback c, gpointer u) { return FALSE; }
void systray_win32_set_menu (gchar **l, const gint *i, guint32 m) {}
void systray_win32_set_menu_theme (gboolean d, gboolean w) {}
void systray_win32_set_tooltip (const gchar *t) {}
void systray_win32_show_balloon (const gchar *t, const gchar *b, int i, SystrayWin32BalloonCallback c, gpointer u, GDestroyNotify d, const gchar *k) { if (d) d (u); }
void systray_win32_hide_balloon (const gchar *k, gboolean p) {}
void systray_win32_cleanup (void) {}
void systray_win32_attach_parent_console (void) {}
gchar *systray_win32_get_system_directory (void) { return NULL; }
void systray_win32_set_app_id (const gchar *app_id_utf8) {}
gboolean systray_win32_register_xmpp_protocol_handler (const gchar *exe_path_utf8) { return FALSE; }
gboolean systray_win32_open_file (const gchar *path_utf8) { return FALSE; }
gboolean systray_win32_foreground_window_is_external (void) { return FALSE; }
void systray_win32_suppress_crt_assertions (void) {}

#endif
