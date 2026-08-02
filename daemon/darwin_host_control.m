#import <AppKit/NSWorkspace.h>
#import <Foundation/NSArray.h>
#import <Foundation/NSBundle.h>
#import <Foundation/NSPathUtilities.h>
#import <Foundation/NSString.h>
#import <Foundation/NSURL.h>
#include <dispatch/dispatch.h>
#include <sys/socket.h>
#include <sys/stat.h>
#include <sys/un.h>
#include <poll.h>
#include <pwd.h>
#include <fcntl.h>
#include <errno.h>
#include <stdlib.h>
#include <unistd.h>
#include <mach-o/dyld.h>
#include <limits.h>

#include "darwin_host_control.h"

enum { frame_limit = 64 * 1024 };

static uint64_t now_ns(void) {
    struct timespec t; clock_gettime(CLOCK_MONOTONIC, &t);
    return (uint64_t)t.tv_sec * 1000000000ULL + (uint64_t)t.tv_nsec;
}
unsigned long long sayall_darwin_monotonic_now(void) { return now_ns(); }
void sayall_darwin_sleep_ns(unsigned long long duration) { usleep((useconds_t)MIN(duration / 1000, UINT_MAX)); }

int sayall_darwin_classify_errno(int error, int endpoint_validated, int probe) {
    if (!error) return SAYALL_DARWIN_SUCCESS;
    if (error == ETIMEDOUT) return SAYALL_DARWIN_TIMEOUT;
    if (error == EPROTO || error == EMSGSIZE) return SAYALL_DARWIN_INCOMPATIBLE;
    if (probe && (error == ENOENT || (endpoint_validated && error == ECONNREFUSED))) return SAYALL_DARWIN_ABSENT_LAUNCHABLE;
    if (error == EACCES || error == EPERM || error == ELOOP || error == ENOTDIR) return SAYALL_DARWIN_UNSAFE;
    return SAYALL_DARWIN_TRANSPORT;
}
static int wait_fd(int fd, short events, uint64_t deadline) {
    for (;;) {
        uint64_t now = now_ns();
        if (now >= deadline) return ETIMEDOUT;
        int ms = (int)MIN((deadline - now + 999999) / 1000000, INT_MAX);
        struct pollfd p = { fd, events, 0 };
        int n = poll(&p, 1, ms);
        if (n < 0 && errno == EINTR) continue;
        if (n <= 0) return n == 0 ? ETIMEDOUT : errno;
        if ((p.revents & (POLLNVAL | POLLERR | POLLHUP)) && !(p.revents & events)) return ECONNRESET;
        return 0;
    }
}
static int endpoint(char path[sizeof(((struct sockaddr_un *)0)->sun_path)]) {
    errno = 0;
    struct passwd *pw = getpwuid(geteuid());
    if (!pw || !pw->pw_dir || pw->pw_dir[0] != '/') return EACCES;
    NSString *home = [NSString stringWithUTF8String:pw->pw_dir];
    NSString *dir = [home stringByAppendingPathComponent:@"Library/Application Support/SayAll/control"];
    struct stat st;
    if (lstat(dir.fileSystemRepresentation, &st)) return errno;
    if (!S_ISDIR(st.st_mode) || S_ISLNK(st.st_mode) || st.st_uid != geteuid() || (st.st_mode & 077) != 0) return EACCES;
    NSString *sock = [dir stringByAppendingPathComponent:@"control.sock"];
    if (lstat(sock.fileSystemRepresentation, &st)) return errno;
    if (!S_ISSOCK(st.st_mode) || S_ISLNK(st.st_mode) || st.st_uid != geteuid() || (st.st_mode & 077) != 0) return EACCES;
    size_t n = strlen(sock.fileSystemRepresentation);
    if (n >= sizeof(((struct sockaddr_un *)0)->sun_path)) return ENAMETOOLONG;
    memcpy(path, sock.fileSystemRepresentation, n + 1); return 0;
}
static int connect_control(uint64_t deadline, int *result) {
    struct sockaddr_un address = { .sun_len = sizeof(address), .sun_family = AF_UNIX };
    int e = endpoint(address.sun_path); if (e) return e;
    int fd = socket(AF_UNIX, SOCK_STREAM, 0); if (fd < 0) return errno;
    if (fcntl(fd, F_SETFD, FD_CLOEXEC) < 0) { e = errno; close(fd); return e; }
    int flags = fcntl(fd, F_GETFL); if (flags < 0 || fcntl(fd, F_SETFL, flags | O_NONBLOCK) < 0) { e = errno; close(fd); return e; }
    if (connect(fd, (struct sockaddr *)&address, sizeof(address)) && errno != EINPROGRESS) { e = errno; close(fd); return e; }
    e = wait_fd(fd, POLLOUT, deadline);
    int socket_error = 0; socklen_t length = sizeof(socket_error);
    if (!e && (getsockopt(fd, SOL_SOCKET, SO_ERROR, &socket_error, &length) || socket_error)) e = socket_error ?: errno;
    uid_t uid; gid_t gid;
    if (!e && (getpeereid(fd, &uid, &gid) || uid != geteuid())) e = EACCES;
    int one = 1; if (!e && setsockopt(fd, SOL_SOCKET, SO_NOSIGPIPE, &one, sizeof(one))) e = errno;
    if (e) { close(fd); return e; } *result = fd; return 0;
}
int sayall_darwin_probe(unsigned long long deadline) {
    char path[sizeof(((struct sockaddr_un *)0)->sun_path)];
    int e = endpoint(path); if (e) return sayall_darwin_classify_errno(e, 0, 1);
    int fd; e = connect_control(deadline, &fd); if (!e) close(fd);
    return sayall_darwin_classify_errno(e, 1, 1);
}
int sayall_darwin_classify_frame(const char *bytes, size_t length, size_t *payload_length) {
    if (!bytes || !payload_length || !length || length > frame_limit) return SAYALL_DARWIN_INCOMPATIBLE;
    const char *nl = memchr(bytes, '\n', length);
    if (!nl || nl != bytes + length - 1) return SAYALL_DARWIN_INCOMPATIBLE;
    *payload_length = length - 1; return SAYALL_DARWIN_SUCCESS;
}
int sayall_darwin_exchange(const char *method, unsigned long long deadline, char **reply, size_t *reply_len) {
    if (!reply || !reply_len) return SAYALL_DARWIN_INCOMPATIBLE; *reply = NULL; *reply_len = 0;
    int fd, e = connect_control(deadline, &fd); if (e) return sayall_darwin_classify_errno(e, 1, 0);
    char request[64]; int request_len = snprintf(request, sizeof(request), "{\"version\":2,\"method\":\"%s\"}\n", method);
    for (int off = 0; off < request_len;) { e = wait_fd(fd, POLLOUT, deadline); if (e) goto done; ssize_t n = write(fd, request + off, request_len - off); if (n < 0 && (errno == EINTR || errno == EAGAIN)) continue; if (n <= 0) { e = errno ?: EIO; goto done; } off += (int)n; }
    char *buffer = malloc(frame_limit); if (!buffer) { e = ENOMEM; goto done; }
    size_t used = 0;
    while (used < frame_limit) { e = wait_fd(fd, POLLIN, deadline); if (e) { free(buffer); goto done; } ssize_t n = read(fd, buffer + used, frame_limit - used); if (n < 0 && (errno == EINTR || errno == EAGAIN)) continue; if (n <= 0) { e = ECONNRESET; free(buffer); goto done; } used += n; if (memchr(buffer, '\n', used)) { size_t payload = 0; if (sayall_darwin_classify_frame(buffer, used, &payload)) { e = EPROTO; free(buffer); goto done; } *reply = buffer; *reply_len = payload; e = 0; goto done; } }
    e = EMSGSIZE; free(buffer);
done: close(fd); return sayall_darwin_classify_errno(e, 1, 0);
}
int sayall_darwin_validate_app_path(const char *executable_path, char *app_path, size_t capacity) {
    char resolved[PATH_MAX];
    if (!executable_path || !realpath(executable_path, resolved)) return SAYALL_DARWIN_UNSAFE;
    NSString *path = [NSString stringWithUTF8String:resolved];
    NSArray *parts = path.pathComponents; NSUInteger n = parts.count;
    if (n < 5) return SAYALL_DARWIN_UNSAFE;
    NSString *appComponent = parts[n-4];
    if (![parts[n-1] isEqual:@"sayall"] || ![parts[n-2] isEqual:@"Helpers"] || ![parts[n-3] isEqual:@"Contents"] || ![appComponent.pathExtension isEqual:@"app"]) return SAYALL_DARWIN_UNSAFE;
    NSString *app = [NSString pathWithComponents:[parts subarrayWithRange:NSMakeRange(0, n-3)]];
    NSBundle *bundle = [NSBundle bundleWithPath:app];
    if (![bundle.bundleIdentifier isEqual:@"pro.leets.sayall"] || ![bundle.executableURL.lastPathComponent isEqual:@"SayAll"] || !bundle.infoDictionary) return SAYALL_DARWIN_UNSAFE;
    const char *validated = bundle.bundleURL.fileSystemRepresentation;
    if (!app_path || strlen(validated) + 1 > capacity) return SAYALL_DARWIN_TRANSPORT;
    strcpy(app_path, validated); return SAYALL_DARWIN_SUCCESS;
}
static NSURL *containing_app(void) {
    // argv is deliberately irrelevant: only dyld's actual executable path is accepted.
    uint32_t size = 0; _NSGetExecutablePath(NULL, &size); char *raw = malloc(size); char app[PATH_MAX];
    if (!raw || _NSGetExecutablePath(raw, &size)) { free(raw); return nil; }
    int result = sayall_darwin_validate_app_path(raw, app, sizeof(app)); free(raw);
    return result == SAYALL_DARWIN_SUCCESS ? [NSURL fileURLWithPath:[NSString stringWithUTF8String:app]] : nil;
}
int sayall_darwin_launch_containing_app(void) {
    NSURL *app = containing_app(); if (!app) return SAYALL_DARWIN_UNSAFE;
    NSWorkspaceOpenConfiguration *configuration = NSWorkspaceOpenConfiguration.configuration;
    configuration.activates = NO; configuration.allowsRunningApplicationSubstitution = NO;
    dispatch_semaphore_t semaphore = dispatch_semaphore_create(0); __block NSError *failure = nil;
    [NSWorkspace.sharedWorkspace openApplicationAtURL:app configuration:configuration completionHandler:^(NSRunningApplication *a, NSError *error) { failure = error; dispatch_semaphore_signal(semaphore); }];
    if (dispatch_semaphore_wait(semaphore, dispatch_time(DISPATCH_TIME_NOW, 2 * NSEC_PER_SEC))) return SAYALL_DARWIN_TIMEOUT;
    return failure ? SAYALL_DARWIN_TRANSPORT : SAYALL_DARWIN_SUCCESS;
}
void sayall_darwin_free(void *pointer) { free(pointer); }
char *sayall_darwin_effective_home(void) {
    errno = 0; struct passwd *pw = getpwuid(geteuid());
    if (!pw || !pw->pw_dir || pw->pw_dir[0] != '/') return NULL;
    return strdup(pw->pw_dir);
}
