# encoding: utf-8
require "logstash/inputs/base"
require "logstash/namespace"
require "logstash/json"
require "logstash/util/safe_uri"
require "base64"
require "logstash/plugin_mixins/jdbc/jdbc"



# .Compatibility Note
# [NOTE]
# ================================================================================
# Starting with Elasticsearch 5.3, there's an {ref}modules-http.html[HTTP setting]
# called `http.content_type.required`. If this option is set to `true`, and you
# are using Logstash 2.4 through 5.2, you need to update the Elasticsearch input
# plugin to version 4.0.2 or higher.
# 
# ================================================================================
# 
# Read from an Elasticsearch cluster, based on search query results.
# This is useful for replaying test logs, reindexing, etc.
# It also supports periodically scheduling lookup enrichments
# using a cron syntax (see `schedule` setting).
#
# Example:
# [source,ruby]
#     input {
#       # Read all documents from Elasticsearch matching the given query
#       elasticsearch {
#         hosts => "localhost"
#         query => '{ "query": { "match": { "statuscode": 200 } }, "sort": [ "_doc" ] }'
#       }
#     }
#
# This would create an Elasticsearch query with the following format:
# [source,json]
#     curl 'http://localhost:9200/logstash-*/_search?&scroll=1m&size=1000' -d '{
#       "query": {
#         "match": {
#           "statuscode": 200
#         }
#       },
#       "sort": [ "_doc" ]
#     }'
#
# ==== Scheduling
#
# Input from this plugin can be scheduled to run periodically according to a specific
# schedule. This scheduling syntax is powered by https://github.com/jmettraux/rufus-scheduler[rufus-scheduler].
# The syntax is cron-like with some extensions specific to Rufus (e.g. timezone support ).
#
# Examples:
#
# |==========================================================
# | `* 5 * 1-3 *`               | will execute every minute of 5am every day of January through March.
# | `0 * * * *`                 | will execute on the 0th minute of every hour every day.
# | `0 6 * * * America/Chicago` | will execute at 6:00am (UTC/GMT -5) every day.
# |==========================================================
#
#
# Further documentation describing this syntax can be found https://github.com/jmettraux/rufus-scheduler#parsing-cronlines-and-time-strings[here].
#
#
class LogStash::Inputs::Myelastic < LogStash::Inputs::Base
  config_name "myelastic"

  default :codec, "json"

  # List of elasticsearch hosts to use for querying.
  # Each host can be either IP, HOST, IP:port or HOST:port.
  # Port defaults to 9200
  config :hosts, :validate => :array

  # Cloud ID, from the Elastic Cloud web console. If set `hosts` should not be used.
  #
  # For more info, check out the https://www.elastic.co/guide/en/logstash/current/connecting-to-cloud.html#_cloud_id[Logstash-to-Cloud documentation]
  config :cloud_id, :validate => :string

  # The index or alias to search.
  config :index, :validate => :string, :default => "logstash-*"

  # The query to be executed. Read the Elasticsearch query DSL documentation
  # for more info
  # https://www.elastic.co/guide/en/elasticsearch/reference/current/query-dsl.html
  config :query, :validate => :string, :default => '{ "sort": [ "_doc" ] }'

  # This allows you to set the maximum number of hits returned per scroll.
  config :size, :validate => :number, :default => 1000

  # This allows you to set the maximum number of hits returned per scroll.
  config :alive, :validate => :number, :default => 60
  # This parameter controls the keepalive time in seconds of the scrolling
  # request and initiates the scrolling process. The timeout applies per
  # round trip (i.e. between the previous scroll request, to the next).
  config :scroll, :validate => :string, :default => "1m"

  # This parameter controls the number of parallel slices to be consumed simultaneously
  # by this pipeline input.
  config :slices, :validate => :number

  # If set, include Elasticsearch document information such as index, type, and
  # the id in the event.
  #
  # It might be important to note, with regards to metadata, that if you're
  # ingesting documents with the intent to re-index them (or just update them)
  # that the `action` option in the elasticsearch output wants to know how to
  # handle those things. It can be dynamically assigned with a field
  # added to the metadata.
  #
  # Example
  # [source, ruby]
  #     input {
  #       myelastic {
  #         hosts => "es.production.mysite.org"
  #         index => "mydata-2018.09.*"
  #         query => "*"
  #         size => 500
  #         scroll => "5m"
  #         docinfo => true
  #       }
  #     }
  #     output {
  #       elasticsearch {
  #         index => "copy-of-production.%{[@metadata][_index]}"
  #         document_type => "%{[@metadata][_type]}"
  #         document_id => "%{[@metadata][_id]}"
  #       }
  #     }
  #
  config :docinfo, :validate => :boolean, :default => false

  # Where to move the Elasticsearch document information. By default we use the @metadata field.
  config :docinfo_target, :validate=> :string, :default => LogStash::Event::METADATA

  # List of document metadata to move to the `docinfo_target` field.
  # To learn more about Elasticsearch metadata fields read
  # http://www.elasticsearch.org/guide/en/elasticsearch/guide/current/_document_metadata.html
  config :docinfo_fields, :validate => :array, :default => ['_index', '_type', '_id']

  # Basic Auth - username
  config :user, :validate => :string

  # Basic Auth - password
  config :password, :validate => :password

  # Cloud authentication string ("<username>:<password>" format) is an alternative for the `user`/`password` configuration.
  #
  # For more info, check out the https://www.elastic.co/guide/en/logstash/current/connecting-to-cloud.html#_cloud_auth[Logstash-to-Cloud documentation]
  config :cloud_auth, :validate => :password

  # Set the address of a forward HTTP proxy.
  config :proxy, :validate => :uri_or_empty

  # SSL
  config :ssl, :validate => :boolean, :default => false

  # SSL Certificate Authority file in PEM encoded format, must also include any chain certificates as necessary 
  config :ca_file, :validate => :path

  # Schedule of when to periodically run statement, in Cron format
  # for example: "* * * * *" (execute query every minute, on the minute)
  #
  # There is no schedule by default. If no schedule is given, then the statement is run
  # exactly once.
  config :schedule, :validate => :string
# inspired from jdbc plugin to record the last record processed.

  # Path to file with last run time
  config :last_run_metadata_path, :validate => :string, :default => "#{ENV['HOME']}/.logstash_jdbc_last_run"

  # Use an incremental column value rather than a timestamp
  config :use_column_value, :validate => :boolean, :default => false

  # If tracking column value rather than timestamp, the column whose value is to be tracked
  config :tracking_column, :validate => :string

  # Type of tracking column. Currently only "numeric" and "timestamp"
  config :tracking_column_type, :validate => ['numeric', 'timestamp'], :default => 'numeric'

  # Whether the previous run state should be preserved
  config :clean_run, :validate => :boolean, :default => false

  # Whether to save state or not in last_run_metadata_path
  config :record_last_run, :validate => :boolean, :default => true

 # Timezone conversion.
      # SQL does not allow for timezone data in timestamp fields.  This plugin will automatically
      # convert your SQL timestamp fields to Logstash timestamps, in relative UTC time in ISO8601 format.
      #
      # Using this setting will manually assign a specified timezone offset, instead
      # of using the timezone setting of the local machine.  You must use a canonical
      # timezone, *America/Denver*, for example.
      config :jdbc_default_timezone, :validate => :string


  def register
    require "elasticsearch"
    require "rufus/scheduler"
    require "elasticsearch/transport/transport/http/manticore"

# added ER from jdbc
    if @use_column_value
      # Raise an error if @use_column_value is true, but no @tracking_column is set
      if @tracking_column.nil?
        raise(LogStash::ConfigurationError, "Must set :tracking_column if :use_column_value is true.")
      end
    end
    set_value_tracker(LogStash::PluginMixins::Jdbc::ValueTracking.build_last_value_tracker(self))
    logger.info("<<<<<< .  ER . >>>>>>> in build_last_value_tracker #{@value_tracker.value.to_s}")
    @original_query = @query.clone
#########
    @options = {
      :index => @index,
      :scroll => @scroll,
      :size => @size
    }

    # #     LogStash::Timestamp.new(value)
    #  logger.info("<<<<<< .  ER . >>>>>>> query value before #{@query}")
    #  @query[':sql_value_last'] = LogStash::Timestamp.new(@value_tracker.value).to_s
    #  logger.info("<<<<<< .  ER . >>>>>>> query value after #{@query}")
 
    # @base_query = LogStash::Json.load(@query)
    # if @slices
    #   @base_query.include?('slice') && fail(LogStash::ConfigurationError, "Elasticsearch Input Plugin's `query` option cannot specify specific `slice` when configured to manage parallel slices with `slices` option")
    #   @slices < 1 && fail(LogStash::ConfigurationError, "Elasticsearch Input Plugin's `slices` option must be greater than zero, got `#{@slices}`")
    # end

    transport_options = {}

    fill_user_password_from_cloud_auth

    if @user && @password
      token = Base64.strict_encode64("#{@user}:#{@password.value}")
      transport_options[:headers] = { :Authorization => "Basic #{token}" }
    end

    fill_hosts_from_cloud_id
    @hosts = Array(@hosts).map { |host| host.to_s } # potential SafeURI#to_s

    hosts = if @ssl
      @hosts.map do |h|
        host, port = h.split(":")
        { :host => host, :scheme => 'https', :port => port }
      end
    else
      @hosts
    end
    ssl_options = { :ssl  => true, :ca_file => @ca_file } if @ssl && @ca_file
    ssl_options ||= {}

    @logger.warn "Supplied proxy setting (proxy => '') has no effect" if @proxy.eql?('')

    transport_options[:proxy] = @proxy.to_s if @proxy && !@proxy.eql?('')

    @client = Elasticsearch::Client.new(:hosts => hosts, :transport_options => transport_options,
                                        :transport_class => ::Elasticsearch::Transport::Transport::HTTP::Manticore,
                                        :ssl => ssl_options)
  end

  ##
  # @override to handle proxy => '' as if none was set
  # @param value [Array<Object>]
  # @param validator [nil,Array,Symbol]
  # @return [Array(true,Object)]: if validation is a success, a tuple containing `true` and the coerced value
  # @return [Array(false,String)]: if validation is a failure, a tuple containing `false` and the failure reason.
  def self.validate_value(value, validator)
    return super unless validator == :uri_or_empty

    value = deep_replace(value)
    value = hash_or_array(value)

    return true, value.first if value.size == 1 && value.first.empty?

    return super(value, :uri)
  end

  def run(output_queue)
    if @schedule
      @scheduler = Rufus::Scheduler.new(:max_work_threads => 1)
      @scheduler.cron @schedule do
        do_run(output_queue)
      end

      @scheduler.join
    else
      do_run(output_queue)
    end
  end

  def stop
    @scheduler.stop if @scheduler
  end

  private

  def do_run(output_queue)

    #     LogStash::Timestamp.new(value)
    @query = @original_query.clone
    logger.info("<<<<<< ER >>>>>>> query value before #{@query} \n original #{@original_query}")
    @query[':sql_value_last'] = LogStash::Timestamp.new(@value_tracker.value).to_s
    logger.info("<<<<<< ER >>>>>>> query value after #{@query}")

   @base_query = LogStash::Json.load(@query)
   if @slices
     @base_query.include?('slice') && fail(LogStash::ConfigurationError, "Elasticsearch Input Plugin's `query` option cannot specify specific `slice` when configured to manage parallel slices with `slices` option")
     @slices < 1 && fail(LogStash::ConfigurationError, "Elasticsearch Input Plugin's `slices` option must be greater than zero, got `#{@slices}`")
   end


    # if configured to run a single slice, don't bother spinning up threads
    return do_run_slice(output_queue) if @slices.nil? || @slices <= 1

    logger.warn("managed slices for query is very large (#{@slices}); consider reducing") if @slices > 8

    @slices.times.map do |slice_id|
      Thread.new do
        LogStash::Util::set_thread_name("#{@id}_slice_#{slice_id}")
        do_run_slice(output_queue, slice_id)
      end
    end.map(&:join)
  end

  def do_run_slice(output_queue, slice_id=nil)
    starttime = Time.now

    slice_query = @base_query
    slice_query = slice_query.merge('slice' => { 'id' => slice_id, 'max' => @slices}) unless slice_id.nil?

    slice_options = @options.merge(:body => LogStash::Json.dump(slice_query) )

    logger.info("Slice starting", slice_id: slice_id, slices: @slices) unless slice_id.nil?
    r = search_request(slice_options)

    r['hits']['hits'].each { |hit| push_hit(hit, output_queue) }
    @value_tracker.write
    logger.debug("Slice progress", slice_id: slice_id, slices: @slices) unless slice_id.nil?

    has_hits = r['hits']['hits'].any?

    while has_hits && r['_scroll_id'] && !stop?
      r = process_next_scroll(output_queue, r['_scroll_id'])
      logger.debug("Slice progress", slice_id: slice_id, slices: @slices) unless slice_id.nil?
      has_hits = r['has_hits']
      @value_tracker.write
      break if Time.now - starttime > @alive
    end
    logger.info("Slice complete", slice_id: slice_id, slices: @slices) unless slice_id.nil?
  end

  def process_next_scroll(output_queue, scroll_id)
    r = scroll_request(scroll_id)
    r['hits']['hits'].each { |hit| push_hit(hit, output_queue) }
    {'has_hits' => r['hits']['hits'].any?, '_scroll_id' => r['_scroll_id']}
  end

  def push_hit(hit, output_queue)
    # sql_last_value = @use_column_value ? @value_tracker.value : Time.now.utc
 
    event = LogStash::Event.new(hit['_source'])

    if @docinfo
      # do not assume event[@docinfo_target] to be in-place updatable. first get it, update it, then at the end set it in the event.
      docinfo_target = event.get(@docinfo_target) || {}

      unless docinfo_target.is_a?(Hash)
        @logger.error("Elasticsearch Input: Incompatible Event, incompatible type for the docinfo_target=#{@docinfo_target} field in the `_source` document, expected a hash got:", :docinfo_target_type => docinfo_target.class, :event => event)

        # TODO: (colin) I am not sure raising is a good strategy here?
        raise Exception.new("Elasticsearch input: incompatible event")
      end

      @docinfo_fields.each do |field|
        docinfo_target[field] = hit[field]
      end

      event.set(@docinfo_target, docinfo_target)
    end

    decorate(event)

    output_queue << event


    #sql_last_value = get_column_value(event) #if @use_column_value
    #      yield extract_values_from(event)
    #logger.info("<<<<<< .  ER . >>>>>>>event.get(@tracking_column) #{event.get(@tracking_column)} event.get(@tracking_column).respond_to?(:to_string) #{event.get(@tracking_column).kind_of?(String)}") 
    sql_last_value = event.get(@tracking_column).kind_of?(String)?event.get(@tracking_column):event.get(@tracking_column).to_iso8601
    #logger.info("<<<<<< .  ER . >>>>>>>sql_last_value #{sql_last_value} respond to to_iso8601 : #{sql_last_value.respond_to?(:to_iso8601)} timestamp : #{sql_last_value.respond_to?(:to_timestamp)} String :#{sql_last_value.respond_to?(:to_string)} numeric : #{sql_last_value.respond_to?(:to_numeric)}")
    @value_tracker.set_value(sql_last_value)

  end

  def scroll_request scroll_id
    client.scroll(:body => { :scroll_id => scroll_id }, :scroll => @scroll)
  end

  def search_request(options)
    client.search(options)
  end

  attr_reader :client

  def hosts_default?(hosts)
    hosts.nil? || ( hosts.is_a?(Array) && hosts.empty? )
  end

  def fill_hosts_from_cloud_id
    return unless @cloud_id

    if @hosts && !hosts_default?(@hosts)
      raise LogStash::ConfigurationError, 'Both cloud_id and hosts specified, please only use one of those.'
    end
    @hosts = parse_host_uri_from_cloud_id(@cloud_id)
  end

  def fill_user_password_from_cloud_auth
    return unless @cloud_auth

    if @user || @password
      raise LogStash::ConfigurationError, 'Both cloud_auth and user/password specified, please only use one.'
    end
    @user, @password = parse_user_password_from_cloud_auth(@cloud_auth)
    params['user'], params['password'] = @user, @password
  end

  def parse_host_uri_from_cloud_id(cloud_id)
    begin # might not be available on older LS
      require 'logstash/util/cloud_setting_id'
    rescue LoadError
      raise LogStash::ConfigurationError, 'The cloud_id setting is not supported by your version of Logstash, ' +
          'please upgrade your installation (or set hosts instead).'
    end

    begin
      cloud_id = LogStash::Util::CloudSettingId.new(cloud_id) # already does append ':{port}' to host
    rescue ArgumentError => e
      raise LogStash::ConfigurationError, e.message.to_s.sub(/Cloud Id/i, 'cloud_id')
    end
    cloud_uri = "#{cloud_id.elasticsearch_scheme}://#{cloud_id.elasticsearch_host}"
    LogStash::Util::SafeURI.new(cloud_uri)
  end

  def parse_user_password_from_cloud_auth(cloud_auth)
    begin # might not be available on older LS
      require 'logstash/util/cloud_setting_auth'
    rescue LoadError
      raise LogStash::ConfigurationError, 'The cloud_auth setting is not supported by your version of Logstash, ' +
          'please upgrade your installation (or set user/password instead).'
    end

    cloud_auth = cloud_auth.value if cloud_auth.is_a?(LogStash::Util::Password)
    begin
      cloud_auth = LogStash::Util::CloudSettingAuth.new(cloud_auth)
    rescue ArgumentError => e
      raise LogStash::ConfigurationError, e.message.to_s.sub(/Cloud Auth/i, 'cloud_auth')
    end
    [ cloud_auth.username, cloud_auth.password ]
  end


# added by ER inspired by jdbc
def set_value_tracker(instance)
  @value_tracker = instance
end



def get_column_value(row)
  if !row.has_key?(@tracking_column.to_sym)
    if !@tracking_column_warning_sent
      @logger.warn("tracking_column not found in dataset.", :tracking_column => @tracking_column)
      @tracking_column_warning_sent = true
    end
    # If we can't find the tracking column, return the current value in the ivar
    @value_tracker.value
  else
    # Otherwise send the updated tracking column
    row[@tracking_column.to_sym]
  end
end
#private
#Stringify row keys and decorate values when necessary
#def extract_values_from(row)
#  Hash[row.map { |k, v| [k.to_s, decorate_value(v)] }]
#end

# private
# def decorate_value(value)
#   case value
#   when Time
#     # transform it to LogStash::Timestamp as required by LS
#     LogStash::Timestamp.new(value)
#   when Date, DateTime
#     LogStash::Timestamp.new(value.to_time)
#   else
#     value
#   end
# end

end
