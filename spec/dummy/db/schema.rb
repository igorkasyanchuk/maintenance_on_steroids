ActiveRecord::Schema[7.1].define(version: 0) do
  create_table :users, force: true do |t|
    t.string  :name
    t.integer :age
    t.string  :email,              null: false, default: ""
    t.string  :encrypted_password, null: false, default: ""
    t.string  :role,               null: false, default: "user"
    t.boolean :active, default: true

    # Devise recoverable
    t.string   :reset_password_token
    t.datetime :reset_password_sent_at

    # Devise rememberable
    t.datetime :remember_created_at

    t.timestamps null: false
  end

  add_index :users, :email, unique: true
  add_index :users, :reset_password_token, unique: true

  create_table :maintenance_on_steroids_runs, force: true do |t|
    t.string  :task_class,       null: false
    t.string  :status,           null: false, default: "enqueued"
    t.json    :params,           default: {}
    t.string  :cursor
    t.integer :progress_current, null: false, default: 0
    t.integer :progress_total,   null: false, default: 0
    t.text    :error_message
    t.text    :error_backtrace
    t.string  :active_job_id
    t.string  :user_id
    t.string  :user_type
    t.string  :user_email

    t.datetime :started_at
    t.datetime :completed_at
    t.timestamps null: false
  end

  create_table :maintenance_on_steroids_artifacts, force: true do |t|
    t.integer :run_id,        null: false
    t.string  :name,          null: false
    t.string  :kind,          null: false, default: "output"
    t.string  :artifact_type, null: false, default: "jsonb"
    t.json    :data_jsonb
    t.binary  :data_blob
    t.text    :data_text
    t.string  :file_name
    t.string  :content_type
    t.json    :metadata,      default: {}
    t.timestamps null: false
  end

  add_index :maintenance_on_steroids_runs, :task_class
  add_index :maintenance_on_steroids_runs, :status
  add_index :maintenance_on_steroids_runs, :created_at
  add_index :maintenance_on_steroids_runs, [:task_class, :status]
  add_index :maintenance_on_steroids_runs, [:task_class, :created_at]
  add_index :maintenance_on_steroids_artifacts, [:run_id, :name, :kind], unique: true, name: "idx_mos_artifacts_run_name_kind"
end
