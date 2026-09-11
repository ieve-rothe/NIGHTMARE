require "spec"
require "../src/nightmare"
require "file_utils"

# Creates an isolated temporary directory, yields the canonical path, and cleans it up afterward.
def with_temp_dir(& : String -> Nil)
  dir = File.tempfile("nightmare_spec_dir").path
  File.delete(dir) if File.exists?(dir)
  Dir.mkdir_p(dir)
  begin
    yield File.realpath(dir)
  ensure
    FileUtils.rm_rf(dir) if Dir.exists?(dir)
  end
end

# Scopes environment variable modifications to a block and restores them afterwards.
def with_env(vars : Hash(String, String?), &)
  original = {} of String => String?
  vars.each do |k, v|
    original[k] = ENV[k]?
    if v.nil?
      ENV.delete(k)
    else
      ENV[k] = v
    end
  end

  begin
    yield
  ensure
    original.each do |k, v|
      if v.nil?
        ENV.delete(k)
      else
        ENV[k] = v
      end
    end
  end
end
