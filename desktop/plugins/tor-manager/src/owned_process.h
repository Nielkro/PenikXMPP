/* SPDX-License-Identifier: GPL-3.0-or-later */
#pragma once

#include <gio/gio.h>

G_BEGIN_DECLS

#define DINO_TYPE_TOR_OWNED_PROCESS (dino_tor_owned_process_get_type())
G_DECLARE_FINAL_TYPE(DinoTorOwnedProcess, dino_tor_owned_process, DINO, TOR_OWNED_PROCESS, GObject)

DinoTorOwnedProcess *dino_tor_owned_process_spawn(const gchar *const *argv,
                                                const gchar *cwd,
                                                GError **error);
GInputStream *dino_tor_owned_process_get_stdout_pipe(DinoTorOwnedProcess *self);
GInputStream *dino_tor_owned_process_get_stderr_pipe(DinoTorOwnedProcess *self);
const gchar *dino_tor_owned_process_get_identifier(DinoTorOwnedProcess *self);
gint dino_tor_owned_process_get_exit_status(DinoTorOwnedProcess *self);
gboolean dino_tor_owned_process_is_tree_drained(DinoTorOwnedProcess *self);
void dino_tor_owned_process_request_stop(DinoTorOwnedProcess *self);

void dino_tor_owned_process_wait_async(DinoTorOwnedProcess *self,
                                     GCancellable *cancellable,
                                     GAsyncReadyCallback callback,
                                     gpointer user_data);
gboolean dino_tor_owned_process_wait_finish(DinoTorOwnedProcess *self,
                                          GAsyncResult *result,
                                          GError **error);
void dino_tor_owned_process_stop_and_wait_async(DinoTorOwnedProcess *self,
                                              GCancellable *cancellable,
                                              GAsyncReadyCallback callback,
                                              gpointer user_data);
gboolean dino_tor_owned_process_stop_and_wait_finish(DinoTorOwnedProcess *self,
                                                   GAsyncResult *result,
                                                   GError **error);

G_END_DECLS
