package im.conversations.android.json;

import com.google.common.primitives.Longs;
import com.google.gson.Gson;
import com.google.gson.GsonBuilder;
import com.google.gson.TypeAdapter;
import com.google.gson.stream.JsonReader;
import com.google.gson.stream.JsonToken;
import com.google.gson.stream.JsonWriter;
import eu.siacs.conversations.xmpp.Jid;
import java.io.IOException;
import java.time.Instant;
import okhttp3.HttpUrl;

public class Services {

    public static final Gson GSON;

    static {
        GSON =
                new GsonBuilder()
                        .registerTypeAdapter(Jid.class, new JidTypeAdapter())
                        .registerTypeAdapter(HttpUrl.class, new HttpUrlTypeAdapter())
                        .registerTypeAdapter(Instant.class, new InstantTypeAdapter())
                        .create();
    }

    private static class HttpUrlTypeAdapter extends TypeAdapter<HttpUrl> {

        @Override
        public void write(final JsonWriter out, final HttpUrl value) throws IOException {
            if (value == null) {
                out.nullValue();
            } else {
                out.value(value.toString());
            }
        }

        @Override
        public HttpUrl read(final JsonReader in) throws IOException {
            if (in.peek() == JsonToken.NULL) {
                in.nextNull();
                return null;
            } else if (in.peek() == JsonToken.STRING) {
                final String value = in.nextString();
                return HttpUrl.parse(value);
            }
            throw new IOException("Unexpected token");
        }
    }

    private static class JidTypeAdapter extends TypeAdapter<Jid> {
        @Override
        public void write(final JsonWriter out, final Jid value) throws IOException {
            if (value == null) {
                out.nullValue();
            } else {
                out.value(value.toString());
            }
        }

        @Override
        public Jid read(final JsonReader in) throws IOException {
            if (in.peek() == JsonToken.NULL) {
                in.nextNull();
                return null;
            } else if (in.peek() == JsonToken.STRING) {
                final String value = in.nextString();
                return Jid.of(value);
            }
            throw new IOException("Unexpected token");
        }
    }

    private static class InstantTypeAdapter extends TypeAdapter<Instant> {

        @Override
        public void write(final JsonWriter out, final Instant value) throws IOException {
            if (value == null) {
                out.nullValue();
            } else if (value.equals(Instant.MAX)) {
                out.value(Long.MAX_VALUE);
            } else if (value.equals(Instant.MIN)) {
                out.value(Long.MIN_VALUE);
            } else {
                try {
                    out.value(value.toEpochMilli());
                } catch (final ArithmeticException e) {
                    out.value(value.isAfter(Instant.EPOCH) ? Long.MAX_VALUE : Long.MIN_VALUE);
                }
            }
        }

        @Override
        public Instant read(final JsonReader in) throws IOException {
            final long epochMilli;
            if (in.peek() == JsonToken.NULL) {
                in.nextNull();
                return null;
            } else if (in.peek() == JsonToken.NUMBER) {
                final var value = in.nextLong();
                return Instant.ofEpochMilli(value);
            } else if (in.peek() == JsonToken.STRING) {
                final var value = in.nextString();
                final var asLong = Longs.tryParse(value);
                if (asLong == null) {
                    return null;
                }
                epochMilli = asLong;
            } else {
                throw new IOException("Unexpected token");
            }
            if (epochMilli == Long.MAX_VALUE) {
                return Instant.MAX;
            } else if (epochMilli == Long.MIN_VALUE) {
                return Instant.MIN;
            } else {
                return Instant.ofEpochMilli(epochMilli);
            }
        }
    }
}
