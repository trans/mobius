require "./kneser_ney"

module Mobius
  # Shapes, keys and the byte alphabet shared by the mined-pattern models.
  #
  # A shape is a bitmask: bit o - 1 stands for offset o, and offset 1 is the
  # byte just before the target. A key packs the alphabet slots of the bytes at
  # a shape's offsets, nearest offset most significant. Score vectors have one
  # slot per alphabet byte plus a last slot that stands for each byte outside
  # the alphabet.
  class PatternSpace
    getter window : Int32
    getter order : Int32
    getter context_limit : Int32
    getter alphabet : Bytes
    getter shapes : Array(UInt32)
    getter outside : UInt8?

    @slots : StaticArray(Int32, 256)

    def initialize(text : Bytes, @window : Int32, @order : Int32, @context_limit : Int32)
      raise ArgumentError.new("window must be 1 to 32") unless 1 <= @window <= 32
      raise ArgumentError.new("order must be 1 to 3") unless 1 <= @order <= 3
      raise ArgumentError.new("context limit must be 0 to the window") unless 0 <= @context_limit <= @window
      present = StaticArray(Bool, 256).new(false)
      text.each { |byte| present[byte.to_i] = true }
      @alphabet = Bytes.new(present.count(true))
      @slots = StaticArray(Int32, 256).new(-1)
      next_slot = 0
      256.times do |byte|
        next unless present[byte]
        @alphabet[next_slot] = byte.to_u8
        @slots[byte] = next_slot
        next_slot += 1
      end
      @outside = (0..255).find { |byte| !present[byte] }.try(&.to_u8)
      @shapes = [] of UInt32
      1.upto(@order) do |size|
        (0...@window).to_a.each_combination(size) do |bits|
          @shapes << bits.sum(0_u32) { |bit| 1_u32 << bit }
        end
      end
      @shapes.sort!
    end

    def size : Int32
      @alphabet.size
    end

    def slot(byte : UInt8) : Int32
      @slots[byte.to_i]
    end

    def popcount(shape : UInt32) : Int32
      shape.popcount.to_i
    end

    def offsets(shape : UInt32) : Array(Int32)
      (1..@window).select { |offset| shape.bit(offset - 1) == 1 }
    end

    # Offsets 1 to the context limit: what Kneser–Ney already sees.
    def inside : UInt32
      @context_limit >= 32 ? UInt32::MAX : ((1_u64 << @context_limit) - 1).to_u32
    end

    def reaches_beyond?(shape : UInt32) : Bool
      shape & ~inside != 0
    end

    # Packs the bytes at the shape's offsets before `position`, or returns -1
    # when an offset falls before the text or a byte is outside the alphabet.
    def key_at(corpus : Bytes, shape : UInt32, position : Int32) : Int32
      key = 0
      offset = 1
      remaining = shape
      while remaining != 0
        if remaining & 1 == 1
          return -1 if position - offset < 0
          slot = @slots[corpus[position - offset].to_i]
          return -1 if slot < 0
          key = key * @alphabet.size + slot
        end
        remaining >>= 1
        offset += 1
      end
      key
    end

    # The rendered pattern, from its farthest offset down to offset 1, in the
    # query syntax: `*` for an ignored byte.
    def display(shape : UInt32, key : Int32) : String
      bytes = {} of Int32 => UInt8
      remaining = key
      offsets(shape).reverse_each do |offset|
        bytes[offset] = @alphabet[remaining % @alphabet.size]
        remaining //= @alphabet.size
      end
      String.build do |io|
        (offsets(shape).max).downto(1) do |offset|
          if byte = bytes[offset]?
            case byte
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

    # Natural-log Kneser–Ney scores by slot.
    def base_scores(kneser_ney : KneserNey, corpus : Bytes, position : Int32) : Slice(Float64)
      distribution = kneser_ney.distribution(kneser_ney.levels(corpus[0, position], @context_limit), @context_limit)
      Slice(Float64).new(size + 1) do |slot|
        byte = slot < size ? @alphabet[slot] : @outside
        byte ? Math.log(distribution[byte]) : -Float64::INFINITY
      end
    end

    # Normalized probability of `byte` from natural-log scores by slot.
    def probability(scores : Slice(Float64), byte : UInt8) : Float64
      top = scores.max
      outside = 256 - size
      total = (0...size).sum { |slot| Math.exp(scores[slot] - top) }
      total += outside * Math.exp(scores[size] - top) if outside > 0
      slot = @slots[byte.to_i]
      Math.exp(scores[slot >= 0 ? slot : size] - top) / total
    end
  end
  # Keeps the `capacity` highest-scoring items seen so far. Items respond to
  # `score`, `shape` and `key`; `sorted` breaks score ties by shape, then key.
  class BestScores(T)
    def initialize(@capacity : Int32)
      @heap = [] of T
    end

    def admits?(score : Float64) : Bool
      @capacity > 0 && (@heap.size < @capacity || score > @heap[0].score)
    end

    def push(item : T) : Nil
      return unless admits?(item.score)
      if @heap.size < @capacity
        @heap << item
        index = @heap.size - 1
        while index > 0
          parent = (index - 1) // 2
          break if @heap[parent].score <= @heap[index].score
          @heap.swap(parent, index)
          index = parent
        end
      else
        @heap[0] = item
        index = 0
        loop do
          smallest = index
          {2 * index + 1, 2 * index + 2}.each do |child|
            smallest = child if child < @heap.size && @heap[child].score < @heap[smallest].score
          end
          break if smallest == index
          @heap.swap(smallest, index)
          index = smallest
        end
      end
    end

    def sorted : Array(T)
      @heap.sort do |a, b|
        order = b.score <=> a.score
        order = a.shape <=> b.shape if order == 0
        order != 0 ? order : a.key <=> b.key
      end
    end
  end
end
