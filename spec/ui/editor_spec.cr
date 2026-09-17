require "../spec_helper"

describe Nightmare::UI::Editor do
  it "resolves editor priority via underlying engine" do
    Nightmare::UI::Editor.resolve_editor("custom-editor").should eq("custom-editor")
  end

  it "successfully executes an editor command on prompt text" do
    mock_editor = "sh -c 'echo \"\\nAdditional rules\" >> \"$1\"' --"
    res = Nightmare::UI::Editor.edit(
      initial_text: "System prompt content",
      editor_override: "sh -c 'echo \"Additional rules\" >> \"$1\"' --"
    )
    res.should eq("System prompt content\nAdditional rules")
  end

  it "returns nil and writes warning when output is empty" do
    err_io = IO::Memory.new
    res = Nightmare::UI::Editor.edit(
      initial_text: "System prompt content",
      editor_override: "sh -c '> \"$1\"' --",
      io_err: err_io
    )
    res.should be_nil
    err_io.to_s.should contain("Warning: Edited system prompt was empty. Retaining previous system prompt.")
  end

  it "returns nil and writes notice on non-zero exit" do
    err_io = IO::Memory.new
    res = Nightmare::UI::Editor.edit(
      initial_text: "System prompt content",
      editor_override: "sh -c 'exit 1' --",
      io_err: err_io
    )
    res.should be_nil
    err_io.to_s.should contain("Notice: Editor exited with non-zero status (1). In-memory system prompt unchanged.")
  end
end
