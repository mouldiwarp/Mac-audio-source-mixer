// Single-producer / single-consumer stereo float ring (spec/features/control-and-recording.md).
// Used for recording (audio thread writes, writer thread reads) and for the
// file player (decoder thread writes, audio thread reads). Never blocks.
#ifndef STEREORING_H
#define STEREORING_H

#include <stdbool.h>
#include <stdint.h>

typedef struct StereoRing StereoRing;

StereoRing *StereoRingCreate(uint32_t capacityFrames);
void StereoRingDestroy(StereoRing *r);

// Producer. Writes up to n frames; returns the number written (the rest is dropped and counted).
uint32_t StereoRingWrite(StereoRing *r, const float *l, const float *rr, uint32_t n);
// Consumer. Reads up to n frames; returns the number read.
uint32_t StereoRingRead(StereoRing *r, float *l, float *rr, uint32_t n);
// Consumer: discards frames so that at most `keep` remain (pre-record window).
void StereoRingTrim(StereoRing *r, uint32_t keep);
// Total frames ever written, and a consumer-side trim to an absolute frame index.
// Rings filled in the same mix cycles share indices, which keeps tracks aligned.
uint64_t StereoRingWriteCount(StereoRing *r);
void StereoRingTrimTo(StereoRing *r, uint64_t index);

uint32_t StereoRingAvailable(StereoRing *r);   // frames readable
uint32_t StereoRingSpace(StereoRing *r);       // frames writable
uint64_t StereoRingDropped(StereoRing *r);      // frames the producer could not write

// Player control, honoured by the consumer (the audio thread) on its next read.
void StereoRingSetPaused(StereoRing *r, bool paused);   // paused: reads return silence, nothing consumed
bool StereoRingPaused(StereoRing *r);
void StereoRingRequestFlush(StereoRing *r);             // consumer discards everything buffered
bool StereoRingFlushPending(StereoRing *r);
// Consumer helper for audio threads: fills exactly n frames (silence when
// paused or short) and returns the number of real frames delivered.
uint32_t StereoRingPull(StereoRing *r, float *l, float *rr, uint32_t n);

#endif
