# mic module: finding the capture devices.

test_capture_nodes_come_from_proc_asound() {
    printf '%s\n' '00-00: PCM : PCM : playback 1' '00-11: MIC : MIC : capture 1' >"$T_TMP/pcm"
    load_module mic
    nodes=$(OYG_PROC_ASOUND_PCM="$T_TMP/pcm" OYG_TMPDIR="$T_TMP" mod_mic_list_capture_nodes)
    assert_eq "$nodes" "/dev/snd/pcmC0D11c"
}

test_listing_capture_nodes_leaves_no_files() {
    printf '%s\n' '00-11: MIC : MIC : capture 1' >"$T_TMP/pcm"
    mkdir "$T_TMP/scratch"
    load_module mic
    OYG_PROC_ASOUND_PCM="$T_TMP/pcm" OYG_TMPDIR="$T_TMP/scratch" mod_mic_list_capture_nodes >/dev/null
    assert_eq "$(ls -A "$T_TMP/scratch")" ""
}

# The 43UM7300 (webOS 4): eight playback devices, no capture device. Its only
# microphone is in the Magic Remote, which the voice module covers.
_playback_only() {
    [ -d /dev/snd ] && skip "this machine has real sound devices"
    printf '00-%02d: Mars PCM : Mars PCM : playback 8\n' 0 1 2 3 4 5 6 7 >"$T_TMP/pcm"
    OYG_PROC_ASOUND_PCM=$T_TMP/pcm
    export OYG_PROC_ASOUND_PCM
    stub id 'echo 0'
    stub mount
    load_module mic
}

test_a_tv_without_capture_devices_has_no_mic_to_mute() {
    _playback_only
    assert_eq "$(mod_mic_list_capture_nodes)" ""
}

test_harden_without_capture_devices_mutes_nothing() {
    _playback_only
    out=$(mod_mic_harden 2>&1)
    assert_contains "$out" "no built-in microphone"
    assert_not_contains "$(calls)" "mount"
}

test_status_without_capture_devices_says_so() {
    _playback_only
    assert_contains "$(mod_mic_status 2>&1)" "N/A      mic: no built-in microphone"
}

test_with_nothing_to_scan_the_known_list_is_used() {
    [ -d /dev/snd ] && skip "this machine has real sound devices"
    OYG_PROC_ASOUND_PCM=$T_TMP/none
    export OYG_PROC_ASOUND_PCM
    load_module mic
    [ -r /proc/asound/pcm ] && skip "this machine has /proc/asound/pcm"
    assert_contains "$(mod_mic_list_capture_nodes)" "/dev/snd/pcmC0D11c"
}
