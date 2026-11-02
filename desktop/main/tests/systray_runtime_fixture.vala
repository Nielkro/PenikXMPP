using GLib;
namespace Dino.Entities { public class Conversation : Object {} }
namespace Dino {
 public class Settings : Object {
  public bool keep_background { get; set; default=true; }
  public bool notifications { get; set; default=true; }
  public bool notification_sounds { get; set; default=true; }
 }
 public class Application : Object {
  private static Application? instance;
  public Settings settings = new Settings();
  public Application() { instance = this; }
  public static Application get_default() { return instance; }
 }
 public class PresenceManager : Object {
  public static string IDENTITY = "presence";
  public string show = "online";
  public string? status_msg = "R&D_name__ 日本語 العربية 😀";
  public signal void status_changed(string show, string? msg);
  public string get_current_show() { return show; }
  public string? get_current_status_msg() { return status_msg; }
  public void update(string value) { stdout.printf("status=%s\n", value); stdout.flush(); show = value; status_changed(value, status_msg); }
 }
 public class ChatInteraction : Object {
  public static string IDENTITY = "chat";
  public void on_window_focus_out(Entities.Conversation? conv) {}
 }
 public class ConnectionManager : Object { public void disconnect_all() {} }
 public class StreamInteractor : Object {
  public PresenceManager pm = new PresenceManager();
  public ChatInteraction ci = new ChatInteraction();
  public ConnectionManager connection_manager = new ConnectionManager();
  public T get_module<T>(string name) { return (T)(name == "presence" ? (Object)pm : (Object)ci); }
 }
 public class Controller : Object { public Entities.Conversation? conversation; }
}
namespace Dino.Ui {
 public class MainWindow : Object {
  public signal bool close_request();
  public bool visible=true;
  public void set_visible(bool value) { visible=value; }
  public bool is_visible() { return visible; }
  public void present() { visible=true; }
 }
 public class Application : Dino.Application {
  public StreamInteractor stream_interactor = new StreamInteractor();
  public Controller? controller;
  public void activate_action(string name, Variant? parameter) { stdout.printf("action=%s\n", name); stdout.flush(); if (name == "set-status" && parameter != null) stream_interactor.pm.update(parameter.get_string()); }
  public bool plugin_shutdown_in_progress { get { return false; } }
  public void shutdown_plugins_once() {}
  public void hold() {}
  public void release() {}
  public void quit() {}
 }
}

// No real XMPP account, settings backend, tray host or user window is used.
[DBus (name = "im.dinox.TrayTest")]
public class TrayTestControl : Object {
 public Dino.Ui.SystrayManager manager;
 public TrayTestControl(Dino.Ui.SystrayManager value) { manager = value; }
 public void cleanup() throws DBusError, IOError { manager.cleanup(); }
}
int main() {
 assert(Intl.setlocale(LocaleCategory.ALL, "") != null);
 var catalogs = Environment.get_variable("DINOX_TRAY_TEST_LOCALEDIR");
 if (catalogs != null) { Intl.bindtextdomain("dino", catalogs); Intl.bind_textdomain_codeset("dino", "UTF-8"); Intl.textdomain("dino"); }
 Gtk.init(); Adw.init();
 Gtk.Widget.set_default_direction(Environment.get_variable("DINOX_TRAY_TEST_RTL") == "1" ? Gtk.TextDirection.RTL : Gtk.TextDirection.LTR);
 var loop = new MainLoop();
 var app = new Dino.Ui.Application();
 var manager = new Dino.Ui.SystrayManager(app);
 var window = new Dino.Ui.MainWindow();
 manager.set_window(window);
 try {
  var connection = Bus.get_sync(BusType.SESSION);
  connection.register_object<TrayTestControl>("/TrayTest", new TrayTestControl(manager));
 } catch (Error e) { stderr.printf("%s\n", e.message); return 1; }
 Timeout.add(60000, () => { manager.cleanup(); loop.quit(); return Source.REMOVE; });
 loop.run(); return 0;
}
