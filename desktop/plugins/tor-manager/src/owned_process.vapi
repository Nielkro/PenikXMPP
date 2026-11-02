/* SPDX-License-Identifier: GPL-3.0-or-later */
[CCode (cheader_filename = "owned_process.h")]
namespace Dino.Plugins.TorManager {
    [CCode (cname = "DinoTorOwnedProcess", lower_case_cprefix = "dino_tor_owned_process_", type_id = "dino_tor_owned_process_get_type ()")]
    public class OwnedProcess : GLib.Object {
        [CCode (cname = "dino_tor_owned_process_spawn")]
        public static OwnedProcess spawn([CCode (array_length = false, array_null_terminated = true, type = "const gchar* const*")] string[] argv, string? cwd = null) throws GLib.Error;
        public unowned GLib.InputStream get_stdout_pipe();
        public unowned GLib.InputStream get_stderr_pipe();
        public unowned string get_identifier();
        public int get_exit_status();
        public bool is_tree_drained();
        public void request_stop();
        [CCode (cname = "dino_tor_owned_process_wait_async", finish_name = "dino_tor_owned_process_wait_finish")]
        public async bool wait_async(GLib.Cancellable? cancellable = null) throws GLib.Error;
        [CCode (cname = "dino_tor_owned_process_stop_and_wait_async", finish_name = "dino_tor_owned_process_stop_and_wait_finish")]
        public async bool stop_and_wait(GLib.Cancellable? cancellable = null) throws GLib.Error;
    }
}
