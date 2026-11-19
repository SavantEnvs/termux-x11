#!/usr/bin/env python3
"""Write the x11-client-clipboard seeds: X11 client byte streams (LSB first, no auth).

Atom and window ids are the ones this server assigns deterministically at start-up
(root window 0x42; CLIPBOARD=72, TARGETS=73, UTF8_STRING=74; STRING=31 is predefined).
Usage: mkseeds.py <outdir>
"""
import os, struct, sys

ROOT, STRING, CLIPBOARD, TARGETS, UTF8 = 0x42, 31, 72, 73, 74

def setup():
    return struct.pack('<BxHHHHxx', ord('l'), 11, 0, 0, 0)

def pad(b):
    return b + b'\0' * ((4 - len(b) % 4) % 4)

def change_property(win, prop, typ, data, fmt=8, mode=0):
    d = pad(data)
    return struct.pack('<BBHIIIBxxxI', 18, mode, 6 + len(d) // 4, win, prop, typ, fmt, len(data)) + d

def send_selection_notify(dest, requestor, selection, target, prop, time=0):
    ev = struct.pack('<BxHIIIII8x', 31, 0, time, requestor, selection, target, prop)
    return struct.pack('<BBHII', 25, 0, 11, dest, 0) + ev

def convert_selection(requestor, selection, target, prop, time=0):
    return struct.pack('<BxHIIIII', 24, 6, requestor, selection, target, prop, time)

def intern_atom(name, only_if_exists=0):
    return struct.pack('<BBHHxx', 16, only_if_exists, 2 + len(pad(name)) // 4, len(name)) + pad(name)

def get_input_focus():
    return struct.pack('<BxH', 43, 1)

SEEDS = {
    'string_clipboard': setup() + change_property(ROOT, STRING, STRING, b'hello\r\nworld\xe9')
        + send_selection_notify(ROOT, ROOT, CLIPBOARD, STRING, STRING) + get_input_focus(),
    'utf8_clipboard': setup() + change_property(ROOT, UTF8, UTF8, b'caf\xc3\xa9\r\nx\ry')
        + send_selection_notify(ROOT, ROOT, CLIPBOARD, UTF8, UTF8) + get_input_focus(),
    'utf8_truncated': setup() + change_property(ROOT, UTF8, UTF8, b'ab\xe2\x82')
        + send_selection_notify(ROOT, ROOT, CLIPBOARD, UTF8, UTF8) + get_input_focus(),
    'targets_then_convert': setup() + change_property(ROOT, TARGETS, 4, struct.pack('<II', UTF8, STRING), fmt=32)
        + send_selection_notify(ROOT, ROOT, CLIPBOARD, TARGETS, TARGETS)
        + convert_selection(ROOT, CLIPBOARD, UTF8, UTF8) + get_input_focus(),
    'intern_atoms': setup() + intern_atom(b'CLIPBOARD') + intern_atom(b'UTF8_STRING', 1)
        + intern_atom(b'MAYHEM_NEW_ATOM') + get_input_focus(),
}

if __name__ == '__main__':
    out = sys.argv[1]
    os.makedirs(out, exist_ok=True)
    for name, data in SEEDS.items():
        with open(os.path.join(out, name), 'wb') as f:
            f.write(data)
