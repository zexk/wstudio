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
    default_tempo = rangedNumber 20 999 "Tempo of new projects, in BPM.";
    default_sample_rate = rangedInt 8000 192000 "Sample rate of new projects, in Hz.";
    default_beats_per_bar = rangedInt 1 16 "Beats per bar of new projects.";
    default_octave = rangedInt 0 8 "Starting octave for the QWERTY piano layout.";
    default_velocity = rangedNumber 0 1 "Velocity for keyboard and step-recorded notes.";
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
          "umbra"
        ]
      );
      default = null;
      description = "TUI terminal-palette theme.";
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
          "umbra"
        ]
      );
      default = null;
      description = "GUI color theme.";
    };
    gui_window_width = rangedInt 960 7680 "Initial GUI window width in pixels.";
    gui_window_height = rangedInt 600 4320 "Initial GUI window height in pixels.";
  };
}
