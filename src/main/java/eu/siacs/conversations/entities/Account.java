package eu.siacs.conversations.entities;

import android.content.ContentValues;
import android.database.Cursor;
import android.util.Log;
import com.google.common.base.Objects;
import com.google.common.base.Optional;
import com.google.common.base.Strings;
import com.google.common.collect.ImmutableMap;
import com.google.common.collect.ImmutableMultimap;
import com.google.gson.JsonParseException;
import com.google.gson.annotations.SerializedName;
import de.gultsch.common.MiniUri;
import eu.siacs.conversations.Config;
import eu.siacs.conversations.R;
import eu.siacs.conversations.crypto.PgpDecryptionService;
import eu.siacs.conversations.crypto.axolotl.AxolotlService;
import eu.siacs.conversations.crypto.sasl.ChannelBinding;
import eu.siacs.conversations.crypto.sasl.ChannelBindingMechanism;
import eu.siacs.conversations.crypto.sasl.HashedToken;
import eu.siacs.conversations.crypto.sasl.HashedTokenSha256;
import eu.siacs.conversations.crypto.sasl.HashedTokenSha512;
import eu.siacs.conversations.crypto.sasl.SaslMechanism;
import eu.siacs.conversations.http.ServiceOutageStatus;
import eu.siacs.conversations.services.AvatarService;
import eu.siacs.conversations.utils.Resolver;
import eu.siacs.conversations.utils.UIHelper;
import eu.siacs.conversations.xmpp.Jid;
import eu.siacs.conversations.xmpp.XmppConnection;
import eu.siacs.conversations.xmpp.jingle.RtpCapability;
import eu.siacs.conversations.xmpp.manager.HttpUploadManager;
import eu.siacs.conversations.xmpp.manager.RosterManager;
import im.conversations.android.json.Services;
import java.util.Arrays;
import java.util.Collection;
import java.util.Locale;
import okhttp3.HttpUrl;
import org.jspecify.annotations.NonNull;

public class Account extends AbstractEntity implements AvatarService.Avatar {

    public static final String TABLENAME = "accounts";

    public static final String USERNAME = "username";
    public static final String SERVER = "server";
    public static final String PASSWORD = "password";
    public static final String OPTIONS = "options";
    public static final String ROSTERVERSION = "rosterversion";
    public static final String KEYS = "keys";
    public static final String AVATAR = "avatar";
    public static final String DISPLAY_NAME = "display_name";
    public static final String HOSTNAME = "hostname";
    public static final String PORT = "port";
    public static final String STATUS = "status";
    public static final String STATUS_MESSAGE = "status_message";
    public static final String RESOURCE = "resource";
    public static final String PINNED_MECHANISM = "pinned_mechanism";
    public static final String PINNED_CHANNEL_BINDING = "pinned_channel_binding";
    public static final String FAST_MECHANISM = "fast_mechanism";
    public static final String FAST_TOKEN = "fast_token";

    public static final int OPTION_DISABLED = 1;
    public static final int OPTION_REGISTER = 2;
    public static final int OPTION_MAGIC_CREATE = 4;
    public static final int OPTION_REQUIRES_ACCESS_MODE_CHANGE = 5;
    public static final int OPTION_LOGGED_IN_SUCCESSFULLY = 6;
    public static final int OPTION_HTTP_UPLOAD_AVAILABLE = 7;
    public static final int OPTION_UNVERIFIED = 8;
    public static final int OPTION_FIXED_USERNAME = 9;
    public static final int OPTION_QUICKSTART_AVAILABLE = 10;
    public static final int OPTION_SOFT_DISABLED = 11;

    protected final Keys keys;
    protected Jid jid;
    protected String password;
    protected int options = 0;
    protected State status = State.OFFLINE;
    private State lastErrorStatus = State.OFFLINE;
    protected String resource;
    protected String avatar;
    protected String hostname = null;
    protected int port = 5222;
    protected boolean online = false;
    private String rosterVersion;
    private String displayName = null;
    private XmppConnection xmppConnection = null;
    private im.conversations.android.xmpp.model.stanza.Presence.Availability presenceStatus;
    private String presenceStatusMessage;
    private String pinnedMechanism;
    private String pinnedChannelBinding;
    private String fastMechanism;
    private String fastToken;
    private ServiceOutageStatus serviceOutageStatus;

    public Account(final Jid jid, final String password) {
        this(
                java.util.UUID.randomUUID().toString(),
                jid,
                password,
                0,
                null,
                new Keys(),
                null,
                null,
                null,
                Resolver.XMPP_PORT_STARTTLS,
                im.conversations.android.xmpp.model.stanza.Presence.Availability.ONLINE,
                null,
                null,
                null,
                null,
                null);
    }

    private Account(
            final String uuid,
            final Jid jid,
            final String password,
            final int options,
            final String rosterVersion,
            final Keys keys,
            final String avatar,
            String displayName,
            String hostname,
            int port,
            final im.conversations.android.xmpp.model.stanza.Presence.Availability status,
            String statusMessage,
            final String pinnedMechanism,
            final String pinnedChannelBinding,
            final String fastMechanism,
            final String fastToken) {
        this.uuid = uuid;
        this.jid = jid;
        this.password = password;
        this.options = options;
        this.rosterVersion = rosterVersion;
        this.keys = keys;
        this.avatar = avatar;
        this.displayName = displayName;
        this.hostname = hostname;
        this.port = port;
        this.presenceStatus = status;
        this.presenceStatusMessage = statusMessage;
        this.pinnedMechanism = pinnedMechanism;
        this.pinnedChannelBinding = pinnedChannelBinding;
        this.fastMechanism = fastMechanism;
        this.fastToken = fastToken;
    }

    public static Account fromCursor(final Cursor cursor) {
        final Jid jid;
        try {
            final String resource = cursor.getString(cursor.getColumnIndexOrThrow(RESOURCE));
            jid =
                    Jid.of(
                            cursor.getString(cursor.getColumnIndexOrThrow(USERNAME)),
                            cursor.getString(cursor.getColumnIndexOrThrow(SERVER)),
                            resource == null || resource.trim().isEmpty() ? null : resource);
        } catch (final IllegalArgumentException e) {
            Log.d(
                    Config.LOGTAG,
                    cursor.getString(cursor.getColumnIndexOrThrow(USERNAME))
                            + "@"
                            + cursor.getString(cursor.getColumnIndexOrThrow(SERVER)));
            throw new AssertionError(e);
        }
        return new Account(
                cursor.getString(cursor.getColumnIndexOrThrow(UUID)),
                jid,
                cursor.getString(cursor.getColumnIndexOrThrow(PASSWORD)),
                cursor.getInt(cursor.getColumnIndexOrThrow(OPTIONS)),
                cursor.getString(cursor.getColumnIndexOrThrow(ROSTERVERSION)),
                Keys.parse(cursor.getString(cursor.getColumnIndexOrThrow(KEYS))),
                cursor.getString(cursor.getColumnIndexOrThrow(AVATAR)),
                cursor.getString(cursor.getColumnIndexOrThrow(DISPLAY_NAME)),
                cursor.getString(cursor.getColumnIndexOrThrow(HOSTNAME)),
                cursor.getInt(cursor.getColumnIndexOrThrow(PORT)),
                im.conversations.android.xmpp.model.stanza.Presence.Availability.valueOfShown(
                        cursor.getString(cursor.getColumnIndexOrThrow(STATUS))),
                cursor.getString(cursor.getColumnIndexOrThrow(STATUS_MESSAGE)),
                cursor.getString(cursor.getColumnIndexOrThrow(PINNED_MECHANISM)),
                cursor.getString(cursor.getColumnIndexOrThrow(PINNED_CHANNEL_BINDING)),
                cursor.getString(cursor.getColumnIndexOrThrow(FAST_MECHANISM)),
                cursor.getString(cursor.getColumnIndexOrThrow(FAST_TOKEN)));
    }

    // TODO remove this method and call HttpUploadManager directly i
    public boolean httpUploadAvailable(final long fileSize) {
        return xmppConnection.getManager(HttpUploadManager.class).isAvailableForSize(fileSize);
    }

    public boolean httpUploadAvailable() {
        return isOptionSet(OPTION_HTTP_UPLOAD_AVAILABLE)
                || xmppConnection.getManager(HttpUploadManager.class).isAvailableForSize(0);
    }

    public String getDisplayName() {
        return displayName;
    }

    public void setDisplayName(String displayName) {
        this.displayName = displayName;
    }

    public Contact getSelfContact() {
        return getRoster().getContact(jid);
    }

    public boolean hasPendingPgpIntent(Conversation conversation) {
        return getPgpDecryptionService().hasPendingIntent(conversation);
    }

    public boolean isPgpDecryptionServiceConnected() {
        return getPgpDecryptionService().isConnected();
    }

    public boolean setShowErrorNotification(final boolean newValue) {
        final boolean oldValue = this.showErrorNotification();
        this.keys.showError = newValue;
        return newValue != oldValue;
    }

    public boolean showErrorNotification() {
        return this.keys.showError == null || this.keys.showError;
    }

    public boolean isEnabled() {
        return !isOptionSet(Account.OPTION_DISABLED);
    }

    public boolean isConnectionEnabled() {
        return !isOptionSet(Account.OPTION_DISABLED) && !isOptionSet(Account.OPTION_SOFT_DISABLED);
    }

    public boolean isOptionSet(final int option) {
        return ((options & (1 << option)) != 0);
    }

    public boolean setOption(final int option, final boolean value) {
        if (value && (option == OPTION_DISABLED || option == OPTION_SOFT_DISABLED)) {
            this.setStatus(State.OFFLINE);
        }
        final int before = this.options;
        if (value) {
            this.options |= 1 << option;
        } else {
            this.options &= ~(1 << option);
        }
        return before != this.options;
    }

    public String getUsername() {
        return jid.getLocal();
    }

    public boolean setJid(final Jid next) {
        final Jid previousFull = this.jid;
        final Jid prev = this.jid != null ? this.jid.asBareJid() : null;
        final boolean changed = prev == null || (next != null && !prev.equals(next.asBareJid()));
        if (changed) {
            final AxolotlService oldAxolotlService = xmppConnection.getAxolotlService();
            // TODO check that changing JID and recreating the AxolotlService still works
            if (oldAxolotlService != null) {
                oldAxolotlService.destroy();
                this.jid = next;
                xmppConnection.setAxolotlService(oldAxolotlService.makeNew());
            }
        }
        this.jid = next;
        return next != null && !next.equals(previousFull);
    }

    public Jid getDomain() {
        return jid.getDomain();
    }

    public String getServer() {
        return jid.getDomain().toString();
    }

    public String getPassword() {
        return password;
    }

    public void setPassword(final String password) {
        this.password = password;
    }

    @NonNull
    public String getHostname() {
        return Strings.nullToEmpty(this.hostname);
    }

    public void setHostname(final String hostname) {
        this.hostname = hostname;
    }

    public boolean isOnion() {
        final String server = getServer();
        return server != null && server.endsWith(".onion");
    }

    public boolean isDirectToOnion() {
        final var hostname = Strings.nullToEmpty(this.hostname).trim();
        return isOnion() && (hostname.isEmpty() || hostname.endsWith(".onion"));
    }

    public int getPort() {
        return this.port;
    }

    public void setPort(int port) {
        this.port = port;
    }

    public State getStatus() {
        if (isOptionSet(OPTION_DISABLED)) {
            return State.DISABLED;
        } else if (isOptionSet(OPTION_SOFT_DISABLED)) {
            return State.LOGGED_OUT;
        } else {
            return this.status;
        }
    }

    public boolean unauthorized() {
        return this.status == State.UNAUTHORIZED || this.lastErrorStatus == State.UNAUTHORIZED;
    }

    public State getLastErrorStatus() {
        return this.lastErrorStatus;
    }

    public void setStatus(@org.jspecify.annotations.NonNull final State status) {
        this.status = status;
        if (status.isError
                || (Arrays.asList(State.ONLINE, State.AIRPLANE_MODE, State.NO_INTERNET)
                        .contains(status))) {
            this.lastErrorStatus = status;
        }
    }

    public void setPinnedMechanism(final SaslMechanism mechanism) {
        this.pinnedMechanism = mechanism.getMechanism();
        if (mechanism instanceof ChannelBindingMechanism) {
            this.pinnedChannelBinding =
                    ((ChannelBindingMechanism) mechanism).getChannelBinding().toString();
        } else {
            this.pinnedChannelBinding = null;
        }
    }

    public void setFastToken(final HashedToken.Mechanism mechanism, final String token) {
        this.fastMechanism = mechanism.name();
        this.fastToken = token;
    }

    public void resetFastToken() {
        this.fastMechanism = null;
        this.fastToken = null;
    }

    public void resetPinnedMechanism() {
        this.pinnedMechanism = null;
        this.pinnedChannelBinding = null;
    }

    public int getPinnedMechanismPriority() {
        final SaslMechanism saslMechanism = getPinnedMechanism();
        if (saslMechanism == null) {
            return Integer.MIN_VALUE;
        } else {
            return saslMechanism.getPriority();
        }
    }

    private SaslMechanism getPinnedMechanism() {
        final String mechanism = Strings.nullToEmpty(this.pinnedMechanism);
        final ChannelBinding channelBinding = ChannelBinding.get(this.pinnedChannelBinding);
        return new SaslMechanism.Factory(this).of(mechanism, channelBinding);
    }

    public HashedToken getFastMechanism() {
        final HashedToken.Mechanism fastMechanism =
                HashedToken.Mechanism.ofOrNull(this.fastMechanism);
        final String token = this.fastToken;
        if (fastMechanism == null || Strings.isNullOrEmpty(token)) {
            return null;
        }
        if (fastMechanism.hashFunction().equals("SHA-256")) {
            return new HashedTokenSha256(this, fastMechanism.channelBinding());
        } else if (fastMechanism.hashFunction().equals("SHA-512")) {
            return new HashedTokenSha512(this, fastMechanism.channelBinding());
        } else {
            return null;
        }
    }

    public SaslMechanism getQuickStartMechanism() {
        final HashedToken hashedTokenMechanism = getFastMechanism();
        if (hashedTokenMechanism != null) {
            return hashedTokenMechanism;
        }
        return getPinnedMechanism();
    }

    public String getFastToken() {
        return this.fastToken;
    }

    public State getTrueStatus() {
        return this.status;
    }

    public boolean hasErrorStatus() {
        if (isConnectionEnabled()) {
            final var state = this.lastErrorStatus;
            return state != null && state.isError && this.xmppConnection.getAttempt() >= 3;
        }
        return false;
    }

    public im.conversations.android.xmpp.model.stanza.Presence.Availability getPresenceStatus() {
        return this.presenceStatus;
    }

    public void setPresenceStatus(
            im.conversations.android.xmpp.model.stanza.Presence.Availability status) {
        this.presenceStatus = status;
    }

    public String getPresenceStatusMessage() {
        return this.presenceStatusMessage;
    }

    public void setPresenceStatusMessage(String message) {
        this.presenceStatusMessage = message;
    }

    public String getResource() {
        return jid.getResource();
    }

    public void setResource(final String resource) {
        this.jid = this.jid.withResource(resource);
    }

    public Jid getJid() {
        return jid;
    }

    public void setPrivateKeyAlias(final String alias) {
        this.keys.privateKeyAlias = alias;
    }

    public String getPrivateKeyAlias() {
        return this.keys.privateKeyAlias;
    }

    @Override
    public ContentValues getContentValues() {
        final ContentValues values = new ContentValues();
        values.put(UUID, uuid);
        values.put(USERNAME, jid.getLocal());
        values.put(SERVER, jid.getDomain().toString());
        values.put(PASSWORD, password);
        values.put(OPTIONS, options);
        values.put(KEYS, Services.GSON.toJson(this.keys));
        values.put(ROSTERVERSION, rosterVersion);
        values.put(AVATAR, avatar);
        values.put(DISPLAY_NAME, displayName);
        values.put(HOSTNAME, hostname);
        values.put(PORT, port);
        values.put(STATUS, presenceStatus.toShowString());
        values.put(STATUS_MESSAGE, presenceStatusMessage);
        values.put(RESOURCE, jid.getResource());
        values.put(PINNED_MECHANISM, pinnedMechanism);
        values.put(PINNED_CHANNEL_BINDING, pinnedChannelBinding);
        values.put(FAST_MECHANISM, this.fastMechanism);
        values.put(FAST_TOKEN, this.fastToken);
        return values;
    }

    public AxolotlService getAxolotlService() {
        return this.xmppConnection.getAxolotlService();
    }

    public PgpDecryptionService getPgpDecryptionService() {
        return this.xmppConnection.getPgpDecryptionService();
    }

    public XmppConnection getXmppConnection() {
        return this.xmppConnection;
    }

    public String getRosterVersion() {
        return Strings.emptyToNull(this.rosterVersion);
    }

    public void setRosterVersion(final String version) {
        this.rosterVersion = version;
    }

    public int countPresences() {
        return this.getSelfContact().getPresences().size();
    }

    public int activeDevicesWithRtpCapability() {
        final var connection = getXmppConnection();
        if (connection == null) {
            return 0;
        }
        int i = 0;
        for (final var optionalInfoQuery : getSelfContact().getCapabilities()) {
            if (RtpCapability.check(optionalInfoQuery.orNull()) != RtpCapability.Capability.NONE) {
                i++;
            }
        }
        return i;
    }

    public String getPgpSignature() {
        return this.keys.pgpSignature;
    }

    public void setPgpSignature(final String signature) {
        this.keys.pgpSignature = signature;
    }

    public void resetPgp() {
        this.keys.pgpKeyId = null;
        this.keys.pgpSignature = null;
    }

    public Optional<Long> getPgpId() {
        return Optional.fromNullable(this.keys.pgpKeyId);
    }

    public void setPgpSignId(final long pgpID) {
        this.keys.pgpKeyId = pgpID;
    }

    public Optional<Integer> getAxolotlRegistrationId() {
        return this.keys.getAxolotlRegistrationId();
    }

    public void setAxolotlRegistrationId(final int registrationId) {
        this.keys.axolotlRegistrationId = registrationId;
    }

    public int getAxolotlCurrentPreKey() {
        return this.keys.axolotlCurrentPreKey;
    }

    public void setAxolotlCurrentPreKey(final int id) {
        this.keys.axolotlCurrentPreKey = id;
    }

    public Optional<String> getPreAuthRegistrationToken() {
        return Optional.fromNullable(Strings.emptyToNull(this.keys.preAuthRegistrationToken));
    }

    public void setPreAuthRegistrationToken(final String preAuthRegistrationToken) {
        this.keys.preAuthRegistrationToken = preAuthRegistrationToken;
    }

    public Optional<HttpUrl> getSosUrl() {
        return Optional.fromNullable(this.keys.sosUrl);
    }

    public boolean setSosUrl(final HttpUrl url) {
        final var old = this.keys.sosUrl;
        this.keys.sosUrl = url;
        return !Objects.equal(old, url);
    }

    public Roster getRoster() {
        return xmppConnection.getManager(RosterManager.class);
    }

    public boolean setAvatar(final String filename) {
        if (this.avatar != null && this.avatar.equals(filename)) {
            return false;
        } else {
            this.avatar = filename;
            return true;
        }
    }

    public String getAvatar() {
        return this.avatar;
    }

    public MiniUri.Xmpp getShareableUri() {
        return new MiniUri.Xmpp(this.getJid().asBareJid(), getFingerprints());
    }

    public ImmutableMap<String, Collection<String>> getFingerprints() {
        final ImmutableMultimap.Builder<String, String> builder = new ImmutableMultimap.Builder<>();
        final var axolotlService = getAxolotlService();
        builder.put(
                String.format(Locale.US, "omemo-sid-%d", axolotlService.getOwnDeviceId()),
                axolotlService.getOwnFingerprint().substring(2));
        for (final var session : axolotlService.findOwnSessions()) {
            if (session.getTrust().isVerified() && session.getTrust().isActive()) {
                builder.put(
                        String.format(
                                Locale.US,
                                "omemo-sid-%d",
                                session.getRemoteAddress().getDeviceId()),
                        session.getFingerprint().substring(2));
            }
        }
        return builder.build().asMap();
    }

    public boolean isOnlineAndConnected() {
        return this.getStatus() == State.ONLINE && this.getXmppConnection() != null;
    }

    @Override
    public int getAvatarBackgroundColor() {
        return UIHelper.getColorForName(jid.asBareJid().toString());
    }

    public void setServiceOutageStatus(final ServiceOutageStatus sos) {
        this.serviceOutageStatus = sos;
    }

    public ServiceOutageStatus getServiceOutageStatus() {
        return this.serviceOutageStatus;
    }

    public boolean isServiceOutage() {
        final var sos = this.serviceOutageStatus;
        if (sos != null
                && isOptionSet(Account.OPTION_LOGGED_IN_SUCCESSFULLY)
                && ServiceOutageStatus.isPossibleOutage(this.status)) {
            return sos.isNow();
        }
        return false;
    }

    public void setXmppConnection(final XmppConnection connection) {
        this.xmppConnection = connection;
    }

    public static class Keys {

        @SerializedName("pgp_signature")
        private String pgpSignature;

        @SerializedName("pgp_id")
        private Long pgpKeyId;

        @SerializedName("sos_url")
        private HttpUrl sosUrl;

        @SerializedName("pre_auth_registration")
        private String preAuthRegistrationToken;

        @SerializedName("show_error")
        private Boolean showError;

        @SerializedName("private_key_alias")
        private String privateKeyAlias;

        @SerializedName("axolotl_reg_id")
        private Integer axolotlRegistrationId;

        @SerializedName("axolotl_cur_prekey_id")
        private int axolotlCurrentPreKey;

        public Optional<Integer> getAxolotlRegistrationId() {
            return Optional.fromNullable(this.axolotlRegistrationId);
        }

        public static Keys parse(final String json) {
            if (Strings.isNullOrEmpty(json)) {
                return new Keys();
            }
            try {
                return Services.GSON.fromJson(json, Keys.class);
            } catch (final JsonParseException e) {
                Log.d(Config.LOGTAG, "could not parse account keys", e);
                return new Keys();
            }
        }

        public Keys() {}

        public Keys(final int deviceId) {
            this.axolotlRegistrationId = deviceId;
        }
    }

    public enum State {
        DISABLED(false, false),
        LOGGED_OUT(false, false),
        OFFLINE(false),
        CONNECTING(false),
        ONLINE(false),
        NO_INTERNET(false),
        AIRPLANE_MODE(false),
        CONNECTION_TIMEOUT,
        UNAUTHORIZED,
        TEMPORARY_AUTH_FAILURE,
        SERVER_NOT_FOUND,
        REGISTRATION_SUCCESSFUL(false),
        REGISTRATION_FAILED(true, false),
        REGISTRATION_WEB(true, false),
        REGISTRATION_CONFLICT(true, false),
        REGISTRATION_NOT_SUPPORTED(true, false),
        REGISTRATION_PLEASE_WAIT(true, false),
        REGISTRATION_INVALID_TOKEN(true, false),
        REGISTRATION_INVALID_CAPTCHA(true, false),
        REGISTRATION_PASSWORD_TOO_WEAK(true, false),
        TLS_ERROR,
        TLS_ERROR_DOMAIN,
        TLS_ERROR_UNTRUSTED,
        TLS_ERROR_PROTOCOL,
        CHANNEL_BINDING,
        INCOMPATIBLE_SERVER,
        INCOMPATIBLE_CLIENT,
        TOR_NOT_AVAILABLE,
        DOWNGRADE_ATTACK,
        SESSION_FAILURE,
        BIND_FAILURE,
        HOST_UNKNOWN,
        STREAM_ERROR,
        SEE_OTHER_HOST,
        STREAM_OPENING_ERROR,
        POLICY_VIOLATION,
        PAYMENT_REQUIRED,
        MISSING_INTERNET_PERMISSION(false),
        MISSING_LOCAL_NETWORK_PERMISSION(false);

        private final boolean isError;
        private final boolean attemptReconnect;

        State(final boolean isError) {
            this(isError, true);
        }

        State(final boolean isError, final boolean reconnect) {
            this.isError = isError;
            this.attemptReconnect = reconnect;
        }

        State() {
            this(true, true);
        }

        public boolean isError() {
            return this.isError;
        }

        public boolean isAttemptReconnect() {
            return this.attemptReconnect;
        }

        public int getReadableId() {
            return switch (this) {
                case DISABLED -> R.string.account_status_disabled;
                case LOGGED_OUT -> R.string.account_state_logged_out;
                case ONLINE -> R.string.account_status_online;
                case CONNECTING -> R.string.account_status_connecting;
                case OFFLINE -> R.string.account_status_offline;
                case UNAUTHORIZED -> R.string.account_status_unauthorized;
                case SERVER_NOT_FOUND -> R.string.account_status_not_found;
                case NO_INTERNET -> R.string.account_status_no_internet;
                case AIRPLANE_MODE -> R.string.account_status_airplane_mode;
                case CONNECTION_TIMEOUT -> R.string.account_status_connection_timeout;
                case REGISTRATION_FAILED -> R.string.account_status_regis_fail;
                case REGISTRATION_WEB -> R.string.account_status_regis_web;
                case REGISTRATION_CONFLICT -> R.string.account_status_regis_conflict;
                case REGISTRATION_SUCCESSFUL -> R.string.account_status_regis_success;
                case REGISTRATION_NOT_SUPPORTED -> R.string.account_status_regis_not_sup;
                case REGISTRATION_INVALID_CAPTCHA -> R.string.account_status_regis_invalid_captcha;
                case REGISTRATION_INVALID_TOKEN -> R.string.account_status_regis_invalid_token;
                case TLS_ERROR -> R.string.account_status_tls_error;
                case TLS_ERROR_DOMAIN -> R.string.account_status_tls_error_domain;
                case TLS_ERROR_PROTOCOL -> R.string.account_status_tls_error_protocol;
                case TLS_ERROR_UNTRUSTED -> R.string.account_status_tls_error_untrusted;
                case INCOMPATIBLE_SERVER -> R.string.account_status_incompatible_server;
                case INCOMPATIBLE_CLIENT -> R.string.account_status_incompatible_client;
                case CHANNEL_BINDING -> R.string.account_status_channel_binding;
                case TOR_NOT_AVAILABLE -> R.string.account_status_tor_unavailable;
                case BIND_FAILURE -> R.string.account_status_bind_failure;
                case SESSION_FAILURE -> R.string.session_failure;
                case DOWNGRADE_ATTACK -> R.string.sasl_downgrade;
                case HOST_UNKNOWN -> R.string.account_status_host_unknown;
                case POLICY_VIOLATION -> R.string.account_status_policy_violation;
                case REGISTRATION_PLEASE_WAIT -> R.string.registration_please_wait;
                case REGISTRATION_PASSWORD_TOO_WEAK -> R.string.registration_password_too_weak;
                case STREAM_ERROR -> R.string.account_status_stream_error;
                case STREAM_OPENING_ERROR -> R.string.account_status_stream_opening_error;
                case PAYMENT_REQUIRED -> R.string.payment_required;
                case SEE_OTHER_HOST -> R.string.reconnect_on_other_host;
                case MISSING_INTERNET_PERMISSION -> R.string.missing_internet_permission;
                case MISSING_LOCAL_NETWORK_PERMISSION -> R.string.missing_local_network_permission;
                case TEMPORARY_AUTH_FAILURE -> R.string.account_status_temporary_auth_failure;
            };
        }
    }
}
