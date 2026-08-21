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

    # Set by RunJob so a task can honour pause/cancel mid-work.
    attr_writer :checkpoint_handler

    # Honour a pending pause or cancel at this point.
    #
    # A collection task gets this for free between records. A callable task is
    # a single Continuable step, so without an explicit call here a long-running
    # `call` ignores Pause until it returns. Sprinkle it through the slow parts:
    #
    #   def call
    #     Account.find_each do |account|
    #       checkpoint!
    #       account.recalculate!
    #     end
    #   end
    #
    # When a stop is pending this does not return -- the job unwinds and the
    # run lands in "paused" or "cancelled". No-op outside a job.
    def checkpoint!
      @checkpoint_handler&.call
    end

    # Access typed form parameters
    def params
      @params_proxy ||= ParamsProxy.new(@run, self.class.form_inputs)
    end

    # Access artifacts (read/write)
    def artifacts
      @artifacts_proxy ||= ArtifactsProxy.new(@run, self.class.artifact_definitions)
    end

    # Maps the friendly :read/:write aliases onto Active Record's role names.
    def self.normalize_database_role(role)
      case role.to_sym
      when :read, :reading  then :reading
      when :write, :writing then :writing
      else role.to_sym
      end
    end

    # Switch database role for the block.
    # Usage: with_database_role(:read) { User.where(active: true).count }
    #
    # The block must force whatever it reads. Returning a lazy Relation from
    # here does nothing -- the role is restored on the way out and the query
    # runs later on the primary. To scan a `collection` against a replica,
    # declare it instead so RunJob can hold the role open for the whole scan:
    #
    #   job { database_role :reading }
    def with_database_role(role, &block)
      ActiveRecord::Base.connected_to(role: self.class.normalize_database_role(role), &block)
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
