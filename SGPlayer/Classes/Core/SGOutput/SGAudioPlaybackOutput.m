//
//  SGAudioPlaybackOutput.m
//  SGPlayer
//
//  Created by Single on 2018/1/19.
//  Copyright © 2018年 single. All rights reserved.
//

#import "SGAudioPlaybackOutput.h"
#import "SGAudioStreamPlayer.h"
#import "SGAudioBufferFrame.h"
#import "SGTime.h"
#import "SGError.h"
#import "swscale.h"
#import "swresample.h"

@interface SGAudioPlaybackOutput () <SGAudioStreamPlayerDelegate, NSLocking>

{
    void * _swrContextBufferData[SGAudioFrameMaxChannelCount];
    int _swrContextBufferLinesize[SGAudioFrameMaxChannelCount];
    int _swrContextBufferMallocSize[SGAudioFrameMaxChannelCount];
}

@property (nonatomic, assign) CMTime finalRate;
@property (nonatomic, assign) CMTime frameRate;

@property (nonatomic, strong) NSLock * coreLock;
@property (nonatomic, strong) SGAudioStreamPlayer * audioPlayer;
@property (nonatomic, strong) SGObjectQueue * frameQueue;

@property (nonatomic, strong) SGAudioFrame * currentFrame;
@property (nonatomic, assign) int32_t currentRenderReadOffset;
@property (nonatomic, assign) CMTime currentScale;
@property (nonatomic, assign) CMTime currentPreparePosition;
@property (nonatomic, assign) CMTime currentPrepareDuration;
@property (nonatomic, assign) BOOL timeSyncDidUpdate;
@property (nonatomic, assign) BOOL hasFrame;

@property (nonatomic, assign) SwrContext * swrContext;
@property (nonatomic, assign) NSError * swrContextError;

@property (nonatomic, assign) enum AVSampleFormat inputFormat;
@property (nonatomic, assign) enum AVSampleFormat outputFormat;
@property (nonatomic, assign) int inputSampleRate;
@property (nonatomic, assign) int inputNumberOfChannels;
@property (nonatomic, assign) int outputSampleRate;
@property (nonatomic, assign) int outputNumberOfChannels;

@end

@implementation SGAudioPlaybackOutput

@synthesize delegate = _delegate;
@synthesize enable = _enable;
@synthesize key = _key;

- (SGMediaType)mediaType
{
    return SGMediaTypeAudio;
}

- (instancetype)init
{
    if (self = [super init])
    {
        _enable = NO;
        _key = NO;
        _rate = CMTimeMake(1, 1);
        _finalRate = CMTimeMake(1, 1);
        _frameRate = CMTimeMake(1, 1);
        _currentScale = CMTimeMake(1, 1);
        self.audioPlayer = [[SGAudioStreamPlayer alloc] init];
        self.audioPlayer.delegate = self;
    }
    return self;
}

- (void)dealloc
{
    [self close];
}

#pragma mark - Interface

- (void)open
{
    if (!self.enable)
    {
        return;
    }
    self.frameQueue = [[SGObjectQueue alloc] init];
    self.currentRenderReadOffset = 0;
    self.currentPreparePosition = kCMTimeZero;
    self.currentPrepareDuration = kCMTimeZero;
}

- (void)pause
{
    if (!self.enable)
    {
        return;
    }
    [self.audioPlayer pause];
}

- (void)resume
{
    if (!self.enable)
    {
        return;
    }
    [self.audioPlayer play];
}

- (void)close
{
    if (!self.enable)
    {
        return;
    }
    [self.audioPlayer pause];
    [self lock];
    [self.currentFrame unlock];
    self.currentFrame = nil;
    self.currentRenderReadOffset = 0;
    self.currentPreparePosition = kCMTimeZero;
    self.currentPrepareDuration = kCMTimeZero;
    self.timeSyncDidUpdate = NO;
    self.hasFrame = NO;
    [self unlock];
    [self.frameQueue destroy];
    [self destorySwrContextBuffer];
    [self destorySwrContext];
}

- (void)putFrame:(__kindof SGFrame *)frame
{
    if (!self.enable)
    {
        return;
    }
    if (![frame isKindOfClass:[SGAudioFrame class]])
    {
        return;
    }
    SGAudioFrame * audioFrame = frame;
    
    enum AVSampleFormat inputFormat = audioFrame.format;
    enum AVSampleFormat outputFormat = AV_SAMPLE_FMT_FLTP;
    int inputSampleRate = audioFrame.sampleRate;
    int inputNumberOfChannels = audioFrame.numberOfChannels;
    int outputSampleRate = self.audioPlayer.asbd.mSampleRate;
    int outputNumberOfChannels = self.audioPlayer.asbd.mChannelsPerFrame;
    
    if (self.inputFormat != inputFormat ||
        self.outputFormat != outputFormat ||
        self.inputSampleRate != inputSampleRate ||
        self.outputSampleRate != outputSampleRate ||
        self.inputNumberOfChannels != inputNumberOfChannels ||
        self.outputNumberOfChannels != outputNumberOfChannels)
    {
        self.inputFormat = inputFormat;
        self.outputFormat = outputFormat;
        self.inputSampleRate = inputSampleRate;
        self.outputSampleRate = outputSampleRate;
        self.inputNumberOfChannels = inputNumberOfChannels;
        self.outputNumberOfChannels = outputNumberOfChannels;
        
        [self destorySwrContext];
        [self setupSwrContext];
    }
    
    if (!self.swrContext)
    {
        return;
    }
    const int numberOfChannelsRatio = MAX(1, self.outputNumberOfChannels / self.inputNumberOfChannels);
    const int sampleRateRatio = MAX(1, self.outputSampleRate / self.inputSampleRate);
    const int ratio = sampleRateRatio * numberOfChannelsRatio;
    const int bufferSize = av_samples_get_buffer_size(NULL, 1, audioFrame.numberOfSamples * ratio, self.outputFormat, 1);
    [self setupSwrContextBufferIfNeeded:bufferSize];
    int numberOfSamples = swr_convert(self.swrContext,
                                      (uint8_t **)_swrContextBufferData,
                                      audioFrame.numberOfSamples * ratio,
                                      (const uint8_t **)audioFrame.data,
                                      audioFrame.numberOfSamples);
    [self updateSwrContextBufferLinsize:numberOfSamples * sizeof(float)];
    
    SGAudioBufferFrame * result = [[SGObjectPool sharePool] objectWithClass:[SGAudioBufferFrame class]];
    [result fillWithAudioFrame:audioFrame];
    result.format = AV_SAMPLE_FMT_FLTP;
    result.numberOfSamples = numberOfSamples;
    result.sampleRate = self.outputSampleRate;
    result.numberOfChannels = self.outputNumberOfChannels;
    result.channelLayout = audioFrame.channelLayout;
    result.bestEffortTimestamp = audioFrame.bestEffortTimestamp;
    result.packetPosition = audioFrame.packetPosition;
    result.packetDuration = audioFrame.packetDuration;
    result.packetSize = audioFrame.packetSize;
    [result updateData:_swrContextBufferData linesize:_swrContextBufferLinesize];
    if (!self.timeSyncDidUpdate && self.frameQueue.count == 0)
    {
        [self.timeSync updateKeyTime:result.timeStamp duration:kCMTimeZero rate:CMTimeMake(1, 1)];
    }
    self.hasFrame = YES;
    [self.frameQueue putObjectSync:result];
    [self.delegate outputDidChangeCapacity:self];
    [result unlock];
}

- (void)flush
{
    if (!self.enable)
    {
        return;
    }
    [self lock];
    [self.currentFrame unlock];
    self.currentFrame = nil;
    self.currentRenderReadOffset = 0;
    self.currentPreparePosition = kCMTimeZero;
    self.currentPrepareDuration = kCMTimeZero;
    self.timeSyncDidUpdate = NO;
    self.hasFrame = NO;
    [self unlock];
    [self.frameQueue flush];
    [self.delegate outputDidChangeCapacity:self];
}

#pragma mark - Setter & Getter

- (NSError *)error
{
    if (self.audioPlayer.error)
    {
        return self.audioPlayer.error;
    }
    return self.swrContextError;
}

- (BOOL)empty
{
    return self.count <= 0;
}

- (CMTime)duration
{
    if (self.frameQueue)
    {
        return self.frameQueue.duration;
    }
    return kCMTimeZero;
}

- (long long)size
{
    if (self.frameQueue)
    {
        return self.frameQueue.size;
    }
    return 0;
}

- (NSUInteger)count
{
    if (self.frameQueue)
    {
        return self.frameQueue.count;
    }
    return 0;
}

- (NSUInteger)maxCount
{
    return 5;
}

- (void)setVolume:(float)volume
{
    [self.audioPlayer setVolume:volume error:nil];
}

- (float)volume
{
    return self.audioPlayer.volume;
}

- (void)setRate:(CMTime)rate
{
    if (CMTimeCompare(_rate, rate) != 0)
    {
        _rate = rate;
        [self updatePlayerRate];
    }
}

- (void)setFrameRate:(CMTime)frameRate
{
    if (CMTimeCompare(_frameRate, frameRate) != 0)
    {
        _frameRate = frameRate;
        [self updatePlayerRate];
    }
}

- (void)updatePlayerRate
{
    CMTime rate = SGCMTimeMultiply(self.rate, self.frameRate);
    NSError * error = nil;
    [self.audioPlayer setRate:CMTimeGetSeconds(rate) error:&error];
}

#pragma mark - swr

- (void)setupSwrContext
{
    if (self.swrContextError || self.swrContext)
    {
        return;
    }
    self.swrContext = swr_alloc_set_opts(NULL,
                                         av_get_default_channel_layout(self.outputNumberOfChannels),
                                         self.outputFormat,
                                         self.outputSampleRate,
                                         av_get_default_channel_layout(self.inputNumberOfChannels),
                                         self.inputFormat,
                                         self.inputSampleRate,
                                         0, NULL);
    int result = swr_init(self.swrContext);
    self.swrContextError = SGFFGetErrorCode(result, SGErrorCodeAuidoSwrInit);
    if (self.swrContextError)
    {
        [self destorySwrContext];
    }
}

- (void)destorySwrContext
{
    if (self.swrContext)
    {
        swr_free(&_swrContext);
        self.swrContext = nil;
    }
}

- (void)setupSwrContextBufferIfNeeded:(int)bufferSize
{
    for (int i = 0; i < SGAudioFrameMaxChannelCount; i++)
    {
        if (_swrContextBufferMallocSize[i] < bufferSize)
        {
            _swrContextBufferMallocSize[i] = bufferSize;
            _swrContextBufferData[i] = realloc(_swrContextBufferData[i], bufferSize);
        }
    }
}

- (void)updateSwrContextBufferLinsize:(int)linesize
{
    for (int i = 0; i < SGAudioFrameMaxChannelCount; i++)
    {
        _swrContextBufferLinesize[i] = (i < self.outputNumberOfChannels) ? linesize : 0;
    }
}

- (void)destorySwrContextBuffer
{
    for (int i = 0; i < SGAudioFrameMaxChannelCount; i++)
    {
        if (_swrContextBufferData[i])
        {
            free(_swrContextBufferData[i]);
            _swrContextBufferData[i] = NULL;
        }
        _swrContextBufferLinesize[i] = 0;
        _swrContextBufferMallocSize[i] = 0;
    }
}

#pragma mark - SGAudioStreamPlayerDelegate

- (void)audioPlayer:(SGAudioStreamPlayer *)audioPlayer inputSample:(const AudioTimeStamp *)timestamp ioData:(AudioBufferList *)ioData numberOfSamples:(UInt32)numberOfSamples
{
    BOOL hasNewFrame = NO;
    [self lock];
    NSUInteger ioDataWriteOffset = 0;
    while (numberOfSamples > 0)
    {
        if (!self.currentFrame)
        {
            self.currentFrame = [self.frameQueue getObjectAsync];
            hasNewFrame = YES;
        }
        if (!self.currentFrame)
        {
            break;
        }
        self.currentScale = self.currentFrame.scale;
        
        int32_t residueLinesize = self.currentFrame.linesize[0] - self.currentRenderReadOffset;
        int32_t bytesToCopy = MIN(numberOfSamples * (int32_t)sizeof(float), residueLinesize);
        int32_t framesToCopy = bytesToCopy / sizeof(float);
        
        for (int i = 0; i < ioData->mNumberBuffers && i < self.currentFrame.numberOfChannels; i++)
        {
            if (self.currentFrame.linesize[i] - self.currentRenderReadOffset >= bytesToCopy)
            {
                Byte * bytes = (Byte *)self.currentFrame.data[i] + self.currentRenderReadOffset;
                memcpy(ioData->mBuffers[i].mData + ioDataWriteOffset, bytes, bytesToCopy);
            }
        }
        
        if (ioDataWriteOffset == 0)
        {
            self.currentPrepareDuration = kCMTimeZero;
            CMTime duration = CMTimeMultiplyByRatio(self.currentFrame.originalDuration, self.currentRenderReadOffset, self.currentFrame.linesize[0]);
            duration = SGCMTimeMultiply(duration, self.currentFrame.scale);
            self.currentPreparePosition = CMTimeAdd(self.currentFrame.timeStamp, duration);
        }
        CMTime duration = CMTimeMultiplyByRatio(self.currentFrame.originalDuration, bytesToCopy, self.currentFrame.linesize[0]);
        duration = SGCMTimeMultiply(duration, self.currentFrame.scale);
        self.currentPrepareDuration = CMTimeAdd(self.currentPrepareDuration, duration);
        
        numberOfSamples -= framesToCopy;
        ioDataWriteOffset += bytesToCopy;
        
        if (bytesToCopy < residueLinesize)
        {
            self.currentRenderReadOffset += bytesToCopy;
        }
        else
        {
            [self.currentFrame unlock];
            self.currentFrame = nil;
            self.currentRenderReadOffset = 0;
        }
    }
    [self unlock];
    if (hasNewFrame)
    {
        [self.delegate outputDidChangeCapacity:self];
    }
}

- (void)audioStreamPlayer:(SGAudioStreamPlayer *)audioDataPlayer postSample:(const AudioTimeStamp *)timestamp
{
    [self lock];
    self.frameRate = SGCMTimeDivide(CMTimeMake(1, 1), self.currentScale);
    self.timeSyncDidUpdate = YES;
    [self.timeSync updateKeyTime:self.currentPreparePosition duration:self.currentPrepareDuration rate:self.rate];
    [self unlock];
}

#pragma mark - NSLocking

- (void)lock
{
    if (!self.coreLock)
    {
        self.coreLock = [[NSLock alloc] init];
    }
    [self.coreLock lock];
}

- (void)unlock
{
    [self.coreLock unlock];
}

@end
