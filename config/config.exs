import Config

if config_env() == :test do
  config :peep, udp_module: Peep.Test.UDP
end
