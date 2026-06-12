module MaintenanceOnSteroids
  module JobRegistry
    LOAD_MUTEX = Mutex.new

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

      # Resolves a task class by name.
      #
      # Only returns registered task classes (or, as a fallback for classes
      # loaded outside app/maintenance, constants that are actual
      # MaintenanceOnSteroids::Task subclasses). Returns nil for anything
      # else so that user-supplied input can never resolve arbitrary
      # constants (source disclosure / 500s) -- controllers 404 on nil.
      def find(class_name)
        load_all!
        class_name = class_name.to_s
        return registry[class_name] if registry.key?(class_name)

        klass = class_name.safe_constantize
        return nil unless klass.is_a?(Class) && klass < MaintenanceOnSteroids::Task

        klass
      end

      def load_all!
        return if @loaded

        LOAD_MUTEX.synchronize do
          return if @loaded

          begin
            tasks_path = Rails.root.join("app/maintenance")
            if tasks_path.exist?
              Rails.autoloaders.main.eager_load_dir(tasks_path.to_s)
            end
          rescue => e
            Rails.logger.warn "[MaintenanceOnSteroids] Failed to eager load tasks: #{e.message}"
          end

          @loaded = true
        end
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
