defmodule OptionsTest do
  use ExUnit.Case, async: true

  alias Peep.Options

  test "docs/0 returns a string" do
    assert is_binary(Options.docs())
  end

  test "validate/1 returns error when required options are missing" do
    assert {:error, msg} = Options.validate(name: :test)
    assert msg =~ "metrics"
  end

  describe "host/1" do
    test "accepts a valid IP tuple" do
      assert {:ok, {127, 0, 0, 1}} = Options.host({127, 0, 0, 1})
    end

    test "rejects an invalid IP tuple" do
      assert {:error, msg} = Options.host({999, 999, 999})
      assert msg =~ "valid IP address"
    end

    test "accepts a binary hostname" do
      assert {:ok, ~c"example.com"} = Options.host("example.com")
    end

    test "rejects non-tuple non-binary values" do
      assert {:error, msg} = Options.host(12345)
      assert msg =~ "IP address or a hostname"
    end
  end

  describe "socket_path/1" do
    test "accepts a binary path" do
      assert {:ok, {:local, ~c"/tmp/peep.sock"}} = Options.socket_path("/tmp/peep.sock")
    end

    test "rejects non-binary values" do
      assert {:error, msg} = Options.socket_path(12345)
      assert msg =~ "socket_path"
    end
  end

  describe "formatter/1" do
    test "accepts :standard" do
      assert {:ok, :standard} = Options.formatter(:standard)
    end

    test "accepts :datadog" do
      assert {:ok, :datadog} = Options.formatter(:datadog)
    end

    test "rejects other values" do
      assert {:error, msg} = Options.formatter(:invalid)
      assert msg =~ "formatter"
    end
  end

  test "validate with statsd socket_path renames to host" do
    assert {:ok, opts} =
             Options.validate(
               name: :socket_path_test,
               metrics: [],
               statsd: [socket_path: "/tmp/peep.sock"]
             )

    assert {:local, ~c"/tmp/peep.sock"} = opts.statsd[:host]
    refute Keyword.has_key?(opts.statsd, :socket_path)
  end

  test "validate with statsd options without socket_path preserves host" do
    assert {:ok, opts} =
             Options.validate(
               name: :no_socket_path_test,
               metrics: [],
               statsd: [host: {127, 0, 0, 1}, port: 8125]
             )

    assert {127, 0, 0, 1} = opts.statsd[:host]
  end
end
