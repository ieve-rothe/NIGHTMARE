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

# In-process fake client for deterministic testing of inference and step loops (ARCHITECTURE_R3 §9)
class FakeClient < Mantle::Clients::Client
  property model_name : String = "fake"
  property responses : Array(Mantle::Clients::Response)
  property call_count : Int32 = 0
  property recorded_messages : Array(Array(Mantle::Message)) = [] of Array(Mantle::Message)
  property raise_on_call : Hash(Int32, Exception) = Hash(Int32, Exception).new

  def initialize(@responses : Array(Mantle::Clients::Response) = [] of Mantle::Clients::Response)
  end

  def execute(
    messages : Array(Mantle::Message),
    tools : Array(Mantle::Tools::Tool)? = nil,
    &on_chunk : String -> Nil
  ) : Mantle::Clients::Response
    @recorded_messages << messages.dup
    @call_count += 1

    if ex = @raise_on_call[@call_count]?
      raise ex
    end

    response = if @responses.empty?
      Mantle::Clients::Response.new(content: "default response", tool_calls: nil)
    elsif @call_count <= @responses.size
      @responses[@call_count - 1]
    else
      @responses.last
    end

    if content = response.content
      on_chunk.call(content) unless content.empty?
    end

    response
  end
end
