#include "windows_midi2.h"

#include <new>
#include <windows.h>
#include <winrt/Windows.Foundation.h>
#include <winrt/Windows.Foundation.Collections.h>
#include <winrt/Microsoft.Windows.Devices.Midi2.h>

namespace midi2 = winrt::Microsoft::Windows::Devices::Midi2;

extern "C" HRESULT WINAPI RoGetActivationFactory(void *class_id, GUID const &interface_id,
                                                   void **factory) noexcept {
    using Function = HRESULT(WINAPI *)(void *, GUID const &, void **);
    static auto function = reinterpret_cast<Function>(
        GetProcAddress(LoadLibraryW(L"combase.dll"), "RoGetActivationFactory"));
    return function ? function(class_id, interface_id, factory) : E_NOTIMPL;
}

extern "C" BOOL WINAPI RoOriginateLanguageException(HRESULT error, void *message,
                                                      void *exception) noexcept {
    using Function = BOOL(WINAPI *)(HRESULT, void *, void *);
    static auto function = reinterpret_cast<Function>(
        GetProcAddress(LoadLibraryW(L"combase.dll"), "RoOriginateLanguageException"));
    return function ? function(error, message, exception) : FALSE;
}

struct IMidiClientInitializer : IUnknown {
    virtual HRESULT __stdcall GetInstalledWindowsMidiServicesSdkVersion(
        uint32_t *, uint16_t *, uint16_t *, uint16_t *, wchar_t **, wchar_t **, wchar_t **) = 0;
    virtual HRESULT __stdcall EnsureServiceAvailable() = 0;
};

static constexpr GUID midi_client_initializer_class =
    {0xc3263827, 0xc3b0, 0xbdbd, {0x25, 0x00, 0xce, 0x63, 0xa3, 0xf3, 0xf2, 0xc3}};
static constexpr GUID midi_client_initializer_interface =
    {0x8087b303, 0xd551, 0xbce2, {0x1e, 0xad, 0xa2, 0x50, 0x0d, 0x50, 0xc5, 0x80}};

struct WstudioMidi2Handle {
    IMidiClientInitializer *initializer{nullptr};
    midi2::MidiSession session{nullptr};
    midi2::MidiEndpointConnection connection{nullptr};
    winrt::event_token message_token{};
    bool message_registered{false};
    bool apartment_initialized{false};
};

static bool initialize(WstudioMidi2Handle &handle) noexcept {
    try {
        winrt::init_apartment(winrt::apartment_type::multi_threaded);
        handle.apartment_initialized = true;
        if (FAILED(CoCreateInstance(midi_client_initializer_class, nullptr,
                                    CLSCTX_INPROC_SERVER | CLSCTX_FROM_DEFAULT_CONTEXT,
                                    midi_client_initializer_interface,
                                    reinterpret_cast<void **>(&handle.initializer)))) return false;
        return SUCCEEDED(handle.initializer->EnsureServiceAvailable());
    } catch (...) {
        return false;
    }
}

extern "C" void *wstudio_midi2_open(const uint16_t *endpoint_id, uint32_t endpoint_id_len,
                                     wstudio_midi2_message_callback callback, void *context) {
    if (!callback) return nullptr;
    auto *handle = new (std::nothrow) WstudioMidi2Handle;
    if (!handle) return nullptr;
    try {
        if (!initialize(*handle)) throw winrt::hresult_error(E_FAIL);
        handle->session = midi2::MidiSession::Create(L"wstudio");
        winrt::hstring selected_id;
        if (endpoint_id && endpoint_id_len > 0) {
            selected_id = winrt::hstring(reinterpret_cast<const wchar_t *>(endpoint_id), endpoint_id_len);
        } else {
            auto endpoints = midi2::MidiEndpointDeviceInformation::FindAll(
                midi2::MidiEndpointDeviceInformationSortOrder::Name,
                midi2::MidiEndpointDeviceInformationFilters::AllStandardEndpoints);
            if (endpoints.Size() == 0) throw winrt::hresult_error(E_FAIL);
            selected_id = endpoints.GetAt(0).EndpointDeviceId();
        }
        handle->connection = handle->session.CreateEndpointConnection(
            selected_id);
        if (!handle->connection) throw winrt::hresult_error(E_FAIL);
        handle->message_token = handle->connection.MessageReceived(
            [callback, context](midi2::IMidiMessageReceivedEventSource const &,
                                midi2::MidiMessageReceivedEventArgs const &args) {
                uint32_t words[4]{};
                if (!args.FillWords(words[0], words[1], words[2], words[3])) return;
                uint32_t count = static_cast<uint32_t>(args.PacketType());
                if (count >= 1 && count <= 4) callback(context, words, count);
            });
        handle->message_registered = true;
        if (!handle->connection.Open()) throw winrt::hresult_error(E_FAIL);
        return handle;
    } catch (...) {
        wstudio_midi2_close(handle);
        return nullptr;
    }
}

extern "C" void wstudio_midi2_close(void *opaque) {
    auto *handle = static_cast<WstudioMidi2Handle *>(opaque);
    if (!handle) return;
    try {
        if (handle->connection) {
            if (handle->message_registered) handle->connection.MessageReceived(handle->message_token);
            handle->connection.as<winrt::Windows::Foundation::IClosable>().Close();
        }
        if (handle->session) handle->session.Close();
    } catch (...) {
    }
    handle->connection = nullptr;
    handle->session = nullptr;
    if (handle->initializer) handle->initializer->Release();
    if (handle->apartment_initialized) winrt::uninit_apartment();
    delete handle;
}

extern "C" int wstudio_midi2_list(wstudio_midi2_device_callback callback, void *context) {
    if (!callback) return 0;
    WstudioMidi2Handle handle;
    try {
        if (!initialize(handle)) throw winrt::hresult_error(E_FAIL);
        auto endpoints = midi2::MidiEndpointDeviceInformation::FindAll(
            midi2::MidiEndpointDeviceInformationSortOrder::Name,
            midi2::MidiEndpointDeviceInformationFilters::AllStandardEndpoints);
        for (auto const &endpoint : endpoints) {
            auto id = endpoint.EndpointDeviceId();
            auto name = endpoint.Name();
            callback(context, reinterpret_cast<const uint16_t *>(id.c_str()), id.size(),
                     reinterpret_cast<const uint16_t *>(name.c_str()), name.size());
        }
        if (handle.initializer) {
            handle.initializer->Release();
            handle.initializer = nullptr;
        }
        winrt::uninit_apartment();
        handle.apartment_initialized = false;
        return 1;
    } catch (...) {
        if (handle.initializer) handle.initializer->Release();
        if (handle.apartment_initialized) winrt::uninit_apartment();
        return 0;
    }
}
