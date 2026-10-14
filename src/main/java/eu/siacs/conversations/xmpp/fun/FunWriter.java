package eu.siacs.conversations.xmpp.fun;

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
        final byte[] payload = encodeNode(element);
        out.write(payload);
        out.flush();
    }

    public static byte[] encodeNode(final Element element) throws IOException {
        final ByteArrayOutputStream nodeBytes = new ByteArrayOutputStream();
        final DataOutputStream data = new DataOutputStream(nodeBytes);

        // 1. Tag name
        writeTokenOrString(data, element.getName());

        // 2. Attributes
        final Map<String, String> attrs = new java.util.HashMap<>(element.getAttributes());
        if (element.getNamespace() != null && !attrs.containsKey("xmlns")) {
            attrs.put("xmlns", element.getNamespace());
        }
        data.writeByte(attrs.size());
        for (final Map.Entry<String, String> entry : attrs.entrySet()) {
            writeTokenOrString(data, entry.getKey());
            writeTokenOrString(data, entry.getValue());
        }

        // 3. Content: Children vs Text vs Empty
        final List<Element> children = element.getChildren();
        final String text = element.getContent();
        if (!children.isEmpty()) {
            data.writeByte(FunTokens.CONTENT_CHILDREN);
            data.writeShort(children.size());
            for (final Element child : children) {
                final byte[] childBytes = encodeNode(child);
                data.write(childBytes);
            }
        } else if (text != null && !text.isEmpty()) {
            data.writeByte(FunTokens.CONTENT_TEXT);
            final byte[] utf8 = text.getBytes(StandardCharsets.UTF_8);
            data.writeShort(utf8.length);
            data.write(utf8);
        } else {
            data.writeByte(FunTokens.CONTENT_EMPTY);
        }

        data.flush();
        final byte[] body = nodeBytes.toByteArray();

        // Wrap with 2-byte Length prefix for safe TLV skipping
        final ByteArrayOutputStream finalOut = new ByteArrayOutputStream(body.length + 2);
        final DataOutputStream finalData = new DataOutputStream(finalOut);
        finalData.writeShort(body.length);
        finalData.write(body);
        finalData.flush();

        return finalOut.toByteArray();
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
        } else {
            final byte[] utf8 = str.getBytes(StandardCharsets.UTF_8);
            if (utf8.length <= 255) {
                data.writeByte(FunTokens.LITERAL_STRING_8);
                data.writeByte(utf8.length);
                data.write(utf8);
            } else {
                data.writeByte(FunTokens.LITERAL_STRING_16);
                data.writeShort(utf8.length);
                data.write(utf8);
            }
        }
    }

    public void flush() throws IOException {
        out.flush();
    }
}
