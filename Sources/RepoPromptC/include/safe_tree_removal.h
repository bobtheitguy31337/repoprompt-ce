#ifndef RP_SAFE_TREE_REMOVAL_H
#define RP_SAFE_TREE_REMOVAL_H

// Removes a relative, non-symlink filesystem tree beneath an already pinned
// directory descriptor. Returns zero or an errno value.
int rp_remove_tree_at(int root_fd, const char *relative_path);
int rp_rename_at(int root_fd, const char *source_relative_path, const char *destination_relative_path);

#endif
