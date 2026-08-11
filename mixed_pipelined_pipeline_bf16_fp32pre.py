"""ORT INT8 PRE + FPGA + NCNN POST with PRE/FPGA overlap support."""
from __future__ import annotations

import time
from pathlib import Path

import numpy as np
import torch

from hw.hw_driver import Model6Fpga
from sw.hybrid_pipeline import letterbox


class MixedPipelinedPipeline:
    def __init__(
        self,
        weights,
        calib_path,
        graph_dir="models/onnx",
        imgsz=640,
        conf=0.5,
        iou=0.45,
        threads=4,
    ):
        import ncnn
        import onnxruntime as ort
        from ultralytics import YOLO

        self.ncnn = ncnn
        self.imgsz = imgsz
        self.conf = conf
        self.iou = iou
        self.names = YOLO(str(weights)).model.names

        graph_dir = Path(graph_dir)
        # FPGA Model.6 INT8 scales
        # These are the original parameters already fixed in
        # design/model6_params.h by the FPGA design team.
        # No calibration is performed in this runtime.
        self.hw_in_scale = 0.0389917693   # S_IN
        self.s_cat = 0.0553356526         # S_CAT
# ORT INT8 PRE
        opt = ort.SessionOptions()
        opt.graph_optimization_level = (
            ort.GraphOptimizationLevel.ORT_ENABLE_ALL
        )
        opt.intra_op_num_threads = threads
        opt.inter_op_num_threads = 1
        opt.execution_mode = ort.ExecutionMode.ORT_SEQUENTIAL

        try:
            opt.add_session_config_entry(
                "session.intra_op.allow_spinning",
                "0",
            )
        except Exception:
            pass

        self.pre = ort.InferenceSession(
            str(graph_dir / "pre_model6.onnx"),
            opt,
            providers=["CPUExecutionProvider"],
        )

        self.pre_input_name = self.pre.get_inputs()[0].name

        # NCNN FP32 POST
        self.post = ncnn.Net()
        self.post.opt.use_vulkan_compute = False
        self.post.opt.num_threads = threads
        self.post.opt.use_bf16_storage = True

        if self.post.load_param(
            str(graph_dir / "post_model6.ncnn.param")
        ) != 0:
            raise RuntimeError("ncnn post param load failed")

        if self.post.load_model(
            str(graph_dir / "post_model6.ncnn.bin")
        ) != 0:
            raise RuntimeError("ncnn post model load failed")

        self.fpga = Model6Fpga()

        print(f"MODEL NAMES: {self.names}")
        print(
            "MODEL6 backend: "
            "PIPELINED ORT INT8 PRE + FPGA + NCNN BF16 POST"
        )

    def close(self):
        self.fpga.close()

    def pre_stage(self, bgr):
        # -------------------------
        # image preprocessing
        # -------------------------
        t0 = time.monotonic()

        image, ratio, dx, dy = letterbox(
            bgr,
            self.imgsz,
        )

        rgb = np.ascontiguousarray(
            image[:, :, ::-1].transpose(2, 0, 1)
        )

        image_f32 = np.ascontiguousarray(
            rgb[None].astype(np.float32) / 255.0
        )

        prep_time = time.monotonic() - t0

        # -------------------------
        # ORT INT8 PRE
        # -------------------------
        t0 = time.monotonic()

        feature, skip4 = self.pre.run(
            None,
            {
                self.pre_input_name: image_f32,
            },
        )

        pre_time = time.monotonic() - t0

        feature = np.ascontiguousarray(feature[0])
        skip4 = np.ascontiguousarray(skip4[0])

        meta = {
            "ratio": ratio,
            "dx": dx,
            "dy": dy,
            "width": bgr.shape[1],
            "height": bgr.shape[0],
        }

        return (
            feature,
            skip4,
            meta,
            prep_time,
            pre_time,
        )

    def fpga_stage(self, feature):
        # IMPORTANT:
        # public Python -> driver boundary stays CHW
        t0 = time.monotonic()

        q = np.clip(
            np.rint(
                feature / self.hw_in_scale
            ),
            -128,
            127,
        ).astype(np.int8)

        payload = np.ascontiguousarray(q)

        raw = self.fpga.run(payload)

        # Driver output is raw HWC
        hwc = raw.reshape(
            40,
            40,
            256,
        ).astype(np.float32)

        fpga_output = (
            np.ascontiguousarray(
                hwc.transpose(2, 0, 1)
            )
            * self.s_cat
        )

        fpga_time = time.monotonic() - t0

        return fpga_output, fpga_time

    def post_stage(
        self,
        fpga_output,
        skip4,
        meta,
    ):
        try:
            from ultralytics.utils.nms import (
                non_max_suppression,
            )
        except ImportError:
            from ultralytics.yolo.utils.ops import (
                non_max_suppression,
            )

        # -------------------------
        # NCNN FP32 POST
        # -------------------------
        t0 = time.monotonic()

        ex = self.post.create_extractor()

        ex.input(
            "in0",
            self.ncnn.Mat(
                np.ascontiguousarray(fpga_output)
            ),
        )

        ex.input(
            "in1",
            self.ncnn.Mat(
                np.ascontiguousarray(skip4)
            ),
        )

        ret, pred_mat = ex.extract("out0")

        if ret != 0:
            raise RuntimeError(
                f"ncnn post extract failed: {ret}"
            )

        prediction = np.array(
            pred_mat,
            dtype=np.float32,
        )

        if prediction.shape == (8400, 14):
            prediction = prediction.T

        if prediction.shape == (14, 8400):
            prediction = prediction[None]

        if prediction.shape != (1, 14, 8400):
            raise RuntimeError(
                f"unexpected prediction shape "
                f"{prediction.shape}"
            )

        post_time = time.monotonic() - t0

        # -------------------------
        # NMS
        # -------------------------
        t0 = time.monotonic()

        detections = non_max_suppression(
            torch.from_numpy(
                prediction.copy()
            ),
            self.conf,
            self.iou,
            nc=len(self.names),
        )[0]

        nms_time = time.monotonic() - t0

        # letterbox coordinates -> camera coordinates
        if len(detections):
            ratio = meta["ratio"]
            dx = meta["dx"]
            dy = meta["dy"]

            detections[:, [0, 2]] = (
                detections[:, [0, 2]] - dx
            ) / ratio

            detections[:, [1, 3]] = (
                detections[:, [1, 3]] - dy
            ) / ratio

            detections[:, [0, 2]] = (
                detections[:, [0, 2]]
                .clamp(0, meta["width"])
            )

            detections[:, [1, 3]] = (
                detections[:, [1, 3]]
                .clamp(0, meta["height"])
            )

        return detections, post_time, nms_time
