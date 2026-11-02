using Xmpp;
using Xmpp.Xep;
using Gee;

namespace Xmpp.Test {

/**
 * Spec-based tests for XEP-0448 Encryption for Stateless File Sharing.
 *
 * References:
 *   - XEP-0448 §3: The <encrypted> element wraps inner <sources> with key/iv
 *   - XEP-0447 §3: <file-sharing> structure with <file> and <sources>
 *   - XEP-0448 namespace: urn:xmpp:esfs:0
 *   - XEP-0447 namespace: urn:xmpp:sfs:0
 */
public class Xep0448Test : Gee.TestCase {
    public Xep0448Test() {
        base("Xep0448Test");
        add_test("XEP0448_encryption_element_structure", test_encryption_element_structure);
        add_test("XEP0448_key_iv_base64_preserved", test_key_iv_base64);
        add_test("XEP0448_parse_valid_esfs_source", test_parse_valid_esfs_source);
        add_test("XEP0448_parse_rejects_missing_cipher", test_parse_rejects_missing_cipher);
        add_test("XEP0448_parse_rejects_empty_key", test_parse_rejects_empty_key);
        add_test("XEP0448_parse_rejects_non_http_url", test_parse_rejects_non_http_url);
    }

    /**
     * XEP-0448 §3: set_sfs_element MUST produce:
     *   <file-sharing xmlns='urn:xmpp:sfs:0'>
     *     <file .../>
     *     <sources xmlns='urn:xmpp:sfs:0'>
     *       <encrypted xmlns='urn:xmpp:esfs:0'>
     *         <key>...</key>
     *         <iv>...</iv>
     *         <sources xmlns='urn:xmpp:sfs:0'>
     *           <url-data .../>
     *         </sources>
     *       </encrypted>
     *     </sources>
     *   </file-sharing>
     */
    public void test_encryption_element_structure() {
        var message = new MessageStanza();
        var metadata = new FileMetadataElement.FileMetadata();
        metadata.name = "secret.txt";
        metadata.size = 1234;
        
        var sources = new ArrayList<StatelessFileSharing.Source>();
        sources.add(new StatelessFileSharing.HttpSource() { url = "https://example.com/secret.txt" });

        var encryption = new StatelessFileSharing.EncryptionData();
        encryption.key = Base64.decode("MDEyMzQ1Njc4OTAxMjM0NTY3ODkwMTIzNDU2Nzg5MDE=");
        encryption.iv = Base64.decode("MDEyMzQ1Njc4OTAx");
        encryption.cipher_uri = "urn:xmpp:ciphers:aes-256-gcm-nopadding:0";

        StatelessFileSharing.set_sfs_element(message, "share-id-1", metadata, sources, encryption);

        // XEP-0447: Root <file-sharing> in urn:xmpp:sfs:0
        var sfs_node = message.stanza.get_subnode("file-sharing", StatelessFileSharing.NS_URI);
        assert(sfs_node != null);
        
        // XEP-0447: <sources> inside <file-sharing>
        var sources_node = sfs_node.get_subnode("sources", StatelessFileSharing.NS_URI);
        assert(sources_node != null);

        // XEP-0448: <encrypted> inside <sources> with urn:xmpp:esfs:0 namespace
        var enc_node = sources_node.get_subnode("encrypted", StatelessFileSharing.EncryptionData.NS_URI);
        assert(enc_node != null);

        // XEP-0448 §3: <key> and <iv> children MUST be present
        var key_node = enc_node.get_subnode("key", StatelessFileSharing.EncryptionData.NS_URI);
        assert(key_node != null);

        var iv_node = enc_node.get_subnode("iv", StatelessFileSharing.EncryptionData.NS_URI);
        assert(iv_node != null);

        // XEP-0448 §3: Inner <sources> wraps the actual download URLs
        var inner_sources = enc_node.get_subnode("sources", StatelessFileSharing.NS_URI);
        assert(inner_sources != null);
    }

    /**
     * XEP-0448 §3: Key and IV MUST be Base64-encoded in the XML.
     * Verify the exact Base64 values survive serialization.
     */
    public void test_key_iv_base64() {
        string expected_key_b64 = "MDEyMzQ1Njc4OTAxMjM0NTY3ODkwMTIzNDU2Nzg5MDE=";
        string expected_iv_b64 = "MDEyMzQ1Njc4OTAx";

        var message = new MessageStanza();
        var metadata = new FileMetadataElement.FileMetadata();
        metadata.name = "test.bin";
        metadata.size = 42;
        
        var sources = new ArrayList<StatelessFileSharing.Source>();
        sources.add(new StatelessFileSharing.HttpSource() { url = "https://example.com/test.bin" });

        var encryption = new StatelessFileSharing.EncryptionData();
        encryption.key = Base64.decode(expected_key_b64);
        encryption.iv = Base64.decode(expected_iv_b64);
        encryption.cipher_uri = "urn:xmpp:ciphers:aes-256-gcm-nopadding:0";

        StatelessFileSharing.set_sfs_element(message, "id-2", metadata, sources, encryption);

        var sfs_node = message.stanza.get_subnode("file-sharing", StatelessFileSharing.NS_URI);
        var sources_node = sfs_node.get_subnode("sources", StatelessFileSharing.NS_URI);
        var enc_node = sources_node.get_subnode("encrypted", StatelessFileSharing.EncryptionData.NS_URI);

        var key_node = enc_node.get_subnode("key", StatelessFileSharing.EncryptionData.NS_URI);
        assert(key_node.get_string_content() == expected_key_b64);

        var iv_node = enc_node.get_subnode("iv", StatelessFileSharing.EncryptionData.NS_URI);
        assert(iv_node.get_string_content() == expected_iv_b64);
    }

    public void test_parse_valid_esfs_source() {
        string cipher_uri = "urn:xmpp:ciphers:aes-256-gcm-nopadding:0";
        var message = build_esfs_message("https://example.com/secret.txt",
            { 1, 2, 3, 4 },
            { 5, 6, 7, 8 },
            cipher_uri);

        var shares = StatelessFileSharing.get_file_shares(message);
        fail_if(shares == null || shares.size != 1, "Expected one parsed SFS share");
        var sources = shares[0].sources;
        fail_if(sources == null || sources.size != 1, "Expected one parsed ESFS source");

        var esfs = sources[0] as StatelessFileSharing.EsfsHttpSource;
        fail_if(esfs == null, "Expected an ESFS source");
        fail_if_not_eq_str(((!) esfs).url, "https://example.com/secret.txt", "ESFS URL");
        fail_if_not_eq_str(((!) esfs).cipher_uri, cipher_uri, "ESFS cipher");
    }

    public void test_parse_rejects_missing_cipher() {
        var message = build_esfs_message("https://example.com/secret.txt",
            { 1, 2, 3, 4 },
            { 5, 6, 7, 8 },
            null);

        assert_no_sources(message, "Missing ESFS cipher must be rejected");
    }

    public void test_parse_rejects_empty_key() {
        var message = build_esfs_message("https://example.com/secret.txt",
            new uint8[0],
            { 5, 6, 7, 8 },
            "urn:xmpp:ciphers:aes-256-gcm-nopadding:0");

        assert_no_sources(message, "Empty ESFS key must be rejected");
    }

    public void test_parse_rejects_non_http_url() {
        var message = build_esfs_message("file:///tmp/secret.txt",
            { 1, 2, 3, 4 },
            { 5, 6, 7, 8 },
            "urn:xmpp:ciphers:aes-256-gcm-nopadding:0");

        assert_no_sources(message, "Non-HTTP ESFS URL must be rejected");
    }

    private MessageStanza build_esfs_message(string url, uint8[] key, uint8[] iv, string? cipher_uri) {
        var message = new MessageStanza();
        var metadata = new FileMetadataElement.FileMetadata();
        metadata.name = "secret.txt";
        metadata.size = 1234;

        var sources = new ArrayList<StatelessFileSharing.Source>();
        sources.add(new StatelessFileSharing.HttpSource() { url = url });

        var encryption = new StatelessFileSharing.EncryptionData();
        encryption.key = key;
        encryption.iv = iv;
        encryption.cipher_uri = cipher_uri;

        StatelessFileSharing.set_sfs_element(message, "share-id-parse", metadata, sources, encryption);
        return message;
    }

    private void assert_no_sources(MessageStanza message, string reason) {
        var shares = StatelessFileSharing.get_file_shares(message);
        fail_if(shares == null || shares.size != 1, "Expected one parsed SFS share");
        fail_if(shares[0].sources != null, reason);
    }
}

}
