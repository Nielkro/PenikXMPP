using Xmpp;
using Gee;
using Qlite;

using Dino.Entities;

namespace Dino {

    public class CallStore : StreamInteractionModule, Object {
        public static ModuleIdentity<CallStore> IDENTITY = new ModuleIdentity<CallStore>("call_store");
        public string id { get { return IDENTITY.id; } }

        private StreamInteractor stream_interactor;
        private Database db;

        private WeakMap<int, Call> calls_by_db_id = new WeakMap<int, Call>();

        public static void start(StreamInteractor stream_interactor, Database db) {
            CallStore m = new CallStore(stream_interactor, db);
            stream_interactor.add_module(m);
        }

        private CallStore(StreamInteractor stream_interactor, Database db) {
            this.stream_interactor = stream_interactor;
            this.db = db;
            drop_stale_pending_other_device_calls();
        }

        /**
         * Carboned proposals are kept only while their owning device may still
         * publish a terminal action. They intentionally have no content item;
         * a process restart therefore discards the stale transient rows.
         */
        private void drop_stale_pending_other_device_calls() {
            var ids = new ArrayList<int>();
            foreach (Row row in db.call.select({db.call.id})
                    .with(db.call.state, "=", (int) Call.State.OTHER_DEVICE)) {
                int id = row[db.call.id];
                RowOption item = db.content_item.select({db.content_item.id})
                    .with(db.content_item.content_type, "=", 3)
                    .with(db.content_item.foreign_id, "=", id)
                    .single().row();
                if (!item.is_present()) ids.add(id);
            }
            foreach (int id in ids) delete_call_row(id);
        }

        public void add_call(Call call, Conversation conversation) {
            call.persist(db);
            cache_call(call);
        }

        internal void remove_unpublished_call(Call call) {
            if (call.id < 0) return;
            delete_call_row(call.id);
            calls_by_db_id.unset(call.id);
        }

        private void delete_call_row(int id) {
            bool savepoint_open = false;
            try {
                db.exec("SAVEPOINT call_row_delete");
                savepoint_open = true;
                db.call_jmi_proposal.delete()
                    .with(db.call_jmi_proposal.call_id, "=", id).perform();
                db.content_item.delete()
                    .with(db.content_item.content_type, "=", 3)
                    .with(db.content_item.foreign_id, "=", id)
                    .perform();
                db.call_jmi_sid.delete()
                    .with(db.call_jmi_sid.call_id, "=", id).perform();
                db.call_counterpart.delete()
                    .with(db.call_counterpart.call_id, "=", id).perform();
                db.call.delete().with(db.call.id, "=", id).perform();
                db.exec("RELEASE SAVEPOINT call_row_delete");
            } catch (Error e) {
                if (savepoint_open) rollback_call_delete(db);
                warning("Could not atomically delete call %d: %s", id,
                    e.message);
            }
        }

        public Call? get_call_by_id(int id, Conversation conversation) {
            Call? call = calls_by_db_id[id];
            if (call != null) {
                return call;
            }

            RowOption row_option = db.call.select()
                .with(db.call.id, "=", id)
                .single()
                .row();

            return create_call_from_row_opt(row_option, conversation);
        }

        /** Resolve the stable account-scoped XEP-0353 lifecycle identity. */
        internal Call? get_call_by_jmi_sid(Account account, string sid,
                Conversation conversation) {
            string normalized = sid.strip();
            if (normalized == "") return null;
            RowOption mapping = db.call_jmi_sid.select({
                    db.call_jmi_sid.call_id})
                .with(db.call_jmi_sid.account_id, "=", account.id)
                .with(db.call_jmi_sid.sid, "=", normalized)
                .single().row();
            if (!mapping.is_present()) return null;
            return get_call_by_id(mapping.inner[db.call_jmi_sid.call_id],
                conversation);
        }

        /**
         * Atomically bind account-scoped JMI identities to one persisted call.
         * INSERT OR IGNORE is followed by an owner readback; a foreign owner
         * rolls the complete set back before in-memory state is changed.
         */
        internal bool claim_jmi_sids(Call call,
                Gee.Collection<string> requested_sids) {
            return claim_jmi_sids_in_database(db, call, requested_sids);
        }

        internal static bool claim_jmi_sids_in_database(Database db,
                Call call, Gee.Collection<string> requested_sids) {
            ArrayList<string> normalized_sids;
            try {
                db.exec("SAVEPOINT call_jmi_sid_claim");
                if (!stage_jmi_sid_claims_in_database(db, call,
                        requested_sids, out normalized_sids)) {
                    rollback_sid_claim(db);
                    return false;
                }
                db.exec("RELEASE SAVEPOINT call_jmi_sid_claim");
            } catch (Error e) {
                rollback_sid_claim(db);
                warning("Could not claim JMI SID ownership for call %d: %s",
                    call.id, e.message);
                return false;
            }

            remember_jmi_sids(call, normalized_sids);
            return true;
        }

        /** Stage SID rows in the caller's transaction without changing Call. */
        internal static bool stage_jmi_sid_claims_in_database(Database db,
                Call call, Gee.Collection<string> requested_sids,
                out ArrayList<string> normalized_sids) {
            normalized_sids = new ArrayList<string>();
            if (call.id < 0 || call.account.id < 0) return false;
            foreach (string sid in requested_sids) {
                string normalized = sid.strip();
                if (normalized == "" || normalized_sids.contains(normalized)) {
                    continue;
                }
                normalized_sids.add(normalized);
            }
            if (normalized_sids.is_empty) return false;

            foreach (string sid in normalized_sids) {
                RowOption existing = db.call_jmi_sid.select({
                        db.call_jmi_sid.call_id})
                    .with(db.call_jmi_sid.account_id, "=",
                        call.account.id)
                    .with(db.call_jmi_sid.sid, "=", sid)
                    .single().row();
                if (existing.is_present() &&
                        existing.inner[db.call_jmi_sid.call_id] != call.id) {
                    return false;
                }
                if (!existing.is_present()) {
                    db.call_jmi_sid.insert()
                        .value(db.call_jmi_sid.call_id, call.id)
                        .value(db.call_jmi_sid.account_id, call.account.id)
                        .value(db.call_jmi_sid.sid, sid)
                        .perform();
                }
                RowOption owner = db.call_jmi_sid.select({
                        db.call_jmi_sid.call_id})
                    .with(db.call_jmi_sid.account_id, "=",
                        call.account.id)
                    .with(db.call_jmi_sid.sid, "=", sid)
                    .single().row();
                if (!owner.is_present() ||
                        owner.inner[db.call_jmi_sid.call_id] != call.id) {
                    return false;
                }
            }
            return true;
        }

        internal static void remember_jmi_sids(Call call,
                Gee.Collection<string> normalized_sids) {
            foreach (string sid in normalized_sids) {
                call.remember_jmi_sid(sid);
            }
        }

        internal bool claim_jmi_sid(Call call, string sid) {
            var sids = new ArrayList<string>();
            sids.add(sid);
            return claim_jmi_sids(call, sids);
        }

        internal void release_jmi_sid(Call call, string sid) {
            string normalized = sid.strip();
            if (call.id < 0 || normalized == "") return;
            RowOption owner = db.call_jmi_sid.select({
                    db.call_jmi_sid.call_id})
                .with(db.call_jmi_sid.account_id, "=", call.account.id)
                .with(db.call_jmi_sid.sid, "=", normalized)
                .single().row();
            if (!owner.is_present() ||
                    owner.inner[db.call_jmi_sid.call_id] != call.id) return;
            db.call_jmi_sid.delete()
                .with(db.call_jmi_sid.account_id, "=", call.account.id)
                .with(db.call_jmi_sid.sid, "=", normalized)
                .perform();
            call.forget_jmi_sid(normalized);
        }

        private static void rollback_sid_claim(Database db) {
            try {
                db.exec("ROLLBACK TO SAVEPOINT call_jmi_sid_claim");
                db.exec("RELEASE SAVEPOINT call_jmi_sid_claim");
            } catch (Error rollback_error) {
                warning("Could not roll back JMI SID claim: %s",
                    rollback_error.message);
            }
        }

        private static void rollback_call_delete(Database db) {
            try {
                db.exec("ROLLBACK TO SAVEPOINT call_row_delete");
                db.exec("RELEASE SAVEPOINT call_row_delete");
            } catch (Error rollback_error) {
                warning("Could not roll back call deletion: %s",
                    rollback_error.message);
            }
        }

        private Call? create_call_from_row_opt(RowOption row_opt, Conversation conversation) {
            if (!row_opt.is_present()) return null;

            try {
                Call call = new Call.from_row(db, row_opt.inner);
                if (conversation.type_.is_muc_semantic()) {
                    call.ourpart = conversation.counterpart.with_resource(call.ourpart.resourcepart);
                }
                cache_call(call);
                return call;
            } catch (InvalidJidError e) {
                warning("Got message with invalid Jid: %s", e.message);
            }
            return null;
        }

        private void cache_call(Call call) {
            calls_by_db_id[call.id] = call;
        }
    }
}
