require "test_helper"

module InternalApi
  # Issue #75. The behaviour under test is *diagnostic output*, so these assert on
  # what a deployer reading the log would actually see — and on the two rules that
  # must not be broken while providing it: the token value is never logged, and
  # the blank/wrong distinction never leaves the log.
  class TokenTest < ActiveSupport::TestCase
    SECRET = "s3cr3t-internal-token-for-tests".freeze

    setup do
      @original = ENV["INTERNAL_API_TOKEN"]
    end

    teardown do
      ENV["INTERNAL_API_TOKEN"] = @original
    end

    # A logger that keeps everything written to it, at any level, so a test can
    # assert about the whole output rather than one expected line.
    class CapturingLogger
      attr_reader :lines

      def initialize = @lines = []

      %i[debug info warn error fatal unknown].each do |level|
        define_method(level) { |message = nil, &block| @lines << "#{level}: #{message || block&.call}" }
      end

      def text = lines.join("\n")
    end

    def with_token(value)
      ENV["INTERNAL_API_TOKEN"] = value
      yield
    end

    # -- configured? ----------------------------------------------------------

    test "a blank, whitespace-only or unset variable is NOT configured" do
      [ nil, "", "   ", "\t\n" ].each do |value|
        with_token(value) do
          assert_not Token.configured?, "#{value.inspect} must not count as configured"
        end
      end
    end

    test "a real value is configured" do
      with_token(SECRET) { assert Token.configured? }
    end

    # -- matches? -------------------------------------------------------------

    test "matches only the exact configured token" do
      with_token(SECRET) do
        assert Token.matches?(SECRET)

        [ SECRET[0..-2], "#{SECRET}x", SECRET.upcase, SECRET.reverse, "", "   ", nil ].each do |candidate|
          assert_not Token.matches?(candidate), "#{candidate.inspect} must not match"
        end
      end
    end

    test "nothing matches while the variable is blank — including a blank presentation" do
      [ nil, "", "   " ].each do |configured|
        with_token(configured) do
          [ nil, "", "   ", SECRET, "anything" ].each do |presented|
            assert_not Token.matches?(presented),
                       "#{presented.inspect} must not authenticate against #{configured.inspect}"
          end
        end
      end
    end

    # -- the boot line --------------------------------------------------------

    test "the boot line says ENABLED when the variable is set" do
      logger = CapturingLogger.new

      with_token(SECRET) { Token.log_status(logger:) }

      assert_equal 1, logger.lines.size
      assert_match(/info:/, logger.text)
      assert_match(/ENABLED/, logger.text)
      assert_no_match(/DISABLED/, logger.text)
    end

    test "the boot line says DISABLED and names the variable when it is blank" do
      [ nil, "", "   " ].each do |configured|
        logger = CapturingLogger.new

        with_token(configured) { Token.log_status(logger:) }

        assert_match(/DISABLED/, logger.text)
        assert_match(/INTERNAL_API_TOKEN/, logger.text,
                     "a deployer who typo'd the NAME must see the name it expects")
        assert_match(/401/, logger.text, "say what the consequence is, not just that it is off")
      end
    end

    # -- the rejection line ---------------------------------------------------

    test "a rejection while blank says it is not a token mismatch" do
      logger = CapturingLogger.new

      with_token("") { Token.log_rejection(logger:) }

      assert_equal 1, logger.lines.size
      assert_match(/not configured/, logger.text)
      assert_match(/NOT a token mismatch/, logger.text)
    end

    test "a rejection while CONFIGURED logs nothing at all" do
      logger = CapturingLogger.new

      with_token(SECRET) { Token.log_rejection(logger:) }

      # A line on every wrong-token 401 would flood the log for anyone probing
      # the endpoint, and the wrong-token case was never the ambiguous one.
      assert_empty logger.lines
    end

    # -- rule 1: the token value is never logged ------------------------------

    test "no logging path ever emits the token value" do
      logger = CapturingLogger.new

      with_token(SECRET) do
        Token.log_status(logger:)
        Token.log_rejection(logger:)
        Token.matches?(SECRET)
        Token.matches?("wrong")
      end

      assert_not_includes logger.text, SECRET
      # Also not a prefix long enough to be worth brute-forcing the rest of.
      assert_not_includes logger.text, SECRET[0, 8]
    end
  end
end
