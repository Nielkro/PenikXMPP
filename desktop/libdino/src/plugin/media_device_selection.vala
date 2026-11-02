using Gee;

namespace Dino.Plugins {

// An explicit platform default is different from a missing override, which
// recorder providers interpret as using the message-device preference.
public class SystemDefaultMediaDevice : Object, MediaDevice {
    private string media_kind;
    private bool incoming_device;
    public string id { owned get { return ""; } }
    public string display_name { owned get { return "System Default"; } }
    public string? detail_name { owned get { return null; } }
    public string? media { owned get { return media_kind; } }
    public bool incoming { get { return incoming_device; } }

    public SystemDefaultMediaDevice(string media, bool incoming = false) {
        this.media_kind = media;
        this.incoming_device = incoming;
    }
}

public class MediaDeviceSelection : Object {
    public static bool is_indexed_identifier(string value) {
        string[] parts = value.split(":", 3);
        if (parts.length != 3 || (parts[0] != "recording" && parts[0] != "playout" && parts[0] != "video")) return false;
        int index;
        return int.try_parse(parts[1], out index) && index >= 0;
    }

    public static MediaDevice? find(Gee.List<MediaDevice> devices, string saved) {
        if (saved == "") return null;
        MediaDevice? found = null;
        int matches = 0;
        foreach (MediaDevice device in devices) {
            if (device.persistent_id != "" && device.persistent_id == saved) {
                found = device;
                matches++;
            }
        }
        // In particular, duplicate name-only identities are ambiguous. Do not
        // fall through and pick the first device in the current enumeration.
        if (matches != 0) return matches == 1 ? found : null;
        foreach (MediaDevice device in devices) {
            if (device.matches_saved_identifier(saved)) {
                found = device;
                matches++;
            }
        }
        if (matches != 0) return matches == 1 ? found : null;
        // Identified hardware that disappeared must not be substituted by an
        // unrelated device with the same friendly name.
        if (saved.has_prefix("webrtc:") || is_indexed_identifier(saved)) return null;
        foreach (MediaDevice device in devices) {
            if (device.display_name == saved) {
                found = device;
                matches++;
            }
        }
        return matches == 1 ? found : null;
    }

    public static MediaDevice? find_selected(Gee.List<MediaDevice> devices, MediaDevice selected) {
        if (selected is SystemDefaultMediaDevice) return selected;
        // A current runtime ID takes precedence over friendly names. Also
        // check the persistent identity so a reused empty-GUID index cannot
        // silently select a different named device after hotplug.
        foreach (MediaDevice candidate in devices) {
            if (candidate.media == selected.media && candidate.incoming == selected.incoming &&
                    candidate.id != "" && candidate.id == selected.id &&
                    candidate.persistent_id == selected.persistent_id) return candidate;
        }
        return find(devices, selected.persistent_id);
    }
}

}
