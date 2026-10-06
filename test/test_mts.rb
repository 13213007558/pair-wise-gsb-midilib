require 'stringio'
require 'test/unit'
require_relative '../lib/midilib'

class MTSTester < Test::Unit::TestCase
  QUANTUM = 1.0 / MIDI::MTS::FRACTION_UNITS

  def test_default_tuning_table
    table = MIDI::MTS::TuningTable.new

    assert_equal(128, table.length)
    assert_equal((0..127).to_a, table.to_a)
    assert_equal(60, table[60])
  end

  def test_table_rounds_pitches_to_protocol_resolution
    table = MIDI::MTS::TuningTable.new
    table[60] = 60.31254

    encoded = MIDI::MTS::PitchCodec.pitch_to_bytes(table[60])
    decoded = MIDI::MTS::PitchCodec.bytes_to_pitch(encoded)

    assert_in_delta(60.31254, decoded, QUANTUM / 2.0)
    assert_equal(60.31256103515625, decoded)
  end

  def test_out_of_range_pitches_are_rejected_without_modulo
    assert_raises(MIDI::MTS::InvalidValueError) do
      MIDI::MTS::PitchCodec.pitch_to_bytes(-0.1)
    end
    assert_raises(MIDI::MTS::InvalidValueError) do
      MIDI::MTS::PitchCodec.pitch_to_bytes(128.0)
    end
    assert_raises(MIDI::MTS::InvalidValueError) do
      MIDI::MTS::TuningTable.new[128] = 0
    end

    bytes = MIDI::MTS::PitchCodec.pitch_to_bytes(127.0)
    assert_equal(127.0, MIDI::MTS::PitchCodec.bytes_to_pitch(bytes))
    assert_raises(MIDI::MTS::InvalidValueError) do
      MIDI::MTS::PitchCodec.pitch_to_bytes(
        127 + (MIDI::MTS::FRACTION_UNITS - 1).to_f / MIDI::MTS::FRACTION_UNITS
      )
    end
    assert_raises(MIDI::MTS::FormatError) do
      MIDI::MTS::PitchCodec.bytes_to_pitch([128, 0, 0])
    end
  end

  def test_bulk_tuning_dump_round_trip_with_three_retuned_notes
    table = MIDI::MTS::TuningTable.new(name: 'Example Tuning')
    table[57] = 57.0 + (10.0 / 100.0)
    table[60] = 60.0 - (7.0 / 100.0)
    table[69] = 69.0 + (1.0 / 3.0)

    dump = MIDI::MTS::BulkTuningDump.new(table, device_id: 5)
    bytes = dump.sysex_bytes

    assert_equal(0xF0, bytes.first)
    assert_equal(MIDI::MTS::NON_REALTIME_UNIVERSAL, bytes[1])
    assert_equal(5, bytes[2])
    assert_equal(MIDI::MTS::DEVICE_CONTROL_SUB_ID, bytes[3])
    assert_equal(MIDI::MTS::BULK_TUNING_DUMP_SUB_ID, bytes[4])
    assert_equal(0xF7, bytes.last)
    assert_equal(407, bytes.length)

    decoded = MIDI::MTS::MTSMessage.parse(bytes)
    assert_kind_of(MIDI::MTS::BulkTuningDump, decoded)
    assert_equal(5, decoded.device_id)
    assert_equal('Example Tuning', decoded.table.name_string)
    assert_equal(table.to_a, decoded.table.to_a)
    (0..127).each do |note|
      next if [57, 60, 69].include?(note)
      assert_equal(note, decoded.table[note])
    end
    assert_in_delta(57.10, decoded.table[57], QUANTUM / 2.0)
    assert_in_delta(59.93, decoded.table[60], QUANTUM / 2.0)
    assert_in_delta(69.33333333333333, decoded.table[69], QUANTUM / 2.0)
  end

  def test_bulk_tuning_dump_checksum
    dump = MIDI::MTS::BulkTuningDump.new(
      { 60 => 60.25 }, device_id: MIDI::MTS::DEVICE_ID_BROADCAST
    )
    bytes = dump.sysex_bytes
    checksum_index = bytes.length - 2

    expected = MIDI::MTS::BulkTuningDump.checksum_for(
      MIDI::MTS::BULK_TUNING_DUMP_SUB_ID,
      bytes[5, MIDI::MTS::BulkTuningDump::PITCH_DATA_LENGTH]
    )
    assert_equal(expected, dump.checksum)
    assert_equal(expected, bytes[checksum_index])

    corrupted = bytes.dup
    corrupted[checksum_index] = (expected + 1) & 0x7F
    error = assert_raises(MIDI::MTS::ChecksumError) do
      MIDI::MTS::MTSMessage.parse(corrupted)
    end
    assert_match(/checksum/, error.message)
  end

  def test_single_note_no_change_sentinel_round_trips
    message = MIDI::MTS::SingleNoteTuningChange.new(
      [[60, 60.5], [64, nil], [72, nil]],
      tuning_program: 7,
      device_id: 9
    )
    bytes = message.sysex_bytes

    assert_equal(MIDI::MTS::REALTIME_UNIVERSAL, bytes[1])
    assert_equal(9, bytes[2])
    assert_equal(MIDI::MTS::SINGLE_NOTE_REALTIME_SUB_ID, bytes[3])
    assert_equal(0x7F, bytes[4])
    assert_equal(7, bytes[5])
    assert_equal(3, bytes[6])
    assert_equal(MIDI::MTS::NO_CHANGE_BYTES, bytes[12, 3])
    assert_equal(MIDI::MTS::NO_CHANGE_BYTES, bytes[16, 3])

    decoded = MIDI::MTS::MTSMessage.parse(bytes)
    assert_predicate(decoded, :realtime?)
    assert_equal([[60, 60.5], [64, nil], [72, nil]], decoded.changes)
    assert_equal([60], decoded.changed_notes)
  end

  def test_single_note_non_realtime_is_distinct
    message = MIDI::MTS::SingleNoteTuningChange.new(
      [[60, 60.5]], tuning_program: 1, realtime: false
    )
    bytes = message.sysex_bytes

    assert_equal(MIDI::MTS::NON_REALTIME_UNIVERSAL, bytes[1])
    assert_equal(MIDI::MTS::SINGLE_NOTE_NON_REALTIME_SUB_ID, bytes[3])
    decoded = MIDI::MTS::MTSMessage.parse(bytes)
    assert_not_predicate(decoded, :realtime?)
  end

  def test_bulk_tuning_dump_request_round_trips
    request = MIDI::MTS::BulkTuningDumpRequest.new(11, device_id: 42)
    decoded = MIDI::MTS::MTSMessage.parse(request.sysex_bytes)

    assert_kind_of(MIDI::MTS::BulkTuningDumpRequest, decoded)
    assert_equal(11, decoded.tuning_program)
    assert_equal(42, decoded.device_id)
  end

  def test_bulk_table_rejects_single_note_sentinel
    dump = MIDI::MTS::BulkTuningDump.new
    bytes = dump.sysex_bytes
    note_offset = 5 + 16 + (60 * 3)
    bytes[note_offset, 3] = MIDI::MTS::NO_CHANGE_BYTES

    assert_raises(MIDI::MTS::ChecksumError) do
      MIDI::MTS::MTSMessage.parse(bytes)
    end

    data = dump.table.encode_pitch_data
    data[16 + (60 * 3), 3] = MIDI::MTS::NO_CHANGE_BYTES
    assert_raises(MIDI::MTS::FormatError) do
      MIDI::MTS::TuningTable.decode_pitch_data(data)
    end
  end

  def test_illegal_device_program_and_duplicate_notes
    assert_raises(MIDI::MTS::InvalidValueError) do
      MIDI::MTS::BulkTuningDump.new(nil, device_id: 128)
    end
    assert_raises(MIDI::MTS::InvalidValueError) do
      MIDI::MTS::SingleNoteTuningChange.new([[0, 0]], tuning_program: -1)
    end
    assert_raises(MIDI::MTS::InvalidValueError) do
      MIDI::MTS::SingleNoteTuningChange.new([[0, 0], [0, 1]])
    end
    assert_raises(MIDI::MTS::InvalidValueError) do
      MIDI::MTS::SingleNoteTuningChange.new([])
    end
  end

  def test_bad_message_structure_is_rejected
    not_universal = [0xF0, 0x7D, 0, 0x08] + Array.new(400, 0) + [0xF7]
    assert_raises(MIDI::MTS::FormatError) do
      MIDI::MTS::MTSMessage.parse(not_universal)
    end

    bulk = MIDI::MTS::BulkTuningDump.new.sysex_bytes
    truncated = bulk[0...-10]
    assert_raises(MIDI::MTS::FormatError) do
      MIDI::MTS::MTSMessage.parse(truncated)
    end

    bad_single = [0xF0, 0x7F, 0, 0x02, 0x00, 0, 1, 60, 0, 0, 0xF7]
    assert_raises(MIDI::MTS::FormatError) do
      MIDI::MTS::MTSMessage.parse(bad_single)
    end
  end

  def test_application_semantics_for_sounding_notes
    state = MIDI::MTS::TuningState.new
    state.note_on(0, 60)
    state.note_on(1, 60)
    state.note_on(0, 64)

    realtime = MIDI::MTS::SingleNoteTuningChange.new(
      [[60, 60.25], [64, nil]], tuning_program: 0, realtime: true
    )
    update = state.apply(realtime)

    assert_predicate(update, :sounding_notes_affected?)
    assert_equal([[0, 60], [1, 60]], update.affected_sounding_notes)
    assert_equal([60], update.changed_notes)
    assert_equal(60.25, state.pitch(0, 60))
    assert_equal(64, state.pitch(0, 64))

    non_realtime = MIDI::MTS::SingleNoteTuningChange.new(
      [[60, 60.5]], realtime: false
    )
    update = state.apply(non_realtime)

    assert_not_predicate(update, :sounding_notes_affected?)
    assert_equal([], update.affected_sounding_notes)
    assert_equal(60.5, state.pitch(0, 60))
    assert(state.sounding?(0, 60))

    dump = MIDI::MTS::BulkTuningDump.new({ 60 => 60.75 })
    update = state.apply(dump, tuning_program: 2)
    assert_equal([], update.affected_sounding_notes)
    assert_equal(60.75, state[2][60])
    assert_equal(60.5, state[0][60])
  end

  def test_mts_sysex_round_trips_through_standard_midi_file
    table = MIDI::MTS::TuningTable.new(name: 'SMF Tuning')
    table[60] = 60.01
    table[61] = 61.02
    table[62] = 62.03
    dump = MIDI::MTS::BulkTuningDump.new(table, device_id: 127)
    single = MIDI::MTS::SingleNoteTuningChange.new(
      [[60, 60.025]], tuning_program: 4, realtime: false
    )

    sequence = MIDI::Sequence.new
    track = MIDI::Track.new(sequence)
    sequence.tracks << track
    track.events << dump.to_system_exclusive(0)
    track.events << single.to_system_exclusive(10)

    io = StringIO.new
    sequence.write(io)
    io.rewind

    read_sequence = MIDI::Sequence.new
    read_sequence.read(io)
    events = read_sequence.tracks[0].events.grep(MIDI::SystemExclusive)
    assert_equal(2, events.length)
    assert_equal(407, events[0].data.length)
    assert_equal(0xF0, events[0].data.first)
    assert_equal(0xF7, events[0].data.last)

    decoded_dump = MIDI::MTS::MTSMessage.parse(events[0])
    decoded_single = MIDI::MTS::MTSMessage.parse(events[1])
    assert_kind_of(MIDI::MTS::BulkTuningDump, decoded_dump)
    assert_kind_of(MIDI::MTS::SingleNoteTuningChange, decoded_single)
    assert_equal('SMF Tuning', decoded_dump.table.name_string)
    assert_in_delta(60.01, decoded_dump.table[60], QUANTUM / 2.0)
    assert_equal(4, decoded_single.tuning_program)
    assert_not_predicate(decoded_single, :realtime?)
    assert_equal(10, events[1].delta_time)
  end
end
