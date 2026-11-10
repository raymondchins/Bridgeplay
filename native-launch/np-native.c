/*
 * np-native: Steam launch-option wrapper for native macOS games.
 *
 *   np-native [VAR=VALUE ...] [--] %command% [game args]
 *
 * Steam on Apple Silicon is an x86_64 process, so a native game it spawns
 * inherits Rosetta unless something re-execs it with arm64 preferred. The
 * system `arch` tool does that but is SIP protected, so dyld strips every
 * DYLD_* variable Steam set (its overlay injection included) before the game
 * starts. This launcher is a plain, non-system binary: it sees Steam's
 * DYLD_INSERT_LIBRARIES, merges our shims in front of it and replaces itself
 * with the game (POSIX_SPAWN_SETEXEC keeps the pid Steam is tracking).
 *
 * Environment sources, highest precedence first:
 *   1. VAR=VALUE launch-option arguments
 *   2. ~/Library/Application Support/bridgeplay/gamefixes/native/<appid>.conf
 *   3. ~/Library/Application Support/bridgeplay/gamefixes/native-default.conf
 *   4. the environment Steam passed in
 * Until the app moves them over, ~/Library/Application Support/notproton and
 * ~/.notproton are used when the bridgeplay ones do not exist.
 *
 * Settings are spelled BRIDGEPLAY_<X>; the shims read NOTPROTON_<X>, the upstream
 * name, so each BRIDGEPLAY_<X> is also set as NOTPROTON_<X>. A NOTPROTON_<X> given
 * in the same source wins, so options written before Bridgeplay 3.0 still apply.
 *
 * DYLD_INSERT_LIBRARIES is composed, never replaced:
 *   gamepad shim (~/.bridgeplay/libnp_gamepad.dylib, unless NP_PAD_MODE=off)
 *   overlay shim (only when BRIDGEPLAY_FRAMEGEN, BRIDGEPLAY_PERF_OVERLAY,
 *   BRIDGEPLAY_FPS_LIMIT or BRIDGEPLAY_SCALING_FILTER is set and not 0/off, the
 *   limit only while BRIDGEPLAY_FPS_LIMIT_OFF is not 1)
 *   DYLD_INSERT_LIBRARIES given through the sources above
 *   DYLD_INSERT_LIBRARIES and STEAM_DYLD_INSERT_LIBRARIES received from Steam
 * de-duplicated, ours first. STEAM_DYLD_INSERT_LIBRARIES is set to the same
 * list because Valve's launch scripts (e.g. dota.sh) run under SIP-protected
 * /bin/bash and restore DYLD_INSERT_LIBRARIES from it.
 *
 * Fail open: a malformed conf line, an unreadable conf, a missing shim or any
 * other problem outside the command line is warned about on stderr and the
 * game still starts. Only an unusable command line (no program, an invalid
 * NAME=VALUE token) or a failed exec exits 127. A library that does not exist
 * is never put into DYLD_INSERT_LIBRARIES, since dyld would abort the game.
 */
#include <CoreFoundation/CoreFoundation.h>
#include <ctype.h>
#include <errno.h>
#include <limits.h>
#include <mach/machine.h>
#include <pwd.h>
#include <spawn.h>
#include <stdarg.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <sys/stat.h>
#include <unistd.h>

extern char **environ;

#define FAIL_EXIT 127
#define PAD_SHIM_REL "/.bridgeplay/libnp_gamepad.dylib"
#define LEGACY_PAD_SHIM_REL "/.notproton/libnp_gamepad.dylib"
#define SUPPORT_REL "/Library/Application Support/bridgeplay"
#define LEGACY_SUPPORT_REL "/Library/Application Support/notproton"
#define OVERLAY_SHIM_REL "/overlay-shim.dylib"
#define CONF_DIR_REL "/gamefixes"
#define PUBLIC_PREFIX "BRIDGEPLAY_"
#define LEGACY_PREFIX "NOTPROTON_"
#define MAX_LIBS 64

static void die(const char *fmt, ...) __attribute__((noreturn, format(printf, 1, 2)));
static void die(const char *fmt, ...)
{
	va_list ap;
	fputs("np-native: ", stderr);
	va_start(ap, fmt);
	vfprintf(stderr, fmt, ap);
	va_end(ap);
	fputc('\n', stderr);
	exit(FAIL_EXIT);
}

static void warn(const char *fmt, ...) __attribute__((format(printf, 1, 2)));
static void warn(const char *fmt, ...)
{
	va_list ap;
	fputs("np-native: warning: ", stderr);
	va_start(ap, fmt);
	vfprintf(stderr, fmt, ap);
	va_end(ap);
	fputc('\n', stderr);
}

static char *xstrdup(const char *s)
{
	char *d = strdup(s);
	if (!d)
		die("out of memory");
	return d;
}

static char *join3(const char *a, const char *b, const char *c)
{
	size_t n = strlen(a) + strlen(b) + strlen(c) + 1;
	char *d = malloc(n);
	if (!d)
		die("out of memory");
	snprintf(d, n, "%s%s%s", a, b, c);
	return d;
}

/* NAME as [A-Z_][A-Z0-9_]* */
static int valid_name(const char *s, size_t len)
{
	if (len == 0 || !(isupper((unsigned char)s[0]) || s[0] == '_'))
		return 0;
	for (size_t i = 1; i < len; i++)
		if (!(isupper((unsigned char)s[i]) || isdigit((unsigned char)s[i]) || s[i] == '_'))
			return 0;
	return 1;
}

static const char *home_dir(void)
{
	const char *h = getenv("HOME");
	if (h && h[0] == '/')
		return h;
	struct passwd *pw = getpwuid(getuid());
	if (pw && pw->pw_dir && pw->pw_dir[0] == '/')
		return pw->pw_dir;
	warn("cannot determine the home directory; skipping conf files and shims");
	return NULL;
}

/* Expands a leading "~/" and every "$HOME" / "${HOME}" in a conf value. */
static char *expand_home(const char *v, const char *home)
{
	size_t cap = strlen(v) * (strlen(home) + 1) + 2, o = 0;
	char *d = malloc(cap);
	if (!d)
		die("out of memory");
	if (v[0] == '~' && (v[1] == '/' || v[1] == '\0')) {
		o += (size_t)snprintf(d, cap, "%s", home);
		v++;
	}
	while (*v) {
		size_t skip = 0;
		if (strncmp(v, "${HOME}", 7) == 0)
			skip = 7;
		else if (strncmp(v, "$HOME", 5) == 0 &&
			 !(isalnum((unsigned char)v[5]) || v[5] == '_'))
			skip = 5;
		if (skip) {
			o += (size_t)snprintf(d + o, cap - o, "%s", home);
			v += skip;
		} else {
			d[o++] = *v++;
		}
	}
	d[o] = '\0';
	return d;
}

/* One override layer: parallel name/value arrays. */
struct layer {
	const char *src;
	char *names[256];
	char *values[256];
	int n;
};

static void layer_put(struct layer *l, const char *name, size_t nlen, const char *value)
{
	for (int i = 0; i < l->n; i++)
		if (strlen(l->names[i]) == nlen && strncmp(l->names[i], name, nlen) == 0) {
			free(l->values[i]);
			l->values[i] = xstrdup(value);
			return;
		}
	if (l->n >= 256) {
		if (strcmp(l->src, "launch options") == 0)
			die("%s: too many variables", l->src);
		warn("%s: too many variables, ignoring the rest", l->src);
		return;
	}
	l->names[l->n] = strndup(name, nlen);
	l->values[l->n] = xstrdup(value);
	if (!l->names[l->n] || !l->values[l->n])
		die("out of memory");
	l->n++;
}

static const char *layer_get(const struct layer *l, const char *name)
{
	for (int i = 0; i < l->n; i++)
		if (strcmp(l->names[i], name) == 0)
			return l->values[i];
	return NULL;
}

static char *trim(char *s)
{
	while (isspace((unsigned char)*s))
		s++;
	char *e = s + strlen(s);
	while (e > s && isspace((unsigned char)e[-1]))
		*--e = '\0';
	return s;
}

/* Missing file is fine; unreadable files and malformed lines are warned about
 * and skipped. */
static void load_conf(struct layer *l, const char *path, const char *home)
{
	l->src = path;
	FILE *f = fopen(path, "r");
	if (!f) {
		if (errno != ENOENT && errno != ENOTDIR)
			warn("cannot read %s: %s; skipped", path, strerror(errno));
		return;
	}
	char *line = NULL;
	size_t cap = 0;
	int lineno = 0;
	while (getline(&line, &cap, f) >= 0) {
		lineno++;
		char *s = trim(line);
		if (*s == '\0' || *s == '#')
			continue;
		if (strncmp(s, "export ", 7) == 0)
			s = trim(s + 7);
		char *eq = strchr(s, '=');
		if (!eq) {
			warn("%s:%d: expected KEY=VALUE, got \"%s\"; line skipped", path, lineno, s);
			continue;
		}
		*eq = '\0';
		char *name = trim(s), *val = trim(eq + 1);
		if (!valid_name(name, strlen(name))) {
			warn("%s:%d: invalid variable name \"%s\"; line skipped", path, lineno, name);
			continue;
		}
		size_t vl = strlen(val);
		if (vl >= 2 && (val[0] == '"' || val[0] == '\'') && val[vl - 1] == val[0]) {
			val[vl - 1] = '\0';
			val++;
		}
		char *ex = expand_home(val, home);
		layer_put(l, name, strlen(name), ex);
		free(ex);
	}
	if (ferror(f))
		warn("error reading %s: %s; using the lines read so far", path, strerror(errno));
	free(line);
	fclose(f);
}

static int is_off(const char *v)
{
	return v && (strcmp(v, "0") == 0 || strcasecmp(v, "off") == 0 ||
		     strcasecmp(v, "false") == 0 || strcasecmp(v, "no") == 0);
}

static int file_exists(const char *p)
{
	struct stat st;
	return stat(p, &st) == 0 && S_ISREG(st.st_mode);
}

static int dir_exists(const char *p)
{
	struct stat st;
	return stat(p, &st) == 0 && S_ISDIR(st.st_mode);
}

/* home + rel, or home + legacy when only that one exists. */
static char *current_or_legacy(const char *home, const char *rel, const char *legacy,
			       int (*exists)(const char *))
{
	char *cur = join3(home, rel, ""), *old = join3(home, legacy, "");
	if (!exists(cur) && exists(old)) {
		free(cur);
		return old;
	}
	free(old);
	return cur;
}

/* NOTPROTON_<X> for a BRIDGEPLAY_<X> name, NULL for any other. */
static char *legacy_name(const char *name)
{
	size_t n = strlen(PUBLIC_PREFIX);
	if (strncmp(name, PUBLIC_PREFIX, n) != 0 || name[n] == '\0')
		return NULL;
	return join3(LEGACY_PREFIX, name + n, "");
}

/* The environment Steam passed in: BRIDGEPLAY_<X> becomes NOTPROTON_<X> unless that is set. */
static void map_public_env(void)
{
	size_t count = 0;
	for (char **e = environ; *e; e++)
		count++;
	char **copy = calloc(count + 1, sizeof(*copy));
	if (!copy)
		die("out of memory");
	size_t n = 0;
	for (char **e = environ; *e; e++)
		if (strncmp(*e, PUBLIC_PREFIX, strlen(PUBLIC_PREFIX)) == 0 && strchr(*e, '='))
			copy[n++] = xstrdup(*e);
	for (size_t i = 0; i < n; i++) {
		char *eq = strchr(copy[i], '=');
		*eq = '\0';
		char *legacy = legacy_name(copy[i]);
		if (legacy && valid_name(legacy, strlen(legacy)) && !getenv(legacy) &&
		    setenv(legacy, eq + 1, 1) != 0)
			die("setenv %s: %s", legacy, strerror(errno));
		free(legacy);
		free(copy[i]);
	}
	free(copy);
}

/* Steam passes some games (Chained Beasts 3569420) as the .app bundle rather
 * than its binary; a directory cannot be exec'd, so run the bundle's main
 * executable instead. NULL when prog is not a bundle with one. */
static char *bundle_executable(const char *prog)
{
	size_t n = strlen(prog);
	while (n > 1 && prog[n - 1] == '/')
		n--;
	struct stat st;
	if (n < 5 || strncasecmp(prog + n - 4, ".app", 4) != 0 ||
	    stat(prog, &st) != 0 || !S_ISDIR(st.st_mode))
		return NULL;
	char *exe = NULL;
	CFURLRef url = CFURLCreateFromFileSystemRepresentation(NULL, (const UInt8 *)prog, (CFIndex)n, true);
	CFBundleRef bundle = url ? CFBundleCreate(NULL, url) : NULL;
	CFURLRef exe_url = bundle ? CFBundleCopyExecutableURL(bundle) : NULL;
	char buf[PATH_MAX];
	if (exe_url && CFURLGetFileSystemRepresentation(exe_url, true, (UInt8 *)buf, sizeof buf))
		exe = xstrdup(buf);
	if (exe_url)
		CFRelease(exe_url);
	if (bundle)
		CFRelease(bundle);
	if (url)
		CFRelease(url);
	return exe;
}

struct libs {
	char *v[MAX_LIBS];
	int n;
};

static void libs_add(struct libs *L, const char *p)
{
	if (!p || !*p)
		return;
	for (int i = 0; i < L->n; i++)
		if (strcmp(L->v[i], p) == 0)
			return;
	if (!file_exists(p)) {
		warn("%s does not exist; left out of DYLD_INSERT_LIBRARIES", p);
		return;
	}
	if (L->n >= MAX_LIBS) {
		warn("too many DYLD_INSERT_LIBRARIES entries; dropping %s", p);
		return;
	}
	L->v[L->n++] = xstrdup(p);
}

static void libs_add_list(struct libs *L, const char *list)
{
	if (!list)
		return;
	char *copy = xstrdup(list), *save = NULL;
	for (char *t = strtok_r(copy, ":", &save); t; t = strtok_r(NULL, ":", &save))
		libs_add(L, t);
	free(copy);
}

static char *libs_join(const struct libs *L)
{
	size_t n = 1;
	for (int i = 0; i < L->n; i++)
		n += strlen(L->v[i]) + 1;
	char *d = calloc(1, n);
	if (!d)
		die("out of memory");
	for (int i = 0; i < L->n; i++) {
		if (i)
			strcat(d, ":");
		strcat(d, L->v[i]);
	}
	return d;
}

static int valid_appid(const char *s)
{
	if (!s || !*s || strlen(s) > 20)
		return 0;
	for (; *s; s++)
		if (!isdigit((unsigned char)*s))
			return 0;
	return 1;
}

static void xsetenv(const char *name, const char *value)
{
	if (setenv(name, value, 1) != 0)
		die("setenv %s: %s", name, strerror(errno));
}

int main(int argc, char **argv)
{
	const char *home = home_dir();
	map_public_env();
	static struct layer args_l = {.src = "launch options"};
	static struct layer app_l, def_l;

	/* 1. leading VAR=VALUE assignments, then the program */
	int i = 1;
	for (; i < argc; i++) {
		const char *a = argv[i];
		if (strcmp(a, "--") == 0) {
			i++;
			break;
		}
		const char *eq = strchr(a, '=');
		if (!eq)
			break;
		size_t nlen = (size_t)(eq - a);
		if (memchr(a, '/', nlen))
			break; /* a path that happens to contain '=' */
		if (!valid_name(a, nlen))
			die("invalid variable name in \"%s\" (want [A-Z_][A-Z0-9_]*=VALUE)", a);
		layer_put(&args_l, a, nlen, eq + 1);
	}
	if (i >= argc || argv[i][0] == '\0')
		die("no program to run; usage: np-native [VAR=VALUE ...] %%command%% [args]");
	char *exe = bundle_executable(argv[i]);
	if (exe)
		argv[i] = exe;
	char *const *prog_argv = &argv[i];
	const char *prog = argv[i];

	/* Steam's own injection, captured before any override touches it */
	const char *steam_dyld = getenv("DYLD_INSERT_LIBRARIES");
	const char *steam_dyld2 = getenv("STEAM_DYLD_INSERT_LIBRARIES");
	char *steam_dyld_c = steam_dyld ? xstrdup(steam_dyld) : NULL;
	char *steam_dyld2_c = steam_dyld2 ? xstrdup(steam_dyld2) : NULL;

	/* 2. conf files */
	const char *appid = getenv("SteamAppId");
	if (!valid_appid(appid))
		appid = getenv("SteamGameId");
	if (home) {
		char *support = current_or_legacy(home, SUPPORT_REL, LEGACY_SUPPORT_REL, dir_exists);
		char *conf_dir = join3(support, CONF_DIR_REL, "");
		char *def_path = join3(conf_dir, "/native-default.conf", "");
		load_conf(&def_l, def_path, home);
		if (valid_appid(appid)) {
			char *app_path = join3(conf_dir, "/native/", appid);
			char *app_conf = join3(app_path, ".conf", "");
			load_conf(&app_l, app_conf, home);
		}
	}

	/* user-supplied DYLD_INSERT_LIBRARIES (highest layer that sets one) */
	const char *user_dyld = layer_get(&args_l, "DYLD_INSERT_LIBRARIES");
	if (!user_dyld)
		user_dyld = layer_get(&app_l, "DYLD_INSERT_LIBRARIES");
	if (!user_dyld)
		user_dyld = layer_get(&def_l, "DYLD_INSERT_LIBRARIES");
	char *user_dyld_c = user_dyld ? xstrdup(user_dyld) : NULL;

	/* apply lowest precedence first so higher layers win; within a layer a
	 * NOTPROTON_<X> wins over the BRIDGEPLAY_<X> it would be set from */
	struct layer *order[] = {&def_l, &app_l, &args_l};
	for (int k = 0; k < 3; k++)
		for (int j = 0; j < order[k]->n; j++) {
			xsetenv(order[k]->names[j], order[k]->values[j]);
			char *legacy = legacy_name(order[k]->names[j]);
			if (legacy && !layer_get(order[k], legacy))
				xsetenv(legacy, order[k]->values[j]);
			free(legacy);
		}

	/* 3. compose DYLD_INSERT_LIBRARIES */
	struct libs L = {.n = 0};
	const char *pad_mode = getenv("NP_PAD_MODE");
	if (home && !is_off(pad_mode)) {
		char *pad_shim = current_or_legacy(home, PAD_SHIM_REL, LEGACY_PAD_SHIM_REL, file_exists);
		/* no NP_PAD_MODE and no shim installed: nothing was asked for */
		if (file_exists(pad_shim) || (pad_mode && *pad_mode))
			libs_add(&L, pad_shim); /* warns and skips when missing */
	}
	/* frame generation, the performance overlay, the frame rate limit and the scaling
	   filter live in the overlay shim */
	const char *framegen = getenv("NOTPROTON_FRAMEGEN");
	const char *perf = getenv("NOTPROTON_PERF_OVERLAY");
	const char *limit = getenv("NOTPROTON_FPS_LIMIT");
	const char *limit_off = getenv("NOTPROTON_FPS_LIMIT_OFF");
	const char *filter = getenv("NOTPROTON_SCALING_FILTER");
	int limited = limit && *limit && !is_off(limit) && !(limit_off && strcmp(limit_off, "1") == 0);
	if (home && ((framegen && *framegen && !is_off(framegen)) || (perf && *perf && !is_off(perf)) ||
	             limited || (filter && *filter && !is_off(filter)))) {
		char *support = current_or_legacy(home, SUPPORT_REL, LEGACY_SUPPORT_REL, dir_exists);
		libs_add(&L, join3(support, OVERLAY_SHIM_REL, ""));
	}
	libs_add_list(&L, user_dyld_c);
	libs_add_list(&L, steam_dyld_c);
	libs_add_list(&L, steam_dyld2_c);
	char *dyld = libs_join(&L);
	if (L.n) {
		xsetenv("DYLD_INSERT_LIBRARIES", dyld);
		xsetenv("STEAM_DYLD_INSERT_LIBRARIES", dyld);
	} else {
		unsetenv("DYLD_INSERT_LIBRARIES");
		unsetenv("STEAM_DYLD_INSERT_LIBRARIES");
	}

	const char *log = getenv("NP_NATIVE_LOG");
	int logging = log && *log && !is_off(log);
	if (logging) {
		fprintf(stderr, "np-native: appid=%s\n", valid_appid(appid) ? appid : "(none)");
		fprintf(stderr, "np-native: DYLD_INSERT_LIBRARIES=%s\n", L.n ? dyld : "(unset)");
#if defined(__arm64__)
		const char *self_arch = "arm64";
#else
		const char *self_arch = "x86_64";
#endif
		fprintf(stderr, "np-native: launcher arch %s; arch preference: arm64, x86_64\n", self_arch);
		fprintf(stderr, "np-native: program: %s\n", prog);
	}

	/* 4. replace ourselves with the program, arm64 preferred */
	posix_spawnattr_t attr;
	int rc = posix_spawnattr_init(&attr);
	if (rc)
		die("posix_spawnattr_init: %s", strerror(rc));
	cpu_type_t pref[2] = {CPU_TYPE_ARM64, CPU_TYPE_X86_64};
	size_t ocount = 0;
	rc = posix_spawnattr_setbinpref_np(&attr, 2, pref, &ocount);
	if (rc || ocount != 2)
		die("posix_spawnattr_setbinpref_np failed: %s", strerror(rc ? rc : EINVAL));
	rc = posix_spawnattr_setflags(&attr, POSIX_SPAWN_SETEXEC);
	if (rc)
		die("posix_spawnattr_setflags: %s", strerror(rc));

	fflush(NULL);
	pid_t pid;
	if (strchr(prog, '/'))
		rc = posix_spawn(&pid, prog, NULL, &attr, prog_argv, environ);
	else
		rc = posix_spawnp(&pid, prog, NULL, &attr, prog_argv, environ);
	/* only reached on failure */
	die("cannot exec %s: %s", prog, strerror(rc));
}
