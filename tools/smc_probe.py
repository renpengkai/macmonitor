#!/usr/bin/env python3
"""Probe AppleSMC via IOKit from Python (no compiler needed).

Selector is always kSMCHandleYPCEvent(2); the SMC command goes into data8.
Dumps the SMC key inventory (fan / temperature / power families).
"""
import ctypes
import struct
import sys

IOKit = ctypes.CDLL("/System/Library/Frameworks/IOKit.framework/IOKit")
libSystem = ctypes.CDLL("/usr/lib/libSystem.B.dylib")

IOKit.IOServiceMatching.restype = ctypes.c_void_p
IOKit.IOServiceMatching.argtypes = [ctypes.c_char_p]
IOKit.IOServiceGetMatchingService.restype = ctypes.c_uint32
IOKit.IOServiceGetMatchingService.argtypes = [ctypes.c_uint32, ctypes.c_void_p]
IOKit.IOServiceOpen.restype = ctypes.c_int
IOKit.IOServiceOpen.argtypes = [
    ctypes.c_uint32, ctypes.c_uint32, ctypes.c_uint32, ctypes.POINTER(ctypes.c_uint32)
]
IOKit.IOServiceClose.restype = ctypes.c_int
IOKit.IOServiceClose.argtypes = [ctypes.c_uint32]
IOKit.IOConnectCallStructMethod.restype = ctypes.c_int
IOKit.IOConnectCallStructMethod.argtypes = [
    ctypes.c_uint32, ctypes.c_uint32, ctypes.c_void_p, ctypes.c_size_t,
    ctypes.c_void_p, ctypes.POINTER(ctypes.c_size_t),
]

mach_task_self = ctypes.c_uint32.in_dll(libSystem, "mach_task_self_").value

SMC_SELECTOR = 2          # kSMCHandleYPCEvent
CMD_READ_BYTES = 5
CMD_WRITE_BYTES = 6
CMD_KEY_COUNT = 7
CMD_READ_INDEX = 8
CMD_READ_KEYINFO = 9
CMD_READ_VERS = 12

SMC_STRUCT_SIZE = 80
OFF_KEY = 0
OFF_KEYINFO = 28          # dataSize(u32) dataType(u32) dataAttributes(u8)
OFF_RESULT = 40
OFF_STATUS = 41
OFF_DATA8 = 42
OFF_DATA32 = 44
OFF_BYTES = 48

_TYPE_NAMES = {b"flt ": "float", b"ui8 ": "uint8", b"ui16": "uint16",
               b"ui32": "uint32", b"ui64": "uint64", b"sp78": "sp78",
               b"fpe2": "fpe2", b"flag": "flag", b"{fds": "fds",
               b"si16": "si16", b"hex_": "hex"}


class SMC:
    def __init__(self, service_name=b"AppleSMC", verbose=False):
        self.conn = ctypes.c_uint32(0)
        self.service = IOKit.IOServiceGetMatchingService(
            0, IOKit.IOServiceMatching(service_name)
        )
        if not self.service:
            raise RuntimeError("IOService %s not found" % service_name)
        rc = IOKit.IOServiceOpen(self.service, mach_task_self, 0, ctypes.byref(self.conn))
        if rc != 0:
            raise RuntimeError("IOServiceOpen rc=0x%x" % rc)
        if verbose:
            print("service=0x%x conn=0x%x" % (self.service, self.conn.value))

    def _call(self, cmd, buf, key=None, size=0):
        buf[OFF_KEY:OFF_KEY + 4] = struct.pack(">I", key) if key else b"\x00" * 4
        buf[OFF_KEYINFO:OFF_KEYINFO + 4] = struct.pack(">I", size)
        buf[OFF_DATA8] = cmd
        out = ctypes.create_string_buffer(SMC_STRUCT_SIZE)
        out_size = ctypes.c_size_t(SMC_STRUCT_SIZE)
        rc = IOKit.IOConnectCallStructMethod(
            self.conn, SMC_SELECTOR, bytes(buf), SMC_STRUCT_SIZE,
            out, ctypes.byref(out_size),
        )
        if rc != 0:
            raise RuntimeError("IOConnectCallStructMethod cmd=%d rc=0x%x" % (cmd, rc))
        return out.raw

    def _flush(self):
        return bytearray(SMC_STRUCT_SIZE)

    def key_info(self, key):
        raw = self._call(CMD_READ_KEYINFO, self._flush(), key=key, size=0)
        size = struct.unpack(">I", raw[OFF_KEYINFO:OFF_KEYINFO + 4])[0]
        dtype = raw[OFF_KEYINFO + 4:OFF_KEYINFO + 8]
        return raw[OFF_RESULT], size, dtype

    def read(self, key):
        info_rc, size, dtype = self.key_info(key)
        if info_rc != 0 or size == 0 or size > 32:
            return info_rc, dtype, None
        buf = self._flush()
        buf[OFF_KEYINFO:OFF_KEYINFO + 4] = struct.pack(">I", size)
        raw = self._call(CMD_READ_BYTES, buf, key=key, size=size)
        return raw[OFF_RESULT], dtype, raw[OFF_BYTES:OFF_BYTES + size]

    def write(self, key, raw_bytes):
        info_rc, size, dtype = self.key_info(key)
        if info_rc != 0:
            return info_rc
        buf = self._flush()
        buf[OFF_KEYINFO:OFF_KEYINFO + 4] = struct.pack(">I", size)
        buf[OFF_BYTES:OFF_BYTES + len(raw_bytes)] = raw_bytes
        raw = self._call(CMD_WRITE_BYTES, buf, key=key, size=size)
        return raw[OFF_RESULT]

    def key_count(self):
        raw = self._call(CMD_KEY_COUNT, self._flush())
        return struct.unpack(">I", raw[OFF_BYTES:OFF_BYTES + 4])[0]

    def key_at(self, index):
        buf = self._flush()
        buf[OFF_BYTES:OFF_BYTES + 4] = struct.pack(">I", index)
        raw = self._call(CMD_READ_INDEX, buf)
        return raw[OFF_KEY:OFF_KEY + 4]

    def version(self):
        raw = self._call(CMD_READ_VERS, self._flush())
        return raw[OFF_BYTES:OFF_BYTES + 6]


def decode(dtype, data):
    if not data:
        return None
    try:
        if dtype == b"flt " and len(data) >= 4:
            return struct.unpack(">f", data[:4])[0]
        if dtype == b"sp78" and len(data) >= 2:
            return struct.unpack(">h", data[:2])[0] / 256.0
        if dtype == b"fpe2" and len(data) >= 2:
            return struct.unpack(">H", data[:2])[0] / 4.0
        if dtype == b"ui8 ":
            return data[0]
        if dtype == b"ui16":
            return struct.unpack(">H", data[:2])[0]
        if dtype == b"ui32":
            return struct.unpack(">I", data[:4])[0]
        if dtype == b"ui64":
            return struct.unpack(">Q", data[:8])[0]
    except Exception:
        return None
    return None


def main():
    smc = SMC(verbose=True)
    print("SMC version:", smc.version().hex())
    count = smc.key_count()
    print("SMC key count:", count)
    if count == 0:
        print("!! key enumeration unavailable on this interface")
        return 1

    keys = []
    for i in range(count):
        k = smc.key_at(i)
        if not k:
            continue
        keys.append(k.decode("ascii", "replace"))

    print("\n=== F(fan) / T(temp) / P(power) / B(battery) keys ===")
    for name in sorted(keys):
        if name[:1] not in "FTPB":
            continue
        key = struct.unpack(">I", name.encode("latin1")[:4].ljust(4, b"\x00"))[0]
        try:
            rc, dtype, data = smc.read(key)
        except Exception as exc:
            print("  %-5s ERR %s" % (name, exc))
            continue
        val = decode(dtype, data)
        kind = _TYPE_NAMES.get(dtype, dtype.decode("latin1", "replace"))
        print("  %-5s %-6s val=%-16s raw=%-16s rc=%d" %
              (name, kind,
               ("%.3f" % val) if isinstance(val, float) else str(val),
               data.hex() if data else "-", rc))

    print("\n=== all keys ===")
    print(" ".join(sorted(keys)))
    return 0


if __name__ == "__main__":
    sys.exit(main())
