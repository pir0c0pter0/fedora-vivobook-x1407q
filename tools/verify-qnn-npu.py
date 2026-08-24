#!/usr/bin/env python3
"""Verifica inferencia real no HTP/NPU via QNN, sem fallback silencioso para CPU."""
import os
import sys
import tempfile
from pathlib import Path

import numpy as np
import onnx
import onnxruntime as ort
import onnxruntime_qnn as qnn
from onnx import TensorProto, helper

SOC_ID_PATH = Path("/sys/devices/soc0/soc_id")
# libQnnHtp.so le esse sysfs e aborta em logCreate quando o id nao esta na tabela
# interna. 555 = X1E80100 (o QNN o chama de SC8380XP); o X1P42100 real (635) nao
# esta la. Nao existe env var de override na lib, dai o shim LD_PRELOAD.
QNN_KNOWN_SOC_IDS = {"555"}
SOC_ID_SHIM = "/usr/local/lib64/qnn_soc_id_fix.so"


def read_soc_id():
    try:
        return SOC_ID_PATH.read_text().strip()
    except OSError as error:
        return f"<ilegivel: {error.strerror}>"


soc_id = read_soc_id()
# O shim pode interceptar uma chamada libc que o Python nao usa para ler o sysfs,
# entao sua presenca no LD_PRELOAD ja conta como override ativo.
shim_preloaded = "qnn_soc_id_fix" in os.environ.get("LD_PRELOAD", "")

if soc_id not in QNN_KNOWN_SOC_IDS and not shim_preloaded:
    print(
        f"SKIP: soc_id={soc_id} nao e reconhecido pelo libQnnHtp.so "
        f"(esperado um de {sorted(QNN_KNOWN_SOC_IDS)}).\n"
        "Sem o override o QNN aborta em logCreate antes de tocar o DSP.\n"
        f"Rode via 'tools/npu-run tools/verify-qnn-npu.py', que injeta {SOC_ID_SHIM}\n"
        "por LD_PRELOAD — este script nao pode se auto-preload (LD_PRELOAD precisa\n"
        "estar setado antes do processo iniciar).",
        file=sys.stderr,
    )
    raise SystemExit(2)

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
    # O HTP quantiza internamente: o erro medido e ~4.7e-07. Igualdade exata
    # reprova um resultado correto da NPU.
    np.testing.assert_allclose(result, np.abs(source), rtol=1e-5, atol=1e-5)

print(
    f"PASS: inferencia HTP/NPU com fallback de CPU desabilitado "
    f"(ORT {ort.__version__}, NPU devices: {len(devices)}, soc_id: {soc_id}"
    f"{', shim LD_PRELOAD ativo' if shim_preloaded else ''})\n"
    f"      resultado: {result.tolist()}"
)
