package eu.siacs.conversations.ui;

import android.content.Intent;
import android.os.Bundle;
import androidx.annotation.NonNull;
import androidx.core.content.ContextCompat;
import androidx.databinding.DataBindingUtil;
import com.google.android.material.color.MaterialColors;
import com.google.common.util.concurrent.FutureCallback;
import com.google.common.util.concurrent.Futures;
import eu.siacs.conversations.R;
import eu.siacs.conversations.databinding.ActivitySearchBinding;
import eu.siacs.conversations.entities.Contact;
import eu.siacs.conversations.entities.Message;
import eu.siacs.conversations.persistance.DatabaseBackend;
import eu.siacs.conversations.ui.adapter.MessageAdapter;
import eu.siacs.conversations.ui.util.DateSeparator;
import eu.siacs.conversations.ui.util.ListViewUtils;
import java.util.ArrayList;
import java.util.List;

public class EditHistoryActivity extends XmppActivity
        implements MessageAdapter.OnContactPictureClicked {

    public static final String EXTRA_CONVERSATION_UUID = "conversation-uuid";
    public static final String EXTRA_MESSAGE_UUID = "message-uuid";

    private ActivitySearchBinding binding;
    private MessageAdapter messageListAdapter;
    private final List<Message> messages = new ArrayList<>();
    private String conversationUuid;
    private String messageUuid;

    @Override
    public void onCreate(final Bundle bundle) {
        super.onCreate(bundle);
        final Intent intent = getIntent();
        final Bundle parameters;
        if (bundle != null) {
            parameters = bundle;
        } else if (intent != null) {
            parameters = intent.getExtras();
        } else {
            parameters = null;
        }
        if (parameters != null) {
            this.conversationUuid = parameters.getString(EXTRA_CONVERSATION_UUID);
            this.messageUuid = parameters.getString(EXTRA_MESSAGE_UUID);
        } else {
            this.conversationUuid = null;
            this.messageUuid = null;
        }
        this.binding = DataBindingUtil.setContentView(this, R.layout.activity_search);
        this.binding.searchResults.setBackgroundColor(
                MaterialColors.getColor(
                        binding.searchResults, com.google.android.material.R.attr.colorSurface));
        Activities.setStatusAndNavigationBarColors(this, binding.getRoot());
        setSupportActionBar(this.binding.toolbar);
        configureActionBar(getSupportActionBar());
        this.messageListAdapter = new MessageAdapter(this, this.messages, false);
        this.messageListAdapter.setOnContactPictureClicked(this);
        this.binding.searchResults.setAdapter(messageListAdapter);
    }

    @Override
    public void onSaveInstanceState(@NonNull Bundle bundle) {
        if (this.conversationUuid != null && this.messageUuid != null) {
            bundle.putString(EXTRA_CONVERSATION_UUID, this.conversationUuid);
            bundle.putString(EXTRA_MESSAGE_UUID, this.messageUuid);
        }
        super.onSaveInstanceState(bundle);
    }

    @Override
    protected void refreshUiReal() {}

    @Override
    protected void onBackendConnected() {
        if (this.conversationUuid == null || this.messageUuid == null) {
            return;
        }
        final var c = xmppConnectionService.findConversationByUuid(this.conversationUuid);
        if (c == null) {
            return;
        }
        final var future =
                DatabaseBackend.getInstance(this).getMessageWithUuidFuture(c, this.messageUuid);
        Futures.addCallback(
                future,
                new FutureCallback<>() {
                    @Override
                    public void onSuccess(final Message m) {
                        setMessages(m.getVersionsAsMessages());
                    }

                    @Override
                    public void onFailure(@NonNull Throwable t) {}
                },
                ContextCompat.getMainExecutor(this));
    }

    private void setMessages(final List<Message> messages) {
        this.messages.clear();
        this.messages.addAll(messages);
        DateSeparator.addAll(this.messages);
        messageListAdapter.notifyDataSetChanged();
        ListViewUtils.scrollToBottom(this.binding.searchResults);
    }

    @Override
    public void onContactPictureClicked(Message message) {
        String fingerprint;
        if (message.getEncryption() == Message.ENCRYPTION_PGP
                || message.getEncryption() == Message.ENCRYPTION_DECRYPTED) {
            fingerprint = "pgp";
        } else {
            fingerprint = message.getFingerprint();
        }
        if (message.getStatus() == Message.STATUS_RECEIVED) {
            final Contact contact = message.getContact();
            if (contact != null) {
                if (contact.isSelf()) {
                    switchToAccount(message.getConversation().getAccount(), fingerprint);
                } else {
                    switchToContactDetails(contact, fingerprint);
                }
            }
        } else {
            switchToAccount(message.getConversation().getAccount(), fingerprint);
        }
    }
}
