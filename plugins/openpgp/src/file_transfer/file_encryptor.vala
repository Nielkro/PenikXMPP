using Dino.Entities;

namespace Dino.Plugins.OpenPgp {

private class PrivateMucFileKeySnapshot : Object {
    public GPGHelper.Key[] keys;
    public string protocol;
    public Xmpp.Jid recipient_jid;

    public PrivateMucFileKeySnapshot(GPGHelper.Key[] keys, string protocol, Xmpp.Jid recipient_jid) {
        this.keys = keys;
        this.protocol = protocol;
        this.recipient_jid = recipient_jid;
    }
}

public class PgpFileEncryptor : Dino.FileEncryptor, Dino.FileEncryptorRejectionReason, Dino.FileEncryptorSenderRequirement, Object {

    StreamInteractor? stream_interactor;
    private Gee.HashMap<int, PrivateMucFileKeySnapshot> pending_private_muc_file_key_snapshots =
        new Gee.HashMap<int, PrivateMucFileKeySnapshot>();

    public PgpFileEncryptor(StreamInteractor? stream_interactor) {
        this.stream_interactor = stream_interactor;
    }

    public bool can_encrypt_file(Conversation conversation, FileTransfer file_transfer) {
        if (!can_encrypt_transfer(file_transfer.encryption)) return false;
        if (conversation.type_ == Conversation.Type.CHAT) return true;
        if (conversation.type_ != Conversation.Type.GROUPCHAT &&
                conversation.type_ != Conversation.Type.GROUPCHAT_PM) return false;
        if (stream_interactor == null) return false;

        Manager? manager = ((!) stream_interactor).get_module<Manager>(Manager.IDENTITY);
        if (manager == null) return false;

        Gee.List<Xmpp.Jid> recipients;
        string reason;
        if (!((!) manager).try_get_private_muc_file_recipient_key_readiness(conversation, out recipients, out reason)) {
            return false;
        }
        return ((!) manager).can_encrypt_for_selected_openpgp_mode(conversation, out reason);
    }

    public string? get_file_encryption_rejection_reason(Conversation conversation, FileTransfer file_transfer) {
        if (!can_encrypt_transfer(file_transfer.encryption)) return null;
        if (conversation.type_ != Conversation.Type.GROUPCHAT &&
                conversation.type_ != Conversation.Type.GROUPCHAT_PM) return null;
        if (stream_interactor == null) {
            return "OpenPGP MUC file transfers require OpenPGP manager state before upload";
        }

        Manager? manager = ((!) stream_interactor).get_module<Manager>(Manager.IDENTITY);
        if (manager == null) {
            return "OpenPGP MUC file transfers require OpenPGP manager state before upload";
        }

        Gee.List<Xmpp.Jid> recipients;
        string reason;
        if (!((!) manager).try_get_private_muc_file_recipient_key_readiness(conversation, out recipients, out reason)) {
            return reason;
        }
        if (((!) manager).can_encrypt_for_selected_openpgp_mode(conversation, out reason)) {
            return null;
        }
        return reason;
    }

    internal static bool can_encrypt_transfer(Encryption transfer_encryption) {
        return transfer_encryption == Encryption.PGP;
    }

    internal static bool can_encrypt_conversation(Conversation conversation) {
        return conversation.type_ == Conversation.Type.CHAT ||
            conversation.type_ == Conversation.Type.GROUPCHAT ||
            conversation.type_ == Conversation.Type.GROUPCHAT_PM;
    }

    public int get_required_file_sender_id() {
        return Dino.FileManager.HTTP_PROVIDER_ID;
    }

    public async FileMeta encrypt_file(Conversation conversation, FileTransfer file_transfer) throws FileSendError {
        if (!can_encrypt_conversation(conversation)) {
            throw new FileSendError.ENCRYPTION_FAILED(
                "PGP file encryption blocked: OpenPGP file transfers are only enabled for one-to-one chats and verified private MUCs");
        }

        InputStream source_stream = file_transfer.input_stream;
        string original_file_name = file_transfer.file_name;
        GPGHelper.Key[] keys;
        string? selected_protocol = null;
        Xmpp.Jid? selected_body_url_recipient = null;
        bool private_muc_file_send = conversation.type_ == Conversation.Type.GROUPCHAT ||
            conversation.type_ == Conversation.Type.GROUPCHAT_PM;
        try {
            if (stream_interactor == null) {
                throw new FileSendError.ENCRYPTION_FAILED("PGP file encryption error: OpenPGP manager not available");
            }

            Manager? manager = ((!) stream_interactor).get_module<Manager>(Manager.IDENTITY);
            if (manager == null) {
                throw new FileSendError.ENCRYPTION_FAILED("PGP file encryption error: OpenPGP manager not available");
            }

            string reason;
            if (!((!) manager).can_encrypt_for_selected_openpgp_mode(conversation, out reason)) {
                throw new FileSendError.ENCRYPTION_FAILED("PGP file encryption blocked: %s".printf(reason));
            }

            if (conversation.type_ == Conversation.Type.CHAT) {
                keys = ((!) manager).get_key_fprs(conversation);
            } else {
                keys = ((!) manager).get_private_muc_file_recipient_key_fprs(conversation);
                selected_body_url_recipient = ((!) manager).get_private_muc_file_body_url_recipient_jid(conversation);
            }

            selected_protocol = ((!) manager).get_selected_file_protocol(conversation.account);
            file_transfer.encryption_protocol = (!) selected_protocol;
        } catch (Error e) {
            throw new FileSendError.ENCRYPTION_FAILED("PGP file encryption error: %s".printf(e.message));
        }

        string? encrypted_path = null;
        int64 encrypted_size = -1;
        string? encrypted_temp_directory = null;

        try {
            yield Dino.FileTransferWorker.run("pgp-file-encrypt", () => {
                TransferTempDirectory? temp_dir = null;
                Dino.PlaintextFileLeaseTarget? plaintext_target = null;
                string? temp_in = null;
                string? temp_out = null;
                try {
                    temp_dir = new TransferTempDirectory("dinox-pgp-enc");
                    plaintext_target = Dino.FileManager.create_plaintext_file_lease_target("pgp-send", secure_delete_plaintext_file);
                    temp_in = ((!) plaintext_target).file.get_path();
                    if (temp_in == null || ((!) temp_in) == "") {
                        throw new IOError.FAILED("PGP plaintext lease input path missing");
                    }
                    temp_out = ((!) temp_dir).child("output.gpg");
                    copy_input_stream_to_private_file(source_stream, (!) temp_in, file_transfer.cancellable);

                    encrypted_size = GPGHelper.encrypt_file_to_path((!) temp_in, temp_out, keys, 0, original_file_name);
                    ((!) plaintext_target).discard();
                    plaintext_target = null;
                    temp_in = null;
                    encrypted_path = temp_out;
                    encrypted_temp_directory = ((!) temp_dir).path;
                    temp_dir = null;
                    temp_out = null;
                } catch (GLib.Error e) {
                    if (plaintext_target != null) {
                        ((!) plaintext_target).discard();
                    } else if (temp_in != null) {
                        GPGHelper.secure_delete_file((!) temp_in);
                    }
                    if (temp_out != null) GPGHelper.secure_delete_file(temp_out);
                    if (temp_dir != null) ((!) temp_dir).remove_if_empty();
                    throw e;
                } finally {
                    close_consumed_source_stream(source_stream, file_transfer.cancellable);
                }
            });
        } catch (GLib.Error e) {
            throw new FileSendError.ENCRYPTION_FAILED("PGP file encryption error: %s".printf(e.message));
        }
        if (encrypted_path == null || encrypted_size < 0) {
            throw new FileSendError.ENCRYPTION_FAILED("PGP file encryption error: encrypted output missing");
        }

        File encrypted_file = File.new_for_path((!) encrypted_path);
        try {
            file_transfer.input_stream = new TempFileInputStream(encrypted_file, encrypted_temp_directory);
        } catch (Error e) {
            GPGHelper.secure_delete_file((!) encrypted_path);
            if (encrypted_temp_directory != null) DirUtils.remove((!) encrypted_temp_directory);
            throw new FileSendError.ENCRYPTION_FAILED("PGP file encryption error: %s".printf(e.message));
        }
        // Keep original filename plus ".pgp" so receiving clients know the file type.
        string base_name = file_transfer.file_name ?? Xmpp.random_uuid();
        file_transfer.server_file_name = base_name + ".pgp";

        FileMeta file_meta = new FileMeta();
        file_meta.size = encrypted_size;
        file_meta.mime_type = "application/pgp-encrypted";
        file_meta.encryption = Encryption.PGP;
        // The upload payload is already GPG-encrypted. Keep FileTransfer.encryption
        // as PGP for UI/DB state, but prevent HttpFileSender from adding AES-GCM.
        file_meta.upload_payload_is_encrypted = true;
        debug("PgpFileEncryptor: encrypted %s -> %s (%lld bytes)", file_transfer.file_name, file_transfer.server_file_name, file_meta.size);

        if (private_muc_file_send && selected_protocol != null && selected_body_url_recipient != null) {
            stage_private_muc_file_key_snapshot(file_transfer, keys, (!) selected_protocol, (!) selected_body_url_recipient);
        }

        return file_meta;
    }

    private void stage_private_muc_file_key_snapshot(FileTransfer file_transfer, GPGHelper.Key[] keys,
            string protocol, Xmpp.Jid recipient_jid) {
        if (file_transfer.id < 0) return;
        pending_private_muc_file_key_snapshots[file_transfer.id] = new PrivateMucFileKeySnapshot(keys, protocol, recipient_jid);
    }

    private PrivateMucFileKeySnapshot? consume_private_muc_file_key_snapshot(FileTransfer file_transfer) {
        if (file_transfer.id < 0) return null;
        PrivateMucFileKeySnapshot? snapshot = pending_private_muc_file_key_snapshots.get(file_transfer.id);
        if (snapshot != null) {
            pending_private_muc_file_key_snapshots.unset(file_transfer.id);
        }
        return snapshot;
    }

    private static void secure_delete_plaintext_file(File file) throws Error {
        string? path = file.get_path();
        if (path != null && path != "") {
            GPGHelper.secure_delete_file((!) path);
        }
    }

    private static void close_consumed_source_stream(InputStream source_stream, Cancellable? cancellable = null) {
        try {
            source_stream.close(cancellable);
        } catch (GLib.Error e) {
            debug("PgpFileEncryptor: failed to close consumed source stream: %s", e.message);
        }
    }

    private static void copy_input_stream_to_private_file(InputStream input, string output_path, Cancellable? cancellable = null) throws GLib.Error {
        File file = File.new_for_path(output_path);
        OutputStream? output = null;
        GLib.Error? copy_error = null;

        try {
            output = file.create(FileCreateFlags.PRIVATE);
            uint8[] buffer = new uint8[65536];
            ssize_t read_bytes;
            while ((read_bytes = input.read(buffer, cancellable)) > 0) {
                size_t bytes_written;
                ((!) output).write_all(buffer[0:(int) read_bytes], out bytes_written, cancellable);
            }
        } catch (GLib.Error e) {
            copy_error = e;
        }

        if (output != null) {
            try {
                ((!) output).close();
            } catch (GLib.Error close_error) {
                if (copy_error == null) copy_error = close_error;
            }
        }

        try {
            input.close();
        } catch (GLib.Error close_error) {
            if (copy_error == null) copy_error = close_error;
        }

        if (copy_error != null) throw (!) copy_error;
    }

    public FileSendData? preprocess_send_file(Conversation conversation, FileTransfer file_transfer, FileSendData file_send_data, FileMeta file_meta) throws FileSendError {
        HttpFileSendData? send_data = file_send_data as HttpFileSendData;
        if (send_data == null) return null;

        // The message containing the download URL must be PGP-encrypted so the
        // URL is not transmitted in cleartext.
        send_data.encrypt_message = true;
        if (conversation.type_ == Conversation.Type.GROUPCHAT ||
                conversation.type_ == Conversation.Type.GROUPCHAT_PM) {
            if (stream_interactor == null) {
                throw new FileSendError.ENCRYPTION_FAILED("PGP private-MUC file encryption snapshot error: OpenPGP manager not available");
            }
            Manager? manager = ((!) stream_interactor).get_module<Manager>(Manager.IDENTITY);
            if (manager == null) {
                throw new FileSendError.ENCRYPTION_FAILED("PGP private-MUC file encryption snapshot error: OpenPGP manager not available");
            }
            PrivateMucFileKeySnapshot? snapshot = consume_private_muc_file_key_snapshot(file_transfer);
            if (snapshot == null) {
                throw new FileSendError.ENCRYPTION_FAILED("PGP private-MUC file encryption snapshot missing");
            }
            ((!) manager).stage_private_muc_file_body_url_key_material(conversation, send_data.url_down,
                ((!) snapshot).keys, ((!) snapshot).protocol, ((!) snapshot).recipient_jid);
        }
        return file_send_data;
    }
}

}
