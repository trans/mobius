module Mobius
  # A pattern uses * for one ignored byte. Leading ignored positions carry no
  # information; trailing ones become additional target distance. As an event,
  # a pattern's leading ignored positions instead delay its first literal.
  class Pattern
    MAX_SPAN = 16

    getter symbols : Array(UInt8?)
    getter trailing_skips : Int32
    getter leading_skips : Int32

    def initialize(@symbols : Array(UInt8?), @trailing_skips : Int32 = 0, @leading_skips : Int32 = 0)
    end

    def self.parse(text : String, max_span : Int32 = MAX_SPAN) : Pattern
      bytes = text.to_slice
      symbols = [] of UInt8?
      i = 0
      while i < bytes.size
        byte = bytes[i]
        if byte == 42_u8 # *
          symbols << nil
        elsif byte == 92_u8 # backslash
          i += 1
          raise ArgumentError.new("unfinished pattern escape") if i >= bytes.size
          escaped = bytes[i]
          case escaped
          when 110_u8 then symbols << 10_u8 # newline
          when 114_u8 then symbols << 13_u8 # \r
          when 116_u8 then symbols << 9_u8  # \t
          when 120_u8                       # \xHH
            raise ArgumentError.new("\\x requires two hex digits") if i + 2 >= bytes.size
            high = hex_digit(bytes[i + 1])
            low = hex_digit(bytes[i + 2])
            symbols << ((high << 4) | low).to_u8
            i += 2
          else
            symbols << escaped
          end
        else
          symbols << byte
        end
        i += 1
      end

      raise ArgumentError.new("pattern must have 1 to #{max_span} positions") if symbols.empty? || symbols.size > max_span
      leading = 0
      while !symbols.empty? && symbols.first?.nil?
        symbols.shift
        leading += 1
      end
      trailing = 0
      while !symbols.empty? && symbols.last?.nil?
        symbols.pop
        trailing += 1
      end
      raise ArgumentError.new("pattern must contain at least one literal byte") if symbols.empty?
      new(symbols, trailing, leading)
    end

    def span : Int32
      @symbols.size
    end

    def distance_from_last_literal(distance : Int32) : Int32
      raise ArgumentError.new("distance must be at least 1") if distance < 1
      total = distance.to_i64 + @trailing_skips
      raise ArgumentError.new("distance is too large") if total > Int32::MAX
      total.to_i32
    end

    private def self.hex_digit(byte : UInt8) : Int32
      case byte
      when 48_u8..57_u8  then byte.to_i - 48
      when 65_u8..70_u8  then byte.to_i - 55
      when 97_u8..102_u8 then byte.to_i - 87
      else                    raise ArgumentError.new("invalid hex digit in pattern")
      end
    end
  end

  class Histogram
    getter counts : Array(Int64)
    getter support : Int64

    def initialize(@counts : Array(Int64), @support : Int64)
    end

    def entropy_bits : Float64
      return 0.0 if @support == 0
      entropy = 0.0
      @counts.each do |count|
        next if count == 0
        p = count.to_f / @support
        entropy -= p * Math.log2(p)
      end
      entropy
    end

    def most_common(limit : Int32 = 256) : Array(Tuple(UInt8, Int64))
      ranked = [] of Tuple(UInt8, Int64)
      @counts.each_with_index do |count, byte|
        ranked << {byte.to_u8, count} if count > 0
      end
      ranked.sort_by! { |entry| {-entry[1], entry[0]} }
      ranked.first(limit)
    end
  end

  # Support counts context matches whose whole event window lies inside the
  # corpus; joint counts those where the event pattern also matches.
  class Cooccurrence
    getter support : Int64
    getter joint : Int64

    def initialize(@support : Int64, @joint : Int64)
    end

    def probability : Float64
      @support == 0 ? 0.0 : @joint.to_f / @support
    end
  end

  # Observed contiguous blocks at one offset, keyed by their bytes.
  class EventCounts
    getter counts : Hash(Bytes, Int64)
    getter support : Int64

    def initialize(@counts : Hash(Bytes, Int64), @support : Int64)
    end

    def most_common(limit : Int32 = 20) : Array(Tuple(Bytes, Int64))
      ranked = @counts.to_a
      ranked.sort! do |a, b|
        order = b[1] <=> a[1]
        order != 0 ? order : a[0] <=> b[0]
      end
      ranked.first(limit)
    end
  end

  # One bit plane per byte found in the corpus. A plane's bit i is set when
  # corpus[i] is that byte. No pattern- or distance-specific rows are stored.
  class Index
    MAGIC = "MOBIDX01"

    getter corpus_size : Int32
    getter alphabet : Bytes
    getter corpus : Bytes
    getter word_count : Int32

    @planes : Slice(UInt64)
    @lookup : StaticArray(Int32, 256)

    private def initialize(@corpus : Bytes, @alphabet : Bytes, @planes : Slice(UInt64))
      @corpus_size = @corpus.size
      @word_count = (@corpus_size + 63) // 64
      @lookup = StaticArray(Int32, 256).new(-1)
      @alphabet.each_with_index { |byte, plane| @lookup[byte.to_i] = plane }
    end

    def self.from_file(path : String) : Index
      from_bytes(File.read(path).to_slice)
    end

    def self.from_bytes(corpus : Bytes) : Index
      raise ArgumentError.new("corpus is empty") if corpus.empty?
      corpus = corpus.dup
      present = StaticArray(Bool, 256).new(false)
      corpus.each { |byte| present[byte.to_i] = true }
      alphabet_size = present.count(true)
      alphabet = Bytes.new(alphabet_size)
      next_slot = 0
      256.times do |i|
        next unless present[i]
        alphabet[next_slot] = i.to_u8
        next_slot += 1
      end

      words = (corpus.size + 63) // 64
      planes = Slice(UInt64).new(alphabet_size * words, 0_u64)
      lookup = StaticArray(Int32, 256).new(-1)
      alphabet.each_with_index { |byte, plane| lookup[byte.to_i] = plane }
      corpus.each_with_index do |byte, position|
        offset = lookup[byte.to_i] * words + position // 64
        planes[offset] |= 1_u64 << (position % 64)
      end
      new(corpus, alphabet, planes)
    end

    def self.load(path : String) : Index
      require_little_endian
      File.open(path, "rb") do |io|
        magic = Bytes.new(MAGIC.bytesize)
        io.read_fully(magic)
        raise ArgumentError.new("unrecognized index format") unless String.new(magic) == MAGIC
        size = io.read_bytes(UInt64, IO::ByteFormat::LittleEndian)
        raise ArgumentError.new("index corpus size is unsupported") if size == 0 || size > Int32::MAX
        alphabet_size = io.read_bytes(UInt16, IO::ByteFormat::LittleEndian).to_i
        raise ArgumentError.new("invalid index alphabet") if alphabet_size == 0 || alphabet_size > 256
        alphabet = Bytes.new(alphabet_size)
        io.read_fully(alphabet)
        words = (size.to_i + 63) // 64
        planes = Slice(UInt64).new(alphabet_size * words, 0_u64)
        io.read_fully(planes.to_unsafe_bytes)
        corpus = Bytes.new(size.to_i)
        io.read_fully(corpus)
        raise ArgumentError.new("index has trailing bytes") unless io.read_byte.nil?
        new(corpus, alphabet, planes)
      end
    end

    def save(path : String) : Nil
      self.class.require_little_endian
      File.open(path, "wb") do |io|
        io.write(MAGIC.to_slice)
        io.write_bytes(@corpus_size.to_u64, IO::ByteFormat::LittleEndian)
        io.write_bytes(@alphabet.size.to_u16, IO::ByteFormat::LittleEndian)
        io.write(@alphabet)
        io.write(@planes.to_unsafe_bytes)
        io.write(@corpus)
      end
    end

    def bitplane_bytes : Int64
      @planes.bytesize.to_i64
    end

    # Every position: a match set before any byte is required.
    def full_set : Slice(UInt64)
      set = Slice(UInt64).new(@word_count, UInt64::MAX)
      if (tail = @corpus_size % 64) != 0
        set[@word_count - 1] = (1_u64 << tail) - 1_u64
      end
      set
    end

    # Writes to `target` the positions of `source` whose byte `offset` places
    # earlier is `byte`, and returns how many there are.
    def restrict(source : Slice(UInt64), target : Slice(UInt64), byte : UInt8, offset : Int32) : Int32
      plane = @lookup[byte.to_i]
      if plane < 0
        target.fill(0_u64)
        return 0
      end
      whole = offset // 64
      remainder = offset % 64
      base = plane * @word_count
      count = 0
      @word_count.times do |word|
        from = word - whole
        aligned = 0_u64
        if from >= 0
          aligned = @planes[base + from] << remainder
          aligned |= @planes[base + from - 1] >> (64 - remainder) if remainder > 0 && from > 0
        end
        bits = source[word] & aligned
        target[word] = bits
        count += bits.popcount
      end
      count
    end

    # Returns corpus positions where the last specified pattern byte occurs.
    def matching_end_positions(pattern : Pattern) : Array(Int32)
      matches = Slice(UInt64).new(@word_count, UInt64::MAX)
      pattern.symbols.each_with_index do |symbol, slot|
        next unless symbol
        plane = @lookup[symbol.to_i]
        return [] of Int32 if plane < 0
        shift = pattern.span - slot - 1
        whole = shift // 64
        remainder = shift % 64
        word = 0
        while word < @word_count
          source = word - whole
          aligned = 0_u64
          if source >= 0
            aligned = @planes[plane * @word_count + source] << remainder
            if remainder > 0 && source > 0
              aligned |= @planes[plane * @word_count + source - 1] >> (64 - remainder)
            end
          end
          matches[word] &= aligned
          word += 1
        end
      end

      if (tail = @corpus_size % 64) != 0
        matches[@word_count - 1] &= (1_u64 << tail) - 1_u64
      end
      positions = [] of Int32
      matches.each_with_index do |bits, word|
        while bits != 0
          positions << word * 64 + bits.trailing_zeros_count
          bits &= bits - 1_u64
        end
      end
      positions
    end

    # Counts exact target bytes without storing a vocabulary-sized row per match.
    def histogram(positions : Array(Int32), distance : Int32) : Histogram
      raise ArgumentError.new("distance must be at least 1") if distance < 1
      counts = Array(Int64).new(256, 0_i64)
      support = 0_i64
      if distance < @corpus_size
        limit = @corpus_size - distance
        positions.each do |position|
          break if position >= limit
          counts[@corpus[position + distance].to_i] += 1
          support += 1
        end
      end
      Histogram.new(counts, support)
    end

    def query(pattern : Pattern, distance : Int32) : Histogram
      histogram(matching_end_positions(pattern), pattern.distance_from_last_literal(distance))
    end

    # Counts context matches followed by the event pattern starting `distance`
    # positions after the context as typed. A one-byte event reproduces `query`.
    def cooccur(context : Pattern, event : Pattern, distance : Int32) : Cooccurrence
      first = context.distance_from_last_literal(distance).to_i64 + event.leading_skips
      limit = @corpus_size.to_i64 - first - event.span
      support = 0_i64
      joint = 0_i64
      matching_end_positions(context).each do |position|
        break if position > limit
        support += 1
        joint += 1 if matches_at?(event, position + first)
      end
      Cooccurrence.new(support, joint)
    end

    # Tallies only the blocks that occur after context matches, so candidate
    # events come from the corpus rather than from every possible sequence.
    def events(context : Pattern, distance : Int32, length : Int32) : EventCounts
      raise ArgumentError.new("event length must be at least 1") if length < 1
      first = context.distance_from_last_literal(distance).to_i64
      limit = @corpus_size.to_i64 - first - length
      counts = Hash(Bytes, Int64).new(0_i64)
      support = 0_i64
      matching_end_positions(context).each do |position|
        break if position > limit
        counts[@corpus[position + first, length]] += 1
        support += 1
      end
      EventCounts.new(counts, support)
    end

    private def matches_at?(pattern : Pattern, start : Int64) : Bool
      pattern.symbols.each_with_index do |symbol, slot|
        return false if symbol && @corpus[start + slot] != symbol
      end
      true
    end

    def self.require_little_endian : Nil
      marker = Slice[1_u64]
      raise ArgumentError.new("index format currently requires a little-endian machine") unless marker.to_unsafe_bytes[0] == 1_u8
    end
  end
end
