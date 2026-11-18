#include "SystemSound.h"

#include "kvj.h"

#include <QDir>
#include <QString>

#include <algorithm>
#include <cmath>
#include <cstring>
#include <utility>

namespace {

// RIFF sizes are 32-bit: a file stops growing before that.
constexpr uint64_t kMostData = 0xFFFFFFFFull - 64;
// Past this many bytes as float, 16-bit instead (a sound of hours).
constexpr double kMostFloat = 3e9;

void putU16(unsigned char *at, uint16_t value)
{
    at[0] = value & 0xFF;
    at[1] = value >> 8;
}

void putU32(unsigned char *at, uint32_t value)
{
    for (int i = 0; i < 4; ++i)
        at[i] = (value >> (8 * i)) & 0xFF;
}

double convert(void *, const char *path, const char *wav)
{
    return systemSound(path, wav);
}

} // namespace

void useSystemSound(const QString &dir)
{
    QDir().mkpath(dir);
    kvj_sound_system(&convert, nullptr, QDir::toNativeSeparators(dir).toUtf8().constData());
}

SoundWriter::~SoundWriter()
{
    if (m_file)
        std::fclose(m_file);
}

bool SoundWriter::open(const char *path, int rate, int channels, const std::vector<Speaker> &speakers, double seconds)
{
    if (rate <= 0 || channels <= 0)
        return false;
    m_rate = rate;
    m_in = channels;
    m_out = channels == 1 ? 1 : 2;
    m_float = !(seconds > 0 && seconds * rate * m_out * 4 > kMostFloat);
    m_toLeft.assign(size_t(channels), 0);
    m_toRight.assign(size_t(channels), 0);
    if (channels == 1) {
        m_toLeft[0] = 1;
    } else if (!place(speakers)) {
        // Not told where they play (a file without a layout): the usual order of the usual counts,
        // else every channel to both sides; the first two alone may be silent (a mono sound
        // made 5.1 is all in the centre).
        using S = Speaker;
        const bool usual = (channels == 2 && place({S::Left, S::Right}))
            || (channels == 6 && place({S::Left, S::Right, S::Center, S::Lfe, S::LeftBack, S::RightBack}))
            || (channels == 8 && place({S::Left, S::Right, S::Center, S::Lfe, S::LeftBack, S::RightBack, S::LeftBack, S::RightBack}));
        if (!usual) {
            const float share = 1.f / std::sqrt(float(channels));
            std::fill(m_toLeft.begin(), m_toLeft.end(), share);
            std::fill(m_toRight.begin(), m_toRight.end(), share);
        }
    }

#ifdef _WIN32
    // The C library's narrow names are the ANSI code page's, not UTF-8.
    m_file = _wfopen(reinterpret_cast<const wchar_t *>(QString::fromUtf8(path).utf16()), L"wb");
#else
    m_file = std::fopen(path, "wb");
#endif
    if (!m_file)
        return false;
    // The header, its sizes written by finish().
    unsigned char header[44] = {};
    std::memcpy(header, "RIFF", 4);
    std::memcpy(header + 8, "WAVEfmt ", 8);
    putU32(header + 16, 16);
    putU16(header + 20, m_float ? 3 : 1);
    putU16(header + 22, uint16_t(m_out));
    putU32(header + 24, uint32_t(rate));
    const int bytes = m_float ? 4 : 2;
    putU32(header + 28, uint32_t(rate * m_out * bytes));
    putU16(header + 32, uint16_t(m_out * bytes));
    putU16(header + 34, uint16_t(bytes * 8));
    std::memcpy(header + 36, "data", 4);
    m_failed = std::fwrite(header, 1, sizeof header, m_file) != sizeof header;
    return !m_failed;
}

bool SoundWriter::place(const std::vector<Speaker> &speakers)
{
    if (int(speakers.size()) != m_in)
        return false;
    std::vector<float> left(size_t(m_in), 0.f), right(size_t(m_in), 0.f);
    constexpr float half = 0.70710678f;
    for (size_t c = 0; c < speakers.size(); ++c) {
        switch (speakers[c]) {
        case Speaker::Left: left[c] = 1; break;
        case Speaker::Right: right[c] = 1; break;
        case Speaker::Center: left[c] = right[c] = half; break;
        case Speaker::LeftBack: left[c] = half; break;
        case Speaker::RightBack: right[c] = half; break;
        case Speaker::Back: left[c] = right[c] = 0.5f; break;
        case Speaker::Lfe:
        case Speaker::Other: break;
        }
    }
    // Nothing on one side: the places say nothing of use (discrete channels).
    const auto none = [](const std::vector<float> &w) { return std::all_of(w.begin(), w.end(), [](float v) { return v == 0; }); };
    if (none(left) || none(right))
        return false;
    m_toLeft = std::move(left);
    m_toRight = std::move(right);
    return true;
}

void SoundWriter::put(const float *frame)
{
    float out[2] = {0, 0};
    for (int c = 0; c < m_in; ++c) {
        const float v = std::isfinite(frame[c]) ? frame[c] : 0.f;
        out[0] += v * m_toLeft[size_t(c)];
        out[1] += v * m_toRight[size_t(c)];
    }
    for (int c = 0; c < m_out; ++c) {
        if (m_float) {
            unsigned char b[4];
            std::memcpy(b, &out[c], 4);
            m_buffer.insert(m_buffer.end(), b, b + 4);
        } else {
            const long v = std::lround(std::clamp(out[c], -1.f, 1.f) * 32767.f);
            m_buffer.push_back(uint16_t(v) & 0xFF);
            m_buffer.push_back(uint16_t(v) >> 8);
        }
    }
}

void SoundWriter::silence(uint64_t frames)
{
    std::vector<float> zero(size_t(m_in), 0.f);
    const int bytes = m_float ? 4 : 2;
    while (frames > 0 && !m_failed) {
        const uint64_t n = std::min<uint64_t>(frames, 4096);
        if ((m_frames + n) * m_out * bytes > kMostData)
            return;
        m_buffer.clear();
        for (uint64_t i = 0; i < n; ++i)
            put(zero.data());
        m_failed = std::fwrite(m_buffer.data(), 1, m_buffer.size(), m_file) != m_buffer.size();
        m_frames += n;
        frames -= n;
    }
}

void SoundWriter::write(const float *interleaved, size_t frames, double at)
{
    if (!m_file || m_failed)
        return;
    // A gap of more than a few milliseconds (or a late start) is silence.
    if (std::isfinite(at) && at > 0) {
        const double start = at * m_rate;
        if (start > double(m_frames) + m_rate * 0.005)
            silence(uint64_t(std::llround(start)) - m_frames);
    }
    const int bytes = m_float ? 4 : 2;
    const uint64_t room = kMostData / (uint64_t(m_out) * bytes);
    frames = size_t(std::min<uint64_t>(frames, room > m_frames ? room - m_frames : 0));
    m_buffer.clear();
    m_buffer.reserve(frames * size_t(m_out * bytes));
    for (size_t i = 0; i < frames; ++i)
        put(interleaved + i * size_t(m_in));
    if (!m_buffer.empty())
        m_failed = std::fwrite(m_buffer.data(), 1, m_buffer.size(), m_file) != m_buffer.size();
    m_frames += frames;
}

bool SoundWriter::finish()
{
    if (!m_file)
        return false;
    const uint32_t data = uint32_t(m_frames * uint64_t(m_out) * (m_float ? 4 : 2));
    unsigned char size[4];
    putU32(size, 36 + data);
    m_failed = m_failed || std::fseek(m_file, 4, SEEK_SET) != 0 || std::fwrite(size, 1, 4, m_file) != 4;
    putU32(size, data);
    m_failed = m_failed || std::fseek(m_file, 40, SEEK_SET) != 0 || std::fwrite(size, 1, 4, m_file) != 4;
    m_failed = std::fclose(m_file) != 0 || m_failed;
    m_file = nullptr;
    return !m_failed && m_frames > 0;
}
