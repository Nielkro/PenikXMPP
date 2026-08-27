package eu.siacs.conversations.utils;

import com.google.common.net.InetAddresses;
import java.net.InetAddress;

public class IP {

    public static String wrapIPv6(final String host) {
        if (InetAddresses.isInetAddress(host)) {
            final InetAddress inetAddress;
            try {
                inetAddress = InetAddresses.forString(host);
            } catch (final IllegalArgumentException e) {
                return host;
            }
            return InetAddresses.toUriString(inetAddress);
        } else {
            return host;
        }
    }

    public static String unwrapIPv6(final String host) {
        if (host.length() > 2 && host.charAt(0) == '[' && host.charAt(host.length() - 1) == ']') {
            final String ip = host.substring(1, host.length() - 1);
            if (InetAddresses.isInetAddress(ip)) {
                return ip;
            }
        }
        return host;
    }
}
