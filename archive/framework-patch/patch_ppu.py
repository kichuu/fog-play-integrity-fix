#!/usr/bin/env python3
"""Neutralise the ROM's PixelPropsUtils inside framework.jar.

Replaces the first instruction of PixelPropsUtils.setProps(String) and
PixelPropsUtils.onEngineGetCertificateChain() with `return-void`, in place
(same size), then fixes the dex checksum/signature and the zip CRC32.

usage: patch_ppu.py <in framework.jar> <out framework.jar>
"""
import hashlib, shutil, struct, sys, zipfile, zlib

CLASS = "Lcom/android/internal/util/custom/PixelPropsUtils;"
TARGETS = {"setProps", "onEngineGetCertificateChain"}
RETURN_VOID = b"\x0e\x00\x00\x00"   # return-void + nop: covers the whole 2-unit original insn (21c/21t)


def uleb(buf, off):
    res = shift = 0
    while True:
        b = buf[off]; off += 1
        res |= (b & 0x7F) << shift
        if b < 0x80:
            return res, off
        shift += 7


def dex_string(d, idx, str_ids_off):
    off = struct.unpack_from("<I", d, str_ids_off + 4 * idx)[0]
    _, off = uleb(d, off)
    return d[off:d.index(b"\0", off)].decode("utf-8", "replace")


def find_methods(d):
    (str_sz, str_off, type_sz, type_off, proto_sz, proto_off, field_sz, field_off,
     meth_sz, meth_off, cls_sz, cls_off) = struct.unpack_from("<12I", d, 0x38)
    type_name = lambda t: dex_string(d, struct.unpack_from("<I", d, type_off + 4 * t)[0], str_off)
    found = {}
    for c in range(cls_sz):
        base = cls_off + 32 * c
        if type_name(struct.unpack_from("<I", d, base)[0]) != CLASS:
            continue
        data_off = struct.unpack_from("<I", d, base + 24)[0]
        p = data_off
        sf, p = uleb(d, p); inf, p = uleb(d, p); dm, p = uleb(d, p); vm, p = uleb(d, p)
        for _ in range(sf + inf):
            _, p = uleb(d, p); _, p = uleb(d, p)
        for count in (dm, vm):          # direct then virtual; index diff restarts per list
            midx = 0
            for _i in range(count):
                diff, p = uleb(d, p); _flags, p = uleb(d, p); code_off, p = uleb(d, p)
                midx += diff
                name_idx = struct.unpack_from("<I", d, meth_off + 8 * midx + 4)[0]
                name = dex_string(d, name_idx, str_off)
                if name in TARGETS:
                    found[name] = code_off
        return found
    return found


def main(src, dst):
    shutil.copyfile(src, dst)
    z = zipfile.ZipFile(src)
    with open(dst, "r+b") as f:
        for info in z.infolist():
            if not info.filename.endswith(".dex"):
                continue
            assert info.compress_type == zipfile.ZIP_STORED
            f.seek(info.header_offset)
            lh = f.read(30)
            fnlen, exlen = struct.unpack_from("<HH", lh, 26)
            data_off = info.header_offset + 30 + fnlen + exlen
            f.seek(data_off)
            d = bytearray(f.read(info.file_size))
            found = find_methods(d)
            if not found:
                continue
            assert set(found) == TARGETS, found
            for name, code_off in found.items():
                insns = code_off + 16          # code_item header is 16 bytes
                print(f"{info.filename}: {name} code@0x{code_off:x} first insn {bytes(d[insns:insns+4]).hex()} -> 0e000000")
                d[insns:insns + 4] = RETURN_VOID
            d[12:32] = hashlib.sha1(d[32:]).digest()
            d[8:12] = struct.pack("<I", zlib.adler32(bytes(d[12:])) & 0xFFFFFFFF)
            crc = zlib.crc32(bytes(d)) & 0xFFFFFFFF
            f.seek(data_off); f.write(d)
            f.seek(info.header_offset + 14); f.write(struct.pack("<I", crc))
            # central directory entry: locate by scanning for its signature + name
            f.seek(0); blob = f.read()
            name_b = info.filename.encode()
            pos = blob.find(b"PK\x01\x02")
            while pos != -1:
                n, = struct.unpack_from("<H", blob, pos + 28)
                if blob[pos + 46:pos + 46 + n] == name_b:
                    f.seek(pos + 16); f.write(struct.pack("<I", crc))
                    break
                pos = blob.find(b"PK\x01\x02", pos + 4)
            else:
                sys.exit("central directory entry not found")
            print(f"patched {info.filename}, new crc {crc:08x}")
            return
    sys.exit("PixelPropsUtils not found")


if __name__ == "__main__":
    main(sys.argv[1], sys.argv[2])
