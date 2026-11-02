private string fixture_dir;

private GLib.TlsDatabase configured_database() {
    try {
        assert(Dino.AppImageTlsTrust.configure("test.AppImage",
            GLib.Path.build_filename(fixture_dir, "trusted.pem")));
        return GLib.TlsBackend.get_default().get_default_database();
    } catch (GLib.Error e) {
        GLib.error("Could not configure fixture trust: %s", e.message);
    }
}

private GLib.TlsCertificateFlags verify_peer(string file, string host) {
    var database = configured_database();
    try {
        var certificate = new GLib.TlsCertificate.from_file(
            GLib.Path.build_filename(fixture_dir, file));
        return database.verify_chain(certificate,
            GLib.TlsDatabase.PURPOSE_AUTHENTICATE_SERVER,
            new GLib.NetworkAddress(host, 443), null,
            GLib.TlsDatabaseVerifyFlags.NONE, null);
    } catch (GLib.Error e) {
        GLib.error("Could not verify fixture certificate: %s", e.message);
    }
}

private void native_trust_unchanged() {
    var original = configured_database();
    try {
        assert(!Dino.AppImageTlsTrust.configure(null, "/missing-native-bundle.pem"));
        assert(!Dino.AppImageTlsTrust.configure("", null));
    } catch (GLib.Error e) {
        GLib.error("Native trust handling changed: %s", e.message);
    }
    assert(GLib.TlsBackend.get_default().get_default_database() == original);
}

private void invalid_bundle_rejected() {
    var original = configured_database();
    string?[] invalid = { null, "", "relative.pem",
        GLib.Path.build_filename(fixture_dir, "does-not-exist.pem") };
    foreach (string? path in invalid) {
        bool rejected = false;
        try {
            Dino.AppImageTlsTrust.configure("test.AppImage", path);
        } catch (GLib.Error e) {
            rejected = true;
        }
        assert(rejected);
        assert(GLib.TlsBackend.get_default().get_default_database() == original);
    }
}

public int main(string[] args) {
    GLib.Test.init(ref args);
    assert(args.length == 2);
    fixture_dir = args[1];
    GLib.Test.add_func("/AppImageTlsTrust/native-unchanged", native_trust_unchanged);
    GLib.Test.add_func("/AppImageTlsTrust/selected-bundle", () => {
        var database = configured_database() as GLib.TlsFileDatabase;
        assert(database != null);
        assert(database.anchors == GLib.Path.build_filename(fixture_dir, "trusted.pem"));
    });
    GLib.Test.add_func("/AppImageTlsTrust/trusted-peer", () => {
        assert(verify_peer("trusted.pem", "localhost") == 0);
    });
    GLib.Test.add_func("/AppImageTlsTrust/wrong-host-rejected", () => {
        assert((verify_peer("trusted.pem", "wrong.example") & GLib.TlsCertificateFlags.BAD_IDENTITY) != 0);
    });
    GLib.Test.add_func("/AppImageTlsTrust/untrusted-peer-rejected", () => {
        assert((verify_peer("untrusted.pem", "localhost") & GLib.TlsCertificateFlags.UNKNOWN_CA) != 0);
    });
    GLib.Test.add_func("/AppImageTlsTrust/invalid-bundle-rejected", invalid_bundle_rejected);
    int result = GLib.Test.run();
    GLib.TlsBackend.get_default().set_default_database(null);
    return result;
}
