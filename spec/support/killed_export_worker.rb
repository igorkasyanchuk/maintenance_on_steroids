require_relative "../dummy/config/environment"

# Run in a separate interpreter by the PostgreSQL crash-recovery spec. This
# loads the application without rails_helper (which would recreate the schema).
class KilledExportTask < MaintenanceOnSteroids::Task
  artifact :report, type: :csv

  def collection
    User.where(id: run.params.fetch("ids"))
  end

  def process(user)
    if ENV["MOS_CRASH_WORKER"] == "1" && user.id == run.params.fetch("ids").last
      $stdout.puts("checkpointed")
      $stdout.flush
      sleep 30
    end
    artifacts.report << [user.id]
  end
end

MaintenanceOnSteroids::RunJob.perform_now(ARGV.fetch(0).to_i) if $PROGRAM_NAME == __FILE__
