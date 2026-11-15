package de.gultsch.common;

import android.content.Context;
import android.os.Build;
import android.util.Log;
import androidx.annotation.Nullable;
import com.google.common.collect.Iterables;
import com.google.common.hash.Hashing;
import eu.siacs.conversations.Config;
import eu.siacs.conversations.Conversations;
import eu.siacs.conversations.R;
import java.io.IOException;
import java.io.InputStream;
import java.security.KeyStore;
import java.security.KeyStoreException;
import java.security.NoSuchAlgorithmException;
import java.security.cert.CertificateException;
import java.security.cert.X509Certificate;
import java.util.Arrays;
import java.util.Set;
import javax.net.ssl.TrustManagerFactory;
import javax.net.ssl.X509TrustManager;

public final class TrustManagers {

    private static final char[] BUNDLED_KEYSTORE_PASSWORD = "letsencrypt".toCharArray();

    private static final Set<String> BLOCKED_ROOT_SHA256 =
            Set.of(
                    // https://emudhra.we-have-a-problem.com/roots.json
                    "7dd78d5f4f13459a83dff9abbba62edbaf6f2d102bf257fd712f4d9f2746ed8d",
                    "f2edaaff3d9b701fb4d14c9f285f8c0bad90fc3bcc1fa07d47f4718edaba34a5",
                    "d7a7a0fb5d7e2731d771e9484ebcdef71d5f0c3e0a2948782bc83ee0ea699ef4",
                    "86a1ecba089c4a8d3bbe2734c612ba341d813e043cf9e8a862cd5c57a36bbe6b",

                    // the other emSign Root CAs
                    "40f6af0346a99aa1cd1d555a4e9cce62c7f9634603ee406615833dc8c8d00367",
                    "125609aa301da0a249b97a8239cb6a34216f44dcac9f3954b14292f2e8c8608f",
                    "bc4d809b15189d78db3e1d8cf4f9726a795da1643ca5f1358e1ddb0edc0d7eb3");

    private TrustManagers() {
        throw new IllegalStateException("Do not instantiate me");
    }

    private static KeyStore getFilteredKeyStore()
            throws KeyStoreException, CertificateException, IOException, NoSuchAlgorithmException {
        final var systemStore = KeyStore.getInstance("AndroidCAStore");
        systemStore.load(null, null);

        final var filteredStore = KeyStore.getInstance(KeyStore.getDefaultType());
        filteredStore.load(null, null);

        final var aliases = systemStore.aliases();
        while (aliases.hasMoreElements()) {
            final var alias = aliases.nextElement();
            if (systemStore.isCertificateEntry(alias)
                    && systemStore.getCertificate(alias) instanceof X509Certificate x509) {
                final var fingerprint = Hashing.sha256().hashBytes(x509.getEncoded()).toString();
                if (BLOCKED_ROOT_SHA256.contains(fingerprint)) {
                    Log.d(Config.LOGTAG, "blocking CA " + fingerprint);
                    continue;
                }
                filteredStore.setCertificateEntry(alias, x509);
            }
        }
        return filteredStore;
    }

    public static X509TrustManager createTrustManager(@Nullable final KeyStore keyStore)
            throws NoSuchAlgorithmException, KeyStoreException {
        final TrustManagerFactory trustManagerFactory =
                TrustManagerFactory.getInstance(TrustManagerFactory.getDefaultAlgorithm());
        trustManagerFactory.init(keyStore);
        return Iterables.getOnlyElement(
                Iterables.filter(
                        Arrays.asList(trustManagerFactory.getTrustManagers()),
                        X509TrustManager.class));
    }

    public static X509TrustManager createForAndroidVersion(final Context context)
            throws NoSuchAlgorithmException, KeyStoreException, CertificateException, IOException {
        if (Build.VERSION.SDK_INT <= Build.VERSION_CODES.N) {
            return TrustManagers.createDefaultWithBundledLetsEncrypt(context);
        } else {
            return Conversations.getInstance(context).getFilteredDefaultTrustManager();
        }
    }

    public static X509TrustManager createDefaultTrustManager()
            throws NoSuchAlgorithmException, KeyStoreException, CertificateException, IOException {
        return createTrustManager(getFilteredKeyStore());
    }

    private static X509TrustManager createDefaultWithBundledLetsEncrypt(final Context context)
            throws NoSuchAlgorithmException, KeyStoreException, CertificateException, IOException {
        final var bundleTrustManager =
                createWithKeyStore(context.getResources().openRawResource(R.raw.letsencrypt));
        return CombiningTrustManager.combineWithDefault(context, bundleTrustManager);
    }

    private static X509TrustManager createWithKeyStore(final InputStream inputStream)
            throws CertificateException, IOException, NoSuchAlgorithmException, KeyStoreException {
        final KeyStore keyStore = KeyStore.getInstance(KeyStore.getDefaultType());
        keyStore.load(inputStream, BUNDLED_KEYSTORE_PASSWORD);
        return TrustManagers.createTrustManager(keyStore);
    }
}
