// macOS: a media file's sound decoded by AVFoundation (AVAssetReader), for
// what the engine's own decoders cannot read (SystemSound.h).

#include "../../SystemSound.h"

#import <AVFoundation/AVFoundation.h>
#import <AudioToolbox/AudioToolbox.h>
#import <CoreMedia/CoreMedia.h>

#include <vector>

namespace {

Speaker speakerOf(AudioChannelLabel label)
{
    switch (label) {
    case kAudioChannelLabel_Left:
    case kAudioChannelLabel_LeftCenter:
    case kAudioChannelLabel_LeftWide:
    case kAudioChannelLabel_LeftTotal:
    case kAudioChannelLabel_HeadphonesLeft:
        return Speaker::Left;
    case kAudioChannelLabel_Right:
    case kAudioChannelLabel_RightCenter:
    case kAudioChannelLabel_RightWide:
    case kAudioChannelLabel_RightTotal:
    case kAudioChannelLabel_HeadphonesRight:
        return Speaker::Right;
    case kAudioChannelLabel_Center:
    case kAudioChannelLabel_Mono:
        return Speaker::Center;
    case kAudioChannelLabel_LFEScreen:
    case kAudioChannelLabel_LFE2:
        return Speaker::Lfe;
    case kAudioChannelLabel_LeftSurround:
    case kAudioChannelLabel_LeftSurroundDirect:
    case kAudioChannelLabel_RearSurroundLeft:
        return Speaker::LeftBack;
    case kAudioChannelLabel_RightSurround:
    case kAudioChannelLabel_RightSurroundDirect:
    case kAudioChannelLabel_RearSurroundRight:
        return Speaker::RightBack;
    case kAudioChannelLabel_CenterSurround:
        return Speaker::Back;
    default:
        return Speaker::Other;
    }
}

// The speakers of `layout` in channel order; empty when it does not say.
std::vector<Speaker> speakersOf(const AudioChannelLayout *layout, size_t size, int channels)
{
    if (!layout || size < offsetof(AudioChannelLayout, mChannelDescriptions))
        return {};
    std::vector<char> expanded;
    if (layout->mChannelLayoutTag != kAudioChannelLayoutTag_UseChannelDescriptions) {
        // Told by a tag or a bitmap: the system spells it out.
        const AudioFormatPropertyID property = layout->mChannelLayoutTag == kAudioChannelLayoutTag_UseChannelBitmap
            ? kAudioFormatProperty_ChannelLayoutForBitmap
            : kAudioFormatProperty_ChannelLayoutForTag;
        const void *specifier = layout->mChannelLayoutTag == kAudioChannelLayoutTag_UseChannelBitmap
            ? static_cast<const void *>(&layout->mChannelBitmap)
            : static_cast<const void *>(&layout->mChannelLayoutTag);
        UInt32 bytes = 0;
        if (AudioFormatGetPropertyInfo(property, sizeof(UInt32), specifier, &bytes) != noErr || bytes == 0)
            return {};
        expanded.resize(bytes);
        if (AudioFormatGetProperty(property, sizeof(UInt32), specifier, &bytes, expanded.data()) != noErr)
            return {};
        layout = reinterpret_cast<const AudioChannelLayout *>(expanded.data());
    }
    if (int(layout->mNumberChannelDescriptions) != channels)
        return {};
    std::vector<Speaker> speakers;
    for (UInt32 i = 0; i < layout->mNumberChannelDescriptions; ++i)
        speakers.push_back(speakerOf(layout->mChannelDescriptions[i].mChannelLabel));
    return speakers;
}

std::vector<Speaker> speakersOf(CMFormatDescriptionRef format, int channels)
{
    size_t size = 0;
    const AudioChannelLayout *layout = format ? CMAudioFormatDescriptionGetChannelLayout(format, &size) : nullptr;
    return speakersOf(layout, size, channels);
}

} // namespace

double systemSound(const char *path, const char *wav)
{
    @autoreleasepool {
        NSString *file = [NSString stringWithUTF8String:path];
        if (!file)
            return 0;
        // Only asked whether there is a sound: no need to scan for exact times.
        AVURLAsset *asset = [AVURLAsset URLAssetWithURL:[NSURL fileURLWithPath:file]
                                                options:@{AVURLAssetPreferPreciseDurationAndTimingKey: @(wav != nullptr)}];
#pragma clang diagnostic push
#pragma clang diagnostic ignored "-Wdeprecated-declarations"
        // Synchronous loading is fine: the engine asks from its own threads.
        AVAssetTrack *track = [asset tracksWithMediaType:AVMediaTypeAudio].firstObject;
        if (!track)
            return 0;
        const double length = CMTimeGetSeconds(CMTimeRangeGetEnd(track.timeRange));
        CMFormatDescriptionRef source = (__bridge CMFormatDescriptionRef)track.formatDescriptions.firstObject;
#pragma clang diagnostic pop
        NSError *failure = nil;
        AVAssetReader *reader = [[AVAssetReader alloc] initWithAsset:asset error:&failure];
        if (!reader)
            return 0;
        // Float, interleaved, its own rate and channels (folded down here by
        // where they play: the system's own fold-down silences channels it
        // is not told the places of).
        AVAssetReaderTrackOutput *output = [AVAssetReaderTrackOutput assetReaderTrackOutputWithTrack:track outputSettings:@{
            AVFormatIDKey: @(kAudioFormatLinearPCM),
            AVLinearPCMBitDepthKey: @32,
            AVLinearPCMIsFloatKey: @YES,
            AVLinearPCMIsNonInterleaved: @NO,
            AVLinearPCMIsBigEndianKey: @NO,
        }];
        output.alwaysCopiesSampleData = NO;
        if (![reader canAddOutput:output])
            return 0;
        [reader addOutput:output];
        if (![reader startReading])
            return 0;

        SoundWriter writer;
        bool opened = false;
        int channels = 0;
        std::vector<float> frames;
        for (;;) {
            @autoreleasepool {
                CMSampleBufferRef sample = [output copyNextSampleBuffer];
                if (!sample)
                    break;
                const CMItemCount count = CMSampleBufferGetNumSamples(sample);
                CMFormatDescriptionRef format = CMSampleBufferGetFormatDescription(sample);
                const AudioStreamBasicDescription *description =
                    format ? CMAudioFormatDescriptionGetStreamBasicDescription(format) : nullptr;
                if (!description || count <= 0) {
                    CFRelease(sample);
                    continue;
                }
                if (!wav) {
                    // A sound comes out: the system reads it.
                    CFRelease(sample);
                    [reader cancelReading];
                    return length > 0 ? length : 1e-3;
                }
                if (!opened) {
                    channels = int(description->mChannelsPerFrame);
                    std::vector<Speaker> speakers = speakersOf(format, channels);
                    if (speakers.empty())
                        speakers = speakersOf(source, channels);
                    if (!writer.open(wav, int(description->mSampleRate), channels, speakers, length)) {
                        CFRelease(sample);
                        [reader cancelReading];
                        return 0;
                    }
                    opened = true;
                }
                if (int(description->mChannelsPerFrame) != channels) {
                    CFRelease(sample);
                    [reader cancelReading];
                    return 0;
                }
                frames.resize(size_t(count) * size_t(channels));
                CMBlockBufferRef block = CMSampleBufferGetDataBuffer(sample);
                const bool copied = block
                    && CMBlockBufferCopyDataBytes(block, 0, frames.size() * sizeof(float), frames.data()) == kCMBlockBufferNoErr;
                const double at = CMTimeGetSeconds(CMSampleBufferGetPresentationTimeStamp(sample));
                CFRelease(sample);
                if (copied)
                    writer.write(frames.data(), size_t(count), at);
            }
        }
        if (reader.status == AVAssetReaderStatusFailed || !opened)
            return 0;
        return writer.finish() ? writer.seconds() : 0;
    }
}
