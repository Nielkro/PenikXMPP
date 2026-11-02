using Crypto;
using Dino;
using Dino.Entities;
using Gee;
using Omemo;
using Xmpp;
using Xmpp.Xep;

namespace Dino.Plugins.JetOmemo {

private const string NS_URI = "urn:xmpp:jingle:jet-omemo:0";
private const string AES_128_GCM_URI = "urn:xmpp:ciphers:aes-128-gcm-nopadding";

public class Module : XmppStreamModule, Jet.EnvelopEncoding {
    public static Xmpp.ModuleIdentity<Module> IDENTITY = new Xmpp.ModuleIdentity<Module>(NS_URI, "0396_jet_omemo");
    const uint KEY_SIZE = 16;
    const uint IV_SIZE = 12;

    public override void attach(XmppStream stream) {
        if (stream.get_module<Jet.Module>(Jet.Module.IDENTITY) != null) {
            stream.get_module<ServiceDiscovery.Module>(ServiceDiscovery.Module.IDENTITY).add_feature(stream, NS_URI);
            Jet.Module jet = stream.get_module<Jet.Module>(Jet.Module.IDENTITY);
            jet.register_envelop_encoding(this);
            jet.register_envelop_encoding(new Omemo2EnvelopeEncoding());
            jet.register_cipher(new AesGcmCipher(KEY_SIZE, IV_SIZE, AES_128_GCM_URI));
        }
    }

    public override void detach(XmppStream stream) {
        stream.get_module<ServiceDiscovery.Module>(ServiceDiscovery.Module.IDENTITY).remove_feature(stream, NS_URI);
    }

    public async bool is_available(XmppStream stream, Jid full_jid) {
        bool? has_feature = yield stream.get_module<ServiceDiscovery.Module>(ServiceDiscovery.Module.IDENTITY).has_entity_feature(stream, full_jid, NS_URI);
        if (has_feature == null || !(!)has_feature) {
            return false;
        }
        return yield stream.get_module<Xep.Jet.Module>(Xep.Jet.Module.IDENTITY).is_available(stream, full_jid);
    }

    public string get_type_uri() {
        return Omemo.NS_URI;
    }

    public Jet.TransportSecret decode_envolop(XmppStream stream, Jid local_full_jid, Jid peer_full_jid, StanzaNode security) throws Jingle.IqError {
        StanzaNode? encrypted = security.get_subnode("encrypted", Omemo.NS_URI);
        if (encrypted == null) throw new Jingle.IqError.BAD_REQUEST("Invalid JET-OMEMO envelop: missing encrypted element");

        Xep.Omemo.OmemoDecryptor decryptor = stream.get_module<Xep.Omemo.OmemoDecryptor>(Xep.Omemo.OmemoDecryptor.IDENTITY);

        Xmpp.Xep.Omemo.ParsedData? data = decryptor.parse_node(encrypted);
        if (data == null)  throw new Jingle.IqError.BAD_REQUEST("Invalid JET-OMEMO envelop: bad encrypted element");

        foreach (Bytes encr_key in data.our_potential_encrypted_keys.keys) {
            data.is_prekey = data.our_potential_encrypted_keys[encr_key];
            data.encrypted_key = encr_key.get_data();

            try {
                if (data.is_prekey) {
                    Dino.Plugins.Omemo.OmemoDecryptor? plugin_decryptor = decryptor as Dino.Plugins.Omemo.OmemoDecryptor;
                    if (plugin_decryptor != null && !((!) plugin_decryptor).prekey_sender_identity_matches_known_device(data, peer_full_jid.bare_jid)) {
                        debug("Rejecting JET prekey from %s/%d: sender identity does not match known device",
                            peer_full_jid.bare_jid.to_string(), data.sid);
                        continue;
                    }
                }
                uint8[] key = decryptor.decrypt_key(data, peer_full_jid.bare_jid);
                return new Jet.TransportSecret(key, data.iv);
            } catch (GLib.Error e) {
                debug("Decrypting JET key from %s/%d failed: %s", peer_full_jid.bare_jid.to_string(), data.sid, e.message);
            }
        }
        throw new Jingle.IqError.NOT_ACCEPTABLE("Not encrypted for targeted device");
    }

    public void encode_envelop(XmppStream stream, Jid local_full_jid, Jid peer_full_jid, Jet.SecurityParameters security_params, StanzaNode security) throws Jingle.Error {
        Store store = stream.get_module<Omemo.StreamModule>(Omemo.StreamModule.IDENTITY).store;

        var encryption_data = new Xep.Omemo.EncryptionData(store.local_registration_id);
        encryption_data.iv = security_params.secret.initialization_vector;
        encryption_data.keytag = security_params.secret.transport_key;
        Xep.Omemo.OmemoEncryptor encryptor = stream.get_module<Xep.Omemo.OmemoEncryptor>(Xep.Omemo.OmemoEncryptor.IDENTITY);
        Xep.Omemo.EncryptionResult encryption_result;
        try {
            encryption_result = encryptor.encrypt_key_to_recipient(stream, encryption_data, peer_full_jid.bare_jid);
        } catch (GLib.Error e) {
            throw new Jingle.Error.UNSUPPORTED_SECURITY(
                "Failed to encrypt JET-OMEMO key to %s: %s".printf(peer_full_jid.bare_jid.to_string(), e.message));
        }
        if (encryption_result.success <= 0 || encryption_data.key_nodes.size == 0) {
            throw new Jingle.Error.UNSUPPORTED_SECURITY(
                "No JET-OMEMO key encrypted for %s (lost=%d unknown=%d failure=%d)".printf(
                    peer_full_jid.bare_jid.to_string(), encryption_result.lost, encryption_result.unknown, encryption_result.failure));
        }

        security.put_node(encryption_data.get_encrypted_node());
    }

    public override string get_ns() { return NS_URI; }
    public override string get_id() { return IDENTITY.id; }
}

public class Omemo2EnvelopeEncoding : Jet.EnvelopEncoding, Object {
    private const uint KEY_SIZE = 16;
    private const uint IV_SIZE = 12;

    public string get_type_uri() {
        return Omemo.NS_URI_V2;
    }

    public Jet.TransportSecret decode_envolop(XmppStream stream, Jid local_full_jid, Jid peer_full_jid, StanzaNode security) throws Jingle.IqError {
        StanzaNode? encrypted = security.get_subnode("encrypted", Omemo.NS_URI_V2);
        if (encrypted == null) throw new Jingle.IqError.BAD_REQUEST("Invalid JET-OMEMO2 envelop: missing encrypted element");

        Xep.Omemo.Omemo2Decryptor? base_decryptor = stream.get_module<Xep.Omemo.Omemo2Decryptor>(Xep.Omemo.Omemo2Decryptor.IDENTITY);
        Dino.Plugins.Omemo.Omemo2Decrypt? decryptor = base_decryptor as Dino.Plugins.Omemo.Omemo2Decrypt;
        if (decryptor == null) throw new Jingle.IqError.NOT_ACCEPTABLE("JET-OMEMO2 decryptor not available");

        Xmpp.Xep.Omemo.Omemo2ParsedData? data = ((!) decryptor).parse_node(encrypted, local_full_jid);
        if (data == null) throw new Jingle.IqError.BAD_REQUEST("Invalid JET-OMEMO2 envelop: bad encrypted element");

        foreach (Bytes encr_key in ((!) data).our_potential_encrypted_keys.keys) {
            bool is_kex = ((!) data).our_potential_encrypted_keys[encr_key];
            uint8[] encrypted_key = encr_key.get_data();
            try {
                if (is_kex && !((!) decryptor).prekey_sender_identity_matches_known_device(encrypted_key, is_kex, ((!) data).sid, peer_full_jid.bare_jid)) {
                    debug("Rejecting JET-OMEMO2 prekey from %s/%d: sender identity does not match known device",
                        peer_full_jid.bare_jid.to_string(), ((!) data).sid);
                    continue;
                }
                uint8[] packed_secret = ((!) decryptor).decrypt_key_for_encrypted_key(encrypted_key, is_kex, ((!) data).sid, peer_full_jid.bare_jid);
                return unpack_secret(packed_secret);
            } catch (GLib.Error e) {
                debug("Decrypting JET-OMEMO2 key from %s/%d failed: %s", peer_full_jid.bare_jid.to_string(), ((!) data).sid, e.message);
            }
        }
        throw new Jingle.IqError.NOT_ACCEPTABLE("Not encrypted for targeted device");
    }

    public void encode_envelop(XmppStream stream, Jid local_full_jid, Jid peer_full_jid, Jet.SecurityParameters security_params, StanzaNode security) throws Jingle.Error {
        Xep.Omemo.Omemo2Encryptor? encryptor = stream.get_module<Xep.Omemo.Omemo2Encryptor>(Xep.Omemo.Omemo2Encryptor.IDENTITY);
        if (encryptor == null) throw new Jingle.Error.UNSUPPORTED_SECURITY("JET-OMEMO2 encryptor not available");

        var encryption_data = new Xep.Omemo.Omemo2EncryptionData(encryptor.own_device_id);
        encryption_data.message_key = pack_secret(security_params.secret);

        Xep.Omemo.EncryptionResult encryption_result;
        try {
            encryption_result = ((!) encryptor).encrypt_key_to_recipient(stream, encryption_data, peer_full_jid.bare_jid);
        } catch (GLib.Error e) {
            throw new Jingle.Error.UNSUPPORTED_SECURITY(
                "Failed to encrypt JET-OMEMO2 key to %s: %s".printf(peer_full_jid.bare_jid.to_string(), e.message));
        }
        if (encryption_result.success <= 0 || encryption_data.keys_by_jid.size == 0) {
            throw new Jingle.Error.UNSUPPORTED_SECURITY(
                "No JET-OMEMO2 key encrypted for %s (lost=%d unknown=%d failure=%d)".printf(
                    peer_full_jid.bare_jid.to_string(), encryption_result.lost, encryption_result.unknown, encryption_result.failure));
        }

        security.put_node(encryption_data.get_encrypted_node());
    }

    private static uint8[] pack_secret(Jet.TransportSecret secret) throws Jingle.Error {
        if (secret.transport_key.length != KEY_SIZE || secret.initialization_vector.length != IV_SIZE) {
            throw new Jingle.Error.UNSUPPORTED_SECURITY("Unsupported JET-OMEMO2 transport secret size");
        }
        uint8[] packed = new uint8[KEY_SIZE + IV_SIZE];
        Memory.copy(packed, secret.transport_key, KEY_SIZE);
        Memory.copy((uint8*) packed + KEY_SIZE, secret.initialization_vector, IV_SIZE);
        return packed;
    }

    private static Jet.TransportSecret unpack_secret(uint8[] packed) throws Jingle.IqError {
        if (packed.length != KEY_SIZE + IV_SIZE) {
            throw new Jingle.IqError.BAD_REQUEST("Invalid JET-OMEMO2 transport secret size");
        }
        uint8[] key = new uint8[KEY_SIZE];
        uint8[] iv = new uint8[IV_SIZE];
        Memory.copy(key, packed, KEY_SIZE);
        Memory.copy(iv, (uint8*) packed + KEY_SIZE, IV_SIZE);
        return new Jet.TransportSecret(key, iv);
    }
}

public class AesGcmCipher : Jet.Cipher, Object {
    private const int TAG_SIZE = 16;
    private const int COPY_BUFFER_SIZE = 65536;

    private uint key_size;
    private uint default_iv_size;
    private string uri;
    public AesGcmCipher(uint key_size, uint default_iv_size, string uri) {
        this.key_size = key_size;
        this.default_iv_size = default_iv_size;
        this.uri = uri;
    }
    public string get_cipher_uri() {
        return uri;
    }
    public Jet.TransportSecret generate_random_secret() {
        uint8[] iv = new uint8[default_iv_size];
        uint8[] key = new uint8[key_size];
        try {
            Omemo.Plugin.get_context().randomize(iv);
            Omemo.Plugin.get_context().randomize(key);
        } catch (GLib.Error e) {
            warning("Failed to generate random secret: %s", e.message);
        }
        return new Jet.TransportSecret(key, iv);
    }
    public InputStream wrap_input_stream(InputStream input, Jet.TransportSecret secret) requires (secret.transport_key.length == key_size) {
        return new AuthenticatedAesGcmInputStream(input, secret.transport_key, secret.initialization_vector);
    }
    public OutputStream wrap_output_stream(OutputStream output, Jet.TransportSecret secret) requires (secret.transport_key.length == key_size) {
        try {
            Crypto.SymmetricCipher cipher = new SymmetricCipher("AES-GCM");
            cipher.set_key(secret.transport_key);
            cipher.set_iv(secret.initialization_vector);
            return new ConverterOutputStream(output, new SymmetricCipherEncrypter((owned) cipher, 16));
        } catch (Crypto.Error e) {
            string reason = "Failed to create JET-OMEMO output cipher: %s".printf(e.message);
            warning("%s", reason);
            return new FailingOutputStream(reason);
        }
    }

    private static uint8[] copy_bytes(uint8[] source) {
        uint8[] copy = new uint8[source.length];
        if (source.length > 0) {
            Memory.copy(copy, source, source.length);
        }
        return copy;
    }

    private class AuthenticatedAesGcmInputStream : DinoNative.InputStream, Jingle.AuthenticatedInputStream {
        private InputStream encrypted_input;
        private uint8[] key;
        private uint8[] iv;
        private InputStream? plaintext_input = null;
        private int64 expected_plaintext_size = -1;
        private bool authenticated = false;
        private bool closed = false;
        private string? authentication_failure = null;

        public AuthenticatedAesGcmInputStream(InputStream encrypted_input, uint8[] key, uint8[] iv) {
            this.encrypted_input = encrypted_input;
            this.key = copy_bytes(key);
            this.iv = copy_bytes(iv);
        }

        public void set_expected_plaintext_size(int64 plaintext_size) {
            expected_plaintext_size = plaintext_size;
        }

        public void authenticate(Cancellable? cancellable = null) throws IOError {
            ensure_authenticated(cancellable);
        }

        public async void authenticate_async(int io_priority = GLib.Priority.DEFAULT, Cancellable? cancellable = null) throws IOError {
            yield ensure_authenticated_async(io_priority, cancellable);
        }

        public override ssize_t read([CCode (type = "void*")] uint8[] buffer, Cancellable? cancellable = null) throws IOError {
            if (closed) throw new IOError.CLOSED("JET-OMEMO input stream is closed");
            if (buffer.length == 0) return 0;
            ensure_authenticated(cancellable);
            return ((!) plaintext_input).read(buffer, cancellable);
        }

        public override async ssize_t read_async([CCode (type = "void*")] uint8[]? buffer, int io_priority = GLib.Priority.DEFAULT, Cancellable? cancellable = null) throws IOError {
            if (closed) throw new IOError.CLOSED("JET-OMEMO input stream is closed");
            if (buffer == null || ((!) buffer).length == 0) return 0;
            yield ensure_authenticated_async(io_priority, cancellable);
            return yield ((!) plaintext_input).read_async(buffer, io_priority, cancellable);
        }

        public override bool close(Cancellable? cancellable = null) throws IOError {
            if (closed) return true;
            closed = true;

            IOError? close_error = null;
            try {
                if (plaintext_input != null) {
                    ((!) plaintext_input).close(cancellable);
                }
            } catch (IOError e) {
                close_error = e;
            }
            try {
                encrypted_input.close(cancellable);
            } catch (IOError.CLOSED e) {
            } catch (IOError e) {
                if (close_error == null) close_error = e;
            }
            if (close_error != null) throw (!) close_error;
            return true;
        }

        public override async bool close_async(int io_priority = GLib.Priority.DEFAULT, Cancellable? cancellable = null) throws IOError {
            if (closed) return true;
            closed = true;

            IOError? close_error = null;
            try {
                if (plaintext_input != null) {
                    yield ((!) plaintext_input).close_async(io_priority, cancellable);
                }
            } catch (IOError e) {
                close_error = e;
            }
            try {
                yield encrypted_input.close_async(io_priority, cancellable);
            } catch (IOError.CLOSED e) {
            } catch (IOError e) {
                if (close_error == null) close_error = e;
            }
            if (close_error != null) throw (!) close_error;
            return true;
        }

        private void ensure_authenticated(Cancellable? cancellable = null) throws IOError {
            if (authenticated) return;
            if (authentication_failure != null) throw new IOError.FAILED((!) authentication_failure);

            File? encrypted_temp_file = null;
            Dino.PlaintextFileLeaseTarget? plaintext_target = null;
            OutputStream? plaintext_output = null;

            try {
                int64 encrypted_size = expected_encrypted_size();
                encrypted_temp_file = copy_encrypted_input_to_temp(encrypted_size, cancellable);

                process_ciphertext_file((!) encrypted_temp_file, encrypted_size, null, cancellable);

                plaintext_target = Dino.FileManager.create_plaintext_file_lease_target("jet-omemo-receive");
                plaintext_output = ((!) plaintext_target).file.create(FileCreateFlags.PRIVATE);
                process_ciphertext_file((!) encrypted_temp_file, encrypted_size, plaintext_output, cancellable);
                ((!) plaintext_output).close(cancellable);
                plaintext_output = null;

                plaintext_input = ((!) plaintext_target).open_input_stream();
                plaintext_target = null;
                authenticated = true;
            } catch (IOError.CANCELLED e) {
                authentication_failure = e.message;
                close_output_quietly(plaintext_output);
                discard_plaintext_target(plaintext_target);
                delete_file(encrypted_temp_file);
                throw e;
            } catch (GLib.Error e) {
                authentication_failure = "JET-OMEMO AES-GCM authentication failed: %s".printf(e.message);
                close_output_quietly(plaintext_output);
                discard_plaintext_target(plaintext_target);
                delete_file(encrypted_temp_file);
                throw new IOError.FAILED((!) authentication_failure);
            }

            delete_file(encrypted_temp_file);
        }

        private async void ensure_authenticated_async(int io_priority, Cancellable? cancellable = null) throws IOError {
            if (authenticated) return;
            if (authentication_failure != null) throw new IOError.FAILED((!) authentication_failure);

            File? encrypted_temp_file = null;
            Dino.PlaintextFileLeaseTarget? plaintext_target = null;
            OutputStream? plaintext_output = null;

            try {
                int64 encrypted_size = expected_encrypted_size();
                encrypted_temp_file = yield copy_encrypted_input_to_temp_async(encrypted_size, io_priority, cancellable);

                yield process_ciphertext_file_async((!) encrypted_temp_file, encrypted_size, null, io_priority, cancellable);

                plaintext_target = Dino.FileManager.create_plaintext_file_lease_target("jet-omemo-receive");
                plaintext_output = ((!) plaintext_target).file.create(FileCreateFlags.PRIVATE);
                yield process_ciphertext_file_async((!) encrypted_temp_file, encrypted_size, plaintext_output, io_priority, cancellable);
                yield ((!) plaintext_output).close_async(io_priority, cancellable);
                plaintext_output = null;

                plaintext_input = ((!) plaintext_target).open_input_stream();
                plaintext_target = null;
                authenticated = true;
            } catch (IOError.CANCELLED e) {
                authentication_failure = e.message;
                yield close_output_quietly_async(plaintext_output, io_priority, null);
                discard_plaintext_target(plaintext_target);
                delete_file(encrypted_temp_file);
                throw e;
            } catch (GLib.Error e) {
                authentication_failure = "JET-OMEMO AES-GCM authentication failed: %s".printf(e.message);
                yield close_output_quietly_async(plaintext_output, io_priority, null);
                discard_plaintext_target(plaintext_target);
                delete_file(encrypted_temp_file);
                throw new IOError.FAILED((!) authentication_failure);
            }

            delete_file(encrypted_temp_file);
        }

        private int64 expected_encrypted_size() throws IOError {
            if (expected_plaintext_size < 0) {
                throw new IOError.FAILED("JET-OMEMO AES-GCM cannot authenticate without the declared plaintext size");
            }
            if (expected_plaintext_size > int64.MAX - TAG_SIZE) {
                throw new IOError.FAILED("JET-OMEMO AES-GCM declared plaintext size is too large");
            }
            return expected_plaintext_size + TAG_SIZE;
        }

        private File copy_encrypted_input_to_temp(int64 encrypted_size, Cancellable? cancellable = null) throws GLib.Error {
            FileIOStream temp_stream;
            File temp_file = File.new_tmp("dinox-jet-omemo-ciphertext-XXXXXX", out temp_stream);
            bool temp_stream_closed = false;
            try {
                copy_exact_stream(encrypted_input, temp_stream.output_stream, encrypted_size, cancellable);
                temp_stream.close(cancellable);
                temp_stream_closed = true;
                return temp_file;
            } catch (GLib.Error e) {
                if (!temp_stream_closed) {
                    try {
                        temp_stream.close(cancellable);
                    } catch (GLib.Error close_error) {
                    }
                }
                delete_file(temp_file);
                throw e;
            }
        }

        private async File copy_encrypted_input_to_temp_async(int64 encrypted_size, int io_priority, Cancellable? cancellable = null) throws GLib.Error {
            FileIOStream temp_stream;
            File temp_file = File.new_tmp("dinox-jet-omemo-ciphertext-XXXXXX", out temp_stream);
            bool temp_stream_closed = false;
            try {
                yield copy_exact_stream_async(encrypted_input, temp_stream.output_stream, encrypted_size, io_priority, cancellable);
                yield temp_stream.close_async(io_priority, cancellable);
                temp_stream_closed = true;
                return temp_file;
            } catch (GLib.Error e) {
                if (!temp_stream_closed) {
                    try {
                        yield temp_stream.close_async(io_priority, cancellable);
                    } catch (GLib.Error close_error) {
                    }
                }
                delete_file(temp_file);
                throw e;
            }
        }

        private void process_ciphertext_file(File encrypted_file, int64 encrypted_size, OutputStream? plaintext_output, Cancellable? cancellable = null) throws GLib.Error {
            FileInputStream input = encrypted_file.read(cancellable);
            try {
                SymmetricCipher cipher = new SymmetricCipher("AES-GCM");
                cipher.set_key(key);
                cipher.set_iv(iv);

                int64 remaining = encrypted_size - TAG_SIZE;
                uint8[] in_buffer = new uint8[COPY_BUFFER_SIZE];
                uint8[] out_buffer = new uint8[COPY_BUFFER_SIZE];
                while (remaining > 0) {
                    int chunk_size = (int) int64.min(COPY_BUFFER_SIZE, remaining);
                    ssize_t read = input.read(in_buffer[0:chunk_size], cancellable);
                    if (read <= 0) {
                        throw new IOError.PARTIAL_INPUT("JET-OMEMO AES-GCM payload ended before the authentication tag");
                    }

                    cipher.decrypt(out_buffer[0:(int) read], in_buffer[0:(int) read]);
                    if (plaintext_output != null) {
                        size_t written;
                        ((!) plaintext_output).write_all(out_buffer[0:(int) read], out written, cancellable);
                    }
                    remaining -= read;
                }

                uint8[] tag = new uint8[TAG_SIZE];
                size_t tag_read;
                input.read_all(tag, out tag_read, cancellable);
                if (tag_read != TAG_SIZE) {
                    throw new IOError.PARTIAL_INPUT("JET-OMEMO AES-GCM authentication tag is incomplete");
                }
                cipher.check_tag(tag);
            } finally {
                close_input_quietly(input);
            }
        }

        private async void process_ciphertext_file_async(File encrypted_file, int64 encrypted_size, OutputStream? plaintext_output, int io_priority, Cancellable? cancellable = null) throws GLib.Error {
            FileInputStream input = yield encrypted_file.read_async(io_priority, cancellable);
            try {
                SymmetricCipher cipher = new SymmetricCipher("AES-GCM");
                cipher.set_key(key);
                cipher.set_iv(iv);

                int64 remaining = encrypted_size - TAG_SIZE;
                uint8[] in_buffer = new uint8[COPY_BUFFER_SIZE];
                uint8[] out_buffer = new uint8[COPY_BUFFER_SIZE];
                while (remaining > 0) {
                    int chunk_size = (int) int64.min(COPY_BUFFER_SIZE, remaining);
                    ssize_t read = yield input.read_async(in_buffer[0:chunk_size], io_priority, cancellable);
                    if (read <= 0) {
                        throw new IOError.PARTIAL_INPUT("JET-OMEMO AES-GCM payload ended before the authentication tag");
                    }

                    cipher.decrypt(out_buffer[0:(int) read], in_buffer[0:(int) read]);
                    if (plaintext_output != null) {
                        size_t written;
                        yield ((!) plaintext_output).write_all_async(out_buffer[0:(int) read], io_priority, cancellable, out written);
                    }
                    remaining -= read;
                }

                uint8[] tag = new uint8[TAG_SIZE];
                size_t tag_read;
                yield input.read_all_async(tag, io_priority, cancellable, out tag_read);
                if (tag_read != TAG_SIZE) {
                    throw new IOError.PARTIAL_INPUT("JET-OMEMO AES-GCM authentication tag is incomplete");
                }
                cipher.check_tag(tag);
            } finally {
                try {
                    yield input.close_async(io_priority, cancellable);
                } catch (GLib.Error e) {
                }
            }
        }

        private void copy_exact_stream(InputStream input, OutputStream output, int64 bytes_to_copy, Cancellable? cancellable = null) throws GLib.Error {
            uint8[] buffer = new uint8[COPY_BUFFER_SIZE];
            int64 remaining = bytes_to_copy;
            while (remaining > 0) {
                int chunk_size = (int) int64.min(COPY_BUFFER_SIZE, remaining);
                ssize_t read = input.read(buffer[0:chunk_size], cancellable);
                if (read <= 0) {
                    throw new IOError.PARTIAL_INPUT("JET-OMEMO AES-GCM payload ended before the declared size and authentication tag");
                }
                size_t written;
                output.write_all(buffer[0:(int) read], out written, cancellable);
                remaining -= read;
            }
        }

        private async void copy_exact_stream_async(InputStream input, OutputStream output, int64 bytes_to_copy, int io_priority, Cancellable? cancellable = null) throws GLib.Error {
            uint8[] buffer = new uint8[COPY_BUFFER_SIZE];
            int64 remaining = bytes_to_copy;
            while (remaining > 0) {
                int chunk_size = (int) int64.min(COPY_BUFFER_SIZE, remaining);
                ssize_t read = yield input.read_async(buffer[0:chunk_size], io_priority, cancellable);
                if (read <= 0) {
                    throw new IOError.PARTIAL_INPUT("JET-OMEMO AES-GCM payload ended before the declared size and authentication tag");
                }
                size_t written;
                yield output.write_all_async(buffer[0:(int) read], io_priority, cancellable, out written);
                remaining -= read;
            }
        }

        private void close_input_quietly(InputStream input) {
            try {
                input.close(null);
            } catch (GLib.Error e) {
            }
        }

        private void close_output_quietly(OutputStream? output) {
            if (output == null) return;
            try {
                ((!) output).close(null);
            } catch (GLib.Error e) {
            }
        }

        private async void close_output_quietly_async(OutputStream? output, int io_priority, Cancellable? cancellable = null) {
            if (output == null) return;
            try {
                yield ((!) output).close_async(io_priority, cancellable);
            } catch (GLib.Error e) {
            }
        }

        private void discard_plaintext_target(Dino.PlaintextFileLeaseTarget? target) {
            if (target == null) return;
            ((!) target).discard();
        }

        private void delete_file(File? file) {
            if (file == null) return;
            try {
                ((!) file).delete(null);
            } catch (GLib.Error e) {
                debug("Failed to delete JET-OMEMO temporary file: %s", e.message);
            }
        }
    }
}

private class FailingInputStream : DinoNative.InputStream {
    private string reason;

    public FailingInputStream(string reason) {
        this.reason = reason;
    }

    public override ssize_t read([CCode (type = "void*")] uint8[] buffer, Cancellable? cancellable = null) throws IOError {
        throw new IOError.FAILED(reason);
    }

    public override async ssize_t read_async([CCode (type = "void*")] uint8[]? buffer, int io_priority = GLib.Priority.DEFAULT, Cancellable? cancellable = null) throws IOError {
        throw new IOError.FAILED(reason);
    }

    public override bool close(Cancellable? cancellable = null) throws IOError {
        return true;
    }
}

private class FailingOutputStream : DinoNative.OutputStream {
    private string reason;

    public FailingOutputStream(string reason) {
        this.reason = reason;
    }

    public override ssize_t write([CCode (type = "const void*")] uint8[] buffer, Cancellable? cancellable = null) throws IOError {
        throw new IOError.FAILED(reason);
    }

    public override async ssize_t write_async([CCode (type = "const void*")] uint8[]? buffer, int io_priority = GLib.Priority.DEFAULT, Cancellable? cancellable = null) throws IOError {
        throw new IOError.FAILED(reason);
    }

    public override bool close(Cancellable? cancellable = null) throws IOError {
        return true;
    }
}
}
