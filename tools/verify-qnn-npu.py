#!/usr/bin/env python3
import os
import tempfile
from pathlib import Path

import numpy as np
import onnx
import onnxruntime as ort
import onnxruntime_qnn as qnn
from onnx import TensorProto, helper


with tempfile.TemporaryDirectory() as directory:
    model_path = Path(directory) / "abs.onnx"
    graph = helper.make_graph(
        [helper.make_node("Abs", ["input"], ["output"])],
        "qnn_hardware_check",
        [helper.make_tensor_value_info("input", TensorProto.FLOAT, [1, 4])],
        [helper.make_tensor_value_info("output", TensorProto.FLOAT, [1, 4])],
    )
    model = helper.make_model(graph, opset_imports=[helper.make_opsetid("", 13)])
    model.ir_version = 8
    onnx.checker.check_model(model)
    onnx.save(model, model_path)

    ort.register_execution_provider_library("QNNExecutionProvider", qnn.get_library_path())
    devices = [
        device
        for device in ort.get_ep_devices()
        if device.ep_name == "QNNExecutionProvider"
        and device.device.type == ort.OrtHardwareDeviceType.NPU
    ]
    assert devices, "QNN did not register a Qualcomm NPU"

    options = ort.SessionOptions()
    options.log_severity_level = int(os.environ.get("ORT_LOG_SEVERITY", "3"))
    provider_options = {"backend_path": qnn.get_qnn_htp_path()}
    if soc_model := os.environ.get("QNN_SOC_MODEL"):
        provider_options["soc_model"] = soc_model
    if htp_arch := os.environ.get("QNN_HTP_ARCH"):
        provider_options["htp_arch"] = htp_arch
    options.add_provider_for_devices(devices, provider_options)
    options.add_session_config_entry("session.disable_cpu_ep_fallback", "1")
    session = ort.InferenceSession(model_path, sess_options=options)
    session.disable_fallback()

    source = np.array([[-1.0, 2.0, -3.5, 4.25]], dtype=np.float32)
    result = session.run(None, {"input": source})[0]
    np.testing.assert_array_equal(result, np.abs(source))

print(f"PASS: QNN HTP/NPU inference with CPU fallback disabled (ORT {ort.__version__})")
