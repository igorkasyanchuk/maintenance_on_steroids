# This file is auto-generated from the current state of the database. Instead
# of editing this file, please use the migrations feature of Active Record to
# incrementally modify your database, and then regenerate this schema definition.
#
# This file is the source Rails uses to define your schema when running `bin/rails
# db:schema:load`. When creating a new database, `bin/rails db:schema:load` tends to
# be faster and is potentially less error prone than running all of your
# migrations from scratch. Old migrations may fail to apply correctly if those
# migrations use external dependencies or application code.
#
# It's strongly recommended that you check this file into your version control system.

ActiveRecord::Schema[8.1].define(version: 0) do
  create_table "maintenance_on_steroids_artifacts", force: :cascade do |t|
    t.string "artifact_type", default: "jsonb", null: false
    t.string "content_type"
    t.datetime "created_at", null: false
    t.binary "data_blob"
    t.json "data_jsonb"
    t.text "data_text"
    t.string "file_name"
    t.string "kind", default: "output", null: false
    t.json "metadata", default: {}
    t.string "name", null: false
    t.integer "run_id", null: false
    t.datetime "updated_at", null: false
    t.index ["run_id", "name", "kind"], name: "idx_mos_artifacts_run_name_kind", unique: true
    t.index ["run_id"], name: "index_maintenance_on_steroids_artifacts_on_run_id"
  end

  create_table "maintenance_on_steroids_runs", force: :cascade do |t|
    t.string "active_job_id"
    t.datetime "completed_at"
    t.datetime "created_at", null: false
    t.string "cursor"
    t.text "error_backtrace"
    t.text "error_message"
    t.json "params", default: {}
    t.integer "progress_current", default: 0, null: false
    t.integer "progress_total", default: 0, null: false
    t.datetime "started_at"
    t.string "status", default: "enqueued", null: false
    t.string "task_class", null: false
    t.datetime "updated_at", null: false
    t.string "user_email"
    t.string "user_id"
    t.string "user_type"
    t.index ["created_at"], name: "index_maintenance_on_steroids_runs_on_created_at"
    t.index ["status"], name: "index_maintenance_on_steroids_runs_on_status"
    t.index ["task_class", "created_at"], name: "idx_on_task_class_created_at_5dc1e6cb4b"
    t.index ["task_class", "status"], name: "idx_on_task_class_status_b6c92a5d68"
    t.index ["task_class"], name: "index_maintenance_on_steroids_runs_on_task_class"
  end

  create_table "products", force: :cascade do |t|
    t.datetime "created_at", null: false
    t.string "name", null: false
    t.integer "price_cents", default: 0, null: false
    t.string "sku", null: false
    t.string "status", default: "draft", null: false
    t.datetime "updated_at", null: false
    t.index ["sku"], name: "index_products_on_sku", unique: true
  end

  create_table "users", force: :cascade do |t|
    t.boolean "active", default: true
    t.integer "age"
    t.datetime "created_at", null: false
    t.string "email", default: "", null: false
    t.string "encrypted_password", default: "", null: false
    t.string "name"
    t.datetime "remember_created_at"
    t.datetime "reset_password_sent_at"
    t.string "reset_password_token"
    t.string "role", default: "user", null: false
    t.datetime "updated_at", null: false
    t.index ["email"], name: "index_users_on_email", unique: true
    t.index ["reset_password_token"], name: "index_users_on_reset_password_token", unique: true
  end
end
