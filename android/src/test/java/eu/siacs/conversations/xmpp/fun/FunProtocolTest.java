package eu.siacs.conversations.xmpp.fun;

import static org.junit.Assert.assertEquals;
import static org.junit.Assert.assertFalse;
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
        assertEquals("3a145c7a", FunTokens.DICTIONARY_HASH);
        assertEquals("68a7596d", FunTokens.LTS_V1_HASH);
        assertTrue(FunTokens.isSupportedDict("68a7596d"));
        assertTrue(FunTokens.isSupportedDict("3a145c7a"));
        assertFalse(FunTokens.isSupportedDict("unknown_hash"));
    }

    @Test
    public void testDictionaryEvolutionFallbackForV1Client() throws Exception {
        final Element message = new Element("message");
        message.setAttribute("id", "bot-msg-1");
        final Element markup = message.addChild("markup", "penik:bot:markup");
        markup.addChild("row");

        // 1. Encode with LTS v1 dictionary: markup and penik:bot:markup MUST fall back to string literals
        final byte[] v1Bytes = FunWriter.encodeNode(message, eu.siacs.conversations.xml.Namespace.JABBER_CLIENT, FunTokens.LTS_V1_HASH);
        final FunReader v1Reader = new FunReader(new ByteArrayInputStream(v1Bytes));
        final Element v1Decoded = v1Reader.readElement();
        assertNotNull(v1Decoded);
        assertEquals("message", v1Decoded.getName());
        assertEquals(1, v1Decoded.getChildren().size());
        assertEquals("markup", v1Decoded.getChildren().get(0).getName());
        assertEquals("penik:bot:markup", v1Decoded.getChildren().get(0).getNamespace());

        // 2. Encode with v2 dictionary: tokens 148 ("markup") and 152 ("penik:bot:markup") are 1-byte tokens
        final byte[] v2Bytes = FunWriter.encodeNode(message, eu.siacs.conversations.xml.Namespace.JABBER_CLIENT, FunTokens.V2_HASH);
        final FunReader v2Reader = new FunReader(new ByteArrayInputStream(v2Bytes));
        final Element v2Decoded = v2Reader.readElement();
        assertNotNull(v2Decoded);
        assertEquals("message", v2Decoded.getName());
        assertEquals("markup", v2Decoded.getChildren().get(0).getName());

        // Tokenized v2 MUST be strictly more compact than v1 with string literals
        assertTrue("v2 tokenized payload (" + v2Bytes.length + ") must be smaller than v1 literal fallback (" + v1Bytes.length + ")",
                v2Bytes.length < v1Bytes.length);
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

    @Test
    public void testSmacksPiggybackTwoFramesNoXmlByte() throws Exception {
        // 1. Stashed message stanza
        final Element message = new Element("message");
        message.setAttribute("id", "msg-1234");
        message.setAttribute("to", "bob@snikket.penik.ru");
        message.addChild("body").setContent("Hello, smacks!");

        // 2. Piggybacked <r xmlns='urn:xmpp:sm:3'/>
        final Element r = new Element("r", "urn:xmpp:sm:3");

        final byte[] frame1 = FunWriter.encodeNode(message);
        final byte[] frame2 = FunWriter.encodeNode(r);

        assertNotNull(frame1);
        assertNotNull(frame2);

        // Frame header must NOT be '<' (0x3C / ASCII 60)
        assertTrue("Frame 1 must not start with '<'", frame1[0] != 0x3C);
        assertTrue("Frame 2 must not start with '<'", frame2[0] != 0x3C);

        // Concatenate both frames into a single binary stream (as sent on socket)
        final ByteArrayOutputStream streamOut = new ByteArrayOutputStream();
        streamOut.write(frame1);
        streamOut.write(frame2);

        final ByteArrayInputStream streamIn = new ByteArrayInputStream(streamOut.toByteArray());
        final FunReader reader = new FunReader(streamIn);

        // Read first element: message
        final Element decoded1 = reader.readElement();
        assertNotNull(decoded1);
        assertEquals("message", decoded1.getName());
        assertEquals("msg-1234", decoded1.getAttribute("id"));
        assertEquals("Hello, smacks!", decoded1.findChildContent("body"));

        // Read second element: <r xmlns='urn:xmpp:sm:3'/>
        final Element decoded2 = reader.readElement();
        assertNotNull(decoded2);
        assertEquals("r", decoded2.getName());
        assertEquals("urn:xmpp:sm:3", decoded2.getNamespace());

        // Stream should now be exhausted
        final Element decoded3 = reader.readElement();
        org.junit.Assert.assertNull(decoded3);
    }

    @Test(expected = IllegalArgumentException.class)
    public void testEncodeNodeThrowsOnExcessiveAttributes() throws Exception {
        final Element element = new Element("iq");
        for (int i = 0; i < 256; i++) {
            element.setAttribute("attr_" + i, "val_" + i);
        }
        FunWriter.encodeNode(element);
    }

    @Test
    public void testWriteElementDropsExcessiveAttributesGracefullyWithoutThrowing() throws Exception {
        final Element malformed = new Element("iq");
        for (int i = 0; i < 256; i++) {
            malformed.setAttribute("attr_" + i, "val_" + i);
        }

        final ByteArrayOutputStream out = new ByteArrayOutputStream();
        final FunWriter writer = new FunWriter(out);

        // writeElement must not throw IllegalArgumentException, and must drop the stanza cleanly
        writer.writeElement(malformed);
        assertEquals("Malformed stanza with >255 attrs must be dropped with 0 bytes written", 0, out.size());

        // Subsequent valid stanza must write successfully
        final Element valid = new Element("presence");
        valid.setAttribute("id", "pres-1");
        writer.writeElement(valid);
        assertTrue("Valid stanza must be written after dropped stanza", out.size() > 0);
    }

    @Test
    public void testDirectPxmppStreamHeaderGenerationAndParsing() throws Exception {
        final String clientHash = FunTokens.V2_HASH;
        final byte[] clientHeader = FunTokens.createDirectStreamHeader(clientHash, "snikket.penik.ru", false);

        assertNotNull(clientHeader);
        assertTrue(clientHeader.length >= 10);
        // Magic
        assertEquals((byte) 'P', clientHeader[0]);
        assertEquals((byte) 'X', clientHeader[1]);
        assertEquals((byte) 'M', clientHeader[2]);
        assertEquals((byte) 'P', clientHeader[3]);
        // Version
        assertEquals(1, clientHeader[4]);
        // Flags (resume = false)
        assertEquals(0, clientHeader[5]);
        // Dict Hash
        final byte[] expectedHashBytes = FunTokens.hexToBytes(clientHash);
        for (int i = 0; i < 4; i++) {
            assertEquals(expectedHashBytes[i], clientHeader[6 + i]);
        }

        // Simulate server response: "PXMP\x01\x00" + selected dict hash
        final ByteArrayOutputStream serverHeaderOut = new ByteArrayOutputStream();
        serverHeaderOut.write(FunTokens.MAGIC_DIRECT_PXMPP);
        serverHeaderOut.write(FunTokens.DIRECT_PXMPP_VERSION);
        serverHeaderOut.write(0); // flags
        serverHeaderOut.write(expectedHashBytes);

        final ByteArrayInputStream in = new ByteArrayInputStream(serverHeaderOut.toByteArray());
        final String serverActiveDict = FunTokens.readServerStreamHeader(in);
        assertEquals(clientHash, serverActiveDict);
    }

    @Test
    public void testDirectPxmppHeaderWithResumeFlag() throws Exception {
        final byte[] resumeHeader = FunTokens.createDirectStreamHeader(FunTokens.LTS_V1_HASH, "snikket.penik.ru", true);
        assertEquals(FunTokens.FLAG_DIRECT_RESUME, resumeHeader[5]);

        final byte[] serverResponse = new byte[] {
            'P', 'X', 'M', 'P', 0x01, 0x00, 0x68, (byte) 0xa7, 0x59, 0x6d
        };
        final String activeDict = FunTokens.readServerStreamHeader(new ByteArrayInputStream(serverResponse));
        assertEquals("68a7596d", activeDict);
    }

    @Test
    public void testNestedJabberClientNamespacePreserved() throws Exception {
        final Element forwarded = new Element("forwarded", "urn:xmpp:forward:0");
        final Element message = forwarded.addChild("message", eu.siacs.conversations.xml.Namespace.JABBER_CLIENT);
        message.setAttribute("to", "bob@snikket.penik.ru");
        message.addChild("body").setContent("Forwarded text");

        final byte[] encoded = FunWriter.encodeNode(forwarded);
        assertNotNull(encoded);

        final ByteArrayInputStream in = new ByteArrayInputStream(encoded);
        final FunReader reader = new FunReader(in);
        final Element decoded = reader.readElement();

        assertNotNull(decoded);
        assertEquals("forwarded", decoded.getName());
        assertEquals("urn:xmpp:forward:0", decoded.getNamespace());

        final Element childMessage = decoded.findChild("message");
        assertNotNull(childMessage);
        assertEquals("message", childMessage.getName());
        assertEquals(eu.siacs.conversations.xml.Namespace.JABBER_CLIENT, childMessage.getNamespace());
    }

    @Test(expected = java.io.IOException.class)
    public void testFunReaderRejectsNegativeOrOutOfBoundsLength() throws Exception {
        final ByteArrayOutputStream out = new ByteArrayOutputStream();
        final DataOutputStream data = new DataOutputStream(out);
        data.writeShort(10); // Frame length
        // Token for tag
        data.writeByte(FunTokens.getToken("message"));
        data.writeByte(0); // 0 attrs
        data.writeByte(FunTokens.CONTENT_TEXT);
        data.writeShort(0xFFFF); // 32-bit length marker
        data.writeInt(0x7FFFFFFF); // Out of bounds 2 GB length!
        data.flush();

        final FunReader reader = new FunReader(new ByteArrayInputStream(out.toByteArray()));
        reader.readElement();
    }

    @Test
    public void testMultipleAtSignsFallsBackToLiteral() throws Exception {
        final ByteArrayOutputStream out = new ByteArrayOutputStream();
        final DataOutputStream dataOut = new DataOutputStream(out);

        final String text = "mailto:user@snikket.penik.ru?body=test@snikket.penik.ru";
        FunWriter.writeTokenOrString(dataOut, text);
        dataOut.flush();

        final byte[] bytes = out.toByteArray();
        // Since there is more than one '@', it must not be parsed as JID_BARE or JID_FULL
        assertTrue(bytes[0] == FunTokens.LITERAL_STRING_8 || bytes[0] == FunTokens.LITERAL_STRING_16);

        final DataInputStream in = new DataInputStream(new ByteArrayInputStream(bytes));
        final String decoded = FunReader.readTokenOrString(in);
        assertEquals(text, decoded);
    }
}
