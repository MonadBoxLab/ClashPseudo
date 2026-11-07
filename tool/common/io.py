"""Bounded I/O, HTTPS downloads, and basic JSON validation."""
import hashlib
import io
import json
import logging
import os
import time
from urllib.parse import urlsplit
from pathlib import Path
import stat
import urllib.request

def require(condition, message):
    if not condition:
        raise ValueError(message)

CHUNK = 64 * 1024


FETCH_LIMIT = 64 * 1024 * 1024


RESOURCE_LIMIT = 128 * 1024 * 1024


RESOURCE_TOTAL_LIMIT = 256 * 1024 * 1024


def read_bounded(stream, limit):
    output = io.BytesIO()
    transfer(stream, output, limit)
    return output.getvalue()


def transfer(source, destination, limit):
    require(type(limit) is int and limit > 0, "Invalid read size limit")
    size, digest = 0, hashlib.sha256()
    while True:
        chunk = source.read(min(CHUNK, limit - size + 1))
        if not chunk:
            break
        size += len(chunk)
        require(size <= limit, "Data exceeds the read size limit")
        digest.update(chunk)
        destination.write(chunk)
    return {"bytes": size, "sha256": digest.hexdigest()}


class HttpsRedirect(urllib.request.HTTPRedirectHandler):
    def redirect_request(self, request, fp, code, message, headers, url):
        require(url.startswith("https://"), "Redirect URLs must use HTTPS")
        return super().redirect_request(request, fp, code, message, headers, url)


def fetch(url, *, limit=FETCH_LIMIT, destination=None):
    """Download update inputs over HTTPS with responses bounded by limit."""
    require(url.startswith("https://"), "Source URLs must use HTTPS: " + url)
    source = urlsplit(url)
    label = (source.hostname or "") + source.path
    started = time.monotonic()
    logging.info("Downloading: %s", label)
    request = urllib.request.Request(url, headers={"User-Agent": "clash-pseudo-dependency-update"})
    with urllib.request.build_opener(HttpsRedirect()).open(request, timeout=60) as response:
        require(response.geturl().startswith("https://"), "Response URLs must use HTTPS")
        length = response.headers.get("Content-Length")
        if length is not None:
            require(length.isdecimal() and int(length) <= limit, "Response length is invalid or exceeds the read size limit")
        if destination is None:
            data = read_bounded(response, limit)
            require(length is None or len(data) == int(length), "Content-Length does not match the number of bytes read")
            logging.info("Downloaded: %s, %.1f MiB in %.1f seconds", label, len(data) / 1024**2, time.monotonic() - started)
            return data
        with Path(destination).open("xb") as output:
            result = transfer(response, output, limit)
            output.flush()
            os.fsync(output.fileno())
        require(length is None or result["bytes"] == int(length), "Content-Length does not match the number of bytes read")
        logging.info("Downloaded: %s, %.1f MiB in %.1f seconds", label, result["bytes"] / 1024**2, time.monotonic() - started)
        return result


def json_bytes(value):
    return (json.dumps(value, ensure_ascii=False, indent=2, sort_keys=True) + "\n").encode()


def unique_object(pairs):
    result = {}
    for key, value in pairs:
        require(key not in result, "Duplicate JSON field: " + key)
        result[key] = value
    return result


def read_resource(path, limit):
    descriptor = os.open(path, os.O_RDONLY | os.O_NOFOLLOW | os.O_NONBLOCK)
    with os.fdopen(descriptor, "rb") as stream:
        require(stat.S_ISREG(os.fstat(stream.fileno()).st_mode), "Resource input is not a regular file")
        return read_bounded(stream, limit)
