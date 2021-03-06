module Rails::Sharding
  class ConnectionHandler

    # Establishes connections to all shards in all shard groups.
    # Despite the name, this actually only creates a connection pool with zero
    # connections for each shard. The connections will be allocated for each
    # thread when #retrieve_connection or #with_connection are called
    def self.establish_all_connections
      Core.shard_groups.each do |shard_group|
        Core.shard_names(shard_group).each do |shard_name|
          establish_connection(shard_group, shard_name)
        end
      end
    end

    # Establishes a connection to a single shard in a single shard group
    def self.establish_connection(shard_group, shard_name, environment=nil)
      self.setup unless defined? @@connection_handler

      configurations = (environment.nil? ? Core.configurations : Core.configurations(environment))

      shard_group_configurations = configurations[shard_group.to_s]
      if shard_group_configurations.nil?
        raise Errors::ConfigNotFoundError, "Cannot find configuration for shard_group '#{shard_group}' in environment '#{environment}' in #{Config.shards_config_file}"
      end

      resolver = ActiveRecord::ConnectionAdapters::ConnectionSpecification::Resolver.new(shard_group_configurations)
      begin
        connection_name = connection_name(shard_group, shard_name)
        connection_spec = resolver.spec(shard_name.to_sym, connection_name)
      rescue ActiveRecord::AdapterNotSpecified
        raise Errors::ConfigNotFoundError, "Cannot find configuration for shard '#{shard_group}:#{shard_name}' in environment '#{environment}' in #{Config.shards_config_file}"
      end

      connection_handler.establish_connection(connection_spec)
    end

    def self.connection_pool(shard_group, shard_name)
      if connection_pool = connection_handler.retrieve_connection_pool(connection_name(shard_group, shard_name))
        return connection_pool
      end

      # mimicking behavior of rails at:
      # https://github.com/rails/rails/blob/v5.0.0.1/activerecord/lib/active_record/connection_handling.rb#124
      raise ActiveRecord::ConnectionNotEstablished, "No connection pool for shard #{connection_name(shard_group, shard_name)}" if connection_pool.nil?
    end

    def self.retrieve_connection(shard_group, shard_name)
      connection_name = connection_name(shard_group, shard_name)
      connection = connection_handler.retrieve_connection(connection_name)

      if connection && Config.add_shard_tag_to_query_logs
        add_shard_tag_to_connection_log(connection, connection_name)
      else
        connection
      end
    end

    def self.connected?(shard_group, shard_name)
      connection_handler.connected?(connection_name(shard_group, shard_name))
    end

    def self.with_connection(shard_group, shard_name, &block)
    	connection_pool(shard_group, shard_name).with_connection do |connection|
        if connection && Config.add_shard_tag_to_query_logs
          connection_name = connection_name(shard_group, shard_name)
          add_shard_tag_to_connection_log(connection, connection_name)
        end
        block.call(connection)
      end
    end

    def self.remove_connection(shard_group, shard_name)
      connection_handler.remove_connection(connection_name(shard_group, shard_name))
    end

  private

    def self.connection_handler
      raise Errors::UninitializedError, 'Shards::ConnectionHandler was not setup' unless defined? @@connection_handler
      @@connection_handler
    end

    def self.setup
      @@connection_handler = ActiveRecord::ConnectionAdapters::ConnectionHandler.new
    end

    # Assembles connection name in the format "shard_group:shard_name"
    def self.connection_name(shard_group, shard_name)
      shard_group.to_s + ':' + shard_name.to_s
    end

    # Adds a shard tag to the log of all queries executed through this connection
    def self.add_shard_tag_to_connection_log(connection, shard_tag)
      # avoids modifing connection twice
      if connection.respond_to? :shard_tag
        connection.shard_tag = shard_tag
        return connection
      end

      # creates #shard_tag attribute in connection
      connection.singleton_class.send(:attr_accessor, :shard_tag)
      connection.shard_tag = shard_tag

      # create an alias #original_log, as a copy of the #log for this connection
      connection.singleton_class.send(:alias_method, :original_log, :log)

      # defines a new #log that adds a tag to the log
      class << connection
        def log(sql, name="SQL", binds=[], statement_name=nil, &block)
          name = (name.to_s + " (#{shard_tag})").strip
          self.original_log(sql, name, binds, statement_name, &block)
        end
      end

      connection
    end
  end
end
