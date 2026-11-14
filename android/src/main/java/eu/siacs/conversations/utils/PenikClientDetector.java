package eu.siacs.conversations.utils;

import com.google.common.base.Strings;
import com.google.common.collect.Iterables;
import eu.siacs.conversations.entities.Account;
import eu.siacs.conversations.entities.Contact;
import eu.siacs.conversations.xmpp.manager.DiscoManager;
import im.conversations.android.xmpp.model.disco.info.Identity;
import im.conversations.android.xmpp.model.stanza.Presence;

import java.util.ArrayList;
import java.util.Collections;
import java.util.LinkedHashSet;
import java.util.List;
import java.util.Locale;
import java.util.Set;

public class PenikClientDetector {

    public static class ClientInfo {
        public final boolean hasPenik;
        public final List<String> allClients;
        public final String displaySummary;

        public ClientInfo(boolean hasPenik, List<String> allClients, String displaySummary) {
            this.hasPenik = hasPenik;
            this.allClients = allClients;
            this.displaySummary = displaySummary;
        }
    }

    public static String nameWithoutVersion(final String name) {
        if (name == null) {
            return "";
        }
        String[] parts = name.trim().split("\\s+");
        if (parts.length > 1 && Character.isDigit(parts[parts.length - 1].charAt(0))) {
            StringBuilder output = new StringBuilder();
            for (int i = 0; i < parts.length - 1; ++i) {
                if (output.length() != 0) {
                    output.append(' ');
                }
                output.append(parts[i]);
            }
            return output.toString();
        } else {
            return name.trim();
        }
    }

    public static String normalizeClientName(String raw) {
        if (raw == null) {
            return null;
        }
        raw = raw.trim();
        if (raw.isEmpty()) {
            return null;
        }
        String lower = raw.toLowerCase(Locale.ROOT);
        if (lower.startsWith("penik")) return "Penik";
        if (lower.startsWith("conversations")) return "Conversations";
        if (lower.startsWith("monal")) return "Monal";
        if (lower.startsWith("gajim")) return "Gajim";
        if (lower.startsWith("dino")) return "Dino";
        if (lower.startsWith("siskin")) return "Siskin";
        if (lower.startsWith("beagle")) return "Beagle";
        if (lower.startsWith("kaidan")) return "Kaidan";
        if (lower.startsWith("yaxim")) return "yaxim";
        if (lower.startsWith("quicksy")) return "Quicksy";
        if (lower.startsWith("profanity")) return "Profanity";
        if (lower.startsWith("cheogram")) return "Cheogram";
        if (lower.startsWith("blabber")) return "blabber.im";
        if (lower.startsWith("movim")) return "Movim";
        if (lower.startsWith("pidgin")) return "Pidgin";
        if (lower.startsWith("snikket")) return "Snikket";
        return nameWithoutVersion(raw);
    }

    public static ClientInfo detectClientInfo(Contact contact) {
        if (contact == null) {
            return new ClientInfo(false, Collections.emptyList(), null);
        }

        Set<String> clients = new LinkedHashSet<>();
        Account account = contact.getAccount();
        List<Presence> presences = contact.getPresences();

        if (account != null && account.getXmppConnection() != null && presences != null && !presences.isEmpty()) {
            DiscoManager discoManager = account.getXmppConnection().getManager(DiscoManager.class);
            for (Presence presence : presences) {
                String detected = null;
                if (discoManager != null) {
                    var serviceDiscoveryResult = discoManager.get(presence.getFrom());
                    if (serviceDiscoveryResult != null && !serviceDiscoveryResult.getIdentities().isEmpty()) {
                        Identity identity = Iterables.getFirst(serviceDiscoveryResult.getIdentities(), null);
                        if (identity != null && !Strings.isNullOrEmpty(identity.getIdentityName())) {
                            detected = normalizeClientName(identity.getIdentityName());
                        }
                    }
                }
                if (detected == null && presence.getFrom() != null && presence.getFrom().isFullJid()) {
                    detected = normalizeClientName(presence.getFrom().getResource());
                }
                if (detected != null && !detected.isEmpty()) {
                    clients.add(detected);
                }
            }
        }

        if (!clients.isEmpty()) {
            contact.setLastClients(new ArrayList<>(clients));
        } else {
            List<String> lastClients = contact.getLastClients();
            if (lastClients != null && !lastClients.isEmpty()) {
                clients.addAll(lastClients);
            } else {
                String lastResource = contact.getLastResource();
                if (!Strings.isNullOrEmpty(lastResource)) {
                    String norm = normalizeClientName(lastResource);
                    if (norm != null) {
                        clients.add(norm);
                    }
                }
            }
        }

        if (clients.isEmpty()) {
            return new ClientInfo(false, Collections.emptyList(), null);
        }

        boolean hasPenik = false;
        List<String> otherClients = new ArrayList<>();
        for (String c : clients) {
            if ("Penik".equalsIgnoreCase(c)) {
                hasPenik = true;
            } else {
                otherClients.add(c);
            }
        }

        String summary;
        if (hasPenik) {
            if (otherClients.isEmpty()) {
                summary = "Penik";
            } else {
                summary = "Penik + " + String.join(", ", otherClients);
            }
        } else {
            summary = String.join(", ", otherClients);
        }

        return new ClientInfo(hasPenik, new ArrayList<>(clients), summary);
    }
}
