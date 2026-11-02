using GLib;

namespace Dino.Ui {

    public class LocationManager : Object {
        private static LocationManager? instance;
        private bool request_in_progress = false;

        public static LocationManager get_default() {
            if (instance == null) {
                instance = new LocationManager();
            }
            return instance;
        }

        private LocationManager() {}

        public bool is_busy() {
            return request_in_progress;
        }

        public async void get_location(Cancellable? cancellable, out double lat, out double lon, out double accuracy) throws Error {
            lat = 0;
            lon = 0;
            accuracy = 0;

            if (request_in_progress) {
                throw new IOError.PENDING(_("A location request is already in progress."));
            }
            request_in_progress = true;

#if HAVE_GEOCLUE
            try {
                var simple = yield new GClue.Simple("im.dinox.dinox", GClue.AccuracyLevel.EXACT, cancellable);
                var location = simple.get_location();
                lat = location.latitude;
                lon = location.longitude;
                accuracy = location.accuracy;
                debug("LocationManager: GeoClue2 returned %.6f, %.6f (accuracy: %.0f m)", lat, lon, accuracy);
                // Release GeoClue client to stop GPS/WiFi scanning (battery)
                try {
                    yield simple.client.call_stop(null);
                } catch (Error stop_err) {
                    debug("LocationManager: call_stop() failed (non-critical): %s", stop_err.message);
                }
            } finally {
                request_in_progress = false;
            }
#else
            request_in_progress = false;
            throw new IOError.NOT_SUPPORTED(_("Location services are not available (GeoClue2 not installed)."));
#endif
        }

        public bool is_available() {
#if HAVE_GEOCLUE
            return true;
#else
            return false;
#endif
        }
    }
}
