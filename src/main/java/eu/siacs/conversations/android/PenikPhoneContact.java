package eu.siacs.conversations.android;

import android.database.Cursor;
import android.provider.ContactsContract;

public class PenikPhoneContact extends AbstractPhoneContact {

    private final String phoneNumber;

    public PenikPhoneContact(Cursor cursor) {
        super(cursor);
        int numberIndex = cursor.getColumnIndex(ContactsContract.CommonDataKinds.Phone.NUMBER);
        this.phoneNumber = numberIndex >= 0 ? cursor.getString(numberIndex) : "";
    }

    public String getPhoneNumber() {
        return phoneNumber;
    }
}
