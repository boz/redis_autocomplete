require 'redis'

class RedisAutocomplete
  DEFAULT_DISALLOWED_CHARS = /[^a-zA-Z0-9_-]/.freeze
  DEFAULT_TERMINAL         = '+'.freeze
  DEFAULT_NAMESPACE        = "redis-autocomplete".freeze
  DEFAULT_CASE_SENSITIVITY = true

  attr_reader :redis, :terminal

  def initialize(opts = {})
    @namespace        = opts[:namespace]        || DEFAULT_NAMESPACE
    @terminal         = opts[:terminal]         || DEFAULT_TERMINAL
    @disallowed_chars = opts[:disallowed_chars] || DEFAULT_DISALLOWED_CHARS
    @redis            = opts[:redis]            || Redis.new
    @case_sensitive   = opts[:case_sensitive].nil? ? DEFAULT_CASE_SENSITIVITY : opts[:case_sensitive]
  end

  def add_word(word, value = word)
    word = cleanup_word(word)
    @redis.hset(value_key,word,serialize_value(value))

    return false if include_word?(word,false)
    each_prefix(word) do |prefix|
      @redis.zincrby(accounting_key,1,prefix)
      @redis.zadd(prefix_key,0,prefix)
    end

    @redis.hset(value_key,word,serialize_value(value))
    word = terminate_word(word)
    @redis.zincrby(accounting_key, 1, word)
    @redis.zadd(prefix_key   , 0, word)
    return true
  end

  def add_words(words)
    words.each do |word|
      add_word(word)
    end
  end
  
  def remove_word(word, refresh = true)
    word = cleanup_word(word)
    return false unless include_word?(word,false)

    @redis.zincrby(accounting_key, -1, terminate_word(word))
    @redis.hdel(value_key,word)

    each_prefix(word) do |prefix|
      @redis.zincrby(accounting_key,-1,prefix)
    end

    refresh_completion_prefixes! if refresh
    return true
  end

  def refresh_completion_prefixes!
    # remove unused prefixes from accounting key
    @redis.zremrangebyscore(accounting_key,"-inf",0)

    # completion = completion & accounting
    @redis.zinterstore(prefix_key,[prefix_key, accounting_key], :weights => [1,0])
  end

  def suggest(prefix, count = 10)
    results    = []
    prefix     = cleanup_word(prefix)
    rangelen   = 50 # This is not random, try to get replies < MTU size
    start      = @redis.zrank(prefix_key, prefix)
    return [] if !start
    while results.length < count
      range  = @redis.zrange(prefix_key, start, start+rangelen-1)
      start += rangelen
      break if !range || range.length == 0
      range.each do |entry|

        minlen = [entry.length, prefix.length].min
        if entry.slice(0, minlen) != prefix.slice(0, minlen)
          # diverging prefixes; bail.
          count = results.count
          break
        end

        if entry.end_with?(@terminal) && include_prefix?(entry,false)
          results << deserialize_value(@redis.hget(value_key,entry.chomp(@terminal)))
          break unless results.length < count
        end
      end
    end
    return results
  end

  # utilities
  def reset!
    @redis.del(*all_keys)
  end
  def include_word?(word,cleanup = true)
    include_prefix?(terminate_word(word),cleanup)
  end
  def include_prefix?(prefix,cleanup = true)
    prefix = cleanup_word(prefix) if cleanup
    @redis.zscore(accounting_key,prefix).to_i > 0
  end

  def serialize_value(value)  ; Marshal.dump(value); end
  def deserialize_value(value); Marshal.load(value); end
  protected
  def cleanup_word(word)
    word.gsub(@disallowed_chars, '')
    @case_sensitive ? word : word.downcase
  end

  def terminate_word(word)
    "#{word}#{@terminal}"
  end

  def all_keys
    [accounting_key, prefix_key, value_key]
  end

  def accounting_key
    "#{@namespace}:accounting"
  end

  def prefix_key
    "#{@namespace}:prefix"
  end

  def value_key
    "#{@namespace}:value"
  end

  def each_prefix(word,&blk)
    word.length.times do |idx|
      blk.call(word.slice(0..(-1 - idx)))
    end
  end
end
