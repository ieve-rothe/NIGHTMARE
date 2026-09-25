# nightmare/keys.cr
# Copyright (C) 2026 Cam Carroll
# Licensed under the AGPL-3.0. See LICENSE for details.

require "./workspace/environment"

module Nightmare
  module Keys
    # Resolves an API or service key by name (e.g., "tavily")
    # Resolution priority:
    # 1. Environment variable: <NAME>_API_KEY, <NAME>_KEY (e.g. TAVILY_API_KEY, TAVILY_KEY)
    # 2. Workspace key file: <workspace_config_dir>/keys/<name>
    # 3. Global keys dir: <global_config_dir>/keys/<name> (default ~/.config/nightmare/keys/<name>)
    # 4. Global fallback flat file: <global_config_dir>/<name>_key (e.g. ~/.config/nightmare/tavily_key)
    def self.get?(name : String, env : Workspace::Environment? = nil) : String?
      clean_name = name.downcase.strip

      # 1. ENV overrides
      if env_val = ENV["#{clean_name.upcase}_API_KEY"]? || ENV["#{clean_name.upcase}_KEY"]?
        return env_val.strip unless env_val.strip.empty?
      end

      # 2. Workspace keys dir (if env provided)
      if env
        ws_key = File.join(env.config_dir, "keys", clean_name)
        if File.exists?(ws_key)
          val = File.read(ws_key).strip
          return val unless val.empty?
        end
      end

      # 3. Global keys directory
      global_dir = env ? env.global_config_dir : default_global_config_dir
      global_key = File.join(global_dir, "keys", clean_name)
      if File.exists?(global_key)
        val = File.read(global_key).strip
        return val unless val.empty?
      end

      # 4. Global flat file fallback (e.g. tavily_key)
      flat_key = File.join(global_dir, "#{clean_name}_key")
      if File.exists?(flat_key)
        val = File.read(flat_key).strip
        return val unless val.empty?
      end

      nil
    end

    def self.get!(name : String, env : Workspace::Environment? = nil) : String
      get?(name, env) || raise "Missing #{name} API key in ENV or ~/.config/nightmare/keys/#{name} (or ~/.config/nightmare/#{name}_key)"
    end

    private def self.default_global_config_dir : String
      xdg = ENV["XDG_CONFIG_HOME"]?
      base = (xdg && !xdg.empty?) ? xdg : File.join(Path.home.to_s, ".config")
      File.join(base, "nightmare")
    end
  end
end
