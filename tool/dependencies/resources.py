"""Frozen resource records, payload validation, and build assets."""
import gzip
import hashlib
import io
import json
import os
from pathlib import Path
import re
import ssl
import shutil
import stat
import tempfile
import urllib.parse
from tool.common.io import (fetch as download, require, read_resource, read_bounded, json_bytes, unique_object, FETCH_LIMIT, RESOURCE_LIMIT, RESOURCE_TOTAL_LIMIT)
from tool.common.workspace import sync_directory

def _resolver(fetch):
    return fetch or download

ROOT = Path(__file__).resolve().parents[2]


ASSET_ROOT = "android/app/src/main/assets/"


RESOURCE_ASSETS = {
    "ca": "certificates/cacert.pem",
    "geoip": "geodata/GeoIP.dat",
    "geosite": "geodata/GeoSite.dat",
    "mmdb": "geodata/dbip-country-lite.mmdb.gzip",
    "asn": "geodata/dbip-asn-lite.mmdb.gzip",
}


RESOURCE_RECORD = "third_party/data/resources.json"


GENERATED_BUNDLED = "build/generated/bundled"


RESOURCE_INPUTS = (
    RESOURCE_RECORD,
    "third_party/data/certificates/MPL-2.0.txt",
    "third_party/data/geodata/CC-BY-SA-4.0.txt",
    "third_party/data/geodata/GeoSite-MIT.txt",
    "third_party/data/geodata/CC-BY-4.0.txt",
)


GEO_SOURCE_REPOSITORIES = {"geoip": "geoip", "geosite": "domain-list-community"}


def resource_spec(spec):
    """Fill in the encoding used for resource installation."""
    return {"encoding": "gzip" if spec["kind"] in ("mmdb", "asn") else "identity", **spec}


def validate_resource(data, spec):
    """Verify downloaded bytes, bound decompression, and record installed data."""
    stored = {"storedBytes": len(data), "storedSha256": hashlib.sha256(data).hexdigest()}
    require(0 < len(data) <= FETCH_LIMIT
            and all(spec.get(key, value) == value for key, value in stored.items()),
            "Downloaded file size or SHA-256 differs from the record, or size exceeds the limit")
    if spec["encoding"] == "gzip":
        with gzip.GzipFile(fileobj=io.BytesIO(data)) as stream:
            installed = read_bounded(stream, RESOURCE_LIMIT)
    else:
        installed = data
    require(0 < len(installed) <= RESOURCE_LIMIT, "Installation file is empty or exceeds the size limit")
    measured = {"installedBytes": len(installed), "installedSha256": hashlib.sha256(installed).hexdigest()}
    if spec["kind"] == "ca":
        context = ssl.SSLContext(ssl.PROTOCOL_TLS_CLIENT)
        # Preserve UTF-8 bytes in PEM comments in cafile; the TLS library parses the entire file.
        with tempfile.TemporaryDirectory(prefix="clash-ca-") as temporary:
            pem = Path(temporary) / "cacert.pem"
            pem.write_bytes(installed)
            context.load_verify_locations(cafile=str(pem))
        measured["certificateRoots"] = context.cert_store_stats()["x509"]
    return dict(spec, **stored, **measured)


def read_prepared_resource(directory):
    """Read frozen resource records and verify payloads."""
    directory = Path(directory).absolute()
    require(directory.resolve() == directory
            and (not directory.is_relative_to(ROOT) or directory.is_relative_to(ROOT / "build/generated")),
            "Resource preparation directory must not contain symbolic links or write into the source directory")
    spec = json.loads(read_resource(directory / "resource.json", 128 * 1024), object_pairs_hook=unique_object)
    data = read_resource(directory / "payload", min(spec["storedBytes"], FETCH_LIMIT))
    return validate_resource(data, spec), data


def prepare_resource(spec, destination, source=None, *, fetch=None):
    """Download resources in a separate directory and save frozen records and payloads on success."""
    fetch = _resolver(fetch)
    spec = resource_spec(spec)
    destination = Path(destination).absolute()
    require(destination.resolve() == destination
            and (not destination.is_relative_to(ROOT) or destination.is_relative_to(ROOT / "build/generated")),
            "Resource preparation directory must not contain symbolic links or write into the source directory")
    destination.mkdir(parents=True, exist_ok=True)
    if any(destination.iterdir()):
        resolved, _ = read_prepared_resource(destination)
        require(all(resolved.get(key) == value for key, value in spec.items()
                    if key not in ("installedBytes", "installedSha256", "certificateRoots")),
                "Resource source or frozen inputs differ on rerun")
        return destination
    expected = dict(spec)
    if "storedSha256" not in spec and spec.get("checksumUrl"):
        checksum = fetch(spec["checksumUrl"], limit=4096).decode("ascii").strip()
        match = re.fullmatch(r"(?:SHA256\([^\r\n]+\)\s*=\s*)?([0-9a-fA-F]{64})(?:[ \t]+\*?[^\r\n]+)?", checksum)
        require(match is not None, "Invalid official checksum file format")
        expected["storedSha256"] = match[1].lower()
    limit = min(spec.get("storedBytes", FETCH_LIMIT), FETCH_LIMIT)
    with tempfile.TemporaryDirectory(prefix=".resource-", dir=destination.parent) as temporary:
        staging = Path(temporary)
        payload = staging / "payload"
        if source is None:
            fetch(spec["sourceUrl"], limit=limit, destination=payload)
        else:
            payload.write_bytes(read_resource(source, limit))
        resolved = validate_resource(read_resource(payload, limit), expected)
        (staging / "resource.json").write_bytes(json_bytes(resolved))
        os.replace(staging, destination)
        sync_directory(destination.parent)
    return destination


def prepare_resources(specs, destination, sources=None):
    specs = [resource_spec(spec) for spec in specs]
    require(len(specs) == len(RESOURCE_ASSETS) and {spec["kind"] for spec in specs} == set(RESOURCE_ASSETS),
            "Delivery resources must be complete with no duplicate kinds")
    paths = [prepare_resource(spec, Path(destination) / spec["kind"], (sources or {}).get(spec["kind"]))
             for spec in specs]
    resolved = [read_prepared_resource(path)[0] for path in paths]
    require(all(sum(spec[prefix + "Bytes"] for spec in resolved) <= RESOURCE_TOTAL_LIMIT
                for prefix in ("stored", "installed")), "Total resource size exceeds the limit")
    return paths


def prepared_resources(directory):
    return [Path(directory) / kind for kind in RESOURCE_ASSETS]


def prepared_specs(prepared):
    specs = {}
    for directory in prepared:
        directory = Path(directory)
        require(directory.is_dir() and not directory.is_symlink(), "Invalid prepared resource directory: " + str(directory))
        spec, _ = read_prepared_resource(directory)
        require(directory.name == spec["kind"], "Resource preparation directory name differs from kind: " + str(directory))
        require(spec["kind"] not in specs, "Prepared resources contain duplicate kinds")
        specs[spec["kind"]] = spec
    require(set(specs) == set(RESOURCE_ASSETS), "Delivery resources are incomplete")
    return specs


def _source_expected(kind, commit):
    repository = GEO_SOURCE_REPOSITORIES[kind]
    revision = urllib.parse.quote(commit, safe="")
    url = f"https://github.com/v2fly/{repository}/archive/{revision}.tar.gz"
    return url, f"{repository}-{revision}.tar.gz"


def resource_source_entries(metadata):
    """Read the source manifest, check archive paths and size limits, and return registered (kind, source) pairs."""
    require(isinstance(metadata, dict) and metadata.get("format") == "clash-pseudo-resource-sources"
            and type(metadata.get("version")) is int and metadata["version"] == 1,
            "Invalid resource source manifest format")
    rows, kinds, total, result, filenames = metadata.get("sources"), set(), 0, [], set()
    require(isinstance(rows, list) and len(rows) == len(GEO_SOURCE_REPOSITORIES)
            and all(isinstance(row, dict) for row in rows), "Invalid resource source manifest entry")
    for row in rows:
        kind = row.get("kind")
        require(isinstance(kind, str) and kind in GEO_SOURCE_REPOSITORIES and kind not in kinds,
                "Invalid resource source kind: " + repr(kind))
        kinds.add(kind)
        entries = row.get("inputs", [])
        require(isinstance(entries, list) and all(isinstance(item, dict) for item in entries),
                "Invalid supplemental resource input manifest: " + kind)
        if kind == "geoip" or entries:
            require(entries and all(isinstance(item.get("description"), str) and item["description"].strip()
                                    for item in entries)
                    and isinstance(row.get("processing"), str) and row["processing"].strip(),
                    "Missing editable supplemental resource inputs or processing description: " + kind)
        commits = set()
        for source in [row, *entries]:
            commit, name = source.get("sourceCommit"), source.get("file")
            require(isinstance(name, str) and name not in ("", ".", "..", "resource-sources.json")
                    and "/" not in name and "\\" not in name and "\0" not in name,
                    "Invalid resource source file path")
            require(name not in filenames and commit not in commits, "Duplicate resource source file or commit: " + kind)
            filenames.add(name)
            commits.add(commit)
            size = source.get("bytes")
            require(type(size) is int and 0 < size <= FETCH_LIMIT, "Invalid resource source size: " + kind)
            total += size
            require(total <= RESOURCE_TOTAL_LIMIT, "Total resource source size exceeds the limit")
            result.append((kind, source))
    return result


def read_release_resources(root, record_path=None):
    """Read sources and digests saved for the release without querying official latest versions."""
    root = Path(root).resolve()
    path = Path(record_path) if record_path else root / RESOURCE_RECORD
    record = json.loads(read_resource(path, 1024 * 1024), object_pairs_hook=unique_object)
    require(isinstance(record, dict) and record.get("format") == "clash-pseudo-release-resources"
            and type(record.get("version")) is int and record["version"] == 1,
            "Invalid release resource source record format")
    specs = record.get("resources")
    require(isinstance(specs, dict) and set(specs) == set(RESOURCE_ASSETS), "Release resource records must contain five resources")
    return record


def bundled_materials(root, record):
    from tool.dependencies import legal
    original = legal.resource_materials(Path(root), record["resources"])
    result = {}
    for name, data in original.items():
        if name == ASSET_ROOT + "geodata/manifest.json":
            result["assets/geodata/manifest.json"] = data
        elif name == "third_party/data/certificates/manifest.json":
            result["certificates.json"] = data
        elif name.startswith("third_party/data/"):
            relative = name.removeprefix("third_party/data/")
            result["legal/" + relative] = data
            if relative.startswith("geodata/"):
                result["assets/geodata/NOTICE.txt"] = data
    for name in record["licenses"]:
        relative = name.removeprefix("third_party/data/")
        data = read_resource(Path(root) / name, 32 * 1024 * 1024)
        require(record["licenses"][name] == {"bytes": len(data), "sha256": hashlib.sha256(data).hexdigest()},
                "Release resource license text changed: " + name)
        result["legal/" + relative] = data
        if relative.startswith("geodata/"):
            result["assets/geodata/licenses/" + Path(name).name] = data
    from tool.contracts import generate as contract
    result["kotlin/io/github/monadboxlab/clashpseudo/nativecore/BundledAssetContract.kt"] = contract.asset_metadata(
        json.loads(result["assets/geodata/manifest.json"], object_pairs_hook=unique_object),
        json.loads(result["certificates.json"], object_pairs_hook=unique_object)).encode()
    result["resources.json"] = json_bytes(record)
    return result


def _replace_directory(staging, destination):
    previous = destination.with_name(destination.name + ".previous")
    require(not previous.exists() and not previous.is_symlink(), "Unrestored resource directory exists: " + str(previous))
    if destination.exists():
        os.replace(destination, previous)
    try:
        os.replace(staging, destination)
    except BaseException as error:
        if previous.exists():
            try:
                os.replace(previous, destination)
            except BaseException as rollback:
                error.add_note("Failed to restore old resources; original files remain at " + str(previous) + ": " + str(rollback))
        raise
    if previous.exists():
        shutil.rmtree(previous)


def prepare_bundled_assets(root, *, prepared=None, payloads=None, output=None, fetch=None, offline=False):
    """Normal builds read only frozen records; fetch missing payloads using recorded URLs and digests."""
    root = Path(root).resolve()
    record = read_release_resources(root)
    output = Path(output).absolute() if output else root / GENERATED_BUNDLED
    require(output.resolve() == output and output.is_relative_to(root / "build/generated"),
            "Bundled assets must be written under build/generated without symbolic links")
    output.parent.mkdir(parents=True, exist_ok=True)
    import fcntl
    with (output.parent / ".bundled.lock").open("a+b") as lock:
        fcntl.flock(lock, fcntl.LOCK_EX)
        cache = root / "build/generated/resource-cache"
        data = {}
        for kind, spec in record["resources"].items():
            if prepared is not None:
                payload = read_resource(Path(prepared) / kind / "payload", min(spec["storedBytes"], FETCH_LIMIT))
                validate_resource(payload, spec)
            else:
                # Use the digest as a single directory name; do not build paths from the record.
                digest_name = spec["storedSha256"]
                require(isinstance(digest_name, str) and digest_name not in ("", ".", "..")
                        and "/" not in digest_name and "\\" not in digest_name and "\0" not in digest_name,
                        "Invalid resource cache path")
                directory = cache / digest_name
                require(directory.resolve() == directory, "Resource cache directory must not contain symbolic links")
                cached_payload = directory / "payload"
                if not cached_payload.exists():
                    source = (payloads or {}).get(kind)
                    require(not offline or source is not None, "Offline build is missing a frozen resource: " + kind)
                    cache.mkdir(parents=True, exist_ok=True)
                    with tempfile.TemporaryDirectory(prefix=".download-", dir=cache) as temporary:
                        incoming = Path(temporary) / "payload"
                        limit = min(spec["storedBytes"], FETCH_LIMIT)
                        if source is None:
                            _resolver(fetch)(spec["sourceUrl"], limit=limit, destination=incoming)
                        else:
                            incoming.write_bytes(read_resource(source, limit))
                        payload = read_resource(incoming, limit)
                        validate_resource(payload, spec)
                        directory.mkdir(exist_ok=True)
                        os.replace(incoming, cached_payload)
                else:
                    payload = read_resource(cached_payload, min(spec["storedBytes"], FETCH_LIMIT))
                    validate_resource(payload, spec)
            data["assets/" + RESOURCE_ASSETS[kind]] = payload
        data.update(bundled_materials(root, record))
        # Stage output in a new directory; preserve the previous complete output if any validation fails.
        with tempfile.TemporaryDirectory(prefix=".bundled-", dir=output.parent) as temporary:
            staging = Path(temporary) / "complete"
            staging.mkdir()
            for name, value in data.items():
                target = staging / name
                target.parent.mkdir(parents=True, exist_ok=True)
                target.write_bytes(value)
            require(read_release_resources(root) == record, "Release resource records changed during generation")
            _replace_directory(staging, output)
    return output


def check_resource_source_selection(root, metadata):
    """Compare editable resource sources against commits in this release's frozen records."""
    record = read_release_resources(root)
    for row in metadata["sources"]:
        require(row["sourceCommit"] == record["resources"][row["kind"]]["sourceCommit"],
                "Resource source commit differs from the release record: " + row["kind"])
    if "sourceInputs" in record:
        require(metadata == record["sourceInputs"], "Resource source origin, size, or digest differs from the release record")


def read_resource_sources(directory):
    """Read resource-sources.json and verify the size and SHA-256 of each archive in the same directory."""
    directory = Path(directory).absolute()
    require(directory.resolve() == directory, "Resource source directory must not contain symbolic links")
    manifest = directory / "resource-sources.json"
    require(not manifest.is_symlink(), "Resource source manifest must not be a symbolic link")
    metadata = json.loads(read_resource(manifest, 128 * 1024), object_pairs_hook=unique_object)
    for kind, source in resource_source_entries(metadata):
        path = directory / source["file"]
        require(not path.is_symlink() and path.is_file(), "Resource sources must be regular files: " + kind)
        descriptor = os.open(path, os.O_RDONLY | os.O_NOFOLLOW | os.O_NONBLOCK)
        with os.fdopen(descriptor, "rb") as stream:
            require(stat.S_ISREG(os.fstat(stream.fileno()).st_mode), "Resource sources must be regular files: " + kind)
            require(os.fstat(stream.fileno()).st_size == source["bytes"], "Resource source size differs: " + kind)
            require(hashlib.file_digest(stream, "sha256").hexdigest() == source["sha256"],
                    "Resource source digest differs: " + kind)
    return metadata
