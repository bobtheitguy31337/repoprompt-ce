#ifndef RP_ANCHORED_PROCESS_SUPERVISOR_H
#define RP_ANCHORED_PROCESS_SUPERVISOR_H

#include <stddef.h>
#include <stdint.h>
#include <sys/types.h>

enum {
    RP_ANCHORED_COMMAND_TERM = 1,
    RP_ANCHORED_COMMAND_KILL = 2,
    RP_ANCHORED_COMMAND_RELEASE = 3
};

// Linux-only process supervisor. The argument/environment blobs contain
// consecutive NUL-terminated strings; argv[0] is supplied from executable.
// Returns zero or an errno value.
int rp_anchored_process_spawn(
    const char *executable,
    const char *argument_blob,
    size_t argument_blob_size,
    const char *environment_blob,
    size_t environment_blob_size,
    const char *working_directory,
    int output_fd,
    pid_t *supervisor_pid,
    int *status_fd,
    int *control_fd
);

// Returns 1 when an exact Git exit status was read, 0 while pending, or a
// negative errno value.
int rp_anchored_process_poll_status(int status_fd, int32_t *exit_status);

// Returns zero or an errno value.
int rp_anchored_process_send_command(int control_fd, uint8_t command);

// Returns 1 once reaped, 0 while still alive, or a negative errno value.
int rp_anchored_process_poll_reap(pid_t supervisor_pid, int32_t *wait_status);

#endif
