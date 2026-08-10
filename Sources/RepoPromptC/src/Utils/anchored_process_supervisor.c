#define _GNU_SOURCE
#include "anchored_process_supervisor.h"

#include <dirent.h>
#include <errno.h>
#include <fcntl.h>
#include <limits.h>
#include <poll.h>
#include <signal.h>
#include <stdint.h>
#include <stdlib.h>
#include <string.h>
#include <sys/resource.h>
#include <sys/socket.h>
#include <sys/syscall.h>
#include <sys/wait.h>
#include <time.h>
#include <unistd.h>

#if defined(__linux__)
#include <sys/prctl.h>
#endif

#if !defined(__linux__)
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
) {
    (void)executable; (void)argument_blob; (void)argument_blob_size;
    (void)environment_blob; (void)environment_blob_size;
    (void)working_directory; (void)output_fd; (void)supervisor_pid;
    (void)status_fd; (void)control_fd;
    return ENOTSUP;
}
int rp_anchored_process_poll_status(int status_fd, int32_t *exit_status) {
    (void)status_fd; (void)exit_status; return -ENOTSUP;
}
int rp_anchored_process_send_command(int control_fd, uint8_t command) {
    (void)control_fd; (void)command; return ENOTSUP;
}
int rp_anchored_process_poll_reap(pid_t supervisor_pid, int32_t *wait_status) {
    (void)supervisor_pid; (void)wait_status; return -ENOTSUP;
}
#else

static int rp_make_vector(
    const char *first,
    const char *blob,
    size_t blob_size,
    char ***vector_out,
    char **storage_out
) {
    size_t count = first == NULL ? 0 : 1;
    for (size_t index = 0; index < blob_size;) {
        size_t remaining = blob_size - index;
        size_t length = strnlen(blob + index, remaining);
        if (length == remaining) return EINVAL;
        count += 1;
        index += length + 1;
    }
    char *storage = NULL;
    if (blob_size > 0) {
        storage = malloc(blob_size);
        if (storage == NULL) return ENOMEM;
        memcpy(storage, blob, blob_size);
    }
    char **vector = calloc(count + 1, sizeof(char *));
    if (vector == NULL) {
        free(storage);
        return ENOMEM;
    }
    size_t vector_index = 0;
    if (first != NULL) vector[vector_index++] = (char *)first;
    for (size_t index = 0; index < blob_size;) {
        vector[vector_index++] = storage + index;
        index += strlen(storage + index) + 1;
    }
    vector[vector_index] = NULL;
    *vector_out = vector;
    *storage_out = storage;
    return 0;
}

static int rp_write_all(int fd, const void *bytes, size_t length) {
    const uint8_t *cursor = bytes;
    while (length > 0) {
        ssize_t written = write(fd, cursor, length);
        if (written < 0) {
            if (errno == EINTR) continue;
            return errno;
        }
        cursor += written;
        length -= (size_t)written;
    }
    return 0;
}

static int32_t rp_normalized_wait_status(int status) {
    if (WIFEXITED(status)) return (int32_t)WEXITSTATUS(status);
    if (WIFSIGNALED(status)) return (int32_t)(128 + WTERMSIG(status));
    return 127;
}

static void rp_reset_child_signals(void) {
    struct sigaction action;
    memset(&action, 0, sizeof(action));
    action.sa_handler = SIG_DFL;
    sigemptyset(&action.sa_mask);
    (void)sigaction(SIGTERM, &action, NULL);
    (void)sigaction(SIGINT, &action, NULL);
    (void)sigaction(SIGHUP, &action, NULL);
    (void)sigaction(SIGPIPE, &action, NULL);
}

static void rp_terminate_on_parent_loss(void) {
    (void)kill(0, SIGTERM);
    struct timespec delay = { .tv_sec = 0, .tv_nsec = 500000000 };
    while (nanosleep(&delay, &delay) != 0 && errno == EINTR) {}
    (void)kill(0, SIGKILL);
    _exit(255);
}

static int rp_force_close_range_fallback(char *const environment[]) {
    static const char variable[] = "REPOPROMPT_TEST_FORCE_CLOSE_RANGE_FALLBACK=1";
    if (environment == NULL) return 0;
    for (size_t index = 0; environment[index] != NULL; ++index) {
        if (strcmp(environment[index], variable) == 0) return 1;
    }
    return 0;
}

static void rp_close_descriptor_range(unsigned int first, unsigned int last, int force_fallback) {
#if defined(SYS_close_range)
    if (!force_fallback && syscall(SYS_close_range, first, last, 0) == 0) return;
#endif

    // Linux exposes the actual open descriptor set through procfs. Enumerating
    // it avoids both arbitrary descriptor caps and pathological close loops.
    DIR *directory = opendir("/proc/self/fd");
    if (directory != NULL) {
        int enumeration_fd = dirfd(directory);
        struct dirent *entry;
        while ((entry = readdir(directory)) != NULL) {
            char *end = NULL;
            errno = 0;
            unsigned long value = strtoul(entry->d_name, &end, 10);
            if (errno != 0 || end == entry->d_name || *end != '\0' || value > INT_MAX) continue;
            unsigned int descriptor = (unsigned int)value;
            if (descriptor >= first && descriptor <= last && (int)descriptor != enumeration_fd) {
                (void)close((int)descriptor);
            }
        }
        (void)closedir(directory);
        return;
    }

    // Procfs may be unavailable in a restricted namespace. A finite rlimit is
    // an exhaustive upper bound and must not be truncated. If it is infinite,
    // sysconf normally reports Linux's finite open-file ceiling; INT_MAX is the
    // final exhaustive bound because file descriptors are signed ints.
    struct rlimit limit;
    rlim_t upper;
    if (getrlimit(RLIMIT_NOFILE, &limit) == 0 && limit.rlim_cur != RLIM_INFINITY) {
        if (limit.rlim_cur == 0) return;
        upper = limit.rlim_cur - 1;
    } else {
        long configured = sysconf(_SC_OPEN_MAX);
        upper = configured > 0 ? (rlim_t)(configured - 1) : (rlim_t)INT_MAX;
    }
    if (upper > (rlim_t)INT_MAX) upper = (rlim_t)INT_MAX;
    if (last != UINT_MAX && upper > (rlim_t)last) upper = (rlim_t)last;
    for (rlim_t descriptor = first; descriptor <= upper; ++descriptor) {
        (void)close((int)descriptor);
        if (descriptor == upper) break;
    }
}

static int rp_isolate_supervisor_descriptors(
    int *output_fd,
    int *status_fd,
    int *control_fd,
    int force_close_range_fallback
) {
    int output_copy = fcntl(*output_fd, F_DUPFD_CLOEXEC, 200);
    if (output_copy < 0) return errno;
    int status_copy = fcntl(*status_fd, F_DUPFD_CLOEXEC, output_copy + 1);
    if (status_copy < 0) { int result = errno; close(output_copy); return result; }
    int control_copy = fcntl(*control_fd, F_DUPFD_CLOEXEC, status_copy + 1);
    if (control_copy < 0) {
        int result = errno; close(output_copy); close(status_copy); return result;
    }
    if (dup2(output_copy, 100) < 0 || dup2(status_copy, 101) < 0 || dup2(control_copy, 102) < 0) {
        int result = errno; close(output_copy); close(status_copy); close(control_copy); return result;
    }
    rp_close_descriptor_range(3, 99, force_close_range_fallback);
    rp_close_descriptor_range(103, UINT_MAX, force_close_range_fallback);
    *output_fd = 100;
    *status_fd = 101;
    *control_fd = 102;
    return 0;
}

static void rp_supervise(
    const char *executable,
    char *const arguments[],
    char *const environment[],
    const char *working_directory,
    int output_fd,
    int status_write_fd,
    int control_read_fd,
    pid_t expected_parent,
    int parent_was_lost
) {
    int force_close_range_fallback = rp_force_close_range_fallback(environment);
    if (rp_isolate_supervisor_descriptors(
        &output_fd,
        &status_write_fd,
        &control_read_fd,
        force_close_range_fallback
    ) != 0) _exit(126);
    if (setsid() < 0) _exit(126);

    sigset_t unblocked;
    sigemptyset(&unblocked);
    (void)sigprocmask(SIG_SETMASK, &unblocked, NULL);
    struct sigaction child_action;
    memset(&child_action, 0, sizeof(child_action));
    child_action.sa_handler = SIG_DFL;
    sigemptyset(&child_action.sa_mask);
    (void)sigaction(SIGCHLD, &child_action, NULL);

    struct sigaction ignored;
    memset(&ignored, 0, sizeof(ignored));
    ignored.sa_handler = SIG_IGN;
    sigemptyset(&ignored.sa_mask);
    (void)sigaction(SIGTERM, &ignored, NULL);
    (void)sigaction(SIGINT, &ignored, NULL);
    (void)sigaction(SIGHUP, &ignored, NULL);
    // Status is a pipe so ignoring SIGPIPE is required: parent loss must
    // reach the explicit family cleanup path instead of killing the anchor.
    (void)sigaction(SIGPIPE, &ignored, NULL);

    // PR_SET_PDEATHSIG is armed before setup begins. Delay family cleanup until
    // setsid() makes this supervisor the process-group owner, then recheck once
    // more so parent loss during setup cannot launch an unowned Git process.
    if (parent_was_lost || getppid() != expected_parent) rp_terminate_on_parent_loss();

    pid_t git_pid = fork();
    if (git_pid == 0) {
        rp_reset_child_signals();
        if (dup2(output_fd, STDOUT_FILENO) < 0 || dup2(output_fd, STDERR_FILENO) < 0) _exit(126);
        close(status_write_fd);
        close(control_read_fd);
        if (output_fd != STDOUT_FILENO && output_fd != STDERR_FILENO) close(output_fd);
        if (chdir(working_directory) != 0) _exit(126);
        execve(executable, arguments, environment);
        _exit(127);
    }
    close(output_fd);

    int git_finished = 0;
    int32_t git_status = 127;
    if (git_pid < 0) git_finished = 1;

    for (;;) {
        if (!git_finished) {
            int status = 0;
            pid_t result = waitpid(git_pid, &status, WNOHANG);
            if (result == git_pid) {
                git_status = rp_normalized_wait_status(status);
                git_finished = 1;
            } else if (result < 0 && errno != EINTR) {
                git_status = 127;
                git_finished = 1;
            }
        }
        if (git_finished && status_write_fd >= 0) {
            if (rp_write_all(status_write_fd, &git_status, sizeof(git_status)) != 0) {
                rp_terminate_on_parent_loss();
            }
            close(status_write_fd);
            status_write_fd = -1;
        }

        struct pollfd descriptor = { .fd = control_read_fd, .events = POLLIN | POLLHUP, .revents = 0 };
        int poll_result;
        do { poll_result = poll(&descriptor, 1, 20); } while (poll_result < 0 && errno == EINTR);
        if (poll_result < 0) rp_terminate_on_parent_loss();
        if (poll_result == 0) continue;
        if ((descriptor.revents & (POLLHUP | POLLERR | POLLNVAL)) != 0
            && (descriptor.revents & POLLIN) == 0) {
            rp_terminate_on_parent_loss();
        }
        if ((descriptor.revents & POLLIN) != 0) {
            uint8_t commands[16];
            ssize_t count;
            do { count = read(control_read_fd, commands, sizeof(commands)); } while (count < 0 && errno == EINTR);
            if (count <= 0) rp_terminate_on_parent_loss();
            for (ssize_t index = 0; index < count; ++index) {
                switch (commands[index]) {
                case RP_ANCHORED_COMMAND_TERM:
                    (void)kill(0, SIGTERM);
                    break;
                case RP_ANCHORED_COMMAND_KILL:
                    (void)kill(0, SIGKILL);
                    _exit(255);
                case RP_ANCHORED_COMMAND_RELEASE:
                    if (git_finished) {
                        // The anchor still owns this numeric process group at
                        // the instant of the final family kill. This both
                        // releases the supervisor and prevents helper orphans.
                        (void)kill(0, SIGKILL);
                        _exit(255);
                    }
                    break;
                default:
                    rp_terminate_on_parent_loss();
                }
            }
        }
    }
}

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
) {
    if (executable == NULL || working_directory == NULL || output_fd < 0
        || supervisor_pid == NULL || status_fd == NULL || control_fd == NULL
        || (argument_blob_size > 0 && argument_blob == NULL)
        || (environment_blob_size > 0 && environment_blob == NULL)) return EINVAL;

    char **arguments = NULL;
    char **environment = NULL;
    char *argument_storage = NULL;
    char *environment_storage = NULL;
    int result = rp_make_vector(executable, argument_blob, argument_blob_size, &arguments, &argument_storage);
    if (result != 0) return result;
    result = rp_make_vector(NULL, environment_blob, environment_blob_size, &environment, &environment_storage);
    if (result != 0) {
        free(arguments); free(argument_storage);
        return result;
    }

    int status_pipe[2] = { -1, -1 };
    int control_socket[2] = { -1, -1 };
    if (pipe2(status_pipe, O_CLOEXEC) != 0
        || socketpair(AF_UNIX, SOCK_STREAM | SOCK_CLOEXEC, 0, control_socket) != 0) {
        result = errno;
        if (status_pipe[0] >= 0) { close(status_pipe[0]); close(status_pipe[1]); }
        if (control_socket[0] >= 0) { close(control_socket[0]); close(control_socket[1]); }
        free(arguments); free(argument_storage); free(environment); free(environment_storage);
        return result;
    }

    pid_t expected_parent = getpid();
    pid_t pid = fork();
    if (pid < 0) {
        result = errno;
        close(status_pipe[0]); close(status_pipe[1]); close(control_socket[0]); close(control_socket[1]);
        free(arguments); free(argument_storage); free(environment); free(environment_storage);
        return result;
    }
    if (pid == 0) {
        // SIGCONT wakes an externally stopped supervisor without terminating it;
        // the closed control socket then drives the normal whole-family cleanup.
        // The immediate parent check closes the fork-to-prctl race.
        struct sigaction continued;
        memset(&continued, 0, sizeof(continued));
        continued.sa_handler = SIG_DFL;
        sigemptyset(&continued.sa_mask);
        (void)sigaction(SIGCONT, &continued, NULL);
        if (prctl(PR_SET_PDEATHSIG, SIGCONT) != 0) _exit(126);
        int parent_was_lost = getppid() != expected_parent;

        close(status_pipe[0]);
        close(control_socket[1]);
        rp_supervise(
            executable,
            arguments,
            environment,
            working_directory,
            output_fd,
            status_pipe[1],
            control_socket[0],
            expected_parent,
            parent_was_lost
        );
        _exit(255);
    }

    close(status_pipe[1]);
    close(control_socket[0]);
    int flags = fcntl(status_pipe[0], F_GETFL, 0);
    if (flags >= 0) (void)fcntl(status_pipe[0], F_SETFL, flags | O_NONBLOCK);
    *supervisor_pid = pid;
    *status_fd = status_pipe[0];
    *control_fd = control_socket[1];
    free(arguments); free(argument_storage); free(environment); free(environment_storage);
    return 0;
}

int rp_anchored_process_poll_status(int status_fd, int32_t *exit_status) {
    if (status_fd < 0 || exit_status == NULL) return -EINVAL;
    int32_t value = 0;
    ssize_t count;
    do { count = read(status_fd, &value, sizeof(value)); } while (count < 0 && errno == EINTR);
    if (count == (ssize_t)sizeof(value)) {
        *exit_status = value;
        return 1;
    }
    if (count < 0 && (errno == EAGAIN || errno == EWOULDBLOCK)) return 0;
    if (count == 0) return -EPIPE;
    return count < 0 ? -errno : -EIO;
}

int rp_anchored_process_send_command(int control_fd, uint8_t command) {
    if (control_fd < 0) return EBADF;
    ssize_t written;
    do {
        written = send(control_fd, &command, sizeof(command), MSG_NOSIGNAL);
    } while (written < 0 && errno == EINTR);
    if (written == (ssize_t)sizeof(command)) return 0;
    return written < 0 ? errno : EIO;
}

int rp_anchored_process_poll_reap(pid_t supervisor_pid, int32_t *wait_status) {
    if (supervisor_pid <= 1 || wait_status == NULL) return -EINVAL;
    int status = 0;
    pid_t result;
    do { result = waitpid(supervisor_pid, &status, WNOHANG); } while (result < 0 && errno == EINTR);
    if (result == 0) return 0;
    if (result == supervisor_pid) {
        *wait_status = rp_normalized_wait_status(status);
        return 1;
    }
    if (result < 0 && errno == ECHILD) return 1;
    return result < 0 ? -errno : -EIO;
}
#endif
