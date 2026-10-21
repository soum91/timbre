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

static const char *const kPrefsDirs[] = {"/var/jb/var/mobile", "/var/jb/var/mobile/Library", "/var/jb/var/mobile/Library/Preferences"};
static const char *const kPrefsFile = "/var/jb/var/mobile/Library/Preferences/com.soum91.timbreaudio.plist";

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
    if (argc < 2) { fprintf(stderr, "usage: timbrectl restart-audio | fix-prefs\n"); return 64; }
    if (strcmp(argv[1], "restart-audio") == 0) {
        const int a = killNamed("mediaserverd"), b = killNamed("audiomxd");
        printf("restarted mediaserverd=%d audiomxd=%d\n", a, b);
        return a > 0 || b > 0 ? 0 : 1;
    }
    if (strcmp(argv[1], "fix-prefs") == 0) {
        const int f = fixPrefs();
        printf("fix-prefs failures=%d\n", f);
        return f ? 1 : 0;
    }
    fprintf(stderr, "timbrectl: unknown command\n");
    return 64;
}
