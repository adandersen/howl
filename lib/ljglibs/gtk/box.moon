-- Copyright 2014 Nils Nordman <nino at nordman.org>
-- License: MIT (see LICENSE)

ffi = require 'ffi'
require 'ljglibs.cdefs.gtk'
core = require 'ljglibs.core'
gobject = require 'ljglibs.gobject'
require 'ljglibs.gtk.container'

gc_ptr = gobject.gc_ptr
C = ffi.C

core.define 'GtkBox < GtkContainer', {
  properties: {
    homogeneous: 'gboolean'
    spacing: 'gint'
  }

  child_properties: {
    expand: 'gboolean'
    fill: 'gboolean'
    pack_type: 'GtkPackType'
    padding: 'guint'
    position: 'gint'
  }

  new: (orientation = C.GTK_ORIENTATION_HORIZONTAL, spacing = 0) ->
    gc_ptr C.gtk_box_new orientation, spacing

  pack_start: (child, expand, fill, padding) =>
    C.gtk_box_pack_start @, child, expand, fill, padding

  pack_end: (child, expand, fill, padding) =>
    C.gtk_box_pack_end @, child, expand, fill, padding

}, (spec, ...) -> spec.new ...