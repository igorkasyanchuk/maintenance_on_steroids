module MaintenanceOnSteroids
  module JobDsl
    extend ActiveSupport::Concern

    class JobConfig
      attr_reader :queue_name

      def initialize
        @queue_name     = nil
        @priority       = nil
        @database_role  = nil
        @concurrency    = nil
      end

      def queue(name)
        @queue_name = name.to_s
      end

      # Acts as both DSL setter (priority 10) and reader (config.priority).
      def priority(value = :__unset__)
        return @priority if value == :__unset__

        @priority = value
      end

      # Maximum number of runs of this task that may be active at once.
      # `concurrency 1` is the usual choice for a destructive task: without it
      # a double-click on New Run happily starts the same migration twice.
      # nil (the default) means unlimited. Acts as setter and reader.
      def concurrency(value = :__unset__)
        return @concurrency if value == :__unset__

        @concurrency = value&.to_i
      end

      # Database role the collection is read under, e.g. `database_role :reading`
      # to scan a replica. Declared rather than block-scoped because a
      # `collection` is a lazy Relation: wrapping the method body in
      # connected_to switches back before the query ever runs. RunJob holds the
      # role open for the whole scan instead, and runs `process` plus its own
      # bookkeeping under :writing. Acts as setter and reader.
      def database_role(value = :__unset__)
        return @database_role if value == :__unset__

        @database_role = MaintenanceOnSteroids::Task.normalize_database_role(value)
      end
    end

    class_methods do
      def job(&block)
        config = JobConfig.new
        config.instance_eval(&block)
        @job_config = config
      end

      def job_config
        @job_config || JobConfig.new
      end
    end
  end
end
