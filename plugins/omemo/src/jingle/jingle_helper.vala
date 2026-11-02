using Dino.Entities;
using Xmpp;

namespace Dino.Plugins.JetOmemo {
public class EncryptionHelper : JingleFileEncryptionHelper, Object {
    private StreamInteractor stream_interactor;
    private Dino.Plugins.Omemo.TrustManager? trust_manager;

    public EncryptionHelper(StreamInteractor stream_interactor, Dino.Plugins.Omemo.TrustManager? trust_manager = null) {
        this.stream_interactor = stream_interactor;
        this.trust_manager = trust_manager;
    }

    public bool can_transfer(Conversation conversation) {
        return true;
    }

    public async bool can_encrypt(Conversation conversation, FileTransfer file_transfer, Jid? full_jid) {
        XmppStream? stream = stream_interactor.get_stream(conversation.account);
        if (stream == null) return false;

        Gee.List<Jid>? resources = stream_interactor.get_module<PresenceManager>(PresenceManager.IDENTITY).get_full_jids(conversation.counterpart, conversation.account);
        if (resources == null) return false;

        if (full_jid == null) {
            foreach (Jid test_jid in resources) {
                if (yield stream.get_module<Module>(Module.IDENTITY).is_available(stream, test_jid)) {
                    return true;
                }
            }
        } else {
            if (yield stream.get_module<Module>(Module.IDENTITY).is_available(stream, full_jid)) {
                return true;
            }
        }
        return false;
    }

    public async bool prepare_encryption(Conversation conversation, FileTransfer file_transfer, Jid full_jid) {
        if (get_envelope_type_uri(conversation) != Omemo.NS_URI) return true;
        if (trust_manager == null || conversation.type_ != Conversation.Type.CHAT ||
                !full_jid.equals_bare(conversation.counterpart) ||
                file_transfer.cancellable.is_cancelled()) return false;
        XmppStream? stream = stream_interactor.get_stream(conversation.account);
        if (stream == null) return false;
        Omemo.StreamModule? module = stream.get_module<Omemo.StreamModule>(Omemo.StreamModule.IDENTITY);
        if (module == null || !module.store.is_persistence_ready || !module.is_attached_stream(stream)) return false;
        uint generation = module.attachment_generation;
        if (module.store.registration_pending) {
            Gee.ArrayList<int32>? own_devices = yield request_list_for_send(module, stream, conversation.account.bare_jid, file_transfer.cancellable);
            if (own_devices == null || own_devices.size == 0) return false;
        }
        if (!send_context_is_current(conversation, file_transfer, stream, module, generation)) return false;
        uint32 own_device_id = module.store.local_registration_id;
        Gee.ArrayList<int32>? advertised = yield request_list_for_send(module, stream, full_jid.bare_jid, file_transfer.cancellable);
        if (advertised == null || advertised.size == 0) return false;
        if (!send_context_is_current(conversation, file_transfer, stream, module, generation) ||
                module.store.local_registration_id != own_device_id) return false;

        // A fresh list can arrive before its metadata IQs complete. Learn the
        // identities first, so ordinary trust policy decides which devices may
        // receive the actual send's ratchet (including blind-trust-disabled).
        foreach (int32 device_id in advertised) {
            if (module.is_ignored_device(full_jid.bare_jid, device_id) ||
                    ((!) trust_manager).has_legacy_device_identity(conversation.account, full_jid.bare_jid, device_id)) continue;
            if (!yield module.await_legacy_bundle_for_send(stream, full_jid.bare_jid,
                    device_id, file_transfer.cancellable, false)) return false;
            if (!send_context_is_current(conversation, file_transfer, stream, module, generation) ||
                    module.store.local_registration_id != own_device_id) return false;
        }

        Gee.List<int32> devices = ((!) trust_manager).get_trusted_devices_omemo1(conversation.account, full_jid.bare_jid);
        if (devices.size == 0) return false;
        foreach (int32 device_id in devices) {
            if (module.is_ignored_device(full_jid.bare_jid, device_id)) continue;
            if (!((!) trust_manager).has_legacy_device_identity(conversation.account, full_jid.bare_jid, device_id)) return false;
            if (!yield module.ensure_legacy_session_for_send(stream, full_jid.bare_jid, device_id, file_transfer.cancellable)) return false;
            if (!send_context_is_current(conversation, file_transfer, stream, module, generation) ||
                    module.store.local_registration_id != own_device_id) return false;
        }
        // Trust or the active device list may have changed while requesting
        // bundles. Only return ready for the devices the envelope will use.
        int ready = 0;
        foreach (int32 device_id in ((!) trust_manager).get_trusted_devices_omemo1(conversation.account, full_jid.bare_jid)) {
            if (module.is_ignored_device(full_jid.bare_jid, device_id)) continue;
            if (!((!) trust_manager).has_legacy_device_identity(conversation.account, full_jid.bare_jid, device_id)) return false;
            if (!module.has_legacy_session_for_send(full_jid.bare_jid, device_id)) return false;
            ready++;
        }
        return ready > 0;
    }

    private bool send_context_is_current(Conversation conversation, FileTransfer file_transfer,
            XmppStream stream, Omemo.StreamModule module, uint generation) {
        return !file_transfer.cancellable.is_cancelled() &&
                stream_interactor.get_stream(conversation.account) == stream &&
                stream.get_module<Omemo.StreamModule>(Omemo.StreamModule.IDENTITY) == module &&
                module.is_attached_stream(stream) && module.attachment_generation == generation &&
                module.store.is_persistence_ready && !module.store.registration_pending;
    }

    private async Gee.ArrayList<int32>? request_list_for_send(Omemo.StreamModule module, XmppStream stream,
            Jid jid, Cancellable cancellable) {
        if (cancellable.is_cancelled()) return null;
        var promise = new Gee.Promise<Gee.ArrayList<int32>?>();
        bool completed = false;
        uint timeout = 0;
        ulong cancelled_handler = cancellable.cancelled.connect(() => {
            if (completed) return;
            completed = true;
            promise.set_value(null);
        });
        timeout = Timeout.add_seconds(15, () => {
            timeout = 0;
            if (!completed) {
                completed = true;
                promise.set_value(null);
            }
            return Source.REMOVE;
        });
        module.request_user_devicelist.begin(stream, jid, (obj, res) => {
            Gee.ArrayList<int32> devices = module.request_user_devicelist.end(res);
            if (completed) return;
            completed = true;
            promise.set_value(cancellable.is_cancelled() ? null : devices);
        });
        try {
            return yield promise.future.wait_async();
        } catch (Gee.FutureError e) {
            return null;
        } finally {
            SignalHandler.disconnect(cancellable, cancelled_handler);
            if (timeout != 0) Source.remove(timeout);
        }
    }

    public string? get_precondition_name(Conversation conversation, FileTransfer file_transfer) {
        return Xep.Jet.NS_URI;
    }

    public Object? get_precondition_options(Conversation conversation, FileTransfer file_transfer) {
        return new Xep.Jet.Options(get_envelope_type_uri(conversation), AES_128_GCM_URI);
    }

    public Encryption get_encryption(Xmpp.Xep.JingleFileTransfer.FileTransfer jingle_transfer) {
        Xep.Jet.SecurityParameters? security = jingle_transfer.security as Xep.Jet.SecurityParameters;
        if (security != null && (security.encoding.get_type_uri() == Omemo.NS_URI ||
                security.encoding.get_type_uri() == Omemo.NS_URI_V2)) {
            return Encryption.OMEMO;
        }
        return Encryption.NONE;
    }

    private string get_envelope_type_uri(Conversation conversation) {
        if (trust_manager == null) return Omemo.NS_URI;

        var recipients = new Gee.ArrayList<Jid>();
        recipients.add(conversation.counterpart.bare_jid);
        if (((!) trust_manager).should_use_omemo2(conversation.account, recipients)) {
            return Omemo.NS_URI_V2;
        }
        return Omemo.NS_URI;
    }
}
}
