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
