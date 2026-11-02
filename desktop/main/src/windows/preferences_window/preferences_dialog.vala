using Gdk;
using Dino.Entities;
using Xmpp;
using Xmpp.Xep;
using Gee;
using Gtk;

[GtkTemplate (ui = "/im/dinox/dinox/preferences_window/preferences_dialog.ui")]
public class Dino.Ui.PreferencesDialog : Adw.PreferencesDialog {
    [GtkChild] public unowned Dino.Ui.PreferencesWindowAccounts accounts_page;
    [GtkChild] public unowned Dino.Ui.PreferencesWindowContacts contacts_page;
    [GtkChild] public unowned Dino.Ui.PreferencesWindowEncryption encryption_page;
    [GtkChild] public unowned Dino.Ui.GeneralPreferencesPage general_page;
    [GtkChild] public unowned Dino.Ui.AudioVideoPreferencesPage audio_video_page;
    private Dino.Ui.AccountPreferencesSubpage? account_page = null;
    private Gdk.FrameClock? first_frame_clock = null;
    private ulong after_paint_handler_id = 0;
    private uint frame_clock_tick_id = 0;
    private uint deferred_content_source_id = 0;
    private bool deferred_content_loaded = false;
    private int64 first_paint_wait_start_us = 0;

    [GtkChild] public unowned ViewModel.PreferencesDialog model { get; }

    public signal void backup_requested();
    public signal void restore_backup_requested();
    public signal void show_data_location();
    public signal void change_db_password_requested();
    public signal void clear_cache_requested();
    public signal void reset_database_requested();
    public signal void factory_reset_requested();

    construct {
        this.content_width = 700;
        this.content_height = 500;

        var bp = new Adw.Breakpoint(new Adw.BreakpointCondition.length(Adw.BreakpointConditionLengthType.MAX_WIDTH, 600, Adw.LengthUnit.PX));
        
        bp.apply.connect(() => {
            accounts_page.title = "";
            contacts_page.title = "";
            encryption_page.title = "";
            general_page.title = "";
            audio_video_page.title = "";
            this.queue_resize();
        });

        bp.unapply.connect(() => {
            accounts_page.title = _("Accounts");
            contacts_page.title = _("Contacts");
            encryption_page.title = _("Encryption");
            general_page.title = _("General");
            audio_video_page.title = _("Audio & Video");
            this.content_width = 700;
        });

        this.add_breakpoint(bp);

        this.bind_property("model", accounts_page, "model", BindingFlags.SYNC_CREATE);
        this.bind_property("model", contacts_page, "model", BindingFlags.SYNC_CREATE);
        this.bind_property("model", encryption_page, "model", BindingFlags.SYNC_CREATE);

        accounts_page.account_chosen.connect((account) => {
            model.selected_account = model.account_details[account];
            this.push_subpage(ensure_account_page());
        });
        
        general_page.backup_requested.connect(() => backup_requested());
        general_page.restore_backup_requested.connect(() => restore_backup_requested());
        general_page.show_data_location.connect(() => show_data_location());
        general_page.change_db_password_requested.connect(() => change_db_password_requested());
        general_page.clear_cache_requested.connect(() => clear_cache_requested());
        general_page.reset_database_requested.connect(() => reset_database_requested());
        general_page.factory_reset_requested.connect(() => factory_reset_requested());

        this.map.connect(schedule_deferred_content);
    }

    private void schedule_deferred_content() {
        if (deferred_content_loaded || deferred_content_source_id != 0 ||
                after_paint_handler_id != 0 || frame_clock_tick_id != 0) return;
        first_paint_wait_start_us = UiTiming.enabled() ? UiTiming.now_us() : 0;

        Gdk.FrameClock? frame_clock = this.get_frame_clock();
        if (frame_clock != null) {
            wait_for_first_paint((!) frame_clock);
            return;
        }

        frame_clock_tick_id = this.add_tick_callback((widget, clock) => {
            frame_clock_tick_id = 0;
            wait_for_first_paint(clock);
            return Source.REMOVE;
        });
    }

    private void wait_for_first_paint(Gdk.FrameClock frame_clock) {
        first_frame_clock = frame_clock;
        after_paint_handler_id = frame_clock.after_paint.connect(() => {
            Gdk.FrameClock? completed_clock = first_frame_clock;
            ulong completed_handler_id = after_paint_handler_id;
            first_frame_clock = null;
            after_paint_handler_id = 0;
            if (completed_clock != null && completed_handler_id != 0) {
                ((!) completed_clock).disconnect(completed_handler_id);
            }
            if (UiTiming.enabled()) {
                UiTiming.log_ms("Preferences.dialog: first paint", first_paint_wait_start_us);
            }

            deferred_content_source_id = Idle.add_full(GLib.Priority.LOW, () => {
                deferred_content_source_id = 0;
                int64 stage_start_us = UiTiming.enabled() ? UiTiming.now_us() : 0;
                general_page.ensure_content();
                if (UiTiming.enabled()) {
                    UiTiming.log_ms("Preferences.dialog: build general content", stage_start_us);
                    stage_start_us = UiTiming.now_us();
                }
                audio_video_page.ensure_content();
                if (UiTiming.enabled()) {
                    UiTiming.log_ms("Preferences.dialog: build audio-video content", stage_start_us);
                }
                deferred_content_loaded = true;
                return Source.REMOVE;
            });
        });
        frame_clock.request_phase(Gdk.FrameClockPhase.AFTER_PAINT);
    }

    private Dino.Ui.AccountPreferencesSubpage ensure_account_page() {
        if (account_page == null) {
            account_page = new Dino.Ui.AccountPreferencesSubpage();
            this.bind_property("model", account_page, "model", BindingFlags.SYNC_CREATE);
        }
        return (!) account_page;
    }

    ~PreferencesDialog() {
        if (frame_clock_tick_id != 0) {
            this.remove_tick_callback(frame_clock_tick_id);
            frame_clock_tick_id = 0;
        }
        if (deferred_content_source_id != 0) {
            Source.remove(deferred_content_source_id);
            deferred_content_source_id = 0;
        }
        if (first_frame_clock != null && after_paint_handler_id != 0) {
            ((!) first_frame_clock).disconnect(after_paint_handler_id);
            after_paint_handler_id = 0;
            first_frame_clock = null;
        }
    }
}
