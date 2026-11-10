// The payload is a macro, so the unit under test is included rather than linked.
// Both forms come from one body, which is what makes the checks that run against
// this output speak for both page shapes at once.
#include "../../feats/webpatch.c"
#include "../../util/file.c"

#include <stdio.h>
#include <string.h>

int np_log_level = 0;
FILE *np_log_file = NULL;

// No displays here: the panel gets the 60 a Mac without a reading gets.
int np_display_max_hz(void) {
    return 60;
}

char *np_nativeplatform_javascript(void) {
    return NULL;
}

static void put_panel(const char *body) {
    for (const char *p = body; *p; p++) {
        const char *text = marker_text(*p);
        if (text) fputs(text, stdout);
        else putchar(*p);
    }
}

int main(int argc, char **argv) {
    if (argc >= 2 && (strcmp(argv[1], "component") == 0 || strcmp(argv[1], "statement") == 0)) {
        np_webpatch_set_fallback_tool(argc >= 3 ? argv[2] : NULL);
        np_webpatch_set_fex_tools((const char *const *)argv + 3,
                                  argc > 3 ? (size_t)(argc - 3) : 0);
        put_panel(strcmp(argv[1], "component") == 0 ? NP_CX_OPTIONS_COMPONENT
                                                    : NP_CX_OPTIONS_STATEMENT);
        return 0;
    }
    if (argc == 2 && strcmp(argv[1], "prefix-row") == 0) {
        fputs(NP_CX_PREFIX_ROW, stdout);
        return 0;
    }
    if (argc == 2 && strcmp(argv[1], "migration") == 0) {
        fputs(NP_LAUNCH_MIGRATION, stdout);
        return 0;
    }
    // The chunk as Steam is served it, defaults included, read from $HOME like the hook.
    if (argc == 4 && strcmp(argv[1], "transform") == 0) {
        FILE *f = fopen(argv[2], "rb");
        if (!f) return 1;
        fseek(f, 0, SEEK_END);
        long n = ftell(f);
        rewind(f);
        uint8_t *src = malloc(n > 0 ? (size_t)n : 1);
        if (!src || fread(src, 1, (size_t)n, f) != (size_t)n) { fclose(f); return 1; }
        fclose(f);
        np_webpatch_set_fallback_tool(argv[3]);
        size_t out_len = 0;
        char *out = np_webpatch_transform(src, (size_t)n, &out_len, NULL);
        free(src);
        if (!out) return 1;
        fwrite(out, 1, out_len, stdout);
        free(out);
        return 0;
    }
    if (argc == 2 && strcmp(argv[1], "compat-hint") == 0) {
        fputs(NP_COMPAT_HINT, stdout);
        return 0;
    }
    if (argc == 2 && strcmp(argv[1], "image-files-label") == 0) {
        fputs(NP_IMAGE_FILES_LABEL, stdout);
        return 0;
    }
    if (argc == 2 && strcmp(argv[1], "library-windows-hint") == 0) {
        fputs(NP_LIBRARY_WINDOWS_HINT, stdout);
        return 0;
    }
    if (argc == 2 && strcmp(argv[1], "library-windows-summary") == 0) {
        fputs(NP_LIBRARY_WINDOWS_SUMMARY, stdout);
        return 0;
    }
    fputs("usage: emit component|statement [fallback [fex-tool...]]|migration|"
          "transform <chunk> <fallback tool>|compat-hint|image-files-label|"
          "library-windows-hint|library-windows-summary|prefix-row\n", stderr);
    return 2;
}
