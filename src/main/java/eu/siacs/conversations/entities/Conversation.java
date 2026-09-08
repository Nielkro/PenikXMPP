package eu.siacs.conversations.entities;

import android.content.ContentValues;
import android.database.Cursor;
import android.util.Log;
import androidx.annotation.NonNull;
import androidx.annotation.Nullable;
import com.google.common.base.Strings;
import com.google.common.collect.Collections2;
import com.google.common.collect.ComparisonChain;
import com.google.common.collect.ImmutableList;
import com.google.common.collect.ImmutableSet;
import com.google.common.collect.Iterables;
import com.google.common.collect.Lists;
import com.google.gson.JsonParseException;
import com.google.gson.annotations.SerializedName;
import eu.siacs.conversations.Config;
import eu.siacs.conversations.crypto.OmemoSetting;
import eu.siacs.conversations.crypto.PgpDecryptionService;
import eu.siacs.conversations.persistance.DatabaseBackend;
import eu.siacs.conversations.services.AvatarService;
import eu.siacs.conversations.services.QuickConversationsService;
import eu.siacs.conversations.utils.JidHelper;
import eu.siacs.conversations.utils.MessageUtils;
import eu.siacs.conversations.utils.UIHelper;
import eu.siacs.conversations.xmpp.Jid;
import eu.siacs.conversations.xmpp.mam.MamReference;
import eu.siacs.conversations.xmpp.manager.BookmarkManager;
import eu.siacs.conversations.xmpp.manager.MultiUserChatManager;
import im.conversations.android.json.Services;
import im.conversations.android.model.Bookmark;
import im.conversations.android.xmpp.model.muc.Affiliation;
import im.conversations.android.xmpp.model.muc.Role;
import java.time.Instant;
import java.util.ArrayList;
import java.util.Collection;
import java.util.Collections;
import java.util.List;
import java.util.ListIterator;
import java.util.Objects;
import java.util.Set;
import java.util.concurrent.atomic.AtomicBoolean;

public class Conversation extends AbstractEntity
        implements Blockable, Comparable<Conversation>, Conversational, AvatarService.Avatar {
    public static final String TABLENAME = "conversations";

    public static final int STATUS_AVAILABLE = 0;
    public static final int STATUS_ARCHIVED = 1;

    public static final String NAME = "name";
    public static final String ACCOUNT = "accountUuid";
    public static final String CONTACT = "contactUuid";
    public static final String CONTACTJID = "contactJid";
    public static final String STATUS = "status";
    public static final String CREATED = "created";
    public static final String MODE = "mode";
    public static final String ATTRIBUTES = "attributes";

    protected final ArrayList<Message> messages = new ArrayList<>();
    public AtomicBoolean messagesLoaded = new AtomicBoolean(true);
    protected Account account = null;
    private String draftMessage;
    private final String name;
    private final String contactUuid;
    private final String accountUuid;
    private Jid contactJid;
    private int status;
    private final long created;
    private int mode;
    private final Attributes attributes;
    private Jid nextCounterpart;
    private boolean messagesLeftOnServer = true;
    private String mFirstMamReference = null;
    private String displayState = null;

    public Conversation(
            final String name, final Account account, final Jid contactJid, final int mode) {
        this(
                java.util.UUID.randomUUID().toString(),
                name,
                null,
                account.getUuid(),
                contactJid,
                System.currentTimeMillis(),
                STATUS_AVAILABLE,
                mode,
                new Attributes());
        this.account = account;
    }

    public Conversation(
            final String uuid,
            final String name,
            final String contactUuid,
            final String accountUuid,
            final Jid contactJid,
            final long created,
            final int status,
            final int mode,
            final Attributes attributes) {
        this.uuid = uuid;
        this.name = name;
        this.contactUuid = contactUuid;
        this.accountUuid = accountUuid;
        this.contactJid = contactJid;
        this.created = created;
        this.status = status;
        this.mode = mode;
        this.attributes = attributes;
    }

    public static Conversation fromCursor(final Cursor cursor) {
        return new Conversation(
                cursor.getString(cursor.getColumnIndexOrThrow(UUID)),
                cursor.getString(cursor.getColumnIndexOrThrow(NAME)),
                cursor.getString(cursor.getColumnIndexOrThrow(CONTACT)),
                cursor.getString(cursor.getColumnIndexOrThrow(ACCOUNT)),
                Jid.ofOrInvalid(cursor.getString(cursor.getColumnIndexOrThrow(CONTACTJID))),
                cursor.getLong(cursor.getColumnIndexOrThrow(CREATED)),
                cursor.getInt(cursor.getColumnIndexOrThrow(STATUS)),
                cursor.getInt(cursor.getColumnIndexOrThrow(MODE)),
                Attributes.parse(cursor.getString(cursor.getColumnIndexOrThrow(ATTRIBUTES))));
    }

    public static Message getLatestMarkableMessage(
            final List<Message> messages, boolean isPrivateAndNonAnonymousMuc) {
        for (int i = messages.size() - 1; i >= 0; --i) {
            final Message message = messages.get(i);
            if (message.getStatus() <= Message.STATUS_RECEIVED
                    && (message.markable || isPrivateAndNonAnonymousMuc)
                    && !message.isPrivateMessage()) {
                return message;
            }
        }
        return null;
    }

    private static boolean suitableForOmemoByDefault(final Conversation conversation) {
        if (conversation.getAddress().asBareJid().equals(Config.BUG_REPORTS)) {
            return false;
        }
        if (conversation.getContact().isOwnServer()) {
            return false;
        }
        return conversation.isSingleOrPrivateAndNonAnonymous()
                || conversation.attributes.formerlyPrivateNonAnonymous();
    }

    public boolean hasMessagesLeftOnServer() {
        return messagesLeftOnServer;
    }

    public void setHasMessagesLeftOnServer(boolean value) {
        this.messagesLeftOnServer = value;
    }

    public Message getFirstUnreadMessage() {
        Message first = null;
        synchronized (this.messages) {
            for (int i = messages.size() - 1; i >= 0; --i) {
                if (messages.get(i).isRead()) {
                    return first;
                } else {
                    first = messages.get(i);
                }
            }
        }
        return first;
    }

    public String findMostRecentRemoteDisplayableId() {
        final boolean multi = mode == Conversation.MODE_MULTI;
        synchronized (this.messages) {
            for (final Message message : Lists.reverse(this.messages)) {
                if (message.getStatus() == Message.STATUS_RECEIVED) {
                    final String serverMsgId = message.getServerMsgId();
                    if (serverMsgId != null && multi) {
                        return serverMsgId;
                    }
                    return message.getRemoteMsgId();
                }
            }
        }
        return null;
    }

    public int countFailedDeliveries() {
        int count = 0;
        synchronized (this.messages) {
            for (final Message message : this.messages) {
                if (message.getStatus() == Message.STATUS_SEND_FAILED) {
                    ++count;
                }
            }
        }
        return count;
    }

    public Message getLastEditableMessage() {
        synchronized (this.messages) {
            for (final Message message : Lists.reverse(this.messages)) {
                if (message.isEditable()) {
                    if (!message.acceptMessageCorrection()) {
                        return null;
                    }
                    return message;
                }
            }
        }
        return null;
    }

    public Message findUnsentMessageWithUuid(String uuid) {
        synchronized (this.messages) {
            for (final Message message : this.messages) {
                final int s = message.getStatus();
                if ((s == Message.STATUS_UNSEND || s == Message.STATUS_WAITING)
                        && message.getUuid().equals(uuid)) {
                    return message;
                }
            }
        }
        return null;
    }

    public void findWaitingMessages(OnMessageFound onMessageFound) {
        final ArrayList<Message> results = new ArrayList<>();
        synchronized (this.messages) {
            for (Message message : this.messages) {
                if (message.getStatus() == Message.STATUS_WAITING) {
                    results.add(message);
                }
            }
        }
        for (Message result : results) {
            onMessageFound.onMessageFound(result);
        }
    }

    public void findUnreadMessagesAndCalls(OnMessageFound onMessageFound) {
        final ArrayList<Message> results = new ArrayList<>();
        synchronized (this.messages) {
            for (final Message message : this.messages) {
                if (message.isRead()) {
                    continue;
                }
                results.add(message);
            }
        }
        for (final Message result : results) {
            onMessageFound.onMessageFound(result);
        }
    }

    public Message findMessageWithFileAndUuid(final String uuid) {
        synchronized (this.messages) {
            for (final Message message : this.messages) {
                final Transferable transferable = message.getTransferable();
                final boolean unInitiatedButKnownSize =
                        MessageUtils.unInitiatedButKnownSize(message);
                if (message.getUuid().equals(uuid)
                        && message.getEncryption() != Message.ENCRYPTION_PGP
                        && (message.isFileOrImage()
                                || message.treatAsDownloadable()
                                || unInitiatedButKnownSize
                                || (transferable != null
                                        && transferable.getStatus()
                                                != Transferable.STATUS_UPLOADING))) {
                    return message;
                }
            }
        }
        return null;
    }

    public Message findMessageWithUuid(final String uuid) {
        synchronized (this.messages) {
            for (final Message message : this.messages) {
                if (message.getUuid().equals(uuid)) {
                    return message;
                }
            }
        }
        return null;
    }

    public Set<Message> findMessagesWithOccupantIdOrRealJid(
            final Jid realJid, final String occupantId) {
        synchronized (this.messages) {
            return ImmutableSet.copyOf(
                    Collections2.filter(
                            this.messages,
                            m -> {
                                if (m.serverMsgId == null) {
                                    return false;
                                }
                                final var tcp = m.getTrueCounterpart();
                                return (realJid != null
                                                && tcp != null
                                                && realJid.equals(tcp.asBareJid()))
                                        || (occupantId != null
                                                && occupantId.equals(m.getOccupantId()));
                            }));
        }
    }

    public boolean markAsDeleted(final List<String> uuids) {
        boolean deleted = false;
        final PgpDecryptionService pgpDecryptionService = account.getPgpDecryptionService();
        synchronized (this.messages) {
            for (Message message : this.messages) {
                if (uuids.contains(message.getUuid())) {
                    message.setDeleted(true);
                    deleted = true;
                    if (message.getEncryption() == Message.ENCRYPTION_PGP
                            && pgpDecryptionService != null) {
                        pgpDecryptionService.discard(message);
                    }
                }
            }
        }
        return deleted;
    }

    public boolean markAsChanged(final List<DatabaseBackend.FilePathInfo> files) {
        boolean changed = false;
        final PgpDecryptionService pgpDecryptionService = account.getPgpDecryptionService();
        synchronized (this.messages) {
            for (Message message : this.messages) {
                for (final DatabaseBackend.FilePathInfo file : files)
                    if (file.uuid.toString().equals(message.getUuid())) {
                        message.setDeleted(file.deleted);
                        changed = true;
                        if (file.deleted
                                && message.getEncryption() == Message.ENCRYPTION_PGP
                                && pgpDecryptionService != null) {
                            pgpDecryptionService.discard(message);
                        }
                    }
            }
        }
        return changed;
    }

    public void clearMessages() {
        synchronized (this.messages) {
            this.messages.clear();
        }
    }

    public void trim() {
        synchronized (this.messages) {
            final int size = messages.size();
            final int maxsize = Config.PAGE_SIZE * Config.MAX_NUM_PAGES;
            if (size > maxsize) {
                List<Message> discards = this.messages.subList(0, size - maxsize);
                final PgpDecryptionService pgpDecryptionService = account.getPgpDecryptionService();
                if (pgpDecryptionService != null) {
                    pgpDecryptionService.discard(discards);
                }
                discards.clear();
                untieMessages();
            }
        }
    }

    public void findUnsentTextMessages(OnMessageFound onMessageFound) {
        final ArrayList<Message> results = new ArrayList<>();
        synchronized (this.messages) {
            for (Message message : this.messages) {
                if ((message.getType() == Message.TYPE_TEXT || message.hasFileOnRemoteHost())
                        && message.getStatus() == Message.STATUS_UNSEND) {
                    results.add(message);
                }
            }
        }
        for (Message result : results) {
            onMessageFound.onMessageFound(result);
        }
    }

    public Message findMessageWithUuidOrRemoteId(
            final String id, final String occupantId, final Boolean received) {
        synchronized (this.messages) {
            for (final var message : this.messages) {
                final var idMatch =
                        id.equals(message.getUuid()) || id.equals(message.getRemoteMsgId());
                final var occupantIdMatch =
                        occupantId == null || occupantId.equals(message.getOccupantId());
                final var directionMatch =
                        received == null
                                || (message.getStatus() == Message.STATUS_RECEIVED) == received;
                if (idMatch && occupantIdMatch && directionMatch) {
                    return message;
                }
            }
        }
        return null;
    }

    public Message findSentMessageWithUuid(String id) {
        synchronized (this.messages) {
            for (Message message : this.messages) {
                if (id.equals(message.getUuid())) {
                    return message;
                }
            }
        }
        return null;
    }

    public Message findMessageWithRemoteId(String id, Jid counterpart) {
        synchronized (this.messages) {
            for (Message message : this.messages) {
                if (counterpart.equals(message.getCounterpart())
                        && (id.equals(message.getRemoteMsgId()) || id.equals(message.getUuid()))) {
                    return message;
                }
            }
        }
        return null;
    }

    public Message findMessageWithServerMsgId(String id) {
        synchronized (this.messages) {
            for (Message message : this.messages) {
                if (id != null && id.equals(message.getServerMsgId())) {
                    return message;
                }
            }
        }
        return null;
    }

    public boolean hasMessageWithCounterpart(Jid counterpart) {
        synchronized (this.messages) {
            for (Message message : this.messages) {
                if (counterpart.equals(message.getCounterpart())) {
                    return true;
                }
            }
        }
        return false;
    }

    public void populateWithMessages(final List<Message> messages) {
        synchronized (this.messages) {
            messages.clear();
            messages.addAll(this.messages);
        }
    }

    @Override
    public boolean isBlocked() {
        return getContact().isBlocked();
    }

    @Override
    public boolean isDomainBlocked() {
        return getContact().isDomainBlocked();
    }

    @Override
    @NonNull
    public Jid getBlockedAddress() {
        return getContact().getBlockedAddress();
    }

    public int countMessages() {
        synchronized (this.messages) {
            return this.messages.size();
        }
    }

    public String getFirstMamReference() {
        return this.mFirstMamReference;
    }

    public void setFirstMamReference(String reference) {
        this.mFirstMamReference = reference;
    }

    public void setLastClearHistory(final long time, final String reference) {
        this.attributes.lastClearHistory = new MamReference(time, reference);
    }

    public MamReference getLastClearHistory() {
        return this.attributes.lastClearHistory;
    }

    public ImmutableSet<Jid> getAcceptedCryptoTargets() {
        if (mode == MODE_SINGLE) {
            return ImmutableSet.of(getAddress().asBareJid());
        } else {
            final var list = this.attributes.cryptoTargets;
            return list == null ? ImmutableSet.of() : ImmutableSet.copyOf(list);
        }
    }

    public void setAcceptedCryptoTargets(final Collection<Jid> acceptedTargets) {
        this.attributes.cryptoTargets = ImmutableList.copyOf(acceptedTargets);
    }

    public boolean setCorrectingMessage(final Message correctingMessage) {
        this.attributes.correctingMessage =
                correctingMessage == null ? null : correctingMessage.getUuid();
        return correctingMessage == null && draftMessage != null;
    }

    public Message getCorrectingMessage() {
        final String uuid = this.attributes.correctingMessage;
        return uuid == null ? null : findSentMessageWithUuid(uuid);
    }

    @Override
    public int compareTo(@NonNull Conversation another) {
        return ComparisonChain.start()
                .compareFalseFirst(another.attributes.pinnedOnTop(), attributes.pinnedOnTop())
                .compare(another.getSortableTime(), getSortableTime())
                .result();
    }

    private long getSortableTime() {
        Draft draft = getDraft();
        long messageTime = getLatestMessage().getTimeSent();
        if (draft == null) {
            return messageTime;
        } else {
            return Math.max(messageTime, draft.instant.toEpochMilli());
        }
    }

    public String getDraftMessage() {
        return draftMessage;
    }

    public void setDraftMessage(final String draftMessage) {
        this.draftMessage = draftMessage;
    }

    public boolean isRead() {
        synchronized (this.messages) {
            for (final Message message : Lists.reverse(this.messages)) {
                if (message.isRead() && message.getType() == Message.TYPE_RTP_SESSION) {
                    continue;
                }
                return message.isRead();
            }
            return true;
        }
    }

    public List<Message> markRead(final String upToUuid) {
        final ImmutableList.Builder<Message> unread = new ImmutableList.Builder<>();
        synchronized (this.messages) {
            for (final Message message : this.messages) {
                if (!message.isRead()) {
                    message.markRead();
                    unread.add(message);
                }
                if (message.getUuid().equals(upToUuid)) {
                    return unread.build();
                }
            }
        }
        return unread.build();
    }

    public Message getLatestMessage() {
        synchronized (this.messages) {
            if (this.messages.isEmpty()) {
                final var message = new Message(this, "", Message.ENCRYPTION_NONE);
                message.setType(Message.TYPE_STATUS);
                final var lastClear = getLastClearHistory();
                message.setTime(
                        Math.max(getCreated(), lastClear == null ? 0 : lastClear.timestamp()));
                return message;
            } else {
                return this.messages.get(this.messages.size() - 1);
            }
        }
    }

    public Instant getLastReceived() {
        synchronized (this.messages) {
            return Iterables.tryFind(
                            Lists.reverse(this.messages),
                            m -> m.getStatus() == Message.STATUS_RECEIVED)
                    .transform(m -> Instant.ofEpochMilli(m.timeSent))
                    .or(Instant.MIN);
        }
    }

    public @NonNull CharSequence getName() {
        if (getMode() == MODE_MULTI) {
            return getName(getMucOptions(), getBookmark());
        } else if ((QuickConversationsService.isConversations()
                        || !Config.QUICKSY_DOMAIN.equals(contactJid.getDomain()))
                && isWithStranger()) {
            return contactJid;
        } else {
            return this.getContact().getDisplayName();
        }
    }

    public static String getName(final MucOptions mucOptions, @Nullable final Bookmark bookmark) {
        final String roomName = mucOptions.getName();
        final String bookmarkName = bookmark != null ? bookmark.getName() : null;
        if (Bookmark.printableValue(roomName)) {
            return roomName;
        } else if (Bookmark.printableValue(bookmarkName)) {
            return bookmarkName;
        } else {
            if (mucOptions.isPrivateAndNonAnonymous()) {
                final var users = mucOptions.getUsersPreviewWithFallback();
                if (!users.isEmpty()) {
                    return UIHelper.concatNames(users, true);
                }
            }
            final var address = mucOptions.getConversation().getAddress();
            if (address.isDomainJid()) {
                return address.toString();
            } else {
                return address.getLocal();
            }
        }
    }

    public String getAccountUuid() {
        return this.accountUuid;
    }

    public Account getAccount() {
        return this.account;
    }

    public void setAccount(final Account account) {
        this.account = account;
    }

    public Contact getContact() {
        return this.account.getRoster().getContact(this.contactJid);
    }

    @Override
    public Jid getAddress() {
        return this.contactJid;
    }

    public int getStatus() {
        return this.status;
    }

    public void setStatus(int status) {
        this.status = status;
    }

    public long getCreated() {
        return this.created;
    }

    public ContentValues getContentValues() {
        ContentValues values = new ContentValues();
        values.put(UUID, uuid);
        values.put(NAME, name);
        values.put(CONTACT, contactUuid);
        values.put(ACCOUNT, accountUuid);
        values.put(CONTACTJID, contactJid.toString());
        values.put(CREATED, created);
        values.put(STATUS, status);
        values.put(MODE, mode);
        synchronized (this.attributes) {
            values.put(ATTRIBUTES, Services.GSON.toJson(attributes));
        }
        return values;
    }

    public int getMode() {
        return this.mode;
    }

    public void setMode(int mode) {
        this.mode = mode;
    }

    /** short for is Private and Non-anonymous */
    public boolean isSingleOrPrivateAndNonAnonymous() {
        return mode == MODE_SINGLE || isPrivateAndNonAnonymous();
    }

    public boolean isPrivateAndNonAnonymous() {
        return getMucOptions().isPrivateAndNonAnonymous();
    }

    public synchronized MucOptions getMucOptions() {
        return getAccount()
                .getXmppConnection()
                .getManager(MultiUserChatManager.class)
                .getOrCreateState(this);
    }

    public void setContactJid(final Jid jid) {
        this.contactJid = jid;
    }

    public Jid getNextCounterpart() {
        return this.nextCounterpart;
    }

    public void setNextCounterpart(Jid jid) {
        this.nextCounterpart = jid;
    }

    public boolean isFormerlyPrivateNonAnonymous() {
        return this.attributes.formerlyPrivateNonAnonymous();
    }

    public boolean setFormerlyPrivateNonAnonymous(final boolean value) {
        final var current = this.attributes.formerlyPrivateNonAnonymous();
        this.attributes.formerlyPrivateNonAnonymous = value;
        return current != value;
    }

    public boolean setMucAffiliation(final Affiliation affiliation) {
        final var current = getMucAffiliationOrNone();
        this.attributes.mucAffiliation = affiliation;
        return current != affiliation;
    }

    @NonNull
    public Affiliation getMucAffiliationOrNone() {
        final var a = this.attributes.mucAffiliation;
        return a == null ? Affiliation.NONE : a;
    }

    @NonNull
    public Role getMucRoleOrNone() {
        final var r = this.attributes.mucRole;
        return r == null ? Role.NONE : r;
    }

    public boolean setMucRole(final Role role) {
        final var current = getMucRoleOrNone();
        this.attributes.mucRole = role;
        return current != role;
    }

    public boolean setMucSubject(final String subject) {
        final var current = this.attributes.mucSubject;
        this.attributes.mucSubject = subject;
        return !Objects.equals(current, subject);
    }

    public String getMucSubject() {
        return this.attributes.mucSubject;
    }

    public String getMucPassword() {
        return this.attributes.mucPassword;
    }

    public void setMucPassword(final String password) {
        this.attributes.mucPassword = password;
    }

    public String getMucCaps2Hash() {
        return this.attributes.mucCaps2Hash;
    }

    public boolean setMucCaps2Hash(final String hash) {
        final var current = this.attributes.mucCaps2Hash;
        this.attributes.mucCaps2Hash = hash;
        return !Objects.equals(current, hash);
    }

    public boolean isPinnedOnTop() {
        return this.attributes.pinnedOnTop();
    }

    public void setPinnedOnTop(final boolean value) {
        this.attributes.pinnedOnTop = value;
    }

    public int getNextEncryption() {
        if (OmemoSetting.isAlways()) {
            return suitableForOmemoByDefault(this)
                    ? Message.ENCRYPTION_AXOLOTL
                    : Message.ENCRYPTION_NONE;
        }
        final int defaultEncryption;
        if (suitableForOmemoByDefault(this)) {
            defaultEncryption = OmemoSetting.getEncryption();
        } else {
            defaultEncryption = Message.ENCRYPTION_NONE;
        }
        final var encryption = this.attributes.nextEncryption;
        if (encryption == null || encryption == Message.ENCRYPTION_OTR) {
            return defaultEncryption;
        } else {
            return encryption;
        }
    }

    public boolean setNextEncryption(final int encryption) {
        final boolean modified =
                this.attributes.nextEncryption == null
                        || this.attributes.nextEncryption != encryption;
        this.attributes.nextEncryption = encryption;
        return modified;
    }

    public @Nullable Draft getDraft() {
        return this.attributes.draft;
    }

    public boolean setNextMessage(final String input) {
        final var message = Strings.nullToEmpty(input).trim();
        final var current = this.attributes.draft;
        if (message.isEmpty()) {
            this.attributes.draft = null;
            return current != null;
        }
        final var modified = current == null || !message.equals(current.message);
        if (modified) {
            this.attributes.draft = new Draft(Instant.now(), message);
            return true;
        }
        return false;
    }

    public Bookmark getBookmark() {
        return this.account
                .getXmppConnection()
                .getManager(BookmarkManager.class)
                .getBookmark(this.contactJid);
    }

    public Message findDuplicateMessage(Message message) {
        synchronized (this.messages) {
            for (int i = this.messages.size() - 1; i >= 0; --i) {
                if (this.messages.get(i).similar(message)) {
                    return this.messages.get(i);
                }
            }
        }
        return null;
    }

    public Message findSentMessageWithBody(String body) {
        synchronized (this.messages) {
            for (int i = this.messages.size() - 1; i >= 0; --i) {
                Message message = this.messages.get(i);
                if (message.getStatus() == Message.STATUS_UNSEND
                        || message.getStatus() == Message.STATUS_SEND) {
                    String otherBody;
                    if (message.hasFileOnRemoteHost()) {
                        otherBody = message.getFileParams().url;
                    } else {
                        otherBody = message.body;
                    }
                    if (otherBody != null && otherBody.equals(body)) {
                        return message;
                    }
                }
            }
            return null;
        }
    }

    public Message findRtpSession(final String sessionId, final int s) {
        synchronized (this.messages) {
            for (int i = this.messages.size() - 1; i >= 0; --i) {
                final Message message = this.messages.get(i);
                if ((message.getStatus() == s)
                        && (message.getType() == Message.TYPE_RTP_SESSION)
                        && sessionId.equals(message.getRemoteMsgId())) {
                    return message;
                }
            }
        }
        return null;
    }

    public boolean possibleDuplicate(final String serverMsgId, final String remoteMsgId) {
        if (serverMsgId == null || remoteMsgId == null) {
            return false;
        }
        synchronized (this.messages) {
            for (Message message : this.messages) {
                if (serverMsgId.equals(message.getServerMsgId())
                        || remoteMsgId.equals(message.getRemoteMsgId())) {
                    return true;
                }
            }
        }
        return false;
    }

    public MamReference getLastMessageTransmitted() {
        final MamReference lastClear = getLastClearHistory();
        MamReference lastReceived = new MamReference(0);
        synchronized (this.messages) {
            for (int i = this.messages.size() - 1; i >= 0; --i) {
                final Message message = this.messages.get(i);
                if (message.isPrivateMessage()) {
                    continue; // it's unsafe to use private messages as anchor. They could be coming
                    // from user archive
                }
                if (message.getStatus() == Message.STATUS_RECEIVED
                        || message.isCarbon()
                        || message.getServerMsgId() != null) {
                    lastReceived =
                            new MamReference(message.getTimeSent(), message.getServerMsgId());
                    break;
                }
            }
        }
        return MamReference.max(lastClear, lastReceived);
    }

    @org.jspecify.annotations.Nullable
    public Instant getMutedTill() {
        return this.attributes.mutedTill;
    }

    public void setMutedTill(final Instant value) {
        this.attributes.mutedTill = value;
    }

    public boolean isMuted() {
        final var mutedTill = this.attributes.mutedTill;
        return mutedTill != null && mutedTill.isAfter(Instant.now());
    }

    public boolean isAcceptNonAnonymous() {
        return this.attributes.acceptNonAnonymous();
    }

    public void setAcceptNonAnonymous(final boolean value) {
        this.attributes.acceptNonAnonymous = value;
    }

    public void setAlwaysNotify(final boolean value) {
        this.attributes.alwaysNotify = value;
    }

    public boolean alwaysNotify() {
        return mode == MODE_SINGLE
                || Attributes.valueOrDefault(
                        this.attributes.alwaysNotify,
                        Config.ALWAYS_NOTIFY_BY_DEFAULT || isPrivateAndNonAnonymous());
    }

    public void add(Message message) {
        synchronized (this.messages) {
            this.messages.add(message);
        }
    }

    public void prepend(int offset, Message message) {
        synchronized (this.messages) {
            this.messages.add(Math.min(offset, this.messages.size()), message);
        }
    }

    public void addAll(int index, List<Message> messages) {
        synchronized (this.messages) {
            this.messages.addAll(index, messages);
        }
        account.getPgpDecryptionService().decrypt(messages);
    }

    public void expireOldMessages(final Instant instant) {
        synchronized (this.messages) {
            for (ListIterator<Message> iterator = this.messages.listIterator();
                    iterator.hasNext(); ) {
                if (iterator.next().getTimeSent() < instant.toEpochMilli()) {
                    iterator.remove();
                }
            }
            untieMessages();
        }
    }

    public void sort() {
        synchronized (this.messages) {
            Collections.sort(
                    this.messages,
                    (left, right) -> {
                        if (left.getTimeSent() < right.getTimeSent()) {
                            return -1;
                        } else if (left.getTimeSent() > right.getTimeSent()) {
                            return 1;
                        } else {
                            return 0;
                        }
                    });
            untieMessages();
        }
    }

    public boolean remove(final Message message) {
        final var success = this.messages.remove(message);
        this.untieMessages();
        return success;
    }

    private void untieMessages() {
        for (Message message : this.messages) {
            message.untie();
        }
    }

    public int unreadCount() {
        synchronized (this.messages) {
            int count = 0;
            for (final Message message : Lists.reverse(this.messages)) {
                if (message.isRead()) {
                    if (message.getType() == Message.TYPE_RTP_SESSION) {
                        continue;
                    }
                    return count;
                }
                ++count;
            }
            return count;
        }
    }

    public int receivedMessagesCount() {
        int count = 0;
        synchronized (this.messages) {
            for (Message message : messages) {
                if (message.getStatus() == Message.STATUS_RECEIVED) {
                    ++count;
                }
            }
        }
        return count;
    }

    public int sentMessagesCount() {
        int count = 0;
        synchronized (this.messages) {
            for (Message message : messages) {
                if (message.getStatus() != Message.STATUS_RECEIVED) {
                    ++count;
                }
            }
        }
        return count;
    }

    public boolean isWithStranger() {
        final Contact contact = getContact();
        return mode == MODE_SINGLE
                && !contact.isOwnServer()
                && !contact.showInContactList()
                && !contact.isSelf()
                && !(contact.getAddress().isDomainJid()
                        && JidHelper.isQuicksyDomain(contact.getAddress()))
                && sentMessagesCount() == 0;
    }

    public int getReceivedMessagesCountSinceUuid(String uuid) {
        if (uuid == null) {
            return 0;
        }
        int count = 0;
        synchronized (this.messages) {
            for (int i = messages.size() - 1; i >= 0; i--) {
                final Message message = messages.get(i);
                if (uuid.equals(message.getUuid())) {
                    return count;
                }
                if (message.getStatus() <= Message.STATUS_RECEIVED) {
                    ++count;
                }
            }
        }
        return 0;
    }

    @Override
    public int getAvatarBackgroundColor() {
        return UIHelper.getColorForName(getName().toString());
    }

    @Override
    public CharSequence getDisplayName() {
        return getName();
    }

    public void setDisplayState(final String stanzaId) {
        this.displayState = stanzaId;
    }

    public String getDisplayState() {
        return this.displayState;
    }

    public static final class Attributes {
        @SerializedName("muted_till")
        private Instant mutedTill;

        @SerializedName("always_notify")
        private Boolean alwaysNotify;

        @SerializedName("last_clear")
        private MamReference lastClearHistory;

        @SerializedName("formerly_private_non_anonymous")
        private Boolean formerlyPrivateNonAnonymous;

        @SerializedName("pinned_on_top")
        private Boolean pinnedOnTop;

        private Affiliation mucAffiliation;
        private Role mucRole;

        @SerializedName("muc_password")
        private String mucPassword;

        @SerializedName("muc_caps2_hash")
        private String mucCaps2Hash;

        @SerializedName("subject")
        private String mucSubject;

        @SerializedName("draft")
        private Draft draft;

        @SerializedName("crypto_targets")
        private List<Jid> cryptoTargets;

        @SerializedName("next_encryption")
        private Integer nextEncryption;

        @SerializedName("correcting_message")
        private String correctingMessage;

        @SerializedName("accept_non_anonymous")
        private Boolean acceptNonAnonymous;

        public static Attributes parse(final String json) {
            if (Strings.isNullOrEmpty(json)) {
                return new Attributes();
            }
            try {
                return Services.GSON.fromJson(json, Attributes.class);
            } catch (final JsonParseException e) {
                Log.d(Config.LOGTAG, "could not parse account keys from " + json, e);
                return new Attributes();
            }
        }

        public boolean acceptNonAnonymous() {
            return valueOrDefault(this.acceptNonAnonymous, false);
        }

        public boolean pinnedOnTop() {
            return valueOrDefault(this.pinnedOnTop, false);
        }

        public boolean formerlyPrivateNonAnonymous() {
            return valueOrDefault(this.formerlyPrivateNonAnonymous, false);
        }

        public MamReference lastClearHistory() {
            return this.lastClearHistory;
        }

        private static boolean valueOrDefault(final Boolean value, final boolean d) {
            return value == null ? d : value;
        }
    }

    public interface OnMessageFound {
        void onMessageFound(final Message message);
    }

    public record Draft(Instant instant, String message) {}
}
