/* DNSSEC/DANE policy shared by connection implementations.
 *
 * This is a decision contract, not a resolver or certificate verifier. Callers
 * must obtain the states from a validating resolver and enforce VERIFY_TLSA on
 * the actual TLS connection before authenticating. An AD bit alone is not
 * sufficient evidence. See docs/internal/DNSSEC_DANE_PLAN.md.
 */
namespace Xmpp.DnsSecurity {

public errordomain ConfigurationError {
    INVALID_MODE
}

public enum Mode {
    OFF,
    WHEN_AVAILABLE,
    REQUIRED;

    public static Mode from_setting(string? value) throws ConfigurationError {
        // Only an absent setting is an old account's default. An unknown value
        // must not silently disable a user's security policy.
        switch (value) {
            case null: case "off": return OFF;
            case "when-available": return WHEN_AVAILABLE;
            case "required": return REQUIRED;
            default:
                throw new ConfigurationError.INVALID_MODE("Unknown DNSSEC/DANE mode");
        }
    }

    public string to_setting() {
        switch (this) {
            case OFF: return "off";
            case WHEN_AVAILABLE: return "when-available";
            case REQUIRED: return "required";
            default: assert_not_reached();
        }
    }
}

// RFC 4035: insecurity is a validated lack of a chain of trust. It is not a
// catch-all for a timeout, a failed signature, or an unavailable validator.
public enum Validation {
    SECURE,
    INSECURE,
    BOGUS,
    INDETERMINATE
}

public enum TlsaRecords {
    ABSENT,
    UNSUPPORTED,
    USABLE
}

public enum Decision {
    EXISTING_TLS,
    VERIFY_TLSA,
    REJECT_BOGUS,
    RETRY_LOOKUP,
    REJECT_REQUIRED
}

// Discovery never authorizes a TLS connection. Keep its result type separate
// so a secure SRV answer cannot accidentally be treated as certificate trust.
public enum DiscoveryDecision {
    USE_EXISTING_LOOKUP,
    CONTINUE_WITH_ANSWER,
    REJECT_BOGUS,
    RETRY_LOOKUP,
    REJECT_REQUIRED
}

/** Policy for one endpoint after service delegation and address validation.
 *
 * authorized_target means that the service-to-target delegation was securely
 * validated (including aliases), or was explicitly configured by the user. It
 * must not be inferred from a valid TLSA record at an arbitrary SRV target.
 * Discovery failures must be handled BEFORE calling this function; a bogus SRV
 * response cannot be represented merely as authorized_target=false.
 */
public Decision decide_endpoint(Mode mode, bool authorized_target,
        Validation address, Validation tlsa, TlsaRecords records) {
    if (mode == Mode.OFF) return Decision.EXISTING_TLS;

    // No unauthenticated DNS answer may authorize a DANE trust override.
    // A broken lookup is not the same as a successful unsigned lookup.
    if (address == Validation.BOGUS || tlsa == Validation.BOGUS) {
        return Decision.REJECT_BOGUS;
    }
    if (address == Validation.INDETERMINATE || tlsa == Validation.INDETERMINATE) {
        return Decision.RETRY_LOOKUP;
    }
    if (authorized_target && address == Validation.SECURE &&
            tlsa == Validation.SECURE && records == TlsaRecords.USABLE) {
        return Decision.VERIFY_TLSA;
    }
    return mode == Mode.REQUIRED ? Decision.REJECT_REQUIRED : Decision.EXISTING_TLS;
}

/** Apply before using a service-discovery result (RFC 7673 section 3.1). */
public DiscoveryDecision decide_discovery(Mode mode, Validation discovery) {
    if (mode == Mode.OFF) return DiscoveryDecision.USE_EXISTING_LOOKUP;
    switch (discovery) {
        case Validation.BOGUS: return DiscoveryDecision.REJECT_BOGUS;
        case Validation.INDETERMINATE: return DiscoveryDecision.RETRY_LOOKUP;
        case Validation.INSECURE:
            return mode == Mode.REQUIRED ? DiscoveryDecision.REJECT_REQUIRED : DiscoveryDecision.CONTINUE_WITH_ANSWER;
        case Validation.SECURE:
            // Discovery alone never verifies the server certificate. The
            // endpoint still needs address/TLSA and live TLS verification.
            return DiscoveryDecision.CONTINUE_WITH_ANSWER;
        default: assert_not_reached();
    }
}

/** Capability for results belonging to exactly one connection attempt.
 *
 * The connection owner retains its current Attempt. Replacing it on reconnect,
 * route/policy changes or account removal makes all old results unusable. Use
 * separate instances even for accounts sharing a domain and proxy. Resolver
 * contexts and certificate evidence must retain this capability, not just a
 * hostname or an account's currently selected UI row.
 */
public class Attempt : Object {
    public Mode mode { get; private set; }
    public Cancellable cancellable { get; private set; }

    public Attempt(Mode mode) {
        this.mode = mode;
        this.cancellable = new Cancellable();
    }

    public bool is_current(Attempt? current) {
        return this == current && !cancellable.is_cancelled();
    }

    public void cancel() {
        cancellable.cancel();
    }
}

}
