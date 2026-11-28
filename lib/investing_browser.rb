# frozen_string_literal: true

require 'ferrum'

module TradingLogic
  class InvestingBrowser
    PRICE_WAIT = 5

    class HttpError < StandardError; end
    class PriceUnavailable < StandardError; end

    def self.path
      configured = ENV['BROWSER_PATH'].to_s.strip
      return configured unless configured.empty?

      ENV.fetch('PATH', '').split(File::PATH_SEPARATOR).each do |dir|
        path = File.join(dir, 'chrome-headless-shell')
        return path if File.file?(path) && File.executable?(path)
      end
      nil
    end

    def initialize(path, sleep_proc:, warn_proc:)
      @path = path
      @sleep_proc = sleep_proc
      @warn_proc = warn_proc
    end

    def fetch_html(uri, price_selector:)
      browser = session
      browser.network.clear(:traffic)
      browser.goto(uri.to_s)
      status = browser.network.status
      raise HttpError, "HTTP #{status || 'status unavailable'} for #{uri}" unless status&.between?(200, 299)

      wait_for_price(browser, price_selector, uri)
      browser.body
    end

    def close
      @session&.quit
    rescue Ferrum::Error, SystemCallError => e
      @warn_proc.call("InvestingBrowser: shutdown failed: #{e.class}: #{e.message}")
    ensure
      @session = @start_error = nil
    end

    private

    def session
      raise @start_error if @start_error

      flags = { 'headless' => nil, 'disable-dev-shm-usage' => nil, 'lang' => 'ru-RU' }
      flags['no-sandbox'] = nil if ENV['BROWSER_NO_SANDBOX'] == '1'
      @session ||= Ferrum::Browser.new(
        browser_path: @path, timeout: 12, process_timeout: 10,
        ignore_default_browser_options: true, browser_options: flags
      )
    rescue Ferrum::Error, SystemCallError => e
      @start_error = e
      raise
    end

    def wait_for_price(browser, selector, uri)
      deadline = Process.clock_gettime(Process::CLOCK_MONOTONIC) + PRICE_WAIT
      until browser.at_css(selector)
        raise PriceUnavailable, "price not found in browser page #{uri}" if Process.clock_gettime(Process::CLOCK_MONOTONIC) >= deadline

        @sleep_proc.call(0.2)
      end
    end
  end
end
