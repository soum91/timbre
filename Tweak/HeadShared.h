// Head orientation shared from SpringBoard (or the Timbre app) to the audio tweak in mediaserverd.
#pragma once
#include <stdint.h>

#define TB_HEAD_PATH "/var/jb/var/mobile/Library/Preferences/com.soum91.timbreaudio.head"
#define TB_HEAD_MAGIC 0x54424844u  /* 'TBHD' */
#define TB_HEAD_FILE_SIZE 4096u

typedef struct {
    uint32_t magic;
    uint32_t source;     // 2 = SpringBoard, 3 = Timbre app
    uint64_t seq;        // incremented on every update
    double yaw;          // degrees, positive = head turned right
    double time;         // CFAbsoluteTime of the last update
    int32_t auth;        // CMAuthorizationStatus seen by the writer
    int32_t available;   // headphone motion available (head-tracking AirPods connected)
    uint32_t reserved[8];
} TBHeadShared;
