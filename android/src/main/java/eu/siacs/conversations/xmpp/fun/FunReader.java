package eu.siacs.conversations.xmpp.fun;

import eu.siacs.conversations.xml.Element;
import java.io.ByteArrayInputStream;
import java.io.DataInputStream;
import java.io.EOFException;
import java.io.IOException;
import java.io.InputStream;
import java.nio.charset.StandardCharsets;

public class FunReader {

    private final DataInputStream in;
    private final String negotiatedDict;

    public static final int MAX_FRAME_SIZE = 1024 * 1024; // 1 MB frame limit

    public FunReader(final InputStream in) {
        this(in, FunTokens.DICTIONARY_HASH);
    }

    public FunReader(final InputStream in, final String negotiatedDict) {
        this.in = new DataInputStream(in);
        this.negotiatedDict = negotiatedDict != null ? negotiatedDict : FunTokens.DICTIONARY_HASH;
    }

    public Element readElement() throws IOException {
        int nodeLength;
        try {
            nodeLength = in.readUnsignedShort();
        } catch (EOFException e) {
            return null;
        }
        if (nodeLength == 0xFFFF) {
            nodeLength = in.readInt();
        }

        if (nodeLength > MAX_FRAME_SIZE || nodeLength < 0) {
            throw new IOException("FunXMPP frame length exceeds limit: " + nodeLength);
        }

        final byte[] nodeData = new byte[nodeLength];
        in.readFully(nodeData);

        final DataInputStream nodeStream = new DataInputStream(new ByteArrayInputStream(nodeData));
        return decodeNode(nodeStream, eu.siacs.conversations.xml.Namespace.JABBER_CLIENT, negotiatedDict);
    }

    public static Element decodeNode(final DataInputStream stream, final String parentNamespace) throws IOException {
        return decodeNode(stream, parentNamespace, FunTokens.DICTIONARY_HASH);
    }

    public static Element decodeNode(final DataInputStream stream, final String parentNamespace, final String negotiatedDict) throws IOException {
        String tagName = readTokenOrString(stream, negotiatedDict);
        if (tagName == null) {
            return null;
        }

        // Attributes
        final int attrCount = stream.readUnsignedByte();
        final java.util.Map<String, String> attrs = new java.util.HashMap<>(attrCount * 2);
        for (int i = 0; i < attrCount; i++) {
            final String key = readTokenOrString(stream, negotiatedDict);
            final String val = readTokenOrString(stream, negotiatedDict);
            if (key != null && val != null) {
                attrs.put(key, val);
            }
        }

        String ns = attrs.get("xmlns");
        if (ns == null) {
            ns = parentNamespace;
        }

        if (tagName.startsWith("stream:")) {
            tagName = tagName.substring(7);
            ns = eu.siacs.conversations.xml.Namespace.STREAMS;
        } else if ("stream".equals(tagName)) {
            ns = eu.siacs.conversations.xml.Namespace.STREAMS;
        }

        if (ns != null && ns.equals(parentNamespace)) {
            attrs.remove("xmlns");
        } else if (ns != null) {
            attrs.put("xmlns", ns);
        }

        final Element element = im.conversations.android.xmpp.ExtensionFactory.create(
                new im.conversations.android.xmpp.ExtensionFactory.Id(tagName, ns));
        element.setAttributes(attrs);

        // Content: Children vs Text vs Mixed vs Empty
        final int contentType = stream.readUnsignedByte();
        if (contentType == FunTokens.CONTENT_CHILDREN) {
            readChildren(stream, element, ns, negotiatedDict);
        } else if (contentType == FunTokens.CONTENT_TEXT) {
            readText(stream, element);
        } else if (contentType == FunTokens.CONTENT_MIXED) {
            readText(stream, element);
            readChildren(stream, element, ns, negotiatedDict);
        }

        return element;
    }

    private static void readChildren(final DataInputStream stream, final Element element, final String ns, final String negotiatedDict) throws IOException {
        final int childrenCount = stream.readUnsignedShort();
        for (int i = 0; i < childrenCount; i++) {
            int childLen = stream.readUnsignedShort();
            if (childLen == 0xFFFF) {
                childLen = stream.readInt();
            }
            if (childLen <= 0 || childLen > stream.available()) {
                throw new IOException("FunXMPP: invalid child length: " + childLen + ", available: " + stream.available());
            }
            final byte[] childBytes = new byte[childLen];
            stream.readFully(childBytes);
            final DataInputStream childStream = new DataInputStream(new ByteArrayInputStream(childBytes));
            final Element child = decodeNode(childStream, ns, negotiatedDict);
            if (child != null) {
                element.addChild(child);
            }
        }
    }

    private static void readText(final DataInputStream stream, final Element element) throws IOException {
        int textLen = stream.readUnsignedShort();
        if (textLen == 0xFFFF) {
            textLen = stream.readInt();
        }
        if (textLen < 0 || textLen > stream.available()) {
            throw new IOException("FunXMPP: invalid text length: " + textLen + ", available: " + stream.available());
        }
        final byte[] textBytes = new byte[textLen];
        stream.readFully(textBytes);
        element.setContent(new String(textBytes, StandardCharsets.UTF_8));
    }

    public static String readTokenOrString(final DataInputStream stream) throws IOException {
        return readTokenOrString(stream, FunTokens.DICTIONARY_HASH);
    }

    public static String readTokenOrString(final DataInputStream stream, final String negotiatedDict) throws IOException {
        final int tokenByte = stream.readUnsignedByte();
        if (tokenByte == (FunTokens.LITERAL_STRING_8 & 0xFF)) {
            final int len = stream.readUnsignedByte();
            if (len > stream.available()) {
                throw new IOException("FunXMPP: literal string length exceeds bounds: " + len);
            }
            final byte[] bytes = new byte[len];
            stream.readFully(bytes);
            return new String(bytes, StandardCharsets.UTF_8);
        } else if (tokenByte == (FunTokens.LITERAL_STRING_16 & 0xFF)) {
            final int len = stream.readUnsignedShort();
            if (len > stream.available()) {
                throw new IOException("FunXMPP: literal string length exceeds bounds: " + len);
            }
            final byte[] bytes = new byte[len];
            stream.readFully(bytes);
            return new String(bytes, StandardCharsets.UTF_8);
        } else if (tokenByte == (FunTokens.LITERAL_STRING_32 & 0xFF)) {
            final int len = stream.readInt();
            if (len < 0 || len > stream.available()) {
                throw new IOException("FunXMPP: invalid literal string length: " + len);
            }
            final byte[] bytes = new byte[len];
            stream.readFully(bytes);
            return new String(bytes, StandardCharsets.UTF_8);
        } else if (tokenByte == (FunTokens.JID_BARE & 0xFF)) {
            final String user = readTokenOrString(stream, negotiatedDict);
            final int domainToken = stream.readUnsignedByte();
            final String domain = FunTokens.getString(domainToken, negotiatedDict);
            if (domain == null) {
                throw new IOException("FunXMPP: unknown domain token 0x" + Integer.toHexString(domainToken));
            }
            return (user != null ? user : "") + "@" + domain;
        } else if (tokenByte == (FunTokens.JID_FULL & 0xFF)) {
            final String user = readTokenOrString(stream, negotiatedDict);
            final int domainToken = stream.readUnsignedByte();
            final String domain = FunTokens.getString(domainToken, negotiatedDict);
            if (domain == null) {
                throw new IOException("FunXMPP: unknown domain token 0x" + Integer.toHexString(domainToken));
            }
            final String resource = readTokenOrString(stream, negotiatedDict);
            return (user != null ? user : "") + "@" + domain + "/" + (resource != null ? resource : "");
        } else {
            final String resolved = FunTokens.getString(tokenByte, negotiatedDict);
            if (resolved != null) {
                return resolved;
            }
            throw new IOException("FunXMPP: unknown token 0x" + Integer.toHexString(tokenByte));
        }
    }
}
