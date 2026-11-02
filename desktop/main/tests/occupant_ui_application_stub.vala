using Dino.Entities;
using Dino.Security;

namespace Dino.Ui {

// Test-only application surface for the production occupant popover. Native
// row and lifecycle tests do not execute main-window navigation or dialogs.
// Keeping that boundary explicit avoids importing the complete live UI app.
public class Application : GLib.Application, Dino.Application {
    public Database db { get; set; }
    public string? db_key { get; set; }
    public FileEncryption file_encryption { get; set; }
    public Dino.Entities.Settings settings { get; set; }
    public StreamInteractor stream_interactor { get; set; }
    public Dino.Plugins.Registry plugin_registry { get; set; default = new Dino.Plugins.Registry(); }
    public SearchPathGenerator? search_path_generator { get; set; }
    public Gtk.Window? window { get; set; }
    public OccupantUiTestController controller = new OccupantUiTestController();

    public void handle_uri(string jid, string query,
            Gee.Map<string, string> options) { }
}

public class OccupantUiTestController : Object {
    public Conversation? selected_conversation { get; private set; }

    public void select_conversation(Conversation conversation) {
        selected_conversation = conversation;
    }
}

}
