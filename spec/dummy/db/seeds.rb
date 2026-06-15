puts "Seeding..."

admin = User.find_or_create_by!(email: "admin@example.com") do |u|
  u.password = "password"
  u.name = "Admin User"
  u.role = "admin"
  u.age = 30
end
puts "  Admin: #{admin.email} / password (role: admin)"

user = User.find_or_create_by!(email: "user@example.com") do |u|
  u.password = "password"
  u.name = "Regular User"
  u.role = "user"
  u.age = 25
end
puts "  User:  #{user.email} / password (role: user)"

10.times do |i|
  u = User.find_or_create_by!(email: "user#{i + 1}@example.com") do |u|
    u.password = "password"
    u.name = "User #{i + 1}"
    u.role = "user"
    u.age = 20 + i
  end
  puts "  User:  #{u.email} / password"
end

puts "Done! (#{User.count} users total)"

PRODUCT_TARGET = 2000
missing = PRODUCT_TARGET - Product.count
if missing.positive?
  now = Time.current
  start = Product.count
  rows = (1..missing).map do |i|
    n = start + i
    {
      name: "Product #{n}",
      sku: format("SKU-%05d", n),
      price_cents: rand(100..99_999),
      status: Product::STATUSES.sample,
      created_at: now,
      updated_at: now
    }
  end
  rows.each_slice(500) { |slice| Product.insert_all(slice) }
end
puts "Products: #{Product.count} total"
