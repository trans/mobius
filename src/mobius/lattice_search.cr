require "./index"

module Mobius
  # Walks the masked patterns consistent with a history: subsets of the
  # offsets 1..window, each filled with the history's bytes at its offsets,
  # matched against a bit-plane index. A shape has bit o - 1 set for offset o;
  # shape 0 is the empty pattern, which matches every position. Offsets are
  # added in increasing order, so each subset is reached once, and the walk
  # stops below a minimum support, which can only shrink as offsets are added.
  class LatticeSearch
    getter index : Index
    getter window : Int32
    getter alphabet : Bytes
    getter unigram_counts : Slice(Int32)
    # Training byte frequencies by alphabet slot.
    getter unigram : Slice(Float64)

    @slots : StaticArray(Int32, 256)
    @full : Slice(UInt64)
    @sets : Array(Slice(UInt64))
    @lists : Array(Array(Int32))
    @as_set : Array(Bool)

    def initialize(@index : Index, @window : Int32)
      raise ArgumentError.new("window must be 1 to 32") unless 1 <= @window <= 32
      @alphabet = @index.alphabet
      @slots = StaticArray(Int32, 256).new(-1)
      @alphabet.each_with_index { |byte, slot| @slots[byte.to_i] = slot }
      @unigram_counts = Slice(Int32).new(@alphabet.size, 0)
      @index.corpus.each { |byte| @unigram_counts[@slots[byte.to_i]] += 1 }
      @unigram = Slice(Float64).new(@alphabet.size) { |slot| @unigram_counts[slot] / @index.corpus_size }
      @full = @index.full_set
      @sets = Array.new(@window + 1) { Slice(UInt64).new(@index.word_count, 0_u64) }
      @lists = Array.new(@window + 1) { [] of Int32 }
      @as_set = Array.new(@window + 1, true)
    end

    def slot(byte : UInt8) : Int32
      @slots[byte.to_i]
    end

    # Calls the block with each pattern's shape, support, next-byte counts by
    # alphabet slot, and depth in the walk: first the empty pattern, then every
    # pattern with at least `min_support` matches. The walk goes below a
    # pattern only when the block returns true for it. During the call,
    # `continuation_counts(depth, offset)` describes that pattern's matches.
    def each(history : Bytes, min_support : Int32, &visit : UInt32, Int32, Slice(Int32), Int32 -> Bool) : Nil
      @sets[0] = @full
      @as_set[0] = true
      return unless visit.call(0_u32, @index.corpus_size, @unigram_counts.dup, 0)
      walk(history, min_support, 0, 0_u32, 1, visit)
    end

    # For the pattern at `depth` of the current walk: for each next byte, by
    # slot, how many distinct bytes occur `offset` places before its matches.
    # A match fewer than `offset` bytes from the start of the text counts the
    # start as one more distinct value.
    def continuation_counts(depth : Int32, offset : Int32) : Slice(Int32)
      corpus = @index.corpus
      seen = Slice(UInt64).new(@alphabet.size * 5, 0_u64)
      result = Slice(Int32).new(@alphabet.size, 0)
      each_position(depth) do |position|
        next_slot = @slots[corpus[position].to_i]
        before = position >= offset ? corpus[position - offset].to_i : 256
        word = next_slot * 5 + before // 64
        bit = 1_u64 << (before % 64)
        if seen[word] & bit == 0
          seen[word] |= bit
          result[next_slot] += 1
        end
      end
      result
    end

    # For the pattern at `depth` of the current walk: its next-byte counts by
    # slot, separately for each of `folds` contiguous blocks of the text.
    def fold_counts(depth : Int32, folds : Int32) : Array(Slice(Int32))
      corpus = @index.corpus
      size = corpus.size.to_i64
      result = Array(Slice(Int32)).new(folds) { Slice(Int32).new(@alphabet.size, 0) }
      each_position(depth) do |position|
        result[(position.to_i64 * folds // size).to_i32][@slots[corpus[position].to_i]] += 1
      end
      result
    end

    # Fold counts of the empty pattern, which match every position.
    def empty_fold_counts(folds : Int32) : Array(Slice(Int32))
      @sets[0] = @full
      @as_set[0] = true
      fold_counts(0, folds)
    end

    # Continuation counts of the empty pattern, which match every position.
    def empty_continuation_counts(offset : Int32) : Slice(Int32)
      @sets[0] = @full
      @as_set[0] = true
      continuation_counts(0, offset)
    end

    # The pattern as a query string: history bytes at its offsets, `*` elsewhere.
    def display(shape : UInt32, history : Bytes) : String
      return "(none)" if shape == 0
      farthest = 32 - shape.leading_zeros_count
      String.build do |io|
        farthest.downto(1) do |offset|
          if shape.bit(offset - 1) == 1
            case byte = history[history.size - offset]
            when 10_u8 then io << "\\n"
            when 42_u8 then io << "\\*"
            when 92_u8 then io << "\\\\"
            else            io << byte.chr
            end
          else
            io << '*'
          end
        end
      end
    end

    private def walk(history : Bytes, min_support : Int32, depth : Int32, shape : UInt32, first : Int32,
                     visit : Proc(UInt32, Int32, Slice(Int32), Int32, Bool)) : Nil
      first.upto(Math.min(@window, history.size)) do |offset|
        support = restrict(depth, offset, history[history.size - offset])
        next if support < min_support
        child = shape | (1_u32 << (offset - 1))
        walk(history, min_support, depth + 1, child, offset + 1, visit) if visit.call(child, support, counts(depth + 1), depth + 1)
      end
    end

    private def each_position(depth : Int32, &)
      if @as_set[depth]
        @sets[depth].each_with_index do |bits, word|
          while bits != 0
            yield word * 64 + bits.trailing_zeros_count
            bits &= bits - 1
          end
        end
      else
        @lists[depth].each { |position| yield position }
      end
    end

    # Builds the match set at depth + 1 from the one at depth: a bit set while
    # it is large, a position list once it is smaller than the bit set's words.
    private def restrict(depth : Int32, offset : Int32, byte : UInt8) : Int32
      child = depth + 1
      if @as_set[depth]
        support = @index.restrict(@sets[depth], @sets[child], byte, offset)
        @as_set[child] = support >= @index.word_count
        unless @as_set[child]
          list = @lists[child]
          list.clear
          @sets[child].each_with_index do |bits, word|
            while bits != 0
              list << word * 64 + bits.trailing_zeros_count
              bits &= bits - 1
            end
          end
        end
        support
      else
        corpus = @index.corpus
        list = @lists[child]
        list.clear
        @lists[depth].each { |position| list << position if position >= offset && corpus[position - offset] == byte }
        @as_set[child] = false
        list.size
      end
    end

    private def counts(depth : Int32) : Slice(Int32)
      corpus = @index.corpus
      counts = Slice(Int32).new(@alphabet.size, 0)
      each_position(depth) { |position| counts[@slots[corpus[position].to_i]] += 1 }
      counts
    end
  end
end
