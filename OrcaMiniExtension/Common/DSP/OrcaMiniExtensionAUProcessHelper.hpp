//
//  OrcaMiniExtensionAUProcessHelper.hpp
//  OrcaMiniExtension
//
//

#pragma once

#import <AudioToolbox/AudioToolbox.h>
#import <AVFoundation/AVFoundation.h>

#include <vector>
#include "OrcaMiniExtensionDSPKernel.hpp"

//MARK:- AUProcessHelper Utility Class
class AUProcessHelper
{
public:
    AUProcessHelper(OrcaMiniExtensionDSPKernel& kernel)
    : mKernel{kernel} {}
    
    /// the kernel works on whole render calls (it needs the host beat at the START of the call), so events are only used for parameters
    void processWithEvents(AudioTimeStamp const *timestamp, AUAudioFrameCount frameCount, AURenderEvent const *events) {
        AUEventSampleTime now = AUEventSampleTime(timestamp->mSampleTime);
        for (AURenderEvent const *e = events; e != nullptr; e = e->head.next) mKernel.handleOneEvent(now, e);
        mKernel.processBlock(now, frameCount);
    }

    // Block which subclassers must provide to implement rendering.
    AUInternalRenderBlock internalRenderBlock() {
        /*
         Capture in locals to avoid ObjC member lookups. If "self" is captured in
         render, we're doing it wrong.
         */
        return ^AUAudioUnitStatus(AudioUnitRenderActionFlags                 *actionFlags,
                                  const AudioTimeStamp                       *timestamp,
                                  AUAudioFrameCount                           frameCount,
                                  NSInteger                                   outputBusNumber,
                                  AudioBufferList                            *outputData,
                                  const AURenderEvent                        *events,
                                  AURenderPullInputBlock __unsafe_unretained pullInputBlock) {
            
            if (frameCount > mKernel.maximumFramesToRender()) {
                return kAudioUnitErr_TooManyFramesToProcess;
            }
            
            /*
             Important:
             If the caller passed non-null output pointers (outputData->mBuffers[x].mData), use those.
             
             If the caller passed null output buffer pointers, process in memory owned by the Audio Unit
             and modify the (outputData->mBuffers[x].mData) pointers to point to this owned memory.
             The Audio Unit is responsible for preserving the validity of this memory until the next call to render,
             or deallocateRenderResources is called.
             
             If your algorithm cannot process in-place, you will need to preallocate an output buffer
             and use it here.
             
             See the description of the canProcessInPlace property.
             */
            processWithEvents(timestamp, frameCount, events);

            return noErr;
        };
        
    }
private:
    OrcaMiniExtensionDSPKernel& mKernel;
};
