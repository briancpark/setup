#!/bin/bash

# Directory to scan (defaults to current directory if none provided)
DIR="${1:-.}"

# Check if ffmpeg is installed
if ! command -v ffmpeg &>/dev/null; then
    echo "ffmpeg not found. Please install ffmpeg first."
    exit 1
fi

# Process each .mp4 file
for file in "$DIR"/*.mp4; do
    [ -e "$file" ] || continue  # skip if no .mp4 found
    echo "Processing: $file"

    temp_file="${file%.mp4}_repaired.mp4"

    # Attempt to rewrap without re-encoding
    if ffmpeg -y -i "$file" -c copy "$temp_file" &>/dev/null; then
        mv "$temp_file" "$file"
        echo "✔ Repaired: $file"
    else
        echo "✖ Failed to repair: $file"
        rm -f "$temp_file"
    fi
done

echo "Done."
