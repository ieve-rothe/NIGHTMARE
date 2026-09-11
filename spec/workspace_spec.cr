require "./spec_helper"

describe Nightmare::Workspace do
  describe Nightmare::Workspace::Environment do
    it "anchors immutably to canonical realpath of directory" do
      with_temp_dir do |dir|
        sym_dir = File.join(Dir.tempdir, "nightmare_sym_#{Random::Secure.hex(4)}")
        File.symlink(dir, sym_dir)

        begin
          env = Nightmare::Workspace::Environment.new(sym_dir, ensure_dirs: false)
          env.root.should eq(dir)
        ensure
          FileUtils.rm_rf(sym_dir)
        end
      end
    end

    it "fails initialization if root path does not exist" do
      nonexistent = "/path/definitely/nonexistent_#{Random::Secure.hex(8)}"
      expect_raises(File::NotFoundError) do
        Nightmare::Workspace::Environment.new(nonexistent, ensure_dirs: false)
      end
    end

    it "raises ArgumentError when workspace directory does not exist via resolve" do
      expect_raises(ArgumentError, /Workspace directory does not exist/) do
        Nightmare::Workspace::Environment.resolve("/non/existent/path/for/sure_#{Random::Secure.hex(8)}")
      end
    end

    it "generates deterministic workspace_id with sanitized slug and 8-character sha256 hash" do
      temp_dir = File.join(Dir.tempdir, "My Cool Project (v1.0)")
      Dir.mkdir_p(temp_dir)
      canonical = File.realpath(temp_dir)

      begin
        env = Nightmare::Workspace::Environment.new(temp_dir, ensure_dirs: false)
        expected_slug = "My_Cool_Project__v1_0_"
        expected_hash = Digest::SHA256.hexdigest(canonical)[0..7]

        env.workspace_id.should eq("#{expected_slug}-#{expected_hash}")
        (env.workspace_id =~ /^[a-zA-Z0-9_-]+-[0-9a-f]{8}$/).should_not be_nil

        # Idempotency
        env2 = Nightmare::Workspace::Environment.new(temp_dir, ensure_dirs: false)
        env2.workspace_id.should eq(env.workspace_id)
      ensure
        FileUtils.rm_rf(temp_dir)
      end
    end

    it "resolves central XDG paths correctly without littering target repo" do
      with_temp_dir do |dir|
        with_temp_dir do |xdg|
          cfg = File.join(xdg, "config")
          st = File.join(xdg, "state")
          ca = File.join(xdg, "cache")

          env = Nightmare::Workspace::Environment.resolve(
            current_dir: dir,
            xdg_config_home: cfg,
            xdg_state_home: st,
            xdg_cache_home: ca,
            ensure_dirs: true
          )

          env.config_dir.should eq(File.join(cfg, "nightmare", "workspaces", env.workspace_id))
          env.state_dir.should eq(File.join(st, "nightmare", "workspaces", env.workspace_id))
          env.cache_dir.should eq(File.join(ca, "nightmare", "workspaces", env.workspace_id))
          env.allowlist_path.should eq(File.join(env.config_dir, "allow"))
          env.log_path.should eq(File.join(env.state_dir, "llm_calls.jsonl"))

          # Central directories exist
          Dir.exists?(env.config_dir).should be_true
          Dir.exists?(env.state_dir).should be_true
          Dir.exists?(env.cache_dir).should be_true
          File.exists?(env.manifest_path).should be_true

          # Target repo must remain pristine (zero repo litter)
          Dir.children(dir).should be_empty
        end
      end
    end

    describe "Path Containment & Security Sanitization" do
      it "allows canonical relative and absolute paths inside root" do
        with_temp_dir do |dir|
          Dir.mkdir_p(File.join(dir, "src"))
          File.write(File.join(dir, "src", "app.cr"), "content")

          env = Nightmare::Workspace::Environment.new(dir, ensure_dirs: false)
          expected = File.join(env.root, "src", "app.cr")

          env.sanitize_path("src/app.cr").should eq(expected)
          env.sanitize_path("./src/../src/./app.cr").should eq(expected)
          env.sanitize_path(expected).should eq(expected)
          env.inside_root?("src/app.cr").should be_true
        end
      end

      it "allows non-existent targets inside root for new file creation" do
        with_temp_dir do |dir|
          env = Nightmare::Workspace::Environment.new(dir, ensure_dirs: false)
          target = env.sanitize_path("new_dir/sub_dir/new_file.cr")
          target.should eq(File.join(env.root, "new_dir", "sub_dir", "new_file.cr"))
          env.inside_root?("new_dir/sub_dir/new_file.cr").should be_true
        end
      end

      it "strictly rejects path traversal escaping root with SecurityError" do
        with_temp_dir do |dir|
          env = Nightmare::Workspace::Environment.new(dir, ensure_dirs: false)

          expect_raises(Nightmare::SecurityError, /Path traversal violation/) do
            env.sanitize_path("../outside.txt")
          end
          expect_raises(Nightmare::SecurityError, /Path traversal violation/) do
            env.sanitize_path("src/../../outside.txt")
          end
          expect_raises(Nightmare::SecurityError, /Path traversal violation/) do
            env.sanitize_path("/etc/passwd")
          end

          env.inside_root?("../outside.txt").should be_false
          env.inside_root?("/etc/shadow").should be_false
        end
      end

      it "rejects sibling prefix collision attacks" do
        parent_dir = File.join(Dir.tempdir, "prefix_#{Random::Secure.hex(4)}")
        root_dir = File.join(parent_dir, "nightmare")
        evil_dir = File.join(parent_dir, "nightmare_evil")
        Dir.mkdir_p(root_dir)
        Dir.mkdir_p(evil_dir)
        File.write(File.join(evil_dir, "secret.txt"), "stolen")

        begin
          env = Nightmare::Workspace::Environment.new(root_dir, ensure_dirs: false)

          expect_raises(Nightmare::SecurityError) do
            env.sanitize_path(File.join(evil_dir, "secret.txt"))
          end
          env.inside_root?(File.join(evil_dir, "secret.txt")).should be_false
          env.inside_root?(evil_dir).should be_false
        ensure
          FileUtils.rm_rf(parent_dir)
        end
      end

      it "allows internal symlinks pointing inside root" do
        with_temp_dir do |dir|
          src_dir = File.join(dir, "src")
          Dir.mkdir_p(src_dir)
          File.write(File.join(src_dir, "code.cr"), "puts 1")

          symlink_dir = File.join(dir, "link_src")
          File.symlink(src_dir, symlink_dir)

          env = Nightmare::Workspace::Environment.new(dir, ensure_dirs: false)
          sanitized = env.sanitize_path("link_src/code.cr")
          sanitized.should eq(File.join(env.root, "src", "code.cr"))
          env.inside_root?("link_src/code.cr").should be_true
        end
      end

      it "strictly rejects out-of-tree symlinks with SecurityError" do
        with_temp_dir do |base|
          root_dir = File.join(base, "root")
          outside_dir = File.join(base, "outside")
          Dir.mkdir_p(root_dir)
          Dir.mkdir_p(outside_dir)
          File.write(File.join(outside_dir, "secret.txt"), "super_secret")

          symlink_outside = File.join(root_dir, "sym_outside")
          File.symlink(outside_dir, symlink_outside)

          env = Nightmare::Workspace::Environment.new(root_dir, ensure_dirs: false)

          expect_raises(Nightmare::SecurityError) { env.sanitize_path("sym_outside") }
          expect_raises(Nightmare::SecurityError) { env.sanitize_path("sym_outside/secret.txt") }
          expect_raises(Nightmare::SecurityError) { env.sanitize_path("sym_outside/new_file.txt") }

          env.inside_root?("sym_outside").should be_false
          env.inside_root?("sym_outside/secret.txt").should be_false
          env.inside_root?("sym_outside/new_file.txt").should be_false
        end
      end

      it "detects .git paths via git_path? helper" do
        with_temp_dir do |dir|
          Dir.mkdir_p(File.join(dir, ".git"))

          env = Nightmare::Workspace::Environment.new(dir, ensure_dirs: false)
          env.git_path?(".git").should be_true
          env.git_path?(".git/config").should be_true
          env.git_path?("src/../.git/HEAD").should be_true
          env.git_path?(".gitignore").should be_false
          env.git_path?("git_util.cr").should be_false
        end
      end
    end

    describe "Startup Notification Banner" do
      it "renders bordered Unicode box banner matching exact specification" do
        with_temp_dir do |dir|
          env = Nightmare::Workspace::Environment.new(dir, ensure_dirs: false)
          banner = env.startup_banner

          banner.should contain("┌── NIGHTMARE ")
          banner.should contain("│ Workspace : #{env.root}")
          banner.should contain("│ Config    : ")
          banner.should contain("│ State/Logs: ")
          banner.should contain("└─")

          lines = banner.lines
          lines.size.should eq(5)
          lines.map(&.size).uniq.size.should eq(1)
          lines.first.size.should be >= 76
        end
      end
    end
  end

  describe Nightmare::Workspace::Manifest do
    it "bootstraps and updates workspace.json metadata" do
      with_temp_dir do |dir|
        m1 = Nightmare::Workspace::Manifest.bootstrap(dir, "test-12345678", "/path/to/repo")
        m1.id.should eq("test-12345678")
        m1.canonical_path.should eq("/path/to/repo")

        path = File.join(dir, "workspace.json")
        File.exists?(path).should be_true

        m2 = Nightmare::Workspace::Manifest.bootstrap(dir, "test-12345678", "/path/to/repo")
        (m2.last_accessed >= m1.last_accessed).should be_true
        m2.created_at.to_unix.should eq(m1.created_at.to_unix)
      end
    end
  end

  describe Nightmare::Workspace::AuditLog do
    it "appends entries and rotates automatically at threshold with 3 history files" do
      with_temp_dir do |dir|
        log_path = File.join(dir, "llm_calls.jsonl")
        logger = Nightmare::Workspace::AuditLog.new(log_path, max_size: 60_i64, max_rotated: 3)

        10.times do |i|
          logger.log(%({"call":#{i},"payload":"#{"a" * 25}"}))
        end

        File.exists?(log_path).should be_true
        logger.rotated_files.size.should be <= 3

        File.exists?("#{log_path}.1").should be_true
        File.exists?("#{log_path}.2").should be_true
        File.exists?("#{log_path}.3").should be_true
        File.exists?("#{log_path}.4").should be_false
      end
    end

    it "does not write logs when disabled via --no-log" do
      with_temp_dir do |dir|
        log_path = File.join(dir, "llm_calls.jsonl")
        logger = Nightmare::Workspace::AuditLog.new(log_path, enabled: false)
        logger.log(%({"test":"ignored"}))
        File.exists?(log_path).should be_false
      end
    end
  end
end
