/*
 * Copyright (C) 2026 Ralf Peter <dinox@handwerker.jetzt>
 *
 * This program is free software: you can redistribute it and/or modify
 * it under the terms of the GNU General Public License as published by
 * the Free Software Foundation, either version 3 of the License, or
 * (at your option) any later version.
 */

namespace Dino.Ui.Util {

public static void load_json_response (Json.Parser parser, Bytes response) throws Error {
    size_t response_size = response.get_size ();
    uint8[] response_data = response.get_data ();
    uint8[] nul_terminated = new uint8[response_size + 1];
    GLib.Memory.copy (nul_terminated, response_data, response_size);
    nul_terminated[response_size] = 0;
    parser.load_from_data ((string) nul_terminated, (ssize_t) response_size);
}

}
