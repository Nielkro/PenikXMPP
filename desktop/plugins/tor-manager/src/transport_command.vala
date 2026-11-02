namespace Dino.Plugins.TorManager {

/** Tor splits ClientTransportPlugin on whitespace; it does not unquote argv. */
internal class TransportCommand : Object {
    public string working_directory { get; private set; }
    public string executable { get; private set; }

    public TransportCommand(string path) throws GLib.IOError {
        string absolute_path = GLib.File.new_for_path(path).get_path();
        string basename = GLib.Path.get_basename(absolute_path);
        // Directory names may contain spaces and Unicode: pass that part via
        // the subprocess cwd, not through Tor's whitespace-split directive.
        for (int i = 0; i < basename.length; i++) {
            char c = basename[i];
            if (c.isspace() || c == '"' || c == '\'' || c == '#') {
                throw new GLib.IOError.INVALID_ARGUMENT(
                    "Bridge transport executable filename contains unsupported characters");
            }
        }
        working_directory = GLib.Path.get_dirname(absolute_path);
        // Explicit relative path prevents an implicit PATH lookup. Windows
        // receives .\lyrebird.exe; Unix receives ./lyrebird.
        executable = GLib.Path.build_filename(".", basename);
    }

    public string config_line(string transports) {
        return "ClientTransportPlugin %s exec %s\n".printf(transports, executable);
    }
}

}
