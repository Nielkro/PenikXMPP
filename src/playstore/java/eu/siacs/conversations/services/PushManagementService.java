package eu.siacs.conversations.services;

import android.content.Context;
import android.util.Log;
import androidx.concurrent.futures.CallbackToFutureAdapter;
import com.google.android.gms.common.ConnectionResult;
import com.google.android.gms.common.GoogleApiAvailabilityLight;
import com.google.common.util.concurrent.FutureCallback;
import com.google.common.util.concurrent.Futures;
import com.google.common.util.concurrent.ListenableFuture;
import com.google.common.util.concurrent.MoreExecutors;
import com.google.firebase.messaging.FirebaseMessaging;
import eu.siacs.conversations.Config;
import eu.siacs.conversations.R;
import eu.siacs.conversations.entities.Account;
import eu.siacs.conversations.utils.PhoneHelper;
import eu.siacs.conversations.xmpp.Jid;
import eu.siacs.conversations.xmpp.XmppConnection;
import eu.siacs.conversations.xmpp.manager.PushNotificationManager;
import java.util.Objects;
import org.jspecify.annotations.NonNull;

public class PushManagementService {

    protected final Context context;

    public PushManagementService(final Context service) {
        this.context = service;
    }

    private Jid getAppServer() {
        return Jid.of(context.getString(R.string.app_server));
    }

    public void registerPushTokenOnServer(final Account account) {
        final var connection = account.getXmppConnection();
        Log.d(Config.LOGTAG, account.getJid().asBareJid() + ": has push support");
        final var fcmTokenFuture = retrieveFcmInstanceToken();
        final var future =
                Futures.transformAsync(
                        fcmTokenFuture,
                        fcmToken -> {
                            final var pushManager =
                                    connection.getManager(PushNotificationManager.class);
                            Log.d(Config.LOGTAG, "FCM Token: " + fcmToken);
                            final var androidId = PhoneHelper.getAndroidId(context);
                            final var appServer = getAppServer();
                            return pushManager.registerAndEnable(appServer, fcmToken, androidId);
                        },
                        MoreExecutors.directExecutor());
        Futures.addCallback(
                future,
                new FutureCallback<>() {
                    @Override
                    public void onSuccess(Void result) {
                        Log.d(
                                Config.LOGTAG,
                                account.getJid().asBareJid() + ": successfully enabled push");
                    }

                    @Override
                    public void onFailure(@NonNull Throwable t) {
                        Log.d(Config.LOGTAG, "could not register for push", t);
                    }
                },
                MoreExecutors.directExecutor());
    }

    private @NonNull ListenableFuture<String> retrieveFcmInstanceToken() {
        return CallbackToFutureAdapter.getFuture(
                completer -> {
                    FirebaseMessaging.getInstance()
                            .getToken()
                            .addOnCompleteListener(
                                    task -> {
                                        if (task.isSuccessful()) {
                                            completer.set(task.getResult());
                                        } else {
                                            completer.setException(
                                                    Objects.requireNonNullElseGet(
                                                            task.getException(),
                                                            () ->
                                                                    new IllegalStateException(
                                                                            "Unknown error getting"
                                                                                    + " FCM token")));
                                        }
                                    });
                    return "retrieveFcmInstanceToken";
                });
    }

    public boolean available(final Account account) {
        final XmppConnection connection = account.getXmppConnection();
        return connection != null
                && connection.getFeatures().sm()
                && connection.getManager(PushNotificationManager.class).hasFeature()
                && playServicesAvailable();
    }

    private boolean playServicesAvailable() {
        return GoogleApiAvailabilityLight.getInstance().isGooglePlayServicesAvailable(context)
                == ConnectionResult.SUCCESS;
    }

    public static boolean isStub() {
        return false;
    }
}
