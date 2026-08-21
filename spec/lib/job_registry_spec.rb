require "rails_helper"

RSpec.describe MaintenanceOnSteroids::JobRegistry do
  it "lists the host app's tasks" do
    expect(MaintenanceOnSteroids.task_classes.map(&:name)).to include("UpdateUsersTask")
  end

  describe "ghost classes" do
    it "does not register a class whose constant no longer resolves to it" do
      ghost = Class.new(MaintenanceOnSteroids::Task) do
        def collection = User.all
        def process(record) = record
      end
      # A class keeps the name it was first assigned even after the constant is
      # removed, and it stays in Task.descendants -- which is how stubbed test
      # classes and stale copies from a dev code-reload used to reach the
      # dashboard.
      Object.const_set(:GhostTask, ghost)
      expect(ghost.name).to eq("GhostTask")
      Object.send(:remove_const, :GhostTask)

      described_class.reset!

      expect(MaintenanceOnSteroids.task_classes).not_to include(ghost)
      expect(described_class.find("GhostTask")).to be_nil
    end

    it "does not register a stale class the constant has been rebound away from" do
      stale = Class.new(MaintenanceOnSteroids::Task) { def call; end }
      Object.const_set(:RelaodedTask, stale)
      Object.send(:remove_const, :RelaodedTask)

      fresh = Class.new(MaintenanceOnSteroids::Task) { def call; end }
      Object.const_set(:RelaodedTask, fresh)

      described_class.reset!
      classes = MaintenanceOnSteroids.task_classes

      expect(classes).to include(fresh)
      expect(classes).not_to include(stale)
    ensure
      Object.send(:remove_const, :RelaodedTask) if Object.const_defined?(:RelaodedTask)
      described_class.reset!
    end
  end
end
