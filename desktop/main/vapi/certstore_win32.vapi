/*
 * VAPI for Windows certificate store export helper.
 */

[CCode (cheader_filename = "certstore_win32.h")]
namespace CertstoreWin32 {

    [CCode (cname = "certstore_win32_export_pem")]
    public static bool export_pem(string output_path);

    [CCode (cname = "certstore_win32_get_active_code_page")]
    public static uint get_active_code_page();
}
