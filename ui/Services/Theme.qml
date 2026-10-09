pragma Singleton

import QtQuick
import Quickshell
import Quickshell.Io

// Material 3 palette from Clavis' matugen output, so Hermes follows the wallpaper.
Singleton {
    id: root

    readonly property string colorsPath: {
        const env = Quickshell.env("HERMES_COLORS");
        if (env)
            return env;
        const data = Quickshell.env("XDG_DATA_HOME") || (Quickshell.env("HOME") + "/.local/share");
        return data + "/clavis/profiles/" + (Quickshell.env("CLAVIS_PROFILE") || "default") + "/generated/clavis/colors.json";
    }

    property color background: "#111418"
    property color surface: "#111418"
    property color surfaceDim: "#111418"
    property color surfaceBright: "#37393e"
    property color surfaceContainerLowest: "#0b0e13"
    property color surfaceContainerLow: "#191c20"
    property color surfaceContainer: "#1d2024"
    property color surfaceContainerHigh: "#272a2f"
    property color surfaceContainerHighest: "#32353a"
    property color fgSurface: "#e1e2e8"
    property color fgSurfaceVariant: "#c3c6cf"
    property color outline: "#8d9199"
    property color outlineVariant: "#43474e"
    property color primary: "#a1cafd"
    property color fgPrimary: "#003259"
    property color primaryContainer: "#1a4975"
    property color fgPrimaryContainer: "#d2e4ff"
    property color secondary: "#bbc7db"
    property color fgSecondary: "#253140"
    property color secondaryContainer: "#3c4858"
    property color fgSecondaryContainer: "#d7e3f8"
    property color tertiary: "#d7bee4"
    property color fgTertiary: "#3b2947"
    property color tertiaryContainer: "#533f5f"
    property color fgTertiaryContainer: "#f3daff"
    property color error: "#ffb4ab"
    property color fgError: "#690005"
    property color errorContainer: "#93000a"
    property color fgErrorContainer: "#ffdad6"
    property color scrim: "#000000"
    property color inverseSurface: "#e1e2e8"
    property color inverseOnSurface: "#2e3135"
    property color inversePrimary: "#37618e"
    property bool dark: true

    // Typography: Clavis bundles Google Sans Flex; fall back gracefully.
    readonly property string font: fontLoader.status === FontLoader.Ready ? fontLoader.name : "sans-serif"
    readonly property string iconFont: "Material Symbols Rounded"
    readonly property string monoFont: "JetBrainsMono Nerd Font"

    readonly property int radiusSm: 8
    readonly property int radiusMd: 14
    readonly property int radiusLg: 22
    readonly property int radiusXl: 28

    readonly property int durFast: 140
    readonly property int durMed: 240
    readonly property var emphasized: [0.05, 0.7, 0.1, 1, 1, 1]

    // Stable per-person accent for group sender names.
    readonly property var nameColors: dark
        ? ["#ffb4a9", "#ffb870", "#e9c46a", "#a8d672", "#6fd8b4", "#7cd0ff", "#a6b4ff", "#d8a6ff", "#ff9fcf", "#8ee3e3"]
        : ["#b3261e", "#9a5a00", "#7c6400", "#3d6b00", "#00695c", "#00639b", "#3f51b5", "#7b3fa0", "#a8327a", "#00696b"]
    function nameColor(key) {
        let h = 0;
        for (let i = 0; i < key.length; i++)
            h = (h * 31 + key.charCodeAt(i)) >>> 0;
        return nameColors[h % nameColors.length];
    }

    function alpha(c, a) {
        return Qt.rgba(c.r, c.g, c.b, a);
    }
    function mix(a, b, t) {
        return Qt.rgba(a.r * (1 - t) + b.r * t, a.g * (1 - t) + b.g * t, a.b * (1 - t) + b.b * t, 1);
    }

    // matugen key -> property name; "on_surface" becomes fgSurface because QML
    // treats any property named onX as a signal handler.
    function camel(key) {
        const c = key.replace(/_([a-z])/g, (m, ch) => ch.toUpperCase());
        return /^on[A-Z]/.test(c) ? "fg" + c.slice(2) : c;
    }

    function apply(text) {
        let data;
        try {
            data = JSON.parse(text);
        } catch (e) {
            return;
        }
        for (const key in data) {
            const prop = camel(key);
            if (root.hasOwnProperty(prop) && typeof data[key] === "string")
                root[prop] = data[key];
        }
        const bg = Qt.color(root.background);
        root.dark = (0.299 * bg.r + 0.587 * bg.g + 0.114 * bg.b) < 0.5;
    }

    FontLoader {
        id: fontLoader
        source: "file://" + (Quickshell.env("HOME") + "/.local/share/clavis-shell/assets/fonts/google-sans-flex/GoogleSansFlex-VariableFont_GRAD,ROND,opsz,slnt,wdth,wght.ttf")
    }

    FileView {
        path: root.colorsPath
        watchChanges: true
        onFileChanged: reload()
        onLoaded: root.apply(text())
    }
}
