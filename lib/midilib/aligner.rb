require_relative 'event'
require_relative 'track'

module MIDI
  # Aligns a monophonic reference melody with a monophonic performance.
  #
  # The typical workflow is:
  #
  # 1. Turn each track's note-on/note-off events into a list of
  #    Aligner::Note objects with #extract_notes. Overlapping same-pitch
  #    notes and events that cannot be paired are reported as issues.
  # 2. Call #align with caller-supplied costs for wrong pitches
  #    (substitution), extra notes (insertion), missed notes (deletion),
  #    and timing deviation. The result is a global minimum-cost monotonic
  #    pairing of the two note sequences. An optional Sakoe-Chiba band
  #    limits how far the pairing may wander; when a band is given the
  #    result is flagged as only a band-restricted optimum.
  #
  # Input tracks are never modified, quantized, or otherwise rewritten.
  module Aligner
    # A single note reconstructed from a note-on/note-off event pair.
    # +source+ identifies where the note came from (defaults to the track
    # name); +on_event+ and +off_event+ are the original MIDI events.
    Note = Struct.new(:pitch, :start_tick, :end_tick, :source, :on_event, :off_event) do
      def duration
        end_tick - start_tick
      end

      def to_s
        "Note(#{pitch} #{start_tick}..#{end_tick} #{source})"
      end
    end

    # A problem found while reconstructing notes from events. +kind+ is one
    # of :overlap (a note-on arrived while the same pitch was still
    # sounding), :unpaired_note_on, or :unpaired_note_off.
    ExtractionIssue = Struct.new(:kind, :message, :pitch, :tick, :events)

    # The result of #extract_notes.
    class Extraction
      attr_reader :notes, :issues

      def initialize(notes, issues)
        @notes = notes
        @issues = issues
      end
    end

    # One entry of an alignment. Exactly one of +reference+ and
    # +performance+ is nil for unmatched notes.
    Pair = Struct.new(:reference, :performance)

    # A piecewise-linear, monotonically non-decreasing mapping from
    # reference ticks to performance ticks, built from the matched note
    # boundaries. Ticks outside the anchored range are clamped to the
    # nearest anchor's performance tick.
    class TickMap
      attr_reader :anchors

      # +anchors+ is a sorted list of [reference_tick, performance_tick].
      def initialize(anchors)
        @anchors = anchors
      end

      def empty?
        @anchors.empty?
      end

      # Map a reference tick to a performance tick. Returns nil when the
      # map has no anchors (no matched notes).
      def map(ref_tick)
        return nil if @anchors.empty?
        return @anchors.first[1] if ref_tick <= @anchors.first[0]
        return @anchors.last[1] if ref_tick >= @anchors.last[0]

        (1...@anchors.length).each do |i|
          r0, p0 = @anchors[i - 1]
          r1, p1 = @anchors[i]
          next if ref_tick > r1

          return p1 if r1 == r0

          ratio = (ref_tick - r0).to_f / (r1 - r0)
          return p0 + ratio * (p1 - p0)
        end
        @anchors.last[1]
      end
    end

    # The result of #align.
    class Alignment
      # All pairs in order, including unmatched notes (one side nil).
      attr_reader :pairs
      # Total cost of the alignment.
      attr_reader :cost
      # True when a band limit was supplied, meaning this is only the
      # minimum-cost alignment within the band, not necessarily the global
      # unconstrained optimum.
      attr_reader :restricted
      # Piecewise monotonic reference-tick to performance-tick mapping.
      attr_reader :tick_map

      def initialize(pairs, cost, restricted)
        @pairs = pairs
        @cost = cost
        @restricted = restricted
        @tick_map = TickMap.new(Alignment.build_anchors(pairs))
      end

      # Matched [reference_note, performance_note] pairs, in order.
      def matches
        @pairs.select { |pair| pair.reference && pair.performance }
            .map { |pair| [pair.reference, pair.performance] }
      end

      # Reference notes with no performance counterpart (deletions).
      def unmatched_reference
        @pairs.select { |pair| pair.performance.nil? }.map(&:reference)
      end

      # Performance notes with no reference counterpart (insertions).
      def unmatched_performance
        @pairs.select { |pair| pair.reference.nil? }.map(&:performance)
      end

      def self.build_anchors(pairs)
        anchors = []
        pairs.each do |pair|
          next unless pair.reference && pair.performance

          anchors << [pair.reference.start_tick, pair.performance.start_tick]
          anchors << [pair.reference.end_tick, pair.performance.end_tick]
        end
        anchors = anchors.sort_by.with_index { |(ref_tick, _), i| [ref_tick, i] }
        anchors.chunk_while { |a, b| a[0] == b[0] }.map(&:first)
      end
    end

    module_function

    # Reconstruct the note sequence of a monophonic +track+ from its
    # note-on/note-off events. A NoteOn with velocity 0 is treated as a
    # note-off, per the MIDI convention.
    #
    # Returns an Extraction holding the notes (sorted by start tick,
    # keeping original order for ties) and a list of ExtractionIssue
    # objects. Same-pitch overlaps are reported and the earlier note is
    # closed when the overlapping note-on arrives. Unpaired note-ons are
    # reported and closed at the track's last event tick; unpaired
    # note-offs are reported and produce no note.
    def extract_notes(track, source: nil)
      source ||= track.name
      notes = []
      issues = []
      pending = {} # pitch => NoteOn event
      last_tick = 0

      track.each do |event|
        tick = event.time_from_start
        last_tick = tick if tick > last_tick

        if note_on?(event)
          if (open = pending[event.note])
            issues << ExtractionIssue.new(
              :overlap,
              "note-on for pitch #{event.note} at tick #{tick} while previous note-on at tick #{open.time_from_start} is still open",
              event.note, tick, [open, event]
            )
            notes << Note.new(event.note, open.time_from_start, tick, source, open, nil)
          end
          pending[event.note] = event
        elsif note_off?(event)
          if (on = pending.delete(event.note))
            notes << Note.new(event.note, on.time_from_start, tick, source, on, event)
          else
            issues << ExtractionIssue.new(
              :unpaired_note_off,
              "note-off for pitch #{event.note} at tick #{tick} has no matching note-on",
              event.note, tick, [event]
            )
          end
        end
      end

      pending.each do |pitch, on|
        issues << ExtractionIssue.new(
          :unpaired_note_on,
          "note-on for pitch #{pitch} at tick #{on.time_from_start} has no matching note-off",
          pitch, on.time_from_start, [on]
        )
        notes << Note.new(pitch, on.time_from_start, last_tick, source, on, nil)
      end

      notes = notes.sort_by.with_index { |note, i| [note.start_tick, i] }
      Extraction.new(notes, issues)
    end

    # Compute the global minimum-cost monotonic alignment between two
    # monophonic note sequences.
    #
    # +reference+ and +performance+ are arrays of Aligner::Note (or any
    # objects responding to #pitch and #start_tick).
    #
    # Costs are supplied by the caller:
    # - +substitute+: cost of pairing two notes of different pitch.
    # - +insert+: cost of leaving a performance note unmatched.
    # - +delete+: cost of leaving a reference note unmatched.
    # - +time+: timing deviation cost; a callable receiving the absolute
    #   start-tick difference of a matched pair, or a number interpreted
    #   as the cost per tick of deviation. Defaults to zero.
    #
    # +substitute+, +insert+, and +delete+ may be numbers or callables
    # (substitution callables receive both notes, insertion/deletion
    # callables receive the unmatched note).
    #
    # +band+, when given, restricts the alignment to pairs where the
    # reference and performance indices differ by at most +band+
    # (a Sakoe-Chiba band); the result's +restricted+ flag is then true.
    #
    # Equal-cost choices are resolved by a fixed order: match/substitute
    # first, then deletion, then insertion.
    def align(reference, performance, substitute: 1, insert: 1, delete: 1, time: nil, band: nil)
      n = reference.length
      m = performance.length
      if band && (n - m).abs > band
        raise ArgumentError, "band #{band} too narrow for sequences of length #{n} and #{m}"
      end

      sub_fn = value_or_callable(substitute)
      ins_fn = value_or_callable(insert)
      del_fn = value_or_callable(delete)
      time_fn = timing_cost_fn(time)

      match_cost = lambda do |i, j|
        ref = reference[i]
        perf = performance[j]
        pitch_cost = ref.pitch == perf.pitch ? 0 : sub_fn.call(ref, perf)
        pitch_cost + time_fn.call((perf.start_tick - ref.start_tick).abs)
      end

      inf = Float::INFINITY
      d = Array.new(n + 1) { Array.new(m + 1, inf) }
      d[0][0] = 0
      (0..n).each do |i|
        j_lo = band ? [i - band, 0].max : 0
        j_hi = band ? [i + band, m].min : m
        (j_lo..j_hi).each do |j|
          next if i.zero? && j.zero?

          best = inf
          best = d[i - 1][j - 1] + match_cost.call(i - 1, j - 1) if i.positive? && j.positive?
          if i.positive?
            c = d[i - 1][j] + del_fn.call(reference[i - 1])
            best = c if c < best
          end
          if j.positive?
            c = d[i][j - 1] + ins_fn.call(performance[j - 1])
            best = c if c < best
          end
          d[i][j] = best
        end
      end

      pairs = traceback(d, reference, performance, match_cost, del_fn, ins_fn)
      Alignment.new(pairs, d[n][m], !band.nil?)
    end

    # Walk the DP table from the end, applying the fixed tie-break order
    # (match/substitute, then delete, then insert).
    def traceback(d, reference, performance, match_cost, del_fn, ins_fn)
      pairs = []
      i = reference.length
      j = performance.length
      while i.positive? || j.positive?
        if i.positive? && j.positive? &&
           d[i][j] == d[i - 1][j - 1] + match_cost.call(i - 1, j - 1)
          pairs << Pair.new(reference[i - 1], performance[j - 1])
          i -= 1
          j -= 1
        elsif i.positive? && d[i][j] == d[i - 1][j] + del_fn.call(reference[i - 1])
          pairs << Pair.new(reference[i - 1], nil)
          i -= 1
        else
          pairs << Pair.new(nil, performance[j - 1])
          j -= 1
        end
      end
      pairs.reverse!
    end

    def note_on?(event)
      event.is_a?(MIDI::NoteOn) && event.velocity.positive?
    end

    def note_off?(event)
      event.is_a?(MIDI::NoteOff) ||
        (event.is_a?(MIDI::NoteOn) && event.velocity.zero?)
    end

    def value_or_callable(value)
      value.respond_to?(:call) ? value : ->(*_) { value }
    end

    def timing_cost_fn(time)
      return ->(_diff) { 0 } if time.nil?
      return time if time.respond_to?(:call)

      ->(diff) { time * diff }
    end
  end
end
