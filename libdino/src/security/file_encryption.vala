/*
 * Copyright (C) 2026 DinoX Developers
 *
 * This program is free software: you can redistribute it and/or modify
 * it under the terms of the GNU General Public License as published by
 * the Free Software Foundation, either version 3 of the License, or
 * (at your option) any later version.
 */

using GLib;
using Crypto;

namespace Dino.Security {

public class FileEncryption : Object {
    private const int SALT_SIZE = 16;       // 128-bit random salt per NIST SP 800-132
    private const int IV_SIZE = 12;
    private const int TAG_SIZE = 16;
    private const int KDF_ITERATIONS = 100000;  // NIST SP 800-132 recommends ≥10,000

    private string password_store;

    public FileEncryption(string password) {
        this.password_store = password;
    }

    /*
     * PBKDF2-SHA256 key derivation (NIST SP 800-132 compliant).
     * Uses random salt and 100,000 iterations.
     */
    private static uint8[] derive_key(string password, uint8[] salt) {
        uint8[] password_bytes = (uint8[]) password.to_utf8();

        // PBKDF2-HMAC-SHA256, single block (output = 32 bytes = SHA256 size)
        uint8[] result = new uint8[32];
        uint8[] last = new uint8[salt.length + 4];
        Memory.copy(last, salt, salt.length);
        last[salt.length + 3] = 1;  // Block counter = 1

        for (int i = 0; i < KDF_ITERATIONS; i++) {
            // HMAC-SHA256(password, last)
            Hmac hmac = new Hmac(ChecksumType.SHA256, password_bytes);
            hmac.update(last);
            size_t out_len = 32;
            uint8[] step = new uint8[32];
            hmac.get_digest(step, ref out_len);
            last = step;

            // XOR into result
            for (int j = 0; j < 32; j++) {
                result[j] ^= step[j];
            }
        }
        return result;
    }

    private async uint8[] derive_key_async(uint8[] salt) {
        uint8[] salt_copy = new uint8[salt.length];
        Memory.copy(salt_copy, salt, salt.length);
        uint8[]? derived_key = null;
        SourceFunc callback = derive_key_async.callback;

        new Thread<void*>("dinox-file-kdf", () => {
            derived_key = derive_key(password_store, salt_copy);
            Idle.add((owned) callback);
            return null;
        });

        yield;
        return (!) derived_key;
    }

    public async void encrypt_stream(InputStream input, OutputStream output, Cancellable? cancellable = null) throws GLib.Error {
        GLib.Error? caught_error = null;
        SourceFunc callback = encrypt_stream.callback;

        new Thread<void*>("dinox-file-encrypt", () => {
            try {
                encrypt_stream_sync(input, output, cancellable);
            } catch (GLib.Error e) {
                caught_error = e;
            }
            Idle.add((owned) callback);
            return null;
        });

        yield;
        if (caught_error != null) throw (!) caught_error;
    }

    internal void encrypt_stream_sync(InputStream input, OutputStream output, Cancellable? cancellable = null) throws GLib.Error {
        uint8[] salt = new uint8[SALT_SIZE];
        Crypto.randomize(salt);
        output.write_all(salt, null, cancellable);

        uint8[] derived_key = derive_key(password_store, salt);

        uint8[] iv = new uint8[IV_SIZE];
        Crypto.randomize(iv);
        output.write_all(iv, null, cancellable);

        var cipher = new SymmetricCipher("AES256-GCM");
        cipher.set_key(derived_key);
        cipher.set_iv(iv);

        uint8[] buffer = new uint8[8192];
        ssize_t read;
        while ((read = input.read(buffer, cancellable)) > 0) {
            uint8[] chunk = buffer[0:(int)read];
            uint8[] out_chunk = new uint8[(int)read];
            cipher.encrypt(out_chunk, chunk);
            output.write_all(out_chunk, null, cancellable);
        }

        uint8[] tag = cipher.get_tag(TAG_SIZE);
        output.write_all(tag, null, cancellable);
    }

    public async void decrypt_stream(InputStream input, OutputStream output, Cancellable? cancellable = null) throws GLib.Error {
        yield decrypt_stream_format(input, output, SALT_SIZE, IV_SIZE, TAG_SIZE, cancellable);
    }

    public async void decrypt_file_to_file(File source_file, File target_file, Cancellable? cancellable = null) throws GLib.Error {
        GLib.Error? caught_error = null;
        SourceFunc callback = decrypt_file_to_file.callback;

        new Thread<void*>("dinox-file-decrypt", () => {
            InputStream? input = null;
            OutputStream? output = null;
            try {
                input = source_file.read(cancellable);
                output = target_file.replace(null, false, FileCreateFlags.NONE, cancellable);
                decrypt_stream_sync((!) input, (!) output, SALT_SIZE, IV_SIZE, TAG_SIZE, cancellable);
            } catch (GLib.Error e) {
                caught_error = e;
            } finally {
                if (input != null) {
                    try { ((!) input).close(cancellable); } catch (GLib.Error e) {}
                }
                if (output != null) {
                    try { ((!) output).close(cancellable); } catch (GLib.Error e) {}
                }
            }
            Idle.add((owned) callback);
            return null;
        });

        yield;
        if (caught_error != null) throw (!) caught_error;
    }

    public async void decrypt_file_to_stream(File source_file, OutputStream output_stream, Cancellable? cancellable = null) throws GLib.Error {
        GLib.Error? caught_error = null;
        SourceFunc callback = decrypt_file_to_stream.callback;

        new Thread<void*>("dinox-file-decrypt-stream", () => {
            try {
                decrypt_file_to_stream_sync(source_file, output_stream, cancellable);
            } catch (GLib.Error e) {
                caught_error = e;
            }
            Idle.add((owned) callback);
            return null;
        });

        yield;
        if (caught_error != null) throw (!) caught_error;
    }

    internal void decrypt_file_to_stream_sync(File source_file, OutputStream output_stream, Cancellable? cancellable = null) throws GLib.Error {
        InputStream? input = null;
        try {
            input = source_file.read(cancellable);
            decrypt_stream_sync((!) input, output_stream, SALT_SIZE, IV_SIZE, TAG_SIZE, cancellable);
        } finally {
            if (input != null) {
                try { ((!) input).close(cancellable); } catch (GLib.Error e) {}
            }
            try { output_stream.close(cancellable); } catch (GLib.Error e) {}
        }
    }

    private async void decrypt_stream_format(InputStream input, OutputStream output, int salt_sz, int iv_sz, int tag_sz, Cancellable? cancellable = null) throws GLib.Error {
        // Read Salt
        uint8[] salt = new uint8[salt_sz];
        size_t bytes_read;
        yield input.read_all_async(salt, Priority.DEFAULT, cancellable, out bytes_read);
        if (bytes_read != salt_sz) throw new IOError.FAILED("Stream too short (missing Salt)");

        // Read IV
        uint8[] iv = new uint8[iv_sz];
        yield input.read_all_async(iv, Priority.DEFAULT, cancellable, out bytes_read);
        if (bytes_read != iv_sz) throw new IOError.FAILED("Stream too short (missing IV)");

        // Derive key from password + salt
        uint8[] derived_key = yield derive_key_async(salt);

        var cipher = new SymmetricCipher("AES256-GCM");
        cipher.set_key(derived_key);
        cipher.set_iv(iv);

        // We need to read until the end to get the tag.
        // The last tag_sz bytes are the tag.
        // This is tricky in a stream because we don't know when it ends until it ends.
        // We need a rolling buffer or lookahead.
        
        // Strategy:
        // Maintain a buffer of size tag_sz + CHUNK_SIZE.
        // Always keep tag_sz bytes "held back" as potential tag.
        
        uint8[] buffer = new uint8[8192];
        uint8[] tag_buffer = new uint8[tag_sz];
        
        // Initial fill of tag buffer (holdback for potential GCM tag at EOF)
        yield input.read_all_async(tag_buffer, Priority.DEFAULT, cancellable, out bytes_read);
        
        if (bytes_read < tag_sz) {
             throw new IOError.FAILED("Stream too short (missing Tag)");
        }

        while (true) {
            ssize_t n = yield input.read_async(buffer, Priority.DEFAULT, cancellable);
            if (n == 0) break; // EOF

            // tag_buffer holds tag_sz bytes from previous reads (potential tag).
            // We now have n new bytes in buffer. Total: tag_sz + n bytes.
            // The first n bytes are confirmed ciphertext, last tag_sz are new holdback.

            if (n >= tag_sz) {
                // Decrypt all of tag_buffer (confirmed ciphertext)
                uint8[] out_held = new uint8[tag_sz];
                cipher.decrypt(out_held, tag_buffer);
                yield output.write_all_async(out_held, Priority.DEFAULT, cancellable, null);

                // Decrypt buffer[0 : n - tag_sz]
                int middle_len = (int)n - tag_sz;
                if (middle_len > 0) {
                    uint8[] middle = buffer[0:middle_len];
                    uint8[] out_middle = new uint8[middle_len];
                    cipher.decrypt(out_middle, middle);
                    yield output.write_all_async(out_middle, Priority.DEFAULT, cancellable, null);
                }

                // New tag_buffer = buffer[n - tag_sz : n]
                Memory.copy(tag_buffer, (void*)((uint8*)buffer + (n - tag_sz)), tag_sz);
            } else {
                // n < tag_sz: decrypt only the first n bytes of tag_buffer,
                // then slide remaining tag_buffer bytes + new buffer bytes into new holdback.
                uint8[] to_decrypt = tag_buffer[0:(int)n];
                uint8[] out_decrypt = new uint8[(int)n];
                cipher.decrypt(out_decrypt, to_decrypt);
                yield output.write_all_async(out_decrypt, Priority.DEFAULT, cancellable, null);

                // New tag_buffer = tag_buffer[n:tag_sz] + buffer[0:n]
                uint8[] new_tag = new uint8[tag_sz];
                int keep = tag_sz - (int)n;
                Memory.copy(new_tag, (void*)((uint8*)tag_buffer + n), (size_t)keep);
                Memory.copy((void*)((uint8*)new_tag + keep), buffer, (size_t)n);
                Memory.copy(tag_buffer, new_tag, tag_sz);
            }
        }
        
        // Loop finished. 'tag_buffer' contains the Tag.
        cipher.check_tag(tag_buffer);
    }

    private void decrypt_stream_sync(InputStream input, OutputStream output, int salt_sz, int iv_sz, int tag_sz, Cancellable? cancellable = null) throws GLib.Error {
        uint8[] salt = new uint8[salt_sz];
        size_t bytes_read;
        input.read_all(salt, out bytes_read, cancellable);
        if (bytes_read != salt_sz) throw new IOError.FAILED("Stream too short (missing Salt)");

        uint8[] iv = new uint8[iv_sz];
        input.read_all(iv, out bytes_read, cancellable);
        if (bytes_read != iv_sz) throw new IOError.FAILED("Stream too short (missing IV)");

        uint8[] derived_key = derive_key(password_store, salt);

        var cipher = new SymmetricCipher("AES256-GCM");
        cipher.set_key(derived_key);
        cipher.set_iv(iv);

        uint8[] buffer = new uint8[8192];
        uint8[] tag_buffer = new uint8[tag_sz];

        input.read_all(tag_buffer, out bytes_read, cancellable);
        if (bytes_read < tag_sz) {
            throw new IOError.FAILED("Stream too short (missing Tag)");
        }

        while (true) {
            ssize_t n = input.read(buffer, cancellable);
            if (n == 0) break;

            if (n >= tag_sz) {
                uint8[] out_held = new uint8[tag_sz];
                cipher.decrypt(out_held, tag_buffer);
                output.write_all(out_held, null, cancellable);

                int middle_len = (int)n - tag_sz;
                if (middle_len > 0) {
                    uint8[] middle = buffer[0:middle_len];
                    uint8[] out_middle = new uint8[middle_len];
                    cipher.decrypt(out_middle, middle);
                    output.write_all(out_middle, null, cancellable);
                }

                Memory.copy(tag_buffer, (void*)((uint8*)buffer + (n - tag_sz)), tag_sz);
            } else {
                uint8[] to_decrypt = tag_buffer[0:(int)n];
                uint8[] out_decrypt = new uint8[(int)n];
                cipher.decrypt(out_decrypt, to_decrypt);
                output.write_all(out_decrypt, null, cancellable);

                uint8[] new_tag = new uint8[tag_sz];
                int keep = tag_sz - (int)n;
                Memory.copy(new_tag, (void*)((uint8*)tag_buffer + n), (size_t)keep);
                Memory.copy((void*)((uint8*)new_tag + keep), buffer, (size_t)n);
                Memory.copy(tag_buffer, new_tag, tag_sz);
            }
        }

        cipher.check_tag(tag_buffer);
    }

    public uint8[] decrypt_data(uint8[] encrypted_data) throws GLib.Error {
        return decrypt_data_format(encrypted_data, SALT_SIZE, IV_SIZE, TAG_SIZE);
    }

    private uint8[] decrypt_data_format(uint8[] encrypted_data, int salt_sz, int iv_sz, int tag_sz) throws GLib.Error {
        int overhead = salt_sz + iv_sz + tag_sz;
        if (encrypted_data.length < overhead) {
            throw new IOError.FAILED("Data too short");
        }

        uint8[] salt = encrypted_data[0:salt_sz];
        uint8[] iv = encrypted_data[salt_sz:salt_sz + iv_sz];
        uint8[] tag = encrypted_data[encrypted_data.length - tag_sz:encrypted_data.length];
        uint8[] ciphertext = encrypted_data[salt_sz + iv_sz:encrypted_data.length - tag_sz];

        uint8[] derived_key = derive_key(password_store, salt);

        var cipher = new SymmetricCipher("AES256-GCM");
        cipher.set_key(derived_key);
        cipher.set_iv(iv);

        uint8[] plaintext = new uint8[ciphertext.length];
        cipher.decrypt(plaintext, ciphertext);
        cipher.check_tag(tag);

        return plaintext;
    }
    
    public uint8[] encrypt_data(uint8[] plaintext) throws GLib.Error {
        // Generate random salt (NIST SP 800-132)
        uint8[] salt = new uint8[SALT_SIZE];
        Crypto.randomize(salt);

        // Derive key from password + random salt
        uint8[] derived_key = derive_key(password_store, salt);

        uint8[] iv = new uint8[IV_SIZE];
        Crypto.randomize(iv);

        var cipher = new SymmetricCipher("AES256-GCM");
        cipher.set_key(derived_key);
        cipher.set_iv(iv);

        uint8[] ciphertext = new uint8[plaintext.length];
        cipher.encrypt(ciphertext, plaintext);
        uint8[] tag = cipher.get_tag(TAG_SIZE);

        // Result: Salt(16) + IV(12) + Ciphertext + Tag(16)
        uint8[] result = new uint8[SALT_SIZE + IV_SIZE + ciphertext.length + TAG_SIZE];
        Memory.copy(result, salt, SALT_SIZE);
        Memory.copy((void*)((uint8*)result + SALT_SIZE), iv, IV_SIZE);
        Memory.copy((void*)((uint8*)result + SALT_SIZE + IV_SIZE), ciphertext, ciphertext.length);
        Memory.copy((void*)((uint8*)result + SALT_SIZE + IV_SIZE + ciphertext.length), tag, TAG_SIZE);
        
        return result;
    }
}

}
