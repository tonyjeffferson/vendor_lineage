#!/bin/bash
#
# Copyright (C) 2019-2026 crDroid Android Project
#
# Licensed under the Apache License, Version 2.0 (the "License");
#

set -e

# $1 = TARGET_DEVICE
# $2 = PRODUCT_OUT
# $3 = FILE_NAME

DEVICE="$1"
PRODUCT_OUT="$2"
FILENAME="$3"

# Detect build variant (version.mk emits VANILLA in uppercase).
if [[ "${FILENAME^^}" == *"VANILLA"* ]]; then
    BUILD_VARIANT="vanilla"
else
    BUILD_VARIANT="gapps"
fi

# Set OTA json location
if [[ "$BUILD_VARIANT" == "vanilla" ]]; then
    existingOTAjson="./vendor/OTA/builds/vanilla/${DEVICE}.json"
    DOWNLOAD_URL="https://tlserver.dynv6.net:8443/${DEVICE}/${FILENAME}"
else
    existingOTAjson="./vendor/OTA/builds/${DEVICE}.json"
    DOWNLOAD_URL="https://tlserver.dynv6.net:8443/${DEVICE}/${FILENAME}"
fi

output="${PRODUCT_OUT}/${DEVICE}.json"

echo "Generating JSON file data for OTA support..."

# Build information
MD5=$(md5sum "$PRODUCT_OUT/$FILENAME" | cut -d' ' -f1)
SHA256=$(sha256sum "$PRODUCT_OUT/$FILENAME" | cut -d' ' -f1)
SIZE=$(stat -c "%s" "$PRODUCT_OUT/$FILENAME")

export DEVICE PRODUCT_OUT FILENAME DOWNLOAD_URL MD5 SHA256 SIZE existingOTAjson output

# Append this build, remove entries whose ZIP is no longer in PRODUCT_OUT, and
# retain the remaining history. A missing output file is initialized with an
# empty response array. Invalid existing JSON is left untouched and fails.
python3 - <<'PY'
import json
import os
import pathlib
import re
import subprocess
import tempfile

env = os.environ
output = pathlib.Path(env["output"])
source = pathlib.Path(env["existingOTAjson"])

fields = (
    "maintainer", "oem", "device", "buildtype", "forum", "gapps",
    "firmware", "modem", "bootloader", "recovery", "paypal", "telegram",
    "dt", "common-dt", "kernel",
)
fallback = {}
if source.is_file():
    with source.open(encoding="utf-8") as stream:
        source_data = json.load(stream)
    if source_data.get("response") and isinstance(source_data["response"][0], dict):
        fallback = source_data["response"][0]

def read_properties(path):
    properties = {}
    if path.is_file():
        for line in path.read_text(encoding="utf-8", errors="replace").splitlines():
            line = line.strip()
            if not line or line.startswith("#") or "=" not in line:
                continue
            key, value = line.split("=", 1)
            properties[key.strip()] = value.strip()
    return properties

product_out = pathlib.Path(env["PRODUCT_OUT"])
properties = {}
for relative in ("system/build.prop", "system_ext/build.prop", "product/build.prop",
                 "vendor/build.prop", "odm/etc/build.prop"):
    properties.update(read_properties(product_out / relative))

def git_url(path):
    if not path.is_dir():
        return ""
    for remote in ("github", "upstream", "origin"):
        result = subprocess.run(
            ["git", "-C", str(path), "config", "--get", f"remote.{remote}.url"],
            capture_output=True, text=True, check=False)
        if result.returncode == 0 and result.stdout.strip():
            value = result.stdout.strip()
            match = re.search(r"(?:https://github\.com/|git@github\.com:)([^\s]+)", value)
            if match:
                return "https://github.com/" + match.group(1).removesuffix(".git")
            return value.removesuffix(".git")
    return ""

tree_candidates = sorted(pathlib.Path("device").glob(f"*/{env['DEVICE']}"))
device_tree = next((path for path in tree_candidates
                    if (path / "AndroidProducts.mk").is_file()), None)
common_tree = None
kernel_tree = None
if device_tree:
    # Resolve common trees declared by the device's dependency manifests or makefiles.
    candidate_paths = []
    for manifest in (device_tree / "lineage.dependencies",
                     device_tree / "lunaris.dependencies"):
        if manifest.is_file():
            try:
                deps = json.loads(manifest.read_text(encoding="utf-8"))
                candidate_paths.extend(item.get("target_path", "") for item in deps
                                       if isinstance(item, dict))
            except (json.JSONDecodeError, OSError):
                pass
    for makefile in device_tree.glob("*.mk"):
        try:
            contents = makefile.read_text(encoding="utf-8", errors="replace")
        except OSError:
            continue
        candidate_paths.extend(re.findall(r"(device/[\w.+-]+/[\w.+-]*common)", contents))
    common_tree = next((pathlib.Path(item) for item in candidate_paths
                        if item and pathlib.Path(item).is_dir()
                        and "common" in pathlib.Path(item).name.lower()), None)

    # Kernel source is declared in a device or common BoardConfig makefile.
    for root in (device_tree, common_tree):
        if not root:
            continue
        for makefile in root.rglob("*.mk"):
            try:
                contents = makefile.read_text(encoding="utf-8", errors="replace")
            except OSError:
                continue
            match = re.search(r"^TARGET_KERNEL_SOURCE\s*:?=\s*([^\\\s]+)",
                              contents, re.MULTILINE)
            if match and pathlib.Path(match.group(1)).is_dir():
                kernel_tree = pathlib.Path(match.group(1))
                break
        if kernel_tree:
            break

tree = {}
tree["maintainer"] = properties.get("ro.lunaris.maintainer", "")
tree["oem"] = properties.get("ro.product.manufacturer", "")
tree["device"] = properties.get("ro.product.device", "")
package_type = properties.get("ro.lunaris.package.type", "")
tree["buildtype"] = package_type.split("-", 1)[0] if package_type else ""
if not tree["buildtype"]:
    tree["buildtype"] = next((value for value in ("GMS", "VANILLA")
                               if value in env["FILENAME"].upper()), "")

# Optional device-specific metadata can be set as ro.lunaris.ota.<field>
# properties. The common Updater defaults and the local Git remotes are also
# available as tree sources.
for field in fields:
    tree[field] = properties.get(f"ro.lunaris.ota.{field}", tree.get(field, ""))

updater_metadata = pathlib.Path("packages/apps/Updater/app/src/main/java/org/lineageos/updater/data/DeviceMetadata.kt")
if updater_metadata.is_file():
    contents = updater_metadata.read_text(encoding="utf-8", errors="replace")
    for field, constant in (("telegram", "DEFAULT_TELEGRAM"), ("paypal", "DEFAULT_PAYPAL")):
        match = re.search(rf'const val {constant}\s*=\s*"([^"]*)"', contents)
        if match:
            tree[field] = tree.get(field) or match.group(1)

if device_tree:
    tree["dt"] = tree.get("dt") or git_url(device_tree)
if common_tree:
    tree["common-dt"] = tree.get("common-dt") or git_url(common_tree)
if kernel_tree:
    tree["kernel"] = tree.get("kernel") or git_url(kernel_tree)

# Tree values take precedence. Empty or unavailable values use the official
# device JSON as a per-field fallback, keeping this script reusable per device.
metadata = {field: (tree.get(field) or fallback.get(field) or "") for field in fields}
metadata["device"] = metadata["device"] or env["DEVICE"]

filename_parts = env["FILENAME"].split("-")
try:
    version_index = next(i for i, part in enumerate(filename_parts)
                         if re.fullmatch(r"v?\d+\.\d+(?:\.\d+)?", part))
    version_parts = filename_parts[version_index].lstrip("v").split(".")
    version = ".".join(version_parts[:2])
except StopIteration:
    version = ""

timestamp = properties.get("ro.system.build.date.utc", "")
patch_level = properties.get("ro.build.version.security_patch", "")
sdk_level = properties.get("ro.build.version.sdk", "")

entry = {
    **metadata,
    "filename": env["FILENAME"],
    "download": env["DOWNLOAD_URL"],
    "timestamp": int(timestamp or 0),
    "md5": env["MD5"],
    "sha256": env["SHA256"],
    "size": int(env["SIZE"]),
    "version": version,
    "os_patch_level": patch_level,
    "os_sdk_level": int(sdk_level or 0),
}

if output.exists():
    with output.open(encoding="utf-8") as stream:
        data = json.load(stream)
    if not isinstance(data, dict) or not isinstance(data.get("response"), list):
        raise SystemExit(f"Invalid OTA JSON structure in {output}; leaving it unchanged")
else:
    data = {"response": []}

# Rebuilding the same filename refreshes its metadata instead of duplicating it.
entries = data["response"]
entries[:] = [item for item in entries
              if not isinstance(item, dict) or item.get("filename") != entry["filename"]]
entries.insert(0, entry)

# Only advertise builds whose packages are still available in the output dir.
entries[:] = [item for item in entries
              if isinstance(item, dict)
              and isinstance(item.get("filename"), str)
              and (product_out / item["filename"]).is_file()]

output.parent.mkdir(parents=True, exist_ok=True)
fd, temporary = tempfile.mkstemp(prefix=output.name + ".", dir=output.parent)
try:
    with os.fdopen(fd, "w", encoding="utf-8") as stream:
        json.dump(data, stream, indent=2, ensure_ascii=False)
        stream.write("\n")
    os.replace(temporary, output)
finally:
    if os.path.exists(temporary):
        os.unlink(temporary)
PY

if [ ! -f "$existingOTAjson" ]; then
    echo "There is no official support for this device yet"
fi

echo "JSON file generation completed"
