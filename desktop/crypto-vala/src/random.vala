namespace Crypto {
[CCode (cname = "dinox_gcrypt_initialize_for_dinox")]
private extern void initialize_gcrypt_for_dinox();

public static void initialize() {
    initialize_gcrypt_for_dinox();
}

public static void disable_secure_memory_warnings() {
    initialize();
}

public static void randomize(uint8[] buffer) {
    initialize();
    GCrypt.Random.randomize(buffer);
}
}
