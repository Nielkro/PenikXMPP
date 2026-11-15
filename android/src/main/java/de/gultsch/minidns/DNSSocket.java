package de.gultsch.minidns;

import android.util.Log;
import com.google.common.base.Preconditions;
import com.google.common.base.Strings;
import com.google.common.collect.ImmutableList;
import com.google.common.util.concurrent.Futures;
import com.google.common.util.concurrent.ListenableFuture;
import com.google.common.util.concurrent.SettableFuture;
import eu.siacs.conversations.Config;
import eu.siacs.conversations.persistance.FileBackend;
import java.io.BufferedOutputStream;
import java.io.Closeable;
import java.io.DataInputStream;
import java.io.DataOutputStream;
import java.io.EOFException;
import java.io.IOException;
import java.net.InetSocketAddress;
import java.net.Socket;
import java.security.cert.X509Certificate;
import java.util.HashMap;
import java.util.Map;
import java.util.concurrent.Semaphore;
import javax.net.ssl.SSLPeerUnverifiedException;
import javax.net.ssl.SSLSocket;
import javax.net.ssl.SSLSocketFactory;
import org.conscrypt.OkHostnameVerifier;
import org.minidns.dnsmessage.DnsMessage;

final class DNSSocket implements Closeable {

    public static final int QUERY_TIMEOUT = 5_000;

    private final Semaphore semaphore = new Semaphore(1);
    private final Map<Integer, SettableFuture<DnsMessage>> inFlightQueries = new HashMap<>();
    private final Socket socket;
    private final DataInputStream dataInputStream;
    private final DataOutputStream dataOutputStream;

    private DNSSocket(
            final Socket socket,
            final DataInputStream dataInputStream,
            final DataOutputStream dataOutputStream) {
        this.socket = socket;
        this.dataInputStream = dataInputStream;
        this.dataOutputStream = dataOutputStream;
        new Thread(this::readDNSMessages).start();
    }

    private void readDNSMessages() {
        try {
            while (socket.isConnected()) {
                final var response = readDNSMessage();
                final SettableFuture<DnsMessage> future;
                synchronized (inFlightQueries) {
                    future = inFlightQueries.remove(response.id);
                }
                if (future != null) {
                    future.set(response);
                } else {
                    Log.e(Config.LOGTAG, "no in flight query found for response id " + response.id);
                }
            }
            evictInFlightQueries(new EOFException());
        } catch (final IOException e) {
            evictInFlightQueries(e);
        } finally {
            FileBackend.close(this.dataOutputStream);
            FileBackend.close(this.dataInputStream);
            FileBackend.close(socket);
            evictInFlightQueries(new IllegalStateException("Removed dangling queries"));
            Log.d(Config.LOGTAG, "shut down connection to " + socket.getInetAddress());
        }
    }

    private void evictInFlightQueries(final Exception e) {
        final ImmutableList<SettableFuture<DnsMessage>> futures;
        synchronized (inFlightQueries) {
            if (this.inFlightQueries.isEmpty()) {
                return;
            }
            futures = ImmutableList.copyOf(this.inFlightQueries.values());
            this.inFlightQueries.clear();
        }
        for (var future : futures) {
            future.setException(e);
        }
    }

    private static DNSSocket of(final Socket socket) throws IOException {
        final var dataInputStream = new DataInputStream(socket.getInputStream());
        final var dataOutputStream =
                new DataOutputStream(new BufferedOutputStream(socket.getOutputStream()));
        return new DNSSocket(socket, dataInputStream, dataOutputStream);
    }

    public static DNSSocket connect(final DNSServer dnsServer) throws IOException {
        return switch (dnsServer.uniqueTransport()) {
            case TCP -> connectTcpSocket(dnsServer);
            case TLS -> connectTlsSocket(dnsServer);
            default -> throw new IllegalStateException("This is not a socket based transport");
        };
    }

    private static DNSSocket connectTcpSocket(final DNSServer dnsServer) throws IOException {
        Preconditions.checkArgument(dnsServer.uniqueTransport() == Transport.TCP);
        final var socketAddress = new InetSocketAddress(dnsServer.inetAddress, dnsServer.port);
        final var socket = new Socket();
        socket.connect(socketAddress, QUERY_TIMEOUT / 2);
        socket.setSoTimeout(QUERY_TIMEOUT);
        return DNSSocket.of(socket);
    }

    private static DNSSocket connectTlsSocket(final DNSServer dnsServer) throws IOException {
        Preconditions.checkArgument(dnsServer.uniqueTransport() == Transport.TLS);
        final var factory = (SSLSocketFactory) SSLSocketFactory.getDefault();
        final var sslSocket = (SSLSocket) factory.createSocket();
        if (Strings.isNullOrEmpty(dnsServer.hostname)) {
            final var socketAddress = new InetSocketAddress(dnsServer.inetAddress, dnsServer.port);
            sslSocket.connect(socketAddress, QUERY_TIMEOUT / 2);
            sslSocket.setSoTimeout(QUERY_TIMEOUT);
            sslSocket.startHandshake();
        } else {
            final var socketAddress = new InetSocketAddress(dnsServer.hostname, dnsServer.port);
            sslSocket.connect(socketAddress, QUERY_TIMEOUT / 2);
            sslSocket.setSoTimeout(QUERY_TIMEOUT);
            sslSocket.startHandshake();
            final var session = sslSocket.getSession();
            final var peerCertificates = session.getPeerCertificates();
            if (peerCertificates.length == 0
                    || !(peerCertificates[0] instanceof X509Certificate certificate)) {
                throw new IOException("Peer did not provide X509 certificates");
            }
            if (!OkHostnameVerifier.strictInstance().verify(dnsServer.hostname, certificate)) {
                throw new SSLPeerUnverifiedException("Peer did not provide valid certificates");
            }
        }
        return DNSSocket.of(sslSocket);
    }

    public ListenableFuture<DnsMessage> queryAsync(final DnsMessage query) {
        try {
            this.semaphore.acquire();
        } catch (InterruptedException e) {
            return Futures.immediateFailedFuture(e);
        }
        try {
            final SettableFuture<DnsMessage> responseFuture = SettableFuture.create();
            synchronized (this.inFlightQueries) {
                this.inFlightQueries.put(query.id, responseFuture);
            }
            query.writeTo(this.dataOutputStream);
            this.dataOutputStream.flush();
            return responseFuture;
        } catch (final IOException e) {
            return Futures.immediateFailedFuture(e);
        } finally {
            this.semaphore.release();
        }
    }

    private DnsMessage readDNSMessage() throws IOException {
        final int length = this.dataInputStream.readUnsignedShort();
        byte[] data = new byte[length];
        int read = 0;
        while (read < length) {
            read += this.dataInputStream.read(data, read, length - read);
        }
        return NetworkDataSource.readDNSMessage(data);
    }

    @Override
    public void close() throws IOException {
        this.socket.close();
    }

    public void closeQuietly() {
        try {
            this.socket.close();
        } catch (final IOException ignored) {

        }
    }
}
