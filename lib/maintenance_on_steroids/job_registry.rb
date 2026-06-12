module MaintenanceOnSteroids
  module JobRegistry
    class << self
      def register(task_class)
        registry[task_class.name] = task_class
      end

      def unregister(task_class_name)
        registry.delete(task_class_name)
      end

      def tasks
        load_all!
        registry.values.sort_by(&:name)
      end

      def find(class_name)
        load_all!
        registry[class_name] || class_name.constantize
      end

      def load_all!
        return if @loaded

        tasks_path = Rails.root.join("app/maintenance")
        if tasks_path.exist?
          Rails.autoloaders.main.eager_load_dir(tasks_path.to_s)
        end
        @loaded = true
      rescue => e
        Rails.logger.warn "[MaintenanceOnSteroids] Failed to eager load tasks: #{e.message}"
        @loaded = true
      end

      def reset!
        @loaded = false
        @registry = {}
      end

      private

      def registry
        @registry ||= {}
      end
    end
  end
end
