// ONNX Runtime 1.29 + QNN; HTP obrigatorio, sem fallback CPU.
#include "onnxruntime_cxx_api.h"
#include <cmath>
#include <cstdio>
#include <stdexcept>
#include <string>
#include <vector>

int main(int argc, char** argv) {
  if (argc != 2) {
    std::fprintf(stderr, "uso: %s abs.onnx\n", argv[0]);
    return 2;
  }
  try {
    Ort::Env env(ORT_LOGGING_LEVEL_VERBOSE, "yoga-npu");
    env.RegisterExecutionProviderLibrary("QNNExecutionProvider",
        "/opt/yoga-npu/lib/libonnxruntime_providers_qnn.so");
    std::vector<Ort::ConstEpDevice> devices;
    for (const auto& dev : env.GetEpDevices()) {
      std::printf("EP=%s device_type=%d\n", dev.EpName(), int(dev.Device().Type()));
      if (std::string(dev.EpName()) == "QNNExecutionProvider" &&
          dev.Device().Type() == OrtHardwareDeviceType_NPU)
        devices.push_back(dev);
    }
    if (devices.size() != 1) throw std::runtime_error("esperada uma NPU QNN");
    Ort::SessionOptions options;
    options.SetIntraOpNumThreads(1);
    options.AddConfigEntry("session.disable_cpu_ep_fallback", "1");
    options.EnableProfiling("yoga-npu-profile");
    options.AppendExecutionProvider_V2(env, devices, {
        {"backend_path", "/opt/yoga-npu/lib/libQnnHtp.so"},
        {"enable_htp_fp16_precision", "1"}});
    Ort::Session session(env, argv[1], options);
    float input[] = {-1, 2, -3.5f, 4.25f};
    const int64_t shape[] = {1, 4};
    auto mem = Ort::MemoryInfo::CreateCpu(OrtArenaAllocator, OrtMemTypeDefault);
    auto tensor = Ort::Value::CreateTensor<float>(mem, input, 4, shape, 2);
    const char* inputs[] = {"input"};
    const char* outputs[] = {"output"};
    for (int run = 0; run < 100; ++run) {
      for (size_t i = 0; i < 4; ++i)
        input[i] = ((run + int(i)) % 2 ? -1.0f : 1.0f) * (run + i) / 4.0f;
      auto result = session.Run(Ort::RunOptions{}, inputs, &tensor, 1, outputs, 1);
      auto info = result.at(0).GetTensorTypeAndShapeInfo();
      if (info.GetElementType() != ONNX_TENSOR_ELEMENT_DATA_TYPE_FLOAT ||
          info.GetShape() != std::vector<int64_t>({1, 4}))
        throw std::runtime_error("tipo/dimensoes de saida inesperados");
      const float* out = result[0].GetTensorData<float>();
      for (size_t i = 0; i < 4; ++i) {
        if (!std::isfinite(out[i]) || std::fabs(out[i] - std::fabs(input[i])) > 0.005f)
          throw std::runtime_error("resultado numerico incorreto");
      }
    }
    Ort::AllocatorWithDefaultOptions allocator;
    auto profile = session.EndProfilingAllocated(allocator);
    std::printf("PASS: 100 inferencias numericamente corretas; conferir QNN no perfil: %s\n", profile.get());
    return 0;
  } catch (const std::exception& e) {
    std::fprintf(stderr, "FAIL: %s\n", e.what());
    return 1;
  }
}
