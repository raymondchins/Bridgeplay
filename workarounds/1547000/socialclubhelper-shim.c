/*
 * Adapted from the SocialClubHelper shim in:
 * https://github.com/matthiasSchedel/rdr2-crossover-apple-silicon/blob/main/src/socialclubhelper-shim.c
 *
 * Local adjustment: append ANGLE with SwiftShader to every forwarded raw
 * command line, so it takes precedence over launcher-provided SwiftShader
 * fallback switches while leaving all original arguments intact.
 */
#define WIN32_LEAN_AND_MEAN
#include <windows.h>
#include <stddef.h>
#include <wchar.h>

#define COMMAND_LINE_CAPACITY 32767u /* includes the terminating NUL */
#define MODULE_PATH_CAPACITY 32768u
#define ARRAY_COUNT(array) (sizeof(array) / sizeof((array)[0]))

static wchar_t real_path[MODULE_PATH_CAPACITY];
static wchar_t forwarded_command_line[COMMAND_LINE_CAPACITY];

static BOOL append_chars(wchar_t *destination,
                        size_t capacity,
                        size_t *length,
                        const wchar_t *source,
                        size_t source_length)
{
    if (destination == NULL || length == NULL || source == NULL ||
        *length >= capacity || source_length > capacity - *length - 1u) {
        return FALSE;
    }

    wmemcpy(destination + *length, source, source_length);
    *length += source_length;
    destination[*length] = L'\0';
    return TRUE;
}

static BOOL bounded_length(const wchar_t *text, size_t capacity, size_t *length)
{
    size_t i;

    if (text == NULL || length == NULL) {
        return FALSE;
    }

    for (i = 0; i < capacity; ++i) {
        if (text[i] == L'\0') {
            *length = i;
            return TRUE;
        }
    }

    return FALSE;
}

static DWORD build_real_path(size_t *real_path_length)
{
    static const wchar_t real_exe[] = L"SocialClubHelper_real.exe";
    DWORD path_length;
    wchar_t *last_separator = NULL;
    size_t directory_length;
    size_t i;

    path_length = GetModuleFileNameW(NULL, real_path,
                                    (DWORD)ARRAY_COUNT(real_path));
    if (path_length == 0) {
        DWORD error_code = GetLastError();
        return error_code != ERROR_SUCCESS ? error_code : ERROR_GEN_FAILURE;
    }
    if ((size_t)path_length >= ARRAY_COUNT(real_path)) {
        return ERROR_INSUFFICIENT_BUFFER;
    }

    real_path[path_length] = L'\0';
    for (i = 0; i < (size_t)path_length; ++i) {
        if (real_path[i] == L'\\' || real_path[i] == L'/') {
            last_separator = real_path + i;
        }
    }
    if (last_separator == NULL ||
        last_separator == real_path + (size_t)path_length - 1u) {
        return ERROR_BAD_PATHNAME;
    }

    directory_length = (size_t)(last_separator - real_path) + 1u;
    real_path[directory_length] = L'\0';
    if (!append_chars(real_path, ARRAY_COUNT(real_path), &directory_length,
                      real_exe, ARRAY_COUNT(real_exe) - 1u)) {
        return ERROR_INSUFFICIENT_BUFFER;
    }

    *real_path_length = directory_length;
    return ERROR_SUCCESS;
}

/* Return the position immediately after argv[0], preserving its raw suffix. */
static const wchar_t *after_argv0(const wchar_t *command_line)
{
    const wchar_t *p = command_line;

    while (*p == L' ' || *p == L'\t') {
        ++p;
    }
    if (*p == L'\0') {
        return NULL;
    }

    if (*p == L'"') {
        ++p;
        while (*p != L'\0' && *p != L'"') {
            ++p;
        }
        if (*p != L'"') {
            return NULL;
        }
        ++p;
    } else {
        while (*p != L'\0' && *p != L' ' && *p != L'\t') {
            ++p;
        }
    }

    return p;
}

static DWORD build_forwarded_command_line(const wchar_t *original_command_line,
                                         size_t original_length,
                                         size_t real_path_length)
{
    static const wchar_t quote = L'"';
    static const wchar_t separator = L' ';
    static const wchar_t use_gl[] = L"--use-gl=angle";
    static const wchar_t use_angle[] = L"--use-angle=swiftshader";
    const wchar_t *raw_arguments;
    size_t raw_arguments_length;
    size_t length = 0;

    raw_arguments = after_argv0(original_command_line);
    if (raw_arguments == NULL) {
        return ERROR_INVALID_DATA;
    }
    raw_arguments_length = original_length -
        (size_t)(raw_arguments - original_command_line);

    forwarded_command_line[0] = L'\0';
    if (!append_chars(forwarded_command_line, ARRAY_COUNT(forwarded_command_line),
                      &length, &quote, 1u) ||
        !append_chars(forwarded_command_line, ARRAY_COUNT(forwarded_command_line),
                      &length, real_path, real_path_length) ||
        !append_chars(forwarded_command_line, ARRAY_COUNT(forwarded_command_line),
                      &length, &quote, 1u) ||
        !append_chars(forwarded_command_line, ARRAY_COUNT(forwarded_command_line),
                      &length, raw_arguments, raw_arguments_length) ||
        !append_chars(forwarded_command_line, ARRAY_COUNT(forwarded_command_line),
                      &length, &separator, 1u) ||
        !append_chars(forwarded_command_line, ARRAY_COUNT(forwarded_command_line),
                      &length, use_gl, ARRAY_COUNT(use_gl) - 1u) ||
        !append_chars(forwarded_command_line, ARRAY_COUNT(forwarded_command_line),
                      &length, &separator, 1u) ||
        !append_chars(forwarded_command_line, ARRAY_COUNT(forwarded_command_line),
                      &length, use_angle, ARRAY_COUNT(use_angle) - 1u)) {
        return ERROR_INSUFFICIENT_BUFFER;
    }

    return ERROR_SUCCESS;
}

static void show_failure(DWORD error_code)
{
    static const wchar_t prefix[] = L"SocialClubHelper shim failed (error ";
    static const wchar_t suffix[] = L").";
    wchar_t message[96];
    wchar_t digits[10];
    size_t message_length = 0;
    size_t digit_count = 0;

    if (error_code == ERROR_SUCCESS) {
        error_code = ERROR_GEN_FAILURE;
    }

    message[0] = L'\0';
    (void)append_chars(message, ARRAY_COUNT(message), &message_length,
                       prefix, ARRAY_COUNT(prefix) - 1u);
    do {
        digits[digit_count++] = (wchar_t)(L'0' + (error_code % 10u));
        error_code /= 10u;
    } while (error_code != 0u && digit_count < ARRAY_COUNT(digits));
    while (digit_count > 0u) {
        (void)append_chars(message, ARRAY_COUNT(message), &message_length,
                           digits + --digit_count, 1u);
    }
    (void)append_chars(message, ARRAY_COUNT(message), &message_length,
                       suffix, ARRAY_COUNT(suffix) - 1u);

    (void)MessageBoxW(NULL, message, L"SocialClubHelper",
                      MB_OK | MB_ICONERROR | MB_TASKMODAL);
}

static int fail_with_code(DWORD error_code)
{
    if (error_code == ERROR_SUCCESS) {
        error_code = ERROR_GEN_FAILURE;
    }
    show_failure(error_code);
    return (int)error_code;
}

int WINAPI wWinMain(HINSTANCE instance,
                    HINSTANCE previous_instance,
                    PWSTR command_line_argument,
                    int show_command)
{
    STARTUPINFOW startup_info;
    PROCESS_INFORMATION process_info;
    const wchar_t *original_command_line;
    size_t original_length;
    size_t real_path_length;
    DWORD error_code;
    DWORD wait_result;
    DWORD exit_code;

    (void)instance;
    (void)previous_instance;
    (void)command_line_argument;
    (void)show_command;

    error_code = build_real_path(&real_path_length);
    if (error_code != ERROR_SUCCESS) {
        return fail_with_code(error_code);
    }

    original_command_line = GetCommandLineW();
    if (!bounded_length(original_command_line, COMMAND_LINE_CAPACITY,
                        &original_length)) {
        return fail_with_code(ERROR_INSUFFICIENT_BUFFER);
    }

    error_code = build_forwarded_command_line(original_command_line,
                                              original_length,
                                              real_path_length);
    if (error_code != ERROR_SUCCESS) {
        return fail_with_code(error_code);
    }

    ZeroMemory(&startup_info, sizeof(startup_info));
    startup_info.cb = sizeof(startup_info);
    ZeroMemory(&process_info, sizeof(process_info));

    if (!CreateProcessW(real_path, forwarded_command_line, NULL, NULL, TRUE, 0,
                        NULL, NULL, &startup_info, &process_info)) {
        error_code = GetLastError();
        return fail_with_code(error_code);
    }

    (void)CloseHandle(process_info.hThread);
    wait_result = WaitForSingleObject(process_info.hProcess, INFINITE);
    if (wait_result != WAIT_OBJECT_0) {
        error_code = wait_result == WAIT_FAILED ? GetLastError() : ERROR_GEN_FAILURE;
        (void)CloseHandle(process_info.hProcess);
        return fail_with_code(error_code);
    }

    if (!GetExitCodeProcess(process_info.hProcess, &exit_code)) {
        error_code = GetLastError();
        (void)CloseHandle(process_info.hProcess);
        return fail_with_code(error_code);
    }

    (void)CloseHandle(process_info.hProcess);
    return (int)exit_code;
}
