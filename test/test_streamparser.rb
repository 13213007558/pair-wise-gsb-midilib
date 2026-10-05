require 'test/unit'
require_relative '../lib/midilib'

class StreamParserTester < Test::Unit::TestCase
  # Feeds a list of short chunks through one parser and returns every
  # emitted event in order.
  def feed_chunks(chunks, max_sysex_bytes: MIDI::IO::StreamParser::DEFAULT_MAX_SYSEX_BYTES)
    parser = MIDI::IO::StreamParser.new(max_sysex_bytes: max_sysex_bytes)
    events = chunks.flat_map { |chunk| parser.feed(chunk) }
    events.concat(parser.finish)
    events
  end

  def assert_note_on(event, channel, note, velocity)
    assert_instance_of(MIDI::NoteOn, event)
    assert_equal(channel, event.channel)
    assert_equal(note, event.note)
    assert_equal(velocity, event.velocity)
  end

  # The headline acceptance case: more than a dozen tiny segments,
  # containing repeated running-status NoteOn messages, a Clock byte
  # wedged between the two data bytes of a PitchBend, a system common
  # message, and a system exclusive dump split across several chunks
  # (with a Clock byte inside it).
  def test_many_short_chunks
    chunks = [
      [0x90],          # Note On, channel 0
      [0x40, 0x40],    # note 64, vel 64
      [0x41],          # running status, first data byte
      [0x42],          # note 65, vel 66
      [0xE0],          # Pitch Bend, channel 0
      [0x34],          # lsb
      [0xF8],          # Clock: emitted immediately, bend still pending
      [0x01],          # msb; bend completes, value = (1 << 7) + 0x34
      [0xF3, 0x05],    # Song Select 5; clears running status
      [0xF0],          # SysEx start
      [0x7E, 0x7F],
      [0xF8],          # Clock inside the SysEx dump
      [0x09, 0x01],
      [0xF7],          # SysEx end
      [0x91, 0x40, 0x40], # Note On, channel 1
      [0x42, 0x10]     # running status Note On
    ]
    events = feed_chunks(chunks)

    assert_equal(9, events.length)
    assert_note_on(events[0], 0, 0x40, 0x40)
    assert_note_on(events[1], 0, 0x41, 0x42)
    assert_instance_of(MIDI::Clock, events[2])
    pb = events[3]
    assert_instance_of(MIDI::PitchBend, pb)
    assert_equal(0, pb.channel)
    assert_equal((1 << 7) + 0x34, pb.value)
    ss = events[4]
    assert_instance_of(MIDI::SongSelect, ss)
    assert_equal(5, ss.song)
    assert_instance_of(MIDI::Clock, events[5])
    sx = events[6]
    assert_instance_of(MIDI::SystemExclusive, sx)
    assert_equal([0x7E, 0x7F, 0x09, 0x01], sx.data)
    assert_note_on(events[7], 1, 0x40, 0x40)
    assert_note_on(events[8], 1, 0x42, 0x10)
  end

  # Status and data bytes may be split at any boundary.
  def test_status_split_across_chunks
    events = feed_chunks([[0xC0], [0x05]]) # Program Change ch0 p5
    assert_equal(1, events.length)
    assert_instance_of(MIDI::ProgramChange, events[0])
    assert_equal(5, events[0].program)
  end

  # A one-byte realtime message between running-status messages does not
  # disturb the running status.
  def test_realtime_between_running_messages
    events = feed_chunks([[0x90, 0x40, 0x40, 0xF8, 0x41, 0x42]])
    assert_equal(3, events.length)
    assert_note_on(events[0], 0, 0x40, 0x40)
    assert_instance_of(MIDI::Clock, events[1])
    assert_note_on(events[2], 0, 0x41, 0x42)
  end

  def test_realtime_inside_sysex
    events = feed_chunks([[0xF0, 0x7E], [0xF8], [0x01], [0xF7]])
    assert_equal(2, events.length)
    assert_instance_of(MIDI::Clock, events[0])
    assert_instance_of(MIDI::SystemExclusive, events[1])
    assert_equal([0x7E, 0x01], events[1].data)
  end

  def test_song_pointer_with_clock_between_data_bytes
    events = feed_chunks([[0xF2, 0x00], [0xF8], [0x01]])
    assert_equal(2, events.length)
    assert_instance_of(MIDI::Clock, events[0])
    assert_instance_of(MIDI::SongPointer, events[1])
    assert_equal(1 << 7, events[1].pointer)
  end

  def test_mtc_quarter_frame_becomes_system_common
    events = feed_chunks([[0xF1, 0x21]])
    assert_equal(1, events.length)
    assert_instance_of(MIDI::SystemCommon, events[0])
    assert_equal(MIDI::MTC_QUARTER_FRAME, events[0].status)
    assert_equal([0x21], events[0].data)
  end

  def test_tune_request_and_undefined_realtime_byte
    events = feed_chunks([[0xF6], [0xF9]]) # Tune Req; undefined realtime
    assert_equal(2, events.length)
    assert_instance_of(MIDI::TuneRequest, events[0])
    assert_instance_of(MIDI::Realtime, events[1])
    assert_equal(0xF9, events[1].status)
  end

  def test_system_common_clears_running_status
    parser = MIDI::IO::StreamParser.new
    assert_nothing_raised do
      parser.feed([0x90, 0x40, 0x40])
      parser.feed([0x41, 0x42])   # running status works
      parser.feed([0xF3, 0x05])   # Song Select clears running status
    end
    assert_raise(MIDI::IO::StreamParser::Error) do
      parser.feed([0x40])         # data byte with no status now
    end
  end

  def test_sysex_clears_running_status
    parser = MIDI::IO::StreamParser.new
    parser.feed([0x90, 0x40, 0x40])
    parser.feed([0xF0, 0x01, 0xF7])
    assert_raise(MIDI::IO::StreamParser::Error) do
      parser.feed([0x40, 0x40])
    end
  end

  def test_string_input
    events = feed_chunks(["\x90\x40\x40"])
    assert_equal(1, events.length)
    assert_note_on(events[0], 0, 0x40, 0x40)
  end

  def test_zero_velocity_stays_note_on
    events = feed_chunks([[0x90, 0x40, 0x00]])
    assert_instance_of(MIDI::NoteOn, events[0])
    assert_equal(0, events[0].velocity)
  end

  def test_illegal_leading_data_byte
    assert_raise(MIDI::IO::StreamParser::Error) { feed_chunks([[0x40]]) }
  end

  def test_stray_end_of_sysex
    assert_raise(MIDI::IO::StreamParser::Error) { feed_chunks([[0xF7]]) }
  end

  def test_undefined_system_common_status
    assert_raise(MIDI::IO::StreamParser::Error) { feed_chunks([[0xF4, 0x00]]) }
    assert_raise(MIDI::IO::StreamParser::Error) { feed_chunks([[0xF5, 0x00]]) }
  end

  def test_status_byte_inside_sysex_is_an_error
    assert_raise(MIDI::IO::StreamParser::Error) do
      feed_chunks([[0xF0, 0x01], [0x90], [0xF7]])
    end
  end

  def test_nested_sysex_start_is_an_error
    assert_raise(MIDI::IO::StreamParser::Error) do
      feed_chunks([[0xF0, 0x01], [0xF0]])
    end
  end

  def test_invalid_byte_value
    parser = MIDI::IO::StreamParser.new
    assert_raise(MIDI::IO::StreamParser::Error) { parser.feed([0x100]) }
  end

  def test_finish_reports_truncated_channel_message
    parser = MIDI::IO::StreamParser.new
    events = parser.feed([0x90, 0x40])
    assert_empty(events)
    assert_raise(MIDI::IO::StreamParser::Error) { parser.finish }
  end

  def test_finish_reports_unterminated_sysex
    parser = MIDI::IO::StreamParser.new
    assert_empty(parser.feed([0xF0, 0x7E, 0x7F]))
    assert(parser.sysex_active?)
    assert_raise(MIDI::IO::StreamParser::Error) { parser.finish }
  end

  def test_sysex_length_cap
    assert_raise(MIDI::IO::StreamParser::Error) do
      feed_chunks([[0xF0], [0x01, 0x02, 0x03, 0x04], [0xF7]],
                  max_sysex_bytes: 3)
    end
  end

  def test_finish_allows_parser_reuse
    parser = MIDI::IO::StreamParser.new
    first = parser.feed([0x90, 0x40, 0x40])
    assert_equal(1, first.length)
    assert_empty(parser.finish)
    second = parser.feed([0x80, 0x40, 0x40])
    assert_equal(1, second.length)
    assert_instance_of(MIDI::NoteOff, second[0])
    assert_empty(parser.finish)
  end
end
