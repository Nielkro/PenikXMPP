package eu.siacs.conversations.ui.adapter;

import android.content.Intent;
import android.view.ContextMenu;
import android.view.LayoutInflater;
import android.view.View;
import android.view.ViewGroup;
import android.widget.Toast;
import androidx.annotation.NonNull;
import androidx.databinding.DataBindingUtil;
import androidx.recyclerview.widget.ListAdapter;
import androidx.recyclerview.widget.RecyclerView;
import eu.siacs.conversations.R;
import eu.siacs.conversations.databinding.ItemUserPreviewBinding;
import eu.siacs.conversations.entities.Contact;
import eu.siacs.conversations.entities.MucOptions;
import eu.siacs.conversations.ui.ContactDetailsActivity;
import eu.siacs.conversations.ui.EditAccountActivity;
import eu.siacs.conversations.ui.XmppActivity;
import eu.siacs.conversations.ui.util.AvatarWorkerTask;
import eu.siacs.conversations.ui.util.MucDetailsContextMenuHelper;
import eu.siacs.conversations.xmpp.Jid;

public class UserPreviewAdapter extends ListAdapter<MucOptions.User, UserPreviewAdapter.ViewHolder>
        implements View.OnCreateContextMenuListener {

    private MucOptions.User selectedUser = null;

    public UserPreviewAdapter() {
        super(UserAdapter.DIFF);
    }

    @NonNull
    @Override
    public ViewHolder onCreateViewHolder(@NonNull ViewGroup viewGroup, int position) {
        return new ViewHolder(
                DataBindingUtil.inflate(
                        LayoutInflater.from(viewGroup.getContext()),
                        R.layout.item_user_preview,
                        viewGroup,
                        false));
    }

    @Override
    public void onBindViewHolder(@NonNull ViewHolder viewHolder, int position) {
        final MucOptions.User user = getItem(position);
        AvatarWorkerTask.loadAvatar(user, viewHolder.binding.avatar, R.dimen.media_size);
        viewHolder
                .binding
                .getRoot()
                .setOnClickListener(
                        v -> {
                            final XmppActivity activity = XmppActivity.find(v);
                            if (activity == null) {
                                return;
                            }
                            final Jid realJid = user.getRealJid();
                            if (realJid != null) {
                                if (user.realJidMatchesAccount()) {
                                    final Intent intent = new Intent(activity, EditAccountActivity.class);
                                    intent.putExtra("jid", user.getAccount().getJid().asBareJid().toString());
                                    activity.startActivity(intent);
                                } else {
                                    final Contact contact = user.getAccount().getRoster().getContact(realJid);
                                    final Intent intent = new Intent(activity, ContactDetailsActivity.class);
                                    intent.setAction(ContactDetailsActivity.ACTION_VIEW_CONTACT);
                                    intent.putExtra(XmppActivity.EXTRA_ACCOUNT, contact.getAccount().getJid().asBareJid().toString());
                                    intent.putExtra("contact", contact.getAddress().toString());
                                    activity.startActivity(intent);
                                }
                                return;
                            }
                            if (user.resource() == null) {
                                Toast.makeText(
                                                activity,
                                                activity.getString(
                                                        R.string.presence_offline),
                                                Toast.LENGTH_SHORT)
                                        .show();
                            }
                            activity.highlightInMuc(user.getConversation(), user.resource());
                        });
        viewHolder.binding.getRoot().setOnCreateContextMenuListener(this);
        viewHolder.binding.getRoot().setTag(user);
        viewHolder
                .binding
                .getRoot()
                .setOnLongClickListener(
                        v -> {
                            selectedUser = user;
                            return false;
                        });
    }

    @Override
    public void onCreateContextMenu(
            ContextMenu menu, View v, ContextMenu.ContextMenuInfo menuInfo) {
        MucDetailsContextMenuHelper.onCreateContextMenu(menu, v);
    }

    public MucOptions.User getSelectedUser() {
        return selectedUser;
    }

    public static final class ViewHolder extends RecyclerView.ViewHolder {

        private final ItemUserPreviewBinding binding;

        private ViewHolder(final ItemUserPreviewBinding binding) {
            super(binding.getRoot());
            this.binding = binding;
        }
    }
}
