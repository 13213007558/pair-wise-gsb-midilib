require_relative '../event'
require_relative '../consts'

module MIDI
  module IO
    # CompactOrder reorders events that share the same start time (delta time
    # zero) so that the written track uses fewer bytes, without changing what
    # the file plays.
    #
    # Legality (performance semantics are preserved):
    #
    # * Events on different MIDI channels may be freely interleaved.
    # * On the same channel, note-keyed events (note on, note off, poly
    #   pressure) keep their relative order only against events of the same
    #   pitch; controllers, program changes, channel pressure and pitch bends
    #   keep their relative order against every other event on their channel,
    #   because they affect the notes around them.
    # * Non-channel events (meta, system exclusive, system common) keep their
    #   relative order among themselves. A track-end meta event is always
    #   written after every other simultaneous event, and channel-prefix /
    #   port-prefix meta events act as barriers against channel events.
    # * Realtime events are never moved; they split simultaneous groups.
    #
    # The cost model mirrors SeqWriter's running-status logic exactly,
    # including the note-off-as-note-on-velocity-0 trick and the fact that
    # meta and SysEx events (any status >= 0xf0) cancel running status.
    #
    # Groups of at most EXACT_THRESHOLD events are ordered optimally with an
    # exact dynamic program over the legal permutations. Larger groups use a
    # beam search bounded to BEAM_WIDTH states per position (O(n^2 * width)
    # work); such groups are flagged as not proven optimal in the report.
    module CompactOrder
      # Groups of this size or smaller are solved exactly.
      EXACT_THRESHOLD = 8
      # Number of states kept per position for larger groups.
      BEAM_WIDTH = 32
      # Meta event type for the (unofficial) port prefix; like the channel
      # prefix it scopes following channel events, so it is a barrier.
      META_PORT_PREFIX = 0x21

      class << self
        # Reorders +events+ (a track's event list, in track order) for a more
        # compact file. Returns [pairs, report] where pairs is an array of
        # [event, delta_time] in write order. Delta times are positional: the
        # first event of a simultaneous group carries the group's delta time.
        #
        # The report hash contains:
        #   optimal:         true if every group was solved exactly
        #   groups:          number of simultaneous groups seen
        #   exact_groups:    number of groups solved exactly
        #   original_bytes:  simulated event-data bytes in original order
        #   optimized_bytes: simulated event-data bytes in reordered order
        #   fallback:        true if the original order was kept because the
        #                    reordered simulation was not smaller
        #   details:         per-group [{size:, optimal:, bytes:}]
        # Byte counts cover event data only (not delta-time var-lens, which
        # reordering never changes).
        def reorder(events, exact_threshold: EXACT_THRESHOLD, beam_width: BEAM_WIDTH)
          pairs = []
          details = []
          optimized_bytes = 0
          running_status = 0

          split_groups(events).each do |group|
            infos = group.map { |event| event_info(event) }
            if group.length == 1
              size, running_status = transition(running_status, infos.first)
              optimized_bytes += size
              pairs << [group.first, group.first.delta_time]
              details << { size: 1, optimal: true, bytes: size }
              next
            end

            order, cost, optimal = optimize_group(infos, group, running_status,
                                                  exact_threshold, beam_width)
            optimized_bytes += cost
            group_delta = group.first.delta_time
            order.each_with_index do |idx, position|
              pairs << [group[idx], position.zero? ? group_delta : 0]
              _size, running_status = transition(running_status, infos[idx])
            end
            details << { size: group.length, optimal: optimal, bytes: cost }
          end

          original_bytes = 0
          running_status = 0
          events.each do |event|
            size, running_status = transition(running_status, event_info(event))
            original_bytes += size
          end

          fallback = optimized_bytes > original_bytes
          if fallback
            pairs = events.map { |event| [event, event.delta_time] }
            optimized_bytes = original_bytes
          end

          report = {
            optimal: details.all? { |d| d[:optimal] },
            groups: details.length,
            exact_groups: details.count { |d| d[:optimal] },
            original_bytes: original_bytes,
            optimized_bytes: optimized_bytes,
            fallback: fallback,
            details: details
          }
          [pairs, report]
        end

        # Splits +events+ into maximal runs of simultaneous events. A new
        # group starts whenever an event has a non-zero delta time. Realtime
        # events are singleton barriers: SeqWriter never writes their delta
        # time, so they are never reordered.
        def split_groups(events)
          groups = []
          current = []
          events.each do |event|
            if event.is_a?(Realtime)
              groups << current unless current.empty?
              groups << [event]
              current = []
            elsif event.delta_time != 0
              groups << current unless current.empty?
              current = [event]
            else
              current << event
            end
          end
          groups << current unless current.empty?
          groups
        end

        # Precomputed per-event data used by the cost model.
        def event_info(event)
          data = event.data_as_bytes
          status = data[0]
          info = { length: data.length, status: status }
          if status < 0xf0
            info[:noteoff64] =
              (status & 0xf0) == NOTE_OFF && data.length > 2 && data[2] == 64
          end
          info
        end

        # Simulates SeqWriter#possibly_munge_due_to_running_status_byte.
        # Given the running status before an event and its event_info, returns
        # [bytes_written, new_running_status].
        def transition(running_status, info)
          status = info[:status]
          return [info[:length], status] if status >= 0xf0 || running_status >= 0xf0

          chan = status & 0x0f
          return [info[:length], status] if chan != (running_status & 0x0f)

          nibble = status & 0xf0
          prev_nibble = running_status & 0xf0
          if nibble == prev_nibble
            [info[:length] - 1, status]
          elsif nibble == NOTE_OFF && info[:noteoff64]
            # A note off with velocity 64 is written as a note on with
            # velocity 0, so the running status becomes note on.
            new_status = NOTE_ON + chan
            prev_nibble == NOTE_ON ? [info[:length] - 1, new_status] : [info[:length], new_status]
          else
            [info[:length], status]
          end
        end

        # Returns an array of bitmasks; bitmask i has a bit for every event
        # that must be written before event i.
        def predecessors(group)
          n = group.length
          preds = Array.new(n, 0)
          group.each_with_index do |a, i|
            next if track_end?(a)

            (i + 1...n).each do |j|
              preds[j] |= (1 << i) if !track_end?(group[j]) && ordered_before?(a, group[j])
            end
          end
          # A track-end meta event stays after every simultaneous event.
          group.each_with_index do |event, i|
            next unless track_end?(event)

            n.times { |j| preds[i] |= (1 << j) unless j == i }
          end
          preds
        end

        def track_end?(event)
          event.is_a?(MetaEvent) && event.meta_type == META_TRACK_END
        end

        # True if +a+ must be written before +b+ to preserve performance
        # semantics. Only called for pairs where +a+ originally precedes +b+.
        def ordered_before?(a, b)
          a_chan = a.is_a?(ChannelEvent)
          b_chan = b.is_a?(ChannelEvent)
          if a_chan && b_chan
            return false if a.channel != b.channel

            pitch_a = note_keyed_pitch(a)
            pitch_b = note_keyed_pitch(b)
            # Two note-keyed events only interfere on the same pitch.
            # Anything else on the channel (controllers, program changes,
            # pressures, bends) interacts with all events on that channel.
            return pitch_a == pitch_b if pitch_a && pitch_b

            return true
          end
          # Non-channel events keep their relative order.
          return true if !a_chan && !b_chan

          # Mixed channel/non-channel pairs may swap, except meta events
          # that scope the channel events around them. (Track end is handled
          # separately in predecessors(), which forces it to stay last.)
          meta = a_chan ? b : a
          return false unless meta.is_a?(MetaEvent)

          meta.meta_type == META_MIDI_CHAN_PREFIX ||
            meta.meta_type == META_PORT_PREFIX
        end

        private

        # Returns the pitch for note-keyed events (note on, note off, poly
        # pressure), nil for everything else.
        def note_keyed_pitch(event)
          event.is_a?(NoteEvent) ? event.note : nil
        end

        def optimize_group(infos, group, entry_status, exact_threshold, beam_width)
          preds = predecessors(group)
          if group.length <= exact_threshold
            cost, order = exact_order(infos, preds, entry_status)
            [order, cost, true]
          else
            cost, order = beam_order(infos, preds, entry_status, beam_width)
            [order, cost, false]
          end
        end

        # Exact dynamic program over subsets of the legal permutations.
        # Returns [min_cost, order] where order is an array of group indices.
        def exact_order(infos, preds, entry_status)
          n = infos.length
          full = (1 << n) - 1
          states = Array.new(full + 1) { {} } # mask -> {running_status => cost}
          states[0][entry_status] = 0
          parent = {}

          (0..full).each do |mask|
            states[mask].each do |running_status, cost|
              n.times do |i|
                bit = 1 << i
                next if (mask & bit) != 0
                next unless (preds[i] & mask) == preds[i]

                size, new_status = transition(running_status, infos[i])
                new_mask = mask | bit
                new_cost = cost + size
                current = states[new_mask][new_status]
                next if current && current <= new_cost

                states[new_mask][new_status] = new_cost
                parent[[new_mask, new_status]] = [mask, running_status, i]
              end
            end
          end

          final_status, final_cost = states[full].min_by { |_status, cost| cost }
          # Unsatisfiable constraints should never happen; keep the original
          # order rather than looping or failing if they somehow do.
          return [simulate_identity(infos, entry_status), (0...n).to_a] if final_cost.nil?

          order = []
          mask = full
          while mask != 0
            prev_mask, prev_status, i = parent[[mask, final_status]]
            order.unshift(i)
            mask = prev_mask
            final_status = prev_status
          end
          [final_cost, order]
        end

        # Cost of the events in their original order.
        def simulate_identity(infos, entry_status)
          running_status = entry_status
          cost = 0
          infos.each do |info|
            size, running_status = transition(running_status, info)
            cost += size
          end
          cost
        end

        # Beam search for large groups. Keeps at most +width+ states per
        # position, so the work is O(n^2 * width). Not guaranteed optimal.
        def beam_order(infos, preds, entry_status, width)
          n = infos.length
          states = { [0, entry_status] => 0 }
          parents = []

          n.times do
            next_states = {}
            parent = {}
            states.each do |(mask, running_status), cost|
              n.times do |i|
                bit = 1 << i
                next if (mask & bit) != 0
                next unless (preds[i] & mask) == preds[i]

                size, new_status = transition(running_status, infos[i])
                new_mask = mask | bit
                new_cost = cost + size
                key = [new_mask, new_status]
                current = next_states[key]
                next if current && current <= new_cost

                next_states[key] = new_cost
                parent[key] = [mask, running_status, i]
              end
            end
            if next_states.size > width
              kept = next_states.sort_by { |(mask, status), cost| [cost, mask, status] }
                                .first(width).to_h
              parent.select! { |key, _| kept.key?(key) }
              next_states = kept
            end
            parents << parent
            states = next_states
          end

          (mask, final_status), final_cost = states.min_by { |_key, cost| cost }
          return [simulate_identity(infos, entry_status), (0...n).to_a] if final_cost.nil?

          order = []
          (n - 1).downto(0) do |depth|
            mask, final_status, i = parents[depth][[mask, final_status]]
            order.unshift(i)
          end
          [final_cost, order]
        end
      end
    end
  end
end
