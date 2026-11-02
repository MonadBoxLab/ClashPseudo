"""为交付工具测试准备完整的五项固定资源，不使用网络或源码 payload。"""

import gzip
import hashlib
from pathlib import Path

from test_dependency_resources import mmdb, pb

ROOT = Path(__file__).resolve().parents[2]


def frozen_resources(root, update, *, source_metadata=None):
    for name in update.RESOURCE_INPUTS:
        if name == update.RESOURCE_RECORD:
            continue
        path = root / name
        path.parent.mkdir(parents=True, exist_ok=True)
        if not path.exists():
            path.write_bytes(("合成许可正文 " + path.name + "\n").encode())
    installed = {
        "ca": (ROOT / "android/app/src/test/resources/certificates/synthetic-ec-acc-positive.pem").read_bytes(),
        "geoip": pb(1, pb(1, b"TEST") + pb(2, pb(1, b"\x7f\0\0\0") + b"\x10\x08")),
        "geosite": pb(1, pb(1, b"TEST") + pb(2, pb(2, b"example.test"))),
        "mmdb": mmdb("mmdb"), "asn": mmdb("asn"),
    }
    payloads = {kind: gzip.compress(data, mtime=0) if kind in ("mmdb", "asn") else data
                for kind, data in installed.items()}
    specs = {}
    sources = {row["kind"]: row for row in (source_metadata or {}).get("sources", [])}
    urls = {
        "ca": "https://curl.se/ca/cacert-2026-10-20.pem",
        "geoip": "https://github.com/v2fly/geoip/releases/download/202610050438/geoip.dat",
        "geosite": "https://github.com/v2fly/domain-list-community/releases/download/20261030132534/dlc.dat",
        "mmdb": "https://download.db-ip.com/free/dbip-country-lite-2026-10.mmdb.gz",
        "asn": "https://download.db-ip.com/free/dbip-asn-lite-2026-10.mmdb.gz",
    }
    for kind, payload in payloads.items():
        version = "2026-10-20" if kind == "ca" else "202610050438" if kind == "geoip" else "20261030132534" if kind == "geosite" else "2026-10"
        row = {"kind": kind, "version": version, "sourceUrl": urls[kind],
               "storedBytes": len(payload), "storedSha256": hashlib.sha256(payload).hexdigest(),
               "installedBytes": len(installed[kind]), "installedSha256": hashlib.sha256(installed[kind]).hexdigest()}
        if kind == "ca":
            row["certificateRoots"] = 1
        elif kind in ("geoip", "geosite"):
            row["sourceCommit"] = sources.get(kind, {}).get("sourceCommit", "1" * 40)
            license_name = "CC-BY-SA-4.0.txt" if kind == "geoip" else "GeoSite-MIT.txt"
            row["licenseSha256"] = hashlib.sha256((root / "third_party/data/geodata" / license_name).read_bytes()).hexdigest()
            if kind in sources and sources[kind].get("inputs"):
                row["sourceInputs"] = [{key: source[key] for key in ("sourceCommit", "description")}
                                       for source in sources[kind]["inputs"]]
        else:
            row["sourcePage"] = "https://db-ip.com/db/download/ip-to-" + ("country" if kind == "mmdb" else "asn") + "-lite"
        specs[kind] = update.resource_spec(row)
    record = {"format": "clash-pseudo-release-resources", "version": 1, "application": "0.2.0+4",
              "resources": specs,
              "licenses": {name: {"bytes": (root / name).stat().st_size,
                                  "sha256": hashlib.sha256((root / name).read_bytes()).hexdigest()}
                           for name in update.RESOURCE_INPUTS if name != update.RESOURCE_RECORD}}
    if source_metadata is not None:
        record["sourceInputs"] = source_metadata
    (root / update.RESOURCE_RECORD).write_bytes(update.json_bytes(record))
    output = root / update.GENERATED_BUNDLED
    for name, data in update.bundled_materials(root, record).items():
        path = output / name
        path.parent.mkdir(parents=True, exist_ok=True)
        path.write_bytes(data)
    for kind, data in payloads.items():
        path = output / "assets" / update.RESOURCE_ASSETS[kind]
        path.parent.mkdir(parents=True, exist_ok=True)
        path.write_bytes(data)
    return record, output
