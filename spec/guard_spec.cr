# spec/guard_spec.cr
require "./spec_helper"

describe Nightmare::Tools::Guard do
  describe "path guard fuzzing (T6)" do
    it "safely contains valid in-tree files and subdirectories" do
      with_temp_dir do |root|
        env = Nightmare::Workspace::Environment.new(root, ensure_dirs: false)
        guard = Nightmare::Tools::Guard.new(env)

        File.write(File.join(root, "app.cr"), "puts 'hello'")
        Dir.mkdir_p(File.join(root, "src"))
        File.write(File.join(root, "src", "main.cr"), "require \"./sub\"")

        guard.resolve_read("app.cr").should eq(File.join(root, "app.cr"))
        guard.resolve_read("./src/main.cr").should eq(File.join(root, "src", "main.cr"))
      end
    end

    it "rejects path traversal attempts (../ chains and absolute out-of-root paths)" do
      with_temp_dir do |root|
        env = Nightmare::Workspace::Environment.new(root, ensure_dirs: false)
        guard = Nightmare::Tools::Guard.new(env)

        expect_raises(SecurityError) { guard.resolve_read("../outside.txt") }
        expect_raises(SecurityError) { guard.resolve_read("../../etc/passwd") }
        expect_raises(SecurityError) { guard.resolve_read("/etc/passwd") }
        expect_raises(SecurityError) { guard.resolve_read("src/../../outside.txt") }
      end
    end

    it "rejects sibling prefix paths (e.g. root-evil)" do
      with_temp_dir do |root|
        sibling = "#{root}-evil"
        Dir.mkdir_p(sibling)
        File.write(File.join(sibling, "leak.txt"), "secret")

        env = Nightmare::Workspace::Environment.new(root, ensure_dirs: false)
        guard = Nightmare::Tools::Guard.new(env)

        expect_raises(SecurityError) { guard.resolve_read("../#{File.basename(sibling)}/leak.txt") }
      ensure
        FileUtils.rm_rf("#{root}-evil") if root
      end
    end

    it "rejects outside symlinks" do
      with_temp_dir do |root|
        with_temp_dir do |outside|
          outside_file = File.join(outside, "secret.txt")
          File.write(outside_file, "top secret")

          symlink_path = File.join(root, "sym_secret.txt")
          File.symlink(outside_file, symlink_path)

          env = Nightmare::Workspace::Environment.new(root, ensure_dirs: false)
          guard = Nightmare::Tools::Guard.new(env)

          expect_raises(SecurityError) { guard.resolve_read("sym_secret.txt") }
        end
      end
    end
  end

  describe "protected paths are unwritable (T7)" do
    it "unconditionally refuses writes to .git and .nightmare targets" do
      with_temp_dir do |root|
        env = Nightmare::Workspace::Environment.new(root, ensure_dirs: false)
        guard = Nightmare::Tools::Guard.new(env)

        expect_raises(SecurityError, /is a protected path/) { guard.resolve_write(".git/config") }
        expect_raises(SecurityError, /is a protected path/) { guard.resolve_write(".git/hooks/pre-commit") }
        expect_raises(SecurityError, /is a protected path/) { guard.resolve_write(".nightmare/prompt.md") }
        expect_raises(SecurityError, /is a protected path/) { guard.resolve_write(".nightmare_backup") }
        expect_raises(SecurityError, /is a protected path/) { guard.resolve_write("sub/.git/HEAD") }
      end
    end
  end

  describe "sensitive read patterns" do
    it "blocks reading .env and credential files" do
      with_temp_dir do |root|
        env = Nightmare::Workspace::Environment.new(root, ensure_dirs: false)
        guard = Nightmare::Tools::Guard.new(env)

        File.write(File.join(root, ".env"), "API_KEY=xyz")
        File.write(File.join(root, "id_rsa"), "private key")

        expect_raises(SecurityError, /sensitive file/) { guard.resolve_read(".env") }
        expect_raises(SecurityError, /sensitive file/) { guard.resolve_read(".env.local") }
        expect_raises(SecurityError, /sensitive file/) { guard.resolve_read("id_rsa") }
      end
    end
  end

  describe "tool boundary output capping" do
    it "caps output strings exceeding max_bytes and appends truncation notice" do
      large_text = "x" * 1000
      capped = Nightmare::Tools::Guard.cap_output(large_text, max_bytes: 200)

      capped.bytesize.should be <= 350
      capped.should contain("[... truncated at 200 bytes; call read_file with offset=X limit=Y for more]")
    end
  end
end
