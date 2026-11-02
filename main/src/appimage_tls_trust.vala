namespace Dino.AppImageTlsTrust {

[CCode (cname = "g_tls_file_database_new", cheader_filename = "gio/gio.h")]
private extern GLib.TlsDatabase? open_database(string anchors) throws GLib.Error;

// AppRun selects the host's current CA bundle. GnuTLS/glib-networking do not
// consume GTLS_SYSTEM_CA_FILE themselves, so install it through GIO's API
// before any application TLS connections or HTTP sessions are constructed.
// Native packages retain their distribution's default trust-store handling.
public bool configure(string? appimage, string? anchors) throws GLib.Error {
    if (appimage == null || appimage == "") return false;
    if (anchors == null || anchors == "" || !GLib.Path.is_absolute(anchors)) {
        throw new GLib.IOError.INVALID_ARGUMENT("AppImage requires an absolute system CA bundle path");
    }

    GLib.TlsDatabase? database = open_database(anchors);
    if (database == null) {
        throw new GLib.IOError.FAILED("Could not load the AppImage system CA bundle");
    }
    GLib.TlsBackend.get_default().set_default_database(database);
    return true;
}

}
