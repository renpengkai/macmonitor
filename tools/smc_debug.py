#!/usr/bin/env python3
"""Low-level AppleSMC debug: dump raw struct traffic."""
import ctypes
import struct
import sys

sys.path.insert(0, "/Volumes/PKSSD/note/macmonitor/tools")
from smc_probe import (  # noqa: E402
    IOKit, SMC, SMC_STRUCT_SIZE, OFF_KEY, OFF_KEYINFO, OFF_RESULT,
    OFF_STATUS, OFF_DATA8, OFF_BYTES, CMD_READ_KEYINFO, CMD_READ_BYTES,
)


def raw_call(conn, selector, buf):
    out = ctypes.create_string_buffer(SMC_STRUCT_SIZE)
    osize = ctypes.c_size_t(SMC_STRUCT_SIZE)
    rc = IOKit.IOConnectCallStructMethod(
        conn, selector, bytes(buf), SMC_STRUCT_SIZE, out, ctypes.byref(osize)
    )
    return rc, out.raw, osize.value


def main():
    smc = SMC(verbose=True)
    print("conn =", hex(smc.conn.value))

    # 1) 直接问 SMC 版本
    for sel in range(0, 16):
        buf = bytearray(SMC_STRUCT_SIZE)
        buf[OFF_DATA8] = sel
        rc, out, osz = raw_call(smc.conn, 2, buf)
        non_zero = sum(1 for b in out if b)
        print("data8=%-3d rc=0x%08x out_size=%-3d nonzero=%d out=%s"
              % (sel, rc, osz, non_zero, out[:24].hex()))

    # 2) keyInfo for F0Ac via data8=9
    buf = bytearray(SMC_STRUCT_SIZE)
    buf[OFF_KEY:OFF_KEY + 4] = b"F0Ac"
    buf[OFF_DATA8] = CMD_READ_KEYINFO
    rc, out, osz = raw_call(smc.conn, 2, buf)
    print("\nkeyInfo F0Ac rc=0x%x size=%d type=%s result=%d status=%d"
          % (rc,
             struct.unpack(">I", out[OFF_KEYINFO:OFF_KEYINFO + 4])[0],
             out[OFF_KEYINFO + 4:OFF_KEYINFO + 8],
             out[OFF_RESULT], out[OFF_STATUS]))
    print("full out:", out.hex())

    # 3) 读 F0Ac 原始值
    buf = bytearray(SMC_STRUCT_SIZE)
    buf[OFF_KEY:OFF_KEY + 4] = b"F0Ac"
    buf[OFF_KEYINFO:OFF_KEYINFO + 4] = struct.pack(">I", 2)
    buf[OFF_DATA8] = CMD_READ_BYTES
    rc, out, osz = raw_call(smc.conn, 2, buf)
    print("\nread F0Ac rc=0x%x bytes=%s result=%d"
          % (rc, out[OFF_BYTES:OFF_BYTES + 8].hex(), out[OFF_RESULT]))


if __name__ == "__main__":
    sys.exit(main())
