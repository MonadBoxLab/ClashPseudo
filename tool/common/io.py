"""有界读写、HTTPS 下载与 JSON 基础校验。"""
import hashlib
import io
import json
import os
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
    require(type(limit) is int and limit > 0, "读取大小上限无效")
    size, digest = 0, hashlib.sha256()
    while True:
        chunk = source.read(min(CHUNK, limit - size + 1))
        if not chunk:
            break
        size += len(chunk)
        require(size <= limit, "数据超过读取大小上限")
        digest.update(chunk)
        destination.write(chunk)
    return {"bytes": size, "sha256": digest.hexdigest()}


class HttpsRedirect(urllib.request.HTTPRedirectHandler):
    def redirect_request(self, request, fp, code, message, headers, url):
        require(url.startswith("https://"), "重定向来源必须使用 HTTPS")
        return super().redirect_request(request, fp, code, message, headers, url)


def fetch(url, *, limit=FETCH_LIMIT, destination=None):
    """通过HTTPS下载更新材料，按limit限制响应大小。"""
    require(url.startswith("https://"), "来源必须使用 HTTPS：" + url)
    request = urllib.request.Request(url, headers={"User-Agent": "clash-pseudo-dependency-update"})
    with urllib.request.build_opener(HttpsRedirect()).open(request, timeout=60) as response:
        require(response.geturl().startswith("https://"), "响应来源必须使用 HTTPS")
        length = response.headers.get("Content-Length")
        if length is not None:
            require(length.isdecimal() and int(length) <= limit, "响应长度超过读取大小上限或无效")
        if destination is None:
            data = read_bounded(response, limit)
            require(length is None or len(data) == int(length), "Content-Length 声明的字节数与实际读取的字节数不一致")
            return data
        with Path(destination).open("xb") as output:
            result = transfer(response, output, limit)
            output.flush()
            os.fsync(output.fileno())
        require(length is None or result["bytes"] == int(length), "Content-Length 声明的字节数与实际读取的字节数不一致")
        return result


def json_bytes(value):
    return (json.dumps(value, ensure_ascii=False, indent=2, sort_keys=True) + "\n").encode()


def unique_object(pairs):
    result = {}
    for key, value in pairs:
        require(key not in result, "JSON 包含重复字段：" + key)
        result[key] = value
    return result


def read_resource(path, limit):
    descriptor = os.open(path, os.O_RDONLY | os.O_NOFOLLOW | os.O_NONBLOCK)
    with os.fdopen(descriptor, "rb") as stream:
        require(stat.S_ISREG(os.fstat(stream.fileno()).st_mode), "资源输入不是普通文件")
        return read_bounded(stream, limit)
