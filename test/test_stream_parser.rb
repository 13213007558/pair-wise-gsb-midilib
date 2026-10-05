require 'test/unit'
require_relative '../lib/midilib'

class StreamParserTester < Test::Unit::TestCase
  # Feeds +chunks+ (arrays of byte arrays) one after another into a
  # fresh parser, collecting every emitted event. Mirrors a server
  # receiving many small device packets.
  def feed_chunks(chunks, max_sysex_length = nil)
    parser =
      if max_sysex_length
        MIDI::IO::StreamParser.new(max_sysex_length)
      else
        MIDI::IO::StreamParser.new
      end
    events = []
    chunks.each { |chunk| events.concat(parser.feed(chunk)) }
    [parser, events]
  end

  # Splits +bytes+ into one-byte chunks, the most aggressive packet
  # fragmentation possible.
  def single_byte_chunks(bytes)
    bytes.map { |byte| [byte] }
  end

  def test_running_status_note_on_in_short_chunks
    # 0x90 note on ch0, then two more note-ons with the status omitted
    # (running status), delivered as ten one-byte chunks.
    bytes = [0x90, 60, 100, 62, 90, 64, 80]
    parser, events = feed_chunks(single_byte_chunks(bytes))

    assert_equal 3, events.length
    events.each { |event| assert_kind_of MIDI::NoteOn, event }
    assert_equal [60, 62, 64], events.map(&:note)
    assert_equal [100, 90, 80], events.map(&:velocity)
    assert_equal 0, events.first.channel
    assert_equal 0x90, parser.running_status
    assert_nothing_raised { parser.finish }
  end

  def test_running_status_survives_arbitrary_chunk_splits
    # Two note-ons under running status, then an explicit note-off and
    # another under its running status.
    bytes = [0x93, 48, 64, 50, 64, 0x83, 48, 64, 50, 64]
    # Split at every possible offset using chunks of varying sizes.
    (1..bytes.length).each do |step|
      chunks = bytes.each_slice(step).to_a
      _parser, events = feed_chunks(chunks)
      assert_equal 4, events.length, "step=#{step}"
      assert_kind_of MIDI::NoteOn, events[0]
      assert_kind_of MIDI::NoteOn, events[1]
      assert_kind_of MIDI::NoteOff, events[2]
      assert_kind_of MIDI::NoteOff, events[3]
      assert_equal 3, events[0].channel
      assert_equal [48, 50], [events[0].note, events[1].note]
    end
  end

  def test_clock_between_pitch_bend_data_bytes_is_immediate
    # Pitch bend on ch 5: E5 lsb=00 msb=40, but a clock tick (F8)
    # arrives between the two data bytes. All bytes arrive one at a
    # time.
    chunks = [[0xE5], [0x00], [0xF8], [0x40]]
    parser, events = feed_chunks(chunks)

    assert_equal 2, events.length
    assert_kind_of MIDI::Clock, events[0]
    bend = events[1]
    assert_kind_of MIDI::PitchBend, bend
    assert_equal 5, bend.channel
    assert_equal (0x40 << 7) + 0x00, bend.value
    assert_equal 0xE5, parser.running_status
    assert_nothing_raised { parser.finish }
  end

  def test_realtime_byte_does_not_consume_data_byte
    # Two clocks bracketing one data byte of a note-on: the note still
    # completes with its own two data bytes.
    chunks = [[0xF8], [0x91], [0xF8], [55], [0xF8], [77]]
    _parser, events = feed_chunks(chunks)

    clocks = events.select { |event| event.is_a?(MIDI::Clock) }
    notes = events.select { |event| event.is_a?(MIDI::NoteOn) }
    assert_equal 3, clocks.length
    assert_equal 1, notes.length
    assert_equal 55, notes.first.note
    assert_equal 77, notes.first.velocity
    assert_equal 1, notes.first.channel
  end

  def test_sysex_split_across_chunks
    payload = [0x7e, 0x7f, 0x09, 0x01, 0x77]
    chunks = [[0xF0], payload[0, 2], payload[2, 1], payload[3, 2], [0xF7]]
    parser, events = feed_chunks(chunks)

    assert_equal 1, events.length
    event = events.first
    assert_kind_of MIDI::SystemExclusive, event
    assert_equal payload, event.data
    assert_equal MIDI::SYSEX, event.status
    assert_nil parser.running_status
    assert_nothing_raised { parser.finish }
  end

  def test_sysex_split_between_every_byte
    payload = [0x01, 0x02, 0x03]
    parser, events = feed_chunks(single_byte_chunks([0xF0] + payload + [0xF7]))

    assert_equal 1, events.length
    assert_kind_of MIDI::SystemExclusive, events.first
    assert_equal payload, events.first.data
    assert_nothing_raised { parser.finish }
  end

  def test_realtime_inside_sysex_is_emitted_not_accumulated
    payload = [0x42, 0x01, 0x02]
    chunks = [[0xF0, 0x42], [0xF8], [0x01], [0xF8], [0x02], [0xF7]]
    _parser, events = feed_chunks(chunks)

    assert_equal 3, events.length
    assert_kind_of MIDI::Clock, events[0]
    assert_kind_of MIDI::Clock, events[1]
    assert_kind_of MIDI::SystemExclusive, events[2]
    assert_equal payload, events[2].data
  end

  def test_sysex_length_limit
    parser = MIDI::IO::StreamParser.new(4)
    assert_nothing_raised { parser.feed([0xF0, 1, 2]) }
    assert_nothing_raised { parser.feed([3, 4]) }
    error = assert_raise(MIDI::IO::StreamParser::SysexTooLong) do
      parser.feed([5])
    end
    assert_match(/4/, error.message)
  end

  def test_finish_reports_unterminated_sysex
    parser = MIDI::IO::StreamParser.new
    parser.feed([0xF0, 0x42, 0x12])
    error = assert_raise(MIDI::IO::StreamParser::TruncatedMessage) do
      parser.finish
    end
    assert_match(/system exclusive/i, error.message)
  end

  def test_finish_reports_partial_channel_message
    parser = MIDI::IO::StreamParser.new
    parser.feed([0x90, 60])
    error = assert_raise(MIDI::IO::StreamParser::TruncatedMessage) do
      parser.finish
    end
    assert_match(/90/, error.message)
  end

  def test_finish_reports_single_missing_data_byte
    parser = MIDI::IO::StreamParser.new
    parser.feed([0xE0, 0x00]) # pitch bend needs two data bytes
    assert_raise(MIDI::IO::StreamParser::TruncatedMessage) { parser.finish }
  end

  def test_illegal_leading_data_byte
    parser = MIDI::IO::StreamParser.new
    error = assert_raise(MIDI::IO::StreamParser::IllegalDataByte) do
      parser.feed([0x42])
    end
    assert_match(/without a status byte/, error.message)
  end

  def test_illegal_data_byte_after_system_common_clears_running_status
    parser = MIDI::IO::StreamParser.new
    parser.feed([0x90, 60, 100])
    assert_equal 0x90, parser.running_status
    # Tune request (F6) is system common and clears running status.
    events = parser.feed([0xF6])
    assert_equal 1, events.length
    assert_kind_of MIDI::TuneRequest, events.first
    assert_nil parser.running_status
    assert_raise(MIDI::IO::StreamParser::IllegalDataByte) do
      parser.feed([0x40])
    end
  end

  def test_sysex_clears_running_status
    parser = MIDI::IO::StreamParser.new
    parser.feed([0x90, 60, 100, 0xF0, 0x01, 0xF7])
    assert_nil parser.running_status
    assert_raise(MIDI::IO::StreamParser::IllegalDataByte) do
      parser.feed([0x40])
    end
  end

  def test_system_common_message
    # Song pointer F2 with two data bytes (14-bit little endian),
    # fragmented.
    _parser, events = feed_chunks([[0xF2, 0x34], [0x10]])
    assert_equal 1, events.length
    assert_kind_of MIDI::SongPointer, events.first
    assert_equal (0x10 << 7) + 0x34, events.first.pointer
  end

  def test_song_select_and_running_status_cleared
    parser = MIDI::IO::StreamParser.new
    events = parser.feed([0xF3, 0x05])
    assert_equal 1, events.length
    assert_kind_of MIDI::SongSelect, events.first
    assert_equal 5, events.first.song
    assert_nil parser.running_status
  end

  def test_callback_receives_events_in_order
    parser = MIDI::IO::StreamParser.new
    seen = []
    parser.feed([0x90, 60, 100]) { |event| seen << event }
    parser.feed([0xF8, 62, 90]) { |event| seen << event }
    assert_equal 3, seen.length
    assert_kind_of MIDI::NoteOn, seen[0]
    assert_kind_of MIDI::Clock, seen[1]
    assert_kind_of MIDI::NoteOn, seen[2]
  end

  def test_constructor_block_is_default_callback
    seen = []
    parser = MIDI::IO::StreamParser.new { |event| seen << event }
    parser.feed([0x90, 60, 100])
    parser.feed([0xF8])
    assert_equal 2, seen.length
    assert_kind_of MIDI::NoteOn, seen[0]
    assert_kind_of MIDI::Clock, seen[1]
  end

  def test_binary_string_input
    parser = MIDI::IO::StreamParser.new
    events = parser.feed("\x90\x3c\x64\xf8".b)
    assert_equal 2, events.length
    assert_kind_of MIDI::NoteOn, events[0]
    assert_equal 60, events[0].note
    assert_kind_of MIDI::Clock, events[1]
  end

  def test_events_carry_no_delta_time
    _parser, events = feed_chunks(single_byte_chunks([0x90, 60, 100]))
    assert_equal [0], events.map(&:delta_time)
  end

  def test_note_on_zero_velocity_becomes_note_off
    _parser, events = feed_chunks([[0x90, 60, 0]])
    assert_equal 1, events.length
    assert_kind_of MIDI::NoteOff, events.first
  end

  def test_reset_clears_partial_message
    parser = MIDI::IO::StreamParser.new
    parser.feed([0x90, 60])
    parser.reset
    assert_nothing_raised { parser.finish }
    assert_raise(IOError) { parser.feed([0x90, 60, 100]) }
  end

  def test_undefined_status_bytes_raise
    parser = MIDI::IO::StreamParser.new
    assert_raise(MIDI::IO::StreamParser::IllegalDataByte) { parser.feed([0xF1]) }
    assert_raise(MIDI::IO::StreamParser::IllegalDataByte) { parser.feed([0xF9]) }
    assert_raise(MIDI::IO::StreamParser::IllegalDataByte) { parser.feed([0xFD]) }
  end

  def test_acceptance_stream_of_a_dozen_plus_chunks
    # End-to-end mix, fed in 16 tiny chunks, exercising running status,
    # interleaved realtime, cross-chunk SysEx, and a partial message.
    chunks = [
      [0x90], [60], [100],        # note on, 3 chunks
      [62, 90],                   # running status note on
      [0xE5, 0x00],               # pitch bend start
      [0xF8],                     # clock tick in the middle
      [0x40],                     # pitch bend end
      [0xF0, 0x7e],               # sysex start
      [0x7f], [0x09, 0x01],       # sysex body
      [0xF7],                     # sysex end
      [0x80, 60, 64],             # note off (running cleared by sysex)
      [0xF3, 0x02],               # song select
      [0xF8]                      # trailing clock
    ]
    parser, events = feed_chunks(chunks)

    classes = events.map(&:class)
    assert_equal(
      [MIDI::NoteOn, MIDI::NoteOn, MIDI::Clock, MIDI::PitchBend,
       MIDI::SystemExclusive, MIDI::NoteOff, MIDI::SongSelect, MIDI::Clock],
      classes
    )
    assert_equal [0x7e, 0x7f, 0x09, 0x01], events[4].data
    assert_nothing_raised { parser.finish }
  end
end
