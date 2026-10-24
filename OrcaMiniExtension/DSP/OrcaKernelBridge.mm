//
//  OrcaKernelBridge.mm
//
#import "OrcaKernelBridge.h"
#import "OrcaMiniExtensionDSPKernel.hpp"

static inline OrcaMiniExtensionDSPKernel *K(OrcaKernelRef r) { return static_cast<OrcaMiniExtensionDSPKernel *>(r); }

OrcaKernelRef OrcaKernelCreate(void) { return OrcaMiniExtensionDSPKernel::create(); }
void OrcaKernelDestroy(OrcaKernelRef k) { OrcaMiniExtensionDSPKernel::destroy(K(k)); }
void OrcaKernelInitialize(OrcaKernelRef k, double sr) { K(k)->initialize(sr); }
void OrcaKernelDeinitialize(OrcaKernelRef k) { K(k)->deInitialize(); }
BOOL OrcaKernelIsBypassed(OrcaKernelRef k) { return K(k)->isBypassed(); }
void OrcaKernelSetBypass(OrcaKernelRef k, BOOL b) { K(k)->setBypass(b); }
AUAudioFrameCount OrcaKernelMaxFrames(OrcaKernelRef k) { return K(k)->maximumFramesToRender(); }
void OrcaKernelSetMaxFrames(OrcaKernelRef k, AUAudioFrameCount n) { K(k)->setMaximumFramesToRender(n); }
void OrcaKernelSetBlocks(OrcaKernelRef k, AUHostMusicalContextBlock ctx, AUHostTransportStateBlock tr,
                         AUMIDIEventListBlock list, AUMIDIOutputEventBlock legacy) {
    K(k)->setMusicalContextBlock(ctx); K(k)->setTransportStateBlock(tr);
    K(k)->setMIDIOutputEventListBlock(list); K(k)->setMIDIOutputEventBlock(legacy);
}
void OrcaKernelSetParameter(OrcaKernelRef k, AUParameterAddress a, AUValue v) { K(k)->setParameter(a, v); }
AUValue OrcaKernelGetParameter(OrcaKernelRef k, AUParameterAddress a) { return K(k)->getParameter(a); }
int OrcaKernelSpeed(OrcaKernelRef k) { return K(k)->speed(); }
MIDIProtocolID OrcaKernelMIDIProtocol(void) { return kMIDIProtocol_1_0; }
uint32_t OrcaKernelGeneration(OrcaKernelRef k) { return K(k)->generation(); }
BOOL OrcaKernelHostPlaying(OrcaKernelRef k) { return K(k)->hostPlaying(); }
int OrcaKernelDepth(OrcaKernelRef k) { return K(k)->depth(); }
BOOL OrcaKernelPush(OrcaKernelRef k, uint32_t gen, const uint8_t *bytes, int32_t count) { return K(k)->tryPush(gen, bytes, count); }
void OrcaKernelSetStartFrames(OrcaKernelRef k, const uint8_t *bytes, const int32_t *lens, int32_t count) { K(k)->setStartFrames(bytes, lens, count); }
uint32_t OrcaKernelStartUsedGen(OrcaKernelRef k) { return K(k)->startUsedGen(); }
int OrcaKernelSlotBytes(void) { return OrcaMiniExtensionDSPKernel::kSlotBytes; }

AUInternalRenderBlock OrcaKernelRenderBlock(OrcaKernelRef ref) {
    OrcaMiniExtensionDSPKernel *k = K(ref);
    return ^AUAudioUnitStatus(AudioUnitRenderActionFlags *actionFlags,
                              const AudioTimeStamp *timestamp,
                              AUAudioFrameCount frameCount,
                              NSInteger outputBusNumber,
                              AudioBufferList *outputData,
                              const AURenderEvent *events,
                              AURenderPullInputBlock __unsafe_unretained pullInputBlock) {
        if (frameCount > k->maximumFramesToRender()) return kAudioUnitErr_TooManyFramesToProcess;
        const AUEventSampleTime now = (AUEventSampleTime)timestamp->mSampleTime;
        for (AURenderEvent const *e = events; e != nullptr; e = e->head.next) k->handleOneEvent(now, e);
        k->processBlock(now, frameCount);
        return noErr;
    };
}
