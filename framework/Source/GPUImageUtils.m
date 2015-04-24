//
//  GPUImageUtils.m
//  GPUImage
//
//  Created by Andrew Poes on 4/24/15.
//  Copyright (c) 2015 Brad Larson. All rights reserved.
//

#import "GPUImageUtils.h"
#import <AVFoundation/AVFoundation.h>

@implementation GPUImageUtils

+ (NSString *)AVFoundationErrorEnumStringFromCode:(NSInteger)error
{
    switch (error) {
        case AVErrorUnknown:
            return @"AVErrorUnknown";
            
        case AVErrorOutOfMemory:
            return @"AVErrorOutOfMemory";
            
        case AVErrorSessionNotRunning:
            return @"AVErrorSessionNotRunning";
            
        case AVErrorDeviceAlreadyUsedByAnotherSession:
            return @"AVErrorDeviceAlreadyUsedByAnotherSession";
            
        case AVErrorNoDataCaptured:
            return @"AVErrorNoDataCaptured";
            
        case AVErrorSessionConfigurationChanged:
            return @"AVErrorSessionConfigurationChanged";
            
        case AVErrorDiskFull:
            return @"AVErrorDiskFull";
            
        case AVErrorDeviceWasDisconnected:
            return @"AVErrorDeviceWasDisconnected";
            
        case AVErrorMediaChanged:
            return @"AVErrorMediaChanged";
            
        case AVErrorMaximumDurationReached:
            return @"AVErrorMaximumDurationReached";
            
        case AVErrorMaximumFileSizeReached:
            return @"AVErrorMaximumFileSizeReached";
            
        case AVErrorMediaDiscontinuity:
            return @"AVErrorMediaDiscontinuity";
            
        case AVErrorMaximumNumberOfSamplesForFileFormatReached:
            return @"AVErrorMaximumNumberOfSamplesForFileFormatReached";
            
        case AVErrorDeviceNotConnected:
            return @"AVErrorDeviceNotConnected";
            
        case AVErrorDeviceInUseByAnotherApplication:
            return @"AVErrorDeviceInUseByAnotherApplication";
            
        case AVErrorDeviceLockedForConfigurationByAnotherProcess:
            return @"AVErrorDeviceLockedForConfigurationByAnotherProcess";
            
#if TARGET_OS_IPHONE
        case AVErrorSessionWasInterrupted:
            return @"AVErrorSessionWasInterrupted";
            
        case AVErrorMediaServicesWereReset:
            return @"AVErrorMediaServicesWereReset";
#endif
            
        case AVErrorExportFailed:
            return @"AVErrorExportFailed";
            
        case AVErrorDecodeFailed:
            return @"AVErrorDecodeFailed";
            
        case AVErrorInvalidSourceMedia:
            return @"AVErrorInvalidSourceMedia";
            
        case AVErrorFileAlreadyExists:
            return @"AVErrorFileAlreadyExists";
            
        case AVErrorCompositionTrackSegmentsNotContiguous:
            return @"AVErrorCompositionTrackSegmentsNotContiguous";
            
        case AVErrorInvalidCompositionTrackSegmentDuration:
            return @"AVErrorInvalidCompositionTrackSegmentDuration";
            
        case AVErrorInvalidCompositionTrackSegmentSourceStartTime:
            return @"AVErrorInvalidCompositionTrackSegmentSourceStartTime";
            
        case AVErrorInvalidCompositionTrackSegmentSourceDuration:
            return @"AVErrorInvalidCompositionTrackSegmentSourceDuration";
            
        case AVErrorFileFormatNotRecognized:
            return @"AVErrorFileFormatNotRecognized";
            
        case AVErrorFileFailedToParse:
            return @"AVErrorFileFailedToParse";
            
        case AVErrorMaximumStillImageCaptureRequestsExceeded:
            return @"AVErrorMaximumStillImageCaptureRequestsExceeded";
            
        case AVErrorContentIsProtected:
            return @"AVErrorContentIsProtected";
            
        case AVErrorNoImageAtTime:
            return @"AVErrorNoImageAtTime";
            
        case AVErrorDecoderNotFound:
            return @"AVErrorDecoderNotFound";
            
        case AVErrorEncoderNotFound:
            return @"AVErrorEncoderNotFound";
            
        case AVErrorContentIsNotAuthorized:
            return @"AVErrorContentIsNotAuthorized";
            
        case AVErrorApplicationIsNotAuthorized:
            return @"AVErrorApplicationIsNotAuthorized";
            
#if TARGET_OS_IPHONE
        case AVErrorDeviceIsNotAvailableInBackground:
            return @"AVErrorDeviceIsNotAvailableInBackground";
#endif
            
        case AVErrorOperationNotSupportedForAsset:
            return @"AVErrorOperationNotSupportedForAsset";
            
        case AVErrorDecoderTemporarilyUnavailable:
            return @"AVErrorDecoderTemporarilyUnavailable";
            
        case AVErrorEncoderTemporarilyUnavailable:
            return @"AVErrorEncoderTemporarilyUnavailable";
            
        case AVErrorInvalidVideoComposition:
            return @"AVErrorInvalidVideoComposition";
            
        case AVErrorReferenceForbiddenByReferencePolicy:
            return @"AVErrorReferenceForbiddenByReferencePolicy";
            
        case AVErrorInvalidOutputURLPathExtension:
            return @"AVErrorInvalidOutputURLPathExtension";
            
        case AVErrorScreenCaptureFailed:
            return @"AVErrorScreenCaptureFailed";
            
        case AVErrorDisplayWasDisabled:
            return @"AVErrorDisplayWasDisabled";
            
        case AVErrorTorchLevelUnavailable:
            return @"AVErrorTorchLevelUnavailable";
            
#if TARGET_OS_IPHONE
        case AVErrorOperationInterrupted:
            return @"AVErrorOperationInterrupted";
#endif
            
        case AVErrorIncompatibleAsset:
            return @"AVErrorIncompatibleAsset";
            
        case AVErrorFailedToLoadMediaData:
            return @"AVErrorFailedToLoadMediaData";
            
        case AVErrorServerIncorrectlyConfigured:
            return @"AVErrorServerIncorrectlyConfigured";
            
        default:
            return @"";
    }
}

@end
