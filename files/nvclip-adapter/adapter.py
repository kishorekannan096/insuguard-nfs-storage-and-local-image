#!/usr/bin/env python3
# NV-CLIP airgapped adapter: exposes the NIM wrapper's /v1/embeddings API
# (base64 image in, embedding vector out) on top of a locally-launched
# tritonserver's native KServe v2 protocol, so claims-backend's existing
# HTTP calls keep working when nvclip runs via airgappedTritonMode instead
# of the NGC-authenticating NIM wrapper.
#
# ASSUMPTIONS THAT NEED FIELD VERIFICATION (see discover-airgap-info.sh):
#   - Preprocessing matches the standard OpenCLIP ViT-H-14 (LAION) transform:
#     resize-shorter-side + center-crop to the model's configured resolution,
#     then normalize with the OpenAI CLIP mean/std constants below.
#   - The output tensor is a single flat embedding per image and should be
#     L2-normalized for cosine similarity (claims-backend's DUPLICATE_THRESHOLD
#     implies cosine similarity against normalized vectors).
#   - Model name, input/output tensor names, shape and datatype are NOT
#     guessed — they're read from Triton's own /v2/models/<name> metadata
#     endpoint at request time, which is ground truth for whatever is
#     actually loaded.
# If real embeddings don't match expectations, start here. Validated so far
# only against a stub Triton server (protocol/shape/dtype plumbing, not real
# NV-CLIP weights) — run discover-airgap-info.sh's verification step before
# trusting this in production.

import base64
import io
import json
import os
import sys
import threading
import urllib.error
import urllib.request
from http.server import BaseHTTPRequestHandler, ThreadingHTTPServer

try:
    import numpy as np
    from PIL import Image
except ImportError as exc:
    sys.stderr.write(
        "FATAL: adapter requires numpy + Pillow, which were expected to "
        "already be present in the nvclip NIM image (it does this same "
        "preprocessing internally in NIM-wrapper mode). Import failed: "
        "%s\n" % exc
    )
    sys.exit(1)

TRITON_PORT = os.environ["TRITON_PORT"]
TRITON_URL = "http://127.0.0.1:%s" % TRITON_PORT
MODEL_NAME = os.environ.get("MODEL_NAME", "").strip()
IMAGE_SIZE_DEFAULT = int(os.environ.get("IMAGE_SIZE", "224"))
LISTEN_PORT = int(os.environ.get("ADAPTER_PORT", "8000"))

# Standard OpenAI CLIP normalization constants (also used by OpenCLIP models,
# including the ViT-H-14 checkpoint NV-CLIP is built on).
CLIP_MEAN = (0.48145466, 0.4578275, 0.40821073)
CLIP_STD = (0.26862954, 0.26130258, 0.27577711)

DTYPE_MAP = {
    "FP32": np.float32,
    "FP16": np.float16,
}

_meta_lock = threading.Lock()
_meta = {}


def _triton_status(path, timeout=5):
    req = urllib.request.Request(TRITON_URL + path, method="GET")
    try:
        with urllib.request.urlopen(req, timeout=timeout) as resp:
            return resp.status
    except urllib.error.HTTPError as e:
        return e.code


def _triton_get_json(path, timeout=10):
    req = urllib.request.Request(TRITON_URL + path, method="GET")
    with urllib.request.urlopen(req, timeout=timeout) as resp:
        return json.loads(resp.read().decode())


def _triton_post_json(path, payload, timeout=30):
    data = json.dumps(payload).encode()
    req = urllib.request.Request(
        TRITON_URL + path, data=data,
        headers={"Content-Type": "application/json"}, method="POST",
    )
    with urllib.request.urlopen(req, timeout=timeout) as resp:
        return json.loads(resp.read().decode())


def _discover_model_name():
    if MODEL_NAME:
        return MODEL_NAME
    index = _triton_post_json("/v2/repository/index", {})
    if not index:
        raise RuntimeError("Triton repository index returned no models")
    return index[0]["name"]


def _resolve_layout(shape):
    # shape is e.g. [-1, 3, 224, 224] (NCHW) or [-1, 224, 224, 3] (NHWC).
    # Ground truth for WHICH dim is which comes from Triton; we only infer
    # NCHW vs NHWC from which axis is size 3 (channel count).
    dims = shape[1:]  # drop batch dim
    if len(dims) != 3:
        raise RuntimeError("unexpected input tensor rank: shape=%r" % (shape,))
    if dims[0] == 3:
        layout, h, w = "NCHW", dims[1], dims[2]
    elif dims[2] == 3:
        layout, h, w = "NHWC", dims[0], dims[1]
    else:
        raise RuntimeError("can't find a 3-channel axis in shape=%r" % (shape,))
    size = h if h > 0 else (w if w > 0 else IMAGE_SIZE_DEFAULT)
    return layout, size


def load_model_meta():
    global _meta
    with _meta_lock:
        if _meta:
            return _meta
        name = _discover_model_name()
        info = _triton_get_json("/v2/models/%s" % name)
        inp = info["inputs"][0]
        out = info["outputs"][0]
        if inp["datatype"] not in DTYPE_MAP:
            raise RuntimeError(
                "unsupported input datatype %r reported by Triton — adapter "
                "only handles FP32/FP16" % inp["datatype"]
            )
        layout, size = _resolve_layout(inp["shape"])
        _meta = {
            "name": name,
            "input_name": inp["name"],
            "output_name": out["name"],
            "datatype": inp["datatype"],
            "numpy_dtype": DTYPE_MAP[inp["datatype"]],
            "layout": layout,
            "size": size,
        }
        return _meta


def decode_image(item):
    s = item
    if not isinstance(s, str):
        raise ValueError("expected a base64 or data-URI string, got %s" % type(s))
    if s.startswith("data:"):
        s = s.split(",", 1)[1]
    raw = base64.b64decode(s)
    return Image.open(io.BytesIO(raw)).convert("RGB")


def preprocess(img, size):
    w, h = img.size
    scale = size / min(w, h)
    new_w, new_h = max(size, round(w * scale)), max(size, round(h * scale))
    img = img.resize((new_w, new_h), Image.BICUBIC)
    left = (new_w - size) // 2
    top = (new_h - size) // 2
    img = img.crop((left, top, left + size, top + size))
    arr = np.asarray(img).astype(np.float32) / 255.0
    mean = np.array(CLIP_MEAN, dtype=np.float32)
    std = np.array(CLIP_STD, dtype=np.float32)
    return (arr - mean) / std  # HWC, float32


class Handler(BaseHTTPRequestHandler):
    server_version = "nvclip-adapter/1.0"

    def log_message(self, fmt, *args):
        sys.stderr.write("%s - %s\n" % (self.address_string(), fmt % args))

    def _write_json(self, code, obj):
        body = json.dumps(obj).encode()
        self.send_response(code)
        self.send_header("Content-Type", "application/json")
        self.send_header("Content-Length", str(len(body)))
        self.end_headers()
        self.wfile.write(body)

    def do_GET(self):
        if self.path in ("/v1/health/ready", "/v1/health/live"):
            triton_path = "/v2/health/ready" if "ready" in self.path else "/v2/health/live"
            try:
                status = _triton_status(triton_path)
            except Exception:
                status = 503
            self.send_response(200 if status == 200 else 503)
            self.end_headers()
            return
        self.send_error(404)

    def do_POST(self):
        if self.path != "/v1/embeddings":
            self.send_error(404)
            return
        length = int(self.headers.get("Content-Length", 0) or 0)
        try:
            body = json.loads(self.rfile.read(length) or b"{}")
        except json.JSONDecodeError as e:
            self._write_json(400, {"error": "invalid JSON body: %s" % e})
            return

        try:
            meta = load_model_meta()
        except Exception as e:
            self._write_json(503, {"error": "triton model metadata unavailable: %s" % e})
            return

        items = body.get("input")
        if isinstance(items, str):
            items = [items]
        if not items:
            self._write_json(400, {"error": '"input" must be a non-empty list of base64/data-URI images'})
            return

        results = []
        for idx, item in enumerate(items):
            try:
                img = decode_image(item)
            except Exception as e:
                self._write_json(400, {"error": "item %d is not decodable image data: %s" % (idx, e)})
                return

            arr = preprocess(img, meta["size"])
            if meta["layout"] == "NCHW":
                arr = arr.transpose(2, 0, 1)
            arr = arr.astype(meta["numpy_dtype"])
            infer_payload = {
                "inputs": [{
                    "name": meta["input_name"],
                    "shape": [1] + list(arr.shape),
                    "datatype": meta["datatype"],
                    "data": arr.reshape(-1).tolist(),
                }],
                "outputs": [{"name": meta["output_name"]}],
            }
            try:
                resp = _triton_post_json("/v2/models/%s/infer" % meta["name"], infer_payload)
            except urllib.error.HTTPError as e:
                self._write_json(502, {"error": "triton infer failed: %s" % e.read().decode(errors="replace")})
                return
            except Exception as e:
                self._write_json(502, {"error": "triton infer failed: %s" % e})
                return

            out = resp["outputs"][0]["data"]
            vec = np.array(out, dtype=np.float32)
            norm = np.linalg.norm(vec)
            if norm > 0:
                vec = vec / norm
            results.append({"object": "embedding", "index": idx, "embedding": vec.tolist()})

        self._write_json(200, {
            "object": "list",
            "data": results,
            "model": meta["name"],
            "usage": {"prompt_tokens": 0, "total_tokens": 0},
        })


if __name__ == "__main__":
    server = ThreadingHTTPServer(("0.0.0.0", LISTEN_PORT), Handler)
    sys.stderr.write("nvclip-adapter listening on :%d, proxying triton at %s\n" % (LISTEN_PORT, TRITON_URL))
    server.serve_forever()
