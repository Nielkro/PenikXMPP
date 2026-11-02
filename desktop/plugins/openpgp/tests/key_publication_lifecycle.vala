using Gee;
using Xmpp;
using Dino.Entities;
using Dino.Plugins.OpenPgp;

namespace OpenPgp.Test {

class KeyPublicationLifecycleTest : Gee.TestCase {
    private const string KEY_A = "AAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAA";
    private const string KEY_B = "BBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBB";
    private const string KEY_C = "CCCCCCCCCCCCCCCCCCCCCCCCCCCCCCCCCCCCCCCC";

    public KeyPublicationLifecycleTest() {
        base("KeyPublicationLifecycle");
        add_test("Reactivate_offline_discards_only_own_pending_retraction", () => run_case(0));
        add_test("Obsolete_key_cleanup_preserves_other_device_metadata", () => run_case(1));
        add_test("Reactivate_during_delete_fences_metadata_and_republishes", () => run_case(2));
        add_test("Publishing_merges_other_device_metadata", () => run_case(3));
        add_test("Backup_lookup_offline_is_error_not_absence", () => run_case(4));
        add_test("Key_cleanup_preserves_unknown_unrelated_and_multiple_backups", () => run_case(5));
        add_test("Failed_backup_cleanup_persists_and_retries_for_exact_account", () => run_case(6));
        add_test("Changed_backup_cancels_old_cleanup_intent", () => run_case(7));
        add_test("Conditional_backup_delete_rejects_changed_payload", () => run_case(8));
        add_test("Remembered_backup_and_bindings_remain_account_scoped", () => run_case(9));
        add_test("Backup_lookup_rejects_an_empty_result_for_another_node", () => run_case(10));
        add_test("Backup_lookup_rejects_duplicate_items_containers", () => run_case(11));
        add_test("Backup_lookup_rejects_unexpected_item_children", () => run_case(12));
        add_test("Delete_acknowledgement_preserves_newer_observation_and_intent", () => run_case(13));
        add_test("A_new_local_backup_waits_for_an_inflight_delete", () => run_case(14));
        add_test("Backup_lookup_rejects_a_foreign_response_sender", () => run_case(15));
        add_test("Backup_lookup_rejects_a_malformed_response_sender", () => run_case(16));
        add_test("Backup_lookup_accepts_implicit_own_sender", () => run_case(17));
        add_test("Backup_lookup_requires_completed_binding", () => run_case(18));
        add_test("Backup_lookup_rejects_binding_lost_before_response", () => run_case(19));
        add_test("Conversation_trust_XMPP_unknown_without_key", () => run_conversation_trust_case(0));
        add_test("Conversation_trust_XMPP_unverified_needs_attention", () => run_conversation_trust_case(1));
        add_test("Conversation_trust_XMPP_verified_matches_current_fingerprint", () => run_conversation_trust_case(2));
        add_test("Conversation_trust_XMPP_changed_fingerprint_loses_verification", () => run_conversation_trust_case(3));
        add_test("Conversation_trust_XMPP_retraction_ignores_legacy_fallback", () => run_conversation_trust_case(4));
        add_test("Conversation_trust_is_account_and_contact_scoped", () => run_conversation_trust_case(5));
        add_test("Conversation_trust_Legacy_never_claims_verification", () => run_conversation_trust_case(6));
        add_test("Conversation_trust_group_and_occupant_PM_are_unknown", () => run_conversation_trust_case(7));
        add_test("Conversation_trust_query_preserves_keys_and_trust", () => run_conversation_trust_case(8));
    }

    private void run_conversation_trust_case(int scenario) {
        LifecycleFixture? fixture = null;
        try {
            fixture = new LifecycleFixture();
            var db = ((!) fixture).db;
            var account = ((!) fixture).first;
            var other_account = ((!) fixture).second;
            var contact = new Jid("contact@example.test");
            var conversation = new Conversation(contact.with_resource("phone"), account, Conversation.Type.CHAT);
            var entry = new Dino.Plugins.OpenPgp.EncryptionListEntry(((!) fixture).interactor, db);
            entry.set_xep0373_manager(((!) fixture).manager);
            // These keys are cached test identifiers only: no GnuPG or key
            // discovery is needed to inspect a contact's stored trust state.
            switch (scenario) {
            case 0:
                fail_if(entry.get_conversation_trust(conversation) != Dino.Plugins.ConversationEncryptionTrust.UNKNOWN,
                    "Missing XMPP keys must not imply trust or trigger discovery");
                fail_if(db.has_contact_xmpp_key(account, contact),
                    "Reading trust must not create a contact key");
                break;
            case 1:
                db.set_contact_key(account, contact, KEY_A, Dino.Plugins.OpenPgp.Database.KEY_SOURCE_XEP0373);
                fail_if(entry.get_conversation_trust(conversation) != Dino.Plugins.ConversationEncryptionTrust.NEEDS_ATTENTION,
                    "An imported XMPP key without fingerprint verification needs attention");
                fail_if(db.contact_xmpp_key_is_verified(account, contact),
                    "Reading trust must not verify an imported key");
                break;
            case 2:
                db.set_contact_key(account, contact, KEY_A, Dino.Plugins.OpenPgp.Database.KEY_SOURCE_XEP0373);
                db.mark_contact_xmpp_key_verified(account, contact);
                fail_if(entry.get_conversation_trust(conversation) != Dino.Plugins.ConversationEncryptionTrust.VERIFIED,
                    "A resource-qualified chat must find the verified key of the same bare contact");
                // Trust is not send readiness: this fixture has no own key.
                fail_if(db.get_account_key(account) != null,
                    "A trust query must not configure an account key");
                break;
            case 3:
                db.set_contact_key(account, contact, KEY_A, Dino.Plugins.OpenPgp.Database.KEY_SOURCE_XEP0373);
                db.mark_contact_xmpp_key_verified(account, contact);
                db.set_contact_key(account, contact, KEY_B, Dino.Plugins.OpenPgp.Database.KEY_SOURCE_XEP0373);
                fail_if(entry.get_conversation_trust(conversation) != Dino.Plugins.ConversationEncryptionTrust.NEEDS_ATTENTION,
                    "A changed fingerprint must not inherit verification from the old key");
                fail_if_not_eq_str(db.get_contact_xmpp_trust_state(account, contact),
                    Dino.Plugins.OpenPgp.Database.XMPP_TRUST_CHANGED,
                    "Inspecting a changed key must preserve the need for review");
                break;
            case 4:
                db.set_contact_key(account, contact, KEY_A, Dino.Plugins.OpenPgp.Database.KEY_SOURCE_XEP0373);
                db.mark_contact_xmpp_key_verified(account, contact);
                db.set_contact_key(account, contact, KEY_B, Dino.Plugins.OpenPgp.Database.KEY_SOURCE_XEP0027);
                db.clear_contact_xmpp_key(account, contact);
                fail_if(entry.get_conversation_trust(conversation) != Dino.Plugins.ConversationEncryptionTrust.UNKNOWN,
                    "A retracted XMPP key must not fall back to an announced legacy key or remembered verification");
                fail_if(db.has_contact_xmpp_key(account, contact),
                    "Reading trust must not restore a retracted XMPP key");
                fail_if_not_eq_str(db.get_contact_legacy_key(account, contact) ?? "", KEY_B,
                    "Reading XMPP trust must preserve the separate legacy key");
                break;
            case 5:
                db.set_contact_key(account, contact, KEY_A, Dino.Plugins.OpenPgp.Database.KEY_SOURCE_XEP0373);
                db.mark_contact_xmpp_key_verified(account, contact);
                var other_conversation = new Conversation(contact, other_account, Conversation.Type.CHAT);
                fail_if(entry.get_conversation_trust(other_conversation) != Dino.Plugins.ConversationEncryptionTrust.UNKNOWN,
                    "One account's verified key must not supply a missing key for another account");
                db.set_contact_key(other_account, contact, KEY_A, Dino.Plugins.OpenPgp.Database.KEY_SOURCE_XEP0373);
                fail_if(entry.get_conversation_trust(other_conversation) != Dino.Plugins.ConversationEncryptionTrust.NEEDS_ATTENTION,
                    "The same fingerprint still needs an independent verification for another account");
                var other_contact = new Jid("different@example.test");
                db.set_contact_key(account, other_contact, KEY_A, Dino.Plugins.OpenPgp.Database.KEY_SOURCE_XEP0373);
                fail_if(entry.get_conversation_trust(new Conversation(other_contact, account, Conversation.Type.CHAT)) !=
                        Dino.Plugins.ConversationEncryptionTrust.NEEDS_ATTENTION,
                    "Verification must not transfer to another contact using the same fingerprint");
                fail_if(entry.get_conversation_trust(conversation) != Dino.Plugins.ConversationEncryptionTrust.VERIFIED,
                    "Reading another account or contact must not change the original verification");
                break;
            case 6:
                db.set_contact_key(account, contact, KEY_A, Dino.Plugins.OpenPgp.Database.KEY_SOURCE_XEP0373);
                db.mark_contact_xmpp_key_verified(account, contact);
                db.set_contact_key(account, contact, KEY_B, Dino.Plugins.OpenPgp.Database.KEY_SOURCE_MANUAL);
                db.set_account_legacy_key(account, KEY_C);
                fail_if(entry.get_conversation_trust(conversation) != Dino.Plugins.ConversationEncryptionTrust.UNKNOWN,
                    "A stored but unannounced legacy key is not an active trusted recipient");
                db.set_contact_legacy_key_announced(account, contact, true);
                fail_if(entry.get_conversation_trust(conversation) != Dino.Plugins.ConversationEncryptionTrust.TRUSTED,
                    "An announced legacy key must never inherit XMPP fingerprint verification");
                db.set_account_xmpp_key(account, KEY_C);
                fail_if(entry.get_conversation_trust(conversation) != Dino.Plugins.ConversationEncryptionTrust.VERIFIED,
                    "Returning to XMPP mode must retain its separate contact verification");
                break;
            case 7:
                db.set_contact_key(account, contact, KEY_A, Dino.Plugins.OpenPgp.Database.KEY_SOURCE_XEP0373);
                db.mark_contact_xmpp_key_verified(account, contact);
                fail_if(entry.get_conversation_trust(new Conversation(contact, account, Conversation.Type.GROUPCHAT)) !=
                        Dino.Plugins.ConversationEncryptionTrust.UNKNOWN,
                    "A room address matching a verified direct contact is not a verified recipient aggregate");
                fail_if(entry.get_conversation_trust(new Conversation(contact.with_resource("nick"), account,
                        Conversation.Type.GROUPCHAT_PM)) != Dino.Plugins.ConversationEncryptionTrust.UNKNOWN,
                    "A room nickname must not inherit a direct contact's key verification");
                break;
            case 8:
                db.set_account_xmpp_key(account, KEY_C);
                db.set_contact_key(account, contact, KEY_A, Dino.Plugins.OpenPgp.Database.KEY_SOURCE_XEP0373);
                db.mark_contact_xmpp_key_verified(account, contact);
                db.set_contact_key(account, contact, KEY_B, Dino.Plugins.OpenPgp.Database.KEY_SOURCE_XEP0027);
                long before_updated_at = db.get_contact_xmpp_trust_updated_at(account, contact);
                for (int i = 0; i < 3; i++) {
                    fail_if(entry.get_conversation_trust(conversation) != Dino.Plugins.ConversationEncryptionTrust.VERIFIED,
                        "Repeated trust reads must preserve the cached verification");
                }
                fail_if_not_eq_str(db.get_contact_xmpp_key(account, contact) ?? "", KEY_A,
                    "Trust inspection must preserve the current XMPP key");
                fail_if_not_eq_str(db.get_contact_xmpp_verified_fingerprint(account, contact) ?? "", KEY_A,
                    "Trust inspection must preserve the exact verified fingerprint");
                fail_if_not_eq_str(db.get_contact_legacy_key(account, contact) ?? "", KEY_B,
                    "Trust inspection must preserve the separate legacy key");
                fail_if(!db.contact_legacy_key_is_announced(account, contact) ||
                        db.get_contact_xmpp_trust_updated_at(account, contact) != before_updated_at,
                    "Trust inspection must not rewrite announcements or verification timestamps");
                fail_if(((!) fixture).manager.republish_count != 0,
                    "Inspecting cached trust must never republish the account key");
                break;
            }
        } catch (Error error) {
            GLib.Test.message("OpenPGP cached-trust fixture failed: %s", error.message);
            GLib.Test.fail();
        } finally {
            if (fixture != null) ((!) fixture).close();
        }
    }

    private void run_case(int scenario) {
        var loop = new MainLoop();
        bool finished = false;
        run_case_async.begin(scenario, (_, result) => {
            try {
                run_case_async.end(result);
            } catch (Error error) {
                GLib.Test.message("OpenPGP lifecycle fixture failed: %s", error.message);
                GLib.Test.fail();
            }
            finished = true;
            loop.quit();
        });
        if (!finished) loop.run();
    }

    private async void pause() {
        SourceFunc resume = pause.callback;
        Timeout.add(1, (owned) resume);
        yield;
    }

    private async void wait_for_retraction(LifecycleFixture fixture, Account account) throws Error {
        int64 deadline = get_monotonic_time() + 2 * 1000 * 1000;
        while (fixture.db.get_pending_xmpp_key_retractions(account).size > 0) {
            if (get_monotonic_time() > deadline) throw new IOError.TIMED_OUT("Pending key retraction did not complete");
            yield pause();
        }
    }

    private async void wait_for_backup_cleanup(LifecycleFixture fixture, Account account) throws Error {
        int64 deadline = get_monotonic_time() + 2 * 1000 * 1000;
        while (fixture.db.get_pending_secret_key_backup_cleanup_fingerprint(account) != null) {
            if (get_monotonic_time() > deadline) throw new IOError.TIMED_OUT("Pending secret backup cleanup did not complete");
            yield pause();
        }
    }

    private async void run_case_async(int scenario) throws Error {
        var fixture = new LifecycleFixture();
        var account = fixture.first;
        var other_account = fixture.second;
        var stream = fixture.first_stream;
        var other_stream = fixture.second_stream;
        var manager = fixture.manager;
        var db = fixture.db;
        try {
            switch (scenario) {
            case 0: {
                db.set_account_xmpp_key(account, KEY_A);
                db.mark_pending_xmpp_key_retraction(account, KEY_A);
                db.set_account_xmpp_key(account, KEY_B);
                db.set_account_xmpp_key(account, KEY_A);
                db.mark_pending_xmpp_key_retraction(other_account, KEY_A);
                fixture.attach_stream(account, stream);
                fixture.negotiate(account, stream);
                fail_if(db.get_pending_xmpp_key_retractions(account).size != 0,
                    "A reselected key must discard its stale cleanup intent");
                fail_if(stream.deleted_nodes.size != 0,
                    "Reconnect must not transmit a delete for the active key");
                fail_if(db.get_pending_xmpp_key_retractions(other_account).size != 1,
                    "Discarding one account's retraction must not touch another account");
                break;
            }
            case 1: {
                db.set_account_xmpp_key(account, KEY_B);
                db.mark_pending_xmpp_key_retraction(account, KEY_A);
                stream.metadata.add(KEY_A);
                stream.metadata.add(KEY_C);
                fixture.attach_stream(account, stream);
                fixture.negotiate(account, stream);
                yield wait_for_retraction(fixture, account);
                fail_if(!stream.deleted_nodes.contains(Xmpp.Xep.OpenPgp.NS_URI_PUBKEYS + ":" + KEY_A),
                    "An obsolete own key must be removed");
                fail_if(stream.metadata.size != 1 || !stream.metadata.contains(KEY_C),
                    "Removing an obsolete key must preserve other-device keys");
                break;
            }
            case 2: {
                db.set_account_xmpp_key(account, KEY_B);
                db.mark_pending_xmpp_key_retraction(account, KEY_A);
                stream.metadata.add(KEY_A);
                stream.metadata.add(KEY_C);
                stream.hold_public_delete = true;
                fixture.attach_stream(account, stream);
                fixture.negotiate(account, stream);
                int64 deadline = get_monotonic_time() + 2 * 1000 * 1000;
                while (stream.held_delete == null) {
                    if (get_monotonic_time() > deadline) throw new IOError.TIMED_OUT("Public-key delete was never transmitted");
                    yield pause();
                }
                db.set_account_xmpp_key(account, KEY_A);
                stream.complete_held_delete();
                yield wait_for_retraction(fixture, account);
                fail_if(stream.metadata_publish_count != 0,
                    "A late delete acknowledgement must not clear the newly reactivated key's metadata");
                fail_if(manager.republish_count != 1,
                    "An already transmitted delete must be compensated by republishing the selected key");
                break;
            }
            case 3: {
                stream.metadata.add(KEY_C);
                fixture.attach_stream(account, stream);
                bool published = yield stream.get_module<Xmpp.Xep.OpenPgp.Module>(Xmpp.Xep.OpenPgp.Module.IDENTITY)
                    .publish_key_data(stream, KEY_A, "isolated-public-key-payload");
                fail_if(!published || stream.metadata.size != 2 ||
                        !stream.metadata.contains(KEY_A) || !stream.metadata.contains(KEY_C),
                    "Publishing a selected key must retain existing account keys from other devices");
                break;
            }
            case 4: {
                bool rejected = false;
                try {
                    yield manager.fetch_secret_key_backup_checked(account);
                } catch (IOError.NOT_CONNECTED error) {
                    rejected = true;
                }
                fail_if(!rejected, "A disconnected account cannot establish that its server backup is absent");
                break;
            }
            case 5: {
                fixture.attach_stream(account, stream);
                stream.secret_payload = "backup-A";
                var fingerprints = new ArrayList<string>();
                fingerprints.add(KEY_A);
                db.remember_secret_key_backup(account, "backup-A", fingerprints);
                var cleanup = yield manager.cleanup_secret_key_backup_for_key(account, KEY_B);
                fail_if(cleanup != SecretBackupCleanupResult.UNRELATED || stream.secret_delete_count != 0,
                    "Revoking B must not remove the backup of A");
                fingerprints.add(KEY_B);
                db.remember_secret_key_backup(account, "backup-A", fingerprints);
                cleanup = yield manager.cleanup_secret_key_backup_for_key(account, KEY_B);
                fail_if(cleanup != SecretBackupCleanupResult.MULTIPLE || stream.secret_delete_count != 0,
                    "A multi-key backup needs an explicit account-wide decision");
                db.forget_secret_key_backup(account);
                cleanup = yield manager.cleanup_secret_key_backup_for_key(account, KEY_A);
                fail_if(cleanup != SecretBackupCleanupResult.UNKNOWN || stream.secret_delete_count != 0,
                    "An unknown encrypted backup must not be deleted on an assumed fingerprint");
                stream.secret_payload = null;
                cleanup = yield manager.cleanup_secret_key_backup_for_key(account, KEY_A);
                fail_if(cleanup != SecretBackupCleanupResult.ABSENT,
                    "A successful empty server lookup must be distinguishable from an unknown payload");
                break;
            }
            case 6: {
                fixture.attach_stream(account, stream);
                fixture.attach_stream(other_account, other_stream);
                stream.secret_payload = "backup-A";
                other_stream.secret_payload = "backup-A";
                var fingerprints = new ArrayList<string>();
                fingerprints.add(KEY_A);
                db.remember_secret_key_backup(account, "backup-A", fingerprints);
                db.remember_secret_key_backup(other_account, "backup-A", fingerprints);
                db.mark_pending_secret_key_backup_cleanup(other_account, KEY_A, "backup-A");
                stream.fail_secret_delete = true;
                var cleanup = yield manager.cleanup_secret_key_backup_for_key(account, KEY_A);
                fail_if(cleanup != SecretBackupCleanupResult.FAILED ||
                        db.get_pending_secret_key_backup_cleanup_fingerprint(account) != KEY_A,
                    "A failed server delete must remain a pending cleanup instead of success");
                stream.fail_secret_delete = false;
                fixture.negotiate(account, stream);
                yield wait_for_backup_cleanup(fixture, account);
                fail_if(stream.secret_payload != null || stream.secret_delete_count != 2,
                    "Reconnect must retry the exact remembered single-key backup");
                fail_if(db.get_pending_secret_key_backup_cleanup_fingerprint(other_account) != KEY_A ||
                        other_stream.secret_delete_count != 0,
                    "Retrying one account must preserve another account's pending backup and payload");
                break;
            }
            case 7: {
                fixture.attach_stream(account, stream);
                var fingerprints = new ArrayList<string>();
                fingerprints.add(KEY_A);
                db.remember_secret_key_backup(account, "old-backup", fingerprints);
                db.mark_pending_secret_key_backup_cleanup(account, KEY_A, "old-backup");
                stream.secret_payload = "new-backup";
                fixture.negotiate(account, stream);
                yield wait_for_backup_cleanup(fixture, account);
                fail_if(stream.secret_delete_count != 0 || stream.secret_payload != "new-backup",
                    "A remote replacement must cancel the old cleanup intent without deleting the new payload");
                db.mark_pending_secret_key_backup_cleanup(account, KEY_A, "old-backup");
                db.remember_secret_key_backup(account, "new-backup", fingerprints);
                fail_if(db.get_pending_secret_key_backup_cleanup_fingerprint(account) != null,
                    "Remembering a new explicit backup must invalidate an old pending cleanup");
                break;
            }
            case 8: {
                fixture.attach_stream(account, stream);
                stream.secret_payload = "new-backup";
                bool changed_rejected = false;
                try {
                    yield manager.retract_secret_key_backup_if_unchanged(account, "old-backup");
                } catch (IOError.BUSY error) {
                    changed_rejected = true;
                }
                fail_if(!changed_rejected || stream.secret_delete_count != 0,
                    "Conditional account-wide backup removal must reject a changed payload");
                stream.fail_secret_lookup = true;
                bool lookup_rejected = false;
                try {
                    yield manager.fetch_secret_key_backup_checked(account);
                } catch (IOError.FAILED error) {
                    lookup_rejected = true;
                }
                fail_if(!lookup_rejected,
                    "A rejected server lookup must not be interpreted as an absent backup");
                break;
            }
            case 9: {
                db.bind_private_key_to_account(account, KEY_A);
                db.bind_private_key_to_account(other_account, KEY_A);
                db.unbind_private_key_from_account(account, KEY_A);
                fail_if(db.get_account_private_key_bindings(account).size != 0 ||
                        db.get_account_private_key_bindings(other_account).size != 1,
                    "Removing one account's manual assignment must preserve another account's assignment");
                fail_if(!db.key_has_other_account_users(account, KEY_A),
                    "Destructive local key actions must see manual assignments on another account");
                var fingerprints = new ArrayList<string>();
                fingerprints.add(KEY_A);
                db.remember_secret_key_backup(account, "same-backup", fingerprints);
                db.remember_secret_key_backup(other_account, "same-backup", fingerprints);
                db.mark_pending_secret_key_backup_cleanup(other_account, KEY_A, "same-backup");
                db.forget_secret_key_backup(account);
                fail_if(db.get_secret_key_backup_fingerprints(account, "same-backup") != null ||
                        db.get_secret_key_backup_fingerprints(other_account, "same-backup") == null ||
                        db.get_pending_secret_key_backup_cleanup_fingerprint(other_account) != KEY_A,
                    "Backup observations and cleanup intents must be isolated by account ID");
                break;
            }
            case 10:
            case 11:
            case 12: {
                fixture.attach_stream(account, stream);
                stream.secret_response_variant = scenario - 9;
                bool malformed_rejected = false;
                try {
                    yield manager.fetch_secret_key_backup_checked(account);
                } catch (IOError.INVALID_DATA error) {
                    malformed_rejected = true;
                }
                fail_if(!malformed_rejected,
                    "A malformed successful response must not establish that a backup is absent");
                break;
            }
            case 13: {
                fixture.attach_stream(account, stream);
                stream.secret_payload = "old-backup";
                stream.hold_secret_delete = true;
                var old_fingerprints = new ArrayList<string>();
                old_fingerprints.add(KEY_A);
                db.remember_secret_key_backup(account, "old-backup", old_fingerprints);
                db.mark_pending_secret_key_backup_cleanup(account, KEY_A, "old-backup");
                bool finished = false;
                bool stale_rejected = false;
                Error? unexpected = null;
                manager.retract_secret_key_backup_if_unchanged.begin(account, "old-backup", (_, result) => {
                    try {
                        manager.retract_secret_key_backup_if_unchanged.end(result);
                    } catch (IOError.BUSY error) {
                        stale_rejected = true;
                    } catch (Error error) {
                        unexpected = error;
                    }
                    finished = true;
                });
                int64 deadline = get_monotonic_time() + 2 * 1000 * 1000;
                while (stream.held_secret_delete == null) {
                    if (get_monotonic_time() > deadline) throw new IOError.TIMED_OUT("Secret backup delete was never transmitted");
                    yield pause();
                }
                var new_fingerprints = new ArrayList<string>();
                new_fingerprints.add(KEY_B);
                stream.secret_payload = "new-backup";
                db.remember_secret_key_backup(account, "new-backup", new_fingerprints);
                db.mark_pending_secret_key_backup_cleanup(account, KEY_B, "new-backup");
                stream.complete_held_secret_delete();
                while (!finished) {
                    if (get_monotonic_time() > deadline) throw new IOError.TIMED_OUT("Held secret backup delete did not complete");
                    yield pause();
                }
                if (unexpected != null) throw (!) unexpected;
                fail_if(!stale_rejected || db.get_secret_key_backup_fingerprints(account, "new-backup") == null ||
                        db.get_pending_secret_key_backup_cleanup_fingerprint(account) != KEY_B,
                    "A delayed delete acknowledgement must preserve a newer backup observation and cleanup intent");
                break;
            }
            case 14: {
                fixture.attach_stream(account, stream);
                stream.secret_payload = "old-backup";
                stream.hold_secret_delete = true;
                bool delete_finished = false;
                bool publish_finished = false;
                bool deleted = false;
                bool published = false;
                Error? unexpected = null;
                manager.retract_secret_key_backup_if_unchanged.begin(account, "old-backup", (_, result) => {
                    try {
                        deleted = manager.retract_secret_key_backup_if_unchanged.end(result);
                    } catch (Error error) {
                        unexpected = error;
                    }
                    delete_finished = true;
                });
                int64 deadline = get_monotonic_time() + 2 * 1000 * 1000;
                while (stream.held_secret_delete == null) {
                    if (get_monotonic_time() > deadline) throw new IOError.TIMED_OUT("Secret backup delete was never transmitted");
                    yield pause();
                }
                manager.publish_secret_key_backup.begin(account, "new-backup", (_, result) => {
                    published = manager.publish_secret_key_backup.end(result);
                    if (published) {
                        var fingerprints = new ArrayList<string>();
                        fingerprints.add(KEY_B);
                        db.remember_secret_key_backup(account, "new-backup", fingerprints);
                    }
                    publish_finished = true;
                });
                for (int waiting_tick = 0; waiting_tick < 20; waiting_tick++) yield pause();
                fail_if(stream.secret_publish_count != 0 || publish_finished,
                    "A new local backup must wait until an older delete has finished");
                stream.complete_held_secret_delete();
                while (!delete_finished || !publish_finished) {
                    if (get_monotonic_time() > deadline) throw new IOError.TIMED_OUT("Serialized secret backup mutations did not complete");
                    yield pause();
                }
                if (unexpected != null) throw (!) unexpected;
                fail_if(!deleted || !published || stream.secret_payload != "new-backup" ||
                        db.get_secret_key_backup_fingerprints(account, "new-backup") == null,
                    "The latest successful backup must remain present on the server and in the account observation");
                break;
            }
            case 15: {
                fixture.attach_stream(account, stream);
                stream.reply_sender_override = "foreign@example.test";
                bool foreign_rejected = false;
                try {
                    yield manager.fetch_secret_key_backup_checked(account);
                } catch (IOError.PERMISSION_DENIED error) {
                    foreign_rejected = true;
                }
                fail_if(!foreign_rejected, "A foreign sender must not establish absence of an account's secret backup");
                break;
            }
            case 16: {
                fixture.attach_stream(account, stream);
                stream.reply_sender_override = "first@";
                bool malformed_rejected = false;
                try {
                    yield manager.fetch_secret_key_backup_checked(account);
                } catch (IOError.INVALID_DATA error) {
                    malformed_rejected = true;
                }
                fail_if(!malformed_rejected, "An invalid raw sender must not be accepted through Stanza.from fallback");
                break;
            }
            case 17: {
                fixture.attach_stream(account, stream);
                stream.omit_reply_sender = true;
                stream.secret_payload = "owner-backup";
                string? payload = yield manager.fetch_secret_key_backup_checked(account);
                fail_if(payload != "owner-backup", "The server may omit the own bare-JID sender according to RFC 6120");
                break;
            }
            case 18: {
                fixture.attach_stream(account, stream);
                Bind.Flag? bind = stream.get_flag(Bind.Flag.IDENTITY);
                ((!) bind).finished = false;
                bool unbound_rejected = false;
                try {
                    yield manager.fetch_secret_key_backup_checked(account);
                } catch (IOError.NOT_CONNECTED error) {
                    unbound_rejected = true;
                }
                fail_if(!unbound_rejected, "A provisional unbound stream must not perform an owner backup lookup");
                break;
            }
            case 19: {
                fixture.attach_stream(account, stream);
                stream.drop_binding_on_reply = true;
                bool disconnected_rejected = false;
                try {
                    yield manager.fetch_secret_key_backup_checked(account);
                } catch (IOError.NOT_CONNECTED error) {
                    disconnected_rejected = true;
                }
                fail_if(!disconnected_rejected, "A completed backup response must be discarded when the account binding was lost");
                break;
            }
            }
        } finally {
            fixture.close();
        }
    }

    private class LifecycleFixture : Object {
        public Dino.Database core_db;
        public Dino.Plugins.OpenPgp.Database db;
        public Dino.StreamInteractor interactor;
        public Account first;
        public Account second;
        public LifecycleManager manager;
        public LifecycleStream first_stream;
        public LifecycleStream second_stream;

        public LifecycleFixture() throws Error {
            core_db = new Dino.Database(":memory:", "isolated-openpgp-lifecycle");
            db = new Dino.Plugins.OpenPgp.Database(":memory:", null);
            interactor = new Dino.StreamInteractor.for_tests(core_db);
            first = new Account(new Jid("first@example.test"), "secret");
            second = new Account(new Jid("second@example.test"), "secret");
            first.persist(core_db);
            second.persist(core_db);
            first_stream = new LifecycleStream(first.bare_jid);
            second_stream = new LifecycleStream(second.bare_jid);
            manager = new LifecycleManager(interactor, db);
        }

        public void attach_stream(Account account, LifecycleStream stream) {
            interactor.connection_manager.set_connected_stream_for_tests(account, stream);
        }

        public void negotiate(Account account, LifecycleStream stream) {
            interactor.stream_negotiated(account, stream);
        }

        public void close() {
            first_stream.detach_responder();
            second_stream.detach_responder();
            db.close();
            core_db.close();
        }
    }

    private class LifecycleManager : Xep0373KeyManager {
        public int republish_count = 0;

        public LifecycleManager(Dino.StreamInteractor interactor, Dino.Plugins.OpenPgp.Database db) {
            base(interactor, db);
            auto_publish_own_key = false;
        }

        // No GnuPG process or real keyring access in lifecycle/transport tests.
        public override void republish_key(Account account) {
            republish_count++;
        }
    }

    private class LifecycleStream : XmppStream {
        private const string OWNER_NS = "http://jabber.org/protocol/pubsub#owner";
        public ArrayList<string> metadata = new ArrayList<string>();
        public ArrayList<string> deleted_nodes = new ArrayList<string>();
        public int metadata_publish_count = 0;
        public int secret_delete_count = 0;
        public int secret_publish_count = 0;
        public int secret_response_variant = 0;
        public string? reply_sender_override = null;
        public bool omit_reply_sender = false;
        public bool drop_binding_on_reply = false;
        public string? secret_payload = null;
        public bool fail_secret_delete = false;
        public bool fail_secret_lookup = false;
        public bool hold_public_delete = false;
        public bool hold_secret_delete = false;
        public StanzaNode? held_delete = null;
        public StanzaNode? held_secret_delete = null;
        private bool responding = true;

        public LifecycleStream(Jid owner) {
            base(owner.domain_jid);
            var iq = new Iq.Module();
            add_module(iq);
            iq.attach(this);
            add_module(new Xmpp.Xep.Pubsub.Module());
            add_module(new Xmpp.Xep.OpenPgp.Module());
            var bind = new Bind.Flag();
            bind.my_jid = owner;
            bind.finished = true;
            add_flag(bind);
        }

        public void detach_responder() {
            responding = false;
        }

        public override async void connect() throws IOError { }
        public override async void disconnect() throws IOError { }
        public override async void setup() throws IOError { }
        public override async StanzaNode read() throws IOError {
            throw new IOError.NOT_CONNECTED("isolated stream has no reader");
        }

        public override async void write_async(StanzaNode node, int io_priority = Priority.DEFAULT,
                Cancellable? cancellable = null) throws IOError {
            if (cancellable != null) cancellable.set_error_if_cancelled();
            if (!responding || node.name != "iq") return;
            StanzaNode? owner_pubsub = node.get_subnode("pubsub", OWNER_NS);
            StanzaNode? delete = owner_pubsub != null ? ((!) owner_pubsub).get_subnode("delete", OWNER_NS) : null;
            if (delete != null) {
                string deleted_node = ((!) delete).get_attribute("node") ?? "";
                if (deleted_node == Xmpp.Xep.OpenPgp.NS_URI_SECRET_KEY) {
                    secret_delete_count++;
                    if (!fail_secret_delete) secret_payload = null;
                    if (hold_secret_delete) held_secret_delete = node;
                    else send_reply(node, null, fail_secret_delete);
                } else {
                    deleted_nodes.add(deleted_node);
                    if (hold_public_delete) held_delete = node;
                    else send_reply(node);
                }
                return;
            }
            StanzaNode? pubsub = node.get_subnode("pubsub", Xmpp.Xep.Pubsub.NS_URI);
            if (pubsub == null) throw new IOError.INVALID_DATA("Unexpected non-PubSub request in lifecycle fixture");
            StanzaNode? items_request = ((!) pubsub).get_subnode("items", Xmpp.Xep.Pubsub.NS_URI);
            if (items_request != null) {
                string requested_node = ((!) items_request).get_attribute("node") ?? "";
                var response_pubsub = new StanzaNode.build("pubsub", Xmpp.Xep.Pubsub.NS_URI).add_self_xmlns();
                var items = new StanzaNode.build("items", Xmpp.Xep.Pubsub.NS_URI).put_attribute("node", requested_node);
                response_pubsub.put_node(items);
                if (requested_node == Xmpp.Xep.OpenPgp.NS_URI_PUBKEYS) {
                    var list = new StanzaNode.build("public-keys-list", Xmpp.Xep.OpenPgp.NS_URI).add_self_xmlns();
                    foreach (string fingerprint in metadata) {
                        list.put_node(new StanzaNode.build("pubkey-metadata", Xmpp.Xep.OpenPgp.NS_URI)
                            .put_attribute("v4-fingerprint", fingerprint));
                    }
                    items.put_node(new StanzaNode.build("item", Xmpp.Xep.Pubsub.NS_URI)
                        .put_attribute("id", "current").put_node(list));
                    send_reply(node, response_pubsub);
                } else if (requested_node == Xmpp.Xep.OpenPgp.NS_URI_SECRET_KEY) {
                    if (secret_response_variant == 1) items.set_attribute("node", "unrelated-node");
                    if (secret_response_variant == 2) {
                        response_pubsub.put_node(new StanzaNode.build("items", Xmpp.Xep.Pubsub.NS_URI)
                            .put_attribute("node", requested_node));
                    }
                    if (secret_response_variant == 3) {
                        items.put_node(new StanzaNode.build("unexpected", Xmpp.Xep.Pubsub.NS_URI));
                    }
                    if (secret_payload != null) {
                        items.put_node(new StanzaNode.build("item", Xmpp.Xep.Pubsub.NS_URI)
                            .put_attribute("id", "current")
                            .put_node(new StanzaNode.build("secretkey", Xmpp.Xep.OpenPgp.NS_URI).add_self_xmlns()
                                .put_node(new StanzaNode.text((!) secret_payload))));
                    }
                    send_reply(node, response_pubsub, fail_secret_lookup);
                } else {
                    throw new IOError.INVALID_DATA("Unexpected PubSub node in lifecycle fixture");
                }
                return;
            }
            StanzaNode? publish = ((!) pubsub).get_subnode("publish", Xmpp.Xep.Pubsub.NS_URI);
            if (publish != null) {
                if (((!) publish).get_attribute("node") == Xmpp.Xep.OpenPgp.NS_URI_SECRET_KEY) {
                    secret_publish_count++;
                    StanzaNode? item = ((!) publish).get_subnode("item", Xmpp.Xep.Pubsub.NS_URI);
                    StanzaNode? secret = item != null ? ((!) item).get_subnode("secretkey", Xmpp.Xep.OpenPgp.NS_URI) : null;
                    secret_payload = secret != null ? ((!) secret).get_string_content() : null;
                }
                if (((!) publish).get_attribute("node") == Xmpp.Xep.OpenPgp.NS_URI_PUBKEYS) {
                    metadata_publish_count++;
                    metadata.clear();
                    StanzaNode? item = ((!) publish).get_subnode("item", Xmpp.Xep.Pubsub.NS_URI);
                    StanzaNode? list = item != null ? ((!) item).get_subnode("public-keys-list", Xmpp.Xep.OpenPgp.NS_URI) : null;
                    if (list != null) {
                        foreach (StanzaNode entry in ((!) list).get_subnodes("pubkey-metadata", Xmpp.Xep.OpenPgp.NS_URI)) {
                            metadata.add(entry.get_attribute("v4-fingerprint") ?? "");
                        }
                    }
                }
                send_reply(node);
                return;
            }
            throw new IOError.INVALID_DATA("Unexpected PubSub operation in lifecycle fixture");
        }

        public void complete_held_delete() {
            if (held_delete == null) return;
            StanzaNode request = (!) held_delete;
            held_delete = null;
            send_reply(request);
        }

        public void complete_held_secret_delete() {
            if (held_secret_delete == null) return;
            StanzaNode request = (!) held_secret_delete;
            held_secret_delete = null;
            send_reply(request, null, fail_secret_delete);
        }

        private void send_reply(StanzaNode request, StanzaNode? payload = null, bool error = false) {
            var result = new StanzaNode.build("iq").put_attribute("type", error ? "error" : "result")
                .put_attribute("id", request.get_attribute("id") ?? "");
            string? to = request.get_attribute("to");
            if (!omit_reply_sender) {
                if (reply_sender_override != null) result.put_attribute("from", (!) reply_sender_override);
                else if (to != null) result.put_attribute("from", (!) to);
            }
            if (error) {
                result.put_node(new StanzaNode.build("error").put_attribute("type", "cancel")
                    .put_node(new StanzaNode.build("not-authorized", "urn:ietf:params:xml:ns:xmpp-stanzas").add_self_xmlns()));
            } else if (payload != null) {
                result.put_node((!) payload);
            }
            Idle.add(() => {
                if (drop_binding_on_reply) {
                    Bind.Flag? bind = get_flag(Bind.Flag.IDENTITY);
                    if (bind != null) ((!) bind).finished = false;
                }
                if (responding) received_iq_stanza(this, result);
                return Source.REMOVE;
            });
        }
    }
}

}
