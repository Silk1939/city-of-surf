#!/usr/bin/env python3
"""
Fetch CC0 lighting/PBR assets and bake Metal-ready IBL maps.

Usage (from repo root):
  python3 tools/fetch_assets.py
  make fetch-assets
"""

from __future__ import annotations

import json
import math
import os
import struct
import sys
import urllib.parse
import urllib.request
import zipfile
from pathlib import Path

try:
    from PIL import Image
except ImportError:
    print("Installing Pillow…")
    import subprocess
    subprocess.check_call([sys.executable, "-m", "pip", "install", "--user", "Pillow"])
    from PIL import Image

import numpy as np

ROOT = Path(__file__).resolve().parents[1]
MANIFEST_PATH = Path(__file__).resolve().parent / "assets.json"
UA = {"User-Agent": "FloodSurfer-fetch_assets/1.0"}


def http_json(url: str):
    req = urllib.request.Request(url, headers=UA)
    with urllib.request.urlopen(req, timeout=120) as r:
        return json.loads(r.read().decode("utf-8"))


def http_download(url: str, dest: Path):
    dest.parent.mkdir(parents=True, exist_ok=True)
    if dest.exists() and dest.stat().st_size > 0:
        print(f"  cached: {dest.name}")
        return
    print(f"  download: {url}")
    req = urllib.request.Request(url, headers=UA)
    with urllib.request.urlopen(req, timeout=300) as r, open(dest, "wb") as f:
        while True:
            chunk = r.read(1024 * 256)
            if not chunk:
                break
            f.write(chunk)


def load_radiance_hdr(path: Path) -> np.ndarray:
    """Load Radiance RGBE .hdr → float32 HxWx3 linear RGB."""
    with open(path, "rb") as f:
        assert f.readline().decode().startswith("#?RADIANCE")
        while True:
            line = f.readline()
            if line.strip() == b"":
                break
        size_line = f.readline().decode().strip()
        # -Y height +X width
        parts = size_line.split()
        height = int(parts[1])
        width = int(parts[3])
        data = np.zeros((height, width, 3), dtype=np.float32)
        for y in range(height):
            if f.read(4) != bytes([2, 2, width >> 8, width & 255]):
                # Old RLE fallback — rare; fill remaining black
                break
            channels = []
            for _ in range(4):
                ch = bytearray()
                while len(ch) < width:
                    count = f.read(1)[0]
                    if count > 128:
                        run = f.read(1)[0]
                        ch.extend([run] * (count - 128))
                    else:
                        ch.extend(f.read(count))
                channels.append(np.frombuffer(bytes(ch), dtype=np.uint8))
            rgbe = np.stack(channels, axis=1)  # W x 4
            e = rgbe[:, 3].astype(np.float32)
            mask = e > 0
            rgb = np.zeros((width, 3), dtype=np.float32)
            rgb[mask] = (rgbe[mask, :3].astype(np.float32) + 0.5) / 256.0 * np.power(
                2.0, e[mask] - 128.0
            )[:, None]
            data[y] = rgb
    return data


def tonemap_reinhard(hdr: np.ndarray, exposure: float = 1.0) -> np.ndarray:
    x = np.clip(hdr * exposure, 0, None)
    ldr = x / (1.0 + x)
    return np.clip(np.power(ldr, 1.0 / 2.2), 0, 1)


def save_png_rgb(path: Path, rgb01: np.ndarray):
    path.parent.mkdir(parents=True, exist_ok=True)
    img = (np.clip(rgb01, 0, 1) * 255.0 + 0.5).astype(np.uint8)
    Image.fromarray(img, mode="RGB").save(path, optimize=True)


def float32_to_float16_bytes(rgba_f32: np.ndarray) -> bytes:
    """HxWx4 float32 → tightly packed little-endian float16 bytes."""
    return np.asarray(rgba_f32, dtype=np.float16).tobytes()


def save_ktx_rgba16f(path: Path, rgb: np.ndarray, channels: int = 4):
    """
    Write KTX 1.1 uncompressed RGBA16F (or RG16F if channels==2).
    Linear HDR values — no tonemap. MTKTextureLoader / custom parser.
    """
    path.parent.mkdir(parents=True, exist_ok=True)
    h, w = rgb.shape[:2]
    if channels == 4:
        if rgb.shape[2] == 3:
            alpha = np.ones((h, w, 1), dtype=np.float32)
            rgba = np.concatenate([rgb.astype(np.float32), alpha], axis=2)
        else:
            rgba = rgb.astype(np.float32)[..., :4]
        gl_format = 0x1908  # GL_RGBA
        gl_internal = 0x881A  # GL_RGBA16F
        gl_base = 0x1908
    elif channels == 2:
        rgba = rgb.astype(np.float32)[..., :2]
        gl_format = 0x8227  # GL_RG
        gl_internal = 0x822F  # GL_RG16F
        gl_base = 0x8227
    else:
        raise ValueError(channels)

    payload = np.asarray(rgba, dtype=np.float16).tobytes()
    # Pad image data to 4-byte boundary
    pad = (4 - (len(payload) % 4)) % 4
    payload_padded = payload + (b"\x00" * pad)

    header = bytearray()
    header += b"\xABKTX 11\xBB\r\n\x1A\n"
    header += struct.pack("<I", 0x04030201)  # little endian
    header += struct.pack("<I", 0x140B)  # GL_HALF_FLOAT
    header += struct.pack("<I", 2)  # glTypeSize
    header += struct.pack("<I", gl_format)
    header += struct.pack("<I", gl_internal)
    header += struct.pack("<I", gl_base)
    header += struct.pack("<I", w)
    header += struct.pack("<I", h)
    header += struct.pack("<I", 0)  # depth
    header += struct.pack("<I", 0)  # array elements
    header += struct.pack("<I", 1)  # faces
    header += struct.pack("<I", 1)  # mipmap levels
    header += struct.pack("<I", 0)  # key-value bytes
    header += struct.pack("<I", len(payload_padded))
    path.write_bytes(bytes(header) + payload_padded)
    print(f"  wrote {path} ({w}x{h} rgba16f, peak={float(np.max(rgb)):.3f})")


def _resize_float(arr: np.ndarray, out_w: int, out_h: int | None = None) -> np.ndarray:
    """HDR-safe box downsample (no 8-bit quantization)."""
    if out_h is None:
        out_h = out_w
    h, w = arr.shape[:2]
    if out_w == w and out_h == h:
        return arr.astype(np.float32)
    # Area average via reshape when divisible, else bilinear via indices
    ys = (np.arange(out_h) + 0.5) * h / out_h - 0.5
    xs = (np.arange(out_w) + 0.5) * w / out_w - 0.5
    y0 = np.clip(np.floor(ys).astype(int), 0, h - 1)
    x0 = np.clip(np.floor(xs).astype(int), 0, w - 1)
    y1 = np.clip(y0 + 1, 0, h - 1)
    x1 = np.clip(x0 + 1, 0, w - 1)
    wy = (ys - y0).astype(np.float32)[:, None, None]
    wx = (xs - x0).astype(np.float32)[None, :, None]
    a = arr[y0][:, x0]
    b = arr[y0][:, x1]
    c = arr[y1][:, x0]
    d = arr[y1][:, x1]
    # Broadcasting carefully
    out = np.zeros((out_h, out_w, arr.shape[2]), dtype=np.float32)
    for j in range(out_h):
        wyj = float(ys[j] - y0[j])
        for i in range(out_w):
            wxi = float(xs[i] - x0[i])
            out[j, i] = (
                arr[y0[j], x0[i]] * (1 - wxi) * (1 - wyj)
                + arr[y0[j], x1[i]] * wxi * (1 - wyj)
                + arr[y1[j], x0[i]] * (1 - wxi) * wyj
                + arr[y1[j], x1[i]] * wxi * wyj
            )
    return out


def equirect_sample(hdr: np.ndarray, dirs: np.ndarray) -> np.ndarray:
    """dirs: Nx3 unit vectors → Nx3 RGB."""
    h, w = hdr.shape[:2]
    x, y, z = dirs[:, 0], dirs[:, 1], dirs[:, 2]
    theta = np.arccos(np.clip(y, -1, 1))
    phi = np.arctan2(z, x)
    u = (phi + math.pi) / (2 * math.pi)
    v = theta / math.pi
    ix = np.clip((u * w).astype(int), 0, w - 1)
    iy = np.clip((v * h).astype(int), 0, h - 1)
    return hdr[iy, ix]


def direction_from_uv(u: float, v: float) -> np.ndarray:
    phi = u * 2 * math.pi - math.pi
    theta = v * math.pi
    st, ct = math.sin(theta), math.cos(theta)
    sp, cp = math.sin(phi), math.cos(phi)
    return np.array([st * cp, ct, st * sp], dtype=np.float32)


def bake_irradiance_equirect(hdr: np.ndarray, size: int = 32) -> np.ndarray:
    """Cosine-weighted irradiance via few fixed hemisphere samples (offline)."""
    src = _resize_float(hdr, min(hdr.shape[1], 256), min(hdr.shape[0], 128))
    out_h, out_w = size // 2, size
    out = np.zeros((out_h, out_w, 3), dtype=np.float32)
    samples = 32
    # Precompute sample offsets on unit disk
    dirs_local = []
    weights = []
    for s in range(samples):
        xi1 = (s + 0.5) / samples
        xi2 = (s * 0.6180339887) % 1.0
        phi = 2 * math.pi * xi1
        cos_t = math.sqrt(1 - xi2)
        sin_t = math.sqrt(xi2)
        dirs_local.append((math.cos(phi) * sin_t, math.sin(phi) * sin_t, cos_t))
        weights.append(cos_t)
    dirs_local = np.array(dirs_local, dtype=np.float32)
    weights = np.array(weights, dtype=np.float32)

    for j in range(out_h):
        for i in range(out_w):
            n = direction_from_uv((i + 0.5) / out_w, (j + 0.5) / out_h)
            up = np.array([0, 1, 0], dtype=np.float32) if abs(n[1]) < 0.999 else np.array([1, 0, 0], dtype=np.float32)
            t = np.cross(up, n)
            t /= np.linalg.norm(t) + 1e-8
            b = np.cross(n, t)
            ls = dirs_local[:, 0:1] * t + dirs_local[:, 1:2] * b + dirs_local[:, 2:3] * n
            ls = ls / (np.linalg.norm(ls, axis=1, keepdims=True) + 1e-8)
            cols = equirect_sample(src, ls)
            out[j, i] = (cols * weights[:, None]).sum(axis=0) / max(float(weights.sum()), 1e-5)
        if j % 4 == 0:
            print(f"  irradiance row {j}/{out_h}")
    return out


def bake_specular_equirect(hdr: np.ndarray, size: int, roughness: float, samples: int = 16) -> np.ndarray:
    src = _resize_float(hdr, min(hdr.shape[1], 256), min(hdr.shape[0], 128))
    out_h, out_w = max(1, size // 2), size
    out = np.zeros((out_h, out_w, 3), dtype=np.float32)
    a = max(roughness, 0.04) ** 2
    for j in range(out_h):
        for i in range(out_w):
            n = direction_from_uv((i + 0.5) / out_w, (j + 0.5) / out_h)
            up = np.array([0, 1, 0], dtype=np.float32) if abs(n[1]) < 0.999 else np.array([1, 0, 0], dtype=np.float32)
            t = np.cross(up, n)
            t /= np.linalg.norm(t) + 1e-8
            b = np.cross(n, t)
            acc = np.zeros(3, dtype=np.float32)
            tw = 0.0
            for s in range(samples):
                xi1 = (s + 0.5) / samples
                xi2 = (s * 0.7548776662) % 1.0
                phi = 2 * math.pi * xi1
                cos_theta = math.sqrt((1 - xi2) / (1 + (a * a - 1) * xi2 + 1e-5))
                sin_theta = math.sqrt(max(0.0, 1 - cos_theta * cos_theta))
                h = t * (math.cos(phi) * sin_theta) + b * (math.sin(phi) * sin_theta) + n * cos_theta
                h /= np.linalg.norm(h) + 1e-8
                l = 2 * np.dot(n, h) * h - n
                ndotl = max(float(np.dot(n, l)), 0.0)
                if ndotl > 0:
                    acc += equirect_sample(src, l[None, :])[0] * ndotl
                    tw += ndotl
            out[j, i] = acc / max(tw, 1e-5)
    return out


def bake_brdf_lut(size: int = 128) -> np.ndarray:
    out = np.zeros((size, size, 3), dtype=np.float32)
    samples = 32
    for j in range(size):
        roughness = (j + 0.5) / size
        a = max(roughness, 0.001) ** 2
        for i in range(size):
            ndotv = max((i + 0.5) / size, 1e-3)
            v = np.array([math.sqrt(1 - ndotv * ndotv), 0.0, ndotv], dtype=np.float32)
            a_scale = 0.0
            a_bias = 0.0
            for s in range(samples):
                xi1 = (s + 0.5) / samples
                xi2 = (s * 0.6180339887) % 1.0
                phi = 2 * math.pi * xi1
                cos_theta = math.sqrt((1 - xi2) / (1 + (a * a - 1) * xi2 + 1e-5))
                sin_theta = math.sqrt(max(0.0, 1 - cos_theta * cos_theta))
                h = np.array([math.cos(phi) * sin_theta, math.sin(phi) * sin_theta, cos_theta], dtype=np.float32)
                l = 2 * np.dot(v, h) * h - v
                ndotl = max(l[2], 0.0)
                ndoth = max(h[2], 0.0)
                vdoth = max(float(np.dot(v, h)), 0.0)
                if ndotl > 0:
                    g_v = ndotv / max(ndotv + math.sqrt(a * a + (1 - a * a) * ndotv * ndotv), 1e-5)
                    g_l = ndotl / max(ndotl + math.sqrt(a * a + (1 - a * a) * ndotl * ndotl), 1e-5)
                    g_vis = (g_v * g_l * vdoth) / max(ndoth * ndotv, 1e-5)
                    fc = (1 - vdoth) ** 5
                    a_scale += (1 - fc) * g_vis
                    a_bias += fc * g_vis
            out[j, i, 0] = a_scale / samples
            out[j, i, 1] = a_bias / samples
    return out


def find_sun_direction(hdr: np.ndarray) -> tuple[list[float], list[float]]:
    # Luminance peak
    lum = 0.2126 * hdr[:, :, 0] + 0.7152 * hdr[:, :, 1] + 0.0722 * hdr[:, :, 2]
    # Blur a bit by downsample
    small = _resize_float(hdr, 256, 128)
    lum_s = 0.2126 * small[:, :, 0] + 0.7152 * small[:, :, 1] + 0.0722 * small[:, :, 2]
    j, i = np.unravel_index(int(np.argmax(lum_s)), lum_s.shape)
    d = direction_from_uv((i + 0.5) / small.shape[1], (j + 0.5) / small.shape[0])
    # Light direction is towards the scene from the sun → -d as "to light" convention used in shaders as L
    to_light = d / (np.linalg.norm(d) + 1e-8)
    # Prefer elevated sun for gameplay readability
    if to_light[1] < 0.15:
        to_light[1] = 0.35
        to_light = to_light / np.linalg.norm(to_light)
    color = small[j, i]
    color = color / (np.max(color) + 1e-5)
    # Warm sunset tint boost
    color = np.clip(color * np.array([1.15, 0.85, 0.55], dtype=np.float32), 0, 1)
    return to_light.tolist(), color.tolist()


def fetch_polyhaven_hdri(asset: dict, cache: Path) -> tuple[Path, Path | None]:
    aid = asset["id"]
    files = http_json(f"https://api.polyhaven.com/files/{aid}")
    res = asset.get("resolution", "4k")
    hdr_path = cache / f"{aid}_{res}.hdr"
    jpg_path = cache / f"{aid}_{res}_tonemap.jpg"

    # Prefer 2K HDR for faster bake when 4k already cached; else requested res.
    if "hdri" in files and res in files["hdri"] and "hdr" in files["hdri"][res]:
        url = files["hdri"][res]["hdr"]["url"]
        http_download(url, hdr_path)
    else:
        # fallback 2k
        for r in ("2k", "1k", "4k"):
            if "hdri" in files and r in files["hdri"] and "hdr" in files["hdri"][r]:
                hdr_path = cache / f"{aid}_{r}.hdr"
                http_download(files["hdri"][r]["hdr"]["url"], hdr_path)
                break
        else:
            raise RuntimeError(f"No HDR for {aid}")

    # For bake speed: if 4k exists, also ensure 2k for convolution source
    hdr_2k = cache / f"{aid}_2k.hdr"
    if "hdri" in files and "2k" in files["hdri"] and "hdr" in files["hdri"]["2k"]:
        http_download(files["hdri"]["2k"]["hdr"]["url"], hdr_2k)
        bake_hdr = hdr_2k
    else:
        bake_hdr = hdr_path

    # Tonemapped JPG for sky
    jpg_out = None
    if "tonemapped" in files:
        tm = files["tonemapped"]
        url = None
        if isinstance(tm, dict):
            if res in tm and "jpg" in tm[res]:
                url = tm[res]["jpg"]["url"]
            elif "4k" in tm and "jpg" in tm["4k"]:
                url = tm["4k"]["jpg"]["url"]
            elif "2k" in tm and "jpg" in tm["2k"]:
                url = tm["2k"]["jpg"]["url"]
        if url:
            http_download(url, jpg_path)
            jpg_out = jpg_path
    return bake_hdr, jpg_out, hdr_path


def fetch_ambientcg_material(asset: dict, cache: Path, out_dir: Path, runtime_res: int):
    aid = asset["id"]
    key = asset["key"]
    q = asset.get("search") or aid
    data = http_json(
        f"https://ambientCG.com/api/v3/assets?q={urllib.parse.quote(q)}&type=material&limit=50&include=downloads,maps,title,url,id"
    )
    assets = data.get("assets") or []
    entry = None
    for a in assets:
        if a.get("id") == aid:
            entry = a
            break
    if entry is None and assets:
        # Fallback: first result if exact id missing from filter
        entry = next((a for a in assets if aid.lower() in a.get("id", "").lower()), assets[0])
    if entry is None:
        raise RuntimeError(f"ambientCG asset not found: {aid}")

    downloads = entry.get("downloads") or []
    zip_url = None
    # Prefer 2K-JPG (matches runtime); fall back to 4K then 1K.
    for pref in ("2K-JPG", "4K-JPG", "1K-JPG"):
        for d in downloads:
            if d.get("attributes") == pref and d.get("extension") == "zip":
                zip_url = d.get("url")
                break
        if zip_url:
            break
    if not zip_url:
        raise RuntimeError(f"No JPG zip for ambientCG {aid}")

    zpath = cache / f"{aid}.zip"
    http_download(zip_url, zpath)
    extract = cache / aid
    extract.mkdir(parents=True, exist_ok=True)
    with zipfile.ZipFile(zpath, "r") as zf:
        zf.extractall(extract)

    dest = out_dir
    dest.mkdir(parents=True, exist_ok=True)
    wanted = {
        "Color": f"{key}_albedo.png",
        "NormalGL": f"{key}_normal.png",
        "Roughness": f"{key}_roughness.png",
    }
    for map_name, out_name in wanted.items():
        candidates = list(extract.rglob(f"*{map_name}*.jpg")) + list(extract.rglob(f"*{map_name}*.png"))
        if not candidates:
            print(f"  WARN missing map {map_name} for {aid}")
            continue
        src = candidates[0]
        img = Image.open(src).convert("RGB")
        img = img.resize((runtime_res, runtime_res), Image.Resampling.LANCZOS)
        img.save(dest / out_name, optimize=True)
        print(f"  wrote {dest / out_name}")
    return {
        "id": entry.get("id", aid),
        "title": entry.get("title", aid),
        "url": entry.get("url") or f"https://ambientcg.com/view?id={aid}",
        "license": "CC0",
    }


def write_credits(credits: list[dict], path: Path):
    lines = [
        "# Credits",
        "",
        "All third-party assets below are **CC0** (public domain dedication).",
        "",
        "## HDRIs",
        "",
    ]
    for c in credits:
        if c.get("kind") == "hdri":
            lines.append(f"- **{c['name']}** — [{c['id']}]({c['url']}) via Poly Haven (CC0)")
    lines += ["", "## Materials (ambientCG)", ""]
    for c in credits:
        if c.get("kind") == "material":
            lines.append(f"- **{c['name']}** (`{c['id']}`) — [{c.get('url','')}]({c.get('url','')}) (CC0)")
    lines += [
        "",
        "## Notes",
        "",
        "- Fetched by `tools/fetch_assets.py` from `tools/assets.json`.",
        "- Source 4K assets are downsampled to 2K for the iOS app bundle (memory).",
        "- Flood Surfer uses **Metal 4** IBL (not RealityKit ImageBasedLight).",
        "",
    ]
    path.write_text("\n".join(lines))


def main():
    manifest = json.loads(MANIFEST_PATH.read_text())
    cache = ROOT / manifest["cache_dir"]
    runtime = ROOT / manifest["runtime_dir"]
    cache.mkdir(parents=True, exist_ok=True)
    runtime.mkdir(parents=True, exist_ok=True)
    ibl_cfg = manifest["ibl"]
    runtime_res = int(manifest.get("runtime_resolution", 1024))
    credits: list[dict] = []

    hdr_path = None
    jpg_path = None
    source_hdr = None

    for asset in manifest["assets"]:
        print(f"\n=== {asset['key']} ({asset['provider']}:{asset['id']}) ===")
        if asset["provider"] == "polyhaven":
            hdr_path, jpg_path, source_hdr = fetch_polyhaven_hdri(asset, cache)
            credits.append(
                {
                    "kind": "hdri",
                    "id": asset["id"],
                    "name": asset.get("credit", asset["id"]),
                    "url": f"https://polyhaven.com/a/{asset['id']}",
                }
            )
        elif asset["provider"] == "ambientcg":
            meta = fetch_ambientcg_material(asset, cache, runtime, runtime_res)
            credits.append(
                {
                    "kind": "material",
                    "id": meta["id"],
                    "name": meta["title"],
                    "url": meta["url"],
                }
            )

    assert hdr_path is not None
    print("\n=== IBL bake (HDR rgba16f KTX) ===")
    print(f"Loading HDR {hdr_path}")
    hdr = load_radiance_hdr(hdr_path)
    print(f"HDR size {hdr.shape[1]}x{hdr.shape[0]} max={hdr.max():.2f}")

    sky_w = int(ibl_cfg.get("sky_width", 1024))
    sky_h = int(ibl_cfg.get("sky_height", 512))
    sky_hdr = _resize_float(hdr, sky_w, sky_h)
    # Linear HDR only — never tonemap / sRGB-encode sky into the KTX.
    assert sky_hdr.dtype == np.float32
    sky_peak = float(sky_hdr.max())
    save_ktx_rgba16f(runtime / "sky_equirect.ktx", sky_hdr)
    print(f"Sky HDR peak (linear)={sky_peak:.3f} — must stay >> 1 for sunset sun disk")

    sun_dir, sun_col = find_sun_direction(hdr)
    print(f"Sun direction {sun_dir}, color {sun_col}")

    irr = bake_irradiance_equirect(hdr, ibl_cfg["irradiance_size"])
    save_ktx_rgba16f(runtime / "irradiance_equirect.ktx", irr)
    irr_peak = float(irr.max() + 1e-5)

    spec_mips = int(ibl_cfg["specular_mips"])
    # Same resolution for every specular layer (Metal 2D-array requires equal sizes).
    spec_size = int(ibl_cfg["specular_size"])
    for mi in range(spec_mips):
        roughness = mi / max(spec_mips - 1, 1)
        print(f"Specular mip {mi} roughness={roughness:.2f} size={spec_size}")
        spec = bake_specular_equirect(hdr, spec_size, roughness, samples=12 if mi > 0 else 16)
        save_ktx_rgba16f(runtime / f"specular_m{mi}.ktx", spec)

    brdf = bake_brdf_lut(ibl_cfg["brdf_lut_size"])
    # RG16F — scale / bias (no need for B/A)
    save_ktx_rgba16f(runtime / "brdf_lut.ktx", brdf[..., :2], channels=2)

    # Remove legacy LDR IBL PNGs if present
    for legacy in [
        "sky_equirect.png",
        "irradiance_equirect.png",
        "brdf_lut.png",
        *[f"specular_m{i}.png" for i in range(8)],
    ]:
        p = runtime / legacy
        if p.exists():
            p.unlink()
            print(f"  removed legacy {legacy}")

    lighting = {
        "sunDirection": sun_dir,
        "sunColor": sun_col,
        "sunIntensity": 2.8,
        "iblIntensity": 1.15,
        # HUD iblPeak must reflect sky HDR peak (not diffuse irradiance ~1–2).
        "skyPeak": sky_peak,
        "irradiancePeak": sky_peak,
        "irradianceMapPeak": irr_peak,
        "specularMips": spec_mips,
        "shadowBias": 0.002,
        "hdri": "sunset_jhbcentral",
        "iblFormat": "rgba16f_ktx",
    }
    (runtime / "lighting.json").write_text(json.dumps(lighting, indent=2))
    write_credits(credits, ROOT / "CREDITS.md")
    print("\nDone. Runtime →", runtime)
    print("Credits →", ROOT / "CREDITS.md")


if __name__ == "__main__":
    main()
