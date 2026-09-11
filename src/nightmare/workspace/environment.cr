require "digest/sha256"
require "file_utils"
require "path"
require "../exceptions"
require "./manifest"

module Nightmare::Workspace
  class Environment
    getter root : String
    getter workspace_id : String
    getter xdg_config_home : String
    getter xdg_state_home : String
    getter xdg_cache_home : String
    getter config_dir : String
    getter state_dir : String
    getter cache_dir : String
    getter global_config_dir : String
    getter allowlist_path : String
    getter log_path : String
    getter manifest_path : String
    getter workspace_prompt_path : String
    getter global_prompt_path : String
    getter repo_prompt_path : String
    getter manifest : Manifest

    def workspace_config_dir : String
      @config_dir
    end

    def workspace_state_dir : String
      @state_dir
    end

    def workspace_cache_dir : String
      @cache_dir
    end

    def initialize(
      root_path : String = Dir.current,
      xdg_config_home : String? = nil,
      xdg_state_home : String? = nil,
      xdg_cache_home : String? = nil,
      ensure_dirs : Bool = true
    )
      @root = File.realpath(root_path)

      raw_slug = File.basename(@root).gsub(/[^a-zA-Z0-9_-]/, "_")
      slug = (raw_slug.empty? || raw_slug == "/" || raw_slug == "_") ? "root" : raw_slug
      slug = "workspace" if slug.empty?

      hash = Digest::SHA256.hexdigest(@root)[0..7]
      @workspace_id = "#{slug}-#{hash}"

      home = Path.home.to_s
      @xdg_config_home = resolve_xdg("XDG_CONFIG_HOME", xdg_config_home, File.join(home, ".config"))
      @xdg_state_home = resolve_xdg("XDG_STATE_HOME", xdg_state_home, File.join(home, ".local", "state"))
      @xdg_cache_home = resolve_xdg("XDG_CACHE_HOME", xdg_cache_home, File.join(home, ".cache"))

      @config_dir = File.join(@xdg_config_home, "nightmare", "workspaces", @workspace_id)
      @state_dir = File.join(@xdg_state_home, "nightmare", "workspaces", @workspace_id)
      @cache_dir = File.join(@xdg_cache_home, "nightmare", "workspaces", @workspace_id)
      @global_config_dir = File.join(@xdg_config_home, "nightmare")

      @allowlist_path = File.join(@config_dir, "allow")
      @log_path = File.join(@state_dir, "llm_calls.jsonl")
      @manifest_path = File.join(@config_dir, "workspace.json")
      @workspace_prompt_path = File.join(@config_dir, "prompt.md")
      @global_prompt_path = File.join(@global_config_dir, "prompt.md")
      @repo_prompt_path = File.join(@root, ".nightmare", "prompt.md")

      if ensure_dirs
        Dir.mkdir_p(@config_dir) unless Dir.exists?(@config_dir)
        Dir.mkdir_p(@state_dir) unless Dir.exists?(@state_dir)
        Dir.mkdir_p(@cache_dir) unless Dir.exists?(@cache_dir)
        @manifest = Manifest.load_or_create(@manifest_path, @workspace_id, @root)
      else
        @manifest = Manifest.new(id: @workspace_id, canonical_path: @root)
      end
    end

    def self.resolve(
      current_dir : String = Dir.current,
      xdg_config_home : String? = nil,
      xdg_state_home : String? = nil,
      xdg_cache_home : String? = nil,
      ensure_dirs : Bool = true
    ) : Environment
      unless Dir.exists?(current_dir) || File.exists?(current_dir)
        raise ArgumentError.new("Workspace directory does not exist: #{current_dir}")
      end

      new(
        root_path: current_dir,
        xdg_config_home: xdg_config_home,
        xdg_state_home: xdg_state_home,
        xdg_cache_home: xdg_cache_home,
        ensure_dirs: ensure_dirs
      )
    end

    def inside_root?(path : String) : Bool
      resolved = resolve_contained_path(path)
      path_inside_root?(resolved)
    rescue SecurityError | File::Error
      false
    end

    def sanitize_path(path : String) : String
      resolved = resolve_contained_path(path)
      unless path_inside_root?(resolved)
        raise SecurityError.new("Path traversal violation: target \"#{path}\" resolves to \"#{resolved}\" outside root \"#{@root}\"")
      end
      resolved
    end

    def git_path?(path : String) : Bool
      sanitized = sanitize_path(path)
      rel = Path.new(sanitized).relative_to(@root).to_s
      rel == ".git" || rel.starts_with?(".git/")
    rescue SecurityError | File::Error
      false
    end

    def startup_banner : String
      home = Path.home.to_s
      config_disp = @config_dir.starts_with?(home) ? "~" + @config_dir[home.size..] : @config_dir
      state_disp = @state_dir.starts_with?(home) ? "~" + @state_dir[home.size..] : @state_dir
      config_disp += "/" unless config_disp.ends_with?("/")
      state_disp += "/" unless state_disp.ends_with?("/")

      l1 = "Workspace : #{@root}"
      l2 = "Config    : #{config_disp}"
      l3 = "State/Logs: #{state_disp}"

      content_width = [72, [l1.size, l2.size, l3.size].max].max

      title = "── NIGHTMARE "
      top_dashes = content_width + 2 - title.size
      top = "┌#{title}#{"─" * [top_dashes, 1].max}┐"

      row1 = "│ #{l1.ljust(content_width)} │"
      row2 = "│ #{l2.ljust(content_width)} │"
      row3 = "│ #{l3.ljust(content_width)} │"
      bot = "└#{"─" * (content_width + 2)}┘"

      [top, row1, row2, row3, bot].join("\n")
    end

    private def resolve_contained_path(path : String) : String
      expanded = if Path.new(path).absolute?
        File.expand_path(path)
      else
        File.expand_path(path, @root)
      end

      curr = expanded
      remaining = [] of String
      while !File.exists?(curr) && !File.symlink?(curr)
        parent = File.dirname(curr)
        break if parent == curr
        remaining.unshift(File.basename(curr))
        curr = parent
      end

      begin
        real_ancestor = File.realpath(curr)
      rescue ex : File::Error
        raise SecurityError.new("Unresolvable path: #{path}")
      end

      if remaining.empty?
        real_ancestor
      else
        File.join(real_ancestor, File.join(remaining))
      end
    end

    private def path_inside_root?(path : String) : Bool
      prefix = @root.ends_with?('/') ? @root : "#{@root}/"
      path == @root || path.starts_with?(prefix)
    end

    private def resolve_xdg(env_var : String, param : String?, fallback : String) : String
      if param && !param.empty?
        param
      elsif (env = ENV[env_var]?) && !env.empty?
        env
      else
        fallback
      end
    end
  end
end
