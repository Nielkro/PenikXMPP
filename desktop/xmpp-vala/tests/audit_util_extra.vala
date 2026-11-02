using Gee;

namespace Xmpp.Test {

/**
 * Security Audit: Utility functions
 *
 * Tests random_uuid() format and get_data_for_uri() data URI parsing.
 *
 * Bug #22: random_uuid() bitmask may not correctly set version nibble.
 *   The expression `(Random.next_int() | 0x4000u) & ~0xb000u` should
 *   set bit 14 (version nibble = 4) and clear other version bits.
 *   But ~0xb000u = 0xFFFF4FFF, so the mask clears bits 15,13,12 but
 *   keeps bit 14. Combined with `| 0x4000u`, the version nibble should
 *   always have bit 14 set. However: if Random produces value with
 *   bit 15 set: 0x4000 | val gives bit 14+15 set, then & 0x4FFF
 *   clears bit 15. Result: nibble = 0x4 or 0x5 (never 0x6, 0x7).
 *   Actually: 0x4FFF allows bits 0-11 and bit 14. The random val
 *   ORed with 0x4000 always has bit 14. After AND with 0x4FFF, bits
 *   15,13,12 are cleared. So the high nibble is 0b01XX where XX
 *   depends on bits 13,12... wait, 0x4FFF = 0100 1111 1111 1111.
 *   Bits 15=0, 14=1, 13=0, 12=0 → high nibble always 0x4. OK, the
 *   bitmask actually works for the version nibble. But the variant
 *   nibble (b4): `(Random.next_int() | 0x8000u) & ~0x4000u` →
 *   0x8000 | val, then & ~0x4000 = 0xBFFF. High nibble: bit 15=1,
 *   bit 14=0, bits 13,12 from random. So variant nibble is 0b10XX
 *   = 0x8, 0x9, 0xA, or 0xB — this is correct RFC 4122 variant.
 *
 * Note: We cannot test randomness quality, but we CAN verify format.
 */
class UtilAudit : Gee.TestCase {

    public UtilAudit() {
        base("UtilAudit");

        // --- random_uuid format ---
        add_test("RFC4122_uuid_format_8_4_4_4_12", test_uuid_format);
        add_test("RFC4122_uuid_version_nibble_is_4", test_uuid_version);
        add_test("RFC4122_uuid_variant_bits", test_uuid_variant);
        add_test("RFC4122_uuid_uniqueness", test_uuid_unique);
        add_test("RFC4122_uuid_lowercase_hex", test_uuid_lowercase);

        // --- get_data_for_uri ---
        add_test("DataURI_png_base64_parses", test_data_uri_png);
        add_test("DataURI_unknown_scheme_returns_null", test_data_uri_unknown);
        add_test("DataURI_jpeg_base64_parses", test_data_uri_jpeg);
        add_test("DataURI_empty_data_returns_bytes", test_data_uri_empty_png);
        add_test("DataURI_thumbhash_reported_examples", test_data_uri_thumbhash);
        add_test("DataURI_percent_escaping_and_binary_data", test_data_uri_escaping);
        add_test("DataURI_malformed_returns_null", test_data_uri_malformed);
        add_test("XEP0264_thumbnail_preserves_media_type", test_thumbnail_media_type);
        add_test("XEP0264_thumbnail_media_parameters_and_invalid_types", test_thumbnail_media_parameters);
        add_test("DataURI_cid_lookup_remains_supported", test_data_uri_cid);
    }

    // ===================== random_uuid =====================

    private void test_uuid_format() {
        string uuid = Xmpp.random_uuid();
        // Format: 8-4-4-4-12 hex chars = 36 total with hyphens
        fail_if_not_eq_int(uuid.length, 36, @"UUID length should be 36: '$uuid'");
        fail_if_not(uuid[8] == '-', @"UUID[8] should be '-': '$uuid'");
        fail_if_not(uuid[13] == '-', @"UUID[13] should be '-': '$uuid'");
        fail_if_not(uuid[18] == '-', @"UUID[18] should be '-': '$uuid'");
        fail_if_not(uuid[23] == '-', @"UUID[23] should be '-': '$uuid'");
    }

    private void test_uuid_version() {
        // UUID v4: the 13th character (index 14) should be '4'
        for (int i = 0; i < 20; i++) {
            string uuid = Xmpp.random_uuid();
            char version = uuid[14];
            fail_if_not(version == '4',
                @"UUID version nibble should be '4', got '$version' in '$uuid'");
        }
    }

    private void test_uuid_variant() {
        // RFC 4122: the variant nibble (char at index 19) should be 8, 9, a, or b
        for (int i = 0; i < 20; i++) {
            string uuid = Xmpp.random_uuid();
            char variant = uuid[19];
            bool valid = variant == '8' || variant == '9' || variant == 'a' || variant == 'b';
            fail_if_not(valid,
                @"UUID variant nibble should be 8/9/a/b, got '$variant' in '$uuid'");
        }
    }

    private void test_uuid_unique() {
        // Generate 100 UUIDs and check none are equal
        var seen = new HashSet<string>();
        for (int i = 0; i < 100; i++) {
            string uuid = Xmpp.random_uuid();
            fail_if(seen.contains(uuid), @"UUID collision detected: $uuid");
            seen.add(uuid);
        }
    }

    private void test_uuid_lowercase() {
        string uuid = Xmpp.random_uuid();
        fail_if_not_eq_str(uuid, uuid.down(),
            "UUID should use lowercase hex characters");
    }

    // ===================== get_data_for_uri =====================

    private void test_data_uri_png() {
        // PNG 1x1 transparent pixel (minimal valid PNG)
        string base64_data = "iVBORw0KGgoAAAANSUhEUgAAAAEAAAABCAYAAAAfFcSJAAAADUlEQVR42mP8/5+hHgAHggJ/PchI7wAAAABJRU5ErkJggg==";
        string uri = "data:image/png;base64," + base64_data;
        Bytes? result = Xmpp.get_data_for_uri(uri);
        fail_if(result == null, "data:image/png;base64 URI should return non-null Bytes");
        if (result != null) {
            fail_if_not(result.get_size() > 0, "Decoded PNG data should have non-zero size");
        }
    }

    private void test_data_uri_unknown() {
        Bytes? result = Xmpp.get_data_for_uri("https://example.com/image.png");
        fail_if(result != null,
            "Non-data/non-cid URI should return null");
    }

    private void test_data_uri_jpeg() {
        string uri = "data:image/jpeg;base64,/9j/4AAQSkZJRg==";
        Bytes? result = Xmpp.get_data_for_uri(uri);
        fail_if(result == null, "JPEG data URIs should decode independently of PNG");
        if (result != null) fail_if_not_eq_str(Base64.encode(result.get_data()), "/9j/4AAQSkZJRg==");
    }

    private void test_data_uri_empty_png() {
        // Edge case: data URI with empty Base64 payload
        string uri = "data:image/png;base64,";
        Bytes? result = Xmpp.get_data_for_uri(uri);
        fail_if(result == null, "Empty PNG data URI should return non-null (empty) Bytes");
    }

    private void test_data_uri_thumbhash() {
        string[] payloads = {
            "RwgCAYCcaEOSmgiFX3cWXwk=",
            "0GcOFA5aumgIp3OJh3eldL+1CA==",
            "zAcKAwBHjQenhXtXRVAZsDM="
        };
        foreach (string payload in payloads) {
            Bytes? result = Xmpp.get_data_for_uri("data:image/thumbhash;base64," + payload);
            fail_if(result == null, "Valid ThumbHash URI should decode without a warning");
            if (result != null) fail_if_not_eq_str(Base64.encode(result.get_data()), payload);
        }
    }

    private void test_data_uri_escaping() {
        Bytes? escaped = Xmpp.get_data_for_uri("DATA:image/jpeg;BASE64,%2F9j%2F4AAQSkZJRg%3D%3D");
        fail_if(escaped == null, "Escaped Base64 and case-insensitive URI scheme should work");
        if (escaped != null) fail_if_not_eq_str(Base64.encode(escaped.get_data()), "/9j/4AAQSkZJRg==");

        Bytes? binary = Xmpp.get_data_for_uri("data:application/octet-stream,%00%FF%2B");
        fail_if(binary == null, "Percent-encoded data may contain NUL and non-UTF-8 bytes");
        if (binary != null) fail_if_not_eq_str(Base64.encode(binary.get_data()), "AP8r");

        Bytes? text = Xmpp.get_data_for_uri("data:;charset=UTF-8,Hello%20world");
        fail_if(text == null, "The media type may be omitted");
        if (text != null) fail_if_not_eq_str(Base64.encode(text.get_data()), "SGVsbG8gd29ybGQ=");

        Bytes? folded = Xmpp.get_data_for_uri("data:image/png;base64,%20Zg%0D%0A==");
        fail_if(folded == null, "MIME whitespace in existing Base64 data should remain accepted");
        if (folded != null) fail_if_not_eq_str(Base64.encode(folded.get_data()), "Zg==");
    }

    private void test_data_uri_malformed() {
        string[] invalid = {
            "data:image/png;base64",
            "data:image/png;base64,%",
            "data:image/png;base64,%GG",
            "data:image/png;base64,%00",
            "data:image/png;base64,!!!!",
            "data:image/png;base64,Zg",
            "data:image/png;base64,Z===",
            "data:image/png;base64,Zg==AAAA",
            "data:image/png;base64,Zg==$",
            "data:image/png;base64,Zh==",
            "data:image/png;base64;base64,Zg==",
            "data:image/png,%0",
            "data:image,%41",
            "data:image/png;%00;base64,Zg==",
            "data:image/png;name=%FF;base64,Zg==",
            "data:image/png;name=%01;base64,Zg=="
        };
        foreach (string uri in invalid) {
            fail_if(Xmpp.get_data_for_uri(uri) != null, "Malformed data URI should be rejected without logging its payload");
        }
    }

    private void test_thumbnail_media_type() {
        var node = new StanzaNode.build("thumbnail", Xep.JingleContentThumbnails.NS_URI)
            .put_attribute("uri", "data:image/thumbhash;base64,RwgCAYCcaEOSmgiFX3cWXwk=");
        var thumbnail = Xep.JingleContentThumbnails.Thumbnail.from_stanza_node(node);
        fail_if(thumbnail == null, "Inline thumbnail should parse");
        if (thumbnail == null) return;
        fail_if_not_eq_str(thumbnail.media_type, "image/thumbhash");
        fail_if_not_eq_str(thumbnail.to_data_uri(), "data:image/thumbhash;base64,RwgCAYCcaEOSmgiFX3cWXwk=");
        var roundtrip = Xep.JingleContentThumbnails.Thumbnail.from_stanza_node(thumbnail.to_stanza_node());
        fail_if(roundtrip == null, "Thumbnail should survive a stanza roundtrip");
        if (roundtrip != null) {
            fail_if_not_eq_str(roundtrip.media_type, "image/thumbhash");
            fail_if_not_eq_str(Base64.encode(roundtrip.data.get_data()), "RwgCAYCcaEOSmgiFX3cWXwk=");
        }

        thumbnail.media_type = null;
        fail_if_not(thumbnail.to_data_uri().has_prefix("data:application/octet-stream;base64,"),
            "Unknown thumbnail bytes must not be mislabeled as PNG");
    }

    private void test_data_uri_cid() {
        var previous = Xep.BitsOfBinary.known_bobs;
        Xep.BitsOfBinary.known_bobs = null;
        fail_if(Xmpp.get_data_for_uri("cid:sha1+123@bob.xmpp.org") != null);
        Xep.BitsOfBinary.known_bobs = new HashMap<string, Bytes>();
        var expected = new Bytes.take(new uint8[] { 1, 2, 3 });
        Xep.BitsOfBinary.known_bobs["sha1+123@bob.xmpp.org"] = expected;
        Bytes? result = Xmpp.get_data_for_uri("cid:sha1+123@bob.xmpp.org");
        fail_if(result == null);
        if (result != null) fail_if_not_eq_str(Base64.encode(result.get_data()), "AQID");
        fail_if(Xmpp.get_data_for_uri("https://example.com/sha1+123@bob.xmpp.org") != null);
        Xep.BitsOfBinary.known_bobs = previous;
    }

    private void test_thumbnail_media_parameters() {
        var node = new StanzaNode.build("thumbnail", Xep.JingleContentThumbnails.NS_URI)
            .put_attribute("uri", "data:image/png;name=a%3Bb%22c%5Cd;base64,Zg==")
            .put_attribute("media-type", "");
        var thumbnail = Xep.JingleContentThumbnails.Thumbnail.from_stanza_node(node);
        fail_if(thumbnail == null, "Escaped MIME separators must remain parameter data");
        if (thumbnail == null) return;
        fail_if_not_eq_str(thumbnail.media_type, "image/png;name=\"a;b\\\"c\\\\d\"");
        var roundtrip = Xep.JingleContentThumbnails.Thumbnail.from_stanza_node(thumbnail.to_stanza_node());
        fail_if(roundtrip == null, "Quoted MIME parameters must survive a URI and stanza roundtrip");
        if (roundtrip != null) fail_if_not_eq_str(roundtrip.media_type, thumbnail.media_type);

        node.put_attribute("media-type", "invalid");
        thumbnail = Xep.JingleContentThumbnails.Thumbnail.from_stanza_node(node);
        fail_if(thumbnail == null);
        if (thumbnail == null) return;
        fail_if_not(thumbnail.media_type.has_prefix("image/png;"), "Invalid declared MIME must not hide the URI's media type");
        thumbnail.media_type = "invalid";
        fail_if_not(thumbnail.to_data_uri().has_prefix("data:application/octet-stream;base64,"));
        fail_if(thumbnail.to_stanza_node().get_attribute("media-type") != null);
    }
}

}
