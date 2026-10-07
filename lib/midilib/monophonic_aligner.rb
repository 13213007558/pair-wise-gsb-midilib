require_relative 'event'

module MIDI
  # Restores a monophonic stream of note on/off events into notes.
  class MonophonicNoteExtractor
    Note = Struct.new(:id, :source, :note, :on_tick, :off_tick, :channel,
                      :on_velocity, :off_velocity, :on_event, :off_event)

    Problem = Struct.new(:type, :source, :note, :tick, :event, :on_event,
                         :off_event)

    Result = Struct.new(:source, :notes, :problems)

    # Returns paired notes and pairing problems from an event list. Events
    # must already have `time_from_start` values.
    def self.extract(track_or_events, source: :performance)
      events = if track_or_events.respond_to?(:events)
                 track_or_events.events
               else
                 track_or_events
               end
      new(events, source: source).extract
    end

    def initialize(events, source: :performance)
      @events = events
      @source = source
      @active = []
      @problems = []
      @event_order = {}
    end

    def extract
      @events.each_with_index do |event, event_index|
        event = event_with_zero_tick(event, event_index)
        next unless note_event?(event)

        if note_off_event?(event)
          pair_note_off(event)
        else
          pair_note_on(event)
        end
      end

      unpaired_note_ons = @active
      @active = []
      unpaired_note_ons.each do |entry|
        event = entry[:event]
        @problems << Problem.new(:unpaired_note_on, @source,
                                 event.note, event.time_from_start,
                                 event, event, nil)
        paired_notes << Note.new(nil, @source, event.note,
                                 event.time_from_start, nil, event.channel,
                                 event.velocity, nil, event, nil)
      end

      paired_notes.sort_by! do |result|
        [result.on_tick, @event_order[result.on_event.object_id] || 0]
      end
      paired_notes.each_with_index do |note, index|
        note.id = index
      end

      Result.new(@source, paired_notes, @problems)
    end

    private

    def note_event?(event)
      event.is_a?(NoteOn) || event.is_a?(NoteOff)
    end

    def event_with_zero_tick(event, event_index)
      unless event.time_from_start.is_a?(Numeric)
        raise ArgumentError, "event #{event_index} has no time_from_start"
      end

      event
    end

    def note_off_event?(event)
      event.is_a?(NoteOff) || (event.is_a?(NoteOn) && event.velocity.zero?)
    end

    def pair_note_on(event)
      @event_order[event.object_id] = @event_order.length
      existing = @active.find do |entry|
        entry[:event].note == event.note &&
          entry[:event].channel == event.channel
      end
      if existing
        @problems << Problem.new(:overlapping_same_pitch, @source, event.note,
                                 event.time_from_start, event,
                                 existing[:event], nil)
        return
      end

      @active << { event: event }
    end

    def pair_note_off(event)
      index = @active.find_index do |entry|
        entry[:event].note == event.note &&
          entry[:event].channel == event.channel
      end

      unless index
        @problems << Problem.new(:unpaired_note_off, @source, event.note,
                                 event.time_from_start, event, nil, event)
        return
      end

      on = @active.delete_at(index)[:event]
      paired_notes << Note.new(nil, @source, event.note, on.time_from_start,
                               event.time_from_start, event.channel,
                               on.velocity, event.velocity, on, event)
    end

    def paired_notes
      @paired_notes ||= []
    end
  end

  # Globally aligns two ordered monophonic note sequences.
  class MonophonicAligner
    Pair = Struct.new(:reference_note, :performance_note, :cost,
                      :wrong_note_cost, :time_cost)
    UnmatchedNote = Struct.new(:note, :side, :cost)
    Result = Struct.new(:pairs, :unmatched_reference_notes,
                        :unmatched_performance_notes, :unmatched_notes,
                        :total_cost, :timing_map, :bandwidth,
                        :restricted_optimum)

    TimingSegment = Struct.new(:reference_tick, :performance_tick,
                               :reference_note, :performance_note,
                               :slope_to_next)

    # A piecewise-linear, non-decreasing map from reference ticks to
    # performance ticks. Values outside the anchors are held constant.
    class TimingMap
      attr_reader :segments

      def initialize(pairs)
        anchors = pairs.map do |pair|
          [pair.reference_note.on_tick, pair.performance_note.on_tick,
           pair.reference_note, pair.performance_note]
        end
        anchors.uniq! { |reference_tick, _, _| reference_tick }

        @segments = anchors.each_with_index.map do |anchor, index|
          next_anchor = anchors[index + 1]
          slope = if next_anchor
                    delta_reference = next_anchor[0] - anchor[0]
                    delta_performance = next_anchor[1] - anchor[1]
                    delta_performance.to_f / delta_reference
                  else
                    nil
                  end
          TimingSegment.new(anchor[0], anchor[1], anchor[2], anchor[3], slope)
        end
      end

      def [](reference_tick)
        return nil if segments.empty?
        return segments.first.performance_tick if reference_tick <= segments.first.reference_tick

        segments.each_cons(2) do |segment, next_segment|
          next unless reference_tick <= next_segment.reference_tick

          position = (reference_tick - segment.reference_tick).to_f /
                     (next_segment.reference_tick - segment.reference_tick)
          return segment.performance_tick +
                 position * (next_segment.performance_tick - segment.performance_tick)
        end

        segments.last.performance_tick
      end
    end

    # Costs may be numbers or callables. A numeric wrong-note, insertion, or
    # deletion cost is paid once. A numeric time-deviation cost is multiplied
    # by the absolute onset-tick difference. Callables receive the relevant
    # note or notes, except the time callable, which receives the difference.
    def self.align(reference_notes, performance_notes,
                   wrong_note_cost:, insertion_cost:, deletion_cost:,
                   time_deviation_cost:, bandwidth: nil)
      new(reference_notes, performance_notes,
          wrong_note_cost: wrong_note_cost,
          insertion_cost: insertion_cost,
          deletion_cost: deletion_cost,
          time_deviation_cost: time_deviation_cost,
          bandwidth: bandwidth).align
    end

    def initialize(reference_notes, performance_notes, costs = {})
      @reference = Array(reference_notes)
      @performance = Array(performance_notes)
      @wrong_note_cost = costs.fetch(:wrong_note_cost)
      @insertion_cost = costs.fetch(:insertion_cost)
      @deletion_cost = costs.fetch(:deletion_cost)
      @time_deviation_cost = costs.fetch(:time_deviation_cost)
      @bandwidth = costs[:bandwidth]
      validate
    end

    def align
      global_cost, _global_back = solve(nil)
      if @bandwidth.nil?
        @total_cost = global_cost
        @restricted_optimum = false
        operations_from_back(@back)
      else
        banded_cost, _banded_back = solve(@bandwidth)
        @total_cost = banded_cost
        @restricted_optimum = banded_cost > global_cost
        operations_from_back(@back)
      end
    end

    # Enumerates every complete monotonic alignment. The operation order is
    # fixed, making it useful for checking the dynamic program on short songs.
    def self.each_alignment(reference_notes, performance_notes, &block)
      return enum_for(__method__, reference_notes, performance_notes) unless block

      enumerate(reference_notes, performance_notes, [], &block)
    end

    # Finds the optimum by enumerating every monotonic alignment. This is
    # intended for short melodies and tests.
    def self.align_exhaustively(reference_notes, performance_notes,
                                wrong_note_cost:, insertion_cost:,
                                deletion_cost:, time_deviation_cost:)
      aligner = new(reference_notes, performance_notes,
                    wrong_note_cost: wrong_note_cost,
                    insertion_cost: insertion_cost,
                    deletion_cost: deletion_cost,
                    time_deviation_cost: time_deviation_cost)
      best = nil
      each_alignment(reference_notes, performance_notes) do |operations|
        cost = aligner.send(:cost_for_operations, operations)
        best = [cost, operations] if best.nil? || cost < best.first
      end
      aligner.send(:result_for_operations, best.last, best.first, nil, false)
    end

    def self.enumerate(reference_notes, performance_notes, operations, &block)
      reference_index = operations.count { |op| op != :insert }
      performance_index = operations.count { |op| op != :delete }

      if reference_index == reference_notes.length &&
         performance_index == performance_notes.length
        yield operations.dup
        return
      end

      if reference_index < reference_notes.length &&
         performance_index < performance_notes.length
        enumerate(reference_notes, performance_notes,
                  operations + [:match], &block)
      end
      if reference_index < reference_notes.length
        enumerate(reference_notes, performance_notes,
                  operations + [:delete], &block)
      end
      if performance_index < performance_notes.length
        enumerate(reference_notes, performance_notes,
                  operations + [:insert], &block)
      end
    end
    private_class_method :enumerate

    private

    def validate
      unless @bandwidth.nil? || (@bandwidth.integer? && @bandwidth >= 0)
        raise ArgumentError, 'bandwidth must be nil or a non-negative integer'
      end

      if @bandwidth && @bandwidth < (@reference.length - @performance.length).abs
        raise ArgumentError, 'bandwidth is too narrow to align both sequences'
      end
    end

    def solve(bandwidth)
      @dp = Array.new(@reference.length + 1) do
        Array.new(@performance.length + 1, Float::INFINITY)
      end
      @rank = Array.new(@reference.length + 1) do
        Array.new(@performance.length + 1)
      end
      @back = Array.new(@reference.length + 1) do
        Array.new(@performance.length + 1)
      end
      @dp[0][0] = 0
      @rank[0][0] = 0

      (0..@reference.length).each do |reference_index|
        (0..@performance.length).each do |performance_index|
          next if reference_index.zero? && performance_index.zero?
          next unless allowed?(reference_index, performance_index, bandwidth)

          candidates = []
          if reference_index.positive? && performance_index.positive?
            previous_cost = @dp[reference_index - 1][performance_index - 1]
            previous_rank = @rank[reference_index - 1][performance_index - 1]
            unless previous_cost.infinite?
              match_cost = operation_cost(:match, reference_index,
                                         performance_index)
              candidates << [previous_cost + match_cost, :match,
                             (previous_rank.to_i << 2) | 0]
            end
          end
          if reference_index.positive?
            previous_cost = @dp[reference_index - 1][performance_index]
            previous_rank = @rank[reference_index - 1][performance_index]
            unless previous_cost.infinite?
              delete_cost = operation_cost(:delete, reference_index,
                                          performance_index)
              candidates << [previous_cost + delete_cost, :delete,
                             (previous_rank.to_i << 2) | 1]
            end
          end
          if performance_index.positive?
            previous_cost = @dp[reference_index][performance_index - 1]
            previous_rank = @rank[reference_index][performance_index - 1]
            unless previous_cost.infinite?
              insert_cost = operation_cost(:insert, reference_index,
                                          performance_index)
              candidates << [previous_cost + insert_cost, :insert,
                             (previous_rank.to_i << 2) | 2]
            end
          end

          best = candidates.min_by { |cost, _operation, rank| [cost, rank] }
          next if best.nil? || best.first.infinite?

          operation = best[1]
          @dp[reference_index][performance_index] =
            best.first
          @back[reference_index][performance_index] = operation
          @rank[reference_index][performance_index] = best[2]
        end
      end
      [@dp[@reference.length][@performance.length], @back]
    end

    def allowed?(reference_index, performance_index, bandwidth)
      return true if bandwidth.nil?

      (reference_index - performance_index).abs <= bandwidth
    end

    def operation_cost(operation, reference_index, performance_index)
      reference_note = @reference[reference_index - 1]
      performance_note = @performance[performance_index - 1]

      case operation
      when :match
        match_cost(reference_note, performance_note)
      when :delete
        cost_value(@deletion_cost, reference_note)
      when :insert
        cost_value(@insertion_cost, performance_note)
      end
    end

    def match_cost(reference_note, performance_note)
      wrong = if reference_note.note == performance_note.note
                0
              else
                cost_value(@wrong_note_cost, reference_note,
                           performance_note)
              end
      time = time_cost_value(reference_note, performance_note)
      wrong + time
    end

    def time_cost_value(reference_note, performance_note)
      deviation = (reference_note.on_tick - performance_note.on_tick).abs
      if @time_deviation_cost.respond_to?(:call)
        cost_value(@time_deviation_cost, deviation)
      else
        @time_deviation_cost * deviation
      end
    end

    def cost_value(cost, *arguments)
      value = cost.respond_to?(:call) ? cost.call(*arguments) : cost
      raise ArgumentError, 'costs must be non-negative' if value.negative?

      value
    end

    def operations_from_back(back)
      operations = []
      reference_index = @reference.length
      performance_index = @performance.length

      while reference_index.positive? || performance_index.positive?
        operation = back[reference_index][performance_index]
        operations << operation
        reference_index -= 1 unless operation == :insert
        performance_index -= 1 unless operation == :delete
      end
      operations.reverse!
      result_for_operations(operations, @total_cost, @bandwidth,
                            @restricted_optimum)
    end

    def cost_for_operations(operations)
      reference_index = 0
      performance_index = 0
      operations.sum do |operation|
        cost = case operation
               when :match
                 match_cost(@reference[reference_index],
                            @performance[performance_index])
               when :delete
                 cost_value(@deletion_cost, @reference[reference_index])
               when :insert
                 cost_value(@insertion_cost, @performance[performance_index])
               end
        reference_index += 1 unless operation == :insert
        performance_index += 1 unless operation == :delete
        cost
      end
    end

    def result_for_operations(operations, total_cost, bandwidth, restricted)
      pairs = []
      unmatched_reference = []
      unmatched_performance = []
      unmatched_in_order = []
      reference_index = 0
      performance_index = 0
      operations.each do |operation|
        case operation
        when :match
          reference_note = @reference[reference_index]
          performance_note = @performance[performance_index]
          wrong = if reference_note.note == performance_note.note
                    0
                  else
                    cost_value(@wrong_note_cost, reference_note,
                               performance_note)
                  end
          time = time_cost_value(reference_note, performance_note)
          pairs << Pair.new(reference_note, performance_note, wrong + time,
                            wrong, time)
          reference_index += 1
          performance_index += 1
        when :delete
          note = @reference[reference_index]
          unmatched = UnmatchedNote.new(note, :reference,
                                       cost_value(@deletion_cost, note))
          unmatched_reference << unmatched
          unmatched_in_order << unmatched
          reference_index += 1
        when :insert
          note = @performance[performance_index]
          unmatched = UnmatchedNote.new(note, :performance,
                                       cost_value(@insertion_cost, note))
          unmatched_performance << unmatched
          unmatched_in_order << unmatched
          performance_index += 1
        end
      end
      Result.new(pairs, unmatched_reference, unmatched_performance,
                 unmatched_in_order, total_cost, TimingMap.new(pairs),
                 bandwidth, restricted)
    end
  end
end
