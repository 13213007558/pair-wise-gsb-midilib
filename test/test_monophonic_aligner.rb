require 'test/unit'
require_relative '../lib/midilib'

class MonophonicAlignerTester < Test::Unit::TestCase
  def note_events(specifications)
    specifications.map do |type, pitch, tick|
      if type == :on
        event = MIDI::NoteOn.new(0, pitch, 80, 0)
      elsif type == :on_zero
        event = MIDI::NoteOn.new(0, pitch, 0, 0)
      else
        event = MIDI::NoteOff.new(0, pitch, 64, 0)
      end
      event.time_from_start = tick
      event
    end
  end

  def notes(pitches, ticks)
    pitches.each_with_index.map do |pitch, index|
      MIDI::MonophonicNoteExtractor::Note.new(
        index, :test, pitch, ticks[index], ticks[index] + 10, 0,
        80, 64, nil, nil
      )
    end
  end

  def test_extracts_notes_and_reports_problems
    events = note_events([
      [:on, 60, 0], [:off, 60, 10],
      [:on, 62, 20], [:on, 62, 25], [:off, 62, 30],
      [:off, 64, 50],
      [:on_zero, 66, 60],
      [:on, 68, 70]
    ])

    result = MIDI::MonophonicNoteExtractor.extract(events, source: :human)

    assert_equal(:human, result.source)
    assert_equal([60, 62, 68], result.notes.map(&:note))
    assert_equal([0, 1, 2], result.notes.map(&:id))
    assert_equal([0, 20, 70], result.notes.map(&:on_tick))
    assert_equal([10, 30, nil], result.notes.map(&:off_tick))
    assert_equal(events[0], result.notes[0].on_event)
    assert_equal(events[1], result.notes[0].off_event)

    problem_types = result.problems.map(&:type)
    assert_equal([
      :overlapping_same_pitch,
      :unpaired_note_off,
      :unpaired_note_off,
      :unpaired_note_on
    ], problem_types)
    assert_equal([62, 64, 66, 68], result.problems.map(&:note))
    assert_equal([25, 50, 60, 70], result.problems.map(&:tick))
    assert(result.problems.all? { |problem| problem.source == :human })
  end

  def test_aligns_wrong_note_insertion_and_deletion
    reference = notes([60, 62, 64, 66], [0, 100, 200, 300])
    performance = notes([60, 64, 66, 67], [0, 100, 200, 300])

    result = MIDI::MonophonicAligner.align(
      reference, performance,
      wrong_note_cost: 100,
      insertion_cost: 7,
      deletion_cost: 5,
      time_deviation_cost: 0
    )

    assert_equal([[60, 60], [64, 64], [66, 66]],
                 result.pairs.map { |pair| [pair.reference_note.note,
                                           pair.performance_note.note] })
    assert_equal([62], result.unmatched_reference_notes.map { |item| item.note.note })
    assert_equal([67], result.unmatched_performance_notes.map { |item| item.note.note })
    assert_equal([:reference, :performance], result.unmatched_notes.map(&:side))
    assert_equal(12, result.total_cost)
    assert_equal(false, result.restricted_optimum)
    assert_nil(result.bandwidth)
  end

  def test_inserted_ornament_after_slowdown_does_not_shift_later_notes
    reference = notes([60, 62, 64, 65], [0, 100, 200, 300])
    performance = notes([60, 72, 62, 64, 65], [0, 50, 100, 300, 600])

    result = MIDI::MonophonicAligner.align(
      reference, performance,
      wrong_note_cost: 100,
      insertion_cost: 1,
      deletion_cost: 100,
      time_deviation_cost: 0.01
    )

    assert_equal([[60, 60], [62, 62], [64, 64], [65, 65]],
                 result.pairs.map { |pair| [pair.reference_note.note,
                                           pair.performance_note.note] })
    assert_equal([72], result.unmatched_performance_notes.map { |item| item.note.note })
    assert_equal([:performance], result.unmatched_notes.map(&:side))
    assert_in_delta(5.0, result.total_cost, 0.000001)
    assert_equal([1.0, 2.0, 3.0],
                 result.timing_map.segments.map(&:slope_to_next).compact)
    assert_in_delta(50.0, result.timing_map[50], 0.000001)
    assert_in_delta(200.0, result.timing_map[150], 0.000001)
    assert_in_delta(450.0, result.timing_map[250], 0.000001)
  end

  def test_exhaustive_alignment_checks_dp_cost_and_fixed_tie_order
    reference = notes([60, 64], [0, 100])
    performance = notes([64, 66], [0, 100])
    costs = {
      wrong_note_cost: 1,
      insertion_cost: 1,
      deletion_cost: 1,
      time_deviation_cost: 0
    }

    dp_result = MIDI::MonophonicAligner.align(reference, performance, **costs)
    exhaustive_result =
      MIDI::MonophonicAligner.align_exhaustively(reference, performance, **costs)
    operations = MIDI::MonophonicAligner.each_alignment(
      reference, performance
    ).to_a

    assert_equal(13, operations.length)
    assert_equal(exhaustive_result.total_cost, dp_result.total_cost)
    assert_equal(2, dp_result.pairs.length)
    assert_equal([[60, 64], [64, 66]],
                 dp_result.pairs.map { |pair| [pair.reference_note.note,
                                               pair.performance_note.note] })
    assert_equal(dp_result.pairs.map(&:cost),
                 exhaustive_result.pairs.map(&:cost))
  end

  def test_fixed_tie_order_matches_exhaustive_prefix_order
    reference = notes([60, 62], [0, 100])
    performance = notes([60, 64], [0, 100])
    costs = {
      wrong_note_cost: 1,
      insertion_cost: 1,
      deletion_cost: 1,
      time_deviation_cost: 0
    }

    dp_result = MIDI::MonophonicAligner.align(reference, performance, **costs)
    exhaustive_result =
      MIDI::MonophonicAligner.align_exhaustively(reference, performance, **costs)

    assert_equal([[60, 60], [62, 64]],
                 dp_result.pairs.map { |pair| [pair.reference_note.note,
                                               pair.performance_note.note] })
    assert_equal(exhaustive_result.pairs.map(&:cost),
                 dp_result.pairs.map(&:cost))
  end

  def test_dp_matches_exhaustive_cost_on_random_short_melodies
    random = Random.new(9182)
    costs = {
      wrong_note_cost: 4,
      insertion_cost: 3,
      deletion_cost: 5,
      time_deviation_cost: 0.01
    }

    25.times do
      reference_size = random.rand(0..5)
      performance_size = random.rand(0..5)
      reference = Array.new(reference_size) do |index|
        pitch = random.rand(60..67)
        tick = index * 100 + random.rand(-5..5)
        MIDI::MonophonicNoteExtractor::Note.new(
          index, :reference, pitch, tick, tick + 10, 0, 80, 64, nil, nil
        )
      end
      performance = Array.new(performance_size) do |index|
        pitch = random.rand(60..67)
        tick = index * 100 + random.rand(-20..20)
        MIDI::MonophonicNoteExtractor::Note.new(
          index, :performance, pitch, tick, tick + 10, 0, 80, 64, nil, nil
        )
      end

      dp_result = MIDI::MonophonicAligner.align(reference, performance, **costs)
      exhaustive_result =
        MIDI::MonophonicAligner.align_exhaustively(reference, performance, **costs)

      assert_in_delta(exhaustive_result.total_cost, dp_result.total_cost,
                      0.000001)
    end
  end

  def test_bandwidth_can_produce_restricted_optimum
    reference = notes([60, 62, 64, 66], [0, 100, 200, 300])
    performance = notes([66, 67, 68, 69], [0, 100, 200, 300])
    costs = {
      wrong_note_cost: 100,
      insertion_cost: 1,
      deletion_cost: 1,
      time_deviation_cost: 0
    }

    global = MIDI::MonophonicAligner.align(reference, performance, **costs)
    restricted = MIDI::MonophonicAligner.align(
      reference, performance, **costs.merge(bandwidth: 0)
    )

    assert_equal(6, global.total_cost)
    assert_equal(false, global.restricted_optimum)
    assert(restricted.total_cost > global.total_cost)
    assert_equal(true, restricted.restricted_optimum)
    assert_equal(0, restricted.bandwidth)
  end

  def test_bandwidth_that_still_contains_global_optimum_is_not_restricted
    reference = notes([60, 62, 64], [0, 100, 200])
    performance = notes([60, 62, 65], [0, 100, 200])

    result = MIDI::MonophonicAligner.align(
      reference, performance,
      wrong_note_cost: 5,
      insertion_cost: 10,
      deletion_cost: 10,
      time_deviation_cost: 0,
      bandwidth: 2
    )

    assert_equal(5, result.total_cost)
    assert_equal(false, result.restricted_optimum)
    assert_equal(2, result.bandwidth)
  end

  def test_rejects_impossible_bandwidth
    reference = notes([60, 62, 64], [0, 100, 200])
    performance = notes([60], [0])

    assert_raise(ArgumentError) do
      MIDI::MonophonicAligner.align(
        reference, performance,
        wrong_note_cost: 1,
        insertion_cost: 1,
        deletion_cost: 1,
        time_deviation_cost: 0,
        bandwidth: 0
      )
    end
  end

  def test_callable_costs
    reference = notes([60, 62], [0, 100])
    performance = notes([60, 64], [0, 130])

    result = MIDI::MonophonicAligner.align(
      reference, performance,
      wrong_note_cost: ->(_reference_note, _performance_note) { 9 },
      insertion_cost: ->(_note) { 40 },
      deletion_cost: ->(_note) { 40 },
      time_deviation_cost: ->(deviation) { deviation * 2 }
    )

    assert_equal(69, result.total_cost)
    assert_equal(9, result.pairs.last.wrong_note_cost)
    assert_equal(60, result.pairs.last.time_cost)
  end
end
