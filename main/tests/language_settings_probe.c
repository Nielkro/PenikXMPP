/* Native language integration fixture. Compiles the application widget sources.
 * General/audio pages exercise their production lazy content constructors;
 * account/login/password templates are instantiated without a live account.
 * This checks widget text/domain/direction, not network settings operations.
 * Run through run-locale-boundary-tests.py with an isolated profile.
 */
#include <gtk/gtk.h>
#include <adwaita.h>
#include <libintl.h>
#include <locale.h>
extern gpointer dino_search_path_generator_new(const char*);
extern char *dino_search_path_generator_get_locale_path(gpointer,const char*,const char*);
extern void dino_search_path_generator_unref(gpointer);
extern void dino_internationalize(const char*,const char*);
extern void dino_ui_interface_language_apply_direction(const char*);
extern gpointer dino_ui_general_preferences_page_new(void);
extern void dino_ui_general_preferences_page_ensure_content(gpointer);
extern gpointer dino_ui_general_preferences_page_get_model(gpointer);
extern gpointer dino_ui_audio_video_preferences_page_new(void);
extern void dino_ui_audio_video_preferences_page_ensure_content(gpointer);
extern GType dino_ui_account_preferences_subpage_get_type(void);
extern GType dino_ui_change_password_dialog_get_type(void);
extern GType dino_ui_manage_accounts_add_account_dialog_get_type(void);
static GHashTable *texts;
static unsigned checks;
static const char *lang;
static void collect(GtkWidget *w) {
 const char *props[]={"title","subtitle","label","description","placeholder-text","tooltip-text",NULL};
 for(int i=0;props[i];i++){
  GParamSpec *p=g_object_class_find_property(G_OBJECT_GET_CLASS(w),props[i]);
  if(p && G_PARAM_SPEC_VALUE_TYPE(p)==G_TYPE_STRING && (p->flags&G_PARAM_READABLE)) {
   char *s=NULL;g_object_get(w,props[i],&s,NULL);
   if(s && *s)g_hash_table_add(texts,s);else g_free(s);
  }
 }
 if(ADW_IS_COMBO_ROW(w)) {
  GListModel *m=adw_combo_row_get_model(ADW_COMBO_ROW(w));
  for(guint i=0;m&&i<g_list_model_get_n_items(m);i++) {
   GObject *o=g_list_model_get_item(m,i);
   if(GTK_IS_STRING_OBJECT(o))g_hash_table_add(texts,g_strdup(gtk_string_object_get_string(GTK_STRING_OBJECT(o))));
   g_object_unref(o);
  }
 }
 if(ADW_IS_DIALOG(w) && adw_dialog_get_child(ADW_DIALOG(w)))collect(adw_dialog_get_child(ADW_DIALOG(w)));
 for(GtkWidget *c=gtk_widget_get_first_child(w);c;c=gtk_widget_get_next_sibling(c))collect(c);
}
static void verify(GtkWidget *w,const char *area,const char **sources) {
 texts=g_hash_table_new_full(g_str_hash,g_str_equal,g_free,NULL);collect(w);
 for(int i=0;sources[i];i++) {
  const char *want=dgettext("dino",sources[i]);
  if(!g_hash_table_contains(texts,want)) {
   g_printerr("Missing native widget text: %s / %s / %s => %s\n",lang,area,sources[i],want);
   GHashTableIter it;gpointer key;g_hash_table_iter_init(&it,texts);while(g_hash_table_iter_next(&it,&key,NULL))g_printerr("  %s\n",(char*)key);
   exit(2);
  }
  checks++;
 }
 g_hash_table_unref(texts);
}
int dinox_language_settings_probe_run(const char *executable) {
 lang=g_getenv("DINOX_TEST_APP_LANGUAGE");
 if (!lang || !setlocale(LC_ALL,"")) return 77;
 gpointer gen=dino_search_path_generator_new(executable);
 const char *domains[]={"dino","dino-omemo","dino-openpgp",NULL};
 for(int i=0;domains[i];i++) {
  char *p=dino_search_path_generator_get_locale_path(gen,domains[i],"/usr/share/locale");
  dino_internationalize(domains[i],p);g_free(p);
 }
 dino_search_path_generator_unref(gen);textdomain("dino");gtk_init();adw_init();dino_ui_interface_language_apply_direction(lang);
 g_assert_cmpint(gtk_widget_get_default_direction(),==,(g_str_equal(lang,"ar")||g_str_equal(lang,"arz")||g_str_equal(lang,"he")||g_str_equal(lang,"ur"))?GTK_TEXT_DIR_RTL:GTK_TEXT_DIR_LTR);
 GtkWidget *general=dino_ui_general_preferences_page_new();g_object_ref_sink(general);
 g_object_set(dino_ui_general_preferences_page_get_model(general),"language",lang,NULL);
 dino_ui_general_preferences_page_ensure_content(general);
 const char *gkeys[]={"Send _Typing Notifications","Send _Read Receipts","Sync Read State Across _Devices","Uses your account server to sync read positions; contacts cannot see them","Allow Location Sharing","Allow sending your current location in chats","_Notifications","Notify when a new message arrives","Message Notification _Sounds","Play a sound when a new message arrives","_Minimize to System Tray on Close","Keep DinoX running in the system tray when the window is closed","Appearance","_Design","_Color Scheme","Choose whether DinoX follows the system appearance","Accent _Color","Change highlights without changing the base theme","Chat _Font","Chat Text _Size","Change only messages and the message field","_Language","Override the system language for the DinoX interface","_Convert Smileys to Emoji","Stickers","Enable Stickers","Play Sticker Animations","Play animated stickers in the chat. When disabled, show a still image.","Botmother","Enable Botmother","Start the local Botmother API server for managing XMPP bots","API Server Mode","Local: localhost only. Network: all interfaces with TLS (HTTPS)","API Port","Port for the HTTP(S) API server","TLS Certificate (PEM)","TLS Private Key (PEM)","Renew Self-Signed Certificate","Delete current certificate. A new one will be generated on next start.","Delete Certificate","Remove the self-signed certificate and private key","User Data","Backup and restore include all XMPP accounts in this data directory.","Backup User Data","Create a backup of your accounts, messages and settings","Restore from Backup","Restore accounts, messages and settings from a backup file","Data Storage Location","View where your data is stored","Database Maintenance","These operations apply to all XMPP accounts in this data directory.","Change Database Password","Change the password used to encrypt your local data","Clear Cache","Clear cached files, avatars and previews","Reset Database","Delete all messages, files and OMEMO keys. Your accounts will remain.","Factory Reset","Delete ALL data including accounts. This cannot be undone!",NULL};
 verify(general,"General",gkeys);
 GtkWidget *account=g_object_new(dino_ui_account_preferences_subpage_get_type(),NULL);g_object_ref_sink(account);
 const char *akeys[]={"XMPP Address","Local alias","Password","Timezone (XEP-0202)","Send to contacts so they know your local time","Connection status","Enter password","View Certificate","Login protection (MITM)","Changing the selection reconnects this account and checks the result immediately.","Server support","Extra login protection (MITM)","Check availability","Reconnects only this account.","Check now","Allow sign-in without extra protection","Removes the saved requirement for this account and reconnects. TLS encryption remains required.","Allow","Current connection","Login protection will be checked when this account connects.","Connection security","DNSSEC and DANE authenticate this account's server connection. They do not change OMEMO or OpenPGP message encryption.","DNSSEC and DANE","How this mode works","HTTPS DNS resolver URL","Verification status","Apply to this account","Saves both settings and reconnects this account if enabled. Leave the resolver empty to use system DNS directly; Tor and SOCKS5 require an HTTPS resolver through the proxy.","Apply","Server Certificate","TLS certificate used by the XMPP server","Status","Issued by","Valid","SHA-256 Fingerprint","Remove Pinned Certificate","Public Profile","Personal details are included in the legacy profile only when public access is enabled. Your profile picture keeps its existing visibility.","Public Access","Allow anyone to see your profile","Share with Contacts","Allow contacts to see your profile","Full Name","Nickname","Gender","Birthday","Address","Street","Postal Code","City","Region","Country","Email","IM Address","Phone Number","Organization","Job Title","Role","Timezone","Website","Description","Save Profile","Advanced Settings","Custom server connection (leave empty for automatic)","Server Hostname","Port","Allow password login (PLAIN)","Only for servers without SCRAM. Sends your password inside the TLS connection. Disabled by default.","SOCKS5 Proxy","Enable SOCKS5 Proxy","Proxy Hostname","Proxy Port","Proxy Username (optional)","Proxy Password (optional)","Proxy Status","Not configured","Botmother","Manage Botmothers","Create, configure and delete Botmothers for this account","MQTT Bot (Account)","Manage Account MQTT Bot","Topics, Publish Presets, Alerts and Bridges for this account's MQTT connection (separate from Standalone MQTT)","Disable account","Remove account",NULL};
 verify(account,"Account",akeys);
 GtkWidget *password=g_object_new(dino_ui_change_password_dialog_get_type(),NULL);g_object_ref_sink(password);
 const char *pkeys[]={"Change password","Cancel","Change","Current password","New password","Confirm password",NULL};
 verify(password,"Password",pkeys);
 GtkWidget *add=g_object_new(dino_ui_manage_accounts_add_account_dialog_get_type(),NULL);g_object_ref_sink(add);
 const char *nkeys[]={"XMPP Address","Advanced Settings","Optional: Custom server or per-account SOCKS5 proxy","Server Hostname","Port","Allow password login (PLAIN)","Only for servers without SCRAM. Sends your password inside the TLS connection. Disabled by default.","Enable SOCKS5 Proxy","Also use this for an I2P router's SOCKS5 endpoint","SOCKS5 Proxy / I2P Router Address","SOCKS5 Proxy / I2P Router Port","Proxy Username (optional)","Proxy Password (optional)","Password","Login","Create account","Could not establish a secure connection","Back","Trust This Certificate","Choose a public server","Update provider list","Or specify a server address","Sign in instead","Next","Register","All set up!","Finish",NULL};
 verify(add,"Add account",nkeys);
 GtkWidget *av=dino_ui_audio_video_preferences_page_new();g_object_ref_sink(av);dino_ui_audio_video_preferences_page_ensure_content(av);
 const char *vkeys[]={"Audio/Video Calls","Devices used for real-time calls","Microphone","Audio input for calls","Speaker","Audio output for calls","Camera","Video input for calls","Call network mode","Changes apply to new calls","Voice/Video Messages","Devices used for recording and playing messages","Recording Microphone","Audio input for voice and video messages","Playback Speaker","Audio output for playing voice and video messages","Recording Camera","Video input for video messages","Call Device Tests","Uses the devices selected under Audio/Video Calls","Test Call Microphone","Record and play back a short clip with the selected call microphone","Test Call Speaker","Play a short tone on the selected call speaker","Test Call Camera","Show a short live preview from the selected call camera","Message Device Tests","Uses the devices selected under Voice/Video Messages","Test Recording Microphone","Record and play back a short clip with the selected message microphone","Test Recording Camera","Show a short live preview from the selected message camera","Device Management","Refresh Devices","Reload Google WebRTC audio and video devices",NULL};
 verify(av,"Audio/Video",vkeys);

 g_print("# Dispose Audio/Video\n");g_object_unref(av);
 g_print("# Dispose Login\n");g_object_unref(add);
 g_print("# Dispose Password\n");g_object_unref(password);
 g_print("# Dispose Account\n");g_object_unref(account);
 g_print("# Dispose General\n");g_object_unref(general);
 g_print("TAP version 13\n1..1\nok 1 /LanguageSettings/native_settings_templates # language=%s checked_texts=%u\n",lang,checks);
 return 0;
}
