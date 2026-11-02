private int main(string[] args) {
    GLib.Test.init(ref args);
    if (Intl.setlocale(LocaleCategory.ALL, "") == null) return 77;
    Gst.init(ref args);
    GLib.Test.add_func("/RtpLocale/codec_tokens_reach_native_caps_without_localized_case", () => {
        var payload = new Xmpp.Xep.JingleRtp.PayloadType() { id = 96, name = "ISAC", clockrate = 16000 };
        assert(Dino.Plugins.Rtp.CodecUtil.get_codec_from_payload("audio", payload) == "isac");
        payload.name = "isac";
        var caps = Dino.Plugins.Rtp.CodecUtil.get_caps("audio", payload, false);
        assert(caps.get_structure(0).get_string("encoding-name") == "ISAC");
    });
    return GLib.Test.run();
}
