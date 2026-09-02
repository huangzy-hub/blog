#!/usr/bin/env bash
set -euo pipefail
umask 022

archive=${1:?archive path is required}
revision=${2:?Git revision is required}

[[ "$archive" == /srv/blog/incoming/*.tar.gz ]] || {
    echo "Archive must be under /srv/blog/incoming." >&2
    exit 2
}
[[ "$revision" =~ ^[0-9a-f]{40}$ ]] || {
    echo "Invalid Git revision." >&2
    exit 2
}
[[ -f "$archive" ]] || {
    echo "Archive not found: $archive" >&2
    exit 2
}

exec 9>/srv/blog/deploy.lock
flock -n 9 || {
    echo "Another blog deployment is running." >&2
    exit 1
}

releases_dir=/srv/blog/releases
release_id="$(date -u +%Y%m%dT%H%M%SZ)-${revision:0:12}"
release_dir="$releases_dir/$release_id"
install -d -m 0755 "$release_dir"
tar --extract --gzip --file "$archive" --directory "$release_dir" --no-same-owner
test -f "$release_dir/index.html"

next_link=/srv/blog/current.next
rm -f "$next_link"
ln -s "$release_dir" "$next_link"
mv -Tf "$next_link" /srv/blog/current
printf '%s\n' "$revision" > /srv/blog/deployed-revision
rm -f "$archive"

echo "Blog deployed: $release_id"
