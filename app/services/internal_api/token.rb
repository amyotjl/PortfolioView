module InternalApi
  # The /api/internal bearer credential, and — the point of issue #75 — the one
  # place that SAYS OUT LOUD which of its two states the deployment is in.
  #
  # WHY THIS EXISTS AT ALL. Failing closed on a blank token is correct and
  # deliberate: a deploy that forgets the variable is inert rather than wide
  # open. But a blank token answers 401 to a *correct* token exactly as it does
  # to a wrong one, and nothing anywhere said which situation you were in. That
  # is not hypothetical — it is what disguised #58's real defect (compose never
  # forwarded INTERNAL_API_TOKEN to `web-prod`) long enough for two separate
  # gates to miss it. The endless 401 read as "my token is wrong".
  #
  # THE FIX IS OBSERVABILITY, NOT ENFORCEMENT, and that was settled with
  # evidence in #58 — don't reopen it:
  #
  #   * `${VAR}` and `${VAR:-}` BOTH resolve to an empty string and both boot.
  #     The bare form buys a stderr warning and nothing else.
  #   * Real enforcement needs `${VAR:?}`, which docker-compose.yml's own header
  #     rules out: interpolation runs at file-parse time for EVERY service,
  #     including profiled ones, so it would break a plain `docker compose up`
  #     for the dev stack whenever the variable is unset.
  #   * Unset is a LEGITIMATE deployment choice. The Settings "Sync now" button
  #     uses session auth and needs no token; unset was confirmed to be a clean
  #     disable (healthy container, `/up` and `/` 200, boot catch-up normal).
  #
  # TWO RULES FOR ANYTHING ADDED HERE.
  #
  # 1. The token value is never logged, at any level. Only its PRESENCE is.
  # 2. The distinction never reaches the HTTP response. A 401 body that admitted
  #    "the server has no token configured" would tell an unauthenticated caller
  #    about the deployment's state. The envelope stays byte-identical between
  #    the blank-token and wrong-token cases; `jobs_controller_test.rb` asserts
  #    that rather than trusting it.
  module Token
    ENV_NAME = "INTERNAL_API_TOKEN".freeze
    LOG_TAG = "[InternalApi]".freeze

    ENABLED_MESSAGE = "internal API namespace: ENABLED (#{ENV_NAME} is set)".freeze

    DISABLED_MESSAGE = (
      "internal API namespace: DISABLED (#{ENV_NAME} is blank or unset, so every " \
      "/api/internal request answers 401 no matter what token it carries). This is a " \
      "supported configuration: the Settings Sync-now button uses session auth and is " \
      "unaffected."
    ).freeze

    REJECTION_MESSAGE = (
      "rejected an /api/internal request: #{ENV_NAME} is not configured, so NO token can " \
      "authenticate here. This is NOT a token mismatch — set the variable to enable the " \
      "namespace."
    ).freeze

    class << self
      def configured? = ENV[ENV_NAME].present?

      # Constant-time compare so the token can't be recovered byte-by-byte from
      # response timing; `secure_compare` digests first, so unequal lengths are
      # safe too. Blank on either side authenticates nobody.
      def matches?(presented)
        configured = ENV[ENV_NAME]

        configured.present? && presented.present? &&
          ActiveSupport::SecurityUtils.secure_compare(configured, presented)
      end

      # One line in the boot log, in the place a deployer is already looking.
      # Both directions are logged: "ENABLED" is what confirms a token that IS
      # set, which is half of what made the original bug invisible.
      def log_status(logger: Rails.logger)
        logger.info("#{LOG_TAG} #{configured? ? ENABLED_MESSAGE : DISABLED_MESSAGE}")
      end

      # Logged at the moment of confusion, and ONLY in the blank-token case — a
      # line on every wrong-token 401 would be a log-flooding gift to anyone
      # probing the endpoint, and the wrong-token case is not ambiguous anyway.
      def log_rejection(logger: Rails.logger)
        return if configured?

        logger.info("#{LOG_TAG} #{REJECTION_MESSAGE}")
      end
    end
  end
end
