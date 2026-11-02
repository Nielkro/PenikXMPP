namespace Dino.Ui {

// The titlebar tests exercise the real call control and Calls service, but
// never start a call or load media windows. Fail if they cross that boundary.
public class CallWindow : Adw.Window {
    public CallWindowController? controller { get; set; }

    public CallWindow() {
        assert_not_reached();
    }
}

public class CallWindowController : Object {
    public CallWindowController(CallWindow window, CallState state, StreamInteractor interactor) {
        assert_not_reached();
    }

    public bool owns_live_call_state(CallState state) {
        assert_not_reached();
    }
}

}
