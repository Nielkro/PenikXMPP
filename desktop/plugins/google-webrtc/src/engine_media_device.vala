namespace Dino.Plugins.GoogleWebrtc {

public class EngineMediaDevice : Dino.Plugins.MediaDevice, Object {
    public EngineAudioDeviceInfo info { get; private set; }

    public string id { owned get { return info.id; } }
    public string persistent_id { owned get {
        return "webrtc:audio:%s:%s:%s".printf(
            info.incoming ? "playout" : "recording", info.guid != "" ? "guid" : "name",
            Uri.escape_string(info.guid != "" ? info.guid : info.display_name, null, false));
    }}
    public bool matches_saved_identifier(string value) {
        if (value == persistent_id) return true;
        if (info.guid == "") return false;
        if (value == info.guid) return true;
        string[] parts = value.split(":", 3);
        return MediaDeviceSelection.is_indexed_identifier(value) &&
            parts[0] == (info.incoming ? "playout" : "recording") && parts[2] == info.guid;
    }
    public string display_name { owned get {
        if (info.display_name != "") return info.display_name;
        return info.incoming ? "Google/libwebrtc speaker" : "Google/libwebrtc microphone";
    }}
    public string? detail_name { owned get {
        return info.guid != "" ? info.guid : null;
    }}
    public string? media { owned get { return "audio"; } }
    public bool incoming { get { return info.incoming; } }

    public EngineMediaDevice(EngineAudioDeviceInfo info) {
        this.info = info;
    }
}

public class EngineVideoMediaDevice : Dino.Plugins.MediaDevice, Object {
    public EngineVideoDeviceInfo info { get; private set; }

    public string id { owned get { return info.id; } }
    public string persistent_id { owned get {
        return "webrtc:video:%s:%s".printf(info.unique_id != "" ? "uid" : "name",
            Uri.escape_string(info.unique_id != "" ? info.unique_id : info.display_name, null, false));
    }}
    public bool matches_saved_identifier(string value) {
        if (value == persistent_id) return true;
        if (info.unique_id == "") return false;
        if (value == info.unique_id) return true;
        string[] parts = value.split(":", 3);
        return MediaDeviceSelection.is_indexed_identifier(value) &&
            parts[0] == "video" && parts[2] == info.unique_id;
    }
    public string display_name { owned get {
        if (info.display_name != "") return info.display_name;
        return "Google/libwebrtc camera";
    }}
    public string? detail_name { owned get {
        if (info.product_id != "") return info.product_id;
        if (info.unique_id != "") return info.unique_id;
        return null;
    }}
    public string? media { owned get { return "video"; } }
    public bool incoming { get { return false; } }

    public EngineVideoMediaDevice(EngineVideoDeviceInfo info) {
        this.info = info;
    }
}

}
