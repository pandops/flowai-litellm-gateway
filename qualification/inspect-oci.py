"""Inspect the immutable, unextracted tar streams in the qualification OCI layout."""

import gzip
import hashlib
import io
import json
import pathlib
import posixpath
import sys
import tarfile
import zipfile

OCI_MANIFEST = "application/vnd.oci.image.manifest.v1+json"
SITE = "app/.venv/lib/python3.13/site-packages/"
MIT_CORE = SITE + "litellm/proxy/"
PINNED_ARCHIVES = {
    SITE + "dateutil/zoneinfo/dateutil-zoneinfo.tar.gz",
    SITE + "ddtrace/internal/third-party.tar.gz",
    "usr/lib/apk/db/scripts.tar",
    "usr/share/python-wheels/pip-26.2.1-py3-none-any.whl",
}
LICENSE_BASE = "usr/share/licenses/flowai-litellm-gateway/"
NOTICE_FILES = {
    LICENSE_BASE + "LICENSE": "LICENSE",
    LICENSE_BASE + "LiteLLM-LICENSE": "licenses/LiteLLM-LICENSE",
    LICENSE_BASE + "PgBouncer-COPYRIGHT": "licenses/PgBouncer-COPYRIGHT",
    LICENSE_BASE + "PgBouncer-lib-COPYRIGHT": "licenses/PgBouncer-lib-COPYRIGHT",
}


def check_path(path):
    if path.startswith("/"):
        raise ValueError("unexpected absolute archive entry")
    path = posixpath.normpath(path)
    if path == ".." or path.startswith("../"):
        raise ValueError("archive traversal")
    parts = path.lower().split("/")
    if path == "app/litellm-proxy-extras/dist" or path.startswith("app/litellm-proxy-extras/dist/"):
        raise ValueError("retained proxy-extras distribution archive")
    if any("enterprise" in part for part in parts):
        allowed = {
            MIT_CORE + "enterprise_billing",
            MIT_CORE + "enterprise_billing/__init__.py",
            MIT_CORE + "enterprise_billing/billing_metrics.py",
            MIT_CORE + "example_config_yaml/enterprise_config.yaml",
        }
        if path not in allowed:
            raise ValueError("unexpected enterprise path or link target")
    return path


def check_nested(path, stream):
    data = stream.read()
    if path.endswith(".whl"):
        with zipfile.ZipFile(io.BytesIO(data)) as archive:
            for member in archive.infolist():
                check_path(member.filename)
            return len(archive.infolist())
    with tarfile.open(fileobj=io.BytesIO(data), mode="r:*") as archive:
        for member in archive:
            check_path(member.name)
            if member.issym() or member.islnk():
                check_path(posixpath.normpath(member.linkname.lstrip("/")))
        return len(archive.getmembers())


def sha(stream):
    return "sha256:" + hashlib.file_digest(stream, "sha256").hexdigest()


def checked_blob(root, descriptor):
    digest = descriptor["digest"]
    algorithm, identifier = digest.split(":")
    assert algorithm == "sha256" and len(identifier) == 64
    blob = root / "blobs" / algorithm / identifier
    assert blob.stat().st_size == descriptor["size"]
    with blob.open("rb") as stream:
        assert sha(stream) == digest
    return blob


def main(root, upstream_path, expected_digest):
    index = json.loads((root / "index.json").read_text())
    descriptor, = index["manifests"]
    assert descriptor["digest"] == expected_digest
    assert descriptor["mediaType"] == OCI_MANIFEST
    manifest = json.loads(checked_blob(root, descriptor).read_text())
    config = json.loads(checked_blob(root, manifest["config"]).read_text())
    upstream = json.loads(upstream_path.read_text())
    upstream_layers = {layer["digest"] for layer in upstream["layers"]}
    assert manifest["mediaType"] == OCI_MANIFEST
    assert (config["os"], config["architecture"]) == ("linux", "amd64")
    runtime = config["config"]
    assert runtime["User"] == "65532:65532" and runtime["WorkingDir"] == "/app"
    assert runtime["Entrypoint"] == ["/usr/local/bin/flowai-litellm-gateway"]
    assert not runtime.get("Cmd")
    assert runtime["ExposedPorts"] == {"4000/tcp": {}}
    assert set(runtime["Env"]) == {
        "PATH=/app/.venv/bin:/usr/local/sbin:/usr/local/bin:/usr/bin:/usr/sbin:/sbin:/bin",
        "SSL_CERT_FILE=/etc/ssl/certs/ca-certificates.crt",
        "PRISMA_BINARY_CACHE_DIR=/opt/prisma/binaries",
        "PRISMA_CLI_PATH=/opt/prisma/binaries/node_modules/.bin/prisma",
        "PRISMA_CLI_QUERY_ENGINE_TYPE=binary",
        "PRISMA_OFFLINE_MODE=true",
        "HOME=/tmp",
    }
    originals = {
        "etc/flowai-litellm/litellm.yaml": "config/litellm.yaml",
        "usr/local/bin/flowai-litellm-gateway": "entrypoint.sh",
        **NOTICE_FILES,
    }
    verified = set()
    nested = {}
    for layer, diff_id in zip(manifest["layers"], config["rootfs"]["diff_ids"], strict=True):
        assert layer["digest"] not in upstream_layers
        assert layer["mediaType"] == "application/vnd.oci.image.layer.v1.tar+gzip"
        blob = checked_blob(root, layer)
        with gzip.open(blob, "rb") as stream:
            assert sha(stream) == diff_id
        count = links = notices = 0
        with tarfile.open(blob, "r|gz") as archive:
            for member in archive:
                name = check_path(member.name)
                assert ".wh." not in posixpath.basename(name)
                count += 1
                if member.issym():
                    check_path(posixpath.join(posixpath.dirname(name), member.linkname)
                               if not member.linkname.startswith("/") else member.linkname.lstrip("/"))
                    links += 1
                if member.islnk():
                    check_path(member.linkname.lstrip("/"))
                    links += 1
                if not member.isfile():
                    continue
                if any(word in posixpath.basename(name).lower()
                       for word in ("license", "licence", "copying", "copyright", "notice")):
                    notices += 1
                if name in originals:
                    with archive.extractfile(member) as stream, open(originals[name], "rb") as source:
                        assert sha(stream) == sha(source)
                    verified.add(name)
                if name.endswith((".tar", ".tar.gz", ".tar.xz", ".tar.bz2", ".tar.zst",
                                  ".tgz", ".whl", ".zip", ".jar", ".7z", ".deb", ".rpm", ".apk")):
                    assert name in PINNED_ARCHIVES
                    with archive.extractfile(member) as stream:
                        nested[name] = check_nested(name, stream)
        print(f"layer={layer['digest']} diff_id={diff_id} entries={count} links={links} notices={notices}")
    assert verified == originals.keys()
    assert nested.keys() == PINNED_ARCHIVES
    expected = {descriptor["digest"], manifest["config"]["digest"],
                *(layer["digest"] for layer in manifest["layers"])}
    actual = {"sha256:" + path.name for path in (root / "blobs" / "sha256").iterdir()}
    assert actual == expected
    print(f"nested_archives={len(nested)} members={sum(nested.values())}")
    print(f"output_platform=linux/amd64 output_media_type={OCI_MANIFEST}")
    print(f"output_config={manifest['config']['digest']} output_manifest={expected_digest}")


if __name__ == "__main__":
    main(pathlib.Path(sys.argv[1]), pathlib.Path(sys.argv[2]), sys.argv[3])
