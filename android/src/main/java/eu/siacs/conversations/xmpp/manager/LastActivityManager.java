package eu.siacs.conversations.xmpp.manager;

import android.util.Log;
import com.google.common.cache.Cache;
import com.google.common.cache.CacheBuilder;
import com.google.common.util.concurrent.FutureCallback;
import com.google.common.util.concurrent.Futures;
import com.google.common.util.concurrent.MoreExecutors;
import eu.siacs.conversations.AppSettings;
import eu.siacs.conversations.Config;
import eu.siacs.conversations.entities.Contact;
import eu.siacs.conversations.services.XmppConnectionService;
import eu.siacs.conversations.xmpp.Jid;
import eu.siacs.conversations.xmpp.XmppConnection;
import im.conversations.android.xmpp.model.error.Condition;
import im.conversations.android.xmpp.model.last.Query;
import im.conversations.android.xmpp.model.stanza.Iq;
import java.time.Duration;
import java.time.Instant;
import org.jspecify.annotations.NonNull;

public class LastActivityManager extends AbstractManager {

    private final XmppConnectionService service;
    private final AppSettings appSettings;
    private final Cache<Jid, Long> queryCooldown =
            CacheBuilder.newBuilder()
                    .expireAfterWrite(Duration.ofMinutes(5))
                    .maximumSize(500)
                    .build();

    public LastActivityManager(final XmppConnectionService service, final XmppConnection connection) {
        super(service.getApplicationContext(), connection);
        this.service = service;
        this.appSettings = new AppSettings(context.getApplicationContext());
    }

    public void handleLastActivityRequest(final Iq packet) {
        if (this.appSettings.isUseTor() || getAccount().isOnion() || !this.appSettings.isBroadcastLastActivity()) {
            this.connection.sendErrorFor(packet, new Condition.Forbidden());
            return;
        }
        final var from = packet.getFrom();
        if (from == null) {
            this.connection.sendErrorFor(packet, new Condition.NotAcceptable());
            return;
        }
        final var contact = getManager(RosterManager.class).getContactFromContactList(from);
        if (contact != null && contact.showInContactList()) {
            final long lastActivity = this.service.getLastActivity();
            final long idleSeconds;
            if (lastActivity > 0) {
                idleSeconds = Math.max(0, (System.currentTimeMillis() - lastActivity) / 1000);
            } else {
                idleSeconds = 0;
            }
            Log.d(
                    Config.LOGTAG,
                    getAccount().getJid().asBareJid()
                            + ": responding to last activity request from "
                            + from
                            + " ("
                            + idleSeconds
                            + "s)");
            this.connection.sendResultFor(packet, new Query(idleSeconds));
        } else {
            this.connection.sendErrorFor(packet, new Condition.Forbidden());
        }
    }

    public void retrieveLastActivity(final Contact contact, final Runnable onUpdated) {
        if (contact == null) {
            return;
        }
        final Jid address = contact.getAddress().asBareJid();
        if (this.queryCooldown.getIfPresent(address) != null) {
            return;
        }
        this.queryCooldown.put(address, System.currentTimeMillis());

        Log.d(Config.LOGTAG, "Querying last activity for " + address);
        final Iq request = new Iq(Iq.Type.GET, address, new Query());
        final var future = this.connection.sendIqPacket(request);
        Futures.addCallback(
                future,
                new FutureCallback<>() {
                    @Override
                    public void onSuccess(final Iq result) {
                        if (result != null && result.getType() == Iq.Type.RESULT) {
                            final Query query = result.getExtension(Query.class);
                            Log.d(Config.LOGTAG, "Received last activity for " + address + ": " + (query != null ? query.getSeconds() : "null") + "s");
                            if (query != null) {
                                final Instant instant = query.getInstant();
                                if (instant != null) {
                                    contact.setLastActivity(instant);
                                    if (onUpdated != null) {
                                        onUpdated.run();
                                    }
                                }
                            }
                        } else {
                            Log.d(Config.LOGTAG, "Received non-result last activity response for " + address + ": " + (result != null ? result.getType() : "null"));
                        }
                    }

                    @Override
                    public void onFailure(@NonNull final Throwable t) {
                        Log.d(
                                Config.LOGTAG,
                                "Could not fetch last activity for "
                                        + address
                                        + ": "
                                        + t.getMessage());
                    }
                },
                MoreExecutors.directExecutor());
    }
}
