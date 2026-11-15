.pragma library

// Colors derived from the bar's foreground, shared by every view.

// Secondary text: labels, captions, hints. Same factor the shell's own
// section headers use.
function dim(color) {
  return Qt.darker(color, 1.4)
}

// The foreground at a given opacity, for tracks, fills and borders.
function tint(color, alpha) {
  return Qt.rgba(color.r, color.g, color.b, alpha)
}
