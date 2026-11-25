#include "flutter_window.h"

#include <flutter/standard_method_codec.h>

#include <cstdint>
#include <cstring>
#include <optional>
#include <variant>
#include <vector>

#include "flutter/generated_plugin_registrant.h"

namespace {

using flutter::EncodableMap;
using flutter::EncodableValue;

template <typename T>
const T* Argument(const EncodableMap& map, const char* key) {
  const auto found = map.find(EncodableValue(key));
  return found == map.end() ? nullptr : std::get_if<T>(&found->second);
}

// Gives |size| bytes to the open clipboard, which then owns them.
bool PutOnClipboard(UINT format, const void* data, size_t size) {
  HGLOBAL memory = GlobalAlloc(GMEM_MOVEABLE, size);
  if (!memory) {
    return false;
  }
  void* target = GlobalLock(memory);
  if (!target) {
    GlobalFree(memory);
    return false;
  }
  std::memcpy(target, data, size);
  GlobalUnlock(memory);
  if (!SetClipboardData(format, memory)) {
    GlobalFree(memory);
    return false;
  }
  return true;
}

// Copies a picture as PNG and as a plain bitmap, so that any app can paste it.
bool CopyImage(HWND window, const std::vector<uint8_t>& png,
               const std::vector<uint8_t>& rgba, int width, int height) {
  const size_t pixels = static_cast<size_t>(width) * height * 4;
  if (width <= 0 || height <= 0 || width > 8192 || height > 8192 ||
      png.empty() || rgba.size() != pixels) {
    return false;
  }
  BITMAPINFOHEADER header = {};
  header.biSize = sizeof(header);
  header.biWidth = width;
  header.biHeight = height;  // Positive: rows are stored bottom first.
  header.biPlanes = 1;
  header.biBitCount = 32;
  header.biCompression = BI_RGB;
  header.biSizeImage = static_cast<DWORD>(pixels);
  std::vector<uint8_t> bitmap(sizeof(header) + pixels);
  std::memcpy(bitmap.data(), &header, sizeof(header));
  uint8_t* out = bitmap.data() + sizeof(header);
  const size_t stride = static_cast<size_t>(width) * 4;
  for (int row = height - 1; row >= 0; --row) {
    const uint8_t* in = rgba.data() + stride * row;
    for (int column = 0; column < width; ++column, in += 4, out += 4) {
      out[0] = in[2];
      out[1] = in[1];
      out[2] = in[0];
      out[3] = 255;
    }
  }

  // Another app can briefly hold the clipboard.
  bool opened = false;
  for (int attempt = 0; attempt < 10 && !opened; ++attempt) {
    opened = OpenClipboard(window) != FALSE;
    if (!opened) {
      Sleep(20);
    }
  }
  if (!opened) {
    return false;
  }
  EmptyClipboard();
  const UINT png_format = RegisterClipboardFormatW(L"PNG");
  const bool copied =
      PutOnClipboard(CF_DIB, bitmap.data(), bitmap.size()) &&
      png_format != 0 &&
      PutOnClipboard(png_format, png.data(), png.size());
  CloseClipboard();
  return copied;
}

}  // namespace

FlutterWindow::FlutterWindow(const flutter::DartProject& project)
    : project_(project) {}

FlutterWindow::~FlutterWindow() {}

bool FlutterWindow::OnCreate() {
  if (!Win32Window::OnCreate()) {
    return false;
  }

  RECT frame = GetClientArea();

  // The size here must match the window dimensions to avoid unnecessary surface
  // creation / destruction in the startup path.
  flutter_controller_ = std::make_unique<flutter::FlutterViewController>(
      frame.right - frame.left, frame.bottom - frame.top, project_);
  // Ensure that basic setup of the controller was successful.
  if (!flutter_controller_->engine() || !flutter_controller_->view()) {
    return false;
  }
  RegisterPlugins(flutter_controller_->engine());
  receipt_channel_ =
      std::make_unique<flutter::MethodChannel<EncodableValue>>(
          flutter_controller_->engine()->messenger(), "sydex/receipt",
          &flutter::StandardMethodCodec::GetInstance());
  receipt_channel_->SetMethodCallHandler(
      [this](const flutter::MethodCall<EncodableValue>& call,
             std::unique_ptr<flutter::MethodResult<EncodableValue>> result) {
        if (call.method_name() != "copyImage") {
          result->NotImplemented();
          return;
        }
        const auto* map = std::get_if<EncodableMap>(call.arguments());
        if (!map) {
          result->Success(EncodableValue(false));
          return;
        }
        const auto* png = Argument<std::vector<uint8_t>>(*map, "png");
        const auto* rgba = Argument<std::vector<uint8_t>>(*map, "rgba");
        const auto* width = Argument<int32_t>(*map, "width");
        const auto* height = Argument<int32_t>(*map, "height");
        result->Success(EncodableValue(
            png && rgba && width && height &&
            CopyImage(GetHandle(), *png, *rgba, *width, *height)));
      });
  SetChildContent(flutter_controller_->view()->GetNativeWindow());

  flutter_controller_->engine()->SetNextFrameCallback([&]() {
    this->Show();
  });

  // Flutter can complete the first frame before the "show window" callback is
  // registered. The following call ensures a frame is pending to ensure the
  // window is shown. It is a no-op if the first frame hasn't completed yet.
  flutter_controller_->ForceRedraw();

  return true;
}

void FlutterWindow::OnDestroy() {
  receipt_channel_ = nullptr;
  if (flutter_controller_) {
    flutter_controller_ = nullptr;
  }

  Win32Window::OnDestroy();
}

LRESULT
FlutterWindow::MessageHandler(HWND hwnd, UINT const message,
                              WPARAM const wparam,
                              LPARAM const lparam) noexcept {
  // Give Flutter, including plugins, an opportunity to handle window messages.
  if (flutter_controller_) {
    std::optional<LRESULT> result =
        flutter_controller_->HandleTopLevelWindowProc(hwnd, message, wparam,
                                                      lparam);
    if (result) {
      return *result;
    }
  }

  switch (message) {
    case WM_FONTCHANGE:
      flutter_controller_->engine()->ReloadSystemFonts();
      break;
  }

  return Win32Window::MessageHandler(hwnd, message, wparam, lparam);
}
