require 'test/unit'
require 'stringio'
require_relative '../lib/midilib'

class TuningTester < Test::Unit::TestCase
  TOLERANCE = MIDI::Tuning::ENCODING_TOLERANCE + 1e-12

  # A 128-note default (12-TET) table with three microtonal notes.
  def microtuned_tuning
    tuning = MIDI::Tuning.new(name: 'QuarterTone', program: 3)
    tuning[60] = 60.5
    tuning[64] = 63.99
    tuning[67] = 67.25
    tuning
  end

  def test_default_table_is_twelve_tone_equal_temperament
    tuning = MIDI::Tuning.new
    MIDI::Tuning::NOTE_COUNT.times { |note| assert_equal(note.to_f, tuning[note]) }
  end

  def test_pitch_encode_decode_stays_within_protocol_resolution
    [0.0, 0.001, 60.0, 60.5, 63.99, 67.25, 69.01, 127.49997].each do |pitch|
      decoded = MIDI::Tuning.decode_pitch(MIDI::Tuning.encode_pitch(pitch))
      assert_in_delta(pitch, decoded, TOLERANCE, "pitch #{pitch} lost too much precision")
    end
  end

  def test_encode_pitch_byte_layout
    assert_equal([60, 0, 0], MIDI::Tuning.encode_pitch(60.0))
    # 0.5 semitone = 8192/16384 -> MSB 0x40, LSB 0x00
    assert_equal([60, 0x40, 0x00], MIDI::Tuning.encode_pitch(60.5))
    # 0.25 semitone = 4096/16384 -> MSB 0x20, LSB 0x00
    assert_equal([67, 0x20, 0x00], MIDI::Tuning.encode_pitch(67.25))
  end

  def test_illegal_pitch_raises_instead_of_wrapping
    # 128.0 and 200.7 would become legal pitches if taken modulo 128.
    [-0.001, 128.0, 200.7, Float::NAN, Float::INFINITY, -Float::INFINITY, '60', nil].each do |bad|
      assert_raise(MIDI::TuningError) { MIDI::Tuning.encode_pitch(bad) }
    end
    tuning = MIDI::Tuning.new
    assert_raise(MIDI::TuningError) { tuning[0] = 128.0 }
    assert_raise(MIDI::TuningError) { tuning[60] = -1.0 }
  end

  def test_illegal_note_number_raises
    tuning = MIDI::Tuning.new
    assert_raise(MIDI::TuningError) { tuning[128] }
    assert_raise(MIDI::TuningError) { tuning[-1] }
    assert_raise(MIDI::TuningError) { tuning[1.5] }
    assert_raise(MIDI::TuningError) { tuning[128] = 60.0 }
  end

  def test_decode_rejects_bytes_above_7f
    # A fraction MSB with the high bit set must not be masked into a
    # legal pitch.
    assert_raise(MIDI::TuningError) { MIDI::Tuning.decode_pitch([60, 0x80, 0x00]) }
    assert_raise(MIDI::TuningError) { MIDI::Tuning.decode_pitch([0xFF, 0x00, 0x00]) }
  end

  def test_no_change_sentinel
    assert(MIDI::Tuning.no_change?([0x7f, 0x7f, 0x7f]))
    assert_nil(MIDI::Tuning.decode_pitch([0x7f, 0x7f, 0x7f]))
    # 0x7f alone is still a legal semitone; only the full triple is the sentinel.
    assert_equal(127.0, MIDI::Tuning.decode_pitch([0x7f, 0x00, 0x00]))
  end

  def test_bulk_dump_byte_layout
    dump = microtuned_tuning.to_bulk_dump(device_id: 0x0A)
    data = dump.data
    assert_equal(5 + 16 + (128 * 3) + 1, data.length)
    assert_equal([MIDI::SYSEX_NON_REALTIME, 0x0A, MIDI::SUB_ID_MIDI_TUNING,
                  MIDI::MTS_BULK_TUNING_DUMP, 3], data[0, 5])
    assert_equal('QuarterTone     ', data[5, 16].pack('C*'))
    assert_equal(data[-1], dump.checksum)
  end

  def test_bulk_dump_roundtrip
    tuning = microtuned_tuning
    dump = tuning.to_bulk_dump(device_id: 0x0A)
    parsed = MIDI::TuningBulkDump.parse(dump.data)
    assert_equal(0x0A, parsed.device_id)
    assert_equal(3, parsed.program)
    assert_equal('QuarterTone', parsed.tuning_name)
    assert(tuning.equivalent_to?(parsed.tuning))
    assert_instance_of(MIDI::TuningBulkDump, MIDI::MTS.parse(dump))
  end

  def test_bulk_dump_rejects_corrupted_checksum_byte
    data = microtuned_tuning.to_bulk_dump.data
    data[-1] = (data[-1] + 1) & 0x7f
    assert_raise(MIDI::TuningError) { MIDI::TuningBulkDump.parse(data) }
  end

  def test_bulk_dump_rejects_corrupted_payload_byte
    data = microtuned_tuning.to_bulk_dump.data
    data[30] ^= 0x01
    assert_raise(MIDI::TuningError) { MIDI::TuningBulkDump.parse(data) }
  end

  def test_bulk_dump_rejects_truncated_message
    data = microtuned_tuning.to_bulk_dump.data[0...-2]
    assert_raise(MIDI::TuningError) { MIDI::TuningBulkDump.parse(data) }
  end

  def test_single_note_change_byte_layout
    change = MIDI::SingleNoteTuningChange.new({ 60 => 60.0 }, device_id: 0, program: 0)
    assert(!change.realtime?)
    assert_equal([MIDI::SYSEX_NON_REALTIME, 0, MIDI::SUB_ID_MIDI_TUNING,
                  MIDI::MTS_SINGLE_NOTE_TUNING_CHANGE, 0, 1, 60, 60, 0, 0],
                 change.data)
  end

  def test_single_note_change_roundtrip_with_no_change_entry
    change = MIDI::SingleNoteTuningChange.new({ 60 => 60.5, 64 => :no_change },
                                              device_id: 2, program: 5, realtime: true)
    assert(change.realtime?)
    parsed = MIDI::SingleNoteTuningChange.parse(change.data)
    assert(change.data[0] == MIDI::SYSEX_REALTIME)
    assert(parsed.realtime?)
    assert_equal(2, parsed.device_id)
    assert_equal(5, parsed.program)
    assert_in_delta(60.5, parsed.changes[60], TOLERANCE)
    assert_equal(:no_change, parsed.changes[64])
    assert_instance_of(MIDI::SingleNoteTuningChange, MIDI::MTS.parse(change))
  end

  def test_single_note_change_rejects_illegal_note
    assert_raise(MIDI::TuningError) do
      MIDI::SingleNoteTuningChange.new({ 128 => 60.0 })
    end
  end

  def test_realtime_change_retunes_sounding_notes
    state = MIDI::TuningState.new
    state.note_on(60)
    state.note_on(64)

    change = MIDI::SingleNoteTuningChange.new({ 60 => 60.25, 64 => 64.25, 67 => 67.25 },
                                              realtime: true)
    retune = state.apply(change)
    assert_equal([60, 64], retune.sort)
    assert_in_delta(60.25, state.tuning[60], 1e-9)
  end

  def test_non_realtime_change_leaves_sounding_notes_alone
    state = MIDI::TuningState.new
    state.note_on(60)

    change = MIDI::SingleNoteTuningChange.new({ 60 => 60.5 }, realtime: false)
    retune = state.apply(change)
    assert_equal([], retune)
    # The table itself is updated for future note-ons.
    assert_in_delta(60.5, state.tuning[60], 1e-9)
  end

  def test_bulk_dump_apply_replaces_table_without_retuning
    state = MIDI::TuningState.new
    state.note_on(60)
    retune = state.apply(microtuned_tuning.to_bulk_dump)
    assert_equal([], retune)
    assert_in_delta(60.5, state.tuning[60], 1e-9)
  end

  def test_no_change_entry_is_skipped_on_apply
    state = MIDI::TuningState.new
    before = state.tuning[64]
    state.apply(MIDI::SingleNoteTuningChange.new({ 64 => :no_change }, realtime: true))
    assert_equal(before, state.tuning[64])
  end

  def test_smf_roundtrip_through_sequence_io
    tuning = microtuned_tuning
    seq = MIDI::Sequence.new
    track = MIDI::Track.new(seq)
    seq.tracks << track
    track.events << tuning.to_bulk_dump(device_id: MIDI::SYSEX_ALL_DEVICES)
    track.events << tuning.to_single_note_change([60, 64], realtime: false)
    track.events << MIDI::NoteOn.new(0, 60, 100, 0)
    track.events << MIDI::NoteOff.new(0, 60, 64, 480)

    io = StringIO.new
    seq.write(io)

    seq2 = MIDI::Sequence.new
    seq2.read(StringIO.new(io.string))
    sysex_events = seq2.tracks[0].events.select { |event| event.is_a?(MIDI::SystemExclusive) }
    assert_equal(2, sysex_events.length)

    dump = MIDI::MTS.parse(sysex_events[0])
    assert_instance_of(MIDI::TuningBulkDump, dump)
    assert(tuning.equivalent_to?(dump.tuning))

    change = MIDI::MTS.parse(sysex_events[1])
    assert_instance_of(MIDI::SingleNoteTuningChange, change)
    assert(!change.realtime?)
    assert_in_delta(60.5, change.changes[60], TOLERANCE)
    assert_in_delta(63.99, change.changes[64], TOLERANCE)
  end

  def test_mts_parse_returns_nil_for_other_sysex
    assert_nil(MIDI::MTS.parse(MIDI::SystemExclusive.new([0x7E, 0x7F, 0x09, 0x01])))
  end
end
