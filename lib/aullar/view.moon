-- Copyright 2014 Nils Nordman <nino at nordman.org>
-- License: MIT (see LICENSE)

ffi = require 'ffi'
bit = require 'bit'
ffi_cast = ffi.cast

Gdk = require 'ljglibs.gdk'
Gtk = require 'ljglibs.gtk'
require 'ljglibs.cairo.cairo'
DisplayLines = require 'aullar.display_lines'
Cursor = require 'aullar.cursor'
Selection = require 'aullar.selection'
Buffer = require 'aullar.buffer'
LineGutter = require 'aullar.line_gutter'
CurrentLineMarker = require 'aullar.current_line_marker'

{:define_class} = require 'aullar.util'
{:parse_key_event} = require 'ljglibs.util'
{:max, :min, :abs} = math

insertable_character = (event) ->
  return false if event.ctrl or event.alt or event.meta or event.super or not event.character
  true

contains_newlines = (s) ->
  s\find('[\n\r]') != nil

notify = (view, event, ...) ->
  listener = view.listener
  if listener and listener[event]
    handled = listener[event] view, ...
    return true if handled == true

  false

signals = {
  on_draw: (_, cr, view) -> view._draw view, cr

  on_focus_in: (_, _, view) ->
    view._on_focus_in view
    notify view, 'on_focus_in'

  on_focus_out: (_, _, view) ->
    view._on_focus_out view
    notify view, 'on_focus_out'

  on_screen_changed: (_, _, view) -> view._on_screen_changed view
  on_size_allocate: (_, allocation, view) ->
    view._on_size_allocate view, ffi_cast('GdkRectangle *', allocation)
  on_button_press: (_, event, view) ->
    view._on_button_press view, ffi_cast('GdkEventButton *', event)
  on_button_release: (_, event, view) ->
    view._on_button_release view, ffi_cast('GdkEventButton *', event)
  on_motion_event: (_, event, view) ->
    view._on_motion_event view, ffi_cast('GdkEventMotion *', event)
  on_scroll_event: (_, event, view) ->
    view._on_scroll view, ffi_cast('GdkEventScroll *', event)

  on_key_press: (_, event, view) ->
    event = parse_key_event event
    return if notify view, 'on_key_press', event

    if insertable_character(event)
      view\insert event.character
}

View = {
  new: (buffer = Buffer('')) =>
    @margin = 3
    @_base_x = 0

    @_first_visible_line = 1
    @_last_visible_line = nil

    @area = Gtk.DrawingArea!
    @selection = Selection @
    @cursor = Cursor @, @selection
    @line_gutter = LineGutter @
    @current_line_marker = CurrentLineMarker @

    with @area
      .can_focus = true
      \add_events bit.bor(Gdk.KEY_PRESS_MASK, Gdk.BUTTON_PRESS_MASK, Gdk.BUTTON_RELEASE_MASK, Gdk.POINTER_MOTION_MASK, Gdk.SCROLL_MASK)
      \on_key_press_event signals.on_key_press, @
      \on_button_press_event signals.on_button_press, @
      \on_button_release_event signals.on_button_release, @
      \on_motion_notify_event signals.on_motion_event, @
      \on_scroll_event signals.on_scroll_event, @
      \on_draw signals.on_draw, @
      \on_screen_changed signals.on_screen_changed, @
      \on_size_allocate signals.on_size_allocate, @
      \on_focus_in_event signals.on_focus_in, @
      \on_focus_out_event signals.on_focus_out, @

    @horizontal_scrollbar = Gtk.Scrollbar Gtk.ORIENTATION_HORIZONTAL
    @horizontal_scrollbar.adjustment\on_value_changed (adjustment) ->
      return if @_updating_scrolling
      @base_x = adjustment.value
      @area\queue_draw!

    @horizontal_scrollbar_alignment = Gtk.Alignment {
      left_padding: @line_gutter.width,
      @horizontal_scrollbar
    }

    @vertical_scrollbar = Gtk.Scrollbar Gtk.ORIENTATION_VERTICAL
    @vertical_scrollbar.adjustment\on_value_changed (adjustment) ->
      return if @_updating_scrolling
      line = math.floor adjustment.value + 0.5
      @scroll_to line

    @bin = Gtk.Box Gtk.ORIENTATION_HORIZONTAL, {
      {
        expand: true,
        Gtk.Box(Gtk.ORIENTATION_VERTICAL, {
          { expand: true, @area },
          @horizontal_scrollbar_alignment
        })
      },
      @vertical_scrollbar
    }

    @_buffer_listener = {
      on_inserted: (_, b, args) -> @\_on_buffer_modified b, args
      on_deleted: (_, b, args) -> @\_on_buffer_modified b, args
      on_styled: (_, b, args) -> @\_on_buffer_styled b, args
      last_line_shown: (_, b) -> @last_visible_line
    }

    @buffer = buffer

  properties: {

    showing: => @height != nil

    first_visible_line: {
      get: => @_first_visible_line
      set: (line) => @scroll_to line
    }

    last_visible_line: {
      get: =>
        unless @_last_visible_line
          return 0 unless @height
          error "Can't determine last visible line until shown", 2 unless @height
          @_last_visible_line = 1

          y = @margin
          for line in @_buffer\lines @_first_visible_line
            d_line = @display_lines[line.nr]
            break if y + d_line.height > @height
            @_last_visible_line = line.nr
            y += d_line.height

        @_last_visible_line

      set: (line) =>
        -- todo: variable height lines
        @first_visible_line = (line - @lines_showing) + 1
        @_last_visible_line = line
    }

    lines_showing: =>
      @last_visible_line - @first_visible_line + 1

    base_x: {
      get: => @_base_x
      set: (x) =>
        if x < 0
          x = 0
        else
          adjustment = @horizontal_scrollbar.adjustment
          x = min x, adjustment.upper - adjustment.page_size

        return if x == @_base_x
        @_base_x = x
        @area\queue_draw!
        @_sync_scrollbars horizontal: true
    }

    edit_area_x: => @line_gutter.width + @margin
    edit_area_width: => @width - @edit_area_x

    buffer: {
      get: => @_buffer
      set: (buffer) =>
        @_buffer\remove_listener(@) if @_buffer
        @_buffer = buffer
        buffer\add_listener @_buffer_listener

        @_first_visible_line = 1
        @_base_x = 0
        @_reset_display!
        @area\queue_draw!
    }
  }

  grab_focus: => @area\grab_focus!

  scroll_to: (line) =>
    return if line < 1 or not @showing
    line = min line, (@buffer.nr_lines - @lines_showing) + 1
    return if @first_visible_line == line

    @_first_visible_line = line
    @_last_visible_line = nil
    @_sync_scrollbars!
    @buffer\ensure_styled_to @last_visible_line + 1
    @area\queue_draw!

  _sync_scrollbars: (opts = { horizontal: true, vertical: true })=>
    @_updating_scrolling = true

    if opts.vertical
      page_size = @lines_showing - 1
      adjustment = @vertical_scrollbar.adjustment
      adjustment\configure @first_visible_line, 1, @buffer.nr_lines, 1, page_size, page_size

    if opts.horizontal
      max_width = 0
      for i = @first_visible_line, @last_visible_line
        max_width = max max_width, @display_lines[i].width

      if max_width <= @edit_area_width
        @horizontal_scrollbar\hide!
      else
        adjustment = @horizontal_scrollbar.adjustment
        adjustment\configure @base_x, 1, max_width - (@margin / 2), 10, @edit_area_width, @edit_area_width
        @horizontal_scrollbar\show!

    @_updating_scrolling = false

  insert: (text) =>
    @_buffer\insert @cursor.pos, text
    @cursor.pos += #text

  delete_back: =>
    cur_line = @cursor.line
    cur_pos = @cursor.pos
    @cursor\backward!
    size = cur_pos - @cursor.pos
    @_buffer\delete(@cursor.pos, size) if size > 0

  to_gobject: => @bin

  refresh_display: (from_offset = 0, to_offset, opts = {}) =>
    return unless @width
    d_lines = @display_lines
    min_y, max_y = nil, nil
    y = @margin
    last_valid = 0

    for line_nr = @_first_visible_line, @last_visible_line + 1
      line = @_buffer\get_line line_nr
      break unless line
      after = to_offset and line.start_offset > to_offset
      break if after
      before = line.end_offset < from_offset and line.has_eol
      d_line = d_lines[line_nr]

      if not(before or after) or (after and not to_offset)
        d_lines[line.nr] = nil if opts.invalidate
        min_y or= y
        max_y = y + d_line.height
      else
        last_valid = max last_valid, line.nr

      y += d_line.height

    if opts.invalidate and not to_offset
      max_y = @height
      for line_nr = last_valid + 1, d_lines.max
        d_lines[line_nr] = nil

      @_last_visible_line = nil
      @display_lines.max = last_valid

    if min_y
      start_x = opts.gutter and 0 or @line_gutter.width + 1
      width = @width - start_x
      height = (max_y - min_y) + 1
      if width > 0
        @area\queue_draw_area start_x, min_y, width, height

  position_from_coordinates: (x, y) =>
    return unless @width
    cur_y = @margin

    for line_nr = @_first_visible_line, @last_visible_line + 1
      d_line = @display_lines[line_nr]
      return nil unless d_line
      end_y = cur_y + d_line.height
      if (y >= cur_y and y <= end_y)
        pango_x = (x - @edit_area_x + @base_x) * 1024
        inside, index = d_line.layout\xy_to_index pango_x, 1
        if not inside
          index += 1 if index > 0 -- move to the ending new line
        else
          -- are we aiming for the next grapheme?
          rect = d_line.layout\index_to_pos index
          if pango_x - rect.x > rect.width * 0.7
            index = d_line.layout\move_cursor_visually true, index, 0, 1

        return @_buffer\get_line(line_nr).start_offset + index

      cur_y = end_y

    nil

  _draw: (cr) =>
    p_ctx = @area.pango_context
    cursor_pos = @cursor.pos - 1
    clip = cr.clip_extents

    @line_gutter\start_draw cr, p_ctx, clip

    edit_area_x, y = @edit_area_x, @margin
    cr\move_to edit_area_x, y
    cr\set_source_rgb 0, 0, 0

    lines = {}
    start_y = nil

    for line in @_buffer\lines @_first_visible_line
      d_line = @display_lines[line.nr]

      if y + d_line.height > clip.y1
        d_line.block -- force evaluation of any block
        lines[#lines + 1] = :line, display_line: d_line
        start_y or= y

      y += d_line.height
      break if y >= clip.y2

    current_line = @cursor.line
    y = start_y

    for line_info in *lines
      {:display_line, :line} = line_info

      if line.nr == current_line
        @current_line_marker\draw_before edit_area_x, y, display_line, cr, clip

      if @selection\affects_line line
        @selection\draw edit_area_x, y, cr, display_line, line

      display_line\draw edit_area_x, y, cr, clip

      if @selection\affects_line line
        @selection\draw_overlay edit_area_x, y, cr, display_line, line

      @line_gutter\draw_for_line line.nr, 0, y, display_line

      if line.nr == current_line
        @current_line_marker\draw_after edit_area_x, y, display_line, cr, clip
        @cursor\draw edit_area_x, y, cr, display_line

      y += display_line.height
      cr\move_to edit_area_x, y

    @line_gutter\end_draw!

  _reset_display: =>
    @_last_visible_line = nil
    @display_lines = DisplayLines @, @buffer, @area.pango_context

  _on_buffer_styled: (buffer, args) =>
    return unless @showing
    last_line = buffer\get_line @last_visible_line
    return if args.start_line > last_line.nr + 1 and last_line.has_eol
    start_line = @buffer\get_line args.start_line

    prev_block = @display_lines[start_line.nr].block
    prev_block_width = prev_block and prev_block.width

    changed_block = ->
      new_block = @display_lines[start_line.nr].block
      return new_block if new_block and not prev_block
      return prev_block if prev_block and not new_block
      if prev_block and prev_block_width != new_block.width
        prev_block

    if not args.invalidated and args.start_line == args.end_line
      -- refresh only the single line, but verify that the modification does not
      -- have other significant percussions
      prev_height = @display_lines[start_line.nr].height

      @refresh_display start_line.start_offset, start_line.end_offset, invalidate: true

      d_line = @display_lines[start_line.nr]
      if d_line.height == prev_height -- height remains the same
        block = changed_block! -- but might still need to adjust for block changes
        if block
          @refresh_display block.start_line.start_offset, block.end_line.end_offset

        @_sync_scrollbars horizontal: true
        return

    @refresh_display start_line.start_offset, nil, invalidate: true, gutter: true
    block = changed_block! -- but might still need to adjust for block changes
    if block
      @refresh_display block.start_line.start_offset, start_line.start_offset, invalidate: true

    @_sync_scrollbars!

  _on_buffer_modified: (buffer, args) =>
    return unless @showing

    if args.styled
      @_on_buffer_styled buffer, args.styled
    else
      if not contains_newlines(args.text)
        @refresh_display args.offset, args.offset + args.size, invalidate: true
        @_sync_scrollbars horizontal: true
      else
        @refresh_display args.offset, nil, invalidate: true, gutter: true
        @_sync_scrollbars!

  _on_focus_in: =>
    @cursor.active = true

  _on_focus_out: =>
    @cursor.active = false

  _on_screen_changed: =>
    @_reset_display!

  _on_button_press: (event) =>
    return if event.x <= @line_gutter.width
    return if event.button != 1

    extend = bit.band(event.state, Gdk.SHIFT_MASK) != 0

    pos = @position_from_coordinates(event.x, event.y)
    if pos
      @area\grab_focus! unless @area.has_focus
      @cursor\move_to :pos, :extend
      @_selection_active = true

  _on_button_release: (event) =>
    return if event.button != 1
    @_selection_active = false

  _on_motion_event: (event) =>
    return unless @_selection_active
    pos = @position_from_coordinates(event.x, event.y)
    if pos
      @cursor\move_to :pos, extend: true
    elseif event.y < 0
      @cursor\up extend: true
    else
      @cursor\down extend: true

  _on_scroll: (event) =>
    if event.direction == Gdk.SCROLL_UP
      @scroll_to @first_visible_line - 1
    elseif event.direction == Gdk.SCROLL_DOWN
      @scroll_to @first_visible_line + 1
    elseif event.direction == Gdk.SCROLL_RIGHT
      @base_x += 20
    elseif event.direction == Gdk.SCROLL_LEFT
      @base_x -= 20

  _on_size_allocate: (allocation) =>
    @width = allocation.width
    @height = allocation.height
    @_reset_display!
    @_sync_scrollbars!
    @buffer\ensure_styled_to @last_visible_line + 1
}

define_class View