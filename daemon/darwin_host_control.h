#pragma once
#include <stddef.h>

typedef enum sayall_darwin_result {
    SAYALL_DARWIN_SUCCESS = 0,
    SAYALL_DARWIN_ABSENT_LAUNCHABLE = 1,
    SAYALL_DARWIN_UNSAFE = 2,
    SAYALL_DARWIN_TIMEOUT = 3,
    SAYALL_DARWIN_INCOMPATIBLE = 4,
    SAYALL_DARWIN_TRANSPORT = 5,
} sayall_darwin_result;

int sayall_darwin_probe(unsigned long long deadline_ns);
int sayall_darwin_exchange(const char *method, unsigned long long deadline_ns, char **reply, size_t *reply_len);
int sayall_darwin_launch_containing_app(void);
void sayall_darwin_free(void *pointer);
char *sayall_darwin_effective_home(void);
unsigned long long sayall_darwin_monotonic_now(void);
void sayall_darwin_sleep_ns(unsigned long long duration_ns);

// Internal test seams used by the native bridge test target.
int sayall_darwin_classify_errno(int error, int endpoint_validated, int probe);
int sayall_darwin_validate_app_path(const char *executable_path, char *app_path, size_t capacity);
int sayall_darwin_classify_frame(const char *bytes, size_t length, size_t *payload_length);
