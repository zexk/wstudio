{ lib }:
let
  inherit (lib) mkOption types;
  rangedNumber =
    min: max: description:
    mkOption {
      type = types.nullOr (types.numbers.between min max);
      default = null;
      inherit description;
    };
  rangedInt =
    min: max: description:
    mkOption {
      type = types.nullOr (types.ints.between min max);
      default = null;
      inherit description;
    };
in
{
  options = {
    preferred_frontend = mkOption {
      type = types.nullOr (
        types.enum [
          "tui"
          "gui"
        ]
      );
      default = null;
      description = "Frontend a flagless `wstudio` launch runs. --tui/--gui always win.";
    };
    default_tempo = rangedNumber 20 400 "Tempo of new projects, in BPM.";
    default_sample_rate = rangedInt 8000 192000 "Sample rate of new projects, in Hz.";
    default_beats_per_bar = rangedInt 1 16 "Beats per bar of new projects.";
    default_octave = rangedInt 0 8 "Starting octave for the QWERTY piano layout.";
    default_velocity = rangedNumber 0 1 "Velocity for keyboard and step-recorded notes.";
    default_master_gain_db = rangedNumber (-40) 6 "Master output gain at session startup, in dB.";
    autosave_interval_s = rangedInt 0 600 "Autosave interval in seconds. Zero disables autosave.";
    frame_poll_ms = rangedInt 5 1000 "TUI input poll interval in milliseconds.";
    audio_block_frames = rangedInt 16 4096 "Audio buffer size in frames.";
    audio_backend = mkOption {
      type = types.nullOr (
        types.enum [
          "auto"
          "pipewire"
          "jack"
          "alsa"
          "none"
        ]
      );
      default = null;
      description = "Audio backend. auto tries PipeWire, then JACK, then ALSA, then silence.";
    };
    audio_output_device = mkOption {
      type = types.nullOr types.str;
      default = null;
      description = "Backend-native playback device ID. Empty uses the system default.";
    };
    audio_input_device = mkOption {
      type = types.nullOr types.str;
      default = null;
      description = "Backend-native capture device ID. Empty uses the system default.";
    };
    midi_input_device = mkOption {
      type = types.nullOr types.str;
      default = null;
      description = "Backend-native live MIDI input source.";
    };
    tap_timeout_ms = rangedInt 100 10000 "Multi-key timeout in milliseconds.";
    note_preview_ms = rangedInt 20 2000 "Audition note release delay in milliseconds.";
    cmd_history_lines = rangedInt 10 500 "Maximum number of command history entries.";
    status_message_ms = rangedInt 200 10000 "Status message lifetime in milliseconds.";
    default_browse_dir = mkOption {
      type = types.nullOr types.str;
      default = null;
      description = "Initial file-browser directory when no project path is known.";
    };
    default_project_path = mkOption {
      type = types.nullOr (types.strMatching ".+");
      default = null;
      description = "Fallback project filename for saving and autosave.";
    };
    file_browser_show_hidden = mkOption {
      type = types.nullOr types.bool;
      default = null;
      description = "Whether the file browser includes dotfiles and dot-directories.";
    };
    default_drum_grid = mkOption {
      type = types.nullOr (
        types.enum [
          "quarter"
          "eighth"
          "sixteenth"
          "thirty_second"
          "sixty_fourth"
          "one_twenty_eighth"
        ]
      );
      default = null;
      description = "Initial drum grid division.";
    };
    default_piano_grid = mkOption {
      type = types.nullOr (
        types.enum [
          "quarter"
          "eighth"
          "sixteenth"
          "thirty_second"
          "sixty_fourth"
          "one_twenty_eighth"
        ]
      );
      default = null;
      description = "Initial piano-roll grid division.";
    };
    default_piano_triplet_grid = mkOption {
      type = types.nullOr types.bool;
      default = null;
      description = "Whether the piano roll starts on its triplet grid.";
    };
    default_piano_note_length_steps = rangedInt 1 16 "Initial piano-roll note length in grid steps.";
    default_piano_pitch = rangedInt 0 127 "Initial piano-roll cursor pitch as a MIDI note number.";
    default_arrangement_grid = mkOption {
      type = types.nullOr (
        types.enum [
          "quarter"
          "eighth"
          "sixteenth"
          "thirty_second"
          "sixty_fourth"
          "one_twenty_eighth"
        ]
      );
      default = null;
      description = "Initial arrangement grid division.";
    };
    piano_ghost_notes = mkOption {
      type = types.nullOr types.bool;
      default = null;
      description = "Whether the piano roll initially shows notes from other tracks.";
    };
    piano_audition = mkOption {
      type = types.nullOr types.bool;
      default = null;
      description = "Whether moving the piano-roll cursor auditions the pitch under it.";
    };
    tui_mouse = mkOption {
      type = types.nullOr types.bool;
      default = null;
      description = "Whether the TUI captures mouse input.";
    };
    tui_theme = mkOption {
      type = types.nullOr (
        types.enum [
          "none"
          "patina"
          "patina_light"
          "graphite"
          "graphite_light"
          "umbra"
          "catppuccin_mocha"
          "catppuccin_latte"
          "dracula"
          "gruvbox_dark"
          "gruvbox_light"
          "nord"
          "solarized_dark"
          "solarized_light"
          "tokyonight"
        ]
      );
      default = null;
      description = "TUI terminal-palette theme.";
    };
    has_nerdfonts = mkOption {
      type = types.nullOr types.bool;
      default = null;
      description = "Whether the terminal renders Nerd Font glyphs. False falls back to plain ascii.";
    };
    gui_font_size = rangedNumber 8 40 "GUI font size in pixels.";
    gui_vsync = mkOption {
      type = types.nullOr types.bool;
      default = null;
      description = "Whether vertical sync is enabled in the GUI.";
    };
    gui_theme = mkOption {
      type = types.nullOr (
        types.enum [
          "patina"
          "patina_light"
          "graphite"
          "graphite_light"
          "umbra"
          "catppuccin_mocha"
          "catppuccin_latte"
          "dracula"
          "gruvbox_dark"
          "gruvbox_light"
          "nord"
          "solarized_dark"
          "solarized_light"
          "tokyonight"
        ]
      );
      default = null;
      description = "GUI color theme.";
    };
    gui_panel_border = mkOption {
      type = types.nullOr (
        types.enum [
          "square"
          "rounded"
        ]
      );
      default = null;
      description = "GUI panel/window corner style.";
    };
    gui_window_width = rangedInt 960 7680 "Initial GUI window width in pixels.";
    gui_window_height = rangedInt 600 4320 "Initial GUI window height in pixels.";
    clap_plugin_path = mkOption {
      type = types.nullOr types.str;
      default = null;
      description = "Extra CLAP plugin search directory. Empty uses the platform default search paths.";
    };
    vst3_plugin_path = mkOption {
      type = types.nullOr types.str;
      default = null;
      description = "Extra VST3 plugin search directory. Empty uses the platform default search paths.";
    };
    sandbox_plugins = mkOption {
      type = types.nullOr types.bool;
      default = null;
      description = "Run hosted CLAP/VST3 plugins in a sandboxed child process (Linux only) so a crashing or hanging plugin can't take the whole DAW down with it.";
    };
    undo_history_entries =
      rangedInt 8 512
        "Entries kept on the undo stack before the oldest start dropping off.";
    default_metronome_enabled = mkOption {
      type = types.nullOr types.bool;
      default = null;
      description = "Start every session with the click track on.";
    };
    default_song_mode = mkOption {
      type = types.nullOr types.bool;
      default = null;
      description = "Start sessions in arrangement song mode instead of pattern mode.";
    };
    metronome_click_gain =
      rangedNumber 0 1
        "Click track loudness, a multiplier on its built-in accent/regular ratio.";
    count_in_bars = rangedInt 0 4 "Count-in bars before recording starts. Zero skips the count-in.";
    default_midi_velocity_curve = mkOption {
      type = types.nullOr (
        types.enum [
          "linear"
          "exponential"
          "fixed"
        ]
      );
      default = null;
      description = "How raw MIDI/keyboard velocity maps to note gain.";
    };
    default_automation_gain_step_db =
      rangedNumber 0 12
        "j/k nudge size for gain breakpoints in the automation editor, in dB.";
    default_automation_pan_step =
      rangedNumber 0 1
        "j/k nudge size for pan breakpoints in the automation editor.";
    gui_knob_drag_pixels =
      rangedNumber 40 600
        "Vertical drag distance for a knob's full range, in pixels. Lower = more sensitive.";
    gui_envelope_drag_pixels =
      rangedNumber 40 600
        "Vertical drag distance for an envelope node's full range, in pixels. Lower = more sensitive.";
    gui_meter_decay_db_s =
      rangedNumber 1 200
        "Master-meter peak-hold fall rate, in dB/s. Higher = the hold indicator drops faster.";
    bounce_tail_seconds =
      rangedNumber 0 30
        "Silence appended past the content by :bounce, so reverb and release ring out.";
    bounce_bit_depth = mkOption {
      type = types.nullOr (
        types.enum [
          "pcm16"
          "pcm24"
        ]
      );
      default = null;
      description = "Bit depth :bounce writes when no 16/24 argument is given.";
    };
    default_bounce_path = mkOption {
      type = types.nullOr (types.strMatching ".+");
      default = null;
      description = "File a pathless :bounce writes to.";
    };
    default_stems_dir = mkOption {
      type = types.nullOr (types.strMatching ".+");
      default = null;
      description = "Directory a pathless :bounce-stems writes into.";
    };
    master_limiter_ceiling_db = rangedNumber (
      -12
    ) 0 "Output ceiling of the always-on master limiter, in dBFS.";
    master_limiter_release_ms =
      rangedNumber 1 1000
        "Gain-recovery time of the master limiter after a reduction, in milliseconds.";
    default_drum_steps = rangedInt 1 256 "Steps a freshly created drum machine starts with.";
    default_slicer_steps = rangedInt 1 64 "Steps a freshly created slicer starts with.";
    default_pattern_length_beats =
      rangedNumber 1 64
        "Loop length of a new piano-roll pattern, in beats.";
    default_swing = rangedNumber 50 75 "Swing percent a new instrument starts at. 50 is straight.";
    completion_popup_rows = rangedInt 1 20 "Rows the `:` Tab-completion popup may occupy.";
    waveform_low_hz = rangedNumber 20 2000 "Low/mid split point of the waveform band tint, in Hz.";
    waveform_high_hz = rangedNumber 1000 16000 "Mid/high split point of the waveform band tint, in Hz.";
    tui_piano_cell_width = rangedInt 1 7 "Terminal columns per piano-roll step.";
    tui_drum_cell_width = rangedInt 1 7 "Terminal columns per drum-grid step.";
    tui_arrangement_cell_width = rangedInt 2 12 "Terminal columns per arrangement bar.";
    tui_spectrum_db_range = rangedNumber 20 120 "dB span the TUI spectrum analyser draws.";
    gui_piano_row_height =
      rangedNumber 8 48
        "Pixel height of one piano-roll key row. The GUI's vertical zoom.";
  };
}
