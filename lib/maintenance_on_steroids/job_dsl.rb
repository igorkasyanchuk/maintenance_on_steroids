module MaintenanceOnSteroids
  module JobDsl
    extend ActiveSupport::Concern

    class JobConfig
      attr_reader :queue_name

      def initialize
        @queue_name = nil
        @priority   = nil
      end

      def queue(name)
        @queue_name = name.to_s
      end

      # Acts as both DSL setter (priority 10) and reader (config.priority).
      def priority(value = :__unset__)
        return @priority if value == :__unset__

        @priority = value
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
