# Shared by the native engine and codec builds. DEPS and DOWNLOAD belong to
# the calling script; its EXIT trap removes the private download staging area.
source_archive() {
    local name="$1" url="$2" hash="$3" strip="$4"
    if [ -f "$DEPS/$name/.leaf-source" ] && [ "$(cat "$DEPS/$name/.leaf-source")" = "$hash" ]; then return; fi
    [ ! -e "$DEPS/$name" ] || { echo "Incomplete source directory: $DEPS/$name" >&2; exit 1; }
    curl --fail --location --connect-timeout 20 --max-time 300 --silent --show-error "$url" -o "$DOWNLOAD/archive"
    echo "$hash  $DOWNLOAD/archive" | shasum -a 256 -c -
    mkdir "$DOWNLOAD/source"
    tar -xf "$DOWNLOAD/archive" --strip-components="$strip" -C "$DOWNLOAD/source"
    echo "$hash" > "$DOWNLOAD/source/.leaf-source"
    mv "$DOWNLOAD/source" "$DEPS/$name"
    rm "$DOWNLOAD/archive"
}
