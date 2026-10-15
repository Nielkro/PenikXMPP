package eu.siacs.conversations.xmpp.fun;

import static org.junit.Assert.assertEquals;
import static org.junit.Assert.assertNotNull;
import static org.junit.Assert.assertTrue;

import eu.siacs.conversations.xml.Element;
import java.io.ByteArrayInputStream;
import java.io.ByteArrayOutputStream;
import java.io.DataInputStream;
import java.io.DataOutputStream;
import org.junit.Test;

public class FunProtocolTest {

    @Test
    public void testJidBareTokenization() throws Exception {
        final ByteArrayOutputStream out = new ByteArrayOutputStream();
        final DataOutputStream dataOut = new DataOutputStream(out);

        final String jid = "alice@snikket.penik.ru";
        FunWriter.writeTokenOrString(dataOut, jid);
        dataOut.flush();

        final byte[] bytes = out.toByteArray();
        // [0xFD (JID_BARE)] [0xFA, 5, 'a','l','i','c','e'] [143 (snikket.penik.ru)]
        assertEquals(FunTokens.JID_BARE, bytes[0]);
        assertEquals(1 + 2 + 5 + 1, bytes.length);

        final DataInputStream in = new DataInputStream(new ByteArrayInputStream(bytes));
        final String decoded = FunReader.readTokenOrString(in);
        assertEquals(jid, decoded);
    }

    @Test
    public void testJidFullTokenization() throws Exception {
        final ByteArrayOutputStream out = new ByteArrayOutputStream();
        final DataOutputStream dataOut = new DataOutputStream(out);

        final String jid = "bob@snikket.penik.ru/phone";
        FunWriter.writeTokenOrString(dataOut, jid);
        dataOut.flush();

        final byte[] bytes = out.toByteArray();
        // [0xFE (JID_FULL)] [0xFA, 3, 'b','o','b'] [143] [0xFA, 5, 'p','h','o','n','e']
        assertEquals(FunTokens.JID_FULL, bytes[0]);
        assertEquals(1 + (2 + 3) + 1 + (2 + 5), bytes.length);

        final DataInputStream in = new DataInputStream(new ByteArrayInputStream(bytes));
        final String decoded = FunReader.readTokenOrString(in);
        assertEquals(jid, decoded);
    }

    @Test
    public void testMucRoomJidTokenization() throws Exception {
        final ByteArrayOutputStream out = new ByteArrayOutputStream();
        final DataOutputStream dataOut = new DataOutputStream(out);

        final String jid = "general@groups.snikket.penik.ru/alice";
        FunWriter.writeTokenOrString(dataOut, jid);
        dataOut.flush();

        final byte[] bytes = out.toByteArray();
        assertEquals(FunTokens.JID_FULL, bytes[0]);

        final DataInputStream in = new DataInputStream(new ByteArrayInputStream(bytes));
        final String decoded = FunReader.readTokenOrString(in);
        assertEquals(jid, decoded);
    }

    @Test
    public void testNonMatchingDomainFallsBackToLiteral() throws Exception {
        final ByteArrayOutputStream out = new ByteArrayOutputStream();
        final DataOutputStream dataOut = new DataOutputStream(out);

        final String jid = "charlie@external-server.org";
        FunWriter.writeTokenOrString(dataOut, jid);
        dataOut.flush();

        final byte[] bytes = out.toByteArray();
        assertEquals(FunTokens.LITERAL_STRING_8, bytes[0]);

        final DataInputStream in = new DataInputStream(new ByteArrayInputStream(bytes));
        final String decoded = FunReader.readTokenOrString(in);
        assertEquals(jid, decoded);
    }

    @Test
    public void testFullStanzaRoundtripWithJids() throws Exception {
        final Element message = new Element("message");
        message.setAttribute("from", "alice@snikket.penik.ru/mobile");
        message.setAttribute("to", "bob@snikket.penik.ru");
        message.setAttribute("type", "chat");
        message.setAttribute("id", "penik-msg-001");

        final Element body = message.addChild("body");
        body.setContent("Привет из FunXMPP!");

        final Element markable = message.addChild("markable", "urn:xmpp:chat-markers:0");

        final byte[] encoded = FunWriter.encodeNode(message);
        assertNotNull(encoded);

        // Verify that the frame can be read and decoded completely
        final ByteArrayInputStream bis = new ByteArrayInputStream(encoded);
        final FunReader reader = new FunReader(bis);
        final Element decoded = reader.readElement();

        assertNotNull(decoded);
        assertEquals("message", decoded.getName());
        assertEquals("alice@snikket.penik.ru/mobile", decoded.getAttribute("from"));
        assertEquals("bob@snikket.penik.ru", decoded.getAttribute("to"));
        assertEquals("chat", decoded.getAttribute("type"));
        assertEquals("penik-msg-001", decoded.getAttribute("id"));

        final Element decodedBody = decoded.findChild("body");
        assertNotNull(decodedBody);
        assertEquals("Привет из FunXMPP!", decodedBody.getContent());

        final Element decodedMarkable = decoded.findChild("markable", "urn:xmpp:chat-markers:0");
        assertNotNull(decodedMarkable);
    }

    @Test
    public void testDictionaryHashDeterministic() {
        assertEquals("68a7596d", FunTokens.DICTIONARY_HASH);
    }

    @Test
    public void testEnableAndEnabledElementWithDict() {
        final im.conversations.android.xmpp.model.fun.Enable enable =
                new im.conversations.android.xmpp.model.fun.Enable(FunTokens.DICTIONARY_HASH);
        assertEquals(FunTokens.DICTIONARY_HASH, enable.getDict());

        final im.conversations.android.xmpp.model.fun.Enabled enabled =
                new im.conversations.android.xmpp.model.fun.Enabled(FunTokens.DICTIONARY_HASH);
        assertEquals(FunTokens.DICTIONARY_HASH, enabled.getDict());
    }
}
