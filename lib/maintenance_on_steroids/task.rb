require_relative "form_dsl"
require_relative "artifact_dsl"
require_relative "job_dsl"
require_relative "about_dsl"
require_relative "callbacks_dsl"
require_relative "artifacts_proxy"
require_relative "jsonb_artifact"
require_relative "params_proxy"
require_relative "job_registry"

module MaintenanceOnSteroids
  class Task
    include FormDsl
    include ArtifactDsl
    include JobDsl
    include AboutDsl
    include CallbacksDsl

    attr_accessor :run

    def self.inherited(subclass)
      super
      JobRegistry.register(subclass) if subclass.name
    end

    def initialize(run = nil)
      @run = run
    end

    # Access typed form parameters
    def params
      @params_proxy ||= ParamsProxy.new(@run, self.class.form_inputs)
    end

    # Access artifacts (read/write)
    def artifacts
      @artifacts_proxy ||= ArtifactsProxy.new(@run, self.class.artifact_definitions)
    end

    # Switch database role for the block
    # Usage: with_database_role(:read) { User.all }
    def with_database_role(role, &block)
      resolved = case role.to_sym
                 when :read, :reading   then :reading
                 when :write, :writing  then :writing
                 else role.to_sym
                 end
      ActiveRecord::Base.connected_to(role: resolved, &block)
    end

    # Override in subclass: return an ActiveRecord::Relation for batch processing
    # def collection
    #   User.where(active: true)
    # end

    # Override in subclass: process a single record from collection
    # def process(record)
    #   record.update!(...)
    # end

    # Override in subclass: for one-off tasks (no collection)
    # def call
    #   SomeService.run
    # end

    def collection_task?
      respond_to?(:collection) && respond_to?(:process)
    end

    def callable_task?
      respond_to?(:call)
    end

    def task_type
      if collection_task?
        :collection
      elsif callable_task?
        :callable
      else
        raise "Task must define either collection+process or call"
      end
    end
  end
end
