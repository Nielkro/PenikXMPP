package eu.siacs.conversations.entities;

import android.content.ContentValues;

public abstract class AbstractEntity {

	public static final String UUID = "uuid";

	protected String uuid;

	public String getUuid() {
		if (this.uuid == null) {
			this.uuid = eu.siacs.conversations.utils.Random.shortId();
		}
		return this.uuid;
	}

	public abstract ContentValues getContentValues();

	public boolean equals(AbstractEntity entity) {
		return this.getUuid().equals(entity.getUuid());
	}
}
