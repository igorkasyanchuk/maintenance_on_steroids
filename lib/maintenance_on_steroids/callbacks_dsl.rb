module MaintenanceOnSteroids
  module CallbacksDsl
    extend ActiveSupport::Concern

    included do
      include ActiveSupport::Callbacks

      define_callbacks :start, :pause, :interrupt, :cancel, :complete, :error
    end

    class_methods do
      def after_start(*methods, &block)
        set_callback(:start, :after, *methods, &block)
      end

      def after_pause(*methods, &block)
        set_callback(:pause, :after, *methods, &block)
      end

      def after_interrupt(*methods, &block)
        set_callback(:interrupt, :after, *methods, &block)
      end

      def after_cancel(*methods, &block)
        set_callback(:cancel, :after, *methods, &block)
      end

      def after_complete(*methods, &block)
        set_callback(:complete, :after, *methods, &block)
      end

      def after_error(*methods, &block)
        set_callback(:error, :after, *methods, &block)
      end
    end

    def run_start_callbacks
      run_callbacks(:start)
    end

    def run_pause_callbacks
      run_callbacks(:pause)
    end

    def run_interrupt_callbacks
      run_callbacks(:interrupt)
    end

    def run_cancel_callbacks
      run_callbacks(:cancel)
    end

    def run_complete_callbacks
      run_callbacks(:complete)
    end

    def run_error_callbacks
      run_callbacks(:error)
    end
  end
end
