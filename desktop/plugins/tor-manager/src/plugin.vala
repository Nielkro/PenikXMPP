using Dino;
using GLib;
using Adw;

namespace Dino.Plugins.TorManager {

    public class Plugin : RootInterface, Object {
        private TorManager? tor_manager;
        private TorIndicator? indicator;

        public void registered(Dino.Application app) {
            tor_manager = new TorManager(app.stream_interactor, app.db);
            app.stream_interactor.add_module(tor_manager);
            
            // Initialize UI Indicator
            indicator = new TorIndicator(tor_manager, app);
            
            app.configure_preferences.connect(on_preferences_configure);
        }
        
        public void shutdown() {
            if (tor_manager != null) {
                // IMPORTANT: Tell TorManager we are shutting down so it doesn't trigger "process exited" signals that disable the setting
                tor_manager.prepare_shutdown();

                var loop = new MainLoop(MainContext.@default(), false);
                bool finished = false;
                bool warned = false;
                uint watchdog = 0;
                tor_manager.stop_tor.begin(false, (obj, res) => {
                    tor_manager.stop_tor.end(res);
                    finished = true;
                    if (loop.is_running()) loop.quit();
                });
                if (!finished) {
                    // A timeout must not let the application exit while its
                    // owned Tor/Lyrebird tree still needs termination/reaping.
                    watchdog = Timeout.add(3000, () => {
                        if (!warned) {
                            warning("TorManager plugin shutdown: still waiting for owned process tree");
                            warned = true;
                        }
                        return Source.CONTINUE;
                    });
                    loop.run();
                }
                if (watchdog != 0) Source.remove(watchdog);

                tor_manager = null;
            }
            indicator = null;
        }

        public void rekey_database(string new_key) throws Error {
            // No own database
        }

        public void checkpoint_database() {
            // No own database
        }
        
        private void on_preferences_configure(Object object) {
             Adw.PreferencesDialog? dialog = object as Adw.PreferencesDialog;
             if (dialog != null && tor_manager != null) {
                var page = new TorSettingsPage(tor_manager);
                dialog.add(page);
                queue_page_after_first_paint(dialog, page);

                // Match the main dialog breakpoint: hide title at narrow width
                var bp = new Adw.Breakpoint(new Adw.BreakpointCondition.length(Adw.BreakpointConditionLengthType.MAX_WIDTH, 600, Adw.LengthUnit.PX));
                bp.apply.connect(() => {
                    page.title = "";
                });
                bp.unapply.connect(() => {
                    page.title = _("Tor");
                });
                dialog.add_breakpoint(bp);
             }
        }

        private void queue_page_after_first_paint(Adw.PreferencesDialog dialog, TorSettingsPage page) {
            bool scheduled = false;
            dialog.map.connect(() => {
                if (scheduled) return;
                scheduled = true;

                Gdk.FrameClock? frame_clock = dialog.get_frame_clock();
                if (frame_clock != null) {
                    wait_for_first_paint((!) frame_clock, page);
                    return;
                }

                dialog.add_tick_callback((widget, clock) => {
                    wait_for_first_paint(clock, page);
                    return Source.REMOVE;
                });
            });
        }

        private void wait_for_first_paint(Gdk.FrameClock frame_clock, TorSettingsPage page) {
            ulong handler_id = 0;
            handler_id = frame_clock.after_paint.connect(() => {
                frame_clock.disconnect(handler_id);
                page.queue_content();
            });
            frame_clock.request_phase(Gdk.FrameClockPhase.AFTER_PAINT);
        }
    }
}
