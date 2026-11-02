/*
 * Copyright (C) 2025-2026 Ralf Peter <dinox@handwerker.jetzt>
 *
 * This program is free software: you can redistribute it and/or modify
 * it under the terms of the GNU General Public License as published by
 * the Free Software Foundation, either version 3 of the License, or
 * (at your option) any later version.
 *
 * Windows Systray — Shell_NotifyIcon via systray_win32.c helper.
 * Provides tray icon with left-click toggle and right-click context menu
 * (status selection + Quit).
 *
 * Mirrors the Linux SystrayManager (systray.vala) behaviour:
 *   - Left-click → toggle window show/hide
 *   - Right-click → context menu: Online / Away / Busy / Not Available / ─ / Quit
 *   - Window X → hide to tray (no balloon), app stays alive
 *   - "Quit" menu item → graceful disconnect + exit
 */
using Gtk;
using GLib;
using Dino.Entities;

namespace Dino.Ui {

    public class SystrayManager : Object {

        private unowned Application application;
        public MainWindow? window;
        public bool is_hidden { get { return window != null && !window.is_visible(); } }
        private bool disposed = false;
        private bool holding = false;
        private bool quitting = false;
        private bool tray_available = false;
        private bool first_hide = true;   /* show balloon on first hide-to-tray */

        private const int MENU_SHOW_ID = 0;
        private const int MENU_FIRST_STATUS_ID = 2;
        private const int MENU_STATUS_MESSAGE_ID = 6;
        private const int MENU_SOUND_ID = 8;
        private const int MENU_NOTIFICATIONS_ID = 9;
        private const int MENU_PREFERENCES_ID = 11;
        private const int MENU_QUIT_ID = 13;
        private string[] status_keys = {"online", "away", "dnd", "xa"};
        private string current_status = "online";
        private string? current_status_msg = null;
        private ulong style_changed_id = 0;
        private ulong design_changed_id = 0;
        private ulong presence_changed_id = 0;
        private ulong notifications_changed_id = 0;
        private ulong notification_sounds_changed_id = 0;

        public SystrayManager(Application application) {
            this.application = application;

            bool ok = SystrayWin32.init("DinoX", 1, on_tray_callback, (void*) this);
            if (!ok) {
                warning("Systray: Shell_NotifyIcon init failed — running without tray");
                return;
            }

            tray_available = true;
            // On Windows there is no D-Bus session to keep the main loop alive.
            // hold() once so GApplication doesn't quit when the window is hidden.
            // (Matches the Linux hold_app() fallback for missing SNI watcher.)
            application.hold();
            holding = true;
            var style = Adw.StyleManager.get_default();
            update_menu_theme();
            style_changed_id = style.notify["dark"].connect(update_menu_theme);
            design_changed_id = application.settings.notify["interface-style"].connect(update_menu_theme);
            rebuild_menu();
            debug("Systray: Win32 tray icon created");
        }

        private void update_menu_theme() {
            SystrayWin32.set_menu_theme(Adw.StyleManager.get_default().dark,
                application.settings.interface_style == "website");
        }

        public void set_window(MainWindow window) {
            this.window = window;

            window.close_request.connect(() => {
                var app = Dino.Application.get_default();
                bool bg = (app != null) ? app.settings.keep_background : true;
                debug("Systray: close_request fired — keep_background=%s, tray_available=%s",
                      bg.to_string(), tray_available.to_string());

                if (bg && tray_available) {
                    // Just hide — matches Linux behaviour (no balloon, no hold)
                    hide_window();

                    // First time: show a balloon so the user knows where to find the icon
                    if (first_hide) {
                        first_hide = false;
                        SystrayWin32.show_balloon(
                            "DinoX",
                            _("DinoX is still running. Click the DinoX icon near the clock (notification area) to reopen the window. Right-click for status and quit."),
                            1,   /* NIIF_INFO */
                            null, null, null, "background");
                    }

                    return true;
                } else {
                    debug("Systray: close_request → quitting (bg=%s, tray=%s)",
                          bg.to_string(), tray_available.to_string());
                    quit_application();
                    return true;
                }
            });

            /* Track status changes for menu checkmarks */
            var pm = application.stream_interactor.get_module<PresenceManager>(PresenceManager.IDENTITY);
            presence_changed_id = pm.status_changed.connect((show, msg) => {
                current_status = show;
                current_status_msg = msg;
                rebuild_menu();
            });
            notifications_changed_id = application.settings.notify["notifications"].connect(() => {
                rebuild_menu();
            });
            notification_sounds_changed_id = application.settings.notify["notification-sounds"].connect(() => {
                rebuild_menu();
            });
            current_status = pm.get_current_show();
            current_status_msg = pm.get_current_status_msg();
            rebuild_menu();
        }

        /* ---- menu ---- */

        private void rebuild_menu() {
            string[] status_labels = {_("Online"), _("Away"), _("Busy"), _("Not Available")};
            string?[] labels = new string?[15];
            int[] icons = new int[14];
            uint32 checked = 0;
            labels[MENU_SHOW_ID] = _("Show DinoX");
            icons[MENU_SHOW_ID] = 1;
            labels[1] = "";
            for (int i = 0; i < 4; i++) {
                int id = MENU_FIRST_STATUS_ID + i;
                labels[id] = status_labels[i];
                icons[id] = 2 + i;
                if (status_keys[i] == current_status) checked |= (1u << id);
            }
            labels[MENU_STATUS_MESSAGE_ID] = current_status_msg != null && current_status_msg.strip() != ""
                ? _("Status Message: %s").printf(current_status_msg.strip()) : _("Set Status Message…");
            icons[MENU_STATUS_MESSAGE_ID] = 6;
            labels[7] = "";
            labels[MENU_SOUND_ID] = _("Sound");
            icons[MENU_SOUND_ID] = 7;
            labels[MENU_NOTIFICATIONS_ID] = _("Notify");
            icons[MENU_NOTIFICATIONS_ID] = 8;
            if (application.settings.notification_sounds) checked |= (1u << MENU_SOUND_ID);
            if (application.settings.notifications) checked |= (1u << MENU_NOTIFICATIONS_ID);
            labels[10] = "";
            labels[MENU_PREFERENCES_ID] = _("Preferences");
            icons[MENU_PREFERENCES_ID] = 9;
            labels[12] = "";
            labels[MENU_QUIT_ID] = _("Quit");
            icons[MENU_QUIT_ID] = 10;
            SystrayWin32.set_menu(labels, icons, checked);
        }

        /* ---- callbacks ---- */

        private static void on_tray_callback(int menu_id, void* user_data) {
            unowned SystrayManager self = (SystrayManager) user_data;
            if (self.disposed) return;

            if (menu_id == -1) {
                /* Left-click: toggle window */
                self.toggle_window_visibility();
            } else if (menu_id == -2) {
                /* Second instance activation: always show window */
                self.show_window();
                self.application.consume_pending_external_xmpp_uri();
            } else if (menu_id == -3) {
                /* System shutdown/logoff: Windows can end the session before
                 * an idle callback runs, so keep cleanup on this callback path. */
                self.quit_for_system_shutdown();
            } else if (menu_id == MENU_SHOW_ID) {
                self.show_window();
            } else if (menu_id == MENU_QUIT_ID) {
                /* Quit — use Idle to escape the Win32 message handler stack */
                Idle.add(() => {
                    self.quit_application();
                    return Source.REMOVE;
                });
            } else if (menu_id == MENU_SOUND_ID) {
                self.application.settings.notification_sounds = !self.application.settings.notification_sounds;
            } else if (menu_id == MENU_NOTIFICATIONS_ID) {
                self.application.settings.notifications = !self.application.settings.notifications;
            } else if (menu_id == MENU_PREFERENCES_ID) {
                self.open_preferences();
            } else if (menu_id == MENU_STATUS_MESSAGE_ID) {
                self.show_window();
                self.application.activate_action("set-status-message", null);
            } else if (menu_id >= MENU_FIRST_STATUS_ID && menu_id < MENU_FIRST_STATUS_ID + 4) {
                /* Status change */
                string status = self.status_keys[menu_id - MENU_FIRST_STATUS_ID];
                self.application.activate_action("set-status", new Variant.string(status));
            }
        }

        /* ---- window visibility ---- */

        public void toggle_window_visibility() {
            if (window == null) return;
            if (!window.is_visible()) {
                show_window();
            } else {
                hide_window();
            }
        }

        private void show_window() {
            if (window == null) return;
            debug("Systray: show_window()");
            window.set_visible(true);
            window.present();
        }

        private void open_preferences() {
            show_window();
            application.activate_action("preferences-page", new Variant.string("general"));
        }

        public void hide_window() {
            if (window == null) return;
            debug("Systray: hide_window()");

            Conversation? conversation = null;
            if (application.controller != null) {
                conversation = application.controller.conversation;
            }
            application.stream_interactor.get_module<ChatInteraction>(ChatInteraction.IDENTITY).on_window_focus_out(conversation);

            window.set_visible(false);
        }

        /* ---- quit ---- */

        public void quit_application() {
            debug("Systray: quit_application() called");

            if (quitting) {
                debug("Systray: quit already in progress");
                return;
            }
            quitting = true;

            begin_quit(false);
        }

        private void quit_for_system_shutdown() {
            message("Systray: system shutdown requested");

            if (quitting) {
                debug("Systray: quit already in progress");
                return;
            }
            quitting = true;

            begin_quit(true);
        }

        private void begin_quit(bool system_shutdown) {
            if (window != null)
                window.set_visible(false);

            cleanup();

            if (system_shutdown) {
                message("Systray: Disconnecting all accounts before system end-session");
            } else {
                debug("Systray: Disconnecting all accounts...");
            }
            application.stream_interactor.connection_manager.disconnect_all();

            if (system_shutdown) {
                message("Systray: Shutting down plugins before system end-session");
                application.shutdown_plugins_once();
            }

            if (system_shutdown) {
                message("Systray: Calling application.quit() after system end-session cleanup");
            } else {
                debug("Systray: Calling application.quit()");
            }
            application.quit();

            if (system_shutdown) return;

            // Force exit only as a delayed fallback.  A synchronous Process.exit()
            // here would skip app.run() unwinding and plugin shutdown.
            Timeout.add(1500, () => {
                // Let plugin-owned process trees finish their shutdown even
                // when the plugin dispatches this timer from a nested loop.
                if (application.plugin_shutdown_in_progress) return Source.CONTINUE;
                debug("Systray: Force exit fallback");
                application.shutdown_plugins_once();
                force_process_exit();
                return Source.REMOVE;
            });
        }

        private void force_process_exit() {
            Process.exit(0);
        }

        /* ---- cleanup ---- */

        public void cleanup() {
            if (disposed) return;
            disposed = true;

            SystrayWin32.cleanup();
            if (presence_changed_id != 0) {
                var pm = application.stream_interactor.get_module<PresenceManager>(PresenceManager.IDENTITY);
                SignalHandler.disconnect(pm, presence_changed_id);
                presence_changed_id = 0;
            }
            if (style_changed_id != 0) {
                SignalHandler.disconnect(Adw.StyleManager.get_default(), style_changed_id);
                style_changed_id = 0;
            }

            if (design_changed_id != 0) {
                SignalHandler.disconnect(application.settings, design_changed_id);
                design_changed_id = 0;
            }
            if (notifications_changed_id != 0) {
                SignalHandler.disconnect(application.settings, notifications_changed_id);
                notifications_changed_id = 0;
            }
            if (notification_sounds_changed_id != 0) {
                SignalHandler.disconnect(application.settings, notification_sounds_changed_id);
                notification_sounds_changed_id = 0;
            }

            if (holding) {
                application.release();
                holding = false;
            }
        }

        ~SystrayManager() {
            cleanup();
        }
    }
}
