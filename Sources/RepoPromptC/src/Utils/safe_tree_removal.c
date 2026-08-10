#include "safe_tree_removal.h"

#include <dirent.h>
#include <errno.h>
#include <fcntl.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <sys/stat.h>
#include <unistd.h>

static int rp_remove_entry_at(int parent_fd, const char *name) {
    struct stat status;
    if (fstatat(parent_fd, name, &status, AT_SYMLINK_NOFOLLOW) != 0) {
        return errno;
    }
    if (!S_ISDIR(status.st_mode)) {
        if (unlinkat(parent_fd, name, 0) != 0) return errno;
        return fsync(parent_fd) == 0 ? 0 : errno;
    }

    int child_fd = openat(parent_fd, name, O_RDONLY | O_DIRECTORY | O_NOFOLLOW | O_CLOEXEC);
    if (child_fd < 0) {
        return errno;
    }
    DIR *directory = fdopendir(child_fd);
    if (directory == NULL) {
        int result = errno;
        close(child_fd);
        return result;
    }
    int result = 0;
    for (;;) {
        errno = 0;
        struct dirent *entry = readdir(directory);
        if (entry == NULL) {
            if (errno != 0) result = errno;
            break;
        }
        if (strcmp(entry->d_name, ".") == 0 || strcmp(entry->d_name, "..") == 0) continue;
        result = rp_remove_entry_at(dirfd(directory), entry->d_name);
        if (result != 0) break;
    }
    if (closedir(directory) != 0 && result == 0) result = errno;
    if (result != 0) return result;
    if (unlinkat(parent_fd, name, AT_REMOVEDIR) != 0) return errno;
    return fsync(parent_fd) == 0 ? 0 : errno;
}

static int rp_open_parent(int root_fd, const char *relative_path, int *parent_fd, char **storage, char **name) {
    if (relative_path == NULL || relative_path[0] == '\0' || relative_path[0] == '/') return EINVAL;
    char *path = strdup(relative_path);
    if (path == NULL) return ENOMEM;
    int current_fd = dup(root_fd);
    if (current_fd < 0) {
        int result = errno;
        free(path);
        return result;
    }
    char *component = path;
    for (;;) {
        char *separator = strchr(component, '/');
        if (separator == NULL) break;
        *separator = '\0';
        if (component[0] == '\0' || strcmp(component, ".") == 0 || strcmp(component, "..") == 0) {
            close(current_fd);
            free(path);
            return EINVAL;
        }
        int next_fd = openat(current_fd, component, O_RDONLY | O_DIRECTORY | O_NOFOLLOW | O_CLOEXEC);
        if (next_fd < 0) {
            int result = errno;
            close(current_fd);
            free(path);
            return result;
        }
        close(current_fd);
        current_fd = next_fd;
        component = separator + 1;
    }
    if (component[0] == '\0' || strcmp(component, ".") == 0 || strcmp(component, "..") == 0) {
        close(current_fd);
        free(path);
        return EINVAL;
    }
    *parent_fd = current_fd;
    *storage = path;
    *name = component;
    return 0;
}

int rp_remove_tree_at(int root_fd, const char *relative_path) {
    if (root_fd < 0 || relative_path == NULL || relative_path[0] == '\0' || relative_path[0] == '/') return EINVAL;
    char *path = strdup(relative_path);
    if (path == NULL) return ENOMEM;

    int parent_fd = dup(root_fd);
    if (parent_fd < 0) {
        int result = errno;
        free(path);
        return result;
    }
    int result = 0;
    char *component = path;
    for (;;) {
        char *separator = strchr(component, '/');
        if (separator == NULL) break;
        *separator = '\0';
        if (component[0] == '\0' || strcmp(component, ".") == 0 || strcmp(component, "..") == 0) {
            result = EINVAL;
            goto done;
        }
        int next_fd = openat(parent_fd, component, O_RDONLY | O_DIRECTORY | O_NOFOLLOW | O_CLOEXEC);
        if (next_fd < 0) {
            result = errno;
            goto done;
        }
        close(parent_fd);
        parent_fd = next_fd;
        component = separator + 1;
    }
    if (component[0] == '\0' || strcmp(component, ".") == 0 || strcmp(component, "..") == 0) {
        result = EINVAL;
        goto done;
    }
    result = rp_remove_entry_at(parent_fd, component);

done:
    close(parent_fd);
    free(path);
    return result;
}

int rp_rename_at(int root_fd, const char *source_relative_path, const char *destination_relative_path) {
    int source_parent = -1;
    int destination_parent = -1;
    char *source_storage = NULL;
    char *destination_storage = NULL;
    char *source_name = NULL;
    char *destination_name = NULL;
    int result = rp_open_parent(root_fd, source_relative_path, &source_parent, &source_storage, &source_name);
    if (result != 0) goto done;
    result = rp_open_parent(root_fd, destination_relative_path, &destination_parent, &destination_storage, &destination_name);
    if (result != 0) goto done;

    struct stat status;
    if (fstatat(source_parent, source_name, &status, AT_SYMLINK_NOFOLLOW) != 0) {
        result = errno;
        goto done;
    }
    if (S_ISLNK(status.st_mode)) {
        result = EPERM;
        goto done;
    }
    if (fstatat(destination_parent, destination_name, &status, AT_SYMLINK_NOFOLLOW) == 0) {
        result = EEXIST;
        goto done;
    }
    if (errno != ENOENT) {
        result = errno;
        goto done;
    }
    if (renameat(source_parent, source_name, destination_parent, destination_name) != 0) {
        result = errno;
        goto done;
    }
    if (fsync(source_parent) != 0 || fsync(destination_parent) != 0) result = errno;

done:
    if (source_parent >= 0) close(source_parent);
    if (destination_parent >= 0) close(destination_parent);
    free(source_storage);
    free(destination_storage);
    return result;
}
