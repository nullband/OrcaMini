//
//  OrcaMiniExtensionDSPKernel.hpp
//  OrcaMiniExtension
//
//  The real-time half of the plugin. It never runs Orca itself: a background thread (Swift) computes Orca frames a few frames
//  AHEAD and pushes each frame's MIDI bytes into a lock-free ring buffer. This kernel, on the audio thread, follows the HOST's
//  beat position, decides which sample each Orca frame lands on (1 frame = 1/16 note by default), pops the prepared frame and
//  sends its MIDI at exactly that sample. No allocation, no locks, no Swift on the audio thread.
//

#pragma once

#import <AudioToolbox/AudioToolbox.h>
#import <CoreMIDI/CoreMIDI.h>
#import <algorithm>
#import <atomic>
#import <cmath>
#import <cstdint>
#import <cstring>

#import "OrcaMiniExtensionParameterAddresses.h"

class OrcaMiniExtensionDSPKernel {
public:
    static constexpr int kSlots = 64;                 // ring size (frames)
    static constexpr int kSlotBytes = 3 * 640;        // up to 640 MIDI messages in one Orca frame
    static constexpr int kSpeedSteps = 8;
    static constexpr int kStartFrames = 4;            // opening frames prepared while the host is stopped

    struct Slot {
        uint32_t gen = 0;
        int32_t n = 0;
        uint8_t b[kSlotBytes];
    };

    // MARK: lifetime (Swift holds a raw pointer; the class has atomics so it cannot be copied)
    static OrcaMiniExtensionDSPKernel* create() { return new OrcaMiniExtensionDSPKernel(); }
    static void destroy(OrcaMiniExtensionDSPKernel* k) { delete k; }

    void initialize(double inSampleRate) {
        mSampleRate = inSampleRate;
        resetTransport();
    }
    void deInitialize() {}

    bool isBypassed() const { return mBypassed; }
    void setBypass(bool shouldBypass) { mBypassed = shouldBypass; }
    AUAudioFrameCount maximumFramesToRender() const { return mMaxFramesToRender; }
    void setMaximumFramesToRender(const AUAudioFrameCount &maxFrames) { mMaxFramesToRender = maxFrames; }

    void setMusicalContextBlock(AUHostMusicalContextBlock b) { mMusicalContextBlock = b; }
    void setTransportStateBlock(AUHostTransportStateBlock b) { mTransportStateBlock = b; }
    void setMIDIOutputEventListBlock(AUMIDIEventListBlock b) { mMIDIOutList = b; }
    void setMIDIOutputEventBlock(AUMIDIOutputEventBlock b) { mMIDIOutLegacy = b; }
    MIDIProtocolID AudioUnitMIDIProtocol() const { return kMIDIProtocol_1_0; }

    // MARK: parameters
    void setParameter(AUParameterAddress address, AUValue value) {
        if (address == speedIndex) mSpeed.store(std::max(0, std::min(kSpeedSteps - 1, (int)std::lround(value))), std::memory_order_relaxed);
    }
    AUValue getParameter(AUParameterAddress address) const {
        if (address == speedIndex) return (AUValue)mSpeed.load(std::memory_order_relaxed);
        return 0.f;
    }
    int speed() const { return mSpeed.load(std::memory_order_relaxed); }

    // MARK: producer side (called from the engine thread, never from the audio thread)
    uint32_t generation() const { return mGen.load(std::memory_order_acquire); }
    bool hostPlaying() const { return mPlaying.load(std::memory_order_acquire); }
    int depth() const { return (int)(mTail.load(std::memory_order_relaxed) - mHead.load(std::memory_order_acquire)); }
    /// push one Orca frame (n bytes of MIDI, 3 per message). returns false when the ring is full
    bool tryPush(uint32_t gen, const uint8_t* bytes, int32_t count) {
        uint32_t tail = mTail.load(std::memory_order_relaxed), head = mHead.load(std::memory_order_acquire);
        if ((int)(tail - head) >= kSlots) return false;
        Slot& s = mRing[tail % kSlots];
        s.gen = gen;
        s.n = std::min<int32_t>(count - count % 3, kSlotBytes);
        if (s.n > 0) std::memcpy(s.b, bytes, (size_t)s.n);
        mTail.store(tail + 1, std::memory_order_release);
        return true;
    }
    /// stopped-state preparation: the engine thread leaves the first Orca frames ready so the downbeat is never late.
    /// lens[i] = byte count of frame i (multiple of 3); bytes = all frames concatenated.
    void setStartFrames(const uint8_t* bytes, const int32_t* lens, int32_t count) {
        uint32_t v = mStartVersion.load(std::memory_order_relaxed);
        mStartVersion.store(v + 1, std::memory_order_release);                      // odd = being written
        std::atomic_thread_fence(std::memory_order_seq_cst);
        mStartCount = std::min<int32_t>(count, kStartFrames);
        int off = 0;
        for (int i = 0; i < mStartCount; i++) {
            Slot& d = mStart[i];
            d.n = std::min<int32_t>(lens[i] - lens[i] % 3, kSlotBytes);
            if (d.n > 0) std::memcpy(d.b, bytes + off, (size_t)d.n);
            off += lens[i];
        }
        std::atomic_thread_fence(std::memory_order_seq_cst);
        mStartVersion.store(v + 2, std::memory_order_release);
        mStartValid.store(true, std::memory_order_release);
    }
    uint32_t startUsedGen() const { return mStartUsedGen.load(std::memory_order_acquire); }
    int64_t framesSent() const { return mFramesSent.load(std::memory_order_relaxed); }

    // MARK: real time
    void processBlock(AUEventSampleTime now, AUAudioFrameCount frames) {
        if (mBypassed || !mMusicalContextBlock) return;
        double tempo = 120.0, beat = 0.0;
        if (!mMusicalContextBlock(&tempo, nullptr, nullptr, &beat, nullptr, nullptr)) return;
        if (tempo < 1.0) tempo = 120.0;

        bool playing;
        if (mTransportStateBlock) {
            AUHostTransportStateFlags flags = 0;
            playing = mTransportStateBlock(&flags, nullptr, nullptr, nullptr) ? ((flags & AUHostTransportStateMoving) != 0) : mWasPlaying;
        } else {
            playing = (mLastTo >= 0.0) && (std::fabs(beat - mLastTo) < 4.0) && (beat != mLastBeatSeen);   // fallback: moving if the position advanced
        }
        mLastBeatSeen = beat;

        if (!playing) {
            mPlaying.store(false, std::memory_order_release);
            if (mWasPlaying) { allNotesOff(now); mGen.fetch_add(1, std::memory_order_acq_rel); drainRing(); }
            mWasPlaying = false; mLastTo = -1.0;
            return;
        }

        const double eps = 1e-9;
        const double fpb = kFramesPerBeat[mSpeed.load(std::memory_order_relaxed)];
        const double span = (double)frames * tempo / (60.0 * mSampleRate);
        const double to = beat + span;

        if (!mWasPlaying) {                                           // transport start: new generation, first frame on the first grid point
            const uint32_t newGen = mGen.fetch_add(1, std::memory_order_acq_rel) + 1; drainRing();
            injectStartFrames(newGen);
            mNextIndex = (int64_t)std::ceil(beat * fpb - eps);
            mPlaying.store(true, std::memory_order_release);          // only AFTER the new generation exists, so the engine thread never feeds the old one
        } else if (std::fabs(beat - mLastTo) > 0.01) {                // locate / loop jump: realign, keep going
            mNextIndex = (int64_t)std::ceil(beat * fpb - eps);
        } else if (fpb != mLastFPB) {                                 // speed changed mid-play
            mNextIndex = (int64_t)std::ceil(beat * fpb - eps);
        }

        while ((double)mNextIndex / fpb < to - eps) {
            const double pos = (double)mNextIndex / fpb;
            int64_t off = (int64_t)std::llround((pos - beat) * 60.0 * mSampleRate / tempo);
            if (off < 0) off = 0;
            if (off >= (int64_t)frames) off = (int64_t)frames - 1;
            emitFrame(now + off);
            mNextIndex++;
        }
        mWasPlaying = true; mLastTo = to; mLastFPB = fpb;
    }

    void handleOneEvent(AUEventSampleTime now, AURenderEvent const *event) {
        if (event->head.eventType == AURenderEventParameter || event->head.eventType == AURenderEventParameterRamp)
            setParameter(event->parameter.parameterAddress, event->parameter.value);
    }

    AUHostMusicalContextBlock mMusicalContextBlock = nullptr;
    AUHostTransportStateBlock mTransportStateBlock = nullptr;
    AUMIDIEventListBlock mMIDIOutList = nullptr;
    AUMIDIOutputEventBlock mMIDIOutLegacy = nullptr;
    bool mBypassed = false;
    AUAudioFrameCount mMaxFramesToRender = 1024;
    double mSampleRate = 44100.0;

    static constexpr double kFramesPerBeat[kSpeedSteps] = {1, 2, 3, 4, 6, 8, 12, 16};

private:
    OrcaMiniExtensionDSPKernel() = default;

    void resetTransport() { mWasPlaying = false; mLastTo = -1.0; mLastBeatSeen = -1.0; mNextIndex = 0; mLastFPB = 4.0; }

    /// drop whatever the old generation left in the ring
    /// copy the prepared opening frames into the (just drained) ring under the new generation. a torn copy (engine thread rewriting at that instant) is discarded.
    void injectStartFrames(uint32_t newGen) {
        if (!mStartValid.load(std::memory_order_acquire)) return;
        const uint32_t v1 = mStartVersion.load(std::memory_order_acquire);
        if ((v1 & 1u) || v1 == 0) return;
        const int n = mStartCount;
        if (n <= 0 || n > kSlots) return;
        const uint32_t tail = mTail.load(std::memory_order_relaxed);
        for (int i = 0; i < n; i++) {
            Slot& d = mRing[(tail + i) % kSlots];
            d.gen = newGen; d.n = mStart[i].n;
            if (d.n > 0) std::memcpy(d.b, mStart[i].b, (size_t)d.n);
        }
        std::atomic_thread_fence(std::memory_order_seq_cst);
        if (mStartVersion.load(std::memory_order_acquire) != v1) return;          // torn: do not publish
        mTail.store(tail + (uint32_t)n, std::memory_order_release);
        mStartUsedGen.store(newGen, std::memory_order_release);
        mStartValid.store(false, std::memory_order_release);                       // a start buffer is single use
    }

    void drainRing() { mHead.store(mTail.load(std::memory_order_acquire), std::memory_order_release); }

    void sendMessage(AUEventSampleTime t, uint8_t status, uint8_t d1, uint8_t d2) {
        if (mMIDIOutList) {
            MIDIEventList list;
            MIDIEventPacket *pkt = MIDIEventListInit(&list, kMIDIProtocol_1_0);
            UInt32 word = (0x2u << 28) | ((UInt32)status << 16) | ((UInt32)d1 << 8) | (UInt32)d2;
            MIDIEventListAdd(&list, sizeof(list), pkt, 0, 1, &word);
            mMIDIOutList(t, 0, &list);
        } else if (mMIDIOutLegacy) {
            uint8_t bytes[3] = { status, d1, d2 };
            mMIDIOutLegacy(t, 0, 3, bytes);
        }
    }

    void emitFrame(AUEventSampleTime t) {
        uint32_t head = mHead.load(std::memory_order_relaxed);
        const uint32_t gen = mGen.load(std::memory_order_acquire);
        for (;;) {                                                       // skip slots from an older generation
            if (head == mTail.load(std::memory_order_acquire)) { mHead.store(head, std::memory_order_release); return; }   // underrun: nothing prepared, skip this frame
            Slot& s = mRing[head % kSlots];
            if (s.gen != gen) { head++; continue; }
            // 1 frame -> one packet list per message (host-safe, tiny)
            for (int i = 0; i + 2 < s.n; i += 3) sendMessage(t, s.b[i], s.b[i + 1], s.b[i + 2]);
            head++;
            mHead.store(head, std::memory_order_release);
            mFramesSent.fetch_add(1, std::memory_order_relaxed);
            return;
        }
    }

    void allNotesOff(AUEventSampleTime t) {
        for (uint8_t ch = 0; ch < 16; ch++) sendMessage(t, (uint8_t)(0xB0 + ch), 123, 0);
    }

    // transport state (audio thread only)
    bool mWasPlaying = false;
    double mLastTo = -1.0, mLastBeatSeen = -1.0, mLastFPB = 4.0;
    int64_t mNextIndex = 0;

    // shared with the engine thread
    std::atomic<uint32_t> mGen{1};
    std::atomic<uint32_t> mHead{0}, mTail{0};
    std::atomic<bool> mPlaying{false};
    std::atomic<int> mSpeed{3};
    std::atomic<int64_t> mFramesSent{0};
    Slot mRing[kSlots];
    // opening frames (seqlock: written by the engine thread, read once by the audio thread at transport start)
    std::atomic<uint32_t> mStartVersion{0};
    std::atomic<bool> mStartValid{false};
    std::atomic<uint32_t> mStartUsedGen{0};
    int32_t mStartCount = 0;
    Slot mStart[kStartFrames];
};
