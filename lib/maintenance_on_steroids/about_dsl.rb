module MaintenanceOnSteroids
  module AboutDsl
    extend ActiveSupport::Concern

    class AboutConfig
      attr_reader :title_text, :description_text, :owner_text

      def initialize
        @title_text       = nil
        @description_text = nil
        @owner_text       = nil
      end

      def title(value)
        @title_text = value
      end

      def description(value)
        @description_text = value
      end

      def owner(value)
        @owner_text = value
      end
    end

    class_methods do
      def about(&block)
        config = AboutConfig.new
        config.instance_eval(&block)
        @about_config = config
      end

      def about_config
        @about_config || AboutConfig.new
      end

      def task_title
        about_config.title_text || name.demodulize.titleize
      end

      def task_description
        about_config.description_text
      end

      def task_owner
        about_config.owner_text
      end
    end
  end
end
