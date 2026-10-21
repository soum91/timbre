// Shared-memory ring between the audio tweak (writer, inside mediaserverd) and timbrecastd (reader).
// The daemon creates and sizes the file; the tweak only maps it read/write.
#pragma once
#include <stdint.h>

#define TB_CAST_RING_PATH "/var/jb/var/mobile/Library/Preferences/com.soum91.timbreaudio.cast.ring"
#define TB_CAST_MAGIC 0x54424352u  /* 'TBCR' */
#define TB_CAST_VERSION 1u
#define TB_CAST_CAPACITY (48000u * 4u)  /* frames; int16 stereo, about 4 s at 48 kHz */

typedef struct {
    uint32_t magic;
    uint32_t version;
    uint32_t capacity;         // frames
    uint32_t rate;             // written by the tweak: sample rate of the frames being written
    uint64_t writeFrames;      // total frames ever written (atomic, release by writer)
    uint64_t readerHeartbeat;  // unix seconds, refreshed by the daemon while casting
    uint32_t muteLocal;        // set by the daemon from the config
    uint32_t reserved[7];
} TBCastHeader;                // 64 bytes; int16 interleaved stereo samples follow

#define TB_CAST_FILE_SIZE (sizeof(TBCastHeader) + (uint64_t)TB_CAST_CAPACITY * 2u * sizeof(int16_t))

static inline int16_t *tbCastSamples(TBCastHeader *h) { return (int16_t *)(h + 1); }
