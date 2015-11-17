-- Copyright 2015 The Howl Developers
-- License: MIT (see LICENSE.md at the top-level directory of the distribution)

{:janitor, :config, :app} = howl
{:time} = os

cleanup_min_buffers_open = config.cleanup_min_buffers_open
cleanup_close_buffers_after = config.cleanup_close_buffers_after

close_buffers = ->
  for b in *app.buffers
    app\close_buffer b, true

describe 'janitor', ->
  before_each -> close_buffers!

  after_each ->
    config.cleanup_min_buffers_open = cleanup_min_buffers_open
    config.cleanup_close_buffers_after = cleanup_close_buffers_after
    close_buffers!

  describe 'clean_up_buffers', ->
    it 'never closes modified buffers', ->
      config.cleanup_min_buffers_open = 0
      config.cleanup_close_buffers_after = 0
      b = app\new_buffer!
      b.last_shown = time! - 60
      b.modified = true
      janitor.clean_up_buffers!
      assert.equals 1, #app.buffers

    it 'does not leave less than <cleanup_min_buffers_open> buffers', ->
      config.cleanup_min_buffers_open = 2
      config.cleanup_close_buffers_after = 0
      for i = 1, 2
        b = app\new_buffer!
        b.last_shown = time! - 60

      janitor.clean_up_buffers!
      assert.equals 2, #app.buffers

    context 'with more buffers than we want', ->
      local now

      before_each -> now = time!

      it 'closes buffers who has not been shown recently enough', ->
        for i = 1, 2
          b = app\new_buffer!
          b.title = 'keep'
          b.last_shown = now

        for i = 1, 2
          b = app\new_buffer!
          b.last_shown = now - 80

        config.cleanup_min_buffers_open = 2
        config.cleanup_close_buffers_after = 1
        janitor.clean_up_buffers!

        assert.equals 2, #app.buffers

        for b in *app.buffers
          assert.match b.title, 'keep'

      it 'closes buffers in a least-recently-shown order', ->
        b = app\new_buffer!
        b.title = 'hour-old'
        b.last_shown = now - 60 * 60

        b = app\new_buffer!
        b.title = '15-min-old'
        b.last_shown = now - 60 * 15

        b = app\new_buffer!
        b.title = '30-min-old'
        b.last_shown = now - 60 * 30

        config.cleanup_min_buffers_open = 1
        config.cleanup_close_buffers_after = 10
        janitor.clean_up_buffers!

        assert.same {'15-min-old'}, [b.title for b in *app.buffers]
