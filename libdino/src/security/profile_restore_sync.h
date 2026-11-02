#ifndef DINO_PROFILE_RESTORE_SYNC_H
#define DINO_PROFILE_RESTORE_SYNC_H

#include <glib.h>

G_BEGIN_DECLS

/* Physical local paths, called offline while holding ProfileLock. Errors must
 * keep the pending transaction/rollback available for the next startup. */
void dino_profile_restore_sync_tree(const gchar *path, GError **error);
void dino_profile_restore_sync_file(const gchar *path, GError **error);
/* POSIX namespace durability. Windows reports G_IO_ERROR_NOT_SUPPORTED: callers
 * must not interpret checked deletion as a directory-fsync/power-loss promise. */
void dino_profile_restore_sync_directory(const gchar *path, GError **error);
void dino_profile_restore_sync_parent(const gchar *path, GError **error);
void dino_profile_restore_rename_directory(const gchar *source,
                                         const gchar *destination, GError **error);

G_END_DECLS

#endif
