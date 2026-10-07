require 'test/unit'
require_relative '../lib/midilib'

class AlignerTester < Test::Unit::TestCase
  PPQN = 480

  def setup
    @align = MIDI::Aligner
  end

  # Builds a track from [pitch, start_tick, duration] triples. Note-offs
  # are ordered before note-ons at the same tick.
  def make_track(note_specs, name = 'track')
    seq = MIDI::Sequence.new
    track = MIDI::Track.new(seq)
    events = []
    note_specs.each_with_index do |(pitch, start, length), idx|
      events << [start, 1, idx, MIDI::NoteOn.new(0, pitch, 100, 0)]
      events << [start + length, 0, idx, MIDI::NoteOff.new(0, pitch, 64, 0)]
    end
    events.sort_by! { |tick, order, idx, _| [tick, order, idx] }
    previous = 0
    events.each do |tick, _, _, event|
      event.delta_time = tick - previous
      previous = tick
      track.events << event
    end
    track.recalc_times
    track.name = name
    track
  end

  def make_notes(note_specs)
    note_specs.map do |pitch, start, length|
      MIDI::Aligner::Note.new(pitch, start, start + length, 'test', nil, nil)
    end
  end

  # === Extraction ===

  def test_extract_basic_notes_with_source
    track = make_track([[60, 0, 480], [62, 480, 480]], 'melody')
    extraction = @align.extract_notes(track)
    assert_equal(0, extraction.issues.length)
    assert_equal(2, extraction.notes.length)
    note = extraction.notes.first
    assert_equal(60, note.pitch)
    assert_equal(0, note.start_tick)
    assert_equal(480, note.end_tick)
    assert_equal('melody', note.source)
    assert_kind_of(MIDI::NoteOn, note.on_event)
    assert_kind_of(MIDI::NoteOff, note.off_event)
  end

  def test_extract_treats_velocity_zero_note_on_as_off
    seq = MIDI::Sequence.new
    track = MIDI::Track.new(seq)
    track.events << MIDI::NoteOn.new(0, 64, 100, 0)
    track.events << MIDI::NoteOn.new(0, 64, 0, 240)
    track.recalc_times
    extraction = @align.extract_notes(track)
    assert_equal(0, extraction.issues.length)
    assert_equal(1, extraction.notes.length)
    assert_equal(240, extraction.notes.first.end_tick)
  end

  def test_extract_reports_same_pitch_overlap
    seq = MIDI::Sequence.new
    track = MIDI::Track.new(seq)
    track.events << MIDI::NoteOn.new(0, 60, 100, 0)
    track.events << MIDI::NoteOn.new(0, 60, 100, 100)
    track.events << MIDI::NoteOff.new(0, 60, 64, 150)
    track.recalc_times
    extraction = @align.extract_notes(track)
    assert_equal(1, extraction.issues.length)
    assert_equal(:overlap, extraction.issues.first.kind)
    assert_equal(60, extraction.issues.first.pitch)
    assert_equal(100, extraction.issues.first.tick)
    # The earlier note is closed when the overlapping note-on arrives.
    assert_equal([[0, 100], [100, 250]],
                 extraction.notes.map { |n| [n.start_tick, n.end_tick] })
  end

  def test_extract_reports_unpaired_events
    seq = MIDI::Sequence.new
    track = MIDI::Track.new(seq)
    track.events << MIDI::NoteOff.new(0, 55, 64, 0)
    track.events << MIDI::NoteOn.new(0, 60, 100, 100)
    track.events << MIDI::NoteOn.new(0, 62, 100, 100)
    track.events << MIDI::NoteOff.new(0, 62, 64, 100)
    track.recalc_times
    extraction = @align.extract_notes(track)
    kinds = extraction.issues.map(&:kind)
    assert_equal(%i[unpaired_note_off unpaired_note_on], kinds.sort)
    # The unpaired note-on is closed at the track's last event tick.
    dangling = extraction.notes.find { |n| n.pitch == 60 }
    assert_equal(300, dangling.end_tick)
    assert_nil(dangling.off_event)
  end

  # === Alignment ===

  def test_align_identical_sequences
    specs = [[60, 0, 480], [62, 480, 480], [64, 960, 480]]
    result = @align.align(make_notes(specs), make_notes(specs),
                          substitute: 5, insert: 3, delete: 3)
    assert_equal(0, result.cost)
    assert_equal(false, result.restricted)
    assert_equal(3, result.matches.length)
    assert_empty(result.unmatched_reference)
    assert_empty(result.unmatched_performance)
  end

  def test_align_reports_insertions_deletions_and_substitutions
    ref = make_notes([[60, 0, 480], [62, 480, 480], [64, 960, 480]])
    perf = make_notes([[60, 0, 480], [63, 480, 480], [64, 960, 480], [66, 1440, 480]])
    result = @align.align(ref, perf, substitute: 5, insert: 3, delete: 1)
    assert_equal([62], result.unmatched_reference.map(&:pitch))
    assert_equal([63, 66], result.unmatched_performance.map(&:pitch))
    assert_equal(1 + 3 + 3, result.cost)
  end

  def test_align_tie_break_prefers_match_then_delete
    ref = make_notes([[60, 0, 480]])
    perf = make_notes([[61, 0, 480]])
    # substitute (2) == delete + insert (1 + 1): fixed order picks the match.
    result = @align.align(ref, perf, substitute: 2, insert: 1, delete: 1)
    assert_equal(1, result.matches.length)
    assert_equal(2, result.cost)
  end

  def test_align_matches_brute_force_on_short_melodies
    rng = Random.new(42)
    20.times do
      ref = random_notes(rng, rng.rand(1..5))
      perf = random_notes(rng, rng.rand(1..5))
      sub = rng.rand(1..6)
      ins = rng.rand(1..4)
      del = rng.rand(1..4)
      per_tick = rng.rand(0..3) * 0.01
      time_fn = ->(diff) { per_tick * diff }
      result = @align.align(ref, perf, substitute: sub, insert: ins,
                            delete: del, time: time_fn)
      expected = brute_force_cost(ref, perf, sub, ins, del, time_fn)
      assert_in_delta(expected, result.cost, 1e-9,
                      "dp cost #{result.cost} != brute force #{expected} " +                      "for #{ref.map(&:pitch)} vs #{perf.map(&:pitch)}")
    end
  end

  def test_align_slowdown_and_ornament
    pitches = [60, 62, 64, 65, 67, 69, 71, 72]
    ref_specs = pitches.each_with_index.map { |p, i| [p, i * PPQN, PPQN] }
    # Performance: first three notes on time, then an inserted ornament,
    # then the remaining notes at half speed (twice the spacing).
    perf_specs = pitches.first(3).each_with_index.map { |p, i| [p, i * PPQN, PPQN] }
    perf_specs << [76, 3 * PPQN, 120] # ornament
    pitches[3..].each_with_index do |p, k|
      perf_specs << [p, 3 * PPQN + 120 + k * 2 * PPQN, 2 * PPQN - 120]
    end

    ref_track = make_track(ref_specs, 'reference')
    perf_track = make_track(perf_specs, 'performance')
    ref = @align.extract_notes(ref_track).notes
    perf = @align.extract_notes(perf_track).notes

    result = @align.align(ref, perf, substitute: 5, insert: 3, delete: 3,
                          time: ->(diff) { diff * 0.001 })

    # The ornament is reported as an extra performance note...
    assert_equal([76], result.unmatched_performance.map(&:pitch))
    assert_empty(result.unmatched_reference)
    # ...and every reference note still matches its own pitch in order,
    # so nothing after the ornament is shifted by one.
    assert_equal(pitches, result.matches.map { |r, _| r.pitch })
    assert_equal(pitches, result.matches.map { |_, p| p.pitch })
    # Timing deviation is absorbed by the time cost, not by mismatches.
    assert_in_delta(3 + (120 + 600 + 1080 + 1560 + 2040) * 0.001, result.cost, 1e-9)

    # The tick map follows the slowdown and stays monotonic.
    map = result.tick_map
    assert_equal(0, map.map(0))
    assert_equal(3 * PPQN - PPQN, map.map(3 * PPQN - PPQN))
    # After the slowdown, reference tick 1920 maps to performance tick 2400.
    assert_equal(2400, map.map(4 * PPQN))
    previous = -1
    (0..7 * PPQN).step(60) do |tick|
      value = map.map(tick)
      assert(value >= previous, "tick map not monotonic at #{tick}")
      previous = value
    end
  end

  def test_align_band_marks_result_restricted
    ref = make_notes([[60, 0, 480], [62, 480, 480]])
    perf = make_notes([[62, 0, 480], [60, 480, 480]])
    # Unrestricted: delete + match + insert beats two substitutions.
    free = @align.align(ref, perf, substitute: 5, insert: 1, delete: 1)
    assert_equal(2, free.cost)
    assert_equal(false, free.restricted)
    # A zero-width band forces the diagonal pairing.
    banded = @align.align(ref, perf, substitute: 5, insert: 1, delete: 1, band: 0)
    assert_equal(true, banded.restricted)
    assert_equal(10, banded.cost)
    assert_equal([[60, 62], [62, 60]],
                 banded.matches.map { |r, p| [r.pitch, p.pitch] })
  end

  def test_align_band_too_narrow_raises
    ref = make_notes([[60, 0, 480], [62, 480, 480], [64, 960, 480]])
    perf = make_notes([[60, 0, 480]])
    assert_raise(ArgumentError) do
      @align.align(ref, perf, band: 1)
    end
  end

  def test_tick_map_empty_without_matches
    ref = make_notes([[60, 0, 480]])
    result = @align.align(ref, [], delete: 1)
    assert_nil(result.tick_map.map(0))
    assert_equal(1, result.unmatched_reference.length)
  end

  # === Helpers ===

  def random_notes(rng, count)
    notes = []
    tick = 0
    count.times do
      length = (rng.rand(1..4)) * 120
      notes << MIDI::Aligner::Note.new(rng.rand(60..64), tick, tick + length,
                                       'test', nil, nil)
      tick += length + rng.rand(0..2) * 60
    end
    notes
  end

  # Exhaustively enumerates every monotonic alignment and returns the
  # minimum total cost.
  def brute_force_cost(ref, perf, sub, ins, del, time_fn)
    memo = {}
    walk = lambda do |i, j|
      next 0 if i == ref.length && j == perf.length

      key = [i, j]
      next memo[key] if memo.key?(key)

      best = Float::INFINITY
      if i < ref.length && j < perf.length
        pitch_cost = ref[i].pitch == perf[j].pitch ? 0 : sub
        deviation = time_fn.call((perf[j].start_tick - ref[i].start_tick).abs)
        best = [best, pitch_cost + deviation + walk.call(i + 1, j + 1)].min
      end
      best = [best, del + walk.call(i + 1, j)].min if i < ref.length
      best = [best, ins + walk.call(i, j + 1)].min if j < perf.length
      memo[key] = best
    end
    walk.call(0, 0)
  end
end
