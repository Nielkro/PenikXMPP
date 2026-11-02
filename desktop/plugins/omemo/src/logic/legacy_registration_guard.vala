using Gee;
using Omemo;
using Qlite;

namespace Dino.Plugins.Omemo {

// A generated ID remains provisional until its list and bundle publication are
// acknowledged. Retrying after a crash may therefore encounter our own bundle;
// only a matching identity key can distinguish that case from another device.
internal class LegacyRegistrationGuard : Object {
    private Database db;
    private int account_id;

    internal LegacyRegistrationGuard(Database db, int account_id) {
        this.db = db;
        this.account_id = account_id;
    }

    private Row read_identity_checked() throws Error {
        Row? row = db.identity.select()
                .with(db.identity.account_id, "=", account_id)
                .single().iterator().get_next_checked();
        if (row == null || ((!) row)[db.identity.id] <= 0 ||
                ((!) row)[db.identity.device_id] <= 0) {
            throw new IOError.FAILED("OMEMO registration identity is unavailable");
        }
        return (!) row;
    }

    internal bool read_pending_checked() throws Error {
        return read_identity_checked()[db.identity.registration_pending];
    }

    internal int32 read_device_id_checked() throws Error {
        return read_identity_checked()[db.identity.device_id];
    }

    internal bool matches_identity_key_checked(ECPublicKey? public_key) throws Error {
        if (public_key == null) return false;
        Row row = read_identity_checked();
        ECPublicKey local_key = Plugin.get_context().decode_public_key(
                Base64.decode(row[db.identity.identity_key_public_base64]));
        return local_key.compare((!) public_key) == 0;
    }

    // Call only after a successful own-list lookup. If the candidate is listed,
    // matching_own_bundle must come from a successful bundle lookup (a confirmed
    // missing bundle counts as nonmatching). Request failures must defer this
    // decision, rather than being interpreted as evidence of a collision.
    internal int32 resolve_candidate_checked(Gee.List<int32> advertised_ids,
            bool matching_own_bundle) throws Error {
        Row row = read_identity_checked();
        int32 current_id = row[db.identity.device_id];
        if (!row[db.identity.registration_pending] ||
                !advertised_ids.contains(current_id) || matching_own_bundle) {
            return current_id;
        }

        int32 replacement = current_id;
        for (int attempt = 0; attempt < 128; attempt++) {
            replacement = Random.int_range(1, int32.MAX);
            if (replacement != current_id && !advertised_ids.contains(replacement)) break;
        }
        if (replacement == current_id || advertised_ids.contains(replacement)) {
            throw new IOError.FAILED("Unable to allocate an unused OMEMO device ID");
        }

        // One checked SQL statement covers both the expected provisional ID
        // and the absence of sessions. A concurrent registration or any prior
        // use of this identity must never cause a silent device-ID rotation.
        // Values are integers only; no JID or key data is interpolated.
        db.exec("UPDATE identity SET device_id = %d WHERE account_id = %d "
                .printf(replacement, account_id) +
                "AND device_id = %d AND registration_pending = 1 ".printf(current_id) +
                "AND NOT EXISTS (SELECT 1 FROM session WHERE identity_id = identity.id)");
        if (db.changes() != 1) {
            throw new IOError.FAILED("OMEMO device ID changed or already has sessions; refusing collision replacement");
        }
        return replacement;
    }

    internal void mark_published_checked(int32 expected_device_id) throws Error {
        if (expected_device_id <= 0) {
            throw new IOError.INVALID_ARGUMENT("Invalid OMEMO registration device ID");
        }
        db.exec("UPDATE identity SET registration_pending = 0 " +
                "WHERE account_id = %d AND device_id = %d".printf(account_id, expected_device_id));
        if (db.changes() != 1) {
            throw new IOError.FAILED("OMEMO publication acknowledgement does not match the persisted device ID");
        }
    }
}

}
