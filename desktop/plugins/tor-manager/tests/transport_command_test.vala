using Dino.Plugins.TorManager;

private void normal_path() {
    try {
        var command = new TransportCommand(GLib.Path.build_filename(
            GLib.Environment.get_tmp_dir(), "dinox-test", "lyrebird"));
        assert(command.executable == GLib.Path.build_filename(".", "lyrebird"));
        assert(command.config_line("obfs4,webtunnel") ==
            "ClientTransportPlugin obfs4,webtunnel exec %s\n".printf(command.executable));
        assert(!command.config_line("obfs4").contains("\""));
    } catch (GLib.Error e) {
        GLib.error("Unexpected transport error: %s", e.message);
    }
}

private void directory_with_spaces() {
    try {
        string directory = GLib.Path.build_filename(
            GLib.Environment.get_tmp_dir(), "DinoX Build ä", "Transport Helpers");
        var command = new TransportCommand(GLib.Path.build_filename(directory, "lyrebird.exe"));
        assert(command.working_directory == directory);
        assert(command.executable == GLib.Path.build_filename(".", "lyrebird.exe"));
        assert(!command.config_line("webtunnel").contains("DinoX Build"));
    } catch (GLib.Error e) {
        GLib.error("Unexpected transport error: %s", e.message);
    }
}

private void invalid_filename() {
    string[] filenames = {"lyre bird", "lyre\tbird", "lyre\nbird", "lyre\"bird", "lyre'bird", "lyre#bird"};
    foreach (string filename in filenames) {
        bool rejected = false;
        try {
            new TransportCommand(GLib.Path.build_filename(GLib.Environment.get_tmp_dir(), filename));
        } catch (GLib.IOError e) {
            rejected = true;
        }
        assert(rejected);
    }
}

int main(string[] crt_args) {
#if WINDOWS
    // Match the application: MinGW's narrow CRT argv can lose Unicode paths.
    string[] win32_args = GLib.Win32.get_command_line();
    unowned string[] args = win32_args;
#else
    unowned string[] args = crt_args;
#endif
    GLib.Test.init(ref args);
    GLib.Test.add_func("/TorTransport/plain-path", normal_path);
    GLib.Test.add_func("/TorTransport/spaces-unicode-directory", directory_with_spaces);
    GLib.Test.add_func("/TorTransport/reject-unrepresentable-filename", invalid_filename);
    return GLib.Test.run();
}
