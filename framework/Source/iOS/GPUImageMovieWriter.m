#import "GPUImageMovieWriter.h"

#import "GPUImageContext.h"
#import "GLProgram.h"
#import "GPUImageFilter.h"

NSString *const kGPUImageColorSwizzlingFragmentShaderString = SHADER_STRING
(
 varying highp vec2 textureCoordinate;
 
 uniform sampler2D inputImageTexture;
 
 void main()
 {
     gl_FragColor = texture2D(inputImageTexture, textureCoordinate).bgra;
 }
);

@interface GPUImageMovieWriter()
{
    GLuint movieFramebuffer, movieRenderbuffer;
}

@property (nonatomic, assign) BOOL audioEncodingIsFinished;
@property (nonatomic, assign) BOOL videoEncodingIsFinished;
@property (nonatomic, strong) GLProgram *colorSwizzlingProgram;
@property (nonatomic, assign) GLint colorSwizzlingPositionAttribute;
@property (nonatomic, assign) GLint colorSwizzlingTextureCoordinateAttribute;
@property (nonatomic, assign) GLint colorSwizzlingInputTextureUniform;
@property (nonatomic, strong) GPUImageFramebuffer *firstInputFramebuffer;
@property (nonatomic, assign) CMTime startTime;
@property (nonatomic, assign) CMTime previousFrameTime;
@property (nonatomic, assign) CMTime previousAudioTime;
@property (nonatomic) dispatch_queue_t audioQueue;
@property (nonatomic) dispatch_queue_t videoQueue;
@property (nonatomic, assign, getter=isRecording) BOOL recording;
@property (nonatomic, assign) BOOL allowWriteAudio;

@end

@interface GPUImageMovieWriter ()

// Movie recording
- (void)initializeMovieWithOutputSettings:(NSMutableDictionary *)outputSettings;

// Frame rendering
- (void)createDataFBO;
- (void)destroyDataFBO;
- (void)setFilterFBO;

- (void)renderAtInternalSizeUsingFramebuffer:(GPUImageFramebuffer *)inputFramebufferToUse;

@end

@implementation GPUImageMovieWriter

#pragma mark -
#pragma mark Initialization and teardown

- (id)initWithMovieURL:(NSURL *)newMovieURL size:(CGSize)newSize;
{
    return [self initWithMovieURL:newMovieURL size:newSize fileType:AVFileTypeQuickTimeMovie outputSettings:nil];
}

- (id)initWithMovieURL:(NSURL *)newMovieURL size:(CGSize)newSize fileType:(NSString *)newFileType outputSettings:(NSMutableDictionary *)outputSettings;
{
    self = [super init];
    if (self) {
        self.shouldInvalidateAudioSampleWhenDone = NO;
        
        self.enabled = YES;
        self.alreadyFinishedRecording = NO;
        self.videoEncodingIsFinished = NO;
        self.audioEncodingIsFinished = NO;
        
        self.videoSize = newSize;
        self.movieURL = newMovieURL;
        self.fileType = newFileType;
        self.startTime = kCMTimeInvalid;
        self.encodingLiveVideo = [[outputSettings objectForKey:@"EncodingLiveVideo"] isKindOfClass:[NSNumber class]] ? [[outputSettings objectForKey:@"EncodingLiveVideo"] boolValue] : YES;
        self.previousFrameTime = kCMTimeNegativeInfinity;
        self.previousAudioTime = kCMTimeNegativeInfinity;
        self.inputRotation = kGPUImageNoRotation;
        
        _movieWriterContext = [[GPUImageContext alloc] init];
        [_movieWriterContext useSharegroup:[[[GPUImageContext sharedImageProcessingContext] context] sharegroup]];
        
        runSynchronouslyOnContextQueue(_movieWriterContext, ^{
            [_movieWriterContext useAsCurrentContext];
            
            if ([GPUImageContext supportsFastTextureUpload]) {
                self.colorSwizzlingProgram = [_movieWriterContext programForVertexShaderString:kGPUImageVertexShaderString fragmentShaderString:kGPUImagePassthroughFragmentShaderString];
            }
            else {
                self.colorSwizzlingProgram = [_movieWriterContext programForVertexShaderString:kGPUImageVertexShaderString fragmentShaderString:kGPUImageColorSwizzlingFragmentShaderString];
            }
            
            if (!self.colorSwizzlingProgram.initialized) {
                [self.colorSwizzlingProgram addAttribute:@"position"];
                [self.colorSwizzlingProgram addAttribute:@"inputTextureCoordinate"];
                
                if (![self.colorSwizzlingProgram link]) {
                    NSString *progLog = [self.colorSwizzlingProgram programLog];
                    NSLog(@"Program link log: %@", progLog);
                    NSString *fragLog = [self.colorSwizzlingProgram fragmentShaderLog];
                    NSLog(@"Fragment shader compile log: %@", fragLog);
                    NSString *vertLog = [self.colorSwizzlingProgram vertexShaderLog];
                    NSLog(@"Vertex shader compile log: %@", vertLog);
                    self.colorSwizzlingProgram = nil;
                    NSAssert(NO, @"Filter shader link failed");
                }
            }
            
            self.colorSwizzlingPositionAttribute = [self.colorSwizzlingProgram attributeIndex:@"position"];
            self.colorSwizzlingTextureCoordinateAttribute = [self.colorSwizzlingProgram attributeIndex:@"inputTextureCoordinate"];
            self.colorSwizzlingInputTextureUniform = [self.colorSwizzlingProgram uniformIndex:@"inputImageTexture"];
            
            [self.movieWriterContext setContextShaderProgram:self.colorSwizzlingProgram];
            
            glEnableVertexAttribArray(self.colorSwizzlingPositionAttribute);
            glEnableVertexAttribArray(self.colorSwizzlingTextureCoordinateAttribute);
        });
        
        [self initializeMovieWithOutputSettings:outputSettings];
    }

    return self;
}

- (void)dealloc;
{
    [self destroyDataFBO];

#if !OS_OBJECT_USE_OBJC
    if( audioQueue != NULL ) {
        dispatch_release(audioQueue);
    }
    if( videoQueue != NULL ) {
        dispatch_release(videoQueue);
    }
#endif
}

#pragma mark -
#pragma mark Movie recording

- (void)initializeMovieWithOutputSettings:(NSDictionary *)outputSettings;
{
    self.recording = NO;
    self.allowWriteAudio = NO;
    
    self.enabled = YES;
    NSError *error = nil;
    self.assetWriter = [[AVAssetWriter alloc] initWithURL:self.movieURL fileType:self.fileType error:&error];
    if (error != nil) {
        NSLog(@"Error: %@", error);
        if (self.failureBlock) {
            self.failureBlock(error);
        } else {
            if (self.delegate && [self.delegate respondsToSelector:@selector(movieWriter:didFinishWithError:)]) {
                [self.delegate movieWriter:self didFinishWithError:error];
            }
        }
    }
    
    // Set this to make sure that a functional movie is produced, even if the recording is cut off mid-stream. Only the last second should be lost in that case.
    self.assetWriter.movieFragmentInterval = CMTimeMakeWithSeconds(1.0, 1000);
    
    // use default output settings if none specified
    if (outputSettings == nil) {
        NSMutableDictionary *settings = [[NSMutableDictionary alloc] init];
        [settings setObject:AVVideoCodecH264 forKey:AVVideoCodecKey];
        [settings setObject:[NSNumber numberWithInt:self.videoSize.width] forKey:AVVideoWidthKey];
        [settings setObject:[NSNumber numberWithInt:self.videoSize.height] forKey:AVVideoHeightKey];
        outputSettings = settings;
    }
    // custom output settings specified
    else {
		NSString *videoCodec = [outputSettings objectForKey:AVVideoCodecKey];
		NSNumber *width = [outputSettings objectForKey:AVVideoWidthKey];
		NSNumber *height = [outputSettings objectForKey:AVVideoHeightKey];
		
		NSAssert(videoCodec && width && height, @"OutputSettings is missing required parameters.");
        
        if( [outputSettings objectForKey:@"EncodingLiveVideo"] ) {
            NSMutableDictionary *tmp = [outputSettings mutableCopy];
            [tmp removeObjectForKey:@"EncodingLiveVideo"];
            outputSettings = tmp;
        }
    }
    
    /*
    NSDictionary *videoCleanApertureSettings = [NSDictionary dictionaryWithObjectsAndKeys:
                                                [NSNumber numberWithInt:videoSize.width], AVVideoCleanApertureWidthKey,
                                                [NSNumber numberWithInt:videoSize.height], AVVideoCleanApertureHeightKey,
                                                [NSNumber numberWithInt:0], AVVideoCleanApertureHorizontalOffsetKey,
                                                [NSNumber numberWithInt:0], AVVideoCleanApertureVerticalOffsetKey,
                                                nil];

    NSDictionary *videoAspectRatioSettings = [NSDictionary dictionaryWithObjectsAndKeys:
                                              [NSNumber numberWithInt:3], AVVideoPixelAspectRatioHorizontalSpacingKey,
                                              [NSNumber numberWithInt:3], AVVideoPixelAspectRatioVerticalSpacingKey,
                                              nil];

    NSMutableDictionary * compressionProperties = [[NSMutableDictionary alloc] init];
    [compressionProperties setObject:videoCleanApertureSettings forKey:AVVideoCleanApertureKey];
    [compressionProperties setObject:videoAspectRatioSettings forKey:AVVideoPixelAspectRatioKey];
    [compressionProperties setObject:[NSNumber numberWithInt: 2000000] forKey:AVVideoAverageBitRateKey];
    [compressionProperties setObject:[NSNumber numberWithInt: 16] forKey:AVVideoMaxKeyFrameIntervalKey];
    [compressionProperties setObject:AVVideoProfileLevelH264Main31 forKey:AVVideoProfileLevelKey];
    
    [outputSettings setObject:compressionProperties forKey:AVVideoCompressionPropertiesKey];
    */
     
    self.assetWriterVideoInput = [AVAssetWriterInput assetWriterInputWithMediaType:AVMediaTypeVideo outputSettings:outputSettings];
    self.assetWriterVideoInput.expectsMediaDataInRealTime = self.encodingLiveVideo;
    
    // You need to use BGRA for the video in order to get realtime encoding. I use a color-swizzling shader to line up glReadPixels' normal RGBA output with the movie input's BGRA.
    NSDictionary *sourcePixelBufferAttributesDictionary = [NSDictionary dictionaryWithObjectsAndKeys: [NSNumber numberWithInt:kCVPixelFormatType_32BGRA], kCVPixelBufferPixelFormatTypeKey,
                                                           [NSNumber numberWithInt:self.videoSize.width], kCVPixelBufferWidthKey,
                                                           [NSNumber numberWithInt:self.videoSize.height], kCVPixelBufferHeightKey,
                                                           nil];
//    NSDictionary *sourcePixelBufferAttributesDictionary = [NSDictionary dictionaryWithObjectsAndKeys: [NSNumber numberWithInt:kCVPixelFormatType_32ARGB], kCVPixelBufferPixelFormatTypeKey,
//                                                           nil];
        
    self.assetWriterPixelBufferInput = [AVAssetWriterInputPixelBufferAdaptor assetWriterInputPixelBufferAdaptorWithAssetWriterInput:self.assetWriterVideoInput sourcePixelBufferAttributes:sourcePixelBufferAttributesDictionary];
    
    [self.assetWriter addInput:self.assetWriterVideoInput];
}

- (void)update:(id)sender {
    NSLog(@"Asset Writer: %li", (long)self.assetWriter.status);
}

- (void)setEncodingLiveVideo:(BOOL)encodingLiveVideo
{
    if (_encodingLiveVideo != encodingLiveVideo) {
        _encodingLiveVideo = encodingLiveVideo;
        if (self.isRecording) {
            NSAssert(NO, @"Can not change Encoding Live Video while recording");
        }
        else
        {
            self.assetWriterVideoInput.expectsMediaDataInRealTime = _encodingLiveVideo;
            self.assetWriterAudioInput.expectsMediaDataInRealTime = _encodingLiveVideo;
        }
    }
}

- (void)startRecording;
{
    self.allowWriteAudio = NO;
    self.alreadyFinishedRecording = NO;
    self.startTime = kCMTimeInvalid;
    runSynchronouslyOnContextQueue(self.movieWriterContext, ^{
        if (self.audioInputReadyCallback == NULL)
        {
            [self.assetWriter startWriting];
        }
    });
    self.recording = YES;
//	    [self.assetWriter startSessionAtSourceTime:kCMTimeZero];
}

- (void)startRecordingInOrientation:(CGAffineTransform)orientationTransform;
{
	self.assetWriterVideoInput.transform = orientationTransform;

	[self startRecording];
}

- (void)cancelRecording;
{
    if (self.assetWriter.status == AVAssetWriterStatusCompleted) {
        return;
    }
    
    self.recording = NO;
    runSynchronouslyOnContextQueue(self.movieWriterContext, ^{
        self.alreadyFinishedRecording = YES;

        if (self.assetWriter.status == AVAssetWriterStatusWriting && ! self.videoEncodingIsFinished) {
            self.videoEncodingIsFinished = YES;
            [self.assetWriterVideoInput markAsFinished];
        }
        if (self.assetWriter.status == AVAssetWriterStatusWriting && ! self.audioEncodingIsFinished) {
            self.audioEncodingIsFinished = YES;
            [self.assetWriterAudioInput markAsFinished];
        }
        [self.assetWriter cancelWriting];
    });
}

- (void)finishRecording;
{
    [self finishRecordingWithCompletionHandler:NULL];
}

- (void)finishRecordingWithCompletionHandler:(void (^)(void))handler;
{
    runSynchronouslyOnContextQueue(_movieWriterContext, ^{
        self.recording = NO;
        
        if (self.assetWriter.status == AVAssetWriterStatusCompleted || self.assetWriter.status == AVAssetWriterStatusCancelled || self.assetWriter.status == AVAssetWriterStatusUnknown) {
            if (handler) {
                runAsynchronouslyOnContextQueue(_movieWriterContext, handler);
            }
            return;
        }
        
        if (self.assetWriter.status == AVAssetWriterStatusWriting && ! self.videoEncodingIsFinished) {
            self.videoEncodingIsFinished = YES;
            [self.assetWriterVideoInput markAsFinished];
        }
        
        if (self.assetWriter.status == AVAssetWriterStatusWriting && ! self.audioEncodingIsFinished) {
            self.audioEncodingIsFinished = YES;
            [self.assetWriterAudioInput markAsFinished];
        }
        
        if (self.delegate && [self.delegate respondsToSelector:@selector(movieWriter:didFinishWithError:)]) {
            [self.delegate movieWriter:self didFinishWithError:nil];
        }
        
#if (!defined(__IPHONE_6_0) || (__IPHONE_OS_VERSION_MAX_ALLOWED < __IPHONE_6_0))
        // Not iOS 6 SDK
        [assetWriter finishWriting];
        if (handler)
            runAsynchronouslyOnContextQueue(_movieWriterContext,handler);
#else
        // iOS 6 SDK
        if ([self.assetWriter respondsToSelector:@selector(finishWritingWithCompletionHandler:)]) {
            // Running iOS 6
            [self.assetWriter finishWritingWithCompletionHandler:(handler ?: ^{ })];
        } else {
            // Not running iOS 6
#pragma clang diagnostic push
#pragma clang diagnostic ignored "-Wdeprecated-declarations"
            [self.assetWriter finishWriting];
#pragma clang diagnostic pop
            if (handler) {
                runAsynchronouslyOnContextQueue(_movieWriterContext, handler);
            }
        }
#endif
    });
}

- (void)processAudioBuffer:(CMSampleBufferRef)audioBuffer;
{
    if (!self.isRecording || !self.allowWriteAudio) {
        return;
    }

    if (self.hasAudioTrack) {
        CFRetain(audioBuffer);

        CMTime currentSampleTime = CMSampleBufferGetOutputPresentationTimeStamp(audioBuffer);
        
        if (CMTIME_IS_INVALID(self.startTime)) {
            runSynchronouslyOnContextQueue(self.movieWriterContext, ^{
                if ((self.audioInputReadyCallback == NULL) && (self.assetWriter.status != AVAssetWriterStatusWriting))
                {
                    [self.assetWriter startWriting];
                }
                [self.assetWriter startSessionAtSourceTime:currentSampleTime];
                self.startTime = currentSampleTime;
            });
        }

        if (!self.assetWriterAudioInput.readyForMoreMediaData && self.encodingLiveVideo)
        {
            NSLog(@"1: Had to drop an audio frame: %@", CFBridgingRelease(CMTimeCopyDescription(kCFAllocatorDefault, currentSampleTime)));
            if (self.shouldInvalidateAudioSampleWhenDone)
            {
                CMSampleBufferInvalidate(audioBuffer);
            }
            CFRelease(audioBuffer);
            return;
        }

        self.previousAudioTime = currentSampleTime;
        
        //if the consumer wants to do something with the audio samples before writing, let him.
        if (self.audioProcessingCallback) {
            //need to introspect into the opaque CMBlockBuffer structure to find its raw sample buffers.
            CMBlockBufferRef buffer = CMSampleBufferGetDataBuffer(audioBuffer);
            CMItemCount numSamplesInBuffer = CMSampleBufferGetNumSamples(audioBuffer);
            AudioBufferList audioBufferList;
            
            CMSampleBufferGetAudioBufferListWithRetainedBlockBuffer(audioBuffer,
                                                                    NULL,
                                                                    &audioBufferList,
                                                                    sizeof(audioBufferList),
                                                                    NULL,
                                                                    NULL,
                                                                    kCMSampleBufferFlag_AudioBufferList_Assure16ByteAlignment,
                                                                    &buffer
                                                                    );
            //passing a live pointer to the audio buffers, try to process them in-place or we might have syncing issues.
            for (int bufferCount=0; bufferCount < audioBufferList.mNumberBuffers; bufferCount++) {
                SInt16 *samples = (SInt16 *)audioBufferList.mBuffers[bufferCount].mData;
                self.audioProcessingCallback(&samples, numSamplesInBuffer);
            }
        }
        
//        NSLog(@"Recorded audio sample time: %lld, %d, %lld", currentSampleTime.value, currentSampleTime.timescale, currentSampleTime.epoch);
        void(^write)() = ^() {
            while( ! self.assetWriterAudioInput.readyForMoreMediaData && ! self.encodingLiveVideo && ! self.audioEncodingIsFinished ) {
                NSDate *maxDate = [NSDate dateWithTimeIntervalSinceNow:0.5];
                //NSLog(@"audio waiting...");
                [[NSRunLoop currentRunLoop] runUntilDate:maxDate];
            }
            if (!self.assetWriterAudioInput.readyForMoreMediaData) {
                NSLog(@"2: Had to drop an audio frame %@", CFBridgingRelease(CMTimeCopyDescription(kCFAllocatorDefault, currentSampleTime)));
            } else if (self.assetWriter.status == AVAssetWriterStatusWriting) {
                if (![self.assetWriterAudioInput appendSampleBuffer:audioBuffer]) {
                    NSLog(@"Problem appending audio buffer at time: %@", CFBridgingRelease(CMTimeCopyDescription(kCFAllocatorDefault, currentSampleTime)));
                }
                
                self.allowWriteAudio = YES;
            }
//            else {
//                NSLog(@"Wrote an audio frame %@", CFBridgingRelease(CMTimeCopyDescription(kCFAllocatorDefault, currentSampleTime)));
//            }

            if (self.shouldInvalidateAudioSampleWhenDone) {
                CMSampleBufferInvalidate(audioBuffer);
            }
            CFRelease(audioBuffer);
        };
//        runAsynchronouslyOnContextQueue(_movieWriterContext, write);
        if (self.encodingLiveVideo) {
            runAsynchronouslyOnContextQueue(self.movieWriterContext, write);
        } else {
            write();
        }
    }
}

- (void)enableSynchronizationCallbacks;
{
    if (self.videoInputReadyCallback != NULL) {
        if (self.assetWriter.status != AVAssetWriterStatusWriting) {
            [self.assetWriter startWriting];
        }
        self.videoQueue = dispatch_queue_create("com.sunsetlakesoftware.GPUImage.videoReadingQueue", NULL);
        [self.assetWriterVideoInput requestMediaDataWhenReadyOnQueue:self.videoQueue usingBlock:^{
            if(self.isPaused)
            {
                //NSLog(@"video requestMediaDataWhenReadyOnQueue paused");
                // if we don't sleep, we'll get called back almost immediately, chewing up CPU
                usleep(10000);
                return;
            }
            //NSLog(@"video requestMediaDataWhenReadyOnQueue begin");
            while (self.assetWriterVideoInput.readyForMoreMediaData && ! self.isPaused) {
                if (self.videoInputReadyCallback && ! self.videoInputReadyCallback() && ! self.videoEncodingIsFinished) {
                    runAsynchronouslyOnContextQueue(self.movieWriterContext, ^{
                        if (self.assetWriter.status == AVAssetWriterStatusWriting && ! self.videoEncodingIsFinished) {
                            self.videoEncodingIsFinished = YES;
                            [self.assetWriterVideoInput markAsFinished];
                        }
                    });
                }
            }
            //NSLog(@"video requestMediaDataWhenReadyOnQueue end");
        }];
    }
    
    if (self.audioInputReadyCallback != NULL) {
        self.audioQueue = dispatch_queue_create("com.sunsetlakesoftware.GPUImage.audioReadingQueue", NULL);
        [self.assetWriterAudioInput requestMediaDataWhenReadyOnQueue:self.audioQueue usingBlock:^{
            if (self.isPaused) {
                //NSLog(@"audio requestMediaDataWhenReadyOnQueue paused");
                // if we don't sleep, we'll get called back almost immediately, chewing up CPU
                usleep(10000);
                return;
            }
            //NSLog(@"audio requestMediaDataWhenReadyOnQueue begin");
            while (self.assetWriterAudioInput.readyForMoreMediaData && ! self.isPaused) {
                if (self.audioInputReadyCallback && ! self.audioInputReadyCallback() && ! self.audioEncodingIsFinished) {
                    runAsynchronouslyOnContextQueue(_movieWriterContext, ^{
                        if (self.assetWriter.status == AVAssetWriterStatusWriting && !self.audioEncodingIsFinished) {
                            self.audioEncodingIsFinished = YES;
                            [self.assetWriterAudioInput markAsFinished];
                        }
                    });
                }
            }
            //NSLog(@"audio requestMediaDataWhenReadyOnQueue end");
        }];
    }        
    
}

#pragma mark -
#pragma mark Frame rendering

- (void)createDataFBO;
{
    glActiveTexture(GL_TEXTURE1);
    glGenFramebuffers(1, &movieFramebuffer);
    glBindFramebuffer(GL_FRAMEBUFFER, movieFramebuffer);
    
    if ([GPUImageContext supportsFastTextureUpload])
    {
        // Code originally sourced from http://allmybrain.com/2011/12/08/rendering-to-a-texture-with-ios-5-texture-cache-api/
        

        CVPixelBufferPoolCreatePixelBuffer (NULL, [self.assetWriterPixelBufferInput pixelBufferPool], &renderTarget);

        /* AVAssetWriter will use BT.601 conversion matrix for RGB to YCbCr conversion
         * regardless of the kCVImageBufferYCbCrMatrixKey value.
         * Tagging the resulting video file as BT.601, is the best option right now.
         * Creating a proper BT.709 video is not possible at the moment.
         */
        CVBufferSetAttachment(renderTarget, kCVImageBufferColorPrimariesKey, kCVImageBufferColorPrimaries_ITU_R_709_2, kCVAttachmentMode_ShouldPropagate);
        CVBufferSetAttachment(renderTarget, kCVImageBufferYCbCrMatrixKey, kCVImageBufferYCbCrMatrix_ITU_R_601_4, kCVAttachmentMode_ShouldPropagate);
        CVBufferSetAttachment(renderTarget, kCVImageBufferTransferFunctionKey, kCVImageBufferTransferFunction_ITU_R_709_2, kCVAttachmentMode_ShouldPropagate);
        
        CVOpenGLESTextureCacheCreateTextureFromImage (kCFAllocatorDefault, [_movieWriterContext coreVideoTextureCache], renderTarget,
                                                      NULL, // texture attributes
                                                      GL_TEXTURE_2D,
                                                      GL_RGBA, // opengl format
                                                      (int)self.videoSize.width,
                                                      (int)self.videoSize.height,
                                                      GL_BGRA, // native iOS format
                                                      GL_UNSIGNED_BYTE,
                                                      0,
                                                      &renderTexture);
        
        glBindTexture(CVOpenGLESTextureGetTarget(renderTexture), CVOpenGLESTextureGetName(renderTexture));
        glTexParameterf(GL_TEXTURE_2D, GL_TEXTURE_WRAP_S, GL_CLAMP_TO_EDGE);
        glTexParameterf(GL_TEXTURE_2D, GL_TEXTURE_WRAP_T, GL_CLAMP_TO_EDGE);
        
        glFramebufferTexture2D(GL_FRAMEBUFFER, GL_COLOR_ATTACHMENT0, GL_TEXTURE_2D, CVOpenGLESTextureGetName(renderTexture), 0);
    }
    else
    {
        glGenRenderbuffers(1, &movieRenderbuffer);
        glBindRenderbuffer(GL_RENDERBUFFER, movieRenderbuffer);
        glRenderbufferStorage(GL_RENDERBUFFER, GL_RGBA8_OES, (int)self.videoSize.width, (int)self.videoSize.height);
        glFramebufferRenderbuffer(GL_FRAMEBUFFER, GL_COLOR_ATTACHMENT0, GL_RENDERBUFFER, movieRenderbuffer);	
    }
    
	
	GLenum status = glCheckFramebufferStatus(GL_FRAMEBUFFER);
    
    NSAssert(status == GL_FRAMEBUFFER_COMPLETE, @"Incomplete filter FBO: %d", status);
}

- (void)destroyDataFBO;
{
    runSynchronouslyOnContextQueue(self.movieWriterContext, ^{
        [self.movieWriterContext useAsCurrentContext];

        if (movieFramebuffer) {
            glDeleteFramebuffers(1, &movieFramebuffer);
            movieFramebuffer = 0;
        }
        
        if (movieRenderbuffer) {
            glDeleteRenderbuffers(1, &movieRenderbuffer);
            movieRenderbuffer = 0;
        }
        
        if ([GPUImageContext supportsFastTextureUpload]) {
            if (renderTexture) {
                CFRelease(renderTexture);
            }
            if (renderTarget) {
                CVPixelBufferRelease(renderTarget);
            }
            
        }
    });
}

- (void)setFilterFBO;
{
    if (!movieFramebuffer) {
        [self createDataFBO];
    }
    
    glBindFramebuffer(GL_FRAMEBUFFER, movieFramebuffer);
    glViewport(0, 0, (int)self.videoSize.width, (int)self.videoSize.height);
}

- (void)renderAtInternalSizeUsingFramebuffer:(GPUImageFramebuffer *)inputFramebufferToUse;
{
    [self.movieWriterContext useAsCurrentContext];
    [self setFilterFBO];
    
    [self.movieWriterContext setContextShaderProgram:self.colorSwizzlingProgram];
    
    glClearColor(1.0f, 0.0f, 0.0f, 1.0f);
    glClear(GL_COLOR_BUFFER_BIT | GL_DEPTH_BUFFER_BIT);
    
    // This needs to be flipped to write out to video correctly
    static const GLfloat squareVertices[] = {
        -1.0f, -1.0f,
        1.0f, -1.0f,
        -1.0f,  1.0f,
        1.0f,  1.0f,
    };
    
    const GLfloat *textureCoordinates = [GPUImageFilter textureCoordinatesForRotation:self.inputRotation];
    
	glActiveTexture(GL_TEXTURE4);
	glBindTexture(GL_TEXTURE_2D, [inputFramebufferToUse texture]);
	glUniform1i(self.colorSwizzlingInputTextureUniform, 4);
    
//    NSLog(@"Movie writer framebuffer: %@", inputFramebufferToUse);
    
    glVertexAttribPointer(self.colorSwizzlingPositionAttribute, 2, GL_FLOAT, 0, 0, squareVertices);
	glVertexAttribPointer(self.colorSwizzlingTextureCoordinateAttribute, 2, GL_FLOAT, 0, 0, textureCoordinates);
    
    glDrawArrays(GL_TRIANGLE_STRIP, 0, 4);
    glFinish();
}

#pragma mark -
#pragma mark GPUImageInput protocol

- (void)newFrameReadyAtTime:(CMTime)frameTime atIndex:(NSInteger)textureIndex;
{
    if (!self.isRecording) {
        [self.firstInputFramebuffer unlock];
        return;
    }

    // Drop frames forced by images and other things with no time constants
    // Also, if two consecutive times with the same value are added to the movie, it aborts recording, so I bail on that case
    if ( (CMTIME_IS_INVALID(frameTime)) || (CMTIME_COMPARE_INLINE(frameTime, ==, self.previousFrameTime)) || (CMTIME_IS_INDEFINITE(frameTime)) ) {
        [self.firstInputFramebuffer unlock];
        return;
    }

    if (CMTIME_IS_INVALID(self.startTime)) {
        runSynchronouslyOnContextQueue(self.movieWriterContext, ^{
            if (self.assetWriter.status == AVAssetWriterStatusFailed) {
                @throw [NSException exceptionWithName:@"AVAssetWriter Error" reason:@"Can't write to a failed status writer" userInfo:nil];
            }
            else if ((self.videoInputReadyCallback == NULL) && (self.assetWriter.status != AVAssetWriterStatusWriting)) {
                [self.assetWriter startWriting];
            }
            
            [self.assetWriter startSessionAtSourceTime:frameTime];
            self.startTime = frameTime;
        });
    }

    GPUImageFramebuffer *inputFramebufferForBlock = self.firstInputFramebuffer;
    glFinish();

    runAsynchronouslyOnContextQueue(self.movieWriterContext, ^{
        if (!self.assetWriterVideoInput.readyForMoreMediaData && self.encodingLiveVideo) {
            [inputFramebufferForBlock unlock];
            NSLog(@"1: Had to drop a video frame: %@", CFBridgingRelease(CMTimeCopyDescription(kCFAllocatorDefault, frameTime)));
            return;
        }
        
        // Render the frame with swizzled colors, so that they can be uploaded quickly as BGRA frames
        [self.movieWriterContext useAsCurrentContext];
        [self renderAtInternalSizeUsingFramebuffer:inputFramebufferForBlock];
        
        CVPixelBufferRef pixel_buffer = NULL;
        
        if ([GPUImageContext supportsFastTextureUpload]) {
            pixel_buffer = renderTarget;
            CVPixelBufferLockBaseAddress(pixel_buffer, 0);
        } else {
            CVReturn status = CVPixelBufferPoolCreatePixelBuffer (NULL, [self.assetWriterPixelBufferInput pixelBufferPool], &pixel_buffer);
            if ((pixel_buffer == NULL) || (status != kCVReturnSuccess)) {
                CVPixelBufferRelease(pixel_buffer);
                return;
            } else {
                CVPixelBufferLockBaseAddress(pixel_buffer, 0);
                
                GLubyte *pixelBufferData = (GLubyte *)CVPixelBufferGetBaseAddress(pixel_buffer);
                glReadPixels(0, 0, self.videoSize.width, self.videoSize.height, GL_RGBA, GL_UNSIGNED_BYTE, pixelBufferData);
            }
        }
        
        void(^write)() = ^() {
            while (!self.assetWriterVideoInput.readyForMoreMediaData && ! self.encodingLiveVideo && ! self.videoEncodingIsFinished) {
                NSDate *maxDate = [NSDate dateWithTimeIntervalSinceNow:0.1];
                //            NSLog(@"video waiting...");
                [[NSRunLoop currentRunLoop] runUntilDate:maxDate];
            }
            
            if (!self.assetWriterVideoInput.readyForMoreMediaData) {
                NSLog(@"2: Had to drop a video frame: %@", CFBridgingRelease(CMTimeCopyDescription(kCFAllocatorDefault, frameTime)));
            } else if (self.assetWriter.status == AVAssetWriterStatusWriting) {
                if (![self.assetWriterPixelBufferInput appendPixelBuffer:pixel_buffer withPresentationTime:frameTime]) {
                    NSLog(@"Problem appending pixel buffer at time: %@", CFBridgingRelease(CMTimeCopyDescription(kCFAllocatorDefault, frameTime)));
                }
                self.allowWriteAudio = YES;
            } else {
                NSLog(@"Couldn't write a frame");
                //NSLog(@"Wrote a video frame: %@", CFBridgingRelease(CMTimeCopyDescription(kCFAllocatorDefault, frameTime)));
            }
            CVPixelBufferUnlockBaseAddress(pixel_buffer, 0);
            
            self.previousFrameTime = frameTime;
            
            if (![GPUImageContext supportsFastTextureUpload]) {
                CVPixelBufferRelease(pixel_buffer);
            }
        };
        
        write();
        
        [inputFramebufferForBlock unlock];
    });
}

- (NSInteger)nextAvailableTextureIndex;
{
    return 0;
}

- (void)setInputFramebuffer:(GPUImageFramebuffer *)newInputFramebuffer atIndex:(NSInteger)textureIndex;
{
    [newInputFramebuffer lock];
//    runSynchronouslyOnContextQueue(_movieWriterContext, ^{
        self.firstInputFramebuffer = newInputFramebuffer;
//    });
}

- (void)setInputRotation:(GPUImageRotationMode)newInputRotation atIndex:(NSInteger)textureIndex;
{
    self.inputRotation = newInputRotation;
}

- (void)setInputSize:(CGSize)newSize atIndex:(NSInteger)textureIndex;
{
    
}

- (CGSize)maximumOutputSize;
{
    return self.videoSize;
}

- (void)endProcessing 
{
    if (self.completionBlock) {
        if (!self.alreadyFinishedRecording) {
            self.alreadyFinishedRecording = YES;
            self.completionBlock();
        }        
    }
}

- (BOOL)shouldIgnoreUpdatesToThisTarget;
{
    return NO;
}

- (BOOL)wantsMonochromeInput;
{
    return NO;
}

- (void)setCurrentlyReceivingMonochromeInput:(BOOL)newValue;
{
    
}

#pragma mark -
#pragma mark Accessors

- (void)setHasAudioTrack:(BOOL)newValue
{
	[self setHasAudioTrack:newValue audioSettings:nil];
}

- (void)setHasAudioTrack:(BOOL)newValue audioSettings:(NSDictionary *)audioOutputSettings;
{
    _hasAudioTrack = newValue;
    
    if (_hasAudioTrack)
    {
        if (_shouldPassthroughAudio)
        {
			// Do not set any settings so audio will be the same as passthrough
			audioOutputSettings = nil;
        }
        else if (audioOutputSettings == nil)
        {
            AVAudioSession *sharedAudioSession = [AVAudioSession sharedInstance];
            double preferredHardwareSampleRate;
            
            if ([sharedAudioSession respondsToSelector:@selector(sampleRate)])
            {
                preferredHardwareSampleRate = [sharedAudioSession sampleRate];
            }
            else
            {
#pragma clang diagnostic push
#pragma clang diagnostic ignored "-Wdeprecated-declarations"
                preferredHardwareSampleRate = [[AVAudioSession sharedInstance] currentHardwareSampleRate];
#pragma clang diagnostic pop
            }
            
            AudioChannelLayout acl;
            bzero( &acl, sizeof(acl));
            acl.mChannelLayoutTag = kAudioChannelLayoutTag_Mono;
            
            audioOutputSettings = [NSDictionary dictionaryWithObjectsAndKeys:
                                         [ NSNumber numberWithInt: kAudioFormatMPEG4AAC], AVFormatIDKey,
                                         [ NSNumber numberWithInt: 1 ], AVNumberOfChannelsKey,
                                         [ NSNumber numberWithFloat: preferredHardwareSampleRate ], AVSampleRateKey,
                                         [ NSData dataWithBytes: &acl length: sizeof( acl ) ], AVChannelLayoutKey,
                                         //[ NSNumber numberWithInt:AVAudioQualityLow], AVEncoderAudioQualityKey,
                                         [ NSNumber numberWithInt: 64000 ], AVEncoderBitRateKey,
                                         nil];
/*
            AudioChannelLayout acl;
            bzero( &acl, sizeof(acl));
            acl.mChannelLayoutTag = kAudioChannelLayoutTag_Mono;
            
            audioOutputSettings = [NSDictionary dictionaryWithObjectsAndKeys:
                                   [ NSNumber numberWithInt: kAudioFormatMPEG4AAC ], AVFormatIDKey,
                                   [ NSNumber numberWithInt: 1 ], AVNumberOfChannelsKey,
                                   [ NSNumber numberWithFloat: 44100.0 ], AVSampleRateKey,
                                   [ NSNumber numberWithInt: 64000 ], AVEncoderBitRateKey,
                                   [ NSData dataWithBytes: &acl length: sizeof( acl ) ], AVChannelLayoutKey,
                                   nil];*/
        }
        
        self.assetWriterAudioInput = [AVAssetWriterInput assetWriterInputWithMediaType:AVMediaTypeAudio outputSettings:audioOutputSettings];
        [self.assetWriter addInput:self.assetWriterAudioInput];
        self.assetWriterAudioInput.expectsMediaDataInRealTime = self.encodingLiveVideo;
    }
    else
    {
        // Remove audio track if it exists
    }
}

- (NSArray *)metaData
{
    return self.assetWriter.metadata;
}

- (void)setMetaData:(NSArray *)metaData
{
    self.assetWriter.metadata = metaData;
}
 
- (CMTime)duration
{
    if( ! CMTIME_IS_VALID(self.startTime) )
        return kCMTimeZero;
    if( ! CMTIME_IS_NEGATIVE_INFINITY(self.previousFrameTime) )
        return CMTimeSubtract(self.previousFrameTime, self.startTime);
    if( ! CMTIME_IS_NEGATIVE_INFINITY(self.previousAudioTime) )
        return CMTimeSubtract(self.previousAudioTime, self.startTime);
    return kCMTimeZero;
}

- (CGAffineTransform)transform
{
    return self.assetWriterVideoInput.transform;
}

- (void)setTransform:(CGAffineTransform)transform
{
    self.assetWriterVideoInput.transform = transform;
}

@end
