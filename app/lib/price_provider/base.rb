# Faraday and its retry middleware are required explicitly so the `:retry`
# handler is registered regardless of Bundler's autorequire path (the gem is
# "faraday-retry" but the middleware lives under "faraday/retry").
require "faraday"
require "faraday/retry"

module PriceProvider
  # Shared HTTP plumbing for the provider adapters: one Faraday connection
  # with faraday-retry, typed status-code mapping, BigDecimal JSON parsing,
  # and the row-validation helpers every adapter uses.
  #
  # Subclasses define:
  #   API_KEY_ENV - name of the ENV var holding the key
  #   BASE_URL    - the provider's origin
  # and add their auth header via #default_headers.
  #
  # The API key is never logged and never appears in an error message; the
  # only place it may travel is the request itself (header or query param).
  class Base
    OPEN_TIMEOUT = 5   # seconds
    TIMEOUT = 15       # seconds

    # Transient 5xx and network hiccups are retried in-process; 429 is NOT
    # (jobs must respect RateLimited#retry_after instead of hammering).
    RETRY_OPTIONS = {
      max: 2,
      interval: 0.25,
      backoff_factor: 2,
      methods: [ :get ],
      retry_statuses: [ 500, 502, 503, 504 ]
    }.freeze

    DEFAULT_RETRY_AFTER = 60 # seconds, when the provider sends no hint

    # v1 is US-listed/USD only; this also keeps symbols path-safe.
    SYMBOL_FORMAT = /\A[A-Z0-9.\-]{1,12}\z/

    # faraday_adapter: pass `[:test, stubs]` in unit tests so requests hit
    # recorded fixtures instead of the network (testing-conventions: mock at
    # the Faraday adapter boundary).
    def initialize(api_key: nil, faraday_adapter: Faraday.default_adapter,
                   retry_options: RETRY_OPTIONS, logger: Rails.logger)
      @api_key = api_key.presence || ENV[self.class::API_KEY_ENV].presence
      if @api_key.nil?
        raise ConfigurationError, "#{self.class::API_KEY_ENV} is not set (see .env.example)"
      end
      @faraday_adapter = faraday_adapter
      @retry_options = retry_options
      @logger = logger
    end

    private

    attr_reader :api_key, :logger

    def provider_name = self.class.name.demodulize.underscore

    def connection
      @connection ||= Faraday.new(
        url: self.class::BASE_URL,
        headers: default_headers,
        request: { timeout: TIMEOUT, open_timeout: OPEN_TIMEOUT }
      ) do |f|
        f.request :retry, @retry_options
        f.adapter(*Array(@faraday_adapter))
      end
    end

    def default_headers = { "Accept" => "application/json" }

    # GET + typed status mapping + BigDecimal JSON parse. Never returns nil.
    def get_json(path, params = {})
      response = connection.get(path, params)
      handle_status!(response, path)
      parse_json(response.body, path)
    rescue Faraday::ConnectionFailed, Faraday::TimeoutError, Faraday::SSLError => e
      # Deliberately reports only the exception class: Faraday messages can
      # embed the full URL, which for some providers carries the API key.
      raise ServerError, "#{provider_name}: request failed (#{e.class.name}) for #{path}"
    end

    def handle_status!(response, path)
      case response.status
      when 200..299 then nil
      when 404
        raise UnknownSymbol, "#{provider_name}: not found (HTTP 404) for #{path}"
      when 429
        raise RateLimited.new("#{provider_name}: rate limited (HTTP 429) for #{path}",
                              retry_after: retry_after_seconds(response))
      when 401, 403
        raise ConfigurationError, "#{provider_name}: credentials rejected (HTTP #{response.status})"
      when 500..599
        raise ServerError, "#{provider_name}: server error (HTTP #{response.status}) for #{path}"
      else
        raise Error, "#{provider_name}: unexpected HTTP #{response.status} for #{path}"
      end
    end

    def retry_after_seconds(response)
      Integer(response.headers["Retry-After"], 10)
    rescue ArgumentError, TypeError
      DEFAULT_RETRY_AFTER
    end

    def parse_json(body, path)
      # decimal_class keeps every fractional number a BigDecimal end to end;
      # no Float ever exists between the wire and the caller.
      JSON.parse(body.to_s, decimal_class: BigDecimal)
    rescue JSON::ParserError
      raise MalformedResponse, "#{provider_name}: response for #{path} is not valid JSON"
    end

    def normalize_symbol(symbol)
      sym = symbol.to_s.strip.upcase
      raise ArgumentError, "invalid symbol #{symbol.inspect}" unless SYMBOL_FORMAT.match?(sym)
      sym
    end

    # Mirrors the daily_prices DB CHECK (high >= low AND low > 0) plus
    # positivity of all four legs, so a bad provider row is skipped here and
    # can never fail (or poison) the batch upsert downstream.
    def valid_ohlc?(open, high, low, close)
      [ open, high, low, close ].all? { |v| v.is_a?(Numeric) && v.positive? } && high >= low
    end

    def to_decimal(value)
      case value
      when BigDecimal then value
      when Integer then value.to_d
      when String then BigDecimal(value)
      when Float then value.to_d # defensive; decimal_class should prevent this
      end
    rescue ArgumentError
      nil
    end

    def parse_date(value)
      Date.iso8601(value.to_s[0, 10])
    rescue ArgumentError, TypeError
      nil
    end

    # Logs and returns the warning so adapters can both surface it on the
    # DailySeries and leave a trace in the logs.
    def skip_warning(symbol, message)
      text = "#{provider_name} #{symbol}: #{message}"
      logger.warn(text)
      text
    end
  end
end
