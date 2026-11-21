"""Convert facenet-pytorch InceptionResnetV1 (VGGFace2) to a Core ML model.

Input : RGB image 160x160 named "input" (normalisation baked in: (x - 127.5) / 128)
Output: 512-d embedding named "embedding" (L2-normalised; app normalises again)

Runs in CI on a macOS runner (coremltools has no Windows wheels).
"""
import argparse

import numpy as np
import torch
import torch.nn.functional as F
import coremltools as ct
from PIL import Image
from facenet_pytorch import InceptionResnetV1


def _l2norm(x, p=2.0, dim=1, eps=1e-12, out=None):
    # Simple ops only, so the converter never trips on aten::norm variants.
    return x / torch.sqrt((x * x).sum(dim=dim, keepdim=True) + eps)


F.normalize = _l2norm  # facenet_pytorch calls F.normalize at the end of forward()


def main():
    ap = argparse.ArgumentParser()
    ap.add_argument("--out", default="Models/FaceNet.mlpackage")
    args = ap.parse_args()

    model = InceptionResnetV1(pretrained="vggface2").eval()
    example = torch.rand(1, 3, 160, 160) * 2 - 1
    traced = torch.jit.trace(model, example)

    mlmodel = ct.convert(
        traced,
        inputs=[
            ct.ImageType(
                name="input",
                shape=example.shape,
                scale=1 / 128.0,
                bias=[-127.5 / 128.0] * 3,
                color_layout=ct.colorlayout.RGB,
            )
        ],
        outputs=[ct.TensorType(name="embedding")],
        convert_to="mlprogram",
        compute_precision=ct.precision.FLOAT16,
        minimum_deployment_target=ct.target.iOS16,
    )
    mlmodel.short_description = "FaceNet (InceptionResnetV1, VGGFace2) face embedding"
    mlmodel.save(args.out)
    print("saved", args.out)

    # Sanity check: Core ML output should match PyTorch output.
    rng = np.random.default_rng(0)
    arr = rng.integers(0, 255, size=(160, 160, 3), dtype=np.uint8)
    with torch.no_grad():
        t = torch.from_numpy((arr.astype(np.float32) - 127.5) / 128.0).permute(2, 0, 1)[None]
        ref = model(t).numpy()[0]
    try:
        got = mlmodel.predict({"input": Image.fromarray(arr)})["embedding"].reshape(-1)
        got = got / np.linalg.norm(got)
        cos = float(np.dot(ref, got))
        print(f"torch vs coreml cosine = {cos:.4f}")
        if cos < 0.98:
            raise SystemExit("Converted model does not match PyTorch output")
    except SystemExit:
        raise
    except Exception as e:  # predict needs macOS; don't fail conversion elsewhere
        print("skip predict check:", e)


if __name__ == "__main__":
    main()
