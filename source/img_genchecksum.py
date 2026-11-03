# Small script to generate and write an FIF image header checksum into an FIF image.

import zlib

with open("artefacts/img.bin", "r+b") as file:
    file.seek(256) # header start
    data = file.read(256)
    checksum = zlib.crc32(data) & 0xffffffff # CRC-32 ISO-HDLC checksum of image header.
    file.seek(12) # checksum start
    file.write(checksum.to_bytes(4, byteorder="little"))
