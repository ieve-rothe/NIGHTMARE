require "json"
require "time"

module Nightmare::Workspace
  struct Manifest
    include JSON::Serializable

    property id : String
    property canonical_path : String
    property created_at : Time
    property last_accessed : Time

    def initialize(
      @id : String,
      @canonical_path : String,
      @created_at : Time = Time.utc.at_beginning_of_second,
      @last_accessed : Time = Time.utc.at_beginning_of_second
    )
    end

    def touch : Nil
      @last_accessed = Time.utc.at_beginning_of_second
    end

    def self.load(path : String) : Manifest
      from_json(File.read(path))
    end

    def save(path : String) : Nil
      File.write(path, to_pretty_json)
    end

    def self.load_or_create(path : String, id : String, canonical_path : String) : Manifest
      if File.exists?(path)
        manifest = begin
          load(path)
        rescue JSON::ParseException
          new(id: id, canonical_path: canonical_path)
        end
        manifest.touch
        manifest.save(path)
        manifest
      else
        dir = File.dirname(path)
        Dir.mkdir_p(dir) unless Dir.exists?(dir)
        manifest = new(id: id, canonical_path: canonical_path)
        manifest.save(path)
        manifest
      end
    end

    def self.bootstrap(config_dir : String, id : String, canonical_path : String) : Manifest
      path = File.join(config_dir, "workspace.json")
      load_or_create(path, id, canonical_path)
    end
  end

  class AuditLog
    MAX_SIZE = 20_971_520_i64 # 20 MB
    MAX_ROTATED = 3

    getter path : String
    getter? enabled : Bool
    getter max_size : Int64
    getter max_rotated : Int32

    def initialize(
      @path : String,
      @enabled : Bool = true,
      @max_size : Int64 = MAX_SIZE,
      @max_rotated : Int32 = MAX_ROTATED
    )
    end

    def log(entry : String) : Nil
      return unless @enabled

      dir = File.dirname(@path)
      Dir.mkdir_p(dir) unless Dir.exists?(dir)

      rotate_if_needed

      File.open(@path, mode: "a") do |file|
        file.puts(entry)
      end
    end

    def log(entry : Hash(String, JSON::Any) | JSON::Any | NamedTuple) : Nil
      log(entry.to_json)
    end

    def rotate_if_needed : Bool
      return false unless File.exists?(@path)
      return false if File.size(@path) < @max_size

      oldest = "#{@path}.#{@max_rotated}"
      File.delete(oldest) if File.exists?(oldest)

      (@max_rotated - 1).downto(1) do |i|
        src = "#{@path}.#{i}"
        dst = "#{@path}.#{i + 1}"
        File.rename(src, dst) if File.exists?(src)
      end

      File.rename(@path, "#{@path}.1")
      true
    end

    def rotated_files : Array(String)
      files = [] of String
      (1..@max_rotated).each do |i|
        candidate = "#{@path}.#{i}"
        files << candidate if File.exists?(candidate)
      end
      files
    end
  end
end
