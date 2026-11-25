// The prefix state the Compatibility page reads, against a scratch Steam layout.
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <sys/stat.h>
#include <sys/time.h>
#include <sys/wait.h>
#include <unistd.h>

#include "../feats/prefixstate.c"

static int fails;
static char root[PATH_MAX];

static void check(const char *what, const char *want, const char *got) {
    if (strcmp(want, got) == 0) { printf("  ok    %s\n", what); return; }
    printf("  FAIL  %s\n         want [%s]\n         got  [%s]\n", what, want, got);
    fails++;
}

static void mkdirs(const char *rel) {
    char path[PATH_MAX];
    snprintf(path, sizeof path, "%s/%s", root, rel);
    for (char *p = path + strlen(root) + 1; *p; p++) {
        if (*p != '/') continue;
        *p = '\0'; mkdir(path, 0755); *p = '/';
    }
    mkdir(path, 0755);
}

static void put(const char *rel, const void *bytes, size_t len) {
    char path[PATH_MAX], dir[PATH_MAX];
    snprintf(path, sizeof path, "%s/%s", root, rel);
    snprintf(dir, sizeof dir, "%s", rel);
    char *slash = strrchr(dir, '/');
    if (slash) { *slash = '\0'; mkdirs(dir); }
    FILE *f = fopen(path, "wb");
    fwrite(bytes, 1, len, f);
    fclose(f);
}

static void put_text(const char *rel, const char *text) { put(rel, text, strlen(text)); }

static void put_ntdll(const char *compatdata, uint16_t machine) {
    uint8_t dll[0x46] = { 'M', 'Z' };
    dll[0x3c] = 0x40;
    memcpy(dll + 0x40, "PE\0\0", 4);
    dll[0x44] = (uint8_t)machine;
    dll[0x45] = (uint8_t)(machine >> 8);
    char rel[PATH_MAX];
    snprintf(rel, sizeof rel, "%s/pfx/drive_c/windows/system32/ntdll.dll", compatdata);
    put(rel, dll, sizeof dll);
}

static np_prefix_state_t st;

static const char *state(uint32_t appid, const char *tool) {
    static char out[2048];
    char steam[PATH_MAX], support[PATH_MAX], server[PATH_MAX];
    snprintf(steam, sizeof steam, "%s/Steam", root);
    snprintf(support, sizeof support, "%s/support", root);
    snprintf(server, sizeof server, "%s/server", root);
    np_prefix_roots_t roots = { steam, support, server };
    np_prefix_state(appid, tool, &roots, &st);
    if (np_prefix_state_json(appid, &st, out, sizeof out) < 0)
        snprintf(out, sizeof out, "(did not fit)");
    return out;
}

static const char *flag(int v) { return v ? "yes" : "no"; }

// Holds the wineserver lock of a prefix from another process, as a running server does.
static pid_t hold_server_lock(const char *compatdata) {
    char pfx[PATH_MAX], dir[PATH_MAX], lock[PATH_MAX];
    struct stat s;
    snprintf(pfx, sizeof pfx, "%s/%s/pfx", root, compatdata);
    stat(pfx, &s);
    snprintf(dir, sizeof dir, "server/server-%llx-%llx", (unsigned long long)s.st_dev,
             (unsigned long long)s.st_ino);
    mkdirs(dir);
    snprintf(lock, sizeof lock, "%s/%s/lock", root, dir);
    int ready[2];
    if (pipe(ready) != 0) return -1;
    pid_t pid = fork();
    if (pid == 0) {
        int fd = open(lock, O_CREAT | O_RDWR, 0600);
        struct flock fl = { .l_type = F_WRLCK, .l_whence = SEEK_SET, .l_start = 0, .l_len = 1 };
        fcntl(fd, F_SETLK, &fl);
        if (write(ready[1], "x", 1) != 1) _exit(1);
        pause();
        _exit(0);
    }
    char c;
    close(ready[1]);
    if (read(ready[0], &c, 1) != 1) pid = -1;
    close(ready[0]);
    return pid;
}

int main(void) {
    snprintf(root, sizeof root, "%s/prefixstate.XXXXXX", getenv("TMPDIR") ? getenv("TMPDIR") : "/tmp");
    if (!mkdtemp(root)) { perror("mkdtemp"); return 1; }

    char vdf[PATH_MAX * 2];
    snprintf(vdf, sizeof vdf,
             "\"libraryfolders\"\n{\n\t\"0\"\n\t{\n\t\t\"path\"\t\t\"%s/Steam\"\n\t}\n"
             "\t\"1\"\n\t{\n\t\t\"path\"\t\t\"%s/External \\\"Games\\\" SSD\"\n\t}\n}\n", root, root);
    put_text("Steam/steamapps/libraryfolders.vdf", vdf);
    put_text("support/tools",
             "notproton-26.3\t26.3.0.39832\trosetta\tCrossOver 26.3\n"
             "notproton-fex-41073\t27.0.0.41073-fex\tfex\tCrossOver 2026 10 15-ARM64 - FEX\n"
             "short\tline\n");

    // A game on the second library, last run by 26.3 under Rosetta.
    const char *ikaruga = "External \"Games\" SSD/steamapps/compatdata/480";
    put_text("External \"Games\" SSD/steamapps/appmanifest_480.acf", "\"AppState\"\n{\n}\n");
    put_ntdll(ikaruga, 0x8664);
    put_text("External \"Games\" SSD/steamapps/compatdata/480/notproton-build",
             "26.3.0.39832\nCrossOver \"26.3\"\n");

    printf("== prefix state ==\n");
    check("the page gets every field, escaped",
          "{\"appid\":480,\"tool\":\"notproton-fex-41073\",\"toolDisplay\":\"CrossOver 2026 10 15-ARM64 - FEX\","
          "\"toolArch\":\"fex\",\"prefix\":true,\"prefixArch\":\"rosetta\",\"lastBuild\":\"26.3.0.39832\","
          "\"lastDisplay\":\"CrossOver \\\"26.3\\\"\",\"needsRebuild\":true,\"running\":false,"
          "\"rebuild\":\"\",\"app\":false}",
          state(480, "notproton-fex-41073"));
    check("the tool's build is what the app is asked to rebuild with", "27.0.0.41073-fex", st.tool_build);
    check("the prefix is found on the library holding the game",
          "External \"Games\" SSD/steamapps/compatdata/480", st.compatdata + strlen(root) + 1);
    state(480, "notproton-26.3");
    check("the same arch needs none", "no", flag(st.needs_rebuild));
    state(480, "proton_9");
    check("a tool that is not ours never asks for a rebuild", "no", flag(st.needs_rebuild));

    put_text("Steam/steamapps/appmanifest_620.acf", "\"AppState\"\n{\n}\n");
    state(620, "notproton-fex-41073");
    check("a game with no prefix yet needs none", "no no", st.has_prefix || st.needs_rebuild ? "yes" : "no no");

    mkdirs("Steam/steamapps/compatdata/700/pfx");
    state(700, "notproton-26.3");
    check("a prefix Steam only laid out has no arch and needs none", "no", flag(st.needs_rebuild));

    put_ntdll("External \"Games\" SSD/steamapps/compatdata/3000000000", 0xaa64);
    state(3000000000u, "notproton-26.3");
    check("a shortcut's prefix is found without a manifest", "fex yes", st.needs_rebuild && strcmp(st.prefix_arch, "fex") == 0 ? "fex yes" : st.prefix_arch);

    put_text("Steam/steamapps/appmanifest_800.acf", "\"AppState\"\n{\n}\n");
    put_ntdll("Steam/steamapps/compatdata/800", 0x014c);
    state(800, "notproton-26.3");
    check("a 32-bit prefix needs a rebuild under Rosetta", "32-bit yes",
          st.needs_rebuild && strcmp(st.prefix_arch, "32-bit") == 0 ? "32-bit yes" : st.prefix_arch);

    printf("== app, server and rebuild ==\n");
    char app[PATH_MAX + 16];
    snprintf(app, sizeof app, "%s/support/NotProtonApp", root);
    put_text("support/NotProtonApp", "#!/bin/sh\n");
    chmod(app, 0755);
    char record[PATH_MAX + 2];
    snprintf(record, sizeof record, "%s\n", app);
    put_text("support/app-executable", record);
    state(480, "notproton-fex-41073");
    check("the recorded app is found", app, st.app);
    chmod(app, 0644);
    state(480, "notproton-fex-41073");
    check("an app that cannot run is not offered", "", st.app);

    check("no server is not running", "no", flag(st.running));
    pid_t holder = hold_server_lock(ikaruga);
    state(480, "notproton-fex-41073");
    check("a server holding the prefix is running", "yes", flag(st.running));
    if (holder > 0) { kill(holder, SIGKILL); waitpid(holder, NULL, 0); }
    state(480, "notproton-fex-41073");
    check("a server that exited is not running", "no", flag(st.running));

    char status[PATH_MAX + 64];
    snprintf(status, sizeof status, "%s/notproton-rebuild", ikaruga);
    char text[64];
    char rebuild_lock[PATH_MAX];
    snprintf(rebuild_lock, sizeof rebuild_lock, "%s/%s/.notproton-rebuild.lock", root, ikaruga);
    int rebuild_fd = open(rebuild_lock, O_CREAT | O_RDWR, 0600);
    if (rebuild_fd < 0 || flock(rebuild_fd, LOCK_EX | LOCK_NB) != 0) abort();
    snprintf(text, sizeof text, "copy\n%d\n", (int)getpid());
    put_text(status, text);
    state(480, "notproton-fex-41073");
    check("a live rebuild reports its phase", "copy", st.rebuild);
    check("a live rebuild is under way", "yes", flag(np_prefix_rebuilding(&st)));
    close(rebuild_fd);
    state(480, "notproton-fex-41073");
    check("a live unrelated pid does not keep a rebuild busy", "failed", st.rebuild);

    pid_t gone = fork();
    if (gone == 0) _exit(0);
    waitpid(gone, NULL, 0);
    snprintf(text, sizeof text, "setup\n%d\n", (int)gone);
    put_text(status, text);
    state(480, "notproton-fex-41073");
    check("a rebuild whose app died has failed", "failed", st.rebuild);
    check("a failed rebuild is not under way", "no", flag(np_prefix_rebuilding(&st)));

    put_text(status, "setup\n0\n");
    state(480, "notproton-fex-41073");
    check("a rebuild just started is under way before the app reports", "setup", st.rebuild);

    put_text(status, "done-backup\n123\n");
    state(480, "notproton-fex-41073");
    check("a finished rebuild says so", "done-backup", st.rebuild);
    char status_path[PATH_MAX + 64];
    snprintf(status_path, sizeof status_path, "%s/%s", root, status);
    struct timeval old[2] = { { time(NULL) - 3600, 0 }, { time(NULL) - 3600, 0 } };
    utimes(status_path, old);
    state(480, "notproton-fex-41073");
    check("a result nobody saw for an hour is not shown", "", st.rebuild);
    put_text(status, "anything\n");
    state(480, "notproton-fex-41073");
    check("an unknown phase is ignored", "", st.rebuild);

    printf("== installed apps ==\n");
    put_text("Steam/steamapps/appmanifest_1422450.acf", "\"AppState\"\n{\n}\n");
    put_text("Steam/steamapps/appmanifest_ 7.acf", "");
    put_text("Steam/steamapps/appmanifest_8.acf.bak", "");
    put_text("Steam/steamapps/appmanifest_0.acf", "");
    put_text("Steam/steamapps/appmanifest_99999999999.acf", "");
    char steam_root[PATH_MAX + 8];
    snprintf(steam_root, sizeof steam_root, "%s/Steam", root);
    uint32_t ids[8];
    size_t found = np_prefix_installed_apps(steam_root, ids, 8);
    // Directory order is the file system's, so sort before comparing.
    for (size_t i = 1; i < found; i++)
        for (size_t j = i; j && ids[j - 1] > ids[j]; j--) {
            uint32_t t = ids[j]; ids[j] = ids[j - 1]; ids[j - 1] = t;
        }
    char list[64] = "";
    for (size_t i = 0; i < found; i++)
        snprintf(list + strlen(list), sizeof list - strlen(list), "%s%u", i ? "," : "", ids[i]);
    check("every library's manifests are read, and nothing that only looks like one",
          "480,620,800,1422450", list);
    check("the list stops at its limit", "1",
          np_prefix_installed_apps(steam_root, ids, 1) == 1 ? "1" : "more");

    char small[16];
    check("an answer that does not fit is refused", "-1",
          np_prefix_state_json(480, &st, small, sizeof small) < 0 ? "-1" : small);

    char cmd[PATH_MAX + 16];
    snprintf(cmd, sizeof cmd, "rm -rf '%s'", root);
    if (system(cmd) != 0) fprintf(stderr, "could not remove %s\n", root);

    if (fails) { printf("==> prefixstate: %d failed\n", fails); return 1; }
    printf("==> prefixstate: libraries, arches, records, tools, servers and rebuilds read as expected\n");
    return 0;
}
