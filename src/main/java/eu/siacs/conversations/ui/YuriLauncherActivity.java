package eu.siacs.conversations.ui;

import android.content.Intent;
import android.os.Bundle;
import android.os.Handler;
import android.os.Looper;
import android.util.Log;
import android.widget.Toast;
import androidx.appcompat.app.AppCompatActivity;
import de.gultsch.common.MiniUri;
import eu.siacs.conversations.Config;
import eu.siacs.conversations.R;
import eu.siacs.conversations.utils.SignupUtils;
import eu.siacs.conversations.utils.XmppUriLauncher;
import eu.siacs.conversations.xmpp.Jid;

public class YuriLauncherActivity extends AppCompatActivity {

    @Override
    public void onCreate(final Bundle savedInstanceState) {
        super.onCreate(savedInstanceState);
        final var intent = getIntent();
        final var data = intent == null ? null : intent.getData();
        if (data == null) {
            new Handler(Looper.getMainLooper()).post(this::finish);
            return;
        }
        final String path = data.getPath();
        if (path != null && path.contains("/invite/")) {
            final String[] parts = path.split("/");
            String token = null;
            for (int i = 0; i < parts.length; i++) {
                if ("invite".equals(parts[i]) && i + 1 < parts.length && !parts[i + 1].isEmpty()) {
                    token = parts[i + 1];
                    break;
                }
            }
            if (token != null) {
                final String domain = data.getHost() != null ? data.getHost() : (Config.MAGIC_CREATE_DOMAIN != null ? Config.MAGIC_CREATE_DOMAIN : "snikket.penik.ru");
                final Intent regIntent = SignupUtils.getTokenRegistrationIntent(this, Jid.of(domain), token);
                regIntent.setFlags(Intent.FLAG_ACTIVITY_NEW_TASK | Intent.FLAG_ACTIVITY_CLEAR_TOP);
                startActivity(regIntent);
                finish();
                return;
            }
        }
        final MiniUri uri;
        try {
            uri = MiniUri.tryInternalParse(data.toString());
        } catch (final IllegalArgumentException e) {
            Log.d(Config.LOGTAG, "could not parse mini uri", e);
            Toast.makeText(this, R.string.invalid_jid, Toast.LENGTH_LONG).show();
            new Handler(Looper.getMainLooper()).post(this::finish);
            return;
        }
        final MiniUri.Xmpp xmpp;
        if (uri instanceof MiniUri.Xmpp x) {
            xmpp = x;
        } else if (uri instanceof MiniUri.Transformable t
                && t.transform() instanceof MiniUri.Xmpp x) {
            xmpp = x;
        } else {
            Log.d(Config.LOGTAG, "mini uri is of unknown type: " + uri.getClass().getSimpleName());
            Toast.makeText(this, R.string.invalid_jid, Toast.LENGTH_LONG).show();
            new Handler(Looper.getMainLooper()).post(this::finish);
            return;
        }
        final var launcher = new XmppUriLauncher(this);
        launcher.launch(xmpp);
        new Handler(Looper.getMainLooper()).post(this::finish);
    }
}
