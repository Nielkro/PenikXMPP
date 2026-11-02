// Exercise the opt-in GIO binding through GLib's ordinary base-class API.
// These are native ABI tests: no user profile, network or encryption state.
private class NativeBindingInput : DinoNative.InputStream {
    public override ssize_t read([CCode (type = "void*")] uint8[] buffer,
            Cancellable? cancellable = null) throws IOError {
        if (cancellable != null) cancellable.set_error_if_cancelled();
        if (buffer.length == 0) return 0;
        ((uint8*) buffer)[0] = 0xa5;
        return 1;
    }

    public override async ssize_t read_async([CCode (type = "void*")] uint8[]? buffer,
            int priority = Priority.DEFAULT, Cancellable? cancellable = null) throws IOError {
        Idle.add(() => { read_async.callback(); return Source.REMOVE; });
        yield;
        if (cancellable != null) cancellable.set_error_if_cancelled();
        if (buffer == null || buffer.length == 0) return 0;
        ((uint8*) buffer)[0] = 0xa5;
        return 1;
    }

    public override bool close(Cancellable? cancellable = null) throws IOError { return true; }
}

private class NativeBindingOutput : DinoNative.OutputStream {
    public uint8 received;

    public override ssize_t write([CCode (type = "const void*")] uint8[] buffer,
            Cancellable? cancellable = null) throws IOError {
        if (cancellable != null) cancellable.set_error_if_cancelled();
        if (buffer.length == 0) return 0;
        received = ((uint8*) buffer)[0];
        return 1;
    }

    public override async ssize_t write_async([CCode (type = "const void*")] uint8[]? buffer,
            int priority = Priority.DEFAULT, Cancellable? cancellable = null) throws IOError {
        Idle.add(() => { write_async.callback(); return Source.REMOVE; });
        yield;
        if (cancellable != null) cancellable.set_error_if_cancelled();
        if (buffer == null || buffer.length == 0) return 0;
        received = ((uint8*) buffer)[0];
        return 1;
    }

    public override bool close(Cancellable? cancellable = null) throws IOError { return true; }
}

private async void exercise_streams() throws Error {
    var typed_input = new NativeBindingInput();
    var typed_output = new NativeBindingOutput();
    // No extra runtime type may appear between the subclass and GIO.
    assert(typed_input.get_type().parent() == typeof(GLib.InputStream));
    assert(typed_output.get_type().parent() == typeof(GLib.OutputStream));
    GLib.InputStream input = typed_input;
    GLib.OutputStream output = typed_output;
    uint8[] bytes = new uint8[3];
    assert(input.read(bytes) == 1 && bytes[0] == 0xa5);
    assert(bytes[1] == 0 && bytes[2] == 0);
    assert(output.write(bytes) == 1 && typed_output.received == 0xa5);
    bytes[0] = 0;
    assert((yield input.read_async(bytes)) == 1 && bytes[0] == 0xa5);
    bytes[0] = 0x71;
    assert((yield output.write_async(bytes)) == 1 && typed_output.received == 0x71);
    // GIO still requires a non-null buffer when count is zero.
    assert(input.read(bytes[0:0]) == 0);
    assert(output.write(bytes[0:0]) == 0);
    var cancellable = new Cancellable();
    cancellable.cancel();
    try { yield input.read_async(bytes, Priority.DEFAULT, cancellable); assert_not_reached(); }
    catch (IOError.CANCELLED e) {}
    try { yield output.write_async(bytes, Priority.DEFAULT, cancellable); assert_not_reached(); }
    catch (IOError.CANCELLED e) {}
    assert(input.close());
    assert(output.close());
    try { input.read(bytes); assert_not_reached(); }
    catch (IOError.CLOSED e) {}
}

int main(string[] args) {
    Test.init(ref args);
    Test.add_func("/NativeStreamBindings/base_dispatch_buffers_async_errors", () => {
        var loop = new MainLoop();
        exercise_streams.begin((obj, result) => {
            try { exercise_streams.end(result); }
            catch (Error e) { error("Native stream ABI: %s", e.message); }
            loop.quit();
        });
        loop.run();
    });
    return Test.run();
}
