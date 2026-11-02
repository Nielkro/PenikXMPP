using Gee;
using Dino.Plugins.GoogleWebrtc;

namespace Dino.Plugins.GoogleWebrtc.Test {

private void require_provider_device(bool condition, string message) throws Error {
    if (!condition) throw new IOError.FAILED(message);
}

internal void run_media_message_provider_device_tests() throws Error {
    // Windows GUIDs and camera unique IDs identify hardware independently of
    // the current enumeration order. Preserve both the new saved form and old
    // indexed settings when the native index changes after a restart.
    var old_windows_microphone = new EngineMediaDevice(
        new EngineAudioDeviceInfo(false, 1, "USB microphone", "{11111111-2222-3333-4444-555555555555}"));
    var windows_microphones = new ArrayList<Dino.Plugins.MediaDevice>();
    windows_microphones.add(new EngineMediaDevice(
        new EngineAudioDeviceInfo(false, 0, "USB microphone", "{11111111-2222-3333-4444-555555555555}")));
    windows_microphones.add(new EngineMediaDevice(
        new EngineAudioDeviceInfo(false, 1, "USB microphone", "{aaaaaaaa-bbbb-cccc-dddd-eeeeeeeeeeee}")));
    require_provider_device(old_windows_microphone.persistent_id == windows_microphones[0].persistent_id,
        "Windows microphone persistent IDs must not contain the enumeration index");
    require_provider_device(
        Dino.Plugins.MediaDeviceSelection.find(windows_microphones, old_windows_microphone.persistent_id) == windows_microphones[0],
        "saved Windows microphone GUIDs must select the same hardware after reordering");
    require_provider_device(
        Dino.Plugins.MediaDeviceSelection.find(windows_microphones, old_windows_microphone.id) == windows_microphones[0],
        "legacy indexed Windows microphone GUIDs must migrate without selecting the reused index");

    var old_windows_speaker = new EngineMediaDevice(
        new EngineAudioDeviceInfo(true, 1, "USB speaker", "{12345678-2222-3333-4444-555555555555}"));
    var windows_speakers = new ArrayList<Dino.Plugins.MediaDevice>();
    windows_speakers.add(new EngineMediaDevice(
        new EngineAudioDeviceInfo(true, 0, "USB speaker", "{12345678-2222-3333-4444-555555555555}")));
    windows_speakers.add(new EngineMediaDevice(
        new EngineAudioDeviceInfo(true, 1, "USB speaker", "{aaaaaaaa-bbbb-cccc-dddd-eeeeeeeeeeee}")));
    require_provider_device(
        Dino.Plugins.MediaDeviceSelection.find(windows_speakers, old_windows_speaker.persistent_id) == windows_speakers[0] &&
        Dino.Plugins.MediaDeviceSelection.find(windows_speakers, old_windows_speaker.id) == windows_speakers[0],
        "new and legacy Windows speaker settings must preserve the GUID after reordering");

    var old_identified_camera = new EngineVideoMediaDevice(
        new EngineVideoDeviceInfo(1, "USB camera", "USB\\VID_1234&PID_5678\\camera-b", "shared-product"));
    var identified_cameras = new ArrayList<Dino.Plugins.MediaDevice>();
    identified_cameras.add(new EngineVideoMediaDevice(
        new EngineVideoDeviceInfo(0, "USB camera", "USB\\VID_1234&PID_5678\\camera-b", "shared-product")));
    identified_cameras.add(new EngineVideoMediaDevice(
        new EngineVideoDeviceInfo(1, "USB camera", "USB\\VID_1234&PID_5678\\camera-a", "shared-product")));
    require_provider_device(old_identified_camera.persistent_id == identified_cameras[0].persistent_id,
        "camera persistent IDs must not contain the enumeration index");
    require_provider_device(
        Dino.Plugins.MediaDeviceSelection.find(identified_cameras, old_identified_camera.persistent_id) == identified_cameras[0] &&
        Dino.Plugins.MediaDeviceSelection.find(identified_cameras, old_identified_camera.id) == identified_cameras[0],
        "new and legacy camera settings must preserve the unique ID after reordering");

    var ambiguous_microphones = new ArrayList<Dino.Plugins.MediaDevice>();
    ambiguous_microphones.add(new EngineMediaDevice(new EngineAudioDeviceInfo(false, 0, "Same microphone", "")));
    ambiguous_microphones.add(new EngineMediaDevice(new EngineAudioDeviceInfo(false, 1, "Same microphone", "")));
    require_provider_device(
        Dino.Plugins.MediaDeviceSelection.find(ambiguous_microphones, "recording:1:") == null,
        "legacy microphone settings with empty GUIDs must not select a reused enumeration index");
    require_provider_device(
        Dino.Plugins.MediaDeviceSelection.find(ambiguous_microphones, ambiguous_microphones[1].persistent_id) == null,
        "duplicate name-only microphone identities must not silently select the first device");
    require_provider_device(
        Dino.Plugins.MediaDeviceSelection.find_selected(ambiguous_microphones, ambiguous_microphones[1]) == ambiguous_microphones[1],
        "an explicit current selection must retain the second microphone despite identical display names");

    // PulseAudio can omit all GUIDs. An empty GUID must never select the first
    // device when another microphone was explicitly chosen.
    var microphones = new ArrayList<EngineAudioDeviceInfo>();
    microphones.add(new EngineAudioDeviceInfo(false, 0, "Default microphone", ""));
    microphones.add(new EngineAudioDeviceInfo(false, 1, "USB microphone", ""));
    microphones.add(new EngineAudioDeviceInfo(false, 2, "Webcam microphone", ""));
    var usb_microphone = new EngineMediaDevice(microphones[1]);
    require_provider_device(
        GoogleWebrtcMediaMessageRecorderProvider.resolve_audio_input_device(microphones, usb_microphone) == microphones[1],
        "empty microphone GUIDs must not override the selected device");

    // The recording context enumerates again. Do not reuse a catalog index
    // after USB hotplug has changed the order.
    var reordered_microphones = new ArrayList<EngineAudioDeviceInfo>();
    reordered_microphones.add(new EngineAudioDeviceInfo(false, 0, "USB microphone", ""));
    reordered_microphones.add(new EngineAudioDeviceInfo(false, 1, "Default microphone", ""));
    require_provider_device(
        GoogleWebrtcMediaMessageRecorderProvider.resolve_audio_input_device(reordered_microphones, usb_microphone) == reordered_microphones[0],
        "the selected microphone must use the recording context's current enumeration");

    var named_microphones = new ArrayList<EngineAudioDeviceInfo>();
    named_microphones.add(new EngineAudioDeviceInfo(false, 0, "Same microphone", "guid-a"));
    named_microphones.add(new EngineAudioDeviceInfo(false, 1, "Same microphone", "guid-b"));
    require_provider_device(
        GoogleWebrtcMediaMessageRecorderProvider.resolve_audio_input_device(
            named_microphones, new EngineMediaDevice(named_microphones[1])) == named_microphones[1],
        "an exact microphone identity must take precedence over duplicate display names");
    try {
        GoogleWebrtcMediaMessageRecorderProvider.resolve_audio_input_device(
            named_microphones, new EngineMediaDevice(new EngineAudioDeviceInfo(false, 1, "Same microphone", "removed-guid")));
        throw new IOError.FAILED("a removed microphone was replaced by a device with the same name");
    } catch (Dino.Plugins.MediaMessageRecorderError e) {
        require_provider_device(e is Dino.Plugins.MediaMessageRecorderError.DEVICE_UNAVAILABLE,
            "a removed microphone must fail as device unavailable");
    }

    // Two identical cameras may share both display name and product ID. The
    // unique ID must choose the right current entry, including its new index.
    var cameras = new ArrayList<EngineVideoDeviceInfo>();
    cameras.add(new EngineVideoDeviceInfo(0, "Same camera", "camera-a", "shared-product"));
    cameras.add(new EngineVideoDeviceInfo(1, "Same camera", "camera-b", "shared-product"));
    var old_camera = new EngineVideoMediaDevice(new EngineVideoDeviceInfo(0, "Same camera", "camera-b", "shared-product"));
    require_provider_device(
        GoogleWebrtcMediaMessageRecorderProvider.resolve_video_input_device(cameras, old_camera) == cameras[1],
        "camera capture must resolve the unique ID in its own current enumeration");
    require_provider_device(
        GoogleWebrtcMediaMessageRecorderProvider.resolve_video_input_device(
            cameras, new Dino.Plugins.SystemDefaultMediaDevice("video")) == cameras[0],
        "explicit call system-default camera must not apply message camera preferences");
    try {
        GoogleWebrtcMediaMessageRecorderProvider.resolve_video_input_device(
            cameras, new EngineVideoMediaDevice(new EngineVideoDeviceInfo(0, "Same camera", "removed-camera", "shared-product")));
        throw new IOError.FAILED("a removed camera was replaced by a device with the same product ID");
    } catch (Dino.Plugins.MediaMessageRecorderError e) {
        require_provider_device(e is Dino.Plugins.MediaMessageRecorderError.DEVICE_UNAVAILABLE,
            "a removed camera must fail as device unavailable");
    }
    try {
        GoogleWebrtcMediaMessageRecorderProvider.resolve_video_input_device(
            cameras, new Dino.Plugins.SystemDefaultMediaDevice("audio"));
        throw new IOError.FAILED("an audio default marker was accepted as a camera");
    } catch (Dino.Plugins.MediaMessageRecorderError e) {
        require_provider_device(e is Dino.Plugins.MediaMessageRecorderError.DEVICE_UNAVAILABLE,
            "default device markers must match their media type");
    }

    var contexts = new ArrayList<EngineContext>();
    var playback_provider = new GoogleWebrtcMediaMessagePlaybackProvider(
        () => {
            var context = new EngineContext();
            contexts.add(context);
            return context;
        },
        () => { return ""; },
        true);
    playback_provider.get_audio_output_devices();
    require_provider_device(contexts.size == 1 && contexts[0].is_closed,
        "owned speaker enumeration contexts must be closed");
    Dino.Plugins.MediaMessagePlaybackSession playback = playback_provider.create_audio_playback_session();
    require_provider_device(contexts.size == 2 && !contexts[1].is_closed,
        "playback must use a fresh owned context");
    playback.start(48000, 1, 2);
    uint8[] pcm = new uint8[960 * 2];
    playback.push_pcm(new Bytes(pcm));
    playback.stop();
    playback.stop();
    require_provider_device(contexts[1].is_closed && contexts[1].active_non_call_activity_count == 0,
        "stopped playback must close its owned context after releasing the activity lease");

    playback = playback_provider.create_audio_playback_session();
    require_provider_device(contexts.size == 3 && contexts[2] != contexts[1],
        "a new system-default playback must not retain the previous device context");
    try {
        playback.start(0, 1, 2);
        throw new IOError.FAILED("invalid playback format unexpectedly started");
    } catch (EngineError e) {
        require_provider_device(contexts[2].is_closed && !playback.active,
            "playback startup failure must close its owned context");
    }
    playback = playback_provider.create_audio_playback_session();
    playback.start(48000, 1, 2);
    try {
        playback.push_pcm(new Bytes(new uint8[0]));
        throw new IOError.FAILED("empty playback PCM unexpectedly succeeded");
    } catch (EngineError e) {
        require_provider_device(contexts[3].is_closed && !playback.active,
            "native PCM failure must stop playback and close its owned context");
    }
    playback_provider.stop_current_session();
}

}
