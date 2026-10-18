package eu.siacs.conversations.ui;

import static eu.siacs.conversations.utils.StringUtils.changed;

import android.content.Intent;
import android.os.Bundle;
import android.view.View;
import android.widget.Toast;
import androidx.databinding.DataBindingUtil;
import com.google.common.base.Strings;
import com.google.common.collect.ImmutableMap;
import eu.siacs.conversations.R;
import eu.siacs.conversations.databinding.ActivityEditConferenceBinding;
import eu.siacs.conversations.entities.Conversation;
import eu.siacs.conversations.entities.MucOptions;
import eu.siacs.conversations.ui.util.AvatarWorkerTask;
import eu.siacs.conversations.ui.util.SoftKeyboardUtils;
import eu.siacs.conversations.xmpp.manager.MultiUserChatManager;
import im.conversations.android.model.Bookmark;
import im.conversations.android.xmpp.model.muc.Affiliation;

public class EditConferenceActivity extends XmppActivity {

    private ActivityEditConferenceBinding binding;
    private Conversation conversation;
    private String uuid;

    @Override
    protected void onCreate(final Bundle savedInstanceState) {
        super.onCreate(savedInstanceState);
        this.binding = DataBindingUtil.setContentView(this, R.layout.activity_edit_conference);
        Activities.setStatusAndNavigationBarColors(this, binding.getRoot());

        this.uuid = getIntent().getStringExtra("uuid");

        this.binding.toolbar.setNavigationOnClickListener(v -> finish());
        this.binding.btnSaveToolbar.setOnClickListener(v -> save());
        this.binding.btnSave.setOnClickListener(v -> save());
        this.binding.avatarContainer.setOnClickListener(v -> onAvatarClicked());
    }

    @Override
    protected void refreshUiReal() {
        if (this.conversation != null) {
            AvatarWorkerTask.loadAvatar(
                    this.conversation, binding.groupPhoto, R.dimen.avatar_on_details_screen_size);
        }
    }

    @Override
    protected void onBackendConnected() {
        if (uuid != null) {
            this.conversation = xmppConnectionService.findConversationByUuid(uuid);
        }
        if (this.conversation == null) {
            finish();
            return;
        }

        final MucOptions mucOptions = this.conversation.getMucOptions();
        final MucOptions.User self = mucOptions.getSelf();
        if (self == null) {
            finish();
            return;
        }

        AvatarWorkerTask.loadAvatar(
                this.conversation, binding.groupPhoto, R.dimen.avatar_on_details_screen_size);

        final String roomName = mucOptions.getName();
        final String subject = mucOptions.getSubject();

        if (this.binding.editTitle.getText().length() == 0 && Bookmark.printableValue(roomName)) {
            this.binding.editTitle.setText(roomName);
        }
        if (this.binding.editSubject.getText().length() == 0 && Bookmark.printableValue(subject)) {
            this.binding.editSubject.setText(subject);
        }

        final boolean isOwner = self.ranks(Affiliation.OWNER);
        final boolean canSubject = mucOptions.canChangeSubject();

        this.binding.editTitle.setEnabled(isOwner);
        if (!isOwner) {
            this.binding.editTitle.setHint("Только владелец может менять название");
        }

        this.binding.editSubject.setEnabled(canSubject);
        if (!canSubject) {
            this.binding.editSubject.setHint("Недостаточно прав для изменения описания");
        }
    }

    private void onAvatarClicked() {
        if (conversation == null) return;
        final MucOptions mucOptions = conversation.getMucOptions();
        if (!mucOptions.hasVCards()) {
            Toast.makeText(this, R.string.host_does_not_support_group_chat_avatars, Toast.LENGTH_SHORT).show();
            return;
        }
        if (!mucOptions.getSelf().ranks(Affiliation.OWNER)) {
            Toast.makeText(this, R.string.only_the_owner_can_change_group_chat_avatar, Toast.LENGTH_SHORT).show();
            return;
        }
        final Intent intent = new Intent(this, PublishGroupChatProfilePictureActivity.class);
        intent.putExtra("uuid", conversation.getUuid());
        startActivity(intent);
    }

    private void save() {
        if (conversation == null) {
            finish();
            return;
        }
        SoftKeyboardUtils.hideSoftKeyboard(this);

        final MucOptions mucOptions = conversation.getMucOptions();
        final MucOptions.User self = mucOptions.getSelf();
        if (self == null) {
            finish();
            return;
        }

        final boolean isOwner = self.ranks(Affiliation.OWNER);
        final boolean canSubject = mucOptions.canChangeSubject();

        final String newName = this.binding.editTitle.getText().toString().trim();
        final String newSubject = this.binding.editSubject.getText().toString().trim();

        boolean changedAny = false;

        if (canSubject && changed(mucOptions.getSubject(), newSubject)) {
            xmppConnectionService.pushSubjectToConference(conversation, newSubject);
            changedAny = true;
        }

        if (isOwner && changed(mucOptions.getRoomConfigName(), newName)) {
            final var options =
                    new ImmutableMap.Builder<String, Object>()
                            .put("muc#roomconfig_persistentroom", true)
                            .put("muc#roomconfig_roomname", Strings.nullToEmpty(newName))
                            .build();
            conversation.getAccount()
                    .getXmppConnection()
                    .getManager(MultiUserChatManager.class)
                    .pushConfiguration(conversation, options);
            changedAny = true;
        }

        if (changedAny) {
            Toast.makeText(this, R.string.modified_conference_options, Toast.LENGTH_SHORT).show();
        }

        finish();
    }
}
