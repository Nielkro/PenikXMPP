/*
 * Copyright (C) 2025 Ralf Peter <dinox@handwerker.jetzt>
 *
 * This program is free software: you can redistribute it and/or modify
 * it under the terms of the GNU General Public License as published by
 * the Free Software Foundation, either version 3 of the License, or
 * (at your option) any later version.
 */

using Gee;
using Gdk;
using Gtk;
using Pango;

namespace Dino.Ui {

    /**
     * Data extracted from a web page's OpenGraph / HTML meta tags.
     */
    public class UrlPreviewData : Object {
        public string url { get; set; }
        public string? site_name { get; set; }
        public string? title { get; set; }
        public string? description { get; set; }
        public string? image_url { get; set; }
        public Gdk.Texture? image_texture { get; set; default = null; }
        public bool failed { get; set; default = false; }
    }

    /**
     * Static cache + fetcher for URL preview metadata.
     *
     * Keeps results in memory so scrolling / re-rendering does not re-fetch.
     */
    public class UrlPreviewCache : Object {
        private static UrlPreviewCache? _instance;
        public static UrlPreviewCache get_instance() {
            if (_instance == null) _instance = new UrlPreviewCache();
            return _instance;
        }

        /* Shared HTTP session — avoids per-request session disposal warnings */
        private Soup.Session session;

        /* url -> preview data (including "failed" entries) */
        private HashMap<string, UrlPreviewData> cache = new HashMap<string, UrlPreviewData>();
        private Gee.LinkedList<string> cache_lru = new Gee.LinkedList<string>();
        private const int MAX_CACHE_SIZE = 50;
        /* urls currently being fetched */
        private HashSet<string> in_flight = new HashSet<string>();

        private UrlPreviewCache() {
            session = new Soup.Session();
            session.user_agent = "Mozilla/5.0 (compatible; DinoX/1.0)";
            session.timeout = 10;
        }

        public signal void preview_ready(string url, UrlPreviewData data);

        public UrlPreviewData? lookup(string url) {
            if (cache.has_key(url)) {
                cache_lru.remove(url);
                cache_lru.add(url);
                return cache[url];
            }
            return null;
        }

        /**
         * Start an async fetch for the given URL if not already cached / in-flight.
         * When done, the preview_ready signal fires.
         */
        public void fetch(string url) {
            if (cache.has_key(url) || in_flight.contains(url)) return;
            in_flight.add(url);
            fetch_async.begin(url, (obj, res) => {
                fetch_async.end(res);
            });
        }

        private void store_result(string url, UrlPreviewData data) {
            cache[url] = data;
            cache_lru.remove(url);
            cache_lru.add(url);
            while (cache_lru.size > MAX_CACHE_SIZE) {
                string oldest = cache_lru.remove_at(0);
                cache.unset(oldest);
            }
        }

        private async void fetch_async(string url) {
            var data = new UrlPreviewData();
            data.url = url;

            try {
                /* Validate URL before passing to libsoup — Soup.Message()
                 * returns null for unparseable URIs, causing a crash.
                 * GLib.Uri.parse is more permissive than libsoup, so also
                 * reject URLs containing characters unsafe for HTTP. */
                if (url.contains("\"") || url.contains("<") || url.contains(">")) {
                    data.failed = true;
                    store_result(url, data);
                    in_flight.remove(url);
                    preview_ready(url, data);
                    return;
                }
                try {
                    Uri.parse(url, UriFlags.NONE);
                } catch (Error e) {
                    data.failed = true;
                    store_result(url, data);
                    in_flight.remove(url);
                    preview_ready(url, data);
                    return;
                }

                Soup.Message? nullable_msg = new Soup.Message("GET", url);
                if (nullable_msg == null) {
                    data.failed = true;
                    store_result(url, data);
                    in_flight.remove(url);
                    preview_ready(url, data);
                    return;
                }
                Soup.Message msg = (!) nullable_msg;

                // Only accept HTML content
                msg.request_headers.append("Accept", "text/html");

                Bytes bytes = yield read_preview_response(msg, 512 * 1024, true);

                if (msg.status_code < 200 || msg.status_code >= 400) {
                    data.failed = true;
                } else {
                    // Check content type - only parse HTML
                    string? content_type = msg.response_headers.get_content_type(null);
                    if (content_type == null || !content_type.has_prefix("text/html")) {
                        data.failed = true;
                    } else {
                        // Detect charset from Content-Type header, convert to UTF-8 if needed
                        string? charset = null;
                        HashTable<string, string>? ct_params = null;
                        msg.response_headers.get_content_type(out ct_params);
                        if (ct_params != null) {
                            charset = ct_params.lookup("charset");
                        }

                        if (bytes == null || bytes.get_size() == 0) {
                            data.failed = true;
                        } else {
                            string html;
                            if (charset != null && charset.ascii_down() != "utf-8" && charset.ascii_down() != "utf8") {
                                try {
                                    html = GLib.convert((string) bytes.get_data(), (ssize_t) bytes.get_size(), "UTF-8", charset);
                                } catch (ConvertError ce) {
                                    debug("URL preview charset convert failed (%s→UTF-8): %s", charset, ce.message);
                                    html = bytes_to_valid_utf8(bytes);
                                }
                            } else {
                                html = bytes_to_valid_utf8(bytes);
                            }

                            if (html != null && html.length > 0) {
                                parse_html_meta(html, data, url);
                            } else {
                                data.failed = true;
                            }
                        }
                    }
                }
            } catch (Error e) {
                debug("URL preview fetch failed for %s: %s", url, e.message);
                data.failed = true;
            }

            // If we got an image URL, try to download it
            if (!data.failed && data.image_url != null) {
                yield fetch_image(data);
            }

            store_result(url, data);
            in_flight.remove(url);
            preview_ready(url, data);
        }

        private async Bytes read_preview_response(Soup.Message message, uint limit, bool html) throws Error {
            InputStream stream = yield session.send_async(message, Priority.DEFAULT, null);
            var buffer = new ByteArray();
            try {
                string? type = message.response_headers.get_content_type(null);
                if (message.status_code >= 200 && message.status_code < 400 &&
                        (!html || (type != null && type.has_prefix("text/html")))) {
                    if (!html && message.response_headers.get_content_length() > limit)
                        throw new IOError.NO_SPACE("URL preview image exceeds the download limit");
                    while (buffer.len < limit) {
                        Bytes chunk = yield stream.read_bytes_async(uint.min(8192, limit - buffer.len), Priority.DEFAULT, null);
                        if (chunk.get_size() == 0) break;
                        buffer.append(chunk.get_data());
                    }
                }
            } catch (Error error) {
                try { yield stream.close_async(Priority.DEFAULT, null); } catch (Error ignored) { }
                throw error;
            }
            // Stop at the preview budget; HTML metadata lives near the start.
            yield stream.close_async(Priority.DEFAULT, null);
            return ByteArray.free_to_bytes((owned) buffer);
        }

        private async void decode_preview_image(UrlPreviewData data, Bytes bytes) {
            Gdk.Pixbuf? preview = null;
            SourceFunc resume = decode_preview_image.callback;
            new Thread<void*>("dinox-url-preview", () => {
                try {
                    var stream = new MemoryInputStream.from_bytes(bytes);
                    int source_width, source_height;
                    var animation = StickerAnimationCompat.new_from_stream(stream, 300, 200,
                        out source_width, out source_height);
                    preview = StickerAnimationCompat.get_static_image(animation).apply_embedded_orientation();
                } catch (Error error) {
                    debug("URL preview image decode failed: %s", error.message);
                }
                Idle.add((owned) resume);
                return null;
            });
            yield;
            if (preview != null) data.image_texture = Util.texture_from_pixbuf(preview);
        }

        private async void fetch_image(UrlPreviewData data) {
            try {
                /* Validate image URL — Soup.Message() returns null for
                 * unparseable URIs, crashing on header access. */
                try {
                    Uri.parse(data.image_url, UriFlags.NONE);
                } catch (Error e) {
                    debug("URL preview: invalid image_url '%s': %s", data.image_url, e.message);
                    return;
                }

                Soup.Message? nullable_msg = new Soup.Message("GET", data.image_url);
                if (nullable_msg == null) return;
                Soup.Message msg = (!) nullable_msg;

                msg.request_headers.append("Accept", "image/avif,image/webp,image/apng,image/svg+xml,image/*,*/*;q=0.8");
                Bytes bytes = yield read_preview_response(msg, 8 * 1024 * 1024, false);

                if (msg.status_code >= 200 && msg.status_code < 400 && bytes != null && bytes.get_size() > 0) {
                    yield decode_preview_image(data, bytes);
                } else {
                    string? content_type = msg.response_headers.get_content_type(null);
                    debug("URL preview image fetch returned status %u for %s (content-type=%s, bytes=%s)",
                          msg.status_code,
                          data.image_url,
                          content_type ?? "unknown",
                          bytes != null ? bytes.get_size().to_string() : "null");
                }
            } catch (Error e) {
                debug("URL preview image fetch failed for %s: %s", data.image_url, e.message);
                // Not fatal - just show preview without image
            }
        }

        /**
         * Parse OpenGraph and standard HTML meta tags from raw HTML.
         */
        private void parse_html_meta(string html, UrlPreviewData data, string page_url) {
            // Limit parsing to <head> section (or first 32KB)
            string head_html = Util.sanitize_utf8(html.substring(0, int.min(html.length, 32768)));
            int head_end = head_html.index_of("</head>");
            if (head_end < 0) head_end = head_html.index_of("</HEAD>");
            if (head_end > 0) {
                head_html = head_html.substring(0, head_end);
            }

            // og:title
            data.title = extract_meta_content(head_html, "og:title");
            // og:description
            data.description = extract_meta_content(head_html, "og:description");
            // og:site_name
            data.site_name = extract_meta_content(head_html, "og:site_name");
            // og:image
            data.image_url = extract_meta_content(head_html, "og:image");

            // Fallback: <title>
            if (data.title == null || data.title == "") {
                data.title = extract_tag_content(head_html, "title");
            }
            // Fallback: <meta name="description">
            if (data.description == null || data.description == "") {
                data.description = extract_meta_name_content(head_html, "description");
            }

            // Make relative image URL absolute
            if (data.image_url != null && data.image_url != "") {
                try {
                    data.image_url = GLib.Uri.resolve_relative(page_url,
                        decode_html_entities(data.image_url), GLib.UriFlags.NONE);
                } catch (Error error) {
                    data.image_url = null;
                }
            }

            // If no title at all, mark as failed
            if (data.title == null || data.title.strip() == "") {
                data.failed = true;
            }

            // Truncate very long text
            if (data.title != null && data.title.char_count() > 200) {
                long byte_off = data.title.index_of_nth_char(197);
                data.title = data.title.substring(0, byte_off) + "...";
            }
            if (data.description != null && data.description.char_count() > 300) {
                long byte_off = data.description.index_of_nth_char(297);
                data.description = data.description.substring(0, byte_off) + "...";
            }

            // Decode HTML entities
            if (data.title != null) data.title = decode_html_entities(data.title);
            if (data.description != null) data.description = decode_html_entities(data.description);
            if (data.site_name != null) data.site_name = decode_html_entities(data.site_name);
        }

        private string bytes_to_valid_utf8(Bytes bytes) {
            return ((string) bytes.get_data()).make_valid((ssize_t) bytes.get_size());
        }

        /**
         * Extract content from <meta property="name" content="...">
         */
        private string? extract_meta_content(string html, string property) {
            // Match both property= and name= variants, both single and double quotes
            // <meta property="og:title" content="Hello World">
            // <meta content="Hello World" property="og:title">
            // HTML identifiers use ASCII case rules. Unicode lowercasing can
            // change byte lengths (e.g. U+0130), invalidating offsets used to
            // slice the original UTF-8 document, regardless of UI language.
            string lower = html.ascii_down();
            string prop_lower = property.ascii_down();

            // Find the meta tag containing our property
            int pos = 0;
            while (true) {
                int meta_start = lower.index_of("<meta", pos);
                if (meta_start < 0) break;
                int meta_end = lower.index_of(">", meta_start);
                if (meta_end < 0) break;

                string tag = html.substring(meta_start, meta_end - meta_start + 1);
                string tag_lower = tag.ascii_down();

                // Check if this meta tag has our property
                bool has_prop = false;
                if (tag_lower.contains("property=\"" + prop_lower + "\"") ||
                    tag_lower.contains("property='" + prop_lower + "'")) {
                    has_prop = true;
                }

                if (has_prop) {
                    return extract_attribute(tag, "content");
                }

                pos = meta_end + 1;
            }
            return null;
        }

        /**
         * Extract content from <meta name="description" content="...">
         */
        private string? extract_meta_name_content(string html, string name) {
            string lower = html.ascii_down();
            string name_lower = name.ascii_down();

            int pos = 0;
            while (true) {
                int meta_start = lower.index_of("<meta", pos);
                if (meta_start < 0) break;
                int meta_end = lower.index_of(">", meta_start);
                if (meta_end < 0) break;

                string tag = html.substring(meta_start, meta_end - meta_start + 1);
                string tag_lower = tag.ascii_down();

                if (tag_lower.contains("name=\"" + name_lower + "\"") ||
                    tag_lower.contains("name='" + name_lower + "'")) {
                    return extract_attribute(tag, "content");
                }

                pos = meta_end + 1;
            }
            return null;
        }

        /**
         * Extract an attribute value from an HTML tag string.
         */
        private string? extract_attribute(string tag, string attr) {
            string lower = tag.ascii_down();
            string search_dq = attr.ascii_down() + "=\"";
            string search_sq = attr.ascii_down() + "='";

            int idx = lower.index_of(search_dq);
            if (idx >= 0) {
                int start = idx + search_dq.length;
                int end = tag.index_of("\"", start);
                if (end > start) return tag.substring(start, end - start);
            }

            idx = lower.index_of(search_sq);
            if (idx >= 0) {
                int start = idx + search_sq.length;
                int end = tag.index_of("'", start);
                if (end > start) return tag.substring(start, end - start);
            }
            return null;
        }

        /**
         * Extract text content between <tag> and </tag>.
         */
        private string? extract_tag_content(string html, string tag_name) {
            string lower = html.ascii_down();
            int start = lower.index_of("<" + tag_name.ascii_down());
            if (start < 0) return null;
            int content_start = lower.index_of(">", start);
            if (content_start < 0) return null;
            content_start++;
            int end = lower.index_of("</" + tag_name.ascii_down() + ">", content_start);
            if (end < 0) return null;
            if (end <= content_start) return null;
            return html.substring(content_start, end - content_start).strip();
        }

        /**
         * Decode common HTML entities.
         */
        private string decode_html_entities(string text) {
            string result = text;
            result = result.replace("&amp;", "&");
            result = result.replace("&lt;", "<");
            result = result.replace("&gt;", ">");
            result = result.replace("&quot;", "\"");
            result = result.replace("&#39;", "'");
            result = result.replace("&apos;", "'");
            result = result.replace("&#x27;", "'");
            result = result.replace("&ndash;", "\u2013");
            result = result.replace("&mdash;", "\u2014");
            result = result.replace("&nbsp;", " ");
            result = result.replace("&#8211;", "\u2013");
            result = result.replace("&#8212;", "\u2014");
            return Dino.Ui.Util.sanitize_utf8(decode_decimal_entities(result));
        }

        private string decode_decimal_entities(string text) {
            var builder = new StringBuilder();
            int cursor = 0;

            while (cursor < text.length) {
                int entity_start = text.index_of("&#", cursor);
                if (entity_start < 0) {
                    builder.append(text.substring(cursor));
                    break;
                }

                builder.append(text.substring(cursor, entity_start - cursor));

                int digit_start = entity_start + 2;
                int entity_end = text.index_of(";", digit_start);
                if (entity_end < 0) {
                    builder.append(text.substring(entity_start));
                    break;
                }

                string num_str = text.substring(digit_start, entity_end - digit_start);
                bool all_digits = num_str.length > 0;
                foreach (char c in num_str.to_utf8()) {
                    if (!c.isdigit()) {
                        all_digits = false;
                        break;
                    }
                }

                if (all_digits) {
                    uint64 code = 0;
                    foreach (char c in num_str.to_utf8()) {
                        code = code * 10 + (uint64) (c - '0');
                        if (code >= 0x10FFFF) break;
                    }
                    unichar uc = (unichar) code;
                    if (code > 0 && code < 0x10FFFF && uc.validate()) {
                        builder.append_unichar(uc);
                    } else {
                        builder.append(text.substring(entity_start, entity_end - entity_start + 1));
                    }
                } else {
                    builder.append(text.substring(entity_start, entity_end - entity_start + 1));
                }

                cursor = entity_end + 1;
            }

            return builder.str;
        }
    }

    /**
     * Widget that displays a URL link preview card.
     *
     * Layout:
     * +-------------------------------------------------------+
     * | [Image]  Site Name                                     |
     * |          Title (bold)                                  |
     * |          Description text...                           |
     * +-------------------------------------------------------+
     */
    public class UrlPreviewWidget : Box {

        private const int MAX_CARD_WIDTH = 540;
        private const int MAX_THUMBNAIL_WIDTH = 160;
        private const int MAX_THUMBNAIL_HEIGHT = 100;

        private string url;
        private ulong ready_handler_id = 0;

        private Box card_box;
        private FixedRatioPicture? image_widget = null;
        private Label? site_label = null;
        private Label? title_label = null;
        private Label? desc_label = null;

        construct {
            this.halign = Align.START;
            this.hexpand = false;
            this.margin_top = 4;
        }

        // Render already available metadata without coupling measurement to a
        // network request. The asynchronous path uses the same card builder.
        public UrlPreviewWidget.from_data(UrlPreviewData data) {
            Object(orientation: Orientation.VERTICAL, spacing: 0);
            this.url = data.url;
            if (!data.failed) build_card(data);
        }

        public UrlPreviewWidget(string url) {
            Object(orientation: Orientation.VERTICAL, spacing: 0);
            this.url = url;

            // Check cache first
            var cache = UrlPreviewCache.get_instance();
            var data = cache.lookup(url);

            if (data != null) {
                if (!data.failed) {
                    build_card(data);
                }
                // If failed, widget stays empty (invisible)
                return;
            }

            // Not cached yet - start fetch and listen for result
            connect_preview_ready(this, cache);
            cache.fetch(url);
        }

        private static void connect_preview_ready(UrlPreviewWidget owner, UrlPreviewCache cache) {
            var owner_ref = WeakRef(owner);
            owner.ready_handler_id = cache.preview_ready.connect((ready_url, ready_data) => {
                var widget = owner_ref.get() as UrlPreviewWidget;
                if (widget == null || ready_url != widget.url) return;
                if (widget.ready_handler_id != 0) {
                    cache.disconnect(widget.ready_handler_id);
                    widget.ready_handler_id = 0;
                }
                if (!ready_data.failed) widget.build_card(ready_data);
            });
        }

        private void build_card(UrlPreviewData data) {
            if (card_box != null) return;
            card_box = new Box(Orientation.HORIZONTAL, 8);
            card_box.add_css_class("dino-link-preview");
            card_box.halign = Align.START;
            card_box.hexpand = false;
            // Don't use width_request (sets MINIMUM width, not max).
            // Instead, constrain via max_width_chars on labels.

            // Image on the left (if available)
            if (data.image_texture != null) {
                double scale = double.min(1.0, double.min(
                    (double) MAX_THUMBNAIL_WIDTH / data.image_texture.get_width(),
                    (double) MAX_THUMBNAIL_HEIGHT / data.image_texture.get_height()));
                int thumbnail_width = int.max(1, (int) (data.image_texture.get_width() * scale));
                int thumbnail_height = int.max(1, (int) (data.image_texture.get_height() * scale));
                image_widget = new FixedRatioPicture() {
                    paintable = data.image_texture,
                    min_width = int.min(48, thumbnail_width), min_height = 1,
                    target_width = thumbnail_width, target_height = thumbnail_height,
                    max_width = thumbnail_width, max_height = thumbnail_height,
                    valign = Align.CENTER
                };
#if GTK_4_8 && (VALA_0_56_GREATER_5 || VALA_0_58)
                image_widget.content_fit = ContentFit.CONTAIN;
#endif
                image_widget.add_css_class("dino-link-preview-image");
                image_widget.overflow = Overflow.HIDDEN;
                // Preserve the complete OpenGraph image, including text near
                // its edges, instead of cropping it into a fixed square.
                card_box.append(image_widget);
            }

            // Text column on the right
            var text_box = new Box(Orientation.VERTICAL, 2);
            text_box.hexpand = true;
            text_box.valign = Align.CENTER;

            // Site name
            if (data.site_name != null && data.site_name.strip() != "") {
                string site_name = Dino.Ui.Util.sanitize_utf8(data.site_name.strip());
                site_label = new Label(site_name);
                site_label.add_css_class("dim-label");
                site_label.halign = Align.FILL;
                site_label.xalign = 0;
                site_label.ellipsize = Pango.EllipsizeMode.END;
                site_label.max_width_chars = 50;
                var attrs = new Pango.AttrList();
                attrs.insert(Pango.attr_scale_new(0.85));
                site_label.set_attributes(attrs);
                text_box.append(site_label);
            } else {
                // Use domain as site name
                try {
                    var uri = GLib.Uri.parse(url, GLib.UriFlags.NONE);
                    string? host = uri.get_host();
                    if (host != null && host != "") {
                        site_label = new Label(Dino.Ui.Util.sanitize_utf8(host));
                        site_label.add_css_class("dim-label");
                        site_label.halign = Align.FILL;
                        site_label.xalign = 0;
                        site_label.ellipsize = Pango.EllipsizeMode.END;
                        var attrs = new Pango.AttrList();
                        attrs.insert(Pango.attr_scale_new(0.85));
                        site_label.set_attributes(attrs);
                        text_box.append(site_label);
                    }
                } catch (Error e) {
                    // ignore
                }
            }

            // Title
            if (data.title != null && data.title.strip() != "") {
                string title = Dino.Ui.Util.sanitize_utf8(data.title.strip());
                title_label = new Label(title);
                title_label.halign = Align.FILL;
                title_label.xalign = 0;
                title_label.wrap = true;
                title_label.wrap_mode = Pango.WrapMode.WORD_CHAR;
                title_label.max_width_chars = 50;
                title_label.lines = 2;
                title_label.ellipsize = Pango.EllipsizeMode.END;
                var attrs = new Pango.AttrList();
                attrs.insert(Pango.attr_weight_new(Pango.Weight.BOLD));
                title_label.set_attributes(attrs);
                text_box.append(title_label);
            }

            // Description
            if (data.description != null && data.description.strip() != "") {
                string description = Dino.Ui.Util.sanitize_utf8(data.description.strip());
                desc_label = new Label(description);
                desc_label.halign = Align.FILL;
                desc_label.xalign = 0;
                desc_label.wrap = true;
                desc_label.wrap_mode = Pango.WrapMode.WORD_CHAR;
                desc_label.max_width_chars = 50;
                desc_label.lines = 3;
                desc_label.ellipsize = Pango.EllipsizeMode.END;
                desc_label.add_css_class("dim-label");
                text_box.append(desc_label);
            }

            card_box.append(text_box);
            var card_bounds = new SizingBin() { max_width = MAX_CARD_WIDTH };
            card_box.set_parent(card_bounds);
            this.append(card_bounds);

            // Make clickable -> open in browser
            var gesture = new GestureClick();
            gesture.pressed.connect(() => {
                var launcher = new Gtk.UriLauncher(this.url);
                launcher.launch.begin(null, null, (obj, res) => {
                    try {
                        launcher.launch.end(res);
                    } catch (Error e) {
                        warning("Failed to open URL: %s", e.message);
                    }
                });
            });
            card_box.add_controller(gesture);
            card_box.set_cursor(new Gdk.Cursor.from_name("pointer", null));
        }

        public override void dispose() {
            if (ready_handler_id != 0) {
                UrlPreviewCache.get_instance().disconnect(ready_handler_id);
                ready_handler_id = 0;
            }
            base.dispose();
        }
    }

    /**
     * Extract the first http/https URL from a message body, if any.
     * Returns null if none found or if it's a special URL (aesgcm, geo, etc.)
     */
    public string? extract_preview_url(string? body) {
        if (body == null || body.length == 0) return null;

        try {
            Regex url_regex = Dino.Ui.Util.get_url_regex();
            MatchInfo match;
            url_regex.match(body, 0, out match);
            while (match.matches()) {
                string url = match.fetch(0);
                // Strip trailing characters that are never valid URL endings
                // (HTML artifacts, quotes, angle brackets, etc.)
                while (url.length > 0) {
                    unichar last = url.get_char(url.char_count() > 1
                        ? url.index_of_nth_char(url.char_count() - 1) : 0);
                    if (last == '"' || last == '\'' || last == '>' || last == '<'
                        || last == ';' || last == ',' || last == '.') {
                        url = url.substring(0, url.index_of_nth_char(url.char_count() - 1));
                    } else {
                        break;
                    }
                }
                // Only preview http:// and https:// URLs
                if (url.has_prefix("http://") || url.has_prefix("https://")) {
                    // Skip aesgcm (OMEMO file transfer)
                    if (url.contains("aesgcm")) {
                        match.next();
                        continue;
                    }
                    return url;
                }
                match.next();
            }
        } catch (Error e) {
            debug("URL extraction error: %s", e.message);
        }
        return null;
    }
}
