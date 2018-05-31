require 'fluent/plugin/input'
require 'fluent/plugin/prometheus'
require 'webrick'
require 'webrick/https'
require 'openssl'


module Fluent::Plugin
  class PrometheusInput < Fluent::Plugin::Input
    Fluent::Plugin.register_input('prometheus', self)

    helpers :thread

    config_param :bind, :string, default: '0.0.0.0'
    config_param :port, :integer, default: 24231
    config_param :metrics_path, :string, default: '/metrics'
    config_param :cert_file, :string, default: 'none'
    config_param :pkey_file, :string, default: 'none'


    attr_reader :registry

    def initialize
      super
      @registry = ::Prometheus::Client.registry
    end

    def configure(conf)
      super
      @port += fluentd_worker_id
    end

    def multi_workers_ready?
      true
    end

    def start
      super

      log.debug "listening prometheus http server on http://#{@bind}:#{@port}/#{@metrics_path} for worker#{fluentd_worker_id}"
      if (@cert_file !='none') && (@pkey_file !='none')
        @cert = OpenSSL::X509::Certificate.new File.read @cert_file
        @pkey = OpenSSL::PKey::RSA.new File.read @pkey_file
        @server = WEBrick::HTTPServer.new(
          BindAddress: @bind,
          Port: @port,
          MaxClients: 5,
          Logger: WEBrick::Log.new(STDERR, WEBrick::Log::FATAL),
          AccessLog: [],
          SSLEnable: true,
          SSLCertificate: @cert,
          SSLPrivateKey: @pkey,
        )
      else
        @server = WEBrick::HTTPServer.new(
          BindAddress: @bind,
          Port: @port,
          MaxClients: 5,
          Logger: WEBrick::Log.new(STDERR, WEBrick::Log::FATAL),
          AccessLog: [],
        )
      end
      @server.mount(@metrics_path, MonitorServlet, self)
      thread_create(:in_prometheus) do
        @server.start
      end
    end

    def shutdown
      if @server
        @server.shutdown
        @server = nil
      end
      super
    end

    class MonitorServlet < WEBrick::HTTPServlet::AbstractServlet
      def initialize(server, prometheus)
        @prometheus = prometheus
      end

      def do_GET(req, res)
        res.status = 200
        res['Content-Type'] = ::Prometheus::Client::Formats::Text::CONTENT_TYPE
        res.body = ::Prometheus::Client::Formats::Text.marshal(@prometheus.registry)
      rescue
        res.status = 500
        res['Content-Type'] = 'text/plain'
        res.body = $!.to_s
      end
    end
  end
end
