#ifndef DINO_PROFILE_LOCK_H
#define DINO_PROFILE_LOCK_H

#include <glib.h>

G_BEGIN_DECLS

/* Returns the physical profile directory. Only its parent may be created.
 * The acquired OS lock is owned by the process and is never explicitly released
 * or unlinked: database workers may outlive the application/window objects. */
gchar *dino_profile_lock_acquire_native(const gchar *storage_dir, GError **error);

G_END_DECLS

#endif
