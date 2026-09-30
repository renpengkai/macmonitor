#!/usr/bin/env python3
"""Apple Silicon SMC reader — empirical byte-order implementation + value reads."""
import ctypes
import struct
import sys

sys.path.insert(0, "/Volumes/PKSSD/note/macmonitor/tools")
from smc_probe import IOKit, SMC, SMC_STRUCT_SIZE, OFF_BYTES, OFF_RESULT  # noqa: E402

OFF_KEY = 0
OFF_KEYINFO = 28
OFF_STATUS = 41
OFF_DATA8 = 42
OFF_DATA32 = 44

CMD_READ_BYTES = 5
CMD_KEY_COUNT = 7
CMD_READ_INDEX = 8
CMD_READ_KEYINFO = 9


class ASmc:
    def __init__(self):
        self.smc = SMC()

    def _call(self, cmd, key=None, size=0, index=None, index_le=True):
        buf = bytearray(SMC_STRUCT_SIZE)
        if key:
            buf[OFF_KEY:OFF_KEY + 4] = key.encode("ascii")[::-1]     # reversed chars
        if size:
            buf[OFF_KEYINFO:OFF_KEYINFO + 4] = struct.pack("<I", size)  # native LE
        if index is not None:
            fmt = "<I" if index_le else ">I"
            buf[OFF_DATA32:OFF_DATA32 + 4] = struct.pack(fmt, index)
        buf[OFF_DATA8] = cmd
        out = ctypes.create_string_buffer(SMC_STRUCT_SIZE)
        osize = ctypes.c_size_t(SMC_STRUCT_SIZE)
        rc = IOKit.IOConnectCallStructMethod(
            self.smc.conn, 2, bytes(buf), SMC_STRUCT_SIZE, out, ctypes.byref(osize)
        )
        return rc, out.raw

    def key_info(self, key):
        rc, out = self._call(CMD_READ_KEYINFO, key=key)
        size = struct.unpack("<I", out[OFF_KEYINFO:OFF_KEYINFO + 4])[0]
        dtype = out[OFF_KEYINFO + 4:OFF_KEYINFO + 8][::-1].decode("latin1", "replace")
        return out[OFF_RESULT], size, dtype

    def read(self, key):
        result, size, dtype = self.key_info(key)
        if result != 0:
            return None, dtype, result
        rc, out = self._call(CMD_READ_BYTES, key=key, size=size)
        return out[OFF_BYTES:OFF_BYTES + size], dtype, out[OFF_RESULT]

    def value(self, key):
        data, dtype, rc = self.read(key)
        if not data:
            return None, dtype, rc
        try:
            if dtype == "flt " and len(data) >= 4:
                return struct.unpack("<f", data[:4])[0], dtype, rc   # native LE float
            if dtype == "sp78" and len(data) >= 2:
                return struct.unpack(">h", data[:2])[0] / 256.0, dtype, rc
            if dtype == "fpe2" and len(data) >= 2:
                return struct.unpack(">H", data[:2])[0] / 4.0, dtype, rc
            if dtype == "ui8 ":
                return data[0], dtype, rc
            if dtype == "ui16":
                return struct.unpack("<H", data[:2])[0], dtype, rc
            if dtype == "ui32":
                return struct.unpack("<I", data[:4])[0], dtype, rc
            if dtype == "flag":
                return data[0], dtype, rc
        except Exception as exc:
            return "ERR:%s" % exc, dtype, rc
        return data.hex(), dtype, rc

    def keys(self, limit=2000, index_le=True):
        names = []
        for i in range(limit):
            rc, out = self._call(CMD_READ_INDEX, index=i, index_le=index_le)
            raw = out[OFF_KEY:OFF_KEY + 4][::-1]
            name = raw.decode("latin1", "replace")
            if raw == b"\x00\x00\x00\x00" or name == "#KEY":
                break
            names.append(name)
        return names


def main():
    s = ASmc()

    print("=== read-index 索引方式对比 ===")
    for le in (True, False):
        rc, out = s._call(CMD_READ_INDEX, index=1234, index_le=le)
        print("  LE=%-5s -> key=%s" % (le, out[OFF_KEY:OFF_KEY + 4][::-1]))

    print("\n=== 已知键读取 ===")
    for key in ("F0Ac", "F0Mn", "F0Mx", "F0Tg", "F0Md", "F0ID", "FS! ",
                "PSTR", "PDTR", "TC0P", "Te05", "#KEY"):
        result, size, dtype = s.key_info(key)
        val, dtype, rc = s.value(key)
        print("  %-5s found=%-3s size=%-3d type=%-5s val=%s" %
              (key, result == 0, size, dtype, val))


if __name__ == "__main__":
    sys.exit(main())
