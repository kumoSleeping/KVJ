// Windows: Media Foundation Source Reader. With a D3D11 device manager the
// decoder runs on the GPU and the video processor scales and converts to RGB32
// there, so only the chosen output size is read back. Without a usable GPU the
// same reader decodes and scales in software.

#include "../../Decoder.h"

#include <windows.h>
#include <d3d11_4.h>
#include <dxgi.h>
#include <mfapi.h>
#include <mferror.h>
#include <mfidl.h>
#include <mfreadwrite.h>
#include <propvarutil.h>
#include <wrl/client.h>

#include <QRect>

#include <algorithm>
#include <cstdlib>
#include <cstring>
#include <iterator>
#include <string>

using Microsoft::WRL::ComPtr;

namespace {

QString hresultText(const char *what, HRESULT hr)
{
    return QStringLiteral("%1失败（0x%2）").arg(QString::fromUtf8(what)).arg(quint32(hr), 8, 16, QLatin1Char('0'));
}

constexpr DWORD kVideo = DWORD(MF_SOURCE_READER_FIRST_VIDEO_STREAM);

class MfDecoder final : public Decoder
{
public:
    ~MfDecoder() override
    {
        m_reader.Reset();
        m_manager.Reset();
        m_device.Reset();
        if (m_started)
            MFShutdown();
        if (m_com)
            CoUninitialize();
    }

    bool open(const QString &path, const DecodeOptions &options, QString *error) override
    {
        m_com = SUCCEEDED(CoInitializeEx(nullptr, COINIT_MULTITHREADED));
        HRESULT hr = MFStartup(MF_VERSION, MFSTARTUP_LITE);
        if (FAILED(hr)) {
            *error = hresultText("启动 Media Foundation", hr);
            return false;
        }
        m_started = true;
        // Hardware first; a machine without a usable GPU path decodes in software.
        if (createGpu() && openReader(path, options, true))
            return true;
        m_reader.Reset();
        m_manager.Reset();
        m_device.Reset();
        if (openReader(path, options, false))
            return true;
        *error = m_error;
        return false;
    }

    bool seek(double seconds) override
    {
        PROPVARIANT position;
        InitPropVariantFromInt64(LONGLONG(std::max(0.0, seconds) * 1e7), &position);
        const HRESULT hr = m_reader->SetCurrentPosition(GUID_NULL, position);
        PropVariantClear(&position);
        if (FAILED(hr)) {
            m_error = hresultText("定位视频", hr);
            return false;
        }
        return true;
    }

    bool next(VideoFrame *frame, double discardBefore) override
    {
        for (;;) {
            DWORD flags = 0;
            LONGLONG timestamp = 0;
            ComPtr<IMFSample> sample;
            HRESULT hr = m_reader->ReadSample(kVideo, 0, nullptr, &flags, &timestamp, &sample);
            if (FAILED(hr)) {
                m_error = hresultText("解码视频", hr);
                return false;
            }
            if (flags & MF_SOURCE_READERF_ENDOFSTREAM)
                return false;
            if ((flags & MF_SOURCE_READERF_CURRENTMEDIATYPECHANGED) && !readFormat())
                return false;
            if (!sample)
                continue;
            // Catching up from a keyframe: skip the conversion and the read-back.
            if (double(timestamp) / 1e7 < discardBefore)
                continue;
            ComPtr<IMFMediaBuffer> buffer;
            if (FAILED(sample->GetBufferByIndex(0, &buffer)) && FAILED(sample->ConvertToContiguousBuffer(&buffer)))
                continue;
            prepareImage(frame->image, m_area.size());
            if (!copy(buffer.Get(), &frame->image))
                continue;
            frame->pts = double(timestamp) / 1e7;
            return true;
        }
    }

    double duration() const override { return m_duration; }
    QString error() const override { return m_error; }
    QSize sourceSize() const override { return m_natural; }
    double frameRate() const override { return m_frameRate; }

private:
    bool createGpu()
    {
        const D3D_FEATURE_LEVEL levels[] = {D3D_FEATURE_LEVEL_11_1, D3D_FEATURE_LEVEL_11_0,
                                            D3D_FEATURE_LEVEL_10_1, D3D_FEATURE_LEVEL_10_0};
        HRESULT hr = D3D11CreateDevice(nullptr, D3D_DRIVER_TYPE_HARDWARE, nullptr,
                                       D3D11_CREATE_DEVICE_VIDEO_SUPPORT | D3D11_CREATE_DEVICE_BGRA_SUPPORT,
                                       levels, UINT(std::size(levels)), D3D11_SDK_VERSION,
                                       &m_device, nullptr, nullptr);
        if (FAILED(hr))
            return false;
        // Without a real GPU, D3D11 falls back to the Basic Render Driver, whose
        // emulated video processing is slower than Media Foundation's software path.
        ComPtr<IDXGIDevice> dxgi;
        ComPtr<IDXGIAdapter> adapter;
        DXGI_ADAPTER_DESC desc{};
        if (SUCCEEDED(m_device.As(&dxgi)) && SUCCEEDED(dxgi->GetAdapter(&adapter))
            && SUCCEEDED(adapter->GetDesc(&desc)) && desc.VendorId == 0x1414 && desc.DeviceId == 0x8c)
            return false;
        // Media Foundation uses the device from its own threads.
        ComPtr<ID3D11Multithread> multithread;
        if (SUCCEEDED(m_device.As(&multithread)))
            multithread->SetMultithreadProtected(TRUE);
        UINT token = 0;
        if (FAILED(MFCreateDXGIDeviceManager(&token, &m_manager)))
            return false;
        return SUCCEEDED(m_manager->ResetDevice(m_device.Get(), token));
    }

    bool openReader(const QString &path, const DecodeOptions &options, bool gpu)
    {
        ComPtr<IMFAttributes> attributes;
        MFCreateAttributes(&attributes, 3);
        attributes->SetUINT32(MF_SOURCE_READER_ENABLE_ADVANCED_VIDEO_PROCESSING, TRUE);
        attributes->SetUINT32(MF_READWRITE_ENABLE_HARDWARE_TRANSFORMS, gpu ? TRUE : FALSE);
        if (gpu)
            attributes->SetUnknown(MF_SOURCE_READER_D3D_MANAGER, m_manager.Get());
        const std::wstring url = path.toStdWString();
        m_reader.Reset();
        HRESULT hr = MFCreateSourceReaderFromURL(url.c_str(), attributes.Get(), &m_reader);
        if (FAILED(hr)) {
            m_error = hresultText("打开视频", hr);
            return false;
        }
        m_reader->SetStreamSelection(DWORD(MF_SOURCE_READER_ALL_STREAMS), FALSE);
        if (FAILED(m_reader->SetStreamSelection(kVideo, TRUE))) {
            m_error = QStringLiteral("文件里没有视频轨");
            return false;
        }
        ComPtr<IMFMediaType> native;
        UINT32 width = 0, height = 0;
        if (SUCCEEDED(m_reader->GetNativeMediaType(kVideo, 0, &native))) {
            MFGetAttributeSize(native.Get(), MF_MT_FRAME_SIZE, &width, &height);
            UINT32 frames = 0, seconds = 0;
            if (SUCCEEDED(MFGetAttributeRatio(native.Get(), MF_MT_FRAME_RATE, &frames, &seconds)) && seconds > 0)
                m_frameRate = double(frames) / seconds;
        }
        m_natural = QSize(int(width), int(height));
        const QSize target = scaledSize(width, height, options.maxHeight);

        ComPtr<IMFMediaType> type;
        MFCreateMediaType(&type);
        type->SetGUID(MF_MT_MAJOR_TYPE, MFMediaType_Video);
        type->SetGUID(MF_MT_SUBTYPE, MFVideoFormat_RGB32);
        if (!target.isEmpty()) {
            MFSetAttributeSize(type.Get(), MF_MT_FRAME_SIZE, UINT32(target.width()), UINT32(target.height()));
            MFSetAttributeRatio(type.Get(), MF_MT_PIXEL_ASPECT_RATIO, 1, 1);
        }
        hr = m_reader->SetCurrentMediaType(kVideo, nullptr, type.Get());
        if (FAILED(hr) && !target.isEmpty()) {
            // Some processors refuse a size; take the source size rather than fail.
            type->DeleteItem(MF_MT_FRAME_SIZE);
            type->DeleteItem(MF_MT_PIXEL_ASPECT_RATIO);
            hr = m_reader->SetCurrentMediaType(kVideo, nullptr, type.Get());
        }
        if (FAILED(hr)) {
            m_error = hresultText("设置视频输出格式", hr);
            return false;
        }
        if (!readFormat())
            return false;
        PROPVARIANT value;
        PropVariantInit(&value);
        if (SUCCEEDED(m_reader->GetPresentationAttribute(DWORD(MF_SOURCE_READER_MEDIASOURCE), MF_PD_DURATION, &value)))
            m_duration = double(value.uhVal.QuadPart) / 1e7;
        PropVariantClear(&value);
        return true;
    }

    bool readFormat()
    {
        ComPtr<IMFMediaType> current;
        HRESULT hr = m_reader->GetCurrentMediaType(kVideo, &current);
        if (FAILED(hr)) {
            m_error = hresultText("读取视频格式", hr);
            return false;
        }
        UINT32 width = 0, height = 0;
        MFGetAttributeSize(current.Get(), MF_MT_FRAME_SIZE, &width, &height);
        if (width == 0 || height == 0) {
            m_error = QStringLiteral("视频尺寸无效");
            return false;
        }
        m_height = height;
        LONG stride = 0;
        if (FAILED(current->GetUINT32(MF_MT_DEFAULT_STRIDE, reinterpret_cast<UINT32 *>(&stride))))
            MFGetStrideForBitmapInfoHeader(MFVideoFormat_RGB32.Data1, width, &stride);
        m_stride = stride;
        // Decoders pad frames (1080 → 1088); show only the display aperture.
        m_area = QRect(0, 0, int(width), int(height));
        MFVideoArea area{};
        if (SUCCEEDED(current->GetBlob(MF_MT_MINIMUM_DISPLAY_APERTURE, reinterpret_cast<UINT8 *>(&area), sizeof(area), nullptr))) {
            const QRect aperture(area.OffsetX.value, area.OffsetY.value, area.Area.cx, area.Area.cy);
            if (aperture.width() > 0 && aperture.height() > 0 && QRect(0, 0, int(width), int(height)).contains(aperture))
                m_area = aperture;
        }
        return true;
    }

    bool copy(IMFMediaBuffer *buffer, QImage *image)
    {
        BYTE *scan0 = nullptr;
        LONG pitch = 0;
        ComPtr<IMF2DBuffer> buffer2d;
        bool locked2d = false;
        BYTE *data = nullptr;
        DWORD length = 0;
        // A 2D buffer (also a GPU surface, read back here) reports the first row
        // in display order and a signed pitch.
        if (SUCCEEDED(buffer->QueryInterface(IID_PPV_ARGS(&buffer2d))) && SUCCEEDED(buffer2d->Lock2D(&scan0, &pitch))) {
            locked2d = true;
        } else if (SUCCEEDED(buffer->Lock(&data, nullptr, &length))) {
            pitch = m_stride;
            scan0 = pitch < 0 ? data + std::abs(pitch) * LONG(m_height - 1) : data;
            if (DWORD(std::abs(pitch)) * m_height > length) {
                buffer->Unlock();
                return false;
            }
        } else {
            return false;
        }
        const int rows = m_area.height();
        const int pixels = m_area.width();
        for (int y = 0; y < rows; ++y) {
            const BYTE *source = scan0 + LONG(y + m_area.y()) * pitch + m_area.x() * 4;
            auto *target = reinterpret_cast<quint32 *>(image->scanLine(y));
            std::memcpy(target, source, size_t(pixels) * 4);
            // RGB32 leaves the X byte undefined; Qt expects it opaque.
            for (int x = 0; x < pixels; ++x)
                target[x] |= 0xff000000u;
        }
        if (locked2d)
            buffer2d->Unlock2D();
        else
            buffer->Unlock();
        return true;
    }

    ComPtr<ID3D11Device> m_device;
    ComPtr<IMFDXGIDeviceManager> m_manager;
    ComPtr<IMFSourceReader> m_reader;
    bool m_com = false;
    bool m_started = false;
    UINT32 m_height = 0;
    LONG m_stride = 0;
    QRect m_area;
    double m_duration = 0;
    double m_frameRate = 0;
    QSize m_natural;
    QString m_error;
};

} // namespace

std::unique_ptr<Decoder> createDecoder()
{
    return std::make_unique<MfDecoder>();
}
