#!/usr/bin/env python3
"""Check a Tricky Store keybox.xml against Google's attestation revocation list.

usage: keybox_check.py <keybox.xml>
exit 0 = no revoked certs, 1 = at least one revoked, 2 = no certificates / error
"""
import json
import re
import subprocess
import sys
import urllib.request

STATUS_URL = "https://android.googleapis.com/attestation/status"


def main(path):
    xml = open(path, encoding="utf-8", errors="ignore").read()
    certs = re.findall(r"-----BEGIN CERTIFICATE-----.*?-----END CERTIFICATE-----", xml, re.S)
    if not certs:
        print("no PEM certificates found in keybox")
        return 2
    with urllib.request.urlopen(STATUS_URL, timeout=30) as r:
        revoked = {k.lower().lstrip("0") for k in json.load(r)["entries"]}
    bad = 0
    for pem in certs:
        pem = "\n".join(line.strip() for line in pem.splitlines())
        out = subprocess.run(["openssl", "x509", "-noout", "-serial", "-subject"],
                             input=pem, capture_output=True, text=True).stdout
        serial = re.search(r"serial=(\w+)", out).group(1)
        subject = re.search(r"subject=(.*)", out).group(1).strip()
        is_bad = serial.lower().lstrip("0") in revoked
        bad += is_bad
        print(f"  {'REVOKED' if is_bad else 'ok     '} {serial}  {subject}")
    print(f"{len(certs)} certs, {bad} revoked")
    return 1 if bad else 0


if __name__ == "__main__":
    sys.exit(main(sys.argv[1]))
