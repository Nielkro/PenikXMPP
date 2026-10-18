package eu.siacs.conversations.utils;

import android.content.Context;
import android.content.Intent;
import de.gultsch.common.MiniUri;
import eu.siacs.conversations.R;
import eu.siacs.conversations.entities.Message;
import eu.siacs.conversations.ui.ShowLocationActivity;
import org.osmdroid.util.GeoPoint;

public class GeoHelper {

    public static void view(final Context context, final Message message) {
        final var miniUri = MiniUri.getOrNull(message.getBody());
        if (miniUri instanceof MiniUri.Geo geo) {
            final var intent = new Intent(Intent.ACTION_VIEW);
            final String label;
            if (message.getStatus() == Message.STATUS_RECEIVED) {
                label = UIHelper.getMessageDisplayName(message);
            } else {
                label = context.getString(R.string.me);
            }
            intent.setData(geo.asUniversalUri(label));
            context.startActivity(intent);
        }
    }

    public static boolean isResolveUniversalUri(final Context context, final Message message) {
        final var miniUri = MiniUri.getOrNull(message.getBody());
        if (miniUri instanceof MiniUri.Geo geo) {
            final var intent = new Intent(Intent.ACTION_VIEW);
            return intent.setData(geo.asUniversalUri()).resolveActivity(context.getPackageManager())
                    != null;
        } else {
            return false;
        }
    }

    public static Intent showLocationIntent(final Context context, final Message message) {
        final GeoPoint geoPoint;
        final var miniUri = MiniUri.getOrNull(message.getBody());
        if (miniUri instanceof MiniUri.Geo geo) {
            geoPoint = geo.asGeoPoint();
        } else {
            geoPoint = new GeoPoint(0.0, 0.0);
        }
        final Intent intent = new Intent(context, ShowLocationActivity.class);
        intent.setAction(ShowLocationActivity.ACTION_SHOW_LOCATION);
        intent.putExtra("latitude", geoPoint.getLatitude());
        intent.putExtra("longitude", geoPoint.getLongitude());
        return intent;
    }
}
