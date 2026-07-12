module PriceProvider
  # Provider-agnostic budget circuit breakers backed by Solid Cache
  # (docs/PLAN.md § Price pipeline). The price-pipeline jobs call these before
  # every provider request so a runaway sync can't blow through a free tier:
  #
  #   * a per-provider DAILY request budget;
  #   * a per-provider HOURLY pacing window (Tiingo's 50/hr) so jobs can
  #     throttle enqueue/fetch rate;
  #   * Tiingo's MONTHLY unique-symbol quota (500 distinct symbols/month) —
  #     counted once per symbol per month, never twice.
  #
  # When a window is full the breaker raises BudgetExceeded (a RateLimited)
  # carrying a `retry_after` of the seconds until that window resets. All
  # windows are scoped in America/New_York and encoded into the cache KEY, so
  # they roll over at their natural day/hour/month boundary with no sweeper —
  # a new period simply reads a fresh, zero-valued key. Counters use the store's
  # atomic `increment` (memory_store in test, solid_cache in production; both
  # initialise a missing key to the increment amount and honour `expires_in`).
  #
  # Not thread-safe against a true concurrent multi-writer race, which the
  # single-user, serialized (`limits_concurrency`) job model does not create;
  # the `increment`-based counting keeps the common paths atomic regardless.
  class Budget
    # Free-tier limits, live-verified July 2026 (docs/PLAN.md § Free data
    # sources). :daily / :hourly / :monthly_symbols; omit a key to disable that
    # window for the provider.
    LIMITS = {
      "tiingo"      => { daily: 1_000, hourly: 50, monthly_symbols: 500 },
      "twelve_data" => { daily: 800 },
      "fmp"         => { daily: 250 }
    }.freeze

    # TTLs only bound how long a spent counter lingers in the cache; correctness
    # comes from the date-scoped key, not the expiry. Each is comfortably longer
    # than its window so a counter never expires mid-period.
    DAY_TTL   = 36.hours
    HOUR_TTL  = 90.minutes
    MONTH_TTL = 40.days

    KEY_NAMESPACE = "price_provider/budget".freeze

    attr_reader :provider

    # `limits:` overrides the built-in LIMITS (used in tests and for any
    # provider not in the table); the class itself is provider-agnostic.
    def initialize(provider, cache: Rails.cache, limits: nil)
      @provider = provider.to_s
      @cache = cache
      @limits = (limits || LIMITS[@provider] ||
        raise(ArgumentError, "no budget limits for provider #{provider.inspect}; pass limits:")
      ).symbolize_keys
    end

    # Charge `cost` request(s) against the daily budget and (if configured) the
    # hourly pacing window. Both windows are checked BEFORE either is mutated,
    # so a refused request never half-charges a counter. Raises BudgetExceeded.
    # Returns the number of requests remaining in the daily budget.
    def charge!(cost = 1)
      cost = Integer(cost)
      raise ArgumentError, "cost must be positive" unless cost.positive?

      if daily_limit && requests_today + cost > daily_limit
        raise BudgetExceeded.new(
          "#{provider}: daily request budget of #{daily_limit} exhausted",
          retry_after: seconds_until_day_reset)
      end
      if hourly_limit && requests_this_hour + cost > hourly_limit
        raise BudgetExceeded.new(
          "#{provider}: hourly pacing limit of #{hourly_limit}/hr reached",
          retry_after: seconds_until_hour_reset)
      end

      cache.increment(daily_key, cost, expires_in: DAY_TTL)  if daily_limit
      cache.increment(hourly_key, cost, expires_in: HOUR_TTL) if hourly_limit
      remaining_today
    end

    # Register a distinct-symbol fetch against the monthly unique-symbol quota.
    # Idempotent per symbol per month: a symbol already counted this month is
    # free and never raises, even at the cap (re-fetching known data is fine).
    # A NEW symbol beyond the cap raises BudgetExceeded and is NOT counted.
    # Returns the month's unique-symbol count.
    def register_symbol!(symbol)
      unless monthly_symbol_limit
        raise ArgumentError, "#{provider} has no monthly unique-symbol quota"
      end
      sym = normalize_symbol(symbol)

      # Only the first increment of the per-symbol marker returns 1; any later
      # value means this symbol was already counted this month.
      seen = cache.increment(symbol_seen_key(sym), 1, expires_in: MONTH_TTL)
      return unique_symbols_this_month if seen && seen > 1

      total = cache.increment(symbol_count_key, 1, expires_in: MONTH_TTL)
      if total > monthly_symbol_limit
        # Undo: a refused symbol must not be remembered as "already counted",
        # or a later re-fetch would wrongly sail through for free.
        cache.decrement(symbol_count_key, 1)
        cache.delete(symbol_seen_key(sym))
        raise BudgetExceeded.new(
          "#{provider}: monthly unique-symbol quota of #{monthly_symbol_limit} reached",
          retry_after: seconds_until_month_reset)
      end
      total
    end

    # --- Introspection (for jobs to pace/skip without triggering a raise) ---

    def requests_today = cache.read(daily_key).to_i
    def requests_this_hour = cache.read(hourly_key).to_i
    def unique_symbols_this_month = cache.read(symbol_count_key).to_i

    def remaining_today
      daily_limit ? [ daily_limit - requests_today, 0 ].max : nil
    end

    def remaining_this_hour
      hourly_limit ? [ hourly_limit - requests_this_hour, 0 ].max : nil
    end

    def remaining_symbols_this_month
      monthly_symbol_limit ? [ monthly_symbol_limit - unique_symbols_this_month, 0 ].max : nil
    end

    def daily_limit = @limits[:daily]
    def hourly_limit = @limits[:hourly]
    def monthly_symbol_limit = @limits[:monthly_symbols]

    private

    attr_reader :cache

    def normalize_symbol(symbol)
      sym = symbol.to_s.strip.upcase
      raise ArgumentError, "blank symbol" if sym.empty?
      sym
    end

    # All periods are computed in America/New_York (respects Time travel in
    # tests, since TimeZone#now reads Time.now under the hood).
    def now = ActiveSupport::TimeZone[PriceProvider::TIME_ZONE].now

    def key_prefix = "#{KEY_NAMESPACE}/#{provider}"
    def daily_key = "#{key_prefix}/daily/#{now.strftime('%Y-%m-%d')}"
    def hourly_key = "#{key_prefix}/hourly/#{now.strftime('%Y-%m-%d-%H')}"
    def month_prefix = "#{key_prefix}/symbols/#{now.strftime('%Y-%m')}"
    def symbol_count_key = "#{month_prefix}/count"
    def symbol_seen_key(sym) = "#{month_prefix}/seen/#{sym}"

    def seconds_until_day_reset   = (now.end_of_day - now).ceil + 1
    def seconds_until_hour_reset  = (now.end_of_hour - now).ceil + 1
    def seconds_until_month_reset = (now.end_of_month.end_of_day - now).ceil + 1
  end
end
