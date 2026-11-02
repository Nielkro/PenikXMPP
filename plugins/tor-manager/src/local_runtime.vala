namespace Dino.Plugins.TorManager.LocalTorRuntime {

/** Private source-build helpers live outside the disposable Meson build tree. */
    internal string? find_prefix(string executable_path) {
        if (!GLib.Path.is_absolute(executable_path)) return null;
        string build_directory = GLib.Path.get_dirname(GLib.Path.get_dirname(executable_path));
        string source_directory = GLib.Path.get_dirname(build_directory);
        if (!GLib.FileUtils.test(GLib.Path.build_filename(build_directory, "meson-private", "coredata.dat"), GLib.FileTest.IS_REGULAR) ||
                !GLib.FileUtils.test(GLib.Path.build_filename(source_directory, "meson.build"), GLib.FileTest.IS_REGULAR) ||
                !GLib.FileUtils.test(GLib.Path.build_filename(source_directory, "scripts", "prepare-linux-tor-runtime.sh"), GLib.FileTest.IS_REGULAR)) {
            return null;
        }
        string prefix = GLib.Path.build_filename(source_directory, ".vendor-deps", "linux-tor-runtime");
        string ancestor = prefix;
        while (ancestor != GLib.Path.DIR_SEPARATOR_S) {
            if (!GLib.FileUtils.test(ancestor, GLib.FileTest.IS_DIR) || GLib.FileUtils.test(ancestor, GLib.FileTest.IS_SYMLINK)) return null;
            ancestor = GLib.Path.get_dirname(ancestor);
        }
        foreach (string relative in new string[] { "bin", "share", "share/tor" }) {
            string directory = GLib.Path.build_filename(prefix, relative);
            if (!GLib.FileUtils.test(directory, GLib.FileTest.IS_DIR) || GLib.FileUtils.test(directory, GLib.FileTest.IS_SYMLINK)) return null;
        }
        foreach (string relative in new string[] { "bin/tor", "bin/lyrebird", "share/tor/geoip", "share/tor/geoip6", "dinox-tor-runtime.json" }) {
            string path = GLib.Path.build_filename(prefix, relative);
            if (!GLib.FileUtils.test(path, GLib.FileTest.IS_REGULAR) || GLib.FileUtils.test(path, GLib.FileTest.IS_SYMLINK)) return null;
            if (relative.has_prefix("bin/") && !GLib.FileUtils.test(path, GLib.FileTest.IS_EXECUTABLE)) return null;
        }
        return prefix;
    }
}
