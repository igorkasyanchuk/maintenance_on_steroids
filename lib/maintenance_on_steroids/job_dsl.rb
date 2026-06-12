module MaintenanceOnSteroids
  module JobDsl
    extend ActiveSupport::Concern

    class JobConfig
      attr_reader :queue_name, :priority

      def initialize
        @queue_name = nil
        @priority   = nil
      end

      def queue(name)
        @queue_name = name.to_s
      end

      def priority(value)
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
