using Dino.Entities;
using Xmpp;
using Xmpp.Xep;

namespace Dino.Plugins.Ice {

internal static string? apply_jingle_s5b_account_proxy_policy(Account account, XmppStream stream) {
    JingleSocks5Bytestreams.Module? module = stream.get_module<JingleSocks5Bytestreams.Module>(JingleSocks5Bytestreams.Module.IDENTITY);
    if (module == null) return null;

    string? proxy_uri = Dino.build_socks5_proxy_uri(account);
    ((!) module).set_network_policy(proxy_uri == null, proxy_uri);
    return proxy_uri;
}

}
