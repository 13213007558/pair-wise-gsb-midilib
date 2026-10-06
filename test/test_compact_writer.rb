require 'test/unit'
require 'stringio'
require_relative '../lib/midilib'

class CompactWriterTest < Test::Unit::TestCase
  def test_disabled_option_preserves_order_and_bytes
    events = [
      MIDI::NoteOn.new(1, 62, 100, 0),
      MIDI::NoteOn.new(0, 60, 100, 0),
      MIDI::NoteOn.new(1, 64, 100, 10)
    ]
    sequence = test_sequence(events)
    original = event_signatures(sequence.tracks[0])

    first_output = StringIO.new
    writer = sequence.write(first_output, 1, compact: false)
    second_output = StringIO.new
    sequence.write(second_output, 1, compact: false)

    assert_equal(first_output.string, second_output.string)
    assert_nil(writer.compact_report)
    assert_equal(original, event_signatures(sequence.tracks[0]))
    assert_equal([MIDI::NOTE_ON + 1, MIDI::NOTE_ON + 0, MIDI::NOTE_ON + 1],
                 status_path(first_output.string)[0...-1])
  end

  def test_exact_small_group_matches_all_legal_permutations
    events = [
      MIDI::NoteOn.new(0, 60, 100, 10),
      MIDI::NoteOn.new(1, 62, 100, 0),
      MIDI::NoteOn.new(2, 64, 100, 0),
      MIDI::NoteOn.new(3, 66, 100, 0),
      MIDI::NoteOn.new(4, 68, 100, 0)
    ]
    sequence = test_sequence(events)
    legal_indices = (0...events.length).to_a.permutation.to_a
    assert_equal(120, legal_indices.length)
    lengths = legal_indices.map { |indices| permutation_length(events, indices, 10) }

    output = StringIO.new
    writer = sequence.write(output, 1, compact: true)
    report = writer.compact_report

    assert_equal(lengths.min, report[:tracks][0][:bytes_after])
    assert_equal(1, report[:groups])
    assert_equal(1, report[:exact_groups])
    assert_equal(0, report[:fallback_groups])
    assert_equal(true, report[:optimal])
    assert_equal([0, 1, 2, 3, 4], channel_path(output.string))
    assert_roundtrip(sequence, output.string)
  end

  def test_exact_noteoff_group_keeps_required_note_order
    events = [
      MIDI::NoteOn.new(0, 50, 100, 10),
      MIDI::NoteOn.new(1, 62, 100, 0),
      MIDI::NoteOff.new(0, 60, 64, 0),
      MIDI::NoteOn.new(0, 60, 100, 0)
    ]
    sequence = test_sequence(events)
    legal_indices = (0...events.length).to_a.permutation.select do |indices|
      indices.index(2) < indices.index(3)
    end
    assert_equal(12, legal_indices.length)
    lengths = legal_indices.map { |indices| permutation_length(events, indices, 10) }

    output = StringIO.new
    writer = sequence.write(output, 1, compact: true)

    assert_equal(lengths.min, writer.compact_report[:tracks][0][:bytes_after])
    assert_equal(true, writer.compact_report[:optimal])
    assert_equal([MIDI::NOTE_ON + 0, MIDI::NOTE_ON + 0,
                  MIDI::NOTE_ON + 0, MIDI::NOTE_ON + 1],
                 status_path(output.string)[0...-1])
    assert_roundtrip(sequence, output.string)
  end

  def test_state_events_meta_and_sysex_keep_necessary_boundaries
    events = [
      MIDI::Controller.new(0, 7, 100, 10),
      MIDI::ProgramChange.new(0, 4, 0),
      MIDI::Controller.new(1, 7, 90, 0),
      MIDI::MetaEvent.new(MIDI::META_COPYRIGHT, 'x', 0),
      MIDI::NoteOn.new(0, 60, 100, 0),
      MIDI::SystemExclusive.new([1, 2], 0),
      MIDI::NoteOn.new(0, 62, 100, 0)
    ]
    sequence = test_sequence(events)
    legal_indices = [0, 1, 2].permutation.map do |indices|
      indices + [3, 4, 5, 6]
    end
    lengths = legal_indices.map { |indices| permutation_length(events, indices, 10) }

    output = StringIO.new
    writer = sequence.write(output, 1, compact: true)

    assert_equal(lengths.min, writer.compact_report[:tracks][0][:bytes_after])
    assert_equal(0, writer.compact_report[:bytes_saved])
    assert_equal([MIDI::CONTROLLER + 0, MIDI::PROGRAM_CHANGE + 0,
                  MIDI::CONTROLLER + 1, :meta, MIDI::NOTE_ON + 0,
                  :sysex, MIDI::NOTE_ON + 0, :eot],
                 status_path(output.string))
    assert_roundtrip(sequence, output.string)
  end

  def test_large_group_uses_reported_bounded_fallback
    events = 7.times.map do |channel|
      MIDI::NoteOn.new(channel, 60 + channel, 100, channel.zero? ? 10 : 0)
    end
    events.concat(7.times.map { |channel| MIDI::NoteOff.new(channel, 60 + channel, 64, 0) })
    sequence = test_sequence(events)
    normal_output = StringIO.new
    sequence.write(normal_output, 1, compact: false)
    normal_length = track_data_length(normal_output.string)

    output = StringIO.new
    writer = sequence.write(output, 1, compact: true)
    report = writer.compact_report

    assert_equal(1, report[:groups])
    assert_equal(0, report[:exact_groups])
    assert_equal(1, report[:fallback_groups])
    assert_equal(false, report[:optimal])
    assert_equal(normal_length, report[:tracks][0][:fallback_upper_bound_bytes])
    assert_operator(report[:bytes_after], :<=, normal_length)
    assert_equal(7, report[:bytes_saved])
    assert_equal([0, 0, 1, 1, 2, 2, 3, 3, 4, 4, 5, 5, 6, 6],
                 channel_path(output.string))
    assert_roundtrip(sequence, output.string)
  end

  private

  def sequence
    @sequence
  end

  def test_sequence(events)
    @sequence = MIDI::Sequence.new
    track = MIDI::Track.new(@sequence)
    @sequence.tracks << track
    track.events.concat(events)
    @sequence
  end

  def build_sequence(events)
    sequence = MIDI::Sequence.new
    track = MIDI::Track.new(sequence)
    sequence.tracks << track
    track.events.concat(events)
    sequence
  end

  def permutation_length(events, indices, first_delta)
    permutation = indices.map.with_index do |index, position|
      event = events[index].dup
      event.delta_time = position.zero? ? first_delta : 0
      event
    end
    output = StringIO.new
    build_sequence(permutation).write(output, 1, compact: false)
    track_data_length(output.string)
  end

  def track_data_length(data)
    data[18, 4].unpack1('N')
  end

  def status_path(data)
    parsed_sequence = MIDI::Sequence.new
    parser = StatusPathParser.new(parsed_sequence)
    parser.read_from(StringIO.new(data))
    parser.statuses
  end

  def channel_path(data)
    status_path(data).grep(Integer).map { |status| status & 0x0f }
  end

  def assert_roundtrip(expected_sequence, data)
    parsed_sequence = MIDI::Sequence.new
    parsed_sequence.read(StringIO.new(data))
    expected_track = expected_sequence.tracks[0]
    expected_track.recalc_times
    actual_events = parsed_sequence.tracks[0].events[0...-1]

    expected = expected_track.events.map { |event| semantic_signature(event) }
    actual = actual_events.map { |event| semantic_signature(event) }
    pending_notes = {}
    expected.delete_if do |signature|
      key = signature[0..2]
      if signature[0] == MIDI::NoteOn && signature[5] != 0
        pending_notes[key] = signature
        false
      elsif signature[0] == MIDI::NoteOff
        !pending_notes.delete(key)
      else
        false
      end
    end
    actual.reject! do |signature|
      signature[0] == MIDI::NoteOff && !expected.include?(signature)
    end
    assert_equal(expected.sort_by { |signature| signature.map(&:to_s) },
                 actual.sort_by { |signature| signature.map(&:to_s) })
  end

  def event_signatures(track)
    track.recalc_times
    track.events.map { |event| semantic_signature(event) }
  end

  def semantic_signature(event)
    signature = [
      event.class,
      event.respond_to?(:channel) ? event.channel : nil,
      event.respond_to?(:note) ? event.note : nil,
      event.respond_to?(:controller) ? event.controller : nil,
      event.respond_to?(:program) ? event.program : nil,
      event.respond_to?(:velocity) ? event.velocity : nil,
      event.respond_to?(:value) ? event.value : nil,
      event.is_a?(MIDI::MetaEvent) ? event.meta_type : nil,
      event.time_from_start
    ]
    normalized_semantic_signature(signature,
                                  event.is_a?(MIDI::NoteOn) && event.velocity.zero? ? MIDI::NoteOff : event.class,
                                  event.is_a?(MIDI::NoteOn) && event.velocity.zero? ? 64 : nil)
  end

  def normalized_semantic_signature(signature, klass, velocity)
    signature = signature.dup
    signature[0] = klass if klass
    signature[5] = velocity if velocity
    signature
  end

  class StatusPathParser < MIDI::IO::SeqReader
    attr_reader :statuses

    def initialize(sequence)
      super
      @statuses = []
    end

    def chan_message(running, status, data1, data2)
      @statuses << status
      super
    end

    def sysex(message)
      @statuses << :sysex
      super
    end

    def meta_event(type)
      @statuses << (type == MIDI::META_TRACK_END ? :eot : :meta)
      super
    end
  end
end
