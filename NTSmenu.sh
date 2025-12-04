#!/bin/bash

#description: NTS radio stream controller using mpv for playback
#5.0 - show show details

# TODO
# [x] view/archive link to current show in txt file (for viewing later)
# [x] archive current tracklist in txt file (for viewing later)
# [] extend search function to id history
# [] new view id's menu. includes clear history, press to search, view .txt file

declare -A streams=(
    ['NTS Radio 1']="https://stream-relay-geo.ntslive.net/stream"
    ['NTS Radio 2']="https://stream-relay-geo.ntslive.net/stream2"
)

api_url="https://www.nts.live/api/v2/live"

# gets title from NTS API
get_title() {
    local response
    local stream_tit

    response=$(curl -s "$api_url") || {
        notify-send "NTS Controller" "Failed to fetch NTS API"
        echo "Failed to fetch NTS API" >&2
        return 1
    }

    case "$1" in
    "NTS Radio 1")
        stream_tit=$(echo "$response" | jq -r '.results[0].now.broadcast_title')
        ;;
    "NTS Radio 2")
        stream_tit=$(echo "$response" | jq -r '.results[1].now.broadcast_title')
        ;;
    *)
        notify-send "NTS Controller" "Error: Invalid station '$1'"
        echo "Error: Invalid station '$1'" >&2
        return 1
        ;;
    esac

    # decode html entities
    stream_tit=$(echo "$stream_tit" | perl -MHTML::Entities -pe 'decode_entities($_);')

    echo "$stream_tit"
}

# determines which stream is currently running for future functions to call.
get_current_stream() {
    if pgrep -f "mpv .*--title=NTS Radio 1" >/dev/null; then
        station=1
    elif pgrep -f "mpv .*--title=NTS Radio 2" >/dev/null; then
        station=2
    else
        notify-send "NTS Controller" "No NTS stream currently playing"
        echo "No NTS stream currently playing" >&2
        return 1
    fi
}

# fetches show details for current show from NTS api
get_details() {
    local station
    get_current_stream || return 1

    local response
    response=$(curl -s "$api_url") || {
        notify-send "NTS Controller" "Failed to fetch NTS API details"
        return 1
    }

    # extract data and output as json
    jq -r --argjson st "$((station - 1))" '
    .results[$st].now | {
        details: (
            "Title: \(.broadcast_title)\n" +
            "Show: \(.embeds.details.show_alias | gsub("-"; " ") | ascii_upcase)\n" +
            "Schedule: \(.start_timestamp[11:16]) - \(.end_timestamp[11:16])\n" +
            "Description: \(.embeds.details.description // "No description available")\n" +
            "Genres: \((.embeds.details.genres // []) | map(.value) | join(", "))\n" +
            "Moods: \((.embeds.details.moods // []) | map(.value) | join(", "))\n" +
            "Location: \(.embeds.details.location_long // "Unknown" | ascii_upcase)"
        ),
        episode_link: (.links[0].href | sub("/api/v2"; "")),
        show_link: (.embeds.details.links[] | select(.rel=="show") | .href | sub("/api/v2"; ""))
    }' <<<"$response" | perl -MHTML::Entities -pe 'decode_entities($_);'
}

show_details() {
    local data details episode_link show_link

    data=$(get_details) || return 1
    details=$(jq -r '.details' <<<"$data")
    episode_link=$(jq -r '.episode_link' <<<"$data")
    show_link=$(jq -r '.show_link' <<<"$data")

    if [[ -z "$details" || "$details" == "null" ]]; then
        rofi -dmenu -p "Details:" -mesg "Unavailable"
    else
        expand_detail=$(printf "%s\n" "$details" "Bookmark show" | rofi -dmenu -p "Details" -i -f "inter 10" -l 10)

        case $expand_detail in
        "Title:"*) setsid -f xdg-open "$episode_link" ;;
        "Show:"*) setsid -f xdg-open "$show_link" ;;
        "Bookmark show")
            bookmark_dir="/home/drill/.config/NTS Control"
            bookmark_file="/home/drill/.config/NTS Control/episode-bookmarks.txt"

            # extract details
            episode_title=$(echo "$details" | awk -F': ' '/^Title:/ {print $2}')
            episode_show_title=$(echo "$details" | awk -F': ' '/^Show:/ {print $2}')

            mkdir -p "$bookmark_dir" && {
                printf "%s - %s\n%s\n%s\n\n" \
                    "$episode_title" \
                    "$(date +%Y-%m-%d)" \
                    "$episode_show_title" \
                    "$episode_link" >>"$bookmark_file"

                notify-send "Bookmark Added" "'$episode_title' saved to bookmarks"
            } || {
                notify-send "Error" "Failed to save bookmark"
            }
            ;;
        "") ;;
        esac
    fi
}

# fetches tracklist of currently playing show from NTS API
get_tracklist() {
    get_current_stream

    # get API data
    local api_url="https://www.nts.live/api/v2/live"
    local response
    response=$(curl -s "$api_url") || {
        notify-send "NTS Controller" "Failed to connect to NTS API"
        echo "Failed to connect to NTS API" >&2
        return 1
    }

    # extract tracklist URL
    local tracklist_json_url
    tracklist_json_url=$(echo "$response" | jq -r ".results[$((station - 1))].now.embeds.details.links[] | select(.rel==\"tracklist\") | .href") || {
        notify-send "NTS Controller" "Could not find tracklist URL"
        echo "Could not find tracklist URL" >&2
        return 1
    }

    # get tracklist data
    local tracklist_data
    tracklist_data=$(curl -s "$tracklist_json_url") || {
        notify-send "NTS Controller" "Failed to fetch tracklist"
        echo "Failed to fetch tracklist" >&2
        return 1
    }

    # parse and output tracklist
    local tracklist
    tracklist=$(echo "$tracklist_data" | jq -r '.results[] | "\(.artist // "Unknown Artist") - \(.title // "Untitled")"')

    if [[ -z "$tracklist" || "$tracklist" == "null" ]]; then
        echo "No tracklist available"
        return 0
    fi

    echo "$tracklist"
}

# searches song selected from tracklist menu via piping from tracklist menu to query link
search_song() {
    # Multi-line variable assignment (better readability)
    local search_sites="YouTube
SoundCloud
RateYourMusic
Discogs
SoulSeek (unavailable)"

    # present menu
    local website
    website=$(rofi -dmenu -p "Select site to search" -i <<<"$search_sites") || {
        notify-send "NTS Controller" "Search cancelled"
        return 1
    }

    case $website in
    "YouTube") setsid -f xdg-open "https://www.youtube.com/results?search_query='$search_selection'" ;;
    "SoundCloud") setsid -f xdg-open "https://soundcloud.com/search?q='$search_selection'" ;;
    "RateYourMusic") setsid -f xdg-open "https://rateyourmusic.com/search?searchterm='$search_selection'" ;;
    "Discogs") setsid -f xdg-open "https://www.discogs.com/search?q='$search_selection'&type=all" ;;
    "SoulSeek (unavailable)"*) notify-send "NTS Controller" "SoulSeek search under construction" ;;
    *)
        notify-send "NTS Controller" "No site selected. Canceling search."
        echo "NTS Controller" "No site selected. Cancelled search."
        ;;
    esac
}

# displays tracklist info in dmenu
show_tracklist() {
    local tracklist
    tracklist=$(get_tracklist) || {
        notify-send "NTS Radio" "Failed to get tracklist"
        return 1
    }

    if [[ -z "$tracklist" || "$tracklist" == "null" ]]; then
        # display empty state in rofis message area
        rofi -dmenu -p "Tracklist:" -mesg "No current tracklist available"
    else
        # display tracklist in both selection and message areas
        local search_selection
        search_selection=$(echo "$tracklist" | rofi -dmenu -p "Tracklist" -i)

        if [[ -z "$search_selection" ]]; then
            echo "No input (user canceled or empty selection)"
            return 0
        else
            search_song "$search_selection" # Pass the selection as an argument
        fi
    fi
}

# ids currently playing song via songrec (monitors current default sink for input)
id_song() {
    # get default sink and append .monitor --
    local current_default
    current_default=$(pactl info | awk 'NR == 13 {print $3}').monitor || {
        notify-send "NTS Controller" "Failed to get audio source"
        echo "Failed to get audio source" >&2
        return 1
    }

    # Identify song
    notify-send "NTS Controller" "Listening..."
    local current_song
    current_song=$(setsid -f songrec recognize -d "$current_default" 2>/dev/null) || {
        notify-send "NTS Controller" "Song recognition failed"
        echo "Songrec failed" >&2
        return 1
    }

    # save and notify results
    if [[ -n "$current_song" ]]; then
        echo "$current_song" >>"$HOME/.config/NTS Control/id-history.txt"
        notify-send "NTS Controller" "Identified:\n$current_song"
        echo "Successfully identified: $current_song"
    else
        notify-send "NTS Controller" "No song detected"
        echo "No song detected" >&2
        return 1
    fi
}

# handles passing the NTS radio stream link to mpv
pass_link_handler() {
    local stream_tit
    stream_tit=$(get_title "$selection") || return 1

    if ! setsid -f mpv \
        --title="$selection - NTS Controller - mpa" \
        --force-media-title="$stream_tit - $selection" \
        "${streams["$selection"]}"; then
        notify-send "NTS Controller" "Failed to open '$selection'"
        echo "Failed to open '$selection'" >&2
        return 1
    fi

    notify-send "NTS Controller" "Opening..." "'$selection'"
    echo "Opening '$selection'"
}

# kills current radio via simple pkill command
kill_radio() {
    if ! pkill -f "mpv --title=.* - NTS Controller.*"; then
        notify-send "NTS Controller" "Failed to kill current stream"
        echo "failed to kill '$selection'" >&2
        #else
        #notify-send "NTS Controller" "no active stream found"
    fi
    #notify-send "NTS Controller" "killed current stream"
    echo "killed current stream"

}

# main execution/hub for all functions and menus

# sort stream names numerically before displaying
sorted_streams=$(printf "%s\n" "${!streams[@]}" | sort -V)
selection=$(printf "%s\n" "$sorted_streams" "Kill session" "View details of current set" "View tracklist of current set" "ID current song" "View bookmarks" "View ID history" | rofi -dmenu -i -p "Select stream or option")

case "$selection" in
"NTS Radio 1")
    kill_radio 2>/dev/null # Silently kill any existing stream
    pass_link_handler
    ;;
"NTS Radio 2")
    kill_radio 2>/dev/null # Silently kill any existing stream
    pass_link_handler
    ;;
"Kill session")
    kill_radio
    ;;
"View tracklist of current set")
    show_tracklist
    ;;
"View details of current set")
    show_details
    ;;
"ID current song")
    id_song
    ;;
"View ID history")
    setsid -f kitty --class nvim -T nvim nvim "/home/drill/.config/NTS Control/id-history.txt"
    ;;
"View bookmarks")
    setsid -f kitty --class nvim -T nvim nvim "/home/drill/.config/NTS Control/episode-bookmarks.txt"
    ;;
*)
    echo "Selection cancelled"
    exit 0
    ;;
esac
