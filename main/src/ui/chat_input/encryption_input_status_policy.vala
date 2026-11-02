namespace Dino.Ui {

internal bool encryption_status_requires_context_restore(
        Plugins.InputFieldStatus status) {
    return status.message_type == Plugins.InputFieldStatus.MessageType.NONE &&
        status.input_state == Plugins.InputFieldStatus.InputState.NORMAL &&
        (status.message == null || ((!) status.message) == "");
}

internal Plugins.InputFieldStatus effective_context_input_status(
        Plugins.InputFieldStatus context_status,
        Plugins.InputFieldStatus? encryption_status) {
    // Room membership and moderation are authoritative. An encryption
    // readiness status may block an otherwise writable composer, but it must
    // never hide or weaken an existing visitor/not-joined block.
    if (context_status.input_state !=
            Plugins.InputFieldStatus.InputState.NORMAL) {
        return context_status;
    }
    return encryption_status ?? context_status;
}

internal bool private_room_info_requires_encryption_refresh(
        bool is_private, Entities.Encryption encryption) {
    return is_private && encryption != Entities.Encryption.NONE;
}

internal bool joined_room_requires_encryption_refresh(
        bool has_live_private_room_features,
        Entities.Encryption encryption) {
    return has_live_private_room_features &&
        encryption != Entities.Encryption.NONE;
}

}
