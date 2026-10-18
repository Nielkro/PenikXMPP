package eu.siacs.conversations.utils;

import java.security.SecureRandom;

public final class Random {

    public static final SecureRandom SECURE_RANDOM = new SecureRandom();
    private static final char[] ALPHANUMERIC =
            "0123456789abcdefghijklmnopqrstuvwxyzABCDEFGHIJKLMNOPQRSTUVWXYZ".toCharArray();

    private Random() {

    }

    public static String shortId() {
        return shortId(12);
    }

    public static String shortId(int length) {
        final char[] buffer = new char[length];
        for (int i = 0; i < length; ++i) {
            buffer[i] = ALPHANUMERIC[SECURE_RANDOM.nextInt(ALPHANUMERIC.length)];
        }
        return new String(buffer);
    }

}
