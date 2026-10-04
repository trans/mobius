module Mobius
  # The suffixes of a text in sorted order, plus each suffix's longest common
  # prefix with the one before it. All suffixes that begin with a given string
  # form one contiguous run, so an exact string count is a binary search.
  class SuffixArray
    getter text : Bytes
    getter order : Slice(Int32)
    getter lcp : Slice(Int32)

    def initialize(@text : Bytes)
      raise ArgumentError.new("text is empty") if @text.empty?
      @order = sort_suffixes
      @lcp = longest_common_prefixes
    end

    def size : Int32
      @text.size
    end

    # Returns the run [first, last) of sorted suffixes that begin with `prefix`.
    def run(prefix : Bytes) : Tuple(Int32, Int32)
      {bound(prefix, after: false), bound(prefix, after: true)}
    end

    def count(prefix : Bytes) : Int32
      first, last = run(prefix)
      last - first
    end

    # Prefix doubling: after the round with step h, ranks order suffixes by
    # their first 2h bytes. Stops once every suffix has its own rank.
    private def sort_suffixes : Slice(Int32)
      n = @text.size
      rank = Slice(Int32).new(n) { |i| @text[i].to_i32 }
      next_rank = Slice(Int32).new(n, 0)
      keyed = Array(Tuple(Int64, Int32)).new(n) { |i| {0_i64, i} }
      step = 1
      loop do
        n.times do |i|
          follower = i + step < n ? rank[i + step] + 1 : 0
          keyed[i] = {(rank[i].to_i64 << 32) | follower, i}
        end
        keyed.sort!
        classes = 0
        next_rank[keyed[0][1]] = 0
        1.upto(n - 1) do |i|
          classes += 1 if keyed[i][0] != keyed[i - 1][0]
          next_rank[keyed[i][1]] = classes
        end
        rank, next_rank = next_rank, rank
        break if classes == n - 1 || step >= n
        step *= 2
      end
      Slice(Int32).new(n) { |i| keyed[i][1] }
    end

    # Kasai's algorithm; lcp[i] compares order[i - 1] with order[i].
    private def longest_common_prefixes : Slice(Int32)
      n = @text.size
      position_rank = Slice(Int32).new(n, 0)
      @order.each_with_index { |start, i| position_rank[start] = i }
      lcp = Slice(Int32).new(n, 0)
      shared = 0
      n.times do |start|
        i = position_rank[start]
        if i == 0
          shared = 0
          next
        end
        other = @order[i - 1]
        while start + shared < n && other + shared < n && @text[start + shared] == @text[other + shared]
          shared += 1
        end
        lcp[i] = shared
        shared -= 1 if shared > 0
      end
      lcp
    end

    # The first sorted index whose suffix is not below `prefix`; with `after`,
    # the first whose suffix is above every string beginning with `prefix`.
    private def bound(prefix : Bytes, after : Bool) : Int32
      low = 0
      high = @order.size
      while low < high
        middle = low + (high - low) // 2
        comparison = compare(@order[middle], prefix)
        if comparison < 0 || (after && comparison == 0)
          low = middle + 1
        else
          high = middle
        end
      end
      low
    end

    # Compares the suffix at `start`, cut to the prefix's length, with prefix.
    private def compare(start : Int32, prefix : Bytes) : Int32
      length = Math.min(prefix.size, @text.size - start)
      length.times do |i|
        a = @text[start + i]
        b = prefix[i]
        return a < b ? -1 : 1 if a != b
      end
      length < prefix.size ? -1 : 0
    end
  end
end
