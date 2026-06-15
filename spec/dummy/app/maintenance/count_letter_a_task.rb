class CountLetterATask < MaintenanceOnSteroids::Task
  about do
    title "Count Letter A"
    description %(Upload a CSV (or any text) file and count how many times the letter "a" appears)
    owner "Test Suite"
  end

  form do
    input :file, type: :blob, help_text: "CSV/text file to scan"
  end

  artifact :result,
           type: :jsonb,
           default: {},
           label: "Letter 'a' count",
           description: %(Occurrences of "a"/"A" in the uploaded file)

  def call
    content = params[:file].to_s

    lower = content.count("a")
    upper = content.count("A")

    artifacts.save(:result, {
      "file_name" => params.file_name(:file),
      "bytes" => content.bytesize,
      "a_lowercase" => lower,
      "A_uppercase" => upper,
      "total" => lower + upper
    })
  end
end
