# nightmare/src/nightmare/ui/editor.cr

require "salamander"

module Nightmare::UI
  module Editor
    extend self

    def resolve_editor(override : String? = nil) : String?
      Salamander::UI::Editor.resolve_editor(override)
    end

    def edit(
      initial_text : String,
      editor_override : String? = nil,
      io_in : IO = STDIN,
      io_out : IO = STDOUT,
      io_err : IO = STDERR,
      tempfile_prefix : String = "nightmare_prompt_",
      tempfile_suffix : String = ".md",
      subject : String = "system prompt"
    ) : String?
      Salamander::UI::Editor.edit(
        initial_text: initial_text,
        editor_override: editor_override,
        io_in: io_in,
        io_out: io_out,
        io_err: io_err,
        tempfile_prefix: tempfile_prefix,
        tempfile_suffix: tempfile_suffix,
        subject: subject
      )
    end
  end
end
