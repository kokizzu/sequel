# frozen-string-literal: true

module Sequel
  class Database
    # ---------------------
    # :section: 7 - Miscellaneous methods
    # These methods don't fit neatly into another category.
    # ---------------------
    
    # Hash of extension name symbols to callable objects to load the extension
    # into the Database object (usually by extending it with a module defined
    # in the extension).
    EXTENSIONS = {}

    # The general default size for string columns for all Sequel::Database
    # instances.
    DEFAULT_STRING_COLUMN_SIZE = 255

    # Empty exception regexp to class map, used by default if Sequel doesn't
    # have specific support for the database in use.
    DEFAULT_DATABASE_ERROR_REGEXPS = {}.freeze

    # Mapping of schema type symbols to class or arrays of classes for that
    # symbol.
    SCHEMA_TYPE_CLASSES = {:string=>String, :integer=>Integer, :date=>Date, :datetime=>[Time, DateTime].freeze,
      :time=>Sequel::SQLTime, :boolean=>[TrueClass, FalseClass].freeze, :float=>Float, :decimal=>BigDecimal,
      :blob=>Sequel::SQL::Blob}.freeze

    # :nocov:
    URI_PARSER = defined?(::URI::RFC2396_PARSER) ? ::URI::RFC2396_PARSER : ::URI::DEFAULT_PARSER
    # :nocov:
    private_constant :URI_PARSER

    # Nested hook Proc; each new hook Proc just wraps the previous one.
    @initialize_hook = proc{|db| }

    # Register a hook that will be run when a new Database is instantiated. It is
    # called with the new database handle.
    def self.after_initialize
      raise Error, "must provide block to after_initialize" unless defined?(yield)
      Sequel.synchronize do
        previous = @initialize_hook
        @initialize_hook = proc do |db|
          previous.call(db)
          yield(db)
        end
      end
    end

    # Apply an extension to all Database objects created in the future.
    def self.extension(*extensions)
      after_initialize{|db| db.extension(*extensions)}
    end

    # Register an extension callback for Database objects.  ext should be the
    # extension name symbol, and mod should either be a Module that the
    # database is extended with, or a callable object called with the database
    # object.  If mod is not provided, a block can be provided and is treated
    # as the mod object.
    def self.register_extension(ext, mod=nil, &block)
      if mod
        raise(Error, "cannot provide both mod and block to Database.register_extension") if block
        if mod.is_a?(Module)
          block = proc{|db| db.extend(mod)}
        else
          block = mod
        end
      end
      Sequel.synchronize{EXTENSIONS[ext] = block}
    end

    # Run the after_initialize hook for the given +instance+.
    def self.run_after_initialize(instance)
      @initialize_hook.call(instance)
    end

    # Converts a uri to an options hash. These options are then passed
    # to a newly created database object. 
    def self.uri_to_options(uri)
      {
        :user => uri.user,
        :password => uri.password,
        :port => uri.port,
        :host => uri.hostname,
        :database => (m = /\/(.*)/.match(uri.path)) && (m[1])
      }
    end
    private_class_method :uri_to_options

    def self.options_from_uri(uri)
      uri_options = uri_to_options(uri)
      uri.query.split('&').map{|s| s.split('=')}.each{|k,v| uri_options[k.to_sym] = v if k && !k.empty?} unless uri.query.to_s.strip.empty?
      uri_options.to_a.each{|k,v| uri_options[k] = URI_PARSER.unescape(v) if v.is_a?(String)}
      uri_options
    end
    private_class_method :options_from_uri

    # The options hash for this database
    attr_reader :opts
    
    # Set the timezone to use for this database, overridding <tt>Sequel.database_timezone</tt>.
    attr_writer :timezone
    
    # The specific default size of string columns for this Sequel::Database, usually 255 by default.
    attr_accessor :default_string_column_size

    # Whether to check the bytesize of strings before typecasting (to avoid typecasting strings that
    # would be too long for the given type), true by default. Strings that are too long will raise
    # a typecasting error.
    attr_accessor :check_string_typecast_bytesize

    # Constructs a new instance of a database connection with the specified
    # options hash.
    #
    # Accepts the following options:
    # :after_connect :: A callable object called after each new connection is made, with the
    #                   connection object (and server argument if the callable accepts 2 arguments),
    #                   useful for customizations that you want to apply to all connections.
    # :compare_connections_by_identity :: Whether to use compare_by_identity on hashes that use
    #                                     connection objects as keys. Defaults to true. This should only
    #                                     be set to false to work around bugs in libraries or
    #                                     ruby implementations.
    # :before_preconnect :: Callable that runs after extensions from :preconnect_extensions are loaded,
    #                       but before any connections are created.
    # :cache_schema :: Whether schema should be cached for this Database instance
    # :check_string_typecast_bytesize :: Whether to check the bytesize of strings before typecasting.
    # :connect_sqls :: An array of sql strings to execute on each new connection, after :after_connect runs.
    # :connect_opts_proc :: Callable object for modifying options hash used when connecting, designed for
    #                       cases where the option values (e.g. password) are automatically rotated on
    #                       a regular basis without involvement from the application using Sequel.
    # :default_string_column_size :: The default size of string columns, 255 by default.
    # :extensions :: Extensions to load into this Database instance.  Can be a symbol, array of symbols,
    #                or string with extensions separated by columns.  These extensions are loaded after
    #                connections are made by the :preconnect option.
    # :keep_reference :: Whether to keep a reference to this instance in Sequel::DATABASES, true by default.
    # :logger :: A specific logger to use.
    # :loggers :: An array of loggers to use.
    # :log_connection_info :: Whether connection information should be logged when logging queries.
    # :log_warn_duration :: The number of elapsed seconds after which queries should be logged at warn level.
    # :name :: A name to use for the Database object, displayed in PoolTimeout.
    # :preconnect :: Automatically create the maximum number of connections, so that they don't
    #                need to be created as needed.  This is useful when connecting takes a long time
    #                and you want to avoid possible latency during runtime.
    #                Set to :concurrently to create the connections in separate threads. Otherwise
    #                they'll be created sequentially.
    # :preconnect_extensions :: Similar to the :extensions option, but loads the extensions before the
    #                           connections are made by the :preconnect option.
    # :quote_identifiers :: Whether to quote identifiers.
    # :servers :: A hash specifying a server/shard specific options, keyed by shard symbol.
    # :single_threaded :: Whether to use a single-threaded connection pool.
    # :sql_log_level :: Method to use to log SQL to a logger, :info by default.
    #
    # For sharded connection pools, :after_connect and :connect_sqls can be specified per-shard.
    #
    # All options given are also passed to the connection pool.  Additional options respected by
    # the connection pool are :max_connections, :pool_timeout, :servers, and :servers_hash.  See the
    # connection pool documentation for details.
    def initialize(opts = OPTS)
      @opts ||= opts
      @opts = connection_pool_default_options.merge(@opts)
      @loggers = Array(@opts[:logger]) + Array(@opts[:loggers])
      @opts[:servers] = {} if @opts[:servers].is_a?(String)
      @sharded = !!@opts[:servers]
      @opts[:adapter_class] = self.class
      @opts[:single_threaded] = @single_threaded = typecast_value_boolean(@opts.fetch(:single_threaded, Sequel.single_threaded))
      @default_string_column_size = @opts[:default_string_column_size] || DEFAULT_STRING_COLUMN_SIZE
      @check_string_typecast_bytesize = typecast_value_boolean(@opts.fetch(:check_string_typecast_bytesize, true))

      @schemas = {}
      @prepared_statements = {}
      @transactions = {}
      @transactions.compare_by_identity if typecast_value_boolean(@opts.fetch(:compare_connections_by_identity, true))
      @symbol_literal_cache = {}

      @timezone = nil

      @dataset_class = dataset_class_default
      @cache_schema = typecast_value_boolean(@opts.fetch(:cache_schema, true))
      @dataset_modules = []
      @loaded_extensions = []
      @schema_type_classes = SCHEMA_TYPE_CLASSES.dup

      self.sql_log_level = @opts[:sql_log_level] ? @opts[:sql_log_level].to_sym : :info
      self.log_warn_duration = @opts[:log_warn_duration]
      self.log_connection_info = typecast_value_boolean(@opts[:log_connection_info])

      @pool = ConnectionPool.get_pool(self, @opts)

      reset_default_dataset
      adapter_initialize

      keep_reference = typecast_value_boolean(@opts[:keep_reference]) != false
      begin
        Sequel.synchronize{::Sequel::DATABASES.push(self)} if keep_reference
        Sequel::Database.run_after_initialize(self)

        initialize_load_extensions(:preconnect_extensions)

        if before_preconnect = @opts[:before_preconnect]
          before_preconnect.call(self)
        end

        if typecast_value_boolean(@opts[:preconnect]) && @pool.respond_to?(:preconnect, true)
          concurrent = typecast_value_string(@opts[:preconnect]) == "concurrently"
          @pool.send(:preconnect, concurrent)
        end

        initialize_load_extensions(:extensions)
        test_connection if typecast_value_boolean(@opts.fetch(:test, true)) && respond_to?(:connect, true)
      rescue
        Sequel.synchronize{::Sequel::DATABASES.delete(self)} if keep_reference
        raise
      end
    end

    # Freeze internal data structures for the Database instance.
    def freeze
      valid_connection_sql
      metadata_dataset
      @opts.freeze
      @loggers.freeze
      @pool.freeze
      @dataset_class.freeze
      @dataset_modules.freeze
      @schema_type_classes.freeze
      @loaded_extensions.freeze
      metadata_dataset
      super
    end

    # Disallow dup/clone for Database instances
    undef_method :dup, :clone, :initialize_copy
    # :nocov:
    if RUBY_VERSION >= '1.9.3'
    # :nocov:
      undef_method :initialize_clone, :initialize_dup
    end

    # Cast the given type to a literal type
    #
    #   DB.cast_type_literal(Float) # double precision
    #   DB.cast_type_literal(:foo)  # foo
    def cast_type_literal(type)
      type_literal(:type=>type)
    end

    # Load an extension into the receiver.  In addition to requiring the extension file, this
    # also modifies the database to work with the extension (usually extending it with a
    # module defined in the extension file).  If no related extension file exists or the
    # extension does not have specific support for Database objects, an Error will be raised.
    # Returns self.
    def extension(*exts)
      exts.each do |ext|
        unless pr = Sequel.synchronize{EXTENSIONS[ext]}
          Sequel.extension(ext)
          pr = Sequel.synchronize{EXTENSIONS[ext]}
        end

        if pr
          if Sequel.synchronize{@loaded_extensions.include?(ext) ? false : (@loaded_extensions << ext)}
            pr.call(self)
          end
        else
          raise(Error, "Extension #{ext} does not have specific support handling individual databases (try: Sequel.extension #{ext.inspect})")
        end
      end
      self
    end

    # Convert the given timestamp from the application's timezone,
    # to the databases's timezone or the default database timezone if
    # the database does not have a timezone.
    def from_application_timestamp(v)
      Sequel.convert_output_timestamp(v, timezone)
    end

    # Returns a string representation of the Database object, including
    # the database type, host, database, and user, if present.
    def inspect
      s = String.new
      s << "#<#{self.class}"
      s << " database_type=#{database_type}" if database_type && database_type != adapter_scheme

      keys = [:host, :database, :user]
      opts = self.opts
      if !keys.any?{|k| opts[k]} && opts[:uri]
        opts = self.class.send(:options_from_uri, URI.parse(opts[:uri]))
      end

      keys.each do |key|
        val = opts[key]
        if val && val != ''
          s << " #{key}=#{val}"
        end
      end

      s << ">"
    end

    # Proxy the literal call to the dataset.
    #
    #   DB.literal(1)   # 1
    #   DB.literal(:a)  # "a" # or `a`, [a], or a, depending on identifier quoting
    #   DB.literal("a") # 'a'
    def literal(v)
      schema_utility_dataset.literal(v)
    end

    # Return the literalized version of the symbol if cached, or
    # nil if it is not cached.
    def literal_symbol(sym)
      Sequel.synchronize{@symbol_literal_cache[sym]}
    end

    # Set the cached value of the literal symbol.
    def literal_symbol_set(sym, lit)
      Sequel.synchronize{@symbol_literal_cache[sym] = lit}
    end

    # Synchronize access to the prepared statements cache.
    def prepared_statement(name)
      Sequel.synchronize{prepared_statements[name]}
    end

    # Proxy the quote_identifier method to the dataset,
    # useful for quoting unqualified identifiers for use
    # outside of datasets.
    def quote_identifier(v)
      schema_utility_dataset.quote_identifier(v)
    end

    # Return ruby class or array of classes for the given type symbol.
    def schema_type_class(type)
      @schema_type_classes[type]
    end
    
    # Default serial primary key options, used by the table creation code.
    def serial_primary_key_options
      {:primary_key => true, :type => Integer, :auto_increment => true}
    end

    # Cache the prepared statement object at the given name.
    def set_prepared_statement(name, ps)
      Sequel.synchronize{prepared_statements[name] = ps}
    end

    # Whether this database instance uses multiple servers, either for sharding
    # or for primary/replica configurations.
    def sharded?
      @sharded
    end

    # The timezone to use for this database, defaulting to <tt>Sequel.database_timezone</tt>.
    def timezone
      @timezone || Sequel.database_timezone
    end

    # Convert the given timestamp to the application's timezone,
    # from the databases's timezone or the default database timezone if
    # the database does not have a timezone.
    def to_application_timestamp(v)
      Sequel.convert_timestamp(v, timezone)
    end

    # Typecast the value to the given column_type. Calls
    # typecast_value_#{column_type} if the method exists,
    # otherwise returns the value.
    # This method should raise Sequel::InvalidValue if assigned value
    # is invalid.
    def typecast_value(column_type, value)
      return nil if value.nil?
      meth = "typecast_value_#{column_type}"
      begin
        # Allow calling private methods as per-type typecasting methods are private
        respond_to?(meth, true) ? send(meth, value) : value
      rescue ArgumentError, TypeError => e
        raise Sequel.convert_exception_class(e, InvalidValue)
      end
    end
    
    # Returns the URI use to connect to the database.  If a URI
    # was not used when connecting, returns nil.
    def uri
      opts[:uri]
    end
    
    # Explicit alias of uri for easier subclassing.
    def url
      uri
    end
    
    private
    
    # Per adapter initialization method, empty by default.
    def adapter_initialize
    end

    # Returns true when the object is considered blank.
    # The only objects that are blank are nil, false,
    # strings with all whitespace, and ones that respond
    # true to empty?
    def blank_object?(obj)
      return obj.blank? if obj.respond_to?(:blank?)
      case obj
      when NilClass, FalseClass
        true
      when Numeric, TrueClass
        false
      when String
        obj.strip.empty?
      else
        obj.respond_to?(:empty?) ? obj.empty? : false
      end
    end

    # An enumerable yielding pairs of regexps and exception classes, used
    # to match against underlying driver exception messages in
    # order to raise a more specific Sequel::DatabaseError subclass.
    def database_error_regexps
      DEFAULT_DATABASE_ERROR_REGEXPS
    end

    # Return the Sequel::DatabaseError subclass to wrap the given
    # exception in.
    def database_error_class(exception, opts)
      database_specific_error_class(exception, opts) || DatabaseError
    end
    
    # Return the SQLState for the given exception, if one can be determined
    def database_exception_sqlstate(exception, opts)
      nil
    end

    # Return a specific Sequel::DatabaseError exception class if
    # one is appropriate for the underlying exception,
    # or nil if there is no specific exception class.
    def database_specific_error_class(exception, opts)
      return DatabaseDisconnectError if disconnect_error?(exception, opts)

      if sqlstate = database_exception_sqlstate(exception, opts)
        if klass = database_specific_error_class_from_sqlstate(sqlstate)
          return klass
        end
      else
        database_error_regexps.each do |regexp, klss|
          return klss if exception.message =~ regexp
        end
      end

      nil
    end
    
    NOT_NULL_CONSTRAINT_SQLSTATES = %w'23502'.freeze.each(&:freeze)
    FOREIGN_KEY_CONSTRAINT_SQLSTATES = %w'23503 23506 23504'.freeze.each(&:freeze)
    UNIQUE_CONSTRAINT_SQLSTATES = %w'23505'.freeze.each(&:freeze)
    CHECK_CONSTRAINT_SQLSTATES = %w'23513 23514'.freeze.each(&:freeze)
    SERIALIZATION_CONSTRAINT_SQLSTATES = %w'40001'.freeze.each(&:freeze)
    # Given the SQLState, return the appropriate DatabaseError subclass.
    def database_specific_error_class_from_sqlstate(sqlstate)
      case sqlstate
      when *NOT_NULL_CONSTRAINT_SQLSTATES
        NotNullConstraintViolation
      when *FOREIGN_KEY_CONSTRAINT_SQLSTATES
        ForeignKeyConstraintViolation
      when *UNIQUE_CONSTRAINT_SQLSTATES
        UniqueConstraintViolation
      when *CHECK_CONSTRAINT_SQLSTATES
        CheckConstraintViolation
      when *SERIALIZATION_CONSTRAINT_SQLSTATES
        SerializationFailure
      end
    end
    
    # Return true if exception represents a disconnect error, false otherwise.
    def disconnect_error?(exception, opts)
      opts[:disconnect]
    end
    
    # Load extensions during initialization from the given key in opts.
    def initialize_load_extensions(key)
      case exts = @opts[key]
      when String
        extension(*exts.split(',').map(&:to_sym))
      when Array
        extension(*exts)
      when Symbol
        extension(exts)
      when nil
        # nothing
      else
        raise Error, "unsupported Database #{key.inspect} option: #{@opts[key].inspect}"
      end
    end

    # Convert the given exception to an appropriate Sequel::DatabaseError
    # subclass, keeping message and backtrace.
    def raise_error(exception, opts=OPTS)
      if !opts[:classes] || Array(opts[:classes]).any?{|c| exception.is_a?(c)}
        raise Sequel.convert_exception_class(exception, database_error_class(exception, opts))
      else
        raise exception
      end
    end

    # Swallow database errors, unless they are connect/disconnect errors.
    def swallow_database_error
      yield
    rescue Sequel::DatabaseDisconnectError, DatabaseConnectionError
      # Always raise disconnect errors
      raise
    rescue Sequel::DatabaseError
      # Don't raise other database errors.
      nil
    # else
    #   Don't rescue other exceptions, they will be raised normally.
    end

    # Check the bytesize of a string before conversion. There is no point
    # trying to typecast strings that would be way too long.
    def typecast_check_string_length(string, max_size)
      if @check_string_typecast_bytesize && string.bytesize > max_size
        raise InvalidValue, "string too long to typecast (bytesize: #{string.bytesize}, max: #{max_size})"
      end
      string
    end

    # Check the bytesize of the string value, if value is a string.
    def typecast_check_length(value, max_size)
      typecast_check_string_length(value, max_size) if String === value
      value
    end

    # Typecast the value to an SQL::Blob
    def typecast_value_blob(value)
      value.is_a?(Sequel::SQL::Blob) ? value : Sequel::SQL::Blob.new(value)
    end

    # Typecast the value to true, false, or nil
    def typecast_value_boolean(value)
      case value
      when false, 0, "0", /\Af(alse)?\z/i, /\Ano?\z/i
        false
      else
        blank_object?(value) ? nil : true
      end
    end

    # Typecast the value to a Date
    def typecast_value_date(value)
      case value
      when DateTime, Time
        Date.new(value.year, value.month, value.day)
      when Date
        value
      when String
        Sequel.string_to_date(typecast_check_string_length(value, 100))
      when Hash
        Date.new(*[:year, :month, :day].map{|x| typecast_check_length(value[x] || value[x.to_s], 100).to_i})
      else
        raise InvalidValue, "invalid value for Date: #{value.inspect}"
      end
    end

    # Typecast the value to a DateTime or Time depending on Sequel.datetime_class
    def typecast_value_datetime(value)
      case value
      when String
        Sequel.typecast_to_application_timestamp(typecast_check_string_length(value, 100))
      when Hash
        [:year, :month, :day, :hour, :minute, :second, :nanos, :offset].each do |x|
          typecast_check_length(value[x] || value[x.to_s], 100)
        end
        Sequel.typecast_to_application_timestamp(value)
      else
        Sequel.typecast_to_application_timestamp(value)
      end
    end
    
    if RUBY_VERSION >= '2.4'
      # Typecast a string to a BigDecimal
      alias _typecast_value_string_to_decimal BigDecimal
    else
      # :nocov:
      def _typecast_value_string_to_decimal(value)
        d = BigDecimal(value)
        if d.zero?
          # BigDecimal parsing is loose by default, returning a 0 value for
          # invalid input.  If a zero value is received, use Float to check
          # for validity.
          begin
            Float(value)
          rescue ArgumentError
            raise InvalidValue, "invalid value for BigDecimal: #{value.inspect}"
          end
        end
        d
      end
      # :nocov:
    end

    # Typecast the value to a BigDecimal
    def typecast_value_decimal(value)
      case value
      when BigDecimal
        value
      when Numeric
        BigDecimal(value.to_s)
      when String
        _typecast_value_string_to_decimal(typecast_check_string_length(value, 1000))
      else
        raise InvalidValue, "invalid value for BigDecimal: #{value.inspect}"
      end
    end

    # Typecast the value to a Float
    def typecast_value_float(value)
      Float(typecast_check_length(value, 1000))
    end

    # Typecast the value to an Integer
    def typecast_value_integer(value)
      case value
      when String
        typecast_check_string_length(value, 100)
        if value =~ /\A-?0+(\d)/
          Integer(value, 10)
        else
          Integer(value)
        end
      else
        Integer(value)
      end
    end

    # Typecast the value to a String
    def typecast_value_string(value)
      case value
      when Hash, Array
        raise Sequel::InvalidValue, "invalid value for String: #{value.inspect}"
      else
        value.to_s
      end
    end

    # Typecast the value to a Time
    def typecast_value_time(value)
      case value
      when Time
        if value.is_a?(SQLTime)
          value
        else
          SQLTime.create(value.hour, value.min, value.sec, value.nsec/1000.0)
        end
      when String
        Sequel.string_to_time(typecast_check_string_length(value, 100))
      when Hash
        SQLTime.create(*[:hour, :minute, :second].map{|x| typecast_check_length(value[x] || value[x.to_s], 100).to_i})
      else
        raise Sequel::InvalidValue, "invalid value for Time: #{value.inspect}"
      end
    end
  end
end
