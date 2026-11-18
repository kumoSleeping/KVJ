// Windows: a media file's sound decoded by Media Foundation (Source Reader),
// for what the engine's own decoders cannot read (SystemSound.h).

#include "../../SystemSound.h"

#include <windows.h>
#include <mfapi.h>
#include <mferror.h>
#include <mfidl.h>
#include <mfreadwrite.h>
#include <propvarutil.h>
#include <wrl/client.h>

#include <QString>

#include <string>
#include <vector>

using Microsoft::WRL::ComPtr;

namespace {

constexpr DWORD kAudio = DWORD(MF_SOURCE_READER_FIRST_AUDIO_STREAM);

// The speakers of a WAVEFORMATEXTENSIBLE channel mask, in channel order.
std::vector<Speaker> speakersOf(UINT32 mask, UINT32 channels)
{
    if (mask == 0) {
        // Not told: the usual order of the usual counts.
        if (channels == 6)
            mask = 0x3F; // 5.1: FL FR FC LFE BL BR
        else if (channels == 8)
            mask = 0x63F; // 7.1: and SL SR
        else
            return {};
    }
    std::vector<Speaker> speakers;
    for (int bit = 0; bit < 32 && speakers.size() < channels; ++bit) {
        if (!(mask & (1u << bit)))
            continue;
        switch (1u << bit) {
        case 0x1: case 0x40: speakers.push_back(Speaker::Left); break; // front left, front left of centre
        case 0x2: case 0x80: speakers.push_back(Speaker::Right); break;
        case 0x4: speakers.push_back(Speaker::Center); break;
        case 0x8: speakers.push_back(Speaker::Lfe); break;
        case 0x10: case 0x200: speakers.push_back(Speaker::LeftBack); break; // back left, side left
        case 0x20: case 0x400: speakers.push_back(Speaker::RightBack); break;
        case 0x100: speakers.push_back(Speaker::Back); break;
        default: speakers.push_back(Speaker::Other); break;
        }
    }
    if (speakers.size() != channels)
        return {};
    return speakers;
}

double read(const char *path, const char *wav)
{
    const std::wstring file = QString::fromUtf8(path).toStdWString();
    ComPtr<IMFSourceReader> reader;
    if (FAILED(MFCreateSourceReaderFromURL(file.c_str(), nullptr, &reader)))
        return 0;
    reader->SetStreamSelection(DWORD(MF_SOURCE_READER_ALL_STREAMS), FALSE);
    // No sound in the file: no first audio stream.
    if (FAILED(reader->SetStreamSelection(kAudio, TRUE)))
        return 0;
    // Float at its own rate and channels; failing, no decoder for it here.
    ComPtr<IMFMediaType> wanted;
    if (FAILED(MFCreateMediaType(&wanted)) || FAILED(wanted->SetGUID(MF_MT_MAJOR_TYPE, MFMediaType_Audio))
        || FAILED(wanted->SetGUID(MF_MT_SUBTYPE, MFAudioFormat_Float))
        || FAILED(reader->SetCurrentMediaType(kAudio, nullptr, wanted.Get())))
        return 0;
    ComPtr<IMFMediaType> type;
    if (FAILED(reader->GetCurrentMediaType(kAudio, &type)))
        return 0;
    const UINT32 rate = MFGetAttributeUINT32(type.Get(), MF_MT_AUDIO_SAMPLES_PER_SECOND, 0);
    const UINT32 channels = MFGetAttributeUINT32(type.Get(), MF_MT_AUDIO_NUM_CHANNELS, 0);
    const UINT32 mask = MFGetAttributeUINT32(type.Get(), MF_MT_AUDIO_CHANNEL_MASK, 0);
    if (rate == 0 || channels == 0)
        return 0;
    double length = 0;
    PROPVARIANT duration;
    PropVariantInit(&duration);
    if (SUCCEEDED(reader->GetPresentationAttribute(DWORD(MF_SOURCE_READER_MEDIASOURCE), MF_PD_DURATION, &duration))
        && duration.vt == VT_UI8)
        length = double(duration.uhVal.QuadPart) / 1e7;
    PropVariantClear(&duration);
    if (!wav)
        return length > 0 ? length : 1e-3;

    SoundWriter writer;
    if (!writer.open(wav, int(rate), int(channels), speakersOf(mask, channels), length))
        return 0;
    for (;;) {
        DWORD flags = 0;
        LONGLONG timestamp = 0;
        ComPtr<IMFSample> sample;
        if (FAILED(reader->ReadSample(kAudio, 0, nullptr, &flags, &timestamp, &sample)))
            return 0;
        if (flags & MF_SOURCE_READERF_ENDOFSTREAM)
            break;
        if (flags & (MF_SOURCE_READERF_CURRENTMEDIATYPECHANGED | MF_SOURCE_READERF_NATIVEMEDIATYPECHANGED)) {
            ComPtr<IMFMediaType> now;
            if (FAILED(reader->GetCurrentMediaType(kAudio, &now))
                || MFGetAttributeUINT32(now.Get(), MF_MT_AUDIO_SAMPLES_PER_SECOND, 0) != rate
                || MFGetAttributeUINT32(now.Get(), MF_MT_AUDIO_NUM_CHANNELS, 0) != channels)
                return 0;
        }
        if (!sample)
            continue;
        ComPtr<IMFMediaBuffer> buffer;
        if (FAILED(sample->ConvertToContiguousBuffer(&buffer)))
            continue;
        BYTE *data = nullptr;
        DWORD bytes = 0;
        if (FAILED(buffer->Lock(&data, nullptr, &bytes)))
            continue;
        writer.write(reinterpret_cast<const float *>(data), bytes / (sizeof(float) * channels), double(timestamp) / 1e7);
        buffer->Unlock();
    }
    return writer.finish() ? writer.seconds() : 0;
}

} // namespace

double systemSound(const char *path, const char *wav)
{
    // The engine's threads come uninitialised; the UI thread is already in an
    // apartment of its own (RPC_E_CHANGED_MODE), which serves as well.
    const HRESULT com = CoInitializeEx(nullptr, COINIT_MULTITHREADED);
    double seconds = 0;
    if (SUCCEEDED(MFStartup(MF_VERSION, MFSTARTUP_LITE))) {
        seconds = read(path, wav);
        MFShutdown();
    }
    if (SUCCEEDED(com))
        CoUninitialize();
    return seconds;
}
