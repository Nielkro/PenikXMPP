package eu.siacs.conversations.ui.fragment.settings;

import android.os.Bundle;
import androidx.annotation.Nullable;
import androidx.preference.ListPreference;
import eu.siacs.conversations.AppSettings;
import eu.siacs.conversations.R;
import eu.siacs.conversations.utils.UIHelper;

public class AttachmentsSettingsFragment extends XmppPreferenceFragment {

    @Override
    public void onCreatePreferences(@Nullable Bundle savedInstanceState, @Nullable String rootKey) {
        setPreferencesFromResource(R.xml.preferences_attachments, rootKey);
        final ListPreference autoAcceptFileSize = findPreference(AppSettings.AUTO_ACCEPT_FILE_SIZE);
        if (autoAcceptFileSize == null) {
            throw new IllegalStateException("The preference resource file is missing preferences");
        }
        setValues(
                autoAcceptFileSize,
                R.array.file_size_values,
                value -> {
                    if (value <= 0) {
                        return getString(R.string.never);
                    } else if (value <= 2097152) {
                        return getString(R.string.file_size_small);
                    } else if (value <= 10485760) {
                        return getString(R.string.file_size_medium);
                    } else {
                        return getString(R.string.file_size_large);
                    }
                });
    }

    @Override
    public void onStart() {
        super.onStart();
        requireActivity().setTitle(R.string.pref_attachments);
    }
}
