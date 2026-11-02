#include <glib.h>
#include <gcrypt.h>

static gsize dinox_gcrypt_initialized = 0;

void
dinox_gcrypt_initialize_for_dinox(void)
{
    if (g_once_init_enter(&dinox_gcrypt_initialized)) {
        if (gcry_check_version(NULL) == NULL) {
            g_error("libgcrypt version mismatch");
        }

        /*
         * DinoX keeps OpenPGP secret-key handling in GnuPG subprocesses and
         * only uses in-process libgcrypt for random bytes and symmetric
         * content ciphers. Do not initialize libgcrypt secure memory here:
         * doing so conflicts with other users in the same process and can emit
         * "Oops, secure memory pool already initialized".
         */
        gcry_control(GCRYCTL_DISABLE_SECMEM, 0);
        gcry_control(GCRYCTL_DISABLE_SECMEM_WARN, 0);
        gcry_control(GCRYCTL_INITIALIZATION_FINISHED, 0);

        g_once_init_leave(&dinox_gcrypt_initialized, 1);
    }
}

void
dinox_gcrypt_disable_secure_memory_warning(void)
{
    dinox_gcrypt_initialize_for_dinox();
}
