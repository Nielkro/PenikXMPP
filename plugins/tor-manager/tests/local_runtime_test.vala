using Dino.Plugins.TorManager;

private void delete_tree(GLib.File file) throws GLib.Error {
    if (file.query_file_type(GLib.FileQueryInfoFlags.NOFOLLOW_SYMLINKS) == GLib.FileType.DIRECTORY) {
        var entries = file.enumerate_children("standard::name", GLib.FileQueryInfoFlags.NOFOLLOW_SYMLINKS);
        GLib.FileInfo? entry;
        while ((entry = entries.next_file()) != null) delete_tree(file.get_child(entry.get_name()));
        entries.close();
    }
    file.delete();
}

[Compact]
private class Fixture {
    public string root;
    public string source;
    public string prefix;
    public string executable;

    public Fixture() throws GLib.Error {
        root = GLib.DirUtils.make_tmp("dinox-tor-lookup-XXXXXX");
        source = GLib.Path.build_filename(root, "DinoX Source ä with spaces");
        prefix = GLib.Path.build_filename(source, ".vendor-deps", "linux-tor-runtime");
        executable = GLib.Path.build_filename(source, "build", "main", "dinox");
        write("meson.build");
        write("scripts/prepare-linux-tor-runtime.sh");
        write("build/meson-private/coredata.dat");
        foreach (string path in new string[] { "bin/tor", "bin/lyrebird", "share/tor/geoip", "share/tor/geoip6", "dinox-tor-runtime.json" }) {
            write(".vendor-deps/linux-tor-runtime/" + path);
            if (path.has_prefix("bin/")) assert(GLib.FileUtils.chmod(GLib.Path.build_filename(prefix, path), 0755) == 0);
        }
    }

    public void write(string relative) throws GLib.Error {
        string path = GLib.Path.build_filename(source, relative);
        assert(GLib.DirUtils.create_with_parents(GLib.Path.get_dirname(path), 0700) == 0);
        GLib.FileUtils.set_contents(path, "offline fixture only\n");
    }
    public void cleanup() throws GLib.Error { delete_tree(GLib.File.new_for_path(root)); }
}

private void source_build() {
    Fixture? fixture = null;
    string previous_cwd = GLib.Environment.get_current_dir();
    try {
        fixture = new Fixture();
        assert(GLib.Environment.set_current_dir(fixture.root) == 0);
        assert(LocalTorRuntime.find_prefix(fixture.executable) == fixture.prefix);
        delete_tree(GLib.File.new_for_path(GLib.Path.build_filename(fixture.source, "build")));
        fixture.write("build/meson-private/coredata.dat");
        assert(LocalTorRuntime.find_prefix(fixture.executable) == fixture.prefix);
    } catch (GLib.Error error) { GLib.error("Source lookup fixture failed: %s", error.message); }
    finally {
        assert(GLib.Environment.set_current_dir(previous_cwd) == 0);
        if (fixture != null) {
            try { fixture.cleanup(); } catch (GLib.Error error) { GLib.error("Cleanup failed: %s", error.message); }
        }
    }
}

private void incomplete_runtime() {
    Fixture? fixture = null;
    try {
        fixture = new Fixture();
        string lyrebird = GLib.Path.build_filename(fixture.prefix, "bin", "lyrebird");
        assert(GLib.FileUtils.chmod(lyrebird, 0644) == 0);
        assert(LocalTorRuntime.find_prefix(fixture.executable) == null);
        assert(GLib.FileUtils.chmod(lyrebird, 0755) == 0);
        GLib.File.new_for_path(GLib.Path.build_filename(fixture.prefix, "share", "tor", "geoip6")).delete();
        assert(LocalTorRuntime.find_prefix(fixture.executable) == null);
        fixture.write(".vendor-deps/linux-tor-runtime/share/tor/geoip6");
        GLib.File.new_for_path(lyrebird).delete();
        // The resolver never substitutes a system/PATH executable for this bundle.
        assert(LocalTorRuntime.find_prefix(fixture.executable) == null);
    } catch (GLib.Error error) { GLib.error("Missing-assets fixture failed: %s", error.message); }
    finally {
        if (fixture != null) {
            try { fixture.cleanup(); } catch (GLib.Error error) { GLib.error("Cleanup failed: %s", error.message); }
        }
    }
}

private void installed_executable() {
    Fixture? fixture = null;
    try {
        fixture = new Fixture();
        assert(LocalTorRuntime.find_prefix(GLib.Path.build_filename(fixture.source, "usr", "bin", "dinox")) == null);
        GLib.File.new_for_path(GLib.Path.build_filename(fixture.source, "build", "meson-private", "coredata.dat")).delete();
        assert(LocalTorRuntime.find_prefix(fixture.executable) == null);
    } catch (GLib.Error error) { GLib.error("Installed lookup fixture failed: %s", error.message); }
    finally {
        if (fixture != null) {
            try { fixture.cleanup(); } catch (GLib.Error error) { GLib.error("Cleanup failed: %s", error.message); }
        }
    }
}

private void symlinked_directory() {
    Fixture? fixture = null;
    try {
        fixture = new Fixture();
        foreach (string relative in new string[] { ".vendor-deps", ".vendor-deps/linux-tor-runtime", ".vendor-deps/linux-tor-runtime/bin", ".vendor-deps/linux-tor-runtime/share", ".vendor-deps/linux-tor-runtime/share/tor" }) {
            var directory = GLib.File.new_for_path(GLib.Path.build_filename(fixture.source, relative));
            var saved = GLib.File.new_for_path(GLib.Path.build_filename(fixture.root, "saved-directory"));
            directory.move(saved, GLib.FileCopyFlags.NOFOLLOW_SYMLINKS);
            directory.make_symbolic_link((!) saved.get_path());
            assert(LocalTorRuntime.find_prefix(fixture.executable) == null);
            directory.delete();
            saved.move(directory, GLib.FileCopyFlags.NOFOLLOW_SYMLINKS);
            assert(LocalTorRuntime.find_prefix(fixture.executable) == fixture.prefix);
        }
    } catch (GLib.Error error) { GLib.error("Symlink fixture failed: %s", error.message); }
    finally {
        if (fixture != null) {
            try { fixture.cleanup(); } catch (GLib.Error error) { GLib.error("Cleanup failed: %s", error.message); }
        }
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
    GLib.Test.add_func("/TorRuntime/private-prefix-survives-build-wipe-and-other-cwd", source_build);
    GLib.Test.add_func("/TorRuntime/incomplete-or-nonexecutable-bundle-is-not-used", incomplete_runtime);
    GLib.Test.add_func("/TorRuntime/installed-application-does-not-use-source-prefix", installed_executable);
    GLib.Test.add_func("/TorRuntime/private-prefix-rejects-intermediate-symlinks", symlinked_directory);
    return GLib.Test.run();
}
