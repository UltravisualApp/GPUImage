#import <Foundation/Foundation.h>
#import <AVFoundation/AVFoundation.h>
#import "GPUImageContext.h"

extern NSString *const kGPUImageColorSwizzlingFragmentShaderString;

@protocol GPUImageMovieWriterDelegate;

@interface GPUImageMovieWriter : NSObject <GPUImageInput>
{
    CVPixelBufferRef renderTarget;
    CVOpenGLESTextureRef renderTexture;
}

@property (nonatomic, assign) BOOL alreadyFinishedRecording;
@property (nonatomic, strong) NSURL *movieURL;
@property (nonatomic, strong) NSString *fileType;
@property (nonatomic, strong) AVAssetWriter *assetWriter;
@property (nonatomic, strong) AVAssetWriterInput *assetWriterAudioInput;
@property (nonatomic, strong) AVAssetWriterInput *assetWriterVideoInput;
@property (nonatomic, strong) AVAssetWriterInputPixelBufferAdaptor *assetWriterPixelBufferInput;

@property (nonatomic, strong) GPUImageContext *movieWriterContext;

@property (nonatomic, assign) CGSize videoSize;
@property (nonatomic, assign) GPUImageRotationMode inputRotation;

@property (nonatomic, assign) BOOL hasAudioTrack;
@property (nonatomic, assign) BOOL shouldPassthroughAudio;
@property (nonatomic, assign) BOOL shouldInvalidateAudioSampleWhenDone;
@property (nonatomic, copy) void(^completionBlock)(void);
@property (nonatomic, copy) void(^failureBlock)(NSError*);
@property (nonatomic, assign) id<GPUImageMovieWriterDelegate> delegate;
@property (readwrite, nonatomic) BOOL encodingLiveVideo;
@property (nonatomic, copy) BOOL(^videoInputReadyCallback)(void);
@property (nonatomic, copy) BOOL(^audioInputReadyCallback)(void);
@property (nonatomic, copy) void(^audioProcessingCallback)(SInt16 **samplesRef, CMItemCount numSamplesInBuffer);
@property (nonatomic, assign) BOOL enabled;
@property (nonatomic, readonly) CMTime duration;
@property (nonatomic, assign) CGAffineTransform transform;
@property (nonatomic, copy) NSArray *metaData;
@property (nonatomic, assign, getter = isPaused) BOOL paused;

// Initialization and teardown
- (id)initWithMovieURL:(NSURL *)newMovieURL size:(CGSize)newSize;
- (id)initWithMovieURL:(NSURL *)newMovieURL size:(CGSize)newSize fileType:(NSString *)newFileType outputSettings:(NSDictionary *)outputSettings;

- (void)setHasAudioTrack:(BOOL)hasAudioTrack audioSettings:(NSDictionary *)audioOutputSettings;

// Movie recording
- (void)startRecording;
- (void)startRecordingInOrientation:(CGAffineTransform)orientationTransform;
- (void)finishRecording;
- (void)finishRecordingWithCompletionHandler:(void (^)(void))handler;
- (void)cancelRecording;
- (void)processAudioBuffer:(CMSampleBufferRef)audioBuffer;
- (void)enableSynchronizationCallbacks;

@end

#pragma mark - <GPUImageMovieWriterDelegate>

@protocol GPUImageMovieWriterDelegate <NSObject>

@optional
- (void)movieWriter:(GPUImageMovieWriter *)movieWriter didFinishWithError:(NSError *)error;

@end
