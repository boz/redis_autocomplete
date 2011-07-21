require 'redis'

class RedisAutocomplete
  DEFAULT_DISALLOWED_CHARS = /[^a-zA-Z0-9_-]/.freeze
  DEFAULT_TERMINAL         = '+'.freeze
  DEFAULT_CASE_SENSITIVITY = true

  attr_reader :redis, :terminal

  def initialize(opts = {})
    @set_name         = opts[:set_name] # optional
    @redis            = opts[:redis] || Redis.new
    @disallowed_chars = opts[:disallowed_chars] || DEFAULT_DISALLOWED_CHARS
    @terminal         = opts[:terminal] || DEFAULT_TERMINAL
    @case_sensitive   = opts[:case_sensitive].nil? ? DEFAULT_CASE_SENSITIVITY : opts[:case_sensitive]
  end

  def add_word(word, set = @set_name)
    word = cleanup_word(word)
    each_prefix(word) do |prefix|
      @redis.zadd(set,0,prefix)
    end
    @redis.zadd(set, 0, terminate_word(word))
  end

  def add_words(words, set_name = @set_name)
    words.flatten.compact.uniq.each { |word| add_word word, set_name }
  end
  
  def remove_word(word, set_name = @set_name, remove_stems = true)
    set_name ||= @set_name
    word       = cleanup_word(word)
    return false unless include?(word,set_name)
    @redis.zrem(set_name, terminate_word(word))

    # remove_word_stem is inefficient and is best done later on with a cron job
    remove_word_stem(word, set_name) if remove_stems
    return true
  end
  
  def suggest(prefix, count = 10, set_name = @set_name)
    results    = []
    prefix     = cleanup_word(prefix)
    rangelen   = 50 # This is not random, try to get replies < MTU size
    start      = @redis.zrank(set_name, prefix)
    return [] if !start
    while results.length < count
      range  = @redis.zrange(set_name, start, start+rangelen-1)
      start += rangelen
      break if !range || range.length == 0
      range.each do |entry|

        minlen = [entry.length, prefix.length].min
        if entry.slice(0, minlen) != prefix.slice(0, minlen)
          # diverging prefixes; bail.
          count = results.count
          break
        end

        if entry.end_with?(@terminal)
          results << entry.chomp(@terminal)
          break unless results.length < count
        end
      end
    end
    return results
  end

  # utilities
  def reset!(set_name = @set_name)
    @redis.del(set_name, 0, 0)
  end

  protected
  def include?(word,set_name = @set_name)
    !!@redis.zrank(set_name,terminate_word(word))
  end
  def remove_word_stem(stem, set_name = @set_name)
    each_prefix(stem) do |prefix|
      break if suggest(prefix,1,set_name).any?
      @redis.zrem(set_name, prefix)
    end
  end

  def cleanup_word(word)
    word.gsub(@disallowed_chars, '')
    @case_sensitive ? word : word.downcase
  end

  def terminate_word(word)
    "#{word}#{@terminal}"
  end

  def each_prefix(word,&blk)
    word.length.times do |idx|
      blk.call(word.slice(0..(-1 - idx)))
    end
  end
end
