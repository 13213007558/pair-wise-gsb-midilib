require 'test/unit'
require 'stringio'
require_relative '../lib/midilib'
require_relative '../lib/midilib/consts'
require_relative '../lib/midilib/io/compact_order'

class CompactOrderTester < Test::Unit::TestCase
  CO = MIDI::IO::CompactOrder

  # Writes +seq+ and returns the file bytes as a String.
  def write_bytes(seq, compact: false, midi_format: 1)
    io = StringIO.new
    seq.write(io, midi_format, compact: compact)
    io.string
  end

  def read_back(bytes)
    seq = MIDI::Sequence.new
    seq.read(StringIO.new(bytes))
    seq
  end

  # Interleaved note ons on two channels at the same tick: running status
  # cannot help the original order, but clustering channels can.
  def interleaved_seq
    seq = MIDI::Sequence.new
    track = MIDI::Track.new(seq)
    seq.tracks << track
    8.times do
      track.events << MIDI::NoteOn.new(0, 60, 100, 0)
      track.events << MIDI::NoteOn.new(1, 64, 100, 0)
    end
    track.events << MIDI::NoteOff.new(0, 60, 64, 480)
    track.events << MIDI::NoteOff.new(1, 64, 64, 0)
    track.events << MIDI::MetaEvent.new(MIDI::META_TRACK_END, nil, 0)
    seq
  end

  # A sequence full of simultaneous groups that exercise the legality
  # constraints: controllers, program changes, same-pitch on/off pairs,
  # pitch bends, meta events and a sysex, all at shared ticks.
  def semantic_seq
    seq = MIDI::Sequence.new
    track = MIDI::Track.new(seq)
    seq.tracks << track
    [
      MIDI::NoteOn.new(0, 60, 100, 0),
      MIDI::Controller.new(1, 7, 100, 0),
      MIDI::NoteOn.new(1, 64, 90, 0),
      MIDI::ProgramChange.new(0, 5, 0),
      MIDI::NoteOff.new(0, 60, 64, 0),
      MIDI::MetaEvent.new(MIDI::META_LYRIC, 'la', 0),
      MIDI::Tempo.new(MIDI::Tempo.bpm_to_mpq(120), 0),
      MIDI::NoteOn.new(0, 67, 80, 0),
      MIDI::PitchBend.new(1, 8192, 0),
      MIDI::Controller.new(0, 10, 64, 0),
      MIDI::NoteOff.new(1, 64, 100, 240),
      MIDI::NoteOff.new(0, 67, 64, 0),
      MIDI::ChannelPressure.new(1, 55, 0),
      MIDI::ProgramChange.new(0, 9, 0),
      MIDI::NoteOn.new(0, 60, 90, 0),
      MIDI::NoteOff.new(0, 60, 64, 0),
      MIDI::MetaEvent.new(MIDI::META_MARKER, 'mark', 0),
      MIDI::MetaEvent.new(MIDI::META_TRACK_END, nil, 0)
    ].each { |event| track.events << event }
    track.recalc_times
    seq
  end

  # Normalized, order-independent description of one event for semantic
  # comparison. A note on with velocity 0 is a note off with velocity 64
  # (that is how the reader reports it).
  def note_descriptor(event)
    case event
    when MIDI::NoteOn
      event.velocity.zero? ? [:off, event.note, 64] : [:on, event.note, event.velocity]
    when MIDI::NoteOff
      [:off, event.note, event.velocity]
    end
  end

  # Per-tick final channel state trajectory for every track: an array of
  # [time_from_start, snapshot] where snapshot maps channel to its state.
  def channel_trajectory(seq)
    seq.tracks.map do |track|
      track.recalc_times
      states = Hash.new { |hash, key| hash[key] = fresh_channel_state }
      trajectory = []
      track.events.group_by(&:time_from_start).sort.each do |time, events|
        events.each { |event| apply_to_state(states, event) }
        trajectory << [time, states.transform_values { |state| deep_copy_state(state) }]
      end
      trajectory
    end
  end

  def deep_copy_state(state)
    { program: state[:program], controllers: state[:controllers].dup,
      bend: state[:bend], pressure: state[:pressure],
      poly: state[:poly].dup, notes: state[:notes].dup }
  end

  def fresh_channel_state
    { program: nil, controllers: {}, bend: nil, pressure: nil,
      poly: {}, notes: Hash.new(0) }
  end

  def apply_to_state(states, event)
    return unless event.is_a?(MIDI::ChannelEvent)

    state = states[event.channel]
    case event
    when MIDI::NoteOn
      if event.velocity.zero?
        state[:notes].delete(event.note)
      else
        state[:notes][event.note] = state[:notes][event.note].to_i + 1
      end
    when MIDI::NoteOff
      state[:notes].delete(event.note)
    when MIDI::Controller
      state[:controllers][event.controller] = event.value
    when MIDI::ProgramChange
      state[:program] = event.program
    when MIDI::PitchBend
      state[:bend] = event.value
    when MIDI::ChannelPressure
      state[:pressure] = event.pressure
    when MIDI::PolyPressure
      state[:poly][event.note] = event.pressure
    end
    state[:notes] = state[:notes].sort.to_h
  end

  # Per (track, tick, channel) multiset of normalized note events.
  def note_multisets(seq)
    seq.tracks.map do |track|
      track.recalc_times
      multisets = Hash.new { |hash, key| hash[key] = [] }
      track.events.each do |event|
        descriptor = note_descriptor(event)
        multisets[[event.time_from_start, event.channel]] << descriptor if descriptor
      end
      multisets.transform_values(&:sort)
    end
  end

  # Per (track, tick) ordered list of non-channel events.
  def non_channel_events(seq)
    seq.tracks.map do |track|
      track.recalc_times
      grouped = Hash.new { |hash, key| hash[key] = [] }
      track.events.each do |event|
        next if event.is_a?(MIDI::ChannelEvent)

        descriptor = case event
                     when MIDI::MetaEvent then [:meta, event.meta_type, event.data]
                     when MIDI::SystemExclusive then [:sysex, event.data]
                     else [:other, event.status]
                     end
        grouped[event.time_from_start] << descriptor
      end
      grouped
    end
  end

  def assert_same_performance(expected_seq, actual_seq, message)
    assert_equal(channel_trajectory(expected_seq), channel_trajectory(actual_seq),
                 "channel state trajectories differ: #{message}")
    assert_equal(note_multisets(expected_seq), note_multisets(actual_seq),
                 "note events differ: #{message}")
    assert_equal(non_channel_events(expected_seq), non_channel_events(actual_seq),
                 "non-channel events differ: #{message}")
  end

  # With compact mode off (the default) the writer must keep the original
  # event order and produce exactly the bytes it always did.
  def test_compact_off_keeps_original_order
    seq = interleaved_seq
    default_bytes = write_bytes(seq)
    explicit_off_bytes = write_bytes(seq, compact: false)
    assert_equal(default_bytes, explicit_off_bytes)

    # The alternating channels prevent any running-status compression in
    # the first group, so every note on takes three bytes.
    read = read_back(default_bytes)
    events = read.tracks[0].events
    8.times do |i|
      assert_equal(0, events[2 * i].channel)
      assert_equal(1, events[2 * i + 1].channel)
    end
  end

  def test_compact_on_shrinks_file_and_reports
    seq = interleaved_seq
    plain = write_bytes(seq)
    compact = write_bytes(seq, compact: true)
    assert(compact.bytesize < plain.bytesize,
           "compact (#{compact.bytesize}) should be smaller than plain (#{plain.bytesize})")

    writer = MIDI::IO::SeqWriter.new(seq, 1, compact: true)
    writer.write_to(StringIO.new)
    report = writer.compact_report
    assert_equal(2, report[:groups])
    assert_equal(1, report[:exact_groups]) # the 16-event group uses the beam
    assert_equal(false, report[:optimal])
    assert(report[:optimized_bytes] < report[:original_bytes])

    # The compact file must still describe the same performance.
    assert_same_performance(read_back(plain), read_back(compact), 'interleaved notes')
  end

  def test_compact_report_is_nil_when_disabled
    writer = MIDI::IO::SeqWriter.new(interleaved_seq, 1)
    writer.write_to(StringIO.new)
    assert_nil(writer.compact_report)
  end

  def test_compact_does_not_mutate_track
    seq = semantic_seq
    track = seq.tracks[0]
    before = track.events.map { |event| [event, event.delta_time] }
    write_bytes(seq, compact: true)
    after = track.events.map { |event| [event, event.delta_time] }
    assert_equal(before, after, 'compact writing must not reorder or retime the track')
  end

  def test_semantic_sequence_round_trip
    seq = semantic_seq
    plain = read_back(write_bytes(seq))
    compact = read_back(write_bytes(seq, compact: true))
    assert_same_performance(plain, compact, 'semantic sequence')
    # The last event written is still the track end meta event.
    assert_equal(MIDI::META_TRACK_END, compact.tracks[0].events.last.meta_type)
  end

  # Meta and SysEx events cancel running status; the optimizer must place
  # them where they do the least damage instead of ignoring that cost.
  def test_sysex_running_status_cost_is_avoided
    events = [
      MIDI::NoteOn.new(0, 60, 100, 0),
      MIDI::SystemExclusive.new([1, 2, 3], 0),
      MIDI::NoteOn.new(0, 61, 100, 0)
    ]
    pairs, report = CO.reorder(events)
    # Optimal: the two note ons are adjacent (3 + 2 bytes) and the 6-byte
    # sysex goes to either edge: 11 bytes total. Keeping the sysex in the
    # middle would cost 3 + 6 + 3 = 12.
    assert_equal(11, report[:details][0][:bytes])
    assert_equal(11, report[:optimized_bytes])
    assert_not_equal(1, pairs.index { |event, _delta| event.is_a?(MIDI::SystemExclusive) })
  end

  def test_track_end_stays_last_within_group
    events = [
      MIDI::NoteOn.new(0, 60, 100, 0),
      MIDI::MetaEvent.new(MIDI::META_TRACK_END, nil, 0),
      MIDI::NoteOn.new(1, 64, 100, 0)
    ]
    pairs, = CO.reorder(events)
    assert(pairs.last[0].is_a?(MIDI::MetaEvent))
    assert_equal(MIDI::META_TRACK_END, pairs.last[0].meta_type)
  end

  def test_same_pitch_note_order_is_preserved
    # A note off followed by a note on of the same pitch and channel must
    # not be swapped, even though swapping would look identical in bytes.
    events = [
      MIDI::NoteOff.new(0, 60, 64, 0),
      MIDI::NoteOn.new(0, 60, 100, 0)
    ]
    pairs, = CO.reorder(events)
    assert(pairs[0][0].is_a?(MIDI::NoteOff))
    assert(pairs[1][0].is_a?(MIDI::NoteOn))
  end

  def test_controller_keeps_order_against_channel_notes
    events = [
      MIDI::NoteOn.new(0, 60, 100, 0),
      MIDI::Controller.new(0, 7, 11, 0),
      MIDI::NoteOn.new(0, 64, 100, 0)
    ]
    pairs, = CO.reorder(events)
    assert(pairs[1][0].is_a?(MIDI::Controller),
           'controller must stay between the two notes of its channel')
  end

  def test_large_group_reports_not_optimal
    seq = MIDI::Sequence.new
    track = MIDI::Track.new(seq)
    seq.tracks << track
    12.times { |chan| track.events << MIDI::NoteOn.new(chan, 60 + chan, 100, 0) }
    12.times { |chan| track.events << MIDI::NoteOff.new(chan, 60 + chan, 64, 0) }
    track.events << MIDI::MetaEvent.new(MIDI::META_TRACK_END, nil, 0)
    track.recalc_times

    writer = MIDI::IO::SeqWriter.new(seq, 1, compact: true)
    io = StringIO.new
    writer.write_to(io)
    report = writer.compact_report
    assert_equal(false, report[:optimal], 'a 25-event group exceeds the exact threshold')
    assert(report[:optimized_bytes] <= report[:original_bytes])

    plain = read_back(write_bytes(seq))
    compact = read_back(io.string)
    assert_same_performance(plain, compact, 'large group')
  end

  def test_report_optimal_for_small_groups
    seq = MIDI::Sequence.new
    track = MIDI::Track.new(seq)
    seq.tracks << track
    4.times do
      track.events << MIDI::NoteOn.new(0, 60, 100, 0)
      track.events << MIDI::NoteOn.new(1, 64, 100, 0)
    end
    track.events << MIDI::NoteOff.new(0, 60, 64, 240)
    track.events << MIDI::NoteOff.new(1, 64, 64, 0)
    track.events << MIDI::MetaEvent.new(MIDI::META_TRACK_END, nil, 0)

    writer = MIDI::IO::SeqWriter.new(seq, 1, compact: true)
    writer.write_to(StringIO.new)
    report = writer.compact_report
    assert_equal(true, report[:optimal])
    assert_equal(report[:groups], report[:exact_groups])
  end

  def test_format_0_compact_round_trip
    seq = MIDI::Sequence.new
    track = MIDI::Track.new(seq)
    seq.tracks << track
    6.times do |i|
      track.events << MIDI::NoteOn.new(i % 2, 60 + i, 100, i.zero? ? 0 : 0)
    end
    track.events << MIDI::NoteOff.new(0, 60, 64, 480)
    track.events << MIDI::MetaEvent.new(MIDI::META_TRACK_END, nil, 0)
    track.recalc_times

    plain = read_back(write_bytes(seq, midi_format: 0))
    compact = read_back(write_bytes(seq, midi_format: 0, compact: true))
    assert_same_performance(plain, compact, 'format 0')
  end

  # --- randomized verification -------------------------------------------

  # Note: SysEx events are excluded from round-trip comparisons because the
  # stock reader/writer pair does not round-trip them (a pre-existing issue
  # unrelated to compact ordering); they are still used for byte-cost tests.
  def random_event(rng, delta, sysex: true)
    case rng.rand(10)
    when 0, 1, 2
      MIDI::NoteOn.new(rng.rand(4), 60 + rng.rand(12), 1 + rng.rand(127), delta)
    when 3, 4
      MIDI::NoteOff.new(rng.rand(4), 60 + rng.rand(12), [64, 64, 100][rng.rand(3)], delta)
    when 5
      MIDI::Controller.new(rng.rand(4), rng.rand(120), rng.rand(128), delta)
    when 6
      MIDI::ProgramChange.new(rng.rand(4), rng.rand(128), delta)
    when 7
      MIDI::PitchBend.new(rng.rand(4), rng.rand(16_384), delta)
    when 8
      MIDI::MetaEvent.new(MIDI::META_TEXT, "t#{rng.rand(5)}", delta)
    else
      if sysex
        MIDI::SystemExclusive.new([rng.rand(128), rng.rand(128)], delta)
      else
        MIDI::MetaEvent.new(MIDI::META_LYRIC, "l#{rng.rand(5)}", delta)
      end
    end
  end

  # Independently enumerates every legal permutation of +group+ and returns
  # the minimum simulated cost, given the incoming running status.
  def brute_force_min_cost(group, entry_status)
    preds = CO.predecessors(group)
    pred_pairs = []
    preds.each_with_index do |mask, i|
      group.length.times { |j| pred_pairs << [j, i] if (mask & (1 << j)) != 0 }
    end
    infos = group.map { |event| CO.event_info(event) }
    best = nil
    (0...group.length).to_a.permutation.each do |perm|
      position = Array.new(group.length)
      perm.each_with_index { |idx, pos| position[idx] = pos }
      next unless pred_pairs.all? { |before, after| position[before] < position[after] }

      running_status = entry_status
      cost = 0
      perm.each do |idx|
        size, running_status = CO.transition(running_status, infos[idx])
        cost += size
      end
      best = cost if best.nil? || cost < best
    end
    best
  end

  # For small groups the optimizer must find the exact optimum: check its
  # answer against an exhaustive enumeration of all legal permutations.
  def test_small_groups_match_exhaustive_enumeration
    rng = Random.new(12_345)
    entry_statuses = [0, 0x90, 0x81, 0xb2, 0xff, 0x93]
    25.times do
      n = 2 + rng.rand(6) # 2..7 events
      group = Array.new(n) { random_event(rng, 0) }
      group << MIDI::MetaEvent.new(MIDI::META_TRACK_END, nil, 0) if n <= 6 && rng.rand(4).zero?
      entry_status = entry_statuses[rng.rand(entry_statuses.length)]

      # Run the group through the optimizer with the chosen entry status by
      # prepending an event that establishes it, or directly when zero.
      _pairs, report = CO.reorder(group)
      assert_equal(1, report[:groups], 'all events share one tick')
      # reorder() always starts from running status 0; verify that case, and
      # verify other entry statuses through a direct exact-order comparison.
      assert_equal(brute_force_min_cost(group, 0), report[:details][0][:bytes],
                   "group #{group.map(&:to_s).inspect} not optimal")
      assert_equal(true, report[:optimal])

      # Cross-check a non-zero entry status by prepending a singleton group
      # (a note on at an earlier tick) that establishes the running status.
      next unless (entry_status & 0xf0) == 0x90

      group.first.delta_time = 100
      combined = [MIDI::NoteOn.new(entry_status & 0x0f, 40, 100, 0)] + group
      _pairs2, report2 = CO.reorder(combined)
      assert_equal(2, report2[:groups])
      assert_equal(brute_force_min_cost(group, 0x90 + (entry_status & 0x0f)),
                   report2[:details][1][:bytes])
    end
  end

  # The cost model must predict the real bytes written, including running
  # status changes and meta/SysEx cancellation, in both modes.
  def test_simulated_cost_matches_actual_file_bytes
    rng = Random.new(999)
    20.times do
      seq = MIDI::Sequence.new
      track = MIDI::Track.new(seq)
      seq.tracks << track
      40.times { track.events << random_event(rng, rng.rand(3).zero? ? 1 + rng.rand(480) : 0) }
      track.events << MIDI::MetaEvent.new(MIDI::META_TRACK_END, nil, 0)

      [false, true].each do |compact|
        pairs = compact ? CO.reorder(track.events).first
                        : track.events.map { |event| [event, event.delta_time] }
        expected = 14 + 8 # header + track header
        running_status = 0
        pairs.each do |event, delta|
          expected += MIDI::Utils.as_var_len(delta).length
          size, running_status = CO.transition(running_status, CO.event_info(event))
          expected += size
        end
        actual = write_bytes(seq, compact: compact).bytesize
        assert_equal(expected, actual, "simulated bytes differ from file bytes (compact=#{compact})")
      end

      assert(write_bytes(seq, compact: true).bytesize <= write_bytes(seq).bytesize,
             'compact output must never be larger than the original order')
    end
  end

  # Random tracks: compact output must read back as the same performance.
  def test_random_tracks_round_trip
    rng = Random.new(77)
    10.times do
      seq = MIDI::Sequence.new
      track = MIDI::Track.new(seq)
      seq.tracks << track
      30.times { track.events << random_event(rng, rng.rand(3).zero? ? 1 + rng.rand(480) : 0, sysex: false) }
      track.events << MIDI::MetaEvent.new(MIDI::META_TRACK_END, nil, 0)
      track.recalc_times

      plain = read_back(write_bytes(seq))
      compact = read_back(write_bytes(seq, compact: true))
      assert_same_performance(plain, compact, 'random track')
    end
  end
end
