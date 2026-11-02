#include <windows.h>
#include <shellapi.h>
#include <glib.h>
#include <stdio.h>
#include <glib/gstdio.h>
static int shell_calls;
static BOOL fake_contrast, fail_next_notification;
static DWORD observed_info_flags;
static BOOL audit_notify(DWORD event, PNOTIFYICONDATAW data) {
    if(event==NIM_MODIFY && (data->uFlags&NIF_INFO) && data->szInfo[0]) ++shell_calls;
    observed_info_flags=data->dwInfoFlags;
    if(event==NIM_MODIFY && data->szInfo[0] && fail_next_notification) {fail_next_notification=FALSE;return FALSE;}
    return TRUE;
}
static BOOL audit_parameters(UINT action, UINT param, PVOID value, UINT flags) {
    if(action==SPI_GETHIGHCONTRAST) { ((HIGHCONTRASTW*)value)->dwFlags=fake_contrast?HCF_HIGHCONTRASTON:0; return TRUE; }
    return SystemParametersInfoW(action,param,value,flags);
}
#define Shell_NotifyIconW audit_notify
#define SystemParametersInfoW audit_parameters
#include "../src/ui/systray_win32.c"
#undef Shell_NotifyIconW
#undef SystemParametersInfoW
static int clicks[128], destroys[128];
static void clicked(gpointer data) { ++clicks[GPOINTER_TO_INT(data)]; }
static void destroyed(gpointer data) { ++destroys[GPOINTER_TO_INT(data)]; }
static void drain(void) { while(g_main_context_pending(NULL)) g_main_context_iteration(NULL,FALSE); }
static void send_event(UINT event) { wnd_proc(NULL,WM_TRAYICON,0,event); }
static void enqueue(const char* key,int id) { systray_win32_show_balloon(key,"Example message",1,clicked,GINT_TO_POINTER(id),destroyed,key); }
static void begin(void) { initialised=TRUE; nid.cbSize=sizeof nid; }
static void end(void) { systray_win32_cleanup(); drain(); }
static void queue_tests(void) {
    begin(); enqueue("A",1); drain(); send_event(NIN_BALLOONSHOW); enqueue("B",2); enqueue("C",3); drain();
    g_assert_cmpint(shell_calls,==,1); send_event(NIN_BALLOONUSERCLICK); g_assert_cmpint(clicks[1],==,1);g_assert_cmpint(clicks[2],==,0);
    drain();g_assert_cmpint(shell_calls,==,2);
    // A late terminal event before the next SHOW cannot steal B's action.
    send_event(NIN_BALLOONTIMEOUT);g_assert_nonnull(active_balloon);
    send_event(NIN_BALLOONSHOW); send_event(NIN_BALLOONTIMEOUT);drain();send_event(NIN_BALLOONSHOW);send_event(NIN_BALLOONUSERCLICK);
    g_assert_cmpint(clicks[3],==,1);for(int i=1;i<=3;i++)g_assert_cmpint(destroys[i],==,1);
    g_assert_true((observed_info_flags&NIIF_NOSOUND)!=0);end();
    puts("PASS serial queue + per-item click + timeout + late terminal + silent sound");
    begin();enqueue("conv:1",4);drain();send_event(NIN_BALLOONSHOW);enqueue("call:2",5);enqueue("conv:3",6);
    systray_win32_hide_balloon("conv:",TRUE);g_assert_cmpint(destroys[4],==,1);g_assert_cmpint(destroys[6],==,1);g_assert_cmpint(destroys[5],==,0);
    send_event(NIN_BALLOONUSERCLICK);g_assert_cmpint(clicks[4],==,0);drain();g_assert_nonnull(active_balloon);send_event(NIN_BALLOONSHOW);send_event(NIN_BALLOONUSERCLICK);g_assert_cmpint(clicks[5],==,1);g_assert_cmpint(destroys[5],==,1);end();
    puts("PASS exact/prefix cancellation does not retract unrelated calls");
    begin();enqueue("conv:7",7);enqueue("conv:7",8);g_assert_cmpint(destroys[7],==,1);drain();send_event(NIN_BALLOONSHOW);enqueue("next",9);end();g_assert_cmpint(destroys[8],==,1);g_assert_cmpint(destroys[9],==,1);
    enqueue("closed",10);g_assert_cmpint(destroys[10],==,1);
    puts("PASS coalescing + shutdown + rejected-item ownership");
}
static void reentrant_click(gpointer data) { clicked(data);systray_win32_cleanup(); }
static void reentrancy_test(void) {
    begin();systray_win32_show_balloon("X","Reentrant cleanup",1,reentrant_click,GINT_TO_POINTER(11),destroyed,"X");enqueue("Y",12);drain();send_event(NIN_BALLOONSHOW);send_event(NIN_BALLOONUSERCLICK);drain();
    g_assert_cmpint(clicks[11],==,1);g_assert_cmpint(destroys[11],==,1);g_assert_cmpint(destroys[12],==,1);g_assert_false(initialised);
    puts("PASS callback reentrant shutdown destroys each item once");
}
static void recursive_destroy(gpointer data) {
    destroyed(data);
    if(destroys[GPOINTER_TO_INT(data)]==1) systray_win32_hide_balloon("recursive",FALSE);
}
static void destroy_cleanup(gpointer data) {destroyed(data);systray_win32_cleanup();}
static void edge_tests(void) {
    begin();systray_win32_show_balloon("R","Recursive cancel",1,clicked,GINT_TO_POINTER(15),recursive_destroy,"recursive");drain();send_event(NIN_BALLOONSHOW);
    systray_win32_hide_balloon("recursive",FALSE);g_assert_cmpint(destroys[15],==,1);send_event(NIN_BALLOONHIDE);end();
    begin();systray_win32_show_balloon("R","Cleanup on cancel",1,clicked,GINT_TO_POINTER(16),destroy_cleanup,"recursive");drain();send_event(NIN_BALLOONSHOW);enqueue("other",17);systray_win32_hide_balloon("recursive",FALSE);g_assert_cmpint(destroys[16],==,1);g_assert_cmpint(destroys[17],==,1);g_assert_false(initialised);
    begin();systray_win32_show_balloon("R","Cleanup on coalesce",1,clicked,GINT_TO_POINTER(18),destroy_cleanup,"recursive");enqueue("later",19);systray_win32_show_balloon("R","New input rejected after cleanup",1,clicked,GINT_TO_POINTER(20),destroyed,"recursive");g_assert_cmpint(destroys[18],==,1);g_assert_cmpint(destroys[19],==,1);g_assert_cmpint(destroys[20],==,1);drain();
    puts("PASS reentrant destroy during active cancellation/coalescing/cleanup");
    begin();WM_TASKBARCREATED=WM_APP+72;enqueue("old Explorer",21);drain();enqueue("next Explorer",22);wnd_proc(NULL,WM_TASKBARCREATED,0,0);g_assert_cmpint(destroys[21],==,1);drain();send_event(NIN_BALLOONSHOW);send_event(NIN_BALLOONUSERCLICK);g_assert_cmpint(clicks[22],==,1);g_assert_cmpint(destroys[22],==,1);end();
    begin();enqueue("suppressed",23);drain();enqueue("next",24);send_event(NIN_BALLOONHIDE);g_assert_cmpint(destroys[23],==,1);drain();send_event(NIN_BALLOONSHOW);send_event(NIN_BALLOONUSERCLICK);g_assert_cmpint(clicks[24],==,1);end();
    begin();enqueue("not shown cancel",25);drain();enqueue("next",26);systray_win32_hide_balloon("not shown cancel",FALSE);g_assert_cmpint(destroys[25],==,1);g_assert_nonnull(active_balloon);send_event(NIN_BALLOONHIDE);drain();send_event(NIN_BALLOONSHOW);send_event(NIN_BALLOONUSERCLICK);g_assert_cmpint(clicks[26],==,1);end();
    puts("PASS Explorer restart + hidden-without-show + cancellation-before-show");
    begin();fail_next_notification=TRUE;enqueue("fail",27);enqueue("next",28);drain();g_assert_cmpint(destroys[27],==,1);send_event(NIN_BALLOONSHOW);send_event(NIN_BALLOONUSERCLICK);g_assert_cmpint(clicks[28],==,1);end();
    begin();for(int id=40;id<=105;id++)enqueue(NULL,id);g_assert_cmpint(g_queue_get_length(&balloon_queue),==,64);g_assert_cmpint(destroys[40],==,1);g_assert_cmpint(destroys[41],==,1);end();for(int id=40;id<=105;id++)g_assert_cmpint(destroys[id],==,1);
    puts("PASS failed native display + bounded queue release ownership");
}
static const gchar* labels[]={"Show DinoX","","Online","Away","Busy","Not Available","Status Message: R&D — Все хорошо","","Sound","Notify","","Preferences","","Quit",NULL};
static const gint icons[]={1,0,2,3,4,5,6,0,7,8,0,9,0,10};
static void bitmap(const char* name,BOOL dark,UINT dpi) {
    menu_dpi=dpi;menu_max_width=MulDiv(420,dpi,96);menu_dark=dark;
    if(menu_font)DeleteObject(menu_font);
    menu_font=CreateFontW(-MulDiv(14,dpi,96),0,0,0,FW_NORMAL,FALSE,FALSE,FALSE,DEFAULT_CHARSET,OUT_DEFAULT_PRECIS,CLIP_DEFAULT_PRECIS,CLEARTYPE_QUALITY,DEFAULT_PITCH,L"Segoe UI");
    rebuild_native_menu();
    int width=0,height=0,heights[32]={0};
    for(int i=0;i<14;i++) { MEASUREITEMSTRUCT m={0};m.CtlType=ODT_MENU;m.itemData=(ULONG_PTR)menu_items[i];g_assert_true(measure_menu_item(&m));width=MAX(width,(int)m.itemWidth);heights[i]=m.itemHeight;height+=m.itemHeight; }
    BITMAPINFO bi={0};bi.bmiHeader.biSize=sizeof(BITMAPINFOHEADER);bi.bmiHeader.biWidth=width;bi.bmiHeader.biHeight=-height;bi.bmiHeader.biPlanes=1;bi.bmiHeader.biBitCount=32;bi.bmiHeader.biCompression=BI_RGB;
    void* pixels;HDC dc=CreateCompatibleDC(NULL);HBITMAP bmp=CreateDIBSection(dc,&bi,DIB_RGB_COLORS,&pixels,NULL,0);HGDIOBJ old=SelectObject(dc,bmp);
    int y=0;for(int i=0;i<14;i++) {DRAWITEMSTRUCT d={0};d.CtlType=ODT_MENU;d.itemData=(ULONG_PTR)menu_items[i];d.itemID=i+1;d.hDC=dc;d.rcItem=(RECT){0,y,width,y+heights[i]};if(i==2||i==8)d.itemState=ODS_CHECKED;if(i==11)d.itemState=ODS_SELECTED|ODS_FOCUS;g_assert_true(paint_menu_item(&d));y+=heights[i];}
    BITMAPFILEHEADER fh={0};fh.bfType=0x4D42;fh.bfOffBits=sizeof fh+sizeof(BITMAPINFOHEADER);fh.bfSize=fh.bfOffBits+width*height*4;
    const char *artifact_dir = g_getenv("DINOX_TRAY_TEST_ARTIFACT_DIR");
    gchar *artifact = g_build_filename(artifact_dir ? artifact_dir : g_get_tmp_dir(), name, NULL);
    FILE* f=g_fopen(artifact,"wb");g_assert_nonnull(f);fwrite(&fh,sizeof fh,1,f);fwrite(&bi.bmiHeader,sizeof(BITMAPINFOHEADER),1,f);fwrite(pixels,width*height*4,1,f);fclose(f); if (!artifact_dir) g_remove(artifact); g_free(artifact);SelectObject(dc,old);DeleteObject(bmp);DeleteDC(dc);
    printf("PASS render %s %dx%d DPI=%u\n",name,width,height,dpi);
}
static void menu_tests(void) {
    begin();systray_win32_set_menu((gchar**)labels,icons,(1u<<2)|(1u<<8));g_assert_cmpint(GetMenuItemCount(popup_menu),==,14);
    g_assert_true((GetMenuState(popup_menu,2,MF_BYPOSITION)&MFT_RADIOCHECK)!=0);
    g_assert_true((GetMenuState(popup_menu,8,MF_BYPOSITION)&MFT_RADIOCHECK)==0);
    g_assert_true(menu_items[6]->accessible.dwMSAASignature==MSAA_MENU_SIG);
    g_assert_true(wcscmp(menu_items[6]->accessible.pszWText,L"Status Message: R&D — Все хорошо")==0);
    bitmap("menu-light-96.bmp",FALSE,96);bitmap("menu-dark-96.bmp",TRUE,96);bitmap("menu-dark-144.bmp",TRUE,144);
    fake_contrast=TRUE;systray_win32_set_menu_theme(TRUE, FALSE);MENUITEMINFOW mi={0};mi.cbSize=sizeof mi;mi.fMask=MIIM_FTYPE;GetMenuItemInfoW(popup_menu,2,TRUE,&mi);g_assert_false((mi.fType&MFT_OWNERDRAW)!=0);fake_contrast=FALSE;
    // Native menu currently tracked: defer replacing owned item data until closed.
    systray_win32_set_menu_theme(FALSE, FALSE);menu_open=TRUE;TrayMenuItem* old=menu_items[0];systray_win32_set_menu_theme(TRUE, FALSE);g_assert_true(old==menu_items[0]);g_assert_true(menu_dirty);menu_open=FALSE;rebuild_native_menu();end();
    begin();gchar *russian[]={"Все хорошо",NULL};gint russian_icon[]={1};systray_win32_set_menu(russian,russian_icon,0);LRESULT result=wnd_proc(NULL,WM_MENUCHAR,0x0432,(LPARAM)popup_menu);g_assert_cmpint(HIWORD(result),==,MNC_SELECT);g_assert_cmpint(LOWORD(result),==,0);end();
    puts("PASS accessibility names + native radio/check + high contrast + deferred menu mutation + Cyrillic keyboard navigation");
}

/* Only the Shell notification API is mocked. Menus, UTF conversion, queue and
 * rendering all use the production implementation. Never call tray init: that
 * would change Jump Lists, register a native icon and touch the user's session. */
static void assert_valid_utf16(const wchar_t *value) {
    GError *error = NULL;
    gchar *utf8 = g_utf16_to_utf8((const gunichar2 *)value, -1, NULL, NULL, &error);
    g_assert_no_error(error);
    g_assert_nonnull(utf8);
    g_free(utf8);
}
static void unicode_tooltip(void) {
    begin();
    const char *text = "日本語 العربية עברית اردو Türkçe 😀 R&D_name";
    systray_win32_set_tooltip(text);
    gchar *roundtrip = g_utf16_to_utf8((gunichar2 *)nid.szTip, -1, NULL, NULL, NULL);
    g_assert_cmpstr(roundtrip, ==, text);
    g_free(roundtrip);
    for (guint prefix = 124; prefix <= 129; prefix++) {
        gchar *padding = g_strnfill(prefix, 'a');
        gchar *long_text = g_strconcat(padding, "😀tail", NULL);
        systray_win32_set_tooltip(long_text);
        assert_valid_utf16(nid.szTip);
        g_assert_cmpuint(wcslen(nid.szTip), <, G_N_ELEMENTS(nid.szTip));
        g_free(long_text); g_free(padding);
    }
    end();
}
static void unicode_balloon(void) {
    for (guint offset = 0; offset < 4; offset++) {
        begin();
        gchar *title_prefix = g_strnfill(61 + offset, 't');
        gchar *body_prefix = g_strnfill(253 + offset, 'b');
        gchar *title = g_strconcat(title_prefix, "😀title", NULL);
        gchar *body = g_strconcat(body_prefix, "😀body", NULL);
        systray_win32_show_balloon(title, body, 1, NULL, NULL, NULL, "unicode");
        drain();
        assert_valid_utf16(nid.szInfoTitle);
        assert_valid_utf16(nid.szInfo);
        g_assert_cmpuint(wcslen(nid.szInfoTitle), <, G_N_ELEMENTS(nid.szInfoTitle));
        g_assert_cmpuint(wcslen(nid.szInfo), <, G_N_ELEMENTS(nid.szInfo));
        end();
        g_free(title_prefix); g_free(body_prefix); g_free(title); g_free(body);
    }
}
static void unicode_log_path(void) {
    gchar *saved_temp = g_strdup(g_getenv("TEMP"));
    GError *error = NULL;
    gchar *base = g_dir_make_tmp("dinox-tray-XXXXXX", &error);
    g_assert_no_error(error);
    gchar *directory = g_build_filename(base, "日本語 العربية 😀", NULL);
    g_assert_cmpint(g_mkdir(directory, 0700), ==, 0);
    gchar *path = g_build_filename(directory, "dinox_systray.log", NULL);
    if (tray_log_file) { fclose(tray_log_file); tray_log_file = NULL; }
    g_setenv("TEMP", directory, TRUE);
    tray_log_file_only("Unicode path test");
    g_assert_nonnull(tray_log_file);
    fclose(tray_log_file); tray_log_file = NULL;
    gchar *contents = NULL;
    g_assert_true(g_file_get_contents(path, &contents, NULL, &error));
    g_assert_no_error(error);
    g_assert_nonnull(strstr(contents, "Unicode path test"));
    g_free(contents);
    g_remove(path); g_rmdir(directory); g_rmdir(base);
    if (saved_temp) g_setenv("TEMP", saved_temp, TRUE); else g_unsetenv("TEMP");
    g_free(saved_temp); g_free(path); g_free(directory); g_free(base);
}
static void multilingual_menu(void) {
    const gchar *cases[] = {"日本語 R&D_name 😀", "العربية حالة_العمل 😀", "עברית שם_מצב 😀",
        "اردو R&D 😀", "Türkçe İı_Çş", "Русский R&D_😀", "繁體中文_😀"};
    for (guint i = 0; i < G_N_ELEMENTS(cases); i++) {
        begin();
        gchar *items[] = {(gchar *)cases[i], NULL};
        gint item_icons[] = {1};
        systray_win32_set_menu(items, item_icons, 0);
        gchar *roundtrip = g_utf16_to_utf8((gunichar2 *)menu_items[0]->accessible.pszWText, -1, NULL, NULL, NULL);
        g_assert_cmpstr(roundtrip, ==, cases[i]);
        g_free(roundtrip);
        fake_contrast = TRUE;
        systray_win32_set_menu_theme(FALSE, FALSE);
        wchar_t text[512];
        g_assert_cmpint(GetMenuStringW(popup_menu, 0, text, G_N_ELEMENTS(text), MF_BYPOSITION), >, 0);
        roundtrip = g_utf16_to_utf8((gunichar2 *)text, -1, NULL, NULL, NULL);
        gchar **parts = g_strsplit(cases[i], "&", -1);
        gchar *expected = g_strjoinv("&&", parts);
        g_assert_cmpstr(roundtrip, ==, expected);
        g_strfreev(parts); g_free(expected); g_free(roundtrip);
        fake_contrast = FALSE;
        end();
    }
}
static void lifecycle(void) { shell_calls = 0; memset(clicks, 0, sizeof clicks); memset(destroys, 0, sizeof destroys); queue_tests(); reentrancy_test(); edge_tests(); }
int main(int argc, char **argv) {
    g_test_init(&argc, &argv, NULL);
    g_test_add_func("/SystrayWindows/tooltip_unicode_boundary", unicode_tooltip);
    g_test_add_func("/SystrayWindows/balloon_unicode_boundary", unicode_balloon);
    g_test_add_func("/SystrayWindows/log_unicode_path", unicode_log_path);
    g_test_add_func("/SystrayWindows/notification_lifecycle", lifecycle);
    g_test_add_func("/SystrayWindows/multilingual_menu", multilingual_menu);
    g_test_add_func("/SystrayWindows/menu_render_accessibility", menu_tests);
    return g_test_run();
}
