#!/usr/bin/env bash
set -euo pipefail
umask 022

repo=/srv/git/blog.git
source_dir=/srv/blog/source
lock_file=/srv/blog/deploy.lock
target_revision=

while read -r old_revision new_revision ref_name; do
    if [[ "$ref_name" == "refs/heads/main" ]]; then
        target_revision=$new_revision
    fi
done

[[ -n "$target_revision" ]] || exit 0
[[ "$target_revision" != "0000000000000000000000000000000000000000" ]] || {
    echo "Refusing to deploy a deleted main branch." >&2
    exit 1
}

exec 9>"$lock_file"
flock -n 9 || {
    echo "Another blog deployment is running." >&2
    exit 1
}

install -d -m 0755 "$source_dir"
git --git-dir="$repo" --work-tree="$source_dir" checkout -f "$target_revision"
printf '%s\n' "$target_revision" > /srv/blog/source-revision
echo "Blog source updated: ${target_revision:0:12}"
