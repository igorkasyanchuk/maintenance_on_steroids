require "csv"

class CsvExportTask < MaintenanceOnSteroids::Task
  about do
    title "CSV Export"
    description "Exports users to CSV"
  end

  artifact :csv_file, type: :file, file_name: "users.csv"

  def call
    csv_data = CSV.generate do |csv|
      csv << %w[id name age email]
      User.find_each do |user|
        csv << [user.id, user.name, user.age, user.email]
      end
    end

    artifacts[:csv_file] = csv_data
  end
end
