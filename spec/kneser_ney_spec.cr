require "spec"
require "../src/mobius/kneser_ney"

def occurrences(text : Bytes, string : Bytes) : Array(Int32)
  (0..text.size - string.size).select { |start| text[start, string.size] == string }
end

# Distinct bytes before each occurrence; -1 stands for the start of the text.
def predecessors(text : Bytes, string : Bytes) : Int32
  occurrences(text, string).map { |start| start > 0 ? text[start - 1].to_i : -1 }.uniq.size
end

def naive_discounts(text : Bytes, length : Int32, continuation : Bool) : StaticArray(Float64, 3)
  strings = (0..text.size - length).map { |start| text[start, length] }.uniq
  n = StaticArray(Int64, 5).new(0_i64)
  strings.each do |string|
    count = continuation ? predecessors(text, string) : occurrences(text, string).size
    n[count] += 1 if count <= 4
  end
  Mobius::KneserNey.discounts(n)
end

# Interpolated modified Kneser–Ney from brute-force counts.
def naive_probability(text : Bytes, history : Bytes, byte : UInt8, limit : Int32) : Float64
  p = 1.0 / 256
  0.upto(Math.min(limit, history.size)) do |k|
    context = history[history.size - k, k]
    raw = k == limit
    counts = (0..255).map do |next_byte|
      string = Bytes.new(k + 1) { |i| i < k ? context[i] : next_byte.to_u8 }
      raw ? occurrences(text, string).size : predecessors(text, string)
    end
    total = counts.sum
    break if total == 0
    discounts = naive_discounts(text, k + 1, !raw)
    discount = ->(count : Int32) { count == 0 ? 0.0 : discounts[Math.min(count, 3) - 1] }
    backoff = counts.sum(0.0) { |count| discount.call(count) } / total
    count = counts[byte]
    p = (count - discount.call(count)) / total + backoff * p
  end
  p
end

describe Mobius::SuffixArray do
  it "sorts suffixes and finds exact string counts" do
    random = Random.new(7)
    texts = ["banana", "aaaaaaaa", "abcabcabcab", String.build { |io| 300.times { io << "ab c"[random.rand(4)] } }]
    texts.each do |source|
      text = source.to_slice
      suffixes = Mobius::SuffixArray.new(text)
      expected = (0...text.size).to_a.sort_by { |start| String.new(text[start, text.size - start]) }
      suffixes.order.to_a.should eq(expected)
      1.upto(text.size - 1) do |i|
        a = text[expected[i - 1], text.size - expected[i - 1]]
        b = text[expected[i], text.size - expected[i]]
        shared = 0
        while shared < Math.min(a.size, b.size) && a[shared] == b[shared]
          shared += 1
        end
        suffixes.lcp[i].should eq(shared)
      end
      1.upto(4) do |length|
        (0..text.size - length).each do |start|
          string = text[start, length]
          suffixes.count(string).should eq(occurrences(text, string).size)
        end
      end
      suffixes.count("zz".to_slice).should eq(0)
    end
  end
end

describe Mobius::KneserNey do
  it "computes Chen and Goodman's discounts from count-of-counts" do
    # n1..n4 = 100, 40, 20, 10: Y = 100 / 180, then D_r = r - (r + 1) Y n_{r+1} / n_r.
    n = StaticArray[0_i64, 100_i64, 40_i64, 20_i64, 10_i64]
    y = 100.0 / 180.0
    discounts = Mobius::KneserNey.discounts(n)
    discounts[0].should be_close(1 - 2 * y * 40 / 100, 1e-12)
    discounts[1].should be_close(2 - 3 * y * 20 / 40, 1e-12)
    discounts[2].should be_close(3 - 4 * y * 10 / 20, 1e-12)
  end

  corpus = begin
    random = Random.new(11)
    String.build { |io| 400.times { io << "abc d."[random.rand(6)] } }.to_slice
  end
  training = corpus[0, 300]

  it "derives discounts from raw and continuation count-of-counts" do
    model = Mobius::KneserNey.new(Mobius::SuffixArray.new(training), 4)
    0.upto(4) do |k|
      model.raw_discounts[k].should eq(naive_discounts(training, k + 1, false))
      model.continuation_discounts[k].should eq(naive_discounts(training, k + 1, true))
    end
  end

  it "matches a brute-force Kneser–Ney at every held-out position and limit" do
    model = Mobius::KneserNey.new(Mobius::SuffixArray.new(training), 4)
    300.upto(339) do |position|
      history = corpus[0, position]
      actual = model.probabilities(model.levels(history), corpus[position])
      0.upto(4) do |limit|
        actual[limit].should be_close(naive_probability(training, history, corpus[position], limit), 1e-12)
      end
    end
  end

  it "gives a normalized distribution over all byte values" do
    model = Mobius::KneserNey.new(Mobius::SuffixArray.new(training), 6)
    {"", "a", "c d", "zzz", "ab.ab"}.each do |text|
      levels = model.levels(text.to_slice)
      totals = Array(Float64).new(7, 0.0)
      256.times do |byte|
        model.probabilities(levels, byte.to_u8).each_with_index { |p, limit| totals[limit] += p }
      end
      totals.each { |total| total.should be_close(1.0, 1e-12) }
    end
  end

  it "reports bits per byte consistent with the per-position probabilities" do
    model = Mobius::KneserNey.new(Mobius::SuffixArray.new(training), 3)
    expected = (300...400).sum { |position| -Math.log2(model.probability(corpus[0, position], corpus[position], 2)) } / 100
    model.bits_per_byte(corpus, 300, 400)[2].should be_close(expected, 1e-12)
  end
end
