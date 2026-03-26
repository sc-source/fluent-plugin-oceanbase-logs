require 'net/http'
require 'uri'
require 'json'
require 'openssl'
require 'time'
require 'digest'
require 'securerandom'
require 'fluent/plugin/input'

module Fluent::Plugin
  class OceanBaseLogsInput < Input
    Fluent::Plugin.register_input('oceanbase_logs', self)

    helpers :thread, :storage

    DEFAULT_STORAGE_TYPE = 'local'

    LOG_TYPE_PATHS = {
      'slow_sql' => 'slowSql',
      'top_sql'  => 'topSql',
    }.freeze

    config_param :log_type, :enum, list: LOG_TYPE_PATHS.keys.map(&:to_sym), default: :slow_sql,
      desc: "Type of SQL diagnostics to collect: slow_sql or top_sql."

    config_param :access_key_id, :string, secret: true,
      desc: "OceanBase Cloud AccessKey ID."
    config_param :access_key_secret, :string, secret: true,
      desc: "OceanBase Cloud AccessKey Secret."

    config_param :instance_id, :string,
      desc: "OceanBase cluster instance ID."
    config_param :tenant_id, :string,
      desc: "OceanBase tenant ID."
    config_param :project_id, :string, default: nil,
      desc: "OceanBase Cloud project ID (X-Ob-Project-Id header)."

    config_param :db_name, :string, default: nil,
      desc: "Filter by database name."
    config_param :search_keyword, :string, default: nil,
      desc: "Search keyword for SQL text."
    config_param :node_ip, :string, default: nil,
      desc: "Filter by database node IP."
    config_param :filter_condition, :string, default: nil,
      desc: "Advanced filter (e.g. '@avgCpuTime > 20 and @executions > 100')."
    config_param :sql_text_length, :integer, default: 65535,
      desc: "Max length of SQL text returned."

    config_param :tag, :string,
      desc: "Fluentd tag for emitted events."
    config_param :fetch_interval, :time, default: 300,
      desc: "Seconds between each API poll (default 5 min)."
    config_param :lookback_seconds, :integer, default: 600,
      desc: "How far back each query window looks (default 10 min)."
    config_param :endpoint, :string, default: 'api-cloud-cn.oceanbase.com',
      desc: "API endpoint."
    config_param :http_proxy, :string, default: nil,
      desc: "HTTP proxy URL."
    config_param :ssl_verify_peer, :bool, default: true,
      desc: "Verify SSL certificates."

    config_param :deduplicate, :bool, default: true,
      desc: "Enable deduplication (by traceId)."
    config_param :include_metadata, :bool, default: true,
      desc: "Attach instance_id / tenant_id / log_type to each record."

    config_section :storage do
      config_set_default :usage, 'seen_traces'
      config_set_default :@type, DEFAULT_STORAGE_TYPE
      config_set_default :persistent, false
    end

    def configure(conf)
      super
      @endpoint = @endpoint.to_s.strip
      @endpoint = 'api-cloud-cn.oceanbase.com' if @endpoint.empty?

      %i[@access_key_id @access_key_secret @instance_id @tenant_id].each do |iv|
        v = instance_variable_get(iv)
        next unless v.is_a?(String)
        instance_variable_set(iv, v.strip)
      end
      raise Fluent::ConfigError, 'access_key_id is required and cannot be empty' if @access_key_id.empty?
      raise Fluent::ConfigError, 'access_key_secret is required and cannot be empty' if @access_key_secret.empty?
      raise Fluent::ConfigError, 'instance_id is required and cannot be empty (e.g. set OCEANBASE_INSTANCE_ID)' if @instance_id.empty?
      raise Fluent::ConfigError, 'tenant_id is required and cannot be empty (e.g. set OCEANBASE_TENANT_ID)' if @tenant_id.empty?

      %i[@db_name @search_keyword @node_ip @filter_condition @project_id].each do |iv|
        v = instance_variable_get(iv)
        instance_variable_set(iv, nil) if v.is_a?(String) && v.strip.empty?
      end
      @api_path_segment = LOG_TYPE_PATHS[@log_type.to_s]
      if @deduplicate
        @seen_storage = storage_create(
          usage: 'seen_traces',
          conf: config,
          default_type: DEFAULT_STORAGE_TYPE
        )
      end
    end

    def start
      super
      @finished = false
      thread_create(:in_oceanbase_logs_runner, &method(:run))
    end

    def shutdown
      @finished = true
      super
    end

    private

    def run
      until @finished
        begin
          fetch_and_emit
        rescue => e
          log.error "Failed to fetch OceanBase #{@log_type} data",
                    error: e.message, error_class: e.class.to_s
          log.debug_backtrace(e.backtrace)
        end
        sleep_interruptible(@fetch_interval)
      end
    end

    def sleep_interruptible(seconds)
      seconds.to_i.times do
        break if @finished
        sleep 1
      end
    end

    def fetch_and_emit
      now = Time.now.utc
      start_time = (now - @lookback_seconds).strftime('%Y-%m-%dT%H:%M:%SZ')
      end_time   = now.strftime('%Y-%m-%dT%H:%M:%SZ')
      fetch_and_emit_samples(start_time, end_time)
    end

    # Fetch list then per-execution samples (one record per trace)
    def fetch_and_emit_samples(start_time, end_time)
      list_response = call_list_api(start_time, end_time)
      return unless list_response

      sql_records = extract_records(list_response)
      return if sql_records.nil? || sql_records.empty?

      sql_ids = sql_records.map { |r| r['sqlId'] }.compact.uniq
      log.debug "Found #{sql_ids.size} unique SQL IDs, fetching samples..."

      total_emitted = 0

      sql_ids.each do |sql_id|
        samples = fetch_samples_for_sql(sql_id, start_time, end_time)
        next if samples.nil? || samples.empty?

        es = Fluent::MultiEventStream.new

        samples.each do |sample|
          trace_id = sample['traceId']
          dedup_id = trace_id || "#{sql_id}_#{sample['requestTime']}"

          if @deduplicate
            dedup_key = :"trace_#{dedup_id}"
            next if @seen_storage.get(dedup_key)
            @seen_storage.put(dedup_key, Time.now.to_i.to_s)
          end

          sample['ob_log_type'] = @log_type.to_s
          sample = attach_metadata(sample, start_time, end_time) if @include_metadata

          event_time = if sample['requestTime']
                         begin
                           Fluent::EventTime.from_time(Time.parse(sample['requestTime']))
                         rescue
                           Fluent::EventTime.now
                         end
                       else
                         Fluent::EventTime.now
                       end

          es.add(event_time, sample)
        end

        unless es.empty?
          router.emit_stream(@tag, es)
          total_emitted += es.size
        end
      end

      log.info "Emitted #{total_emitted} #{@log_type} sample events (#{start_time} ~ #{end_time})" if total_emitted > 0
    end

    def fetch_samples_for_sql(sql_id, start_time, end_time)
      path = "/api/v2/instances/#{@instance_id}/tenants/#{@tenant_id}/sqls/#{sql_id}/samples"
      params = {
        'startTime' => start_time,
        'endTime'   => end_time,
      }
      params['dbName'] = @db_name if @db_name

      response = call_api_raw(path, params)
      return nil unless response
      extract_records(response)
    end

    def attach_metadata(record, start_time, end_time)
      record.merge(
        'ob_instance_id'   => @instance_id,
        'ob_tenant_id'     => @tenant_id,
        'query_start_time' => start_time,
        'query_end_time'   => end_time
      )
    end

    def extract_records(response)
      data = response['data']
      return [] if data.nil?

      if data.is_a?(Hash)
        list = data['dataList']
        return list if list.is_a?(Array)
        return [] if list.nil? || list == []
      elsif data.is_a?(Array)
        return data
      end

      log.warn "Unexpected API response structure",
               keys: response.keys, data_class: data.class.name,
               data_keys: (data.respond_to?(:keys) ? data.keys : nil)
      []
    end

    # ---- API calls ----

    def call_list_api(start_time, end_time)
      path = "/api/v2/instances/#{@instance_id}/tenants/#{@tenant_id}/#{@api_path_segment}"
      params = {
        'startTime' => start_time,
        'endTime'   => end_time,
      }
      params['dbName']          = @db_name          if @db_name
      params['searchKeyWord']   = @search_keyword   if @search_keyword
      params['nodeIp']          = @node_ip           if @node_ip
      params['filterCondition'] = @filter_condition  if @filter_condition
      params['sqlTextLength']   = @sql_text_length.to_s

      call_api_raw(path, params)
    end

    def call_api_raw(path, params)
      query = params.map { |k, v| "#{URI.encode_www_form_component(k)}=#{URI.encode_www_form_component(v)}" }.join('&')
      uri = URI("https://#{@endpoint}#{path}?#{query}")

      http = build_http(uri)
      resp = nil

      http.start do |session|
        resp = request_with_digest_auth(session, uri)
      end

      unless resp && resp.code.to_i == 200
        code = resp&.code
        raw  = resp&.body.to_s
        detail = nil
        begin
          j = JSON.parse(raw)
          detail = j['message'] || j['errorMessage'] || j['msg']
        rescue JSON::ParserError
        end
        log.error "OceanBase API HTTP #{code}",
                  message: detail, body: (raw.bytesize > 512 ? raw.byteslice(0, 512) + '...' : raw), path: path
        return nil
      end

      body = JSON.parse(resp.body)
      unless body['success'] == true
        log.error "OceanBase API error",
                  code: body['errorCode'], message: body['errorMessage'], path: path
        return nil
      end
      body
    rescue JSON::ParserError => e
      log.error "Failed to parse API response", error: e.message, path: path
      nil
    end

    # ---- HTTP Digest Auth ----

    def request_with_digest_auth(session, uri)
      req = Net::HTTP::Get.new(uri)
      req['X-Ob-Project-Id'] = @project_id if @project_id

      initial_resp = session.request(req)
      return initial_resp unless initial_resp.code.to_i == 401

      auth_header = initial_resp['www-authenticate']
      return initial_resp unless auth_header && auth_header.start_with?('Digest')

      digest = build_digest_header(auth_header, uri, 'GET')
      retry_req = Net::HTTP::Get.new(uri)
      retry_req['X-Ob-Project-Id'] = @project_id if @project_id
      retry_req['Authorization'] = digest

      session.request(retry_req)
    end

    def build_digest_header(www_auth, uri, method)
      params = parse_digest_challenge(www_auth)
      realm  = params['realm']
      nonce  = params['nonce']
      qop    = params['qop']
      opaque = params['opaque']

      nc = '00000001'
      cnonce = SecureRandom.hex(8)

      ha1 = md5("#{@access_key_id}:#{realm}:#{@access_key_secret}")
      ha2 = md5("#{method}:#{uri.request_uri}")

      if qop
        response = md5("#{ha1}:#{nonce}:#{nc}:#{cnonce}:#{qop}:#{ha2}")
      else
        response = md5("#{ha1}:#{nonce}:#{ha2}")
      end

      header = %Q(Digest username="#{@access_key_id}", realm="#{realm}", nonce="#{nonce}", uri="#{uri.request_uri}", response="#{response}")
      header += %Q(, qop=#{qop}, nc=#{nc}, cnonce="#{cnonce}") if qop
      header += %Q(, opaque="#{opaque}") if opaque
      header
    end

    def parse_digest_challenge(header)
      params = {}
      header.sub(/^Digest\s+/, '').scan(/(\w+)="([^"]*)"/) do |key, value|
        params[key] = value
      end
      header.sub(/^Digest\s+/, '').scan(/(\w+)=([^",\s]+)/) do |key, value|
        params[key] ||= value
      end
      params
    end

    def md5(str)
      Digest::MD5.hexdigest(str)
    end

    def build_http(uri)
      if @http_proxy
        proxy = URI(@http_proxy)
        http = Net::HTTP.new(uri.host, uri.port,
                             proxy.host, proxy.port, proxy.user, proxy.password)
      else
        http = Net::HTTP.new(uri.host, uri.port)
      end
      http.use_ssl     = true
      http.verify_mode = @ssl_verify_peer ? OpenSSL::SSL::VERIFY_PEER : OpenSSL::SSL::VERIFY_NONE
      http.open_timeout = 30
      http.read_timeout = 60
      http
    end
  end
end
