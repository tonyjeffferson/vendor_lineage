#!/usr/bin/env python3
# Copyright (C) 2026 Lunaris-AOSP
# SPDX-License-Identifier: Apache-2.0

"""Create a signed A/B incremental OTA and add it to the device feed."""

import argparse
import hashlib
import json
import os
from pathlib import Path
import posixpath
import subprocess
import tempfile
from urllib.parse import urlsplit, urlunsplit
import zipfile


def read_metadata(ota_path):
    with zipfile.ZipFile(ota_path) as ota_zip:
        metadata = ota_zip.read("META-INF/com/android/metadata").decode()
    return dict(line.split("=", 1) for line in metadata.splitlines() if "=" in line)


def hashes_and_size(path):
    md5 = hashlib.md5()
    sha256 = hashlib.sha256()
    size = 0
    with path.open("rb") as ota_file:
        for chunk in iter(lambda: ota_file.read(1024 * 1024), b""):
            size += len(chunk)
            md5.update(chunk)
            sha256.update(chunk)
    return md5.hexdigest(), sha256.hexdigest(), size


def read_varint(data, offset):
    value = 0
    shift = 0
    while offset < len(data):
        byte = data[offset]
        offset += 1
        value |= (byte & 0x7F) << shift
        if byte < 0x80:
            return value, offset
        shift += 7
        if shift >= 70:
            break
    raise ValueError("Malformed protobuf varint in update payload")


def protobuf_fields(data):
    offset = 0
    while offset < len(data):
        tag, offset = read_varint(data, offset)
        field_number, wire_type = tag >> 3, tag & 7
        if field_number == 0:
            raise ValueError("Invalid protobuf field in update payload")
        if wire_type == 0:
            value, offset = read_varint(data, offset)
        elif wire_type == 1:
            value, offset = data[offset:offset + 8], offset + 8
        elif wire_type == 2:
            size, offset = read_varint(data, offset)
            value, offset = data[offset:offset + size], offset + size
        elif wire_type == 5:
            value, offset = data[offset:offset + 4], offset + 4
        else:
            raise ValueError(f"Unsupported protobuf wire type {wire_type}")
        yield field_number, wire_type, value


def payload_update_flags(ota_path):
    with zipfile.ZipFile(ota_path) as ota_zip:
        with ota_zip.open("payload.bin") as payload:
            header = payload.read(24)
            if len(header) != 24 or header[:4] != b"CrAU":
                raise ValueError("Generated OTA has an invalid payload header")
            manifest_size = int.from_bytes(header[12:20], "big")
            manifest = payload.read(manifest_size)
            if len(manifest) != manifest_size:
                raise ValueError("Generated OTA has a truncated payload manifest")

    has_source_partitions = False
    is_partial = False
    for field_number, wire_type, value in protobuf_fields(manifest):
        if field_number == 16 and wire_type == 0:
            is_partial = bool(value)
        elif field_number == 13 and wire_type == 2:
            has_source_partitions |= any(
                nested_number == 6 and nested_wire == 2
                for nested_number, nested_wire, _ in protobuf_fields(value)
            )
    return has_source_partitions, is_partial


def add_to_feed(feed_path, ota_path, metadata):
    feed = json.loads(feed_path.read_text())
    if not feed.get("response"):
        raise ValueError(f"No base OTA entry found in {feed_path}")

    entry = dict(feed["response"][0])
    filename = ota_path.name
    entry["filename"] = filename
    base_url = urlsplit(entry["download"])
    entry["download"] = urlunsplit(
        base_url._replace(path=posixpath.join(posixpath.dirname(base_url.path), filename))
    )
    entry["timestamp"] = int(metadata["post-timestamp"])
    for key in ("pre-build", "pre-build-incremental"):
        if metadata.get(key):
            entry[key] = metadata[key]
    if "post-security-patch-level" in metadata:
        entry["os_patch_level"] = metadata["post-security-patch-level"]
    if "post-sdk-level" in metadata:
        entry["os_sdk_level"] = int(metadata["post-sdk-level"])
    entry["md5"], entry["sha256"], entry["size"] = hashes_and_size(ota_path)

    feed["response"] = [
        item for item in feed["response"] if item.get("filename") != filename
    ]
    feed["response"].append(entry)

    with tempfile.NamedTemporaryFile(
        mode="w", encoding="utf-8", dir=feed_path.parent,
        prefix=f".{feed_path.name}.", delete=False
    ) as feed_tmp:
        json.dump(feed, feed_tmp, indent=2, ensure_ascii=False)
        feed_tmp.write("\n")
        temp_name = feed_tmp.name
    os.replace(temp_name, feed_path)


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--build-top", type=Path, required=True)
    parser.add_argument("--product-out", type=Path, required=True)
    parser.add_argument("--device", required=True)
    parser.add_argument("--version", required=True)
    parser.add_argument("--ota-tool", type=Path, required=True)
    parser.add_argument("--source-target-files", type=Path, required=True)
    parser.add_argument("--target-target-files", type=Path, required=True)
    args = parser.parse_args()

    source = Path(os.environ.get("OTA_SOURCE_TARGET_FILES", args.source_target_files))
    target = args.target_target_files
    for archive in (source, target):
        if not archive.is_file():
            raise FileNotFoundError(
                f"Missing target-files archive: {archive}. "
                "Build two successive full packages first, or set "
                "OTA_SOURCE_TARGET_FILES to the installed build's target-files ZIP."
            )

    args.product_out.mkdir(parents=True, exist_ok=True)
    filename = f"{args.version}-incremental.zip"
    ota_path = args.product_out / filename
    fd, temp_path = tempfile.mkstemp(
        prefix=f".{filename}.", suffix=".tmp.zip", dir=args.product_out
    )
    os.close(fd)
    os.unlink(temp_path)

    try:
        # Do not pass --partial: that produces a selective-partition payload,
        # which requires a partition version for every included partition.
        subprocess.run(
            [str(args.ota_tool), "-i", str(source), str(target), temp_path],
            cwd=args.build_top,
            check=True,
        )

        has_source_partitions, is_partial = payload_update_flags(temp_path)
        if not has_source_partitions:
            raise ValueError("Generated package does not contain an incremental payload")
        if is_partial:
            raise ValueError("Generated payload is marked as partial; refusing to publish it")

        metadata = read_metadata(temp_path)
        required = ("post-timestamp", "pre-build", "pre-build-incremental")
        if any(key not in metadata for key in required):
            raise ValueError("Generated OTA metadata is missing post-timestamp")

        os.replace(temp_path, ota_path)
        add_to_feed(args.product_out / f"{args.device}.json", ota_path, metadata)
    finally:
        if os.path.exists(temp_path):
            os.unlink(temp_path)

    print(f"Incremental OTA created: {ota_path}")
    print(f"Updater feed updated: {args.product_out / f'{args.device}.json'}")


if __name__ == "__main__":
    main()
