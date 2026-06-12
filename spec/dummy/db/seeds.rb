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
