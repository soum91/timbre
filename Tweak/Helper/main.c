// timbrectl: small setuid-root helper for the Timbre controller.
// Only fixed commands are accepted; nothing user-supplied is executed.
#include <errno.h>
#include <signal.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <sys/stat.h>
#include <sys/sysctl.h>
#include <sys/types.h>
#include <unistd.h>
#include <stdint.h>
#include <sys/mount.h>

// libproc is not in the iOS SDK; these mirror XNU's sys/proc_info.h.
struct tb_proc_regioninfo {
    uint32_t pri_protection, pri_max_protection, pri_inheritance, pri_flags;
    uint64_t pri_offset;
    uint32_t pri_behavior, pri_user_wired_count, pri_user_tag, pri_pages_resident, pri_pages_shared_now_private,
             pri_pages_swapped_out, pri_pages_dirtied, pri_ref_count, pri_shadow_depth, pri_share_mode,
             pri_private_pages_resident, pri_shared_pages_resident, pri_obj_id, pri_depth;
    uint64_t pri_address, pri_size;
};
struct tb_vinfo_stat {
    uint32_t vst_dev; uint16_t vst_mode, vst_nlink; uint64_t vst_ino; uid_t vst_uid; gid_t vst_gid;
    int64_t vst_atime, vst_atimensec, vst_mtime, vst_mtimensec, vst_ctime, vst_ctimensec, vst_birthtime, vst_birthtimensec;
    off_t vst_size; int64_t vst_blocks; int32_t vst_blksize; uint32_t vst_flags, vst_gen, vst_rdev; int64_t vst_qspare[2];
};
struct tb_vnode_info { struct tb_vinfo_stat vi_stat; int vi_type, vi_pad; fsid_t vi_fsid; };
struct tb_region_path { struct tb_proc_regioninfo info; struct tb_vnode_info vi; char path[1024]; };
int proc_pidinfo(int pid, int flavor, uint64_t arg, void *buffer, int buffersize);
#define TB_PROC_PIDREGIONPATHINFO 8

static const char *const kPrefsDirs[] = {"/var/jb/var/mobile", "/var/jb/var/mobile/Library", "/var/jb/var/mobile/Library/Preferences"};
static const char *const kPrefsFile = "/var/jb/var/mobile/Library/Preferences/com.soum91.timbreaudio.plist";

static int pidsNamed(const char *name, pid_t *out, int max) {
    int mib[4] = {CTL_KERN, KERN_PROC, KERN_PROC_ALL, 0};
    size_t len = 0;
    if (sysctl(mib, 3, NULL, &len, NULL, 0) != 0 || len == 0) return 0;
    len += len / 4;
    struct kinfo_proc *procs = malloc(len);
    if (!procs) return 0;
    int n = 0;
    if (sysctl(mib, 3, procs, &len, NULL, 0) == 0)
        for (size_t i = 0; i < len / sizeof(struct kinfo_proc) && n < max; i++)
            if (strncmp(procs[i].kp_proc.p_comm, name, sizeof(procs[i].kp_proc.p_comm)) == 0) out[n++] = procs[i].kp_proc.p_pid;
    free(procs);
    return n;
}

// Lists file-backed images from the jailbreak root mapped into a process. Answers "is the tweak injected?"
// without relying on anything the sandboxed daemon itself can do.
static void inspectProcess(const char *name) {
    pid_t pids[8];
    const int n = pidsNamed(name, pids, 8);
    if (!n) { printf("%s: not running\n", name); return; }
    for (int p = 0; p < n; p++) {
        printf("%s pid %d\n", name, pids[p]);
        char seen[48][160]; int seenCount = 0, timbre = 0, regions = 0;
        uint64_t addr = 0;
        // Oversized buffer so a small mismatch with the kernel's struct size cannot make the call fail.
        static union { struct tb_region_path r; char raw[4096]; } buf;
        struct tb_region_path *rp = &buf.r;
        while (regions < 200000) {
            memset(&buf, 0, sizeof(buf));
            const int got = proc_pidinfo(pids[p], TB_PROC_PIDREGIONPATHINFO, addr, &buf, (int)sizeof(buf));
            if (got <= 0) { if (!regions) printf("  could not read memory map (%s)\n", strerror(errno)); break; }
            regions++;
            // Find the path by content rather than trusting the struct offset.
            const char *path = "";
            for (int i = 64; i < got - 1 && i < (int)sizeof(buf.raw) - 1; i++)
                if (buf.raw[i] == '/' && (buf.raw[i + 1] == 'p' || buf.raw[i + 1] == 'v' || buf.raw[i + 1] == 'S' || buf.raw[i + 1] == 'u') && buf.raw[i - 1] == 0) {
                    buf.raw[sizeof(buf.raw) - 1] = 0;
                    path = &buf.raw[i];
                    break;
                }
            if (strstr(path, "TimbreAudio")) timbre = 1;
            if (path[0] && (strstr(path, "/jb") || strstr(path, "jbroot") || strstr(path, "procursus") || strstr(path, "MobileSubstrate"))) {
                const char *base = strrchr(path, '/') ? strrchr(path, '/') + 1 : path;
                int dup = 0;
                for (int i = 0; i < seenCount; i++) if (!strcmp(seen[i], base)) dup = 1;
                if (!dup && seenCount < 48) { strncpy(seen[seenCount], base, 159); seen[seenCount][159] = 0; seenCount++; }
            }
            const uint64_t next = rp->info.pri_address + rp->info.pri_size;
            if (next <= addr) break;
            addr = next;
        }
        printf("  TimbreAudio.dylib: %s\n", timbre ? "LOADED" : "NOT LOADED");
        printf("  jailbreak images (%d):", seenCount);
        for (int i = 0; i < seenCount; i++) printf("%s %s", i ? "," : "", seen[i]);
        printf("\n");
    }
}

static void printStatusFiles(void) {
    const char *dirs[] = {"/var/jb/var/mobile/Library/Preferences", "/var/tmp", "/tmp"};
    const char *procs[] = {"mediaserverd", "audiomxd"};
    for (size_t d = 0; d < 3; d++) for (size_t p = 0; p < 2; p++) {
        char path[256];
        snprintf(path, sizeof(path), "%s/com.soum91.timbreaudio.status.%s.txt", dirs[d], procs[p]);
        FILE *f = fopen(path, "r");
        if (!f) continue;
        char line[512];
        printf("status file %s:\n", path);
        while (fgets(line, sizeof(line), f)) printf("  %s", line);
        fclose(f);
    }
}

static int killNamed(const char *name) {
    int mib[4] = {CTL_KERN, KERN_PROC, KERN_PROC_ALL, 0};
    size_t len = 0;
    if (sysctl(mib, 3, NULL, &len, NULL, 0) != 0 || len == 0) return -1;
    len += len / 4;
    struct kinfo_proc *procs = malloc(len);
    if (!procs) return -1;
    if (sysctl(mib, 3, procs, &len, NULL, 0) != 0) { free(procs); return -1; }
    int killed = 0;
    for (size_t i = 0; i < len / sizeof(struct kinfo_proc); i++) {
        if (strncmp(procs[i].kp_proc.p_comm, name, sizeof(procs[i].kp_proc.p_comm)) == 0 &&
            kill(procs[i].kp_proc.p_pid, SIGKILL) == 0) killed++;
    }
    free(procs);
    return killed;
}

static int fixPrefs(void) {
    int failures = 0;
    for (size_t i = 0; i < sizeof(kPrefsDirs) / sizeof(kPrefsDirs[0]); i++) {
        if (mkdir(kPrefsDirs[i], 0755) != 0 && errno != EEXIST) failures++;
        if (chown(kPrefsDirs[i], 501, 501) != 0) failures++;
    }
    struct stat st;
    if (stat(kPrefsFile, &st) == 0 && (chown(kPrefsFile, 501, 501) != 0 || chmod(kPrefsFile, 0644) != 0)) failures++;
    return failures;
}

int main(int argc, char **argv) {
    if (setgid(0) != 0 || setuid(0) != 0) fprintf(stderr, "timbrectl: not running as root (%s)\n", strerror(errno));
    if (argc < 2) { fprintf(stderr, "usage: timbrectl restart-audio | fix-prefs | inspect\n"); return 64; }
    if (strcmp(argv[1], "restart-audio") == 0) {
        const int a = killNamed("mediaserverd"), b = killNamed("audiomxd");
        printf("restarted mediaserverd=%d audiomxd=%d\n", a, b);
        return a > 0 || b > 0 ? 0 : 1;
    }
    if (strcmp(argv[1], "inspect") == 0) {
        inspectProcess("mediaserverd");
        inspectProcess("audiomxd");
        printStatusFiles();
        return 0;
    }
    if (strcmp(argv[1], "fix-prefs") == 0) {
        const int f = fixPrefs();
        printf("fix-prefs failures=%d\n", f);
        return f ? 1 : 0;
    }
    fprintf(stderr, "timbrectl: unknown command\n");
    return 64;
}
