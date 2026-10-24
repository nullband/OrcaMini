//
//  OrcaKernelBridge.h - plain C interface to the real-time kernel (the C++ class holds atomics, so Swift only sees an opaque pointer)
//
#pragma once
#import <AudioToolbox/AudioToolbox.h>
#import <CoreMIDI/CoreMIDI.h>
#import <stdint.h>

#ifdef __cplusplus
extern "C" {
#endif

typedef void * OrcaKernelRef;

OrcaKernelRef OrcaKernelCreate(void);
void OrcaKernelDestroy(OrcaKernelRef k);
void OrcaKernelInitialize(OrcaKernelRef k, double sampleRate);
void OrcaKernelDeinitialize(OrcaKernelRef k);
BOOL OrcaKernelIsBypassed(OrcaKernelRef k);
void OrcaKernelSetBypass(OrcaKernelRef k, BOOL bypass);
AUAudioFrameCount OrcaKernelMaxFrames(OrcaKernelRef k);
void OrcaKernelSetMaxFrames(OrcaKernelRef k, AUAudioFrameCount n);
void OrcaKernelSetBlocks(OrcaKernelRef k, AUHostMusicalContextBlock ctx, AUHostTransportStateBlock transport,
                         AUMIDIEventListBlock midiList, AUMIDIOutputEventBlock midiLegacy);
void OrcaKernelSetParameter(OrcaKernelRef k, AUParameterAddress address, AUValue value);
AUValue OrcaKernelGetParameter(OrcaKernelRef k, AUParameterAddress address);
int OrcaKernelSpeed(OrcaKernelRef k);
MIDIProtocolID OrcaKernelMIDIProtocol(void);
AUInternalRenderBlock OrcaKernelRenderBlock(OrcaKernelRef k);

// engine-thread side (never called from the audio thread)
uint32_t OrcaKernelGeneration(OrcaKernelRef k);
BOOL OrcaKernelHostPlaying(OrcaKernelRef k);
int OrcaKernelDepth(OrcaKernelRef k);
BOOL OrcaKernelPush(OrcaKernelRef k, uint32_t generation, const uint8_t *bytes, int32_t count);
int OrcaKernelSlotBytes(void);
void OrcaKernelSetStartFrames(OrcaKernelRef k, const uint8_t *bytes, const int32_t *lens, int32_t count);
uint32_t OrcaKernelStartUsedGen(OrcaKernelRef k);

#ifdef __cplusplus
}
#endif
