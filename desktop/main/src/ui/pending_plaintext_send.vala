/*
 * Copyright (C) 2025 Ralf Peter <dinox@handwerker.jetzt>
 *
 * This program is free software: you can redistribute it and/or modify
 * it under the terms of the GNU General Public License as published by
 * the Free Software Foundation, either version 3 of the License, or
 * (at your option) any later version.
 */

namespace Dino.Ui {

internal class PendingPlaintextSend : Object {
    public File file { get; private set; }

    private PlaintextFileLeaseTarget? target;
    private bool send_started = false;

    public PendingPlaintextSend(PlaintextFileLeaseTarget target) {
        this.target = target;
        this.file = target.file;
    }

    ~PendingPlaintextSend() {
        release();
    }

    public bool begin_send() {
        if (target == null || send_started) return false;
        send_started = true;
        return true;
    }

    public void overlay_closed() {
        if (!send_started) release();
    }

    public void send_finished() {
        release();
    }

    private void release() {
        if (target == null) return;
        ((!) target).discard();
        target = null;
    }
}

}
