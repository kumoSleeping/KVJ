#pragma once

// Sound the engine's own decoders cannot read, read by the system's
// (AVFoundation on macOS, Media Foundation on Windows) into a WAV the engine
// then reads in its place (core/engine/src/system_sound.rs).

#include <cstddef>
#include <cstdint>
#include <cstdio>
#include <vector>

class QString;

// Seconds of sound the system reads in `path` (UTF-8), 0 when none. With a
// `wav` path it also writes that sound there: float (16-bit past 3 GB), mono
// or stereo (more channels are folded down), at its own rate, from the file's
// time 0. Any thread.
double systemSound(const char *path, const char *wav);

// Hands systemSound to the engine, its WAVs kept under `dir`. Before the
// engine reads anything.
void useSystemSound(const QString &dir);

// Where a channel plays.
enum class Speaker : unsigned char { Left, Right, Center, Lfe, LeftBack, RightBack, Back, Other };

// A sound's frames into a WAV, folded down to stereo (mono stays mono) by
// where each channel plays, and placed on the file's clock: frames that start
// later than those before end are preceded by silence.
class SoundWriter
{
public:
    ~SoundWriter();
    // `speakers` in channel order; empty or unknown, the first two channels
    // are taken as left and right. `seconds`, the expected length (0 unknown),
    // chooses float or 16-bit.
    bool open(const char *path, int rate, int channels, const std::vector<Speaker> &speakers, double seconds);
    // `frames` interleaved frames of all channels, the first at `at` seconds.
    void write(const float *interleaved, size_t frames, double at);
    // Writes the header's sizes; false if anything could not be written.
    bool finish();
    double seconds() const { return m_rate > 0 ? double(m_frames) / m_rate : 0; }

private:
    void put(const float *frame);
    void silence(uint64_t frames);

    std::FILE *m_file = nullptr;
    int m_rate = 0;
    int m_in = 0;
    int m_out = 0;
    bool m_float = true;
    bool m_failed = false;
    uint64_t m_frames = 0;
    // Each input channel's share of left and right.
    std::vector<float> m_toLeft;
    std::vector<float> m_toRight;
    std::vector<unsigned char> m_buffer;
};
