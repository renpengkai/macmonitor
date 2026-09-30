#!/usr/bin/env python3
"""Determine Apple Silicon SMC key byte-order + enumerate the key table."""
import ctypes
import struct
import sys

sys.path.insert(0, "/Volumes/PKSSD/note/macmonitor/tools")
from smc_probe import (  # noqa: E402
    IOKit, SMC, SMC_STRUCT_SIZE, OFF_KEY, OFF_KEYINFO, OFF_RESULT,
    OFF_STATUS, OFF_DATA8, OFF_DATA32, OFF_BYTES, CMD_READ_KEYINFO,
)


def call(smc, cmd, key_bytes=None, index=None, size=0):
    buf = bytearray(SMC_STRUCT_SIZE)
    if key_bytes:
        buf[OFF_KEY:OFF_KEY + 4] = key_bytes
    if index is not None:
        buf[OFF_BYTES:OFF_BYTES + 4] = struct.pack(">I", index)
    if size:
        buf[OFF_KEYINFO:OFF_KEYINFO + 4] = struct.pack(">I", size)
    buf[OFF_DATA8] = cmd
    out = ctypes.create_string_buffer(SMC_STRUCT_SIZE)
    osize = ctypes.c_size_t(SMC_STRUCT_SIZE)
    rc = IOKit.IOConnectCallStructMethod(
        smc.conn, 2, bytes(buf), SMC_STRUCT_SIZE, out, ctypes.byref(osize)
    )
    return rc, out.raw


def main():
    smc = SMC()

    # --- key count: dump full struct to locate the value ---
    rc, out = call(smc, 7)
    print("keyCount rc=0x%x" % rc)
    print("  hex:", out.hex())
    for off in (40, 41, 42, 44, 48):
        chunk = out[off:off + 4]
        print("   off %-2d u32be=%d bytes=%s" %
              (off, struct.unpack(">I", chunk)[0], chunk.hex()))

    # --- enumerate first 24 keys, print raw + reversed ---
    print("\nindex -> raw / reversed")
    for i in range(24):
        rc, out = call(smc, 8, index=i)
        k = out[OFF_KEY:OFF_KEY + 4]
        print("  %3d  %-10s  rev=%-10s rc=0x%x" %
              (i, k.decode("latin1", "replace"),
               k[::-1].decode("latin1", "replace"), rc))

    # --- try keyInfo in both byte orders ---
    print("\nkeyInfo probes (result 0 = found):")
    for name in ("F0Ac", "F0Mn", "F0Mx", "F0Tg", "F0ID", "#KEY", "TC0P", "PSTR"):
        raw = name.encode()
        for label, kb in (("as-is", raw), ("reversed", raw[::-1])):
            rc, out = call(smc, CMD_READ_KEYINFO, key_bytes=kb)
            size = struct.unpack(">I", out[OFF_KEYINFO:OFF_KEYINFO + 4])[0]
            dtype = out[OFF_KEYINFO + 4:OFF_KEYINFO + 8]
            print("  %-5s %-9s rc=0x%08x result=%-3d size=%-3d type=%s" %
                  (name, label, rc & 0xffffffff, out[OFF_RESULT], size, dtype))


if __name__ == "__main__":
    sys.exit(main())
