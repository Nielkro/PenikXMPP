using Gee;
using Xmpp;
using Dino.Entities;

// Alias for XEP-0373 types to avoid conflict with Dino.Plugins.OpenPgp.Module
// The XMPP module is at Xmpp.Xep.OpenPgp.Module

namespace Dino.Plugins.OpenPgp {
    public enum SecretBackupCleanupResult {
        ABSENT, UNRELATED, DELETED, UNKNOWN, MULTIPLE, FAILED
    }
    
    // XEP-0373 Key Publishing Manager
    // Publishes and retrieves OpenPGP keys via PubSub/PEP
    // Compatible with Conversations, Monocles, and other modern XMPP clients
    
    public class Xep0373KeyManager : Object {
        public class RequestGuard : Object {
            public bool cancelled = false;

            public void cancel() {
                cancelled = true;
            }
        }
        
        private StreamInteractor stream_interactor;
        private Database db;
        private Mutex request_mutex = Mutex();
        private HashSet<string> pending_key_requests = new HashSet<string>();
        private HashSet<string> session_key_requests = new HashSet<string>();
        private HashSet<string> connected_public_key_signal_accounts = new HashSet<string>();
        private Mutex publish_mutex = Mutex();
        private HashSet<string> pending_own_key_publishes = new HashSet<string>();
        private HashSet<string> session_own_key_publishes = new HashSet<string>();
        private HashMap<string, uint> own_key_publish_revisions = new HashMap<string, uint>();
        private Mutex pending_retraction_mutex = Mutex();
        private HashSet<string> pending_retraction_attempts = new HashSet<string>();
        private HashSet<int> pending_backup_cleanup_attempts = new HashSet<int>();
        private HashSet<int> own_key_mutation_accounts = new HashSet<int>();
        private HashSet<int> secret_backup_mutation_accounts = new HashSet<int>();
        
        public signal void key_received(Account account, Jid jid, string fingerprint, string key_data_base64);
        public signal void key_cleared(Account account, Jid jid);

        public bool auto_publish_own_key { get; set; default = true; }
        
        public Xep0373KeyManager(StreamInteractor stream_interactor, Database db) {
            this.stream_interactor = stream_interactor;
            this.db = db;
            
            stream_interactor.stream_negotiated.connect(on_stream_negotiated);
        }
        
        private void on_stream_negotiated(Account account, XmppStream stream) {
            debug("XEP-0373: Stream negotiated for %s, scheduling own key publish...", account.bare_jid.to_string());
            // PubSub key data is persistent. Do not export/sign/import OpenPGP
            // material inside the login handshake; schedule it after startup and
            // deduplicate per account/key for this process.
            if (auto_publish_own_key) {
                schedule_own_key_publish(account);
            } else {
                debug("XEP-0373: Own key auto-publish disabled for %s", account.bare_jid.to_string());
            }
            
            // Connect to the XEP-0373 module signals
            Xmpp.Xep.OpenPgp.Module? module = stream.get_module(Xmpp.Xep.OpenPgp.Module.IDENTITY);
            if (module != null) {
                string signal_token = account.bare_jid.to_string();
                request_mutex.lock();
                bool already_connected = connected_public_key_signal_accounts.contains(signal_token);
                if (!already_connected) connected_public_key_signal_accounts.add(signal_token);
                request_mutex.unlock();
                if (!already_connected) {
                    module.public_keys_received.connect((stream_, jid, keys) => {
                        on_public_keys_received(account, stream_, jid, keys);
                    });
                    module.public_keys_advertised.connect((stream_, jid, keys) => {
                        on_public_keys_advertised(account, stream_, jid, keys);
                    });
                    debug("XEP-0373: Connected to module signals");
                } else {
                    debug("XEP-0373: Module signals already connected");
                }
            } else {
                debug("XEP-0373: Module NOT found on stream!");
            }

            retry_pending_xmpp_key_retractions(account);
            retry_pending_secret_key_backup_cleanup.begin(account);
        }

        private string get_publish_token(Account account, string key_id) {
            return "%d\n%s\n%s".printf(account.id, account.bare_jid.to_string(), normalize_key_match_value(key_id));
        }

        private bool is_current_xmpp_key(Account account, string fingerprint) {
            string? current_key = db.get_account_xmpp_key(account);
            return db.get_account_key_mode(account) == Database.ACCOUNT_KEY_MODE_XMPP &&
                current_key != null && fingerprint_or_keyid_matches((!) current_key, fingerprint);
        }

        private uint get_own_key_publish_revision(string token) {
            publish_mutex.lock();
            uint revision = own_key_publish_revisions[token];
            publish_mutex.unlock();
            return revision;
        }

        private async void acquire_own_key_mutation(Account account) {
            while (own_key_mutation_accounts.contains(account.id)) {
                SourceFunc resume = acquire_own_key_mutation.callback;
                Timeout.add(10, (owned) resume);
                yield;
            }
            own_key_mutation_accounts.add(account.id);
        }

        private async void acquire_secret_backup_mutation(Account account) {
            while (secret_backup_mutation_accounts.contains(account.id)) {
                SourceFunc resume = acquire_secret_backup_mutation.callback;
                Timeout.add(10, (owned) resume);
                yield;
            }
            secret_backup_mutation_accounts.add(account.id);
        }

        private void invalidate_own_key_publish(Account account, string fingerprint) {
            string token = get_publish_token(account, fingerprint);
            publish_mutex.lock();
            session_own_key_publishes.remove(token);
            pending_own_key_publishes.remove(token);
            own_key_publish_revisions[token] = own_key_publish_revisions[token] + 1;
            publish_mutex.unlock();
        }

        private void discard_reactivated_key_retraction(Account account, string fingerprint, bool may_have_retracted = false) {
            db.clear_pending_xmpp_key_retraction(account, fingerprint);
            invalidate_own_key_publish(account, fingerprint);
            if (may_have_retracted) {
                republish_key(account);
            } else if (auto_publish_own_key) {
                schedule_own_key_publish(account);
            }
        }

        private void finish_pending_publish(string? publish_token, bool mark_session = false, uint? expected_revision = null) {
            if (publish_token == null) return;

            publish_mutex.lock();
            if (expected_revision != null && own_key_publish_revisions[(!) publish_token] != ((!) expected_revision)) {
                publish_mutex.unlock();
                return;
            }
            pending_own_key_publishes.remove((!) publish_token);
            if (mark_session) {
                session_own_key_publishes.add((!) publish_token);
            }
            publish_mutex.unlock();
        }

        private void refresh_account_runtime_state_after_key_mode_change(Account account) {
            Module legacy_module = stream_interactor.module_manager.get_module<Module>(account, Module.IDENTITY);
            if (legacy_module != null) {
                legacy_module.set_private_key_id(db.get_account_legacy_key_for_presence(account));
            }

            var presence_manager = stream_interactor.get_module<Dino.PresenceManager>(Dino.PresenceManager.IDENTITY);
            if (presence_manager != null) {
                presence_manager.resend_presence(account);
            }

            Manager? manager = stream_interactor.get_module<Manager>(Manager.IDENTITY);
            if (manager != null) {
                manager.notify_key_state_changed(account);
            }
        }

        private bool request_guard_cancelled(RequestGuard? guard) {
            return guard != null && ((!) guard).cancelled;
        }

        private void remove_configured_xmpp_key_if_current(Account account, string key_id, string reason) {
            string? current_key = db.get_account_xmpp_key(account);
            if (current_key == null || !fingerprint_or_keyid_matches((!) current_key, key_id)) return;

            warning("XEP-0373: Disabling configured XMPP OpenPGP key %s for %s: %s",
                    key_id, account.bare_jid.to_string(), reason);
            string key_to_retract = (!) current_key;
            db.remove_account_xmpp_key(account);
            refresh_account_runtime_state_after_key_mode_change(account);
            retract_obsolete_published_key.begin(account, key_to_retract, (obj, res) => {
                bool retracted = retract_obsolete_published_key.end(res);
                if (!retracted) {
                    mark_pending_xmpp_key_retraction(account, key_to_retract);
                    warning("XEP-0373: Failed to retract disabled XMPP OpenPGP key %s for %s; will retry after reconnect",
                            key_to_retract, account.bare_jid.to_string());
                } else {
                    db.clear_pending_xmpp_key_retraction(account, key_to_retract);
                }
            });
        }

        private void schedule_own_key_publish(Account account) {
            if (db.get_account_key_mode(account) != Database.ACCOUNT_KEY_MODE_XMPP) {
                debug("XEP-0373: Not publishing stored XMPP key for %s; active OpenPGP mode is legacy",
                        account.bare_jid.to_string());
                return;
            }
            string? key_id = db.get_account_xmpp_key(account);
            if (key_id == null || key_id.length == 0) {
                debug("XEP-0373: No XMPP-published key configured for account %s", account.bare_jid.to_string());
                return;
            }

            string token = get_publish_token(account, key_id);
            publish_mutex.lock();
            if (pending_own_key_publishes.contains(token) || session_own_key_publishes.contains(token)) {
                publish_mutex.unlock();
                debug("XEP-0373: Skipping duplicate own key publish for %s", account.bare_jid.to_string());
                return;
            }
            pending_own_key_publishes.add(token);
            publish_mutex.unlock();

            Account account_copy = account;
            string token_copy = token;
            Timeout.add_seconds(15, () => {
                XmppStream? current_stream = stream_interactor.get_stream(account_copy);
                if (current_stream == null) {
                    publish_mutex.lock();
                    pending_own_key_publishes.remove(token_copy);
                    publish_mutex.unlock();
                    debug("XEP-0373: Skipping delayed own key publish for %s; stream is gone", account_copy.bare_jid.to_string());
                    return false;
                }
                string? current_key = db.get_account_xmpp_key(account_copy);
                if (db.get_account_key_mode(account_copy) != Database.ACCOUNT_KEY_MODE_XMPP ||
                        current_key == null || current_key.length == 0 ||
                        get_publish_token(account_copy, (!) current_key) != token_copy) {
                    publish_mutex.lock();
                    pending_own_key_publishes.remove(token_copy);
                    publish_mutex.unlock();
                    debug("XEP-0373: Skipping delayed own key publish for %s; configured key or active mode changed",
                            account_copy.bare_jid.to_string());
                    return false;
                }

                publish_own_key_async.begin(account_copy, current_stream, token_copy);
                return false;
            });
        }

        private async void publish_own_key_async(Account account, XmppStream stream, string? publish_token = null) {
            if (db.get_account_key_mode(account) != Database.ACCOUNT_KEY_MODE_XMPP) {
                debug("XEP-0373: Not publishing key for %s; active OpenPGP mode is legacy",
                        account.bare_jid.to_string());
                finish_pending_publish(publish_token);
                return;
            }
            string? key_id = db.get_account_xmpp_key(account);
            if (key_id == null) {
                debug("XEP-0373: No XMPP-published key configured for account %s", account.bare_jid.to_string());
                if (publish_token != null) {
                    publish_mutex.lock();
                    pending_own_key_publishes.remove(publish_token);
                    publish_mutex.unlock();
                }
                return;
            }
            
            debug("XEP-0373: Publishing key %s for account %s (running in background thread)", key_id, account.bare_jid.to_string());
            
            // Copy values for thread safety
            string key_id_copy = key_id;
            Account account_copy = account;
            string revision_token = get_publish_token(account, key_id_copy);
            uint revision = get_own_key_publish_revision(revision_token);
            
            // Run GPG operations in background thread to avoid blocking UI
            new Thread<void*>("xep0373-publish-key", () => {
                GPGHelper.Key? key = null;
                string? key_data_base64 = null;
                
                try {
                    // Get the full key data for publishing
                    key = GPGHelper.get_private_key(key_id_copy);
                    if (key == null) {
                        debug("XEP-0373: Could not get key %s for publishing", key_id_copy);
                        Idle.add(() => {
                            remove_configured_xmpp_key_if_current(account_copy, key_id_copy, "key is missing from the private keyring");
                            finish_pending_publish(publish_token, false, revision);
                            return false;
                        });
                        return null;
                    }

                    if (((!) key).revoked || ((!) key).expired || !((!) key).can_encrypt || !((!) key).can_sign) {
                        Idle.add(() => {
                            remove_configured_xmpp_key_if_current(account_copy, key_id_copy, "key is revoked, expired, or not usable for OpenPGP for XMPP");
                            finish_pending_publish(publish_token, false, revision);
                            return false;
                        });
                        return null;
                    }

                    bool key_has_xmpp_uid = false;
                    bool key_uid_verified = false;
                    try {
                        key_has_xmpp_uid = GPGHelper.key_has_xmpp_uid(((!) key).fpr, account_copy.bare_jid.to_string());
                        key_uid_verified = true;
                    } catch (Error e) {
                        if (e is IOError.TIMED_OUT || e.message.contains("timed out")) {
                            debug("XEP-0373: Keeping configured key %s for %s; local GPG timeout while checking xmpp: user ID",
                                    key_id_copy, account_copy.bare_jid.to_string());
                        } else {
                            debug("XEP-0373: Failed to verify xmpp: user ID for key %s and account %s: %s",
                                    key_id_copy, account_copy.bare_jid.to_string(), e.message);
                        }
                    }

                    if (key_uid_verified && !key_has_xmpp_uid) {
                        Idle.add(() => {
                            remove_configured_xmpp_key_if_current(account_copy, key_id_copy,
                                    "key has no xmpp: user ID for this account");
                            finish_pending_publish(publish_token, false, revision);
                            return false;
                        });
                        return null;
                    }
                    
                    debug("XEP-0373: Got private key, fingerprint: %s", key.fpr);
                    
                    // Export raw OpenPGP public key data and Base64-encode it
                    // for XEP-0373.  This is intentionally not ASCII armor.
                    key_data_base64 = GPGHelper.export_public_key_data_base64(key_id_copy);
                    if (key_data_base64 == null) {
                        debug("XEP-0373: Could not export public key %s", key_id_copy);
                        Idle.add(() => {
                            finish_pending_publish(publish_token, false, revision);
                            return false;
                        });
                        return null;
                    }
                    
                    debug("XEP-0373: Exported public key data, base64 length: %d", key_data_base64.length);
                    
                } catch (Error e) {
                    debug("XEP-0373: Failed to get key for publishing: %s", e.message);
                    Idle.add(() => {
                        finish_pending_publish(publish_token, false, revision);
                        return false;
                    });
                    return null;
                }
                
                // Publish key on main thread (stream operations must be on main thread)
                string fingerprint = key.fpr;
                string key_data_copy = key_data_base64;
                
                Idle.add(() => {
                    if (!is_current_xmpp_key(account_copy, key_id_copy) ||
                            get_own_key_publish_revision(revision_token) != revision) {
                        finish_pending_publish(publish_token, false, revision);
                        return false;
                    }
                    publish_key_to_stream.begin(account_copy, stream, fingerprint, key_data_copy, revision_token, revision, (obj, res) => {
                        bool published = publish_key_to_stream.end(res);
                        finish_pending_publish(publish_token, published &&
                            is_current_xmpp_key(account_copy, key_id_copy) &&
                            get_own_key_publish_revision(revision_token) == revision, revision);
                    });
                    return false;
                });
                
                return null;
            });
        }
        
        // Helper to publish key on main thread
        private async bool publish_key_to_stream(Account account, XmppStream stream, string fingerprint, string key_data_base64,
                string revision_token, uint revision) {
            yield acquire_own_key_mutation(account);
            try {
                // Check if stream is still valid (may have been disconnected while we were processing)
                if (stream == null) {
                    debug("XEP-0373: Stream is null, skipping publish");
                    return false;
                }
                if (stream_interactor.get_stream(account) != stream) {
                    debug("XEP-0373: Stream changed before publishing key %s", fingerprint);
                    return false;
                }
                if (!is_current_xmpp_key(account, fingerprint) ||
                        get_own_key_publish_revision(revision_token) != revision) return false;
            
                // Get the XEP-0373 module
                Xmpp.Xep.OpenPgp.Module? module = stream.get_module(Xmpp.Xep.OpenPgp.Module.IDENTITY);
                if (module == null) {
                    debug("XEP-0373: Module not loaded on stream");
                    return false;
                }
            
                bool ok = yield module.publish_key_data(stream, fingerprint, key_data_base64, () => {
                    return stream_interactor.get_stream(account) == stream &&
                        is_current_xmpp_key(account, fingerprint) &&
                        get_own_key_publish_revision(revision_token) == revision;
                });
                if (stream_interactor.get_stream(account) != stream ||
                        !is_current_xmpp_key(account, fingerprint) ||
                        get_own_key_publish_revision(revision_token) != revision) {
                    debug("XEP-0373: Stream changed after publishing key %s", fingerprint);
                    return false;
                }
                if (ok) {
                    debug("XEP-0373: Successfully published key %s", fingerprint);
                } else {
                    warning("XEP-0373: Failed to publish key %s", fingerprint);
                }
                return ok;
            } finally {
                own_key_mutation_accounts.remove(account.id);
            }
        }
        
        private void on_public_keys_received(Account account, XmppStream stream, Jid jid, Gee.List<Xmpp.Xep.OpenPgp.PublicKeyMeta> keys) {
            // Check stream validity
            if (stream == null) {
                debug("XEP-0373: Stream is null in on_public_keys_received");
                return;
            }
            if (keys.size == 0) {
                clear_stale_xmpp_contact_key(account, jid, "received empty public key list");
                return;
            }
            handle_public_keys_received.begin(account, stream, jid, keys);
        }

        private void on_public_keys_advertised(Account account, XmppStream stream, Jid jid, Gee.List<Xmpp.Xep.OpenPgp.PublicKeyMeta> keys) {
            if (stream == null || keys.size == 0) return;
            if (stream_interactor.get_stream(account) != stream) {
                debug("XEP-0373: Ignoring advertised public key metadata for %s from old stream", jid.to_string());
                return;
            }

            Manager? manager = stream_interactor.get_module<Manager>(Manager.IDENTITY);
            string? stored_key = db.get_contact_xmpp_key(account, jid.bare_jid);
            bool stored_key_is_advertised = false;
            if (stored_key != null && ((!) stored_key).length > 0) {
                foreach (var key_meta in keys) {
                    if (fingerprint_or_keyid_matches((!) stored_key, key_meta.fingerprint)) {
                        stored_key_is_advertised = true;
                        break;
                    }
                }
            }
            if (stored_key_is_advertised && manager != null &&
                    ((!) manager).contact_xmpp_key_was_refreshed_this_session(account, jid.bare_jid)) {
                debug("XEP-0373: Ignoring unchanged advertised key metadata from %s; key is already fresh",
                        jid.to_string());
                return;
            }

            invalidate_lazy_key_request(account, jid.bare_jid);
            if (manager != null) {
                manager.forget_xep0373_key_refresh(account, jid.bare_jid);
                manager.notify_key_state_changed(account, jid.bare_jid);
            }
            debug("XEP-0373: Advertised key metadata from %s invalidated lazy refresh state", jid.to_string());
        }

        private async void handle_public_keys_received(Account account, XmppStream stream, Jid jid, Gee.List<Xmpp.Xep.OpenPgp.PublicKeyMeta> keys) {
            bool imported_any = false;
            foreach (var key_meta in keys) {
                if (yield fetch_and_import_key(account, stream, jid, key_meta.fingerprint)) {
                    imported_any = true;
                }
            }
            if (!imported_any) {
                debug("XEP-0373: Received metadata for %s, but no advertised key imported cleanly", jid.to_string());
                clear_stale_xmpp_contact_key_if_not_advertised(account, jid, keys,
                        "stored XMPP key is no longer advertised");
            }
        }

        private void clear_stale_xmpp_contact_key(Account account, Jid jid, string reason) {
            if (!db.has_contact_xmpp_key(account, jid.bare_jid)) return;
            debug("XEP-0373: %s for %s; clearing stored XMPP key", reason, jid.to_string());
            db.clear_contact_xmpp_key(account, jid.bare_jid);
            key_cleared(account, jid.bare_jid);
        }

        private void clear_stale_xmpp_contact_key_if_not_advertised(Account account, Jid jid,
                Gee.List<Xmpp.Xep.OpenPgp.PublicKeyMeta> advertised_keys, string reason) {
            string? stored_key = db.get_contact_xmpp_key(account, jid.bare_jid);
            if (stored_key == null || ((!) stored_key).length == 0) return;
            foreach (var key_meta in advertised_keys) {
                if (fingerprint_or_keyid_matches((!) stored_key, key_meta.fingerprint)) {
                    debug("XEP-0373: Keeping stored XMPP key %s for %s; still advertised but not refreshed",
                            (!) stored_key, jid.to_string());
                    return;
                }
            }
            clear_stale_xmpp_contact_key(account, jid, reason);
        }
        
        private async bool fetch_and_import_key(Account account, XmppStream stream, Jid jid, string fingerprint, RequestGuard? guard = null) {
            // Check stream validity
            if (stream == null) {
                debug("XEP-0373: Stream is null in fetch_and_import_key");
                return false;
            }
            if (request_guard_cancelled(guard)) {
                debug("XEP-0373: Key request for %s was cancelled before fetching %s", jid.to_string(), fingerprint);
                return false;
            }
            if (stream_interactor.get_stream(account) != stream) {
                debug("XEP-0373: Stream changed before fetching key %s from %s", fingerprint, jid.to_string());
                return false;
            }
            
            Xmpp.Xep.OpenPgp.Module? module = stream.get_module(Xmpp.Xep.OpenPgp.Module.IDENTITY);
            if (module == null) return false;
            
            Xmpp.Xep.OpenPgp.PublicKeyData? key_data = yield module.fetch_public_key(stream, jid, fingerprint);
            if (request_guard_cancelled(guard)) {
                debug("XEP-0373: Key request for %s was cancelled after fetching %s", jid.to_string(), fingerprint);
                return false;
            }
            if (stream_interactor.get_stream(account) != stream) {
                debug("XEP-0373: Stream changed after fetching key %s from %s", fingerprint, jid.to_string());
                return false;
            }
            if (key_data == null) {
                debug("XEP-0373: No key data for %s from %s", fingerprint, jid.to_string());
                return false;
            }
            
            // Validate key format before importing
            string? key_data_base64 = key_data.key_data_base64;
            if (key_data_base64 == null || key_data_base64.length < 20) {
                debug("XEP-0373: Key too short or null for %s from %s", fingerprint, jid.to_string());
                return false;
            }
            
            // Import the key in background thread to avoid blocking
            debug("XEP-0373: About to import key %s from %s, base64 length=%d", fingerprint, jid.to_string(), key_data_base64.length);
            
            // Copy values for thread safety
            string key_data_copy = key_data_base64;
            string fp_copy = fingerprint;
            Jid jid_copy = jid;
            GPGHelper.ImportResult? import_result = null;
            SourceFunc callback = fetch_and_import_key.callback;

            new Thread<void*>("xep0373-import-key", () => {
                try {
                    import_result = GPGHelper.import_key_data_base64_with_result(key_data_copy);
                    if (import_result == null || !((!) import_result).imported) {
                        debug("XEP-0373: Key import returned false for %s from %s", fp_copy, jid_copy.to_string());
                    } else {
                        // import_key already invalidates the cache, but ensure it's done
                        GPGHelper.invalidate_secret_keys_cache();
                        debug("XEP-0373: Imported key %s from %s", fp_copy, jid_copy.to_string());
                    }
                } catch (Error import_err) {
                    // Don't crash on import errors, just log
                    debug("XEP-0373: Key import failed for %s: %s", fp_copy, import_err.message);
                }
                Idle.add((owned) callback);
                return null;
            });

            yield;
            if (request_guard_cancelled(guard)) {
                debug("XEP-0373: Key request for %s was cancelled after importing %s", jid_copy.to_string(), fp_copy);
                return false;
            }
            if (stream_interactor.get_stream(account) != stream) {
                debug("XEP-0373: Stream changed after importing key %s from %s", fp_copy, jid_copy.to_string());
                return false;
            }
            if (import_result != null && ((!) import_result).imported &&
                    imported_key_matches_or_exists((!) import_result, fp_copy)) {
                if (!imported_xmpp_key_is_usable(fp_copy, jid_copy.bare_jid.to_string())) {
                    reject_imported_xmpp_key(account, jid_copy, fp_copy,
                            "imported XMPP-published key is revoked, expired, not usable, or missing its xmpp: user ID");
                    return false;
                }
                key_received(account, jid_copy, fp_copy, key_data_copy);
                return true;
            } else if (import_result != null && ((!) import_result).imported) {
                reject_imported_xmpp_key(account, jid_copy, fp_copy,
                        "imported key data did not match the advertised XEP-0373 fingerprint");
            }
            return false;
        }

        private void reject_imported_xmpp_key(Account account, Jid jid, string fingerprint, string reason) {
            if (db.clear_contact_xmpp_key_if_matches(account, jid.bare_jid, fingerprint)) {
                warning("XEP-0373: %s; clearing stored XMPP key %s for %s",
                        reason, fingerprint, jid.to_string());
                key_cleared(account, jid.bare_jid);
            } else {
                warning("XEP-0373: %s; rejecting XMPP-published key %s from %s",
                        reason, fingerprint, jid.to_string());
            }
        }

        private static bool imported_key_matches_or_exists(GPGHelper.ImportResult result, string advertised_fingerprint) {
            if (import_result_matches_fingerprint(result, advertised_fingerprint)) return true;

            // If GnuPG already had the key unchanged, the import may succeed
            // without an IMPORT_OK fingerprint. Validate the advertised key
            // against the local keyring instead of treating a valid cached key
            // as stale.
            if (result.fingerprints.size == 0) {
                return imported_xmpp_key_is_usable(advertised_fingerprint);
            }
            return false;
        }

        private static bool imported_xmpp_key_is_usable(string fingerprint, string? bare_jid = null) {
            try {
                GPGHelper.Key? key = GPGHelper.get_public_key(fingerprint);
                if (key == null) return false;
                if (((!) key).revoked || ((!) key).expired || !((!) key).can_encrypt) return false;
                if (bare_jid != null && ((!) bare_jid).length > 0) {
                    bool key_uid_verified = false;
                    bool key_has_xmpp_uid = false;
                    try {
                        key_has_xmpp_uid = GPGHelper.key_has_xmpp_uid(fingerprint, (!) bare_jid);
                        key_uid_verified = true;
                    } catch (Error e) {
                        if (e is IOError.TIMED_OUT || e.message.contains("timed out")) {
                            debug("XEP-0373: Skipping strict XMPP UID validation for imported key %s after timeout", fingerprint);
                            return true;
                        }
                        debug("XEP-0373: Failed to validate imported key %s for bare JID %s: %s",
                                fingerprint, (!) bare_jid, e.message);
                        return false;
                    }
                    if (key_uid_verified) return key_has_xmpp_uid;
                    return false;
                }
                return true;
            } catch (Error e) {
                debug("XEP-0373: Failed to validate imported key %s: %s", fingerprint, e.message);
                return false;
            }
        }

        private static bool import_result_matches_fingerprint(GPGHelper.ImportResult result, string advertised_fingerprint) {
            foreach (string imported_fingerprint in result.fingerprints) {
                if (fingerprint_or_keyid_matches(advertised_fingerprint, imported_fingerprint)) {
                    return true;
                }
            }
            return false;
        }

        private static bool fingerprint_or_keyid_matches(string expected_key, string actual_key) {
            string expected = normalize_key_match_value(expected_key);
            string actual = normalize_key_match_value(actual_key);
            if (expected.length == 0 || actual.length == 0) return false;
            return expected == actual || expected.has_suffix(actual) || actual.has_suffix(expected);
        }

        private static string normalize_key_match_value(string value) {
            return value.up().replace(" ", "").replace("\t", "").replace("\r", "").replace("\n", "");
        }
        
        private string get_request_token(Account account, Jid jid) {
            return "%s\n%s".printf(account.bare_jid.to_string(), jid.bare_jid.to_string());
        }

        private string get_pending_retraction_token(Account account, string fingerprint) {
            return "%d\n%s".printf(account.id, normalize_key_match_value(fingerprint));
        }

        private void mark_pending_xmpp_key_retraction(Account account, string fingerprint) {
            if (fingerprint.length == 0) return;
            if (is_current_xmpp_key(account, fingerprint)) {
                discard_reactivated_key_retraction(account, fingerprint);
                return;
            }
            invalidate_own_key_publish(account, fingerprint);
            db.mark_pending_xmpp_key_retraction(account, fingerprint);
            debug("XEP-0373: Queued pending XMPP OpenPGP key retraction %s for %s",
                    fingerprint, account.bare_jid.to_string());
        }

        private void retry_pending_xmpp_key_retractions(Account account) {
            Gee.List<string> fingerprints = db.get_pending_xmpp_key_retractions(account);
            if (fingerprints.size == 0) return;

            debug("XEP-0373: Retrying %d pending XMPP OpenPGP key retraction(s) for %s",
                    fingerprints.size, account.bare_jid.to_string());
            foreach (string fingerprint in fingerprints) {
                retry_pending_xmpp_key_retraction.begin(account, fingerprint);
            }
        }

        private async void retry_pending_xmpp_key_retraction(Account account, string fingerprint) {
            if (is_current_xmpp_key(account, fingerprint)) {
                discard_reactivated_key_retraction(account, fingerprint);
                return;
            }
            string token = get_pending_retraction_token(account, fingerprint);
            pending_retraction_mutex.lock();
            if (pending_retraction_attempts.contains(token)) {
                pending_retraction_mutex.unlock();
                return;
            }
            pending_retraction_attempts.add(token);
            pending_retraction_mutex.unlock();

            bool retracted = yield retract_obsolete_published_key(account, fingerprint);
            if (retracted) {
                db.clear_pending_xmpp_key_retraction(account, fingerprint);
                debug("XEP-0373: Retried and cleared pending XMPP OpenPGP key retraction %s for %s",
                        fingerprint, account.bare_jid.to_string());
            } else {
                warning("XEP-0373: Pending XMPP OpenPGP key retraction %s for %s still failed",
                        fingerprint, account.bare_jid.to_string());
            }

            pending_retraction_mutex.lock();
            pending_retraction_attempts.remove(token);
            pending_retraction_mutex.unlock();
        }

        public void invalidate_lazy_key_request(Account account, Jid jid) {
            string token = get_request_token(account, jid.bare_jid);
            request_mutex.lock();
            session_key_requests.remove(token);
            request_mutex.unlock();
        }

        public async bool request_keys_if_needed(Account account, Jid jid) {
            Jid bare_jid = jid.bare_jid;
            string? existing_key = db.get_contact_xmpp_key(account, bare_jid);
            if (existing_key != null && existing_key.length > 0) {
                debug("XEP-0373: Verifying cached XMPP key for %s via lazy key request", bare_jid.to_string());
            }

            XmppStream? stream = stream_interactor.get_stream(account);
            if (stream == null) {
                debug("XEP-0373: Delaying lazy key request for %s; stream is not ready", bare_jid.to_string());
                return false;
            }

            Xmpp.Xep.OpenPgp.Module? module = stream.get_module(Xmpp.Xep.OpenPgp.Module.IDENTITY);
            if (module == null) {
                debug("XEP-0373: Delaying lazy key request for %s; module is not ready", bare_jid.to_string());
                return false;
            }

            string token = get_request_token(account, bare_jid);
            request_mutex.lock();
            if (pending_key_requests.contains(token) || session_key_requests.contains(token)) {
                request_mutex.unlock();
                debug("XEP-0373: Skipping duplicate lazy key request for %s", bare_jid.to_string());
                return false;
            }
            pending_key_requests.add(token);
            session_key_requests.add(token);
            request_mutex.unlock();

            bool imported = yield request_keys_uncached(account, bare_jid, false);

            request_mutex.lock();
            pending_key_requests.remove(token);
            request_mutex.unlock();

            return imported;
        }

        public async bool request_keys_with_guard(Account account, Jid jid, RequestGuard guard) {
            Jid bare_jid = jid.bare_jid;
            string token = get_request_token(account, bare_jid);
            request_mutex.lock();
            if (pending_key_requests.contains(token)) {
                request_mutex.unlock();
                debug("XEP-0373: Skipping duplicate guarded key request for %s", bare_jid.to_string());
                string? existing_key = db.get_contact_xmpp_key(account, bare_jid);
                return !guard.cancelled && existing_key != null && ((!) existing_key).length > 0;
            }
            pending_key_requests.add(token);
            request_mutex.unlock();

            bool imported = yield request_keys_uncached(account, bare_jid, true, guard);

            request_mutex.lock();
            pending_key_requests.remove(token);
            request_mutex.unlock();

            return !guard.cancelled && imported;
        }

        // Manually request keys from a contact. This path is used by explicit
        // OpenPGP actions, so it always performs the request instead of applying
        // the lazy-startup once-per-session filter.
        public async bool request_keys(Account account, Jid jid) {
            Jid bare_jid = jid.bare_jid;
            string token = get_request_token(account, bare_jid);
            request_mutex.lock();
            if (pending_key_requests.contains(token)) {
                request_mutex.unlock();
                debug("XEP-0373: Skipping duplicate explicit key request for %s", bare_jid.to_string());
                string? existing_key = db.get_contact_xmpp_key(account, bare_jid);
                return existing_key != null && ((!) existing_key).length > 0;
            }
            pending_key_requests.add(token);
            request_mutex.unlock();

            bool imported = yield request_keys_uncached(account, bare_jid, true);

            request_mutex.lock();
            pending_key_requests.remove(token);
            request_mutex.unlock();

            return imported;
        }

        // Incoming XEP-0374 stanzas are not passive UI readiness probes, so a
        // previous once-per-session lazy miss must not suppress the concrete
        // receive-time fetch.  Unlike explicit refresh, this automatic path must
        // not clear cached contact-key state just because remote metadata is
        // temporarily empty.
        public async bool request_keys_for_incoming_message(Account account, Jid jid) {
            Jid bare_jid = jid.bare_jid;
            string token = get_request_token(account, bare_jid);
            request_mutex.lock();
            if (pending_key_requests.contains(token)) {
                request_mutex.unlock();
                debug("XEP-0373: Skipping duplicate incoming-message key request for %s", bare_jid.to_string());
                string? existing_key = db.get_contact_xmpp_key(account, bare_jid);
                return existing_key != null && ((!) existing_key).length > 0;
            }
            pending_key_requests.add(token);
            request_mutex.unlock();

            bool imported = yield request_keys_uncached(account, bare_jid, false);

            request_mutex.lock();
            pending_key_requests.remove(token);
            request_mutex.unlock();

            return imported;
        }

        private async bool request_keys_uncached(Account account, Jid jid, bool clear_on_missing_remote, RequestGuard? guard = null) {
            XmppStream? stream = stream_interactor.get_stream(account);
            if (stream == null) {
                debug("XEP-0373: Cannot request keys - no stream for %s", account.bare_jid.to_string());
                return false;
            }
            
            Xmpp.Xep.OpenPgp.Module? module = stream.get_module(Xmpp.Xep.OpenPgp.Module.IDENTITY);
            if (module == null) {
                debug("XEP-0373: Cannot request keys - XEP-0373 module not loaded");
                return false;
            }
            
            debug("XEP-0373: Requesting keys from %s via PubSub node %s", jid.to_string(), "urn:xmpp:openpgp:0:public-keys");
            Gee.List<Xmpp.Xep.OpenPgp.PublicKeyMeta>? keys = yield module.fetch_public_keys_list(stream, jid);
            if (request_guard_cancelled(guard)) {
                debug("XEP-0373: Key request for %s was cancelled after metadata fetch", jid.to_string());
                return false;
            }
            if (stream_interactor.get_stream(account) != stream) {
                debug("XEP-0373: Stream changed after key list request for %s", jid.to_string());
                return false;
            }
            
            if (keys == null) {
                debug("XEP-0373: Key list request for %s did not return usable data", jid.to_string());
                return false;
            }

            if (keys.size == 0) {
                debug("XEP-0373: No keys found for %s (contact may not have published any)", jid.to_string());
                if (clear_on_missing_remote && !request_guard_cancelled(guard)) {
                    clear_stale_xmpp_contact_key(account, jid, "no published keys found");
                }
                return false;
            }
            
            debug("XEP-0373: Found %d key(s) for %s", keys.size, jid.to_string());
            
            bool imported_any = false;
            foreach (var key_meta in keys) {
                if (request_guard_cancelled(guard)) return false;
                if (yield fetch_and_import_key(account, stream, jid, key_meta.fingerprint, guard)) {
                    imported_any = true;
                }
            }
            if (!imported_any) {
                debug("XEP-0373: No advertised key from %s imported cleanly", jid.to_string());
                if (clear_on_missing_remote && !request_guard_cancelled(guard)) {
                    clear_stale_xmpp_contact_key_if_not_advertised(account, jid, keys,
                            "stored XMPP key is no longer advertised");
                }
            }
            return imported_any;
        }
        
        // Public method to republish our key (called when user changes key in settings)
        public virtual void republish_key(Account account) {
            if (db.get_account_key_mode(account) != Database.ACCOUNT_KEY_MODE_XMPP) {
                debug("XEP-0373: Not republishing stored XMPP key for %s; active OpenPGP mode is legacy",
                        account.bare_jid.to_string());
                return;
            }
            XmppStream? stream = stream_interactor.get_stream(account);
            if (stream == null) {
                debug("XEP-0373: Cannot republish key - no stream for %s", account.bare_jid.to_string());
                return;
            }
            string? key_id = db.get_account_xmpp_key(account);
            if (key_id == null || key_id.length == 0) {
                debug("XEP-0373: Cannot republish key - no XMPP-published key configured for %s", account.bare_jid.to_string());
                return;
            }
            
            debug("XEP-0373: Republishing key for account %s", account.bare_jid.to_string());
            publish_own_key_async.begin(account, stream);
        }

        public void replace_published_key(Account account, string? old_fingerprint, string? new_fingerprint = null) {
            replace_published_key_async.begin(account, old_fingerprint, new_fingerprint);
        }

        private async void replace_published_key_async(Account account, string? old_fingerprint, string? new_fingerprint = null) {
            if (old_fingerprint != null && ((!) old_fingerprint).length > 0 &&
                    (new_fingerprint == null || !fingerprint_or_keyid_matches((!) old_fingerprint, (!) new_fingerprint))) {
                bool retracted = yield retract_obsolete_published_key(account, (!) old_fingerprint);
                if (!retracted) {
                    mark_pending_xmpp_key_retraction(account, (!) old_fingerprint);
                    warning("XEP-0373: Failed to retract previous XMPP OpenPGP key %s for %s; will retry after reconnect",
                            (!) old_fingerprint, account.bare_jid.to_string());
                } else {
                    db.clear_pending_xmpp_key_retraction(account, (!) old_fingerprint);
                }
            }

            if (new_fingerprint != null && ((!) new_fingerprint).length > 0) {
                republish_key(account);
            }
        }

        /**
         * Retract (unpublish) a key from PubSub.
         * Called when the user revokes a key, so contacts no longer see it.
         */
        public async bool retract_published_key(Account account, string fingerprint) {
            invalidate_own_key_publish(account, fingerprint);
            yield acquire_own_key_mutation(account);
            try {
                XmppStream? stream = stream_interactor.get_stream(account);
                if (stream == null) {
                    debug("XEP-0373: Cannot retract key - no stream for %s", account.bare_jid.to_string());
                    return false;
                }

                Xmpp.Xep.OpenPgp.Module? module = stream.get_module(Xmpp.Xep.OpenPgp.Module.IDENTITY);
                if (module == null) {
                    debug("XEP-0373: Cannot retract key - XEP-0373 module not loaded");
                    return false;
                }

                debug("XEP-0373: Retracting key %s for account %s", fingerprint, account.bare_jid.to_string());
                bool retracted = yield module.unpublish_key(stream, fingerprint, () => {
                    return stream_interactor.get_stream(account) == stream;
                });
                return stream_interactor.get_stream(account) == stream && retracted;
            } finally {
                own_key_mutation_accounts.remove(account.id);
            }
        }

        // Automatic cleanup must not remove a key the user selected again while
        // offline or while a previous server request was still in flight.
        private async bool retract_obsolete_published_key(Account account, string fingerprint) {
            yield acquire_own_key_mutation(account);
            try {
                if (is_current_xmpp_key(account, fingerprint)) {
                    discard_reactivated_key_retraction(account, fingerprint);
                    return true;
                }
                invalidate_own_key_publish(account, fingerprint);
                XmppStream? stream = stream_interactor.get_stream(account);
                if (stream == null) return false;
                Xmpp.Xep.OpenPgp.Module? module = stream.get_module(Xmpp.Xep.OpenPgp.Module.IDENTITY);
                if (module == null) return false;
                string? selected_key = db.get_account_key(account);
                string selected_mode = db.get_account_key_mode(account);

                bool retracted = yield module.unpublish_key(stream, fingerprint, () => {
                    return stream_interactor.get_stream(account) == stream &&
                        !is_current_xmpp_key(account, fingerprint) &&
                        db.get_account_key_mode(account) == selected_mode && db.get_account_key(account) == selected_key;
                });
                if (is_current_xmpp_key(account, fingerprint)) {
                    // An already transmitted delete IQ cannot be recalled. Restore
                    // the selected key and metadata instead of persisting a retry.
                    discard_reactivated_key_retraction(account, fingerprint, true);
                    return true;
                }
                if (stream_interactor.get_stream(account) != stream) return false;
                return retracted;
            } finally {
                own_key_mutation_accounts.remove(account.id);
            }
        }

        /**
         * Fetch the synchronized secret key backup from PubSub
         */
        public async string? fetch_secret_key_backup(Account account) {
            XmppStream? stream = stream_interactor.get_stream(account);
            if (stream == null) return null;
            
            Xmpp.Xep.OpenPgp.Module? module = stream.get_module(Xmpp.Xep.OpenPgp.Module.IDENTITY);
            if (module == null) return null;
            
            return yield module.fetch_secret_key(stream);
        }

        public async string? fetch_secret_key_backup_checked(Account account) throws Error {
            XmppStream? stream = stream_interactor.get_stream(account);
            if (stream == null) throw new IOError.NOT_CONNECTED("Account is not connected");
            Xmpp.Xep.OpenPgp.Module? module = stream.get_module(Xmpp.Xep.OpenPgp.Module.IDENTITY);
            if (module == null) throw new IOError.NOT_SUPPORTED("OpenPGP for XMPP is unavailable on this connection");
            string? payload = yield module.fetch_secret_key_checked(stream);
            if (stream_interactor.get_stream(account) != stream) {
                throw new IOError.NOT_CONNECTED("Account connection changed during secret-key backup lookup");
            }
            return payload;
        }

        /**
         * Fetch the account's own published XEP-0373 public key data from PubSub.
         */
        public async string? fetch_own_public_key_data(Account account) {
            string? fingerprint = db.get_account_xmpp_key(account);
            if (fingerprint == null || ((!) fingerprint).length == 0) return null;

            XmppStream? stream = stream_interactor.get_stream(account);
            if (stream == null) return null;

            Xmpp.Xep.OpenPgp.Module? module = stream.get_module(Xmpp.Xep.OpenPgp.Module.IDENTITY);
            if (module == null) return null;

            Xmpp.Xep.OpenPgp.PublicKeyData? key_data = yield module.fetch_public_key(stream, account.bare_jid, (!) fingerprint);
            if (key_data == null) return null;
            return ((!) key_data).key_data_base64;
        }

        /**
         * Publish the encrypted secret key backup to PubSub
         */
        public async bool publish_secret_key_backup(Account account, string encrypted_base64) {
            yield acquire_secret_backup_mutation(account);
            try {
                XmppStream? stream = stream_interactor.get_stream(account);
                if (stream == null) return false;
                Xmpp.Xep.OpenPgp.Module? module = stream.get_module(Xmpp.Xep.OpenPgp.Module.IDENTITY);
                if (module == null) return false;
                bool published = yield module.publish_secret_key(stream, encrypted_base64);
                return stream_interactor.get_stream(account) == stream && published;
            } finally {
                secret_backup_mutation_accounts.remove(account.id);
            }
        }

        // The explicit account-level backup action and the key cleanup barrier
        // both remove only the payload they showed/validated to the user.
        public async bool retract_secret_key_backup_if_unchanged(Account account, string expected_base64) throws Error {
            yield acquire_secret_backup_mutation(account);
            try {
                return yield retract_secret_key_backup_if_unchanged_unlocked(account, expected_base64);
            } finally {
                secret_backup_mutation_accounts.remove(account.id);
            }
        }

        private async bool retract_secret_key_backup_if_unchanged_unlocked(Account account, string expected_base64) throws Error {
            XmppStream? stream = stream_interactor.get_stream(account);
            if (stream == null) throw new IOError.NOT_CONNECTED("Account is not connected");
            Xmpp.Xep.OpenPgp.Module? module = stream.get_module(Xmpp.Xep.OpenPgp.Module.IDENTITY);
            if (module == null) throw new IOError.NOT_SUPPORTED("OpenPGP for XMPP is unavailable on this connection");
            string? observation_digest = db.get_secret_key_backup_observation_digest(account);
            string? pending_fingerprint = db.get_pending_secret_key_backup_cleanup_fingerprint(account);
            string? pending_digest = db.get_pending_secret_key_backup_cleanup_digest(account);
            string? payload = yield module.fetch_secret_key_checked(stream);
            if (stream_interactor.get_stream(account) != stream) {
                throw new IOError.NOT_CONNECTED("Account connection changed before secret-key backup removal");
            }
            ensure_secret_backup_observation_unchanged(account, observation_digest, pending_fingerprint, pending_digest);
            if (payload == null) {
                db.forget_secret_key_backup(account);
                return true;
            }
            if ((!) payload != expected_base64) {
                throw new IOError.BUSY("The server backup changed; review the current backup before removing it");
            }
            bool deleted = yield module.delete_secret_key(stream);
            if (stream_interactor.get_stream(account) != stream) {
                throw new IOError.NOT_CONNECTED("Account connection changed during secret-key backup removal");
            }
            ensure_secret_backup_observation_unchanged(account, observation_digest, pending_fingerprint, pending_digest);
            if (deleted) db.forget_secret_key_backup(account);
            return deleted;
        }

        private void ensure_secret_backup_observation_unchanged(Account account, string? observation_digest,
                string? pending_fingerprint, string? pending_digest) throws Error {
            if (db.get_secret_key_backup_observation_digest(account) != observation_digest ||
                    db.get_pending_secret_key_backup_cleanup_fingerprint(account) != pending_fingerprint ||
                    db.get_pending_secret_key_backup_cleanup_digest(account) != pending_digest) {
                throw new IOError.BUSY("The local backup observation changed; review the current backup before continuing");
            }
        }

        public async SecretBackupCleanupResult cleanup_secret_key_backup_for_key(Account account, string fingerprint) throws Error {
            yield acquire_secret_backup_mutation(account);
            try {
                return yield cleanup_secret_key_backup_for_key_unlocked(account, fingerprint);
            } finally {
                secret_backup_mutation_accounts.remove(account.id);
            }
        }

        private async SecretBackupCleanupResult cleanup_secret_key_backup_for_key_unlocked(Account account, string fingerprint) throws Error {
            string? observation_digest = db.get_secret_key_backup_observation_digest(account);
            string? pending_fingerprint = db.get_pending_secret_key_backup_cleanup_fingerprint(account);
            string? pending_digest = db.get_pending_secret_key_backup_cleanup_digest(account);
            string? payload = yield fetch_secret_key_backup_checked(account);
            ensure_secret_backup_observation_unchanged(account, observation_digest, pending_fingerprint, pending_digest);
            if (payload == null) {
                db.forget_secret_key_backup(account);
                return SecretBackupCleanupResult.ABSENT;
            }
            Gee.List<string>? fingerprints = db.get_secret_key_backup_fingerprints(account, (!) payload);
            if (fingerprints == null) return SecretBackupCleanupResult.UNKNOWN;
            bool contains_key = false;
            foreach (string backed_up_fingerprint in (!) fingerprints) {
                if (normalize_key_match_value(backed_up_fingerprint) == normalize_key_match_value(fingerprint)) {
                    contains_key = true;
                }
            }
            if (!contains_key) return SecretBackupCleanupResult.UNRELATED;
            if (((!) fingerprints).size != 1) return SecretBackupCleanupResult.MULTIPLE;

            db.mark_pending_secret_key_backup_cleanup(account, fingerprint, (!) payload);
            bool deleted = yield retract_secret_key_backup_if_unchanged_unlocked(account, (!) payload);
            return deleted ? SecretBackupCleanupResult.DELETED : SecretBackupCleanupResult.FAILED;
        }

        private async void retry_pending_secret_key_backup_cleanup(Account account) {
            string? fingerprint = db.get_pending_secret_key_backup_cleanup_fingerprint(account);
            string? expected_digest = db.get_pending_secret_key_backup_cleanup_digest(account);
            if (fingerprint == null || expected_digest == null || pending_backup_cleanup_attempts.contains(account.id)) return;
            pending_backup_cleanup_attempts.add(account.id);
            try {
                yield acquire_secret_backup_mutation(account);
                if (db.get_pending_secret_key_backup_cleanup_fingerprint(account) != fingerprint ||
                        db.get_pending_secret_key_backup_cleanup_digest(account) != expected_digest) return;
                string? observation_digest = db.get_secret_key_backup_observation_digest(account);
                string? payload = yield fetch_secret_key_backup_checked(account);
                if (db.get_pending_secret_key_backup_cleanup_fingerprint(account) != fingerprint ||
                        db.get_pending_secret_key_backup_cleanup_digest(account) != expected_digest) return;
                ensure_secret_backup_observation_unchanged(account, observation_digest, fingerprint, expected_digest);
                if (payload == null) {
                    db.forget_secret_key_backup(account);
                    return;
                }
                Gee.List<string>? fingerprints = db.get_secret_key_backup_fingerprints(account, (!) payload);
                if (Checksum.compute_for_string(ChecksumType.SHA256, (!) payload) != expected_digest ||
                        fingerprints == null || ((!) fingerprints).size != 1 ||
                        normalize_key_match_value(((!) fingerprints)[0]) != normalize_key_match_value((!) fingerprint)) {
                    // A newer backup, even of the same key, is a new user action.
                    // Never let an old cleanup intent remove it or unrelated keys.
                    db.clear_pending_secret_key_backup_cleanup(account);
                    return;
                }
                bool deleted = yield retract_secret_key_backup_if_unchanged_unlocked(account, (!) payload);
                if (!deleted) warning("XEP-0373: Secret-key backup cleanup for %s remains pending", account.bare_jid.to_string());
            } catch (Error e) {
                warning("XEP-0373: Secret-key backup cleanup for %s could not be completed: %s",
                    account.bare_jid.to_string(), e.message);
            } finally {
                secret_backup_mutation_accounts.remove(account.id);
                pending_backup_cleanup_attempts.remove(account.id);
            }
        }
    }
}
