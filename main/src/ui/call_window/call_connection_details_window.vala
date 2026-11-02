using Gtk;

namespace Dino.Ui {

    public class CallConnectionDetailsWindow : Adw.Dialog {

        public Box box = new Box(Orientation.VERTICAL, 15) { hexpand=true, vexpand=true };

        private bool video_added = false;
        private CallContentDetails audio_details = new CallContentDetails("Audio");
        private CallContentDetails video_details = new CallContentDetails("Video");

        public CallConnectionDetailsWindow() {
            var toolbar_view = new Adw.ToolbarView();
            var header_bar = new Adw.HeaderBar();
            toolbar_view.add_top_bar(header_bar);

            box.margin_top = 18;
            box.margin_bottom = 18;
            box.margin_start = 18;
            box.margin_end = 18;
            
            box.append(audio_details);
            video_details.visible = false;
            box.append(video_details);

            var scrolled_window = new ScrolledWindow() {
                child=box,
                hscrollbar_policy=PolicyType.NEVER,
                vscrollbar_policy=PolicyType.AUTOMATIC,
                propagate_natural_height=false,
                min_content_height=260,
                max_content_height=420
            };

            toolbar_view.content = scrolled_window;
            this.child = toolbar_view;
            
            this.content_width = 440;
            this.content_height = 360;
        }

        public void update_content(PeerInfo peer_info) {
            if (peer_info.audio != null) {
                audio_details.update_content(peer_info.audio);
            }
            if (peer_info.video != null) {
                add_video_widgets();
                video_details.update_content(peer_info.video);
            }
        }

        private void add_video_widgets() {
            if (video_added) return;

            video_details.visible = true;
            video_added = true;
        }
    }

    public class CallContentDetails : Gtk.Grid {

        public Label rtp_title = new Label("RTP") { xalign=0 };
        public Label rtcp_title = new Label("RTCP") { xalign=0 };
        public Label sent_title = new Label("Sent") { xalign=0 };
        public Label recv_title = new Label("Received") { xalign=0 };
        public Label codec_title = new Label("Codec") { xalign=0 };
        public Label target_recv_title = new Label("Target receive bitrate") { xalign=0 };
        public Label target_send_title = new Label("Target send bitrate") { xalign=0 };
        public Label diagnostics_title = new Label("Diagnostics") { xalign=0, valign=Align.START };

        public Label rtp_ready = new Label("?") { xalign=0 };
        public Label rtcp_ready = new Label("?") { xalign=0 };
        public Label sent_bps = new Label("?") { use_markup=true, xalign=0 };
        public Label recv_bps = new Label("?") { use_markup=true, xalign=0 };
        public Label codec = new Label("?") { xalign=0 };
        public Label target_receive_bitrate = new Label("n/a") { use_markup=true, xalign=0 };
        public Label target_send_bitrate = new Label("n/a") { use_markup=true, xalign=0 };
        public Label diagnostics = new Label("") { xalign=0, wrap=true, wrap_mode=Pango.WrapMode.WORD_CHAR, width_chars=34, max_width_chars=46, selectable=true, hexpand=true };

        private PeerContentInfo? prev_info = null;
        private int row_at = 0;

        public CallContentDetails(string headline) {
            attach(new Label("<b>%s</b>".printf(headline)) { use_markup=true, xalign=0 }, 0, row_at++, 1, 1);
            attach(rtp_title, 0, row_at, 1, 1);
            attach(rtp_ready, 1, row_at++, 1, 1);
            attach(rtcp_title, 0, row_at, 1, 1);
            attach(rtcp_ready, 1, row_at++, 1, 1);
            attach(sent_title, 0, row_at, 1, 1);
            attach(sent_bps, 1, row_at++, 1, 1);
            attach(recv_title, 0, row_at, 1, 1);
            attach(recv_bps, 1, row_at++, 1, 1);
            attach(codec_title, 0, row_at, 1, 1);
            attach(codec, 1, row_at++, 1, 1);
            attach(target_recv_title, 0, row_at, 1, 1);
            attach(target_receive_bitrate, 1, row_at++, 1, 1);
            attach(target_send_title, 0, row_at, 1, 1);
            attach(target_send_bitrate, 1, row_at++, 1, 1);
            attach(diagnostics_title, 0, row_at, 1, 1);
            attach(diagnostics, 1, row_at++, 1, 1);

            this.column_spacing = 5;
        }

        public void update_content(PeerContentInfo info) {
            if (info.transport_status != null || info.control_status != null) {
                rtp_title.label = info.transport_title ?? "Connection";
                rtcp_title.label = info.control_title ?? "Control";
                rtp_ready.visible = rtcp_ready.visible = true;
                rtp_title.visible = rtcp_title.visible = true;
                rtp_ready.label = info.transport_status ?? "unknown";
                rtcp_ready.label = info.control_status ?? "unknown";
            } else if (!info.rtp_ready) {
                rtp_title.label = "RTP";
                rtcp_title.label = "RTCP";
                rtp_ready.visible = rtcp_ready.visible = true;
                rtp_title.visible = rtcp_title.visible = true;
                rtp_ready.label = info.rtp_ready.to_string();
                rtcp_ready.label = info.rtcp_ready.to_string();
            } else {
                rtp_ready.visible = rtcp_ready.visible = false;
                rtp_title.visible = rtcp_title.visible = false;
            }
            if (info.target_send_bytes != -1) {
                target_receive_bitrate.visible = target_send_bitrate.visible = true;
                target_recv_title.visible = target_send_title.visible = true;
                target_receive_bitrate.label = "<span font_family='monospace'>%u</span> kbps".printf(info.target_receive_bytes);
                target_send_bitrate.label = "<span font_family='monospace'>%u</span> kbps".printf(info.target_send_bytes);
            } else {
                target_receive_bitrate.visible = target_send_bitrate.visible = false;
                target_recv_title.visible = target_send_title.visible = false;
            }

            if (info.codec != null) {
                codec.label = "%s %u".printf((!) info.codec, info.clockrate);
            } else {
                codec.label = "n/a";
            }

            sent_title.visible = recv_title.visible = sent_bps.visible = recv_bps.visible = info.show_bitrate_rows;
            if (info.show_bitrate_rows && prev_info != null && ((!) prev_info).show_bitrate_rows) {
                PeerContentInfo previous = (!) prev_info;
                ulong current_sent = info.bytes_sent ?? 0;
                ulong previous_sent = previous.bytes_sent ?? 0;
                ulong current_received = info.bytes_received ?? 0;
                ulong previous_received = previous.bytes_received ?? 0;
                ulong audio_sent_kbps = current_sent >= previous_sent ? (current_sent - previous_sent) * 8 / 1000 : 0;
                sent_bps.label = "<span font_family='monospace'>%lu</span> kbps".printf(audio_sent_kbps);
                ulong audio_recv_kbps = current_received >= previous_received ? (current_received - previous_received) * 8 / 1000 : 0;
                recv_bps.label = "<span font_family='monospace'>%lu</span> kbps".printf(audio_recv_kbps);
            } else if (info.show_bitrate_rows) {
                sent_bps.label = "<span font_family='monospace'>0</span> kbps";
                recv_bps.label = "<span font_family='monospace'>0</span> kbps";
            }

            diagnostics_title.visible = diagnostics.visible = info.diagnostics != null;
            if (info.diagnostics != null) {
                diagnostics.label = (!) info.diagnostics;
            }

            prev_info = info;
        }
    }
}
