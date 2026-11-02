using Gtk;

using Dino.Entities;
using Xmpp.Util;

namespace Dino.Plugins.OpenPgp {

public static string markup_id(string s, bool is_fingerprint) {
    string markup = is_fingerprint ? "" : "0x";
    for (int i = 0; i < s.length; i += 4) {
        string four_chars = s.substring(i, 4).down();

        if (i == 4 * 5) markup += "\n";
        markup += four_chars;
        if (is_fingerprint) markup += " ";
    }
    return "<span font_family='monospace' font='9'>" + markup + "</span>";
}

internal static bool openpgp_key_ids_match(string expected_key, string signer_key) {
    string expected = normalize_openpgp_key_id(expected_key);
    string signer = normalize_openpgp_key_id(signer_key);
    if (expected.length == 0 || signer.length == 0) return false;
    return expected == signer || expected.has_suffix(signer) || signer.has_suffix(expected);
}

private static string normalize_openpgp_key_id(string value) {
    return value.up().replace(" ", "").replace("\t", "").replace("\r", "").replace("\n", "");
}

}
