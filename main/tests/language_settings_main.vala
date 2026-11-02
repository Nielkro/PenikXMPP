[CCode (cname = "dinox_language_settings_probe_run")]
private extern int run_language_settings_probe(string executable);

private int main(string[] crt_args) {
#if WINDOWS
    string[] native_args = GLib.Win32.get_command_line();
    unowned string[] args = native_args;
#else
    unowned string[] args = crt_args;
#endif
    // Also keep the application entry's native temporary-path boundary covered.
    string temporary = Dino.Ui.Application.get_profile_temporary_directory();
    if (!temporary.validate() || !Path.is_absolute(temporary)) return 1;
    return run_language_settings_probe(args[0]);
}
