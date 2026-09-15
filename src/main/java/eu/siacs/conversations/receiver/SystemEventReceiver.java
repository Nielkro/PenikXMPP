package eu.siacs.conversations.receiver;

import android.content.BroadcastReceiver;
import android.content.Context;
import android.content.Intent;
import android.media.AudioManager;
import android.net.ConnectivityManager;
import android.util.Log;
import com.google.common.base.Strings;
import com.google.common.collect.ImmutableSet;
import eu.siacs.conversations.Config;
import eu.siacs.conversations.Conversations;
import eu.siacs.conversations.services.XmppConnectionService;
import eu.siacs.conversations.utils.Compatibility;
import java.util.Set;

public class SystemEventReceiver extends BroadcastReceiver {

    private static final Set<String> ALLOWED_ACTIONS =
            ImmutableSet.of(
                    Intent.ACTION_BOOT_COMPLETED,
                    Intent.ACTION_MY_PACKAGE_REPLACED,
                    ConnectivityManager.CONNECTIVITY_ACTION,
                    AudioManager.RINGER_MODE_CHANGED_ACTION,
                    Intent.ACTION_AIRPLANE_MODE_CHANGED,
                    XmppConnectionService.ACTION_PING,
                    XmppConnectionService.ACTION_PING_IDLE,
                    XmppConnectionService.ACTION_POST_CONNECTIVITY_CHANGE);

    @Override
    public void onReceive(final Context context, final Intent intent) {
        final var extras = intent.getExtras();
        final var action = intent.getAction();
        if (Strings.isNullOrEmpty(action)) {
            return;
        }
        if (ALLOWED_ACTIONS.contains(action)
                && Conversations.getInstance(context).hasEnabledAccount()) {
            Log.d(Config.LOGTAG, "EventReceiver starting service for " + action);
            final var service = new Intent(context, XmppConnectionService.class);
            service.setAction(action);
            if (extras != null && !extras.isEmpty()) {
                service.putExtras(extras);
            }
            Compatibility.startService(context, service);
        } else {
            Log.d(Config.LOGTAG, "EventReceiver ignored action " + action);
        }
    }
}
