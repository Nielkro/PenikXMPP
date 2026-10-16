package eu.siacs.conversations.xmpp.fun;

import android.util.Log;
import eu.siacs.conversations.Config;
import eu.siacs.conversations.xml.Element;
import java.io.ByteArrayOutputStream;
import java.io.DataOutputStream;
import java.io.IOException;
import java.io.OutputStream;
import java.nio.charset.StandardCharsets;
import java.util.List;
import java.util.Map;

public class FunWriter {

    private final OutputStream out;

    public FunWriter(final OutputStream out) {
        this.out = out;
    }

    public synchronized void writeElement(final Element element) throws IOException {
        final byte[] payload;
        try {
            payload = encodeNode(element);
        } catch (IllegalArgumentException e) {
            Log.e(Config.LOGTAG, "FunXMPP: dropping malformed stanza: " + e.getMessage());
            return;
        }
        if (payload != null) {
            out.write(payload);
            out.flush();
        }
    }

    public static byte[] encodeNode(final Element element) throws IOException {
        return encodeNode(element, eu.siacs.conversations.xml.Namespace.JABBER_CLIENT);
    }

    public static byte[] encodeNode(final Element element, final String parentNamespace) throws IOException {
        final ByteArrayOutputStream nodeBytes = new ByteArrayOutputStream();
        final DataOutputStream data = new DataOutputStream(nodeBytes);

        // 1. Tag name
        writeTokenOrString(data, element.getName());

        // Current namespace resolution
        final String elemNs = element.getNamespace();
        final String currentNs = elemNs != null ? elemNs : parentNamespace;

        // 2. Attributes
        final Map<String, String> attrs = new java.util.HashMap<>(element.getAttributes());
        if (elemNs != null && !elemNs.equals(parentNamespace) && !eu.siacs.conversations.xml.Namespace.JABBER_CLIENT.equals(elemNs)) {
            attrs.put("xmlns", elemNs);
        } else if (eu.siacs.conversations.xml.Namespace.JABBER_CLIENT.equals(elemNs) || (parentNamespace != null && parentNamespace.equals(elemNs))) {
            attrs.remove("xmlns");
        }
        final java.util.List<Map.Entry<String, String>> attrList = new java.util.ArrayList<>(attrs.entrySet());
        attrList.sort(Map.Entry.comparingByKey());
        if (attrList.size() > 255) {
            throw new IllegalArgumentException("FunXMPP element has more than 255 attributes: " + element.getName());
        }
        data.writeByte(attrList.size());
        for (final Map.Entry<String, String> entry : attrList) {
            writeTokenOrString(data, entry.getKey());
            writeTokenOrString(data, entry.getValue());
        }

        // 3. Content: Children vs Text vs Mixed vs Empty
        final List<Element> children = element.getChildren();
        final String text = element.getContent();
        final boolean hasChildren = !children.isEmpty();
        final boolean hasText = text != null && !text.isEmpty();

        if (hasChildren && hasText) {
            data.writeByte(FunTokens.CONTENT_MIXED);
            final byte[] utf8 = text.getBytes(StandardCharsets.UTF_8);
            if (utf8.length < 0xFFFF) {
                data.writeShort(utf8.length);
            } else {
                data.writeShort(0xFFFF);
                data.writeInt(utf8.length);
            }
            data.write(utf8);
            data.writeShort(children.size());
            for (final Element child : children) {
                final byte[] childBytes = encodeNode(child, currentNs);
                data.write(childBytes);
            }
        } else if (hasChildren) {
            data.writeByte(FunTokens.CONTENT_CHILDREN);
            data.writeShort(children.size());
            for (final Element child : children) {
                final byte[] childBytes = encodeNode(child, currentNs);
                data.write(childBytes);
            }
        } else if (hasText) {
            data.writeByte(FunTokens.CONTENT_TEXT);
            final byte[] utf8 = text.getBytes(StandardCharsets.UTF_8);
            if (utf8.length < 0xFFFF) {
                data.writeShort(utf8.length);
            } else {
                data.writeShort(0xFFFF);
                data.writeInt(utf8.length);
            }
            data.write(utf8);
        } else {
            data.writeByte(FunTokens.CONTENT_EMPTY);
        }

        data.flush();
        final byte[] body = nodeBytes.toByteArray();

        // Wrap with Length prefix (2 bytes if < 0xFFFF, or 0xFFFF marker + 4 bytes for large stanzas)
        if (body.length < 0xFFFF) {
            final ByteArrayOutputStream finalOut = new ByteArrayOutputStream(body.length + 2);
            final DataOutputStream finalData = new DataOutputStream(finalOut);
            finalData.writeShort(body.length);
            finalData.write(body);
            finalData.flush();
            return finalOut.toByteArray();
        } else {
            final ByteArrayOutputStream finalOut = new ByteArrayOutputStream(body.length + 6);
            final DataOutputStream finalData = new DataOutputStream(finalOut);
            finalData.writeShort(0xFFFF);
            finalData.writeInt(body.length);
            finalData.write(body);
            finalData.flush();
            return finalOut.toByteArray();
        }
    }

    public static void writeTokenOrString(final DataOutputStream data, final String str) throws IOException {
        if (str == null) {
            data.writeByte(FunTokens.LITERAL_STRING_8);
            data.writeByte(0);
            return;
        }
        final Integer token = FunTokens.getToken(str);
        if (token != null && token >= 0 && token < 240) {
            data.writeByte(token);
            return;
        }

        final int atPos = str.indexOf('@');
        if (atPos > 0) {
            final int slashPos = str.indexOf('/', atPos + 1);
            final String user = str.substring(0, atPos);
            final String domain = slashPos == -1 ? str.substring(atPos + 1) : str.substring(atPos + 1, slashPos);
            final Integer domainToken = FunTokens.getToken(domain);
            if (domainToken != null && domainToken >= 0 && domainToken < 240) {
                if (slashPos == -1) {
                    data.writeByte(FunTokens.JID_BARE);
                    writeTokenOrString(data, user);
                    data.writeByte(domainToken);
                    return;
                } else {
                    final String resource = str.substring(slashPos + 1);
                    data.writeByte(FunTokens.JID_FULL);
                    writeTokenOrString(data, user);
                    data.writeByte(domainToken);
                    writeTokenOrString(data, resource);
                    return;
                }
            }
        }

        final byte[] utf8 = str.getBytes(StandardCharsets.UTF_8);
        if (utf8.length <= 255) {
            data.writeByte(FunTokens.LITERAL_STRING_8);
            data.writeByte(utf8.length);
            data.write(utf8);
        } else if (utf8.length <= 65535) {
            data.writeByte(FunTokens.LITERAL_STRING_16);
            data.writeShort(utf8.length);
            data.write(utf8);
        } else {
            data.writeByte(FunTokens.LITERAL_STRING_32);
            data.writeInt(utf8.length);
            data.write(utf8);
        }
    }

    public void flush() throws IOException {
        out.flush();
    }
}
