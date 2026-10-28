package eu.siacs.conversations.ui;

import android.app.Activity;
import android.content.Intent;
import android.os.Build;
import android.os.Bundle;
import android.text.SpannableString;
import android.text.method.LinkMovementMethod;
import android.util.Log;
import android.view.Menu;
import android.view.MenuItem;
import android.view.View;
import android.view.View.OnClickListener;
import android.widget.Toast;
import androidx.annotation.NonNull;
import androidx.appcompat.app.AlertDialog;
import androidx.core.content.ContextCompat;
import androidx.databinding.DataBindingUtil;
import com.google.android.material.dialog.MaterialAlertDialogBuilder;
import com.google.common.collect.ImmutableMap;
import com.google.common.util.concurrent.FutureCallback;
import com.google.common.util.concurrent.Futures;
import de.gultsch.common.Linkify;
import de.gultsch.common.MiniUri;
import eu.siacs.conversations.Config;
import eu.siacs.conversations.R;
import eu.siacs.conversations.databinding.ActivityMucDetailsBinding;
import eu.siacs.conversations.entities.Conversation;
import eu.siacs.conversations.entities.Conversational;
import eu.siacs.conversations.entities.MucOptions;
import eu.siacs.conversations.entities.MucOptions.User;
import eu.siacs.conversations.services.XmppConnectionService.OnConversationUpdate;
import eu.siacs.conversations.services.XmppConnectionService.OnMucRosterUpdate;
import eu.siacs.conversations.ui.adapter.MediaAdapter;
import eu.siacs.conversations.ui.adapter.UserPreviewAdapter;
import eu.siacs.conversations.ui.interfaces.OnMediaLoaded;
import eu.siacs.conversations.ui.text.FixedURLSpan;
import eu.siacs.conversations.ui.util.Attachment;
import eu.siacs.conversations.ui.util.AvatarWorkerTask;
import eu.siacs.conversations.ui.util.GridManager;
import eu.siacs.conversations.ui.util.MenuDoubleTabUtil;
import eu.siacs.conversations.ui.util.MucConfiguration;
import eu.siacs.conversations.ui.util.MucDetailsContextMenuHelper;
import eu.siacs.conversations.utils.AccountUtils;
import eu.siacs.conversations.utils.Compatibility;
import eu.siacs.conversations.utils.JidHelper;
import eu.siacs.conversations.utils.StylingHelper;
import eu.siacs.conversations.xmpp.manager.BookmarkManager;
import im.conversations.android.model.Bookmark;
import im.conversations.android.xmpp.model.muc.Affiliation;
import java.time.Duration;
import java.time.Instant;
import java.util.Collections;
import java.util.List;
import eu.siacs.conversations.utils.TimeFrameUtils;

public class ConferenceDetailsActivity extends XmppActivity
        implements OnConversationUpdate, OnMucRosterUpdate, OnMediaLoaded {
    public static final String ACTION_VIEW_MUC = "view_muc";

    private Conversation mConversation;
    private ActivityMucDetailsBinding binding;
    private MediaAdapter mMediaAdapter;
    private UserPreviewAdapter mUserPreviewAdapter;
    private String uuid = null;

    public static void open(final Activity activity, final Conversation conversation) {
        Intent intent = new Intent(activity, ConferenceDetailsActivity.class);
        intent.setAction(ConferenceDetailsActivity.ACTION_VIEW_MUC);
        intent.putExtra("uuid", conversation.getUuid());
        activity.startActivity(intent);
    }

    private void openChat() {
        if (mConversation != null) {
            switchToConversation(mConversation);
            finish();
        }
    }

    private void toggleMute() {
        if (mConversation != null) {
            if (mConversation.isMuted()) {
                unMuteConversation(mConversation);
            } else {
                muteConversationDialog(mConversation);
            }
        }
    }

    protected void muteConversationDialog(final Conversation conversation) {
        final MaterialAlertDialogBuilder builder = new MaterialAlertDialogBuilder(this);
        builder.setTitle(R.string.disable_notifications);
        final int[] durations = getResources().getIntArray(R.array.mute_options_durations);
        final CharSequence[] labels = new CharSequence[durations.length];
        for (int i = 0; i < durations.length; ++i) {
            if (durations[i] == -1) {
                labels[i] = getString(R.string.until_further_notice);
            } else {
                labels[i] = TimeFrameUtils.resolve(this, 1000L * durations[i]);
            }
        }
        builder.setItems(
                labels,
                (dialog, which) -> {
                    final Instant till;
                    if (durations[which] == -1) {
                        till = Instant.MAX;
                    } else {
                        till = Instant.now().plus(Duration.ofSeconds(durations[which]));
                    }
                    conversation.setMutedTill(till);
                    if (xmppConnectionService != null) {
                        xmppConnectionService.updateConversation(conversation);
                    }
                    updateView();
                });
        builder.create().show();
    }

    public void unMuteConversation(final Conversation conversation) {
        conversation.setMutedTill(null);
        if (xmppConnectionService != null) {
            xmppConnectionService.updateConversation(conversation);
        }
        updateView();
    }

    @Override
    public void onConversationUpdate() {
        refreshUi();
    }

    @Override
    public void onMucRosterUpdate() {
        refreshUi();
    }

    @Override
    protected void refreshUiReal() {
        updateView();
    }

    @Override
    protected void onCreate(final Bundle savedInstanceState) {
        super.onCreate(savedInstanceState);
        if (savedInstanceState != null) {
            this.uuid = savedInstanceState.getString("uuid");
        }
        if (this.uuid == null && getIntent() != null) {
            if (getIntent().hasExtra("uuid")) {
                this.uuid = getIntent().getStringExtra("uuid");
            } else if (getIntent().getExtras() != null) {
                this.uuid = getIntent().getExtras().getString("uuid");
            }
        }
        this.binding = DataBindingUtil.setContentView(this, R.layout.activity_muc_details);
        Activities.setStatusAndNavigationBarColors(this, binding.getRoot());
        setSupportActionBar(binding.toolbar);
        configureActionBar(getSupportActionBar());
        if (getSupportActionBar() != null) {
            getSupportActionBar().setTitle("");
        }
        this.binding.toolbar.setTitle("");

        this.binding.btnActionChat.setOnClickListener(v -> openChat());
        this.binding.btnActionMute.setOnClickListener(v -> toggleMute());
        this.binding.btnActionInvite.setOnClickListener(v -> inviteToConversation(mConversation));
        this.binding.rowNotifications.setOnClickListener(v -> toggleMute());
        this.binding.yourPhoto.setOnClickListener(
                v -> {
                    if (mConversation == null) {
                        return;
                    }
                    final MucOptions mucOptions = mConversation.getMucOptions();
                    if (mucOptions == null || !mucOptions.hasVCards()) {
                        Toast.makeText(
                                        this,
                                        R.string.host_does_not_support_group_chat_avatars,
                                        Toast.LENGTH_SHORT)
                                .show();
                        return;
                    }
                    final User self = mucOptions.getSelf();
                    if (self == null || !self.ranks(Affiliation.OWNER)) {
                        Toast.makeText(
                                        this,
                                        R.string.only_the_owner_can_change_group_chat_avatar,
                                        Toast.LENGTH_SHORT)
                                .show();
                        return;
                    }
                    final Intent intent =
                            new Intent(this, PublishGroupChatProfilePictureActivity.class);
                    intent.putExtra("uuid", mConversation.getUuid());
                    startActivity(intent);
                });
        this.binding.editMucNameButton.setContentDescription(
                getString(R.string.edit_name_and_topic));
        this.binding.editMucNameButton.setOnClickListener(
                v -> {
                    if (mConversation != null) {
                        final Intent intent = new Intent(this, EditConferenceActivity.class);
                        intent.putExtra("uuid", mConversation.getUuid());
                        startActivity(intent);
                    }
                });
        this.mMediaAdapter = new MediaAdapter(this, R.dimen.media_size);
        this.mUserPreviewAdapter = new UserPreviewAdapter();
        this.binding.media.setAdapter(mMediaAdapter);
        this.binding.users.setAdapter(mUserPreviewAdapter);
        GridManager.setupLayoutManager(this, this.binding.media, R.dimen.media_size);
        GridManager.setupLayoutManager(this, this.binding.users, R.dimen.media_size);
        this.binding.invite.setOnClickListener(v -> inviteToConversation(mConversation));
        this.binding.showUsers.setOnClickListener(
                v -> {
                    Intent intent = new Intent(this, MucUsersActivity.class);
                    intent.putExtra("uuid", mConversation.getUuid());
                    startActivity(intent);
                });
    }

    @Override
    protected void onSaveInstanceState(@NonNull final Bundle outState) {
        super.onSaveInstanceState(outState);
        if (this.uuid != null) {
            outState.putString("uuid", this.uuid);
        }
    }

    @Override
    public void onStart() {
        super.onStart();
        binding.mediaWrapper.setVisibility(
                Compatibility.hasStoragePermission(this) ? View.VISIBLE : View.GONE);
    }

    @Override
    public boolean onOptionsItemSelected(MenuItem menuItem) {
        if (MenuDoubleTabUtil.shouldIgnoreTap()) {
            return false;
        }
        final int itemId = menuItem.getItemId();
        if (itemId == android.R.id.home) {
            finish();
            return true;
        } else if (itemId == R.id.action_share_http) {
            shareLink(true);
            return true;
        } else if (itemId == R.id.action_share_uri) {
            shareLink(false);
            return true;
        } else if (itemId == R.id.action_save_as_bookmark) {
            saveAsBookmark();
            return true;
        } else if (itemId == R.id.action_destroy_room) {
            destroyRoom();
            return true;
        } else {
            return super.onOptionsItemSelected(menuItem);
        }
    }

    @Override
    public boolean onContextItemSelected(@NonNull final MenuItem item) {
        final User user = mUserPreviewAdapter.getSelectedUser();
        if (user == null) {
            Toast.makeText(this, R.string.unable_to_perform_this_action, Toast.LENGTH_SHORT).show();
            return true;
        }
        if (!MucDetailsContextMenuHelper.onContextItemSelected(
                item, mUserPreviewAdapter.getSelectedUser(), this)) {
            return super.onContextItemSelected(item);
        }
        return true;
    }



    @Override
    protected MiniUri getShareableUri(final boolean http) {
        if (mConversation == null) {
            return null;
        }
        final var uri =
                new MiniUri.Xmpp(
                        mConversation.getAddress().asBareJid(),
                        ImmutableMap.of(
                                MiniUri.Xmpp.ACTION_JOIN,
                                Collections.singleton(MiniUri.EMPTY_STRING)));
        return http ? uri.asInvitationUri() : uri;
    }

    @Override
    public boolean onPrepareOptionsMenu(final Menu menu) {
        final MenuItem menuItemSaveBookmark = menu.findItem(R.id.action_save_as_bookmark);
        final MenuItem menuItemDestroyRoom = menu.findItem(R.id.action_destroy_room);
        if (mConversation == null) {
            return true;
        }
        if (menuItemSaveBookmark != null) {
            menuItemSaveBookmark.setVisible(mConversation.getBookmark() == null);
        }
        if (menuItemDestroyRoom != null) {
            final MucOptions mucOptions = mConversation.getMucOptions();
            final User self = mucOptions != null ? mucOptions.getSelf() : null;
            menuItemDestroyRoom.setVisible(
                    self != null && self.ranks(Affiliation.OWNER));
        }
        return true;
    }

    @Override
    public boolean onCreateOptionsMenu(final Menu menu) {
        final boolean groupChat = mConversation != null && mConversation.isPrivateAndNonAnonymous();
        getMenuInflater().inflate(R.menu.muc_details, menu);
        final MenuItem share = menu.findItem(R.id.action_share);
        if (share != null) {
            share.setVisible(!groupChat);
        }
        final MenuItem destroy = menu.findItem(R.id.action_destroy_room);
        if (destroy != null) {
            destroy.setTitle(groupChat ? R.string.destroy_room : R.string.destroy_channel);
        }
        return super.onCreateOptionsMenu(menu);
    }

    @Override
    public void onMediaLoaded(final List<Attachment> attachments) {
        runOnUiThread(
                () -> {
                    final int limit = GridManager.getCurrentColumnCount(binding.media);
                    mMediaAdapter.submitList(
                            attachments.subList(0, Math.min(limit, attachments.size())));
                    binding.mediaWrapper.setVisibility(
                            attachments.isEmpty() ? View.GONE : View.VISIBLE);
                });
    }

    protected void saveAsBookmark() {
        final var account = mConversation.getAccount();
        account.getXmppConnection()
                .getManager(BookmarkManager.class)
                .save(mConversation, mConversation.getMucOptions().getName());
    }

    protected void destroyRoom() {
        final var destroyCallBack =
                new FutureCallback<Void>() {

                    @Override
                    public void onSuccess(Void result) {
                        finish();
                    }

                    @Override
                    public void onFailure(Throwable t) {
                        final boolean groupChat =
                                mConversation != null && mConversation.isPrivateAndNonAnonymous();
                        // TODO show toast directly
                        displayToast(
                                getString(
                                        groupChat
                                                ? R.string.could_not_destroy_room
                                                : R.string.could_not_destroy_channel));
                    }
                };
        final boolean groupChat = mConversation != null && mConversation.isPrivateAndNonAnonymous();
        final MaterialAlertDialogBuilder builder = new MaterialAlertDialogBuilder(this);
        builder.setTitle(groupChat ? R.string.destroy_room : R.string.destroy_channel);
        builder.setMessage(
                groupChat ? R.string.destroy_room_dialog : R.string.destroy_channel_dialog);
        builder.setPositiveButton(
                R.string.ok,
                (dialog, which) -> {
                    // TODO call manager directly
                    final var future = xmppConnectionService.destroyRoom(mConversation);
                    Futures.addCallback(
                            future,
                            destroyCallBack,
                            ContextCompat.getMainExecutor(getApplication()));
                });
        builder.setNegativeButton(R.string.cancel, null);
        final AlertDialog dialog = builder.create();
        dialog.setCanceledOnTouchOutside(false);
        dialog.show();
    }

    private void showErrorState(final String message) {
        runOnUiThread(() -> {
            this.binding.contentScrollView.setVisibility(View.GONE);
            this.binding.errorLayout.setVisibility(View.VISIBLE);
            if (message != null) {
                this.binding.errorText.setText(message);
            }
        });
    }

    @Override
    protected void onBackendConnected() {
        if (mPendingConferenceInvite != null) {
            mPendingConferenceInvite.execute(this);
            mPendingConferenceInvite = null;
        }
        if (this.uuid == null && getIntent() != null) {
            if (getIntent().hasExtra("uuid")) {
                this.uuid = getIntent().getStringExtra("uuid");
            } else if (getIntent().getExtras() != null) {
                this.uuid = getIntent().getExtras().getString("uuid");
            }
        }
        if (this.uuid != null) {
            this.mConversation = xmppConnectionService.findConversationByUuid(this.uuid);
            if (this.mConversation != null) {
                this.binding.contentScrollView.setVisibility(View.VISIBLE);
                this.binding.errorLayout.setVisibility(View.GONE);
                if (Compatibility.hasStoragePermission(this)) {
                    final int limit = GridManager.getCurrentColumnCount(this.binding.media);
                    xmppConnectionService.getAttachments(this.mConversation, limit, this);
                    this.binding.showMedia.setOnClickListener(
                            (v) -> MediaBrowserActivity.launch(this, mConversation));
                }
                updateView();
            } else {
                showErrorState("Не удалось найти беседу в приложении (UUID: " + this.uuid + "). Это внутренняя ошибка приложения. Повторные попытки перезахода не помогут.");
            }
        } else {
            showErrorState("Идентификатор беседы не был передан при открытии экрана. Это внутренняя ошибка приложения.");
        }
    }

    private void updateView() {
        invalidateOptionsMenu();
        if (mConversation == null) {
            showErrorState("Беседа недоступна. Это внутренняя ошибка приложения.");
            return;
        }
        final MucOptions mucOptions = mConversation.getMucOptions();
        final User self = mucOptions != null ? mucOptions.getSelf() : null;

        setTitle("");
        if (getSupportActionBar() != null) {
            getSupportActionBar().setTitle("");
        }
        this.binding.toolbar.setTitle("");

        final boolean isArchived = mConversation.getStatus() == Conversation.STATUS_ARCHIVED;
        final boolean canEdit =
                !isArchived
                        && self != null
                        && (self.ranks(Affiliation.OWNER)
                                || (mucOptions != null && mucOptions.canChangeSubject()));
        this.binding.editMucNameButton.setVisibility(canEdit ? View.VISIBLE : View.GONE);

        AvatarWorkerTask.loadAvatar(
                mConversation, binding.yourPhoto, R.dimen.avatar_on_details_screen_size);
        String roomName = mucOptions != null ? mucOptions.getName() : null;
        String subject = mucOptions != null ? mucOptions.getSubject() : null;
        final boolean hasTitle;
        if (Bookmark.printableValue(roomName)) {
            this.binding.mucTitle.setText(roomName);
            this.binding.mucTitle.setVisibility(View.VISIBLE);
            hasTitle = true;
        } else if (!Bookmark.printableValue(subject)) {
            this.binding.mucTitle.setText(mConversation.getName());
            hasTitle = true;
            this.binding.mucTitle.setVisibility(View.VISIBLE);
        } else {
            this.binding.mucTitle.setText(mConversation.getName());
            hasTitle = true;
            this.binding.mucTitle.setVisibility(View.VISIBLE);
        }

        final var userCount = mucOptions != null ? mucOptions.getUserCount() : 0;
        if (userCount > 0) {
            this.binding.mucMembersCount.setText(
                    getResources().getQuantityString(R.plurals.view_users, userCount, userCount));
            this.binding.mucMembersCount.setVisibility(View.VISIBLE);
        } else {
            this.binding.mucMembersCount.setVisibility(View.GONE);
        }

        if (Bookmark.printableValue(subject)) {
            final var spannable = new SpannableString(subject);
            StylingHelper.format(spannable, this.binding.mucSubject.getCurrentTextColor());
            Linkify.addLinks(spannable);
            FixedURLSpan.fix(spannable);
            this.binding.mucSubject.setText(spannable);
            this.binding.mucSubject.setTextAppearance(
                    subject.length() > (hasTitle ? 128 : 196)
                            ? com.google.android.material.R.style
                                    .TextAppearance_Material3_BodyMedium
                            : com.google.android.material.R.style
                                    .TextAppearance_Material3_BodyLarge);
            this.binding.mucSubject.setMovementMethod(LinkMovementMethod.getInstance());
            this.binding.rowSubject.setVisibility(View.VISIBLE);
        } else {
            this.binding.rowSubject.setVisibility(View.GONE);
        }

        // Notifications & Mute
        final boolean isMuted = mConversation.isMuted();
        this.binding.iconActionMute.setImageResource(
                isMuted ? R.drawable.ic_notifications_off_24dp : R.drawable.ic_notifications_24dp);
        if (isMuted) {
            final var mutedTill = mConversation.getMutedTill();
            if (Instant.MAX.equals(mutedTill)) {
                this.binding.notificationStatusText.setText(R.string.notify_never);
            } else {
                this.binding.notificationStatusText.setText(R.string.notify_paused);
            }
        } else {
            this.binding.notificationStatusText.setText("Включены");
        }

        final boolean canInvite = !isArchived && mucOptions != null && mucOptions.canInvite();
        if (mucOptions != null && userCount > 0) {
            this.binding.users.post(
                    () -> {
                        final var list =
                                mucOptions.getUsersPreview(
                                        GridManager.getCurrentColumnCount(binding.users));
                        this.mUserPreviewAdapter.submitList(list);
                    });
        }
        this.binding.invite.setVisibility(canInvite ? View.VISIBLE : View.GONE);
        this.binding.btnActionInvite.setVisibility(canInvite ? View.VISIBLE : View.GONE);
        this.binding.showUsers.setVisibility(userCount == 0 ? View.GONE : View.VISIBLE);
        this.binding.showUsers.setText(
                getResources().getQuantityString(R.plurals.view_users, userCount, userCount));
        if (isArchived) {
            this.binding.usersWrapper.setVisibility(View.VISIBLE);
            this.binding.noUsersHints.setText("Чат находится в архиве");
            this.binding.noUsersHints.setVisibility(View.VISIBLE);
        } else {
            this.binding.usersWrapper.setVisibility(
                    userCount > 0 || canInvite ? View.VISIBLE : View.GONE);
            if (userCount == 0) {
                this.binding.noUsersHints.setText(
                        (mucOptions != null && mucOptions.isPrivateAndNonAnonymous())
                                ? R.string.no_users_hint_group_chat
                                : R.string.no_users_hint_channel);
                this.binding.noUsersHints.setVisibility(View.VISIBLE);
            } else {
                this.binding.noUsersHints.setVisibility(View.GONE);
            }
        }
    }

    private void displayToast(final String msg) {
        runOnUiThread(
                () -> {
                    if (isFinishing()) {
                        return;
                    }
                    Toast.makeText(this, msg, Toast.LENGTH_SHORT).show();
                });
    }


}
