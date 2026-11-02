using Dino.Entities;
using Gee;
using Qlite;
using Xmpp;

namespace Dino {

/** Immutable restart record for one unresolved incoming JMI proposal. */
internal class JmiRecoveredProposalRecord : Object {
    internal int call_id { get; private set; }
    internal int conversation_id { get; private set; }
    internal string sid { get; private set; }
    internal string proposal_source { get; private set; }
    internal string proposal_target { get; private set; }
    internal int64 started_at { get; private set; }
    internal int64 expires_at { get; private set; }
    internal bool audio_requested { get; private set; }
    internal bool video_requested { get; private set; }

    internal JmiRecoveredProposalRecord(int call_id, int conversation_id,
            string sid, string proposal_source, string proposal_target,
            int64 started_at, int64 expires_at, bool audio_requested,
            bool video_requested) {
        this.call_id = call_id;
        this.conversation_id = conversation_id;
        this.sid = sid;
        this.proposal_source = proposal_source;
        this.proposal_target = proposal_target;
        this.started_at = started_at;
        this.expires_at = expires_at;
        this.audio_requested = audio_requested;
        this.video_requested = video_requested;
    }

    internal Gee.List<StanzaNode> build_descriptions() {
        var descriptions = new ArrayList<StanzaNode>();
        if (audio_requested) {
            descriptions.add(new StanzaNode.build("description",
                Xep.JingleRtp.NS_URI).add_self_xmlns()
                    .put_attribute("media", "audio"));
        }
        if (video_requested) {
            descriptions.add(new StanzaNode.build("description",
                Xep.JingleRtp.NS_URI).add_self_xmlns()
                    .put_attribute("media", "video"));
        }
        return descriptions;
    }
}

/**
 * Database owner for passive JMI proposals.  Keeping this separate from the
 * call-history row prevents a restart from guessing that every persisted
 * RINGING call is still actionable.
 */
internal class JmiRecoveredProposalStore : Object {
    private Database db;

    internal JmiRecoveredProposalStore(Database db) {
        this.db = db;
    }

    /**
     * Persist proposal proof and every stable SID as one crash-safe aggregate.
     * Call memory is updated only after the savepoint has committed.
     */
    internal bool save_with_sids(Call call, Conversation conversation,
            string sid,
            Jid proposal_source, Jid proposal_target, DateTime started_at,
            DateTime expires_at, bool audio_requested,
            bool video_requested, Gee.Collection<string> requested_sids) {
        ArrayList<string> normalized_sids;
        bool savepoint_open = false;
        try {
            db.exec("SAVEPOINT jmi_recovered_proposal_aggregate");
            savepoint_open = true;
            if (!CallStore.stage_jmi_sid_claims_in_database(db, call,
                    requested_sids, out normalized_sids) ||
                    !normalized_sids.contains(sid.strip()) ||
                    !save_row(call, conversation, sid, proposal_source,
                        proposal_target, started_at, expires_at,
                        audio_requested, video_requested)) {
                rollback_aggregate();
                return false;
            }
            db.exec("RELEASE SAVEPOINT jmi_recovered_proposal_aggregate");
        } catch (Error e) {
            if (savepoint_open) rollback_aggregate();
            warning("Could not persist recovered JMI proposal for call %d: %s",
                call.id, e.message);
            return false;
        }

        CallStore.remember_jmi_sids(call, normalized_sids);
        return true;
    }

    private bool save_row(Call call, Conversation conversation, string sid,
            Jid proposal_source, Jid proposal_target, DateTime started_at,
            DateTime expires_at, bool audio_requested,
            bool video_requested) {
        string normalized_sid = sid.strip();
        if (call.id < 0 || conversation.id < 0 ||
                !call.account.equals(conversation.account) ||
                normalized_sid == "" ||
                proposal_source.resourcepart == null ||
                !proposal_source.equals_bare(call.counterpart) ||
                !proposal_target.equals_bare(call.account.bare_jid) ||
                (!audio_requested && !video_requested) ||
                expires_at.compare(started_at) <= 0) return false;

        RowOption sid_owner = db.call_jmi_proposal.select({
                db.call_jmi_proposal.call_id})
            .with(db.call_jmi_proposal.account_id, "=", call.account.id)
            .with(db.call_jmi_proposal.sid, "=", normalized_sid)
            .single().row();
        if (sid_owner.is_present() &&
                sid_owner.inner[db.call_jmi_proposal.call_id] != call.id) {
            return false;
        }
        RowOption call_owner = db.call_jmi_proposal.select({
                db.call_jmi_proposal.sid})
            .with(db.call_jmi_proposal.call_id, "=", call.id)
            .single().row();
        if (call_owner.is_present() &&
                call_owner.inner[db.call_jmi_proposal.sid] !=
                    normalized_sid) return false;

        if (!call_owner.is_present()) {
            db.call_jmi_proposal.insert()
                .value(db.call_jmi_proposal.call_id, call.id)
                .value(db.call_jmi_proposal.account_id, call.account.id)
                .value(db.call_jmi_proposal.conversation_id, conversation.id)
                .value(db.call_jmi_proposal.sid, normalized_sid)
                .value(db.call_jmi_proposal.proposal_source,
                    proposal_source.to_string())
                .value(db.call_jmi_proposal.proposal_target,
                    proposal_target.to_string())
                .value(db.call_jmi_proposal.started_at,
                    (long) started_at.to_unix())
                .value(db.call_jmi_proposal.expires_at,
                    (long) expires_at.to_unix())
                .value(db.call_jmi_proposal.audio_requested,
                    audio_requested)
                .value(db.call_jmi_proposal.video_requested,
                    video_requested)
                .perform();
        } else {
            db.call_jmi_proposal.update()
                .with(db.call_jmi_proposal.call_id, "=", call.id)
                .set(db.call_jmi_proposal.conversation_id, conversation.id)
                .set(db.call_jmi_proposal.proposal_source,
                    proposal_source.to_string())
                .set(db.call_jmi_proposal.proposal_target,
                    proposal_target.to_string())
                .set(db.call_jmi_proposal.started_at,
                    (long) started_at.to_unix())
                .set(db.call_jmi_proposal.expires_at,
                    (long) expires_at.to_unix())
                .set(db.call_jmi_proposal.audio_requested,
                    audio_requested)
                .set(db.call_jmi_proposal.video_requested,
                    video_requested)
                .perform();
        }

        RowOption persisted = db.call_jmi_proposal.select()
            .with(db.call_jmi_proposal.call_id, "=", call.id)
            .with(db.call_jmi_proposal.account_id, "=", call.account.id)
            .with(db.call_jmi_proposal.sid, "=", normalized_sid)
            .single().row();
        return persisted.is_present() &&
            persisted.inner[db.call_jmi_proposal.conversation_id] ==
                conversation.id &&
            persisted.inner[db.call_jmi_proposal.proposal_source] ==
                proposal_source.to_string() &&
            persisted.inner[db.call_jmi_proposal.proposal_target] ==
                proposal_target.to_string() &&
            persisted.inner[db.call_jmi_proposal.started_at] ==
                started_at.to_unix() &&
            persisted.inner[db.call_jmi_proposal.expires_at] ==
                expires_at.to_unix() &&
            persisted.inner[db.call_jmi_proposal.audio_requested] ==
                audio_requested &&
            persisted.inner[db.call_jmi_proposal.video_requested] ==
                video_requested;
    }

    private void rollback_aggregate() {
        try {
            db.exec("ROLLBACK TO SAVEPOINT jmi_recovered_proposal_aggregate");
            db.exec("RELEASE SAVEPOINT jmi_recovered_proposal_aggregate");
        } catch (Error rollback_error) {
            warning("Could not roll back recovered JMI proposal: %s",
                rollback_error.message);
        }
    }

    internal Gee.List<JmiRecoveredProposalRecord> load(Account account) {
        var records = new ArrayList<JmiRecoveredProposalRecord>();
        foreach (Row row in db.call_jmi_proposal.select()
                .with(db.call_jmi_proposal.account_id, "=", account.id)
                .order_by(db.call_jmi_proposal.started_at, "ASC")) {
            records.add(new JmiRecoveredProposalRecord(
                row[db.call_jmi_proposal.call_id],
                row[db.call_jmi_proposal.conversation_id],
                row[db.call_jmi_proposal.sid],
                row[db.call_jmi_proposal.proposal_source],
                row[db.call_jmi_proposal.proposal_target],
                row[db.call_jmi_proposal.started_at],
                row[db.call_jmi_proposal.expires_at],
                row[db.call_jmi_proposal.audio_requested],
                row[db.call_jmi_proposal.video_requested]));
        }
        return records;
    }

    /** Exact restart proof; terminal call history alone is never actionable. */
    internal bool owns(Call call, string sid) {
        string normalized_sid = sid.strip();
        if (call.id < 0 || normalized_sid == "") return false;
        return db.call_jmi_proposal.select()
            .with(db.call_jmi_proposal.call_id, "=", call.id)
            .with(db.call_jmi_proposal.account_id, "=", call.account.id)
            .with(db.call_jmi_proposal.sid, "=", normalized_sid)
            .count() == 1;
    }

    internal void remove(Call call) {
        if (call.id >= 0) remove_call_id(call.id);
    }

    internal void remove_call_id(int call_id) {
        db.call_jmi_proposal.delete()
            .with(db.call_jmi_proposal.call_id, "=", call_id).perform();
    }

    internal void remove_account(Account account) {
        db.call_jmi_proposal.delete()
            .with(db.call_jmi_proposal.account_id, "=", account.id).perform();
    }
}

}
