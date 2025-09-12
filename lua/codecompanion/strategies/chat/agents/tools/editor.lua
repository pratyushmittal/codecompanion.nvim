--[[
*Editor Tool*
This tool is used to directly modify the contents of a buffer. It can handle
multiple edits in the same XML block.
--]]

local config = require("codecompanion.config")
local keymaps = require("codecompanion.utils.keymaps")
local log = require("codecompanion.utils.log")
local ui = require("codecompanion.utils.ui")
local patches = require("codecompanion.helpers.patches")

local api = vim.api
local fmt = string.format

---@class CodeCompanion.Tool.Editor: CodeCompanion.Agent.Tool
return {
  name = "editor",
  opts = {
    use_handlers_once = true,
  },
  cmds = {
    ---Ensure the final function returns the status and the output
    ---@param self CodeCompanion.Tool.Editor The Editor tool
    ---@param args table The arguments from the LLM's tool call
    ---@param input? any The output from the previous function call
    ---@return nil|{ status: "success"|"error", data: string }
    function(self, args, input)
      ---Run the action
      ---@param run_args {buffer: number, patch_text: string}
      ---@return { status: "success"|"error", data: string }
      local function run(run_args)
        -- log:trace("[Editor Tool] request: %s", run_args)

        local current_lines = api.nvim_buf_get_lines(run_args.buffer, 0, -1, false)
        local parsed_changes, parse_err = patches.parse_changes(run_args.patch_text)

        if not parsed_changes then
          log:error(("[Editor Tool] Failed to parse patch_text: %s"):format(parse_err))
          return { status = "error", data = "Failed to parse patch_text: " .. (parse_err or "unknown error") }
        end

        for i, change in ipairs(parsed_changes) do
          local new_lines_candidate = patches.apply_change(current_lines, change)
          if not new_lines_candidate then
            log:error(("[Editor Tool] Failed to apply change %d: %s"):format(i, patches.get_change_string(change)))
            return { status = "error", data = "Failed to apply one or more changes from the patch." }
          end
          current_lines = new_lines_candidate
        end

        api.nvim_buf_set_lines(run_args.buffer, 0, -1, false, current_lines)

        --TODO: Scroll to buffer and the new lines

        -- Automatically save the buffer
        if vim.g.codecompanion_auto_tool_mode then
          log:info("[Editor Tool] Auto-saving buffer")
          api.nvim_buf_call(run_args.buffer, function()
            vim.cmd("silent write")
          end)
        end

        return { status = "success", data = nil }
      end

      args.buffer = tonumber(args.buffer)
      if not args.buffer then
        return { status = "error", data = "No buffer number or buffer number conversion failed" }
      end

      local is_valid, _ = pcall(api.nvim_buf_is_valid, args.buffer)
      if not is_valid then
        return { status = "error", data = "Invalid buffer number" }
      end

      -- Validate patch_text exists
      if not args.patch_text or args.patch_text == "" then
        return { status = "error", data = "No patch_text provided" }
      end

      return run(args)
    end,
  },
  schema = {
    type = "function",
    ["function"] = {
      name = "editor",
      description = "Applies a textual patch to a buffer in the user's Neovim instance.",
      parameters = {
        type = "object",
        properties = {
          buffer = {
            type = "integer",
            description = "Neovim buffer number",
          },
          patch_text = {
            type = "string",
            description = "A textual patch in the specified diff format containing the changes to be applied to the buffer.",
          },
        },
        required = {
          "buffer",
          "patch_text",
        },
        additionalProperties = false,
      },
      strict = true,
    },
  },
  system_prompt = string.format([[# Editor Tool (`editor`)

## CONTEXT
- You have access to an editor tool running within CodeCompanion, in Neovim.
- You can use it to apply patches to a Neovim buffer, via a buffer number that the user has provided to you.
- You must provide changes in a specific patch format.

## OBJECTIVE
- To implement code changes in a Neovim buffer by providing a patch.

## PATCH FORMAT
%s

## RESPONSE
- Only invoke this tool when the user specifically asks for code modifications.
- Use this tool strictly for applying code changes as patches.
- If the user asks you to write or modify code, generate a patch in the format described above.
- If the user has not provided you with a buffer number, you must ask them for one.
- Ensure that the code in your patch is syntactically correct and that indentations are accurately represented.
- The `patch_text` parameter should contain *only* the patch itself, starting with `*** Begin Patch` and ending with `*** End Patch`. Do not include any other explanatory text or markdown formatting around the patch block in the `patch_text` parameter.

## POINTS TO NOTE
- This tool can be used alongside other tools within CodeCompanion.
- Multiple sets of changes (diffs) can be included in a single patch.
]], [[
*** Begin Patch
[PATCH]
*** End Patch

The `[PATCH]` is the series of diffs to be applied for each change in the file. Each diff should be in this format:

[3 lines of pre-context]
-[old code]
+[new code]
[3 lines of post-context]

The context blocks are 3 lines of existing code, immediately before and after the modified lines of code. Lines to be modified should be prefixed with a `+` or `-` sign. Unchanged lines used for context starting with a `-` (such as comments in Lua) can be prefixed with a space ` `.

Multiple blocks of diffs should be separated by an empty line and `@@[identifier]` detailed below.

The linked context lines next to the edits are enough to locate the lines to edit. DO NOT USE line numbers anywhere in the patch.

You can use `@@[identifier]` to define a larger context in case the immediately before and after context is not sufficient to locate the edits. Example:

@@class BaseClass(models.Model):
[3 lines of pre-context]
-	pass
+	raise NotImplementedError()
[3 lines of post-context]

You can also use multiple `@@[identifiers]` to provide the right context if a single `@@` is not sufficient.

Example with multiple blocks of changes and `@@` identifiers:

*** Begin Patch
@@class BaseClass(models.Model):
@@	def search():
-		pass
+		raise NotImplementedError()

@@class Subclass(BaseClass):
@@	def search():
-		pass
+		raise NotImplementedError()
*** End Patch

This format is a bit similar to the `git diff` format; the difference is that `@@[identifiers]` uses the unique line identifiers from the preceding code instead of line numbers. We don't use line numbers anywhere since the before and after context, and `@@` identifiers are enough to locate the edits.
]]),
  output = {
    ---@param self CodeCompanion.Tool.Editor
    ---@param agent CodeCompanion.Agent
    ---@param cmd table The command that was executed
    ---@param stdout table
    success = function(self, agent, cmd, stdout)
      local chat = agent.chat
      local args = self.args
      local buf = args.buffer

      -- Since we don't have action, code, start_line, end_line anymore,
      -- we simplify the output message.
      -- We could potentially count the number of changes in the patch_text
      -- or the number of lines affected if that information is needed.
      local short = fmt("**Editor Tool:** Applied patch to buffer %d", buf)
      -- For the full message, we could show the patch_text itself,
      -- but it might be too verbose. A simple confirmation is probably best.
      local ft = "diff" -- Hardcode to diff for the patch text
      local full = fmt("%s:\n```%s\n%s\n```", short, ft, args.patch_text) -- Show the applied patch

      return chat:add_tool_output(self, full, short)
    end,
  },
}
