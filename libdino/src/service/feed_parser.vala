using Gee;

namespace Dino.Feeds {

public const string ATOM = "http://www.w3.org/2005/Atom";
public const int MAX_BYTES = 2 * 1024 * 1024;

public class Entry : Object {
    public string id { get; set; default = ""; }
    public string item_id { get; set; default = ""; }
    public string title { get; set; default = ""; }
    public string text { get; set; default = ""; }
    public string link { get; set; default = ""; }
    public string published { get; set; default = ""; }
    public string author { get; set; default = ""; }
    public string reply_uri { get; set; default = ""; }

    public string message() {
        string body = title;
        if (text != "" && text != title) body += "\n\n" + shorten(text, 1500);
        if (link != "") body += "\n\n" + link;
        return body.strip();
    }

    public string key() {
        return Checksum.compute_for_string(ChecksumType.SHA256,
            id != "" ? id : (link != "" ? link : title + "\n" + published));
    }
}

public string shorten(string text, int characters) {
    if (!text.validate()) return "";
    int codepoints = text.char_count();
    if (codepoints <= characters) return text;
    // A displayed character can contain several code points (combining
    // accents, skin tones, ZWJ emoji, flags). Use the same Unicode grapheme
    // boundaries as GTK's text engine. PCRE2 10.42's \X incorrectly combines
    // adjacent pictographic emoji even when no ZWJ connects them.
    int limit = int.max(0, characters);
    var attrs = new Pango.LogAttr[codepoints + 1];
    Pango.get_log_attrs(text, text.length, -1, Pango.Language.from_string("und"), attrs);
    int count = 0;
    for (int i = 0; i < codepoints; i++) {
        if (attrs[i].is_cursor_position != 0 && count++ == limit) {
            return text.substring(0, text.index_of_nth_char(i)) + "…";
        }
    }
    return text;
}

// A deliberately non-rendering XML tree. GMarkup never resolves external
// entities. Namespace URIs, not prefixes, identify feed fields.
internal class Node : Object {
    public string name;
    public string ns;
    public string base_uri;
    public HashMap<string, string> attrs = new HashMap<string, string>();
    public HashMap<string, string> namespaces = new HashMap<string, string>();
    public ArrayList<Node> children = new ArrayList<Node>();
    public StringBuilder text = new StringBuilder();
    public Node(string name) { this.name = name; }
    public Node? child(string name, string ns = "") {
        foreach (Node node in children) if (node.name == name && node.ns == ns) return node;
        return null;
    }
    public string value(string name, string ns = "") {
        Node? node = child(name, ns);
        return node != null ? ((!) node).text.str.strip() : "";
    }
}

public class Parser : Object {
    private ArrayList<Node> stack = new ArrayList<Node>();
    private Node? root;
    private int nodes;
    private string base_uri;

    private Parser(string base_uri) { this.base_uri = base_uri; }

    public static string decode(uint8[] bytes, string? charset = null) throws Error {
        if (bytes.length > MAX_BYTES) throw new IOError.INVALID_DATA(GLib.dgettext("dino", "Feed exceeds 2 MiB."));
        string encoding = charset ?? "UTF-8";
        // Check four-byte BOMs before UTF-16: UTF-32LE starts with FF FE too.
        if (bytes.length >= 4 && bytes[0] == 0xff && bytes[1] == 0xfe && bytes[2] == 0 && bytes[3] == 0) encoding = "UTF-32LE";
        else if (bytes.length >= 4 && bytes[0] == 0 && bytes[1] == 0 && bytes[2] == 0xfe && bytes[3] == 0xff) encoding = "UTF-32BE";
        else if (bytes.length >= 2 && ((bytes[0] == 0xff && bytes[1] == 0xfe) || (bytes[0] == 0xfe && bytes[1] == 0xff))) encoding = "UTF-16";
        else if (bytes.length >= 3 && bytes[0] == 0xef && bytes[1] == 0xbb && bytes[2] == 0xbf) encoding = "UTF-8";
        // XML's initial '<' / '<?' byte patterns identify endian-specific
        // Unicode input even without a BOM, before reading its declaration.
        else if (charset == null && bytes.length >= 4 && bytes[0] == 0 && bytes[1] == 0 && bytes[2] == 0 && bytes[3] == '<') encoding = "UTF-32BE";
        else if (charset == null && bytes.length >= 4 && bytes[0] == '<' && bytes[1] == 0 && bytes[2] == 0 && bytes[3] == 0) encoding = "UTF-32LE";
        else if (charset == null && bytes.length >= 4 && bytes[0] == 0 && bytes[1] == '<' && bytes[2] == 0 && bytes[3] == '?') encoding = "UTF-16BE";
        else if (charset == null && bytes.length >= 4 && bytes[0] == '<' && bytes[1] == 0 && bytes[2] == '?' && bytes[3] == 0) encoding = "UTF-16LE";
        else if (charset == null) {
            var declaration = new StringBuilder();
            for (int i = 0; i < int.min(bytes.length, 200) && bytes[i] < 128 && bytes[i] != 0; i++) declaration.append_c((char) bytes[i]);
            MatchInfo match;
            if (new Regex("^<\\?xml[^>]*encoding\\s*=\\s*['\"]([^'\"]+)['\"]", RegexCompileFlags.CASELESS).match(declaration.str, 0, out match)) encoding = match.fetch(1);
        }
        size_t written;
        string xml = GLib.convert((string) bytes, bytes.length, "UTF-8", encoding, null, out written);
        if (written > MAX_BYTES || !xml.validate() || written != xml.length) throw new IOError.INVALID_DATA(GLib.dgettext("dino", "The feed is too large or contains unsupported XML."));
        return xml.has_prefix("\xef\xbb\xbf") ? xml.substring(3) : xml;
    }

    public static string http_url(string value, string base_uri = "") throws Error {
        string absolute = base_uri == "" ? value.strip() : Uri.resolve_relative(base_uri, value.strip(), UriFlags.NONE);
        Uri uri = Uri.parse(absolute, UriFlags.NONE);
        if (absolute.length > 4096 || (uri.get_scheme() != "https" && uri.get_scheme() != "http") ||
                uri.get_host() == null || uri.get_host() == "" || uri.get_userinfo() != null)
            throw new IOError.INVALID_ARGUMENT(GLib.dgettext("dino", "A feed URL must use HTTP or HTTPS without credentials."));
        return uri.to_string();
    }

    public static ArrayList<Entry> parse(string xml, string base_uri = "") throws Error {
        if (xml.length > MAX_BYTES || !xml.validate() || "<!DOCTYPE" in xml || "<!ENTITY" in xml)
            throw new IOError.INVALID_DATA(GLib.dgettext("dino", "The feed is too large or contains unsupported XML."));
        var parser = new Parser(base_uri);
        MarkupCallbacks callbacks = { parser.start, parser.end, parser.characters, null, null };
        var context = markup_context_new(ref callbacks, MarkupParseFlags.TREAT_CDATA_AS_TEXT, parser, null);
        context.parse(xml, xml.length);
        context.end_parse();
        if (parser.root == null) throw new IOError.INVALID_DATA(GLib.dgettext("dino", "Empty feed."));
        Node root = (!) parser.root;
        var entries = new ArrayList<Entry>();
        if (root.name == "entry" && root.ns == ATOM) {
            entries.add(parse_entry(root, true));
        } else if (root.name == "feed" && root.ns == ATOM) {
            foreach (Node node in root.children) {
                if (node.name == "entry" && node.ns == ATOM && entries.size < 200) entries.add(parse_entry(node, true));
            }
        } else if (root.name == "rss" && root.ns == "") {
            Node? channel = root.child("channel");
            if (channel == null) throw new IOError.INVALID_DATA(GLib.dgettext("dino", "RSS channel missing."));
            foreach (Node node in ((!) channel).children) {
                if (node.name == "item" && node.ns == "" && entries.size < 200) entries.add(parse_entry(node, false));
            }
        } else if (root.name == "RDF" && root.ns == "http://www.w3.org/1999/02/22-rdf-syntax-ns#") {
            foreach (Node node in root.children) {
                if (node.name == "item" && node.ns == "http://purl.org/rss/1.0/" && entries.size < 200) entries.add(parse_entry(node, false));
            }
        } else throw new IOError.INVALID_DATA(GLib.dgettext("dino", "Expected RSS 1.0, RSS 2.0 or Atom."));
        var unique = new ArrayList<Entry>();
        var keys = new HashSet<string>();
        foreach (Entry entry in entries) if ((entry.title != "" || entry.text != "" || entry.link != "") && keys.add(entry.key())) unique.add(entry);
        return unique;
    }

    private void start(MarkupParseContext context, string name,
            [CCode (type = "const gchar**")] string[] names,
            [CCode (type = "const gchar**")] string[] values) throws MarkupError {
        if (stack.size >= 48 || ++nodes > 30000) throw new MarkupError.INVALID_CONTENT(GLib.dgettext("dino", "Feed XML is too complex."));
        var node = new Node(name);
        node.base_uri = stack.size > 0 ? stack.last().base_uri : base_uri;
        if (stack.size > 0) node.namespaces.set_all(stack.last().namespaces);
        for (int i = 0; i < names.length; i++) {
            if (names[i] == "xmlns") node.namespaces[""] = values[i];
            else if (names[i].has_prefix("xmlns:")) node.namespaces[names[i].substring(6)] = values[i];
            else node.attrs[names[i]] = values[i];
        }
        if (node.attrs.has_key("xml:base")) {
            try { node.base_uri = http_url(node.attrs["xml:base"], node.base_uri); } catch (Error e) { }
        }
        int colon = name.index_of(":");
        node.ns = node.namespaces[colon < 0 ? "" : name.substring(0, colon)] ?? "";
        node.name = colon < 0 ? name : name.substring(colon + 1);
        if (stack.size > 0) stack.last().children.add(node);
        else {
            if (root != null) throw new MarkupError.INVALID_CONTENT(GLib.dgettext("dino", "Multiple XML roots."));
            root = node;
        }
        stack.add(node);
    }

    private void end(MarkupParseContext context, string name) throws MarkupError {
        Node node = stack.remove_at(stack.size - 1);
        if (stack.size > 0) {
            // Keep XHTML text readable without interpreting any of its markup.
            if (node.name == "p" || node.name == "div" || node.name == "br" || node.name == "li" || node.name == "tr")
                stack.last().text.append("\n");
            if (node.name != "script" && node.name != "style") stack.last().text.append(node.text.str);
            if (node.name == "p" || node.name == "div" || node.name == "li" || node.name == "tr") stack.last().text.append("\n");
        }
    }

    private void characters(MarkupParseContext context, string text, size_t length) throws MarkupError {
        if (stack.size > 0) stack.last().text.append_len(text, (ssize_t) length);
    }

    private static string readable(Node? node, bool html_default = false) {
        if (node == null) return "";
        string type = ((!) node).attrs["type"] ?? (html_default ? "html" : "text");
        return shorten(type == "html" ? html_text(((!) node).text.str) : ((!) node).text.str.strip(), 12000);
    }

    private static Entry parse_entry(Node node, bool atom) {
        var entry = new Entry();
        entry.title = shorten(readable(node.child("title", node.ns), !atom), 300);
        entry.id = node.value(atom ? "id" : "guid", node.ns);
        entry.published = node.value(atom ? "published" : "pubDate", node.ns);
        if (entry.published == "") entry.published = node.value(atom ? "updated" : "date", atom ? ATOM : "http://purl.org/dc/elements/1.1/");
        if (atom) {
            // Prefer the required plain text alternative over XHTML.
            Node? content = node.child("content", ATOM);
            foreach (Node candidate in node.children) {
                if (candidate.name == "content" && candidate.ns == ATOM && (candidate.attrs["type"] ?? "text") == "text") content = candidate;
                if (candidate.name == "link" && candidate.ns == ATOM && (candidate.attrs["rel"] ?? "alternate") == "alternate") {
                    try { entry.link = http_url(candidate.attrs["href"] ?? "", candidate.base_uri); } catch (Error e) { }
                }
            }
            entry.text = readable(content ?? node.child("summary", ATOM));
            Node? author = node.child("author", ATOM);
            if (author != null) entry.author = ((!) author).value("name", ATOM);
            Node? reply = node.child("in-reply-to", "http://purl.org/syndication/thread/1.0");
            if (reply != null) entry.reply_uri = ((!) reply).attrs["href"] ?? "";
        } else {
            entry.text = readable(node.child("encoded", "http://purl.org/rss/1.0/modules/content/"), true);
            if (entry.text == "") entry.text = readable(node.child("description", node.ns), true);
            entry.author = node.value("creator", "http://purl.org/dc/elements/1.1/");
            if (entry.author == "") entry.author = node.value("author", node.ns);
            string link = node.value("link", node.ns);
            if (link != "") { try { entry.link = http_url(link, node.base_uri); } catch (Error e) { } }
        }
        if (entry.title == "") entry.title = shorten(entry.text, 120);
        return entry;
    }

    public static string html_text(string html) {
        // No browser, external resource fetching, or executable markup. Convert
        // paragraph/table boundaries before stripping tags; decode only text.
        try {
            string result = new Regex("(?is)<(script|style|iframe)\\b[^>]*>.*?</\\1\\s*>").replace(html, -1, 0, "");
            result = new Regex("(?is)<!--.*?-->").replace(result, -1, 0, "");
            result = new Regex("[\\t \\r\\n]+").replace(result, -1, 0, " ");
            result = new Regex("(?i)</?(p|div|br|li|h[1-6]|tr|blockquote)\\b[^>]*>").replace(result, -1, 0, "\n");
            result = new Regex("(?i)</t[dh]\\s*>").replace(result, -1, 0, " | ");
            result = new Regex("<[^>]*>").replace(result, -1, 0, "");
            result = new Regex("[\\t \\r]+").replace(result, -1, 0, " ");
            result = new Regex("\\n[ \\n]+").replace(result, -1, 0, "\n\n");
            var out_text = new StringBuilder();
            for (int i = 0; i < result.length; i++) {
                if (result[i] == '&') {
                    int end = -1;
                    for (int j = i + 1; j < int.min(i + 16, result.length); j++) if (result[j] == ';') { end = j; break; }
                    if (end > i && end - i < 16) {
                        string entity = result.substring(i + 1, end - i - 1);
                        unichar c = 0;
                        switch (entity) {
                            case "amp": c = '&'; break; case "lt": c = '<'; break;
                            case "gt": c = '>'; break; case "quot": c = '"'; break;
                            case "apos": c = '\''; break; case "nbsp": c = ' '; break;
                            case "ndash": c = '–'; break; case "mdash": c = '—'; break;
                            case "hellip": c = '…'; break;
                            default:
                                uint64 code = 0;
                                string number = entity.has_prefix("#x") || entity.has_prefix("#X") ? "0x" + entity.substring(2) : (entity.has_prefix("#") ? entity.substring(1) : "");
                                if (number != "" && uint64.try_parse(number, out code) && code <= 0x10ffff && ((unichar) code).validate()) c = (unichar) code;
                                break;
                        }
                        if (c != 0) { out_text.append_unichar(c); i = end; continue; }
                    }
                }
                out_text.append_c(result[i]);
            }
            return out_text.str.strip();
        } catch (RegexError e) { return ""; }
    }
}
}
