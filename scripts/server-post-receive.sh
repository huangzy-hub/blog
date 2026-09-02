#!/usr/bin/env bash
set -euo pipefail
umask 022

repo=/srv/git/blog.git
source_dir=/srv/blog/source
releases_dir=/srv/blog/releases
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

install -d -m 0755 "$source_dir" "$releases_dir"
git --git-dir="$repo" --work-tree="$source_dir" checkout -f "$target_revision"

cd "$source_dir"
corepack pnpm install --frozen-lockfile
corepack pnpm build
test -f dist/index.html

release_id="$(date -u +%Y%m%dT%H%M%SZ)-${target_revision:0:12}"
release_dir="$releases_dir/$release_id"
install -d -m 0755 "$release_dir"
cp -a dist/. "$release_dir/"

next_link=/srv/blog/current.next
rm -f "$next_link"
ln -s "$release_dir" "$next_link"
mv -Tf "$next_link" /srv/blog/current

echo "Blog deployed: $release_id"
