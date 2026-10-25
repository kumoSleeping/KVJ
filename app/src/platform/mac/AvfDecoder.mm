// macOS: AVAssetReader with VideoToolbox (hardware) decoding to 32BGRA, scaled
// by the system to the chosen height so large material never reaches memory.

#include "../../Decoder.h"

#import <AVFoundation/AVFoundation.h>
#import <CoreMedia/CoreMedia.h>
#import <CoreVideo/CoreVideo.h>

#include <algorithm>
#include <cmath>
#include <cstring>

namespace {

class AvfDecoder final : public Decoder
{
public:
    ~AvfDecoder() override { [m_reader cancelReading]; }

    bool open(const QString &path, const DecodeOptions &options, QString *error) override
    {
        @autoreleasepool {
            NSURL *url = [NSURL fileURLWithPath:path.toNSString()];
            m_asset = [AVURLAsset URLAssetWithURL:url
                                          options:@{AVURLAssetPreferPreciseDurationAndTimingKey: @YES}];
#pragma clang diagnostic push
#pragma clang diagnostic ignored "-Wdeprecated-declarations"
            // Synchronous loading is fine here: this runs on the player's own thread.
            NSArray<AVAssetTrack *> *tracks = [m_asset tracksWithMediaType:AVMediaTypeVideo];
            m_track = tracks.firstObject;
            if (!m_track) {
                *error = QStringLiteral("文件里没有视频轨");
                return false;
            }
            m_duration = CMTimeGetSeconds(m_asset.duration);
            const CGSize natural = m_track.naturalSize;
            m_frameRate = m_track.nominalFrameRate;
#pragma clang diagnostic pop
            m_natural = QSize(int(std::abs(natural.width) + 0.5), int(std::abs(natural.height) + 0.5));
            m_size = scaledSize(std::abs(natural.width), std::abs(natural.height), options.maxHeight);
            return seek(0);
        }
    }

    bool seek(double seconds) override
    {
        @autoreleasepool {
            [m_reader cancelReading];
            m_reader = nil;
            m_output = nil;
            NSError *failure = nil;
            AVAssetReader *reader = [[AVAssetReader alloc] initWithAsset:m_asset error:&failure];
            if (!reader) {
                m_error = QString::fromNSString(failure.localizedDescription);
                return false;
            }
            NSMutableDictionary *settings = [@{
                (id)kCVPixelBufferPixelFormatTypeKey: @(kCVPixelFormatType_32BGRA),
            } mutableCopy];
            if (!m_size.isEmpty()) {
                settings[(id)kCVPixelBufferWidthKey] = @(m_size.width());
                settings[(id)kCVPixelBufferHeightKey] = @(m_size.height());
            }
            AVAssetReaderTrackOutput *output =
                [AVAssetReaderTrackOutput assetReaderTrackOutputWithTrack:m_track outputSettings:settings];
            output.alwaysCopiesSampleData = NO;
            if (![reader canAddOutput:output]) {
                m_error = QStringLiteral("无法读取这个视频轨");
                return false;
            }
            [reader addOutput:output];
            reader.timeRange = CMTimeRangeMake(CMTimeMakeWithSeconds(std::max(0.0, seconds), 90000),
                                               kCMTimePositiveInfinity);
            if (![reader startReading]) {
                m_error = QString::fromNSString(reader.error.localizedDescription);
                return false;
            }
            m_reader = reader;
            m_output = output;
            return true;
        }
    }

    bool next(VideoFrame *frame, double discardBefore) override
    {
        @autoreleasepool {
            while (m_output) {
                CMSampleBufferRef sample = [m_output copyNextSampleBuffer];
                if (!sample) {
                    if (m_reader.status == AVAssetReaderStatusFailed)
                        m_error = QString::fromNSString(m_reader.error.localizedDescription);
                    return false;
                }
                CVImageBufferRef image = CMSampleBufferGetImageBuffer(sample);
                if (!image) {
                    CFRelease(sample);
                    continue;
                }
                frame->pts = CMTimeGetSeconds(CMSampleBufferGetPresentationTimeStamp(sample));
                if (frame->pts < discardBefore) {
                    CFRelease(sample);
                    continue;
                }
                CVPixelBufferLockBaseAddress(image, kCVPixelBufferLock_ReadOnly);
                const size_t width = CVPixelBufferGetWidth(image);
                const size_t height = CVPixelBufferGetHeight(image);
                const size_t stride = CVPixelBufferGetBytesPerRow(image);
                const auto *base = static_cast<const uchar *>(CVPixelBufferGetBaseAddress(image));
                // 32BGRA in memory is Qt's RGB32 on little-endian machines.
                prepareImage(frame->image, QSize(int(width), int(height)));
                for (size_t y = 0; y < height; ++y)
                    std::memcpy(frame->image.scanLine(int(y)), base + y * stride, width * 4);
                CVPixelBufferUnlockBaseAddress(image, kCVPixelBufferLock_ReadOnly);
                CFRelease(sample);
                return true;
            }
            return false;
        }
    }

    double duration() const override { return m_duration; }
    QString error() const override { return m_error; }
    QSize sourceSize() const override { return m_natural; }
    double frameRate() const override { return m_frameRate; }

private:
    AVURLAsset *m_asset = nil;
    AVAssetTrack *m_track = nil;
    AVAssetReader *m_reader = nil;
    AVAssetReaderTrackOutput *m_output = nil;
    double m_duration = 0;
    double m_frameRate = 0;
    QSize m_natural;
    QSize m_size;
    QString m_error;
};

} // namespace

std::unique_ptr<Decoder> createDecoder()
{
    return std::make_unique<AvfDecoder>();
}
