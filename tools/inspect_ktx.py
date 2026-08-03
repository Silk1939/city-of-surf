#!/usr/bin/env python3
"""Offline KTX 1.1 half-float inspector — prints size / min / max / mean peak."""

from __future__ import annotations

import argparse
import struct
import sys
from pathlib import Path

import numpy as np

KTX_IDENT = bytes([0xAB, 0x4B, 0x54, 0x58, 0x20, 0x31, 0x31, 0xBB, 0x0D, 0x0A, 0x1A, 0x0A])
GL_RGBA16F = 0x881A
GL_RG16F = 0x822F
GL_HALF_FLOAT = 0x140B


def inspect(path: Path) -> dict:
    data = path.read_bytes()
    if len(data) < 68 or data[:12] != KTX_IDENT:
        raise ValueError(f"{path.name}: kein KTX 1.1")

    def u32(off: int) -> int:
        return struct.unpack_from("<I", data, off)[0]

    endian = u32(12)
    if endian != 0x04030201:
        raise ValueError(f"{path.name}: erwartet little-endian, got {endian:#x}")

    gl_type = u32(16)
    gl_internal = u32(28)
    width = u32(36)
    height = u32(40)
    kv = u32(60)
    if gl_type != GL_HALF_FLOAT:
        raise ValueError(f"{path.name}: glType {gl_type:#x} — erwartet GL_HALF_FLOAT")

    if gl_internal == GL_RGBA16F:
        channels = 4
        fmt = "RGBA16F"
    elif gl_internal == GL_RG16F:
        channels = 2
        fmt = "RG16F"
    else:
        raise ValueError(f"{path.name}: unsupported glInternal {gl_internal:#x}")

    img_off = 64 + kv
    image_size = u32(img_off)
    payload = img_off + 4
    expected = width * height * channels * 2
    if payload + expected > len(data):
        raise ValueError(f"{path.name}: payload truncated")

    arr = (
        np.frombuffer(data[payload : payload + expected], dtype="<f2")
        .reshape(height, width, channels)
        .astype(np.float32)
    )
    rgb = arr[..., : min(3, channels)]
    lum = (
        0.2126 * arr[..., 0] + 0.7152 * arr[..., 1] + 0.0722 * arr[..., 2]
        if channels >= 3
        else arr[..., 0]
    )
    return {
        "path": str(path.resolve()),
        "format": fmt,
        "width": width,
        "height": height,
        "channels": channels,
        "image_size": image_size,
        "min": float(rgb.min()),
        "max": float(rgb.max()),
        "mean": float(rgb.mean()),
        "lum_max": float(lum.max()),
        "above_2_pct": float((rgb.max(axis=2) > 2.0).mean() * 100.0) if channels >= 3 else float((rgb > 2.0).mean() * 100.0),
    }


def main() -> int:
    ap = argparse.ArgumentParser(description=__doc__)
    ap.add_argument(
        "paths",
        nargs="*",
        type=Path,
        default=[
            Path("city of surf/Resources/Lighting/sky_equirect.ktx"),
            Path("city of surf/Resources/Lighting/irradiance_equirect.ktx"),
            Path("city of surf/Resources/Lighting/specular_m0.ktx"),
        ],
    )
    args = ap.parse_args()
    for p in args.paths:
        if not p.exists():
            print(f"MISSING {p}", file=sys.stderr)
            continue
        info = inspect(p)
        print(
            f"{p.name}: {info['width']}x{info['height']} {info['format']} "
            f"min={info['min']:.4f} max={info['max']:.4f} mean={info['mean']:.4f} "
            f"lumMax={info['lum_max']:.4f} pct>2={info['above_2_pct']:.2f}%\n"
            f"  path={info['path']}"
        )
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
