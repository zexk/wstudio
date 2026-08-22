const ws = @import("wstudio");
const App = @import("../app.zig").App;

pub fn handleKey(app: *App, key: ws.input.Key) bool {
    const clips = if (app.audio_track < app.session.arrangement.lanes.items.len)
        app.session.arrangement.lanes.items[app.audio_track].clips.items
    else
        &.{};
    switch (key) {
        .escape, .tab => {
            app.view = .tracks;
            return true;
        },
        .char => |c| switch (c) {
            'j' => {
                if (clips.len > 0) app.audio_clip = @min(app.audio_clip +| @as(usize, @intCast(app.takeCount())), clips.len - 1);
                return true;
            },
            'k' => {
                app.audio_clip -|= @as(usize, @intCast(app.takeCount()));
                return true;
            },
            'a' => {
                app.cursor = app.audio_track;
                app.view = .arrangement;
                app.autoSongMode(true);
                return true;
            },
            'i' => {
                app.openBrowser(.import_audio);
                return true;
            },
            'r' => {
                app.doTrackArmToggle(app.audio_track);
                return true;
            },
            '-' => {
                app.doTrackGainStep(app.audio_track, -1.0);
                return true;
            },
            '+', '=' => {
                app.doTrackGainStep(app.audio_track, 1.0);
                return true;
            },
            '<' => {
                app.doTrackPan(app.audio_track, -0.05);
                return true;
            },
            '>' => {
                app.doTrackPan(app.audio_track, 0.05);
                return true;
            },
            else => {},
        },
        else => {},
    }
    return false;
}
