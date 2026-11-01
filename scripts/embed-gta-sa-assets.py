#!/usr/bin/env python3
"""Embed the pinned GTA 1547000 helper and license into a native Swift CLI."""
import argparse
import base64
import hashlib
import json
import os
from pathlib import Path, PurePosixPath

DLL_NAMES = {"d3d11.dll", "dxgi.dll", "d3d10core.dll"}


def sha256(data: bytes) -> str:
    return hashlib.sha256(data).hexdigest()


def require_hash(value: object, label: str) -> str:
    if not isinstance(value, str) or len(value) != 64:
        raise ValueError(f"{label} must be a 64-character SHA-256")
    try:
        int(value, 16)
    except ValueError as error:
        raise ValueError(f"{label} is not a SHA-256") from error
    return value.lower()


def require_relative(value: object, label: str) -> str:
    if not isinstance(value, str) or not value or value.startswith("/"):
        raise ValueError(f"{label} must be a relative path")
    path = PurePosixPath(value)
    if any(part in ("", ".", "..") for part in path.parts):
        raise ValueError(f"{label} contains an unsafe path component")
    return value


def validate_manifest(manifest: object) -> dict:
    if not isinstance(manifest, dict) or manifest.get("schema") != 1:
        raise ValueError("manifest schema must be 1")
    if manifest.get("appid") != "1547000":
        raise ValueError("manifest AppID must be 1547000")
    if manifest.get("engine") != "winecx-11.17":
        raise ValueError("manifest engine must be winecx-11.17")
    require_relative(manifest.get("gameExecutable"), "gameExecutable")
    require_hash(manifest.get("gameExecutableSHA256"), "gameExecutableSHA256")
    if not isinstance(manifest.get("gameExecutableSize"), int) or manifest["gameExecutableSize"] <= 0:
        raise ValueError("gameExecutableSize must be positive")
    require_relative(manifest.get("dxmtDirectory"), "dxmtDirectory")
    files = manifest.get("dxmtFiles")
    if not isinstance(files, list) or {item.get("name") for item in files if isinstance(item, dict)} != DLL_NAMES:
        raise ValueError("dxmtFiles must pin d3d11.dll, dxgi.dll and d3d10core.dll")
    for item in files:
        if not isinstance(item, dict) or item.get("name") not in DLL_NAMES:
            raise ValueError("invalid DXMT DLL entry")
        require_hash(item.get("sha256"), f"{item['name']} sha256")
    require_relative(manifest.get("helperDirectory"), "helperDirectory")
    for key in ("helperName", "realHelperName", "helperChecksumName", "helperLicenseName"):
        name = manifest.get(key)
        if not isinstance(name, str) or not name or "/" in name or name in (".", ".."):
            raise ValueError(f"{key} must be a filename")
    require_hash(manifest.get("helperWrapperSHA256"), "helperWrapperSHA256")
    require_hash(manifest.get("helperLicenseSHA256"), "helperLicenseSHA256")
    vendors = manifest.get("supportedVendorHelpers")
    if not isinstance(vendors, list) or not vendors:
        raise ValueError("supportedVendorHelpers must not be empty")
    for vendor in vendors:
        if not isinstance(vendor, dict) or not isinstance(vendor.get("version"), str):
            raise ValueError("invalid supported vendor helper")
        require_hash(vendor.get("sha256"), "vendor helper sha256")
    return manifest


def swift_data(name: str, data: bytes) -> str:
    encoded = base64.b64encode(data).decode("ascii")
    chunks = [encoded[i:i + 100] for i in range(0, len(encoded), 100)]
    lines = ",\n".join(f'            "{chunk}"' for chunk in chunks)
    return f"""    static let {name} = Data(base64Encoded: [
{lines}
        ].joined())!
"""


def main() -> None:
    parser = argparse.ArgumentParser()
    parser.add_argument("--manifest", required=True, type=Path)
    parser.add_argument("--wrapper", required=True, type=Path)
    parser.add_argument("--license", required=True, type=Path)
    parser.add_argument("--output", required=True, type=Path)
    args = parser.parse_args()

    manifest_bytes = args.manifest.read_bytes()
    manifest = validate_manifest(json.loads(manifest_bytes))
    wrapper = args.wrapper.read_bytes()
    license_text = args.license.read_bytes()
    if sha256(wrapper) != manifest["helperWrapperSHA256"]:
        raise SystemExit("SocialClubHelper.exe SHA-256 does not match the manifest")
    if sha256(license_text) != manifest["helperLicenseSHA256"]:
        raise SystemExit("SocialClubHelper license SHA-256 does not match the manifest")

    output = (
        "import Foundation\n\n"
        "enum GTAFixPrepAssets {\n"
        + swift_data("manifestJSON", manifest_bytes)
        + swift_data("helperWrapper", wrapper)
        + swift_data("helperLicense", license_text)
        + "}\n"
    )
    args.output.parent.mkdir(parents=True, exist_ok=True)
    temporary = args.output.with_name(args.output.name + f".{os.getpid()}.tmp")
    temporary.write_text(output, encoding="utf-8")
    os.replace(temporary, args.output)


if __name__ == "__main__":
    main()
