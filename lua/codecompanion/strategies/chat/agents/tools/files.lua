--[[
*Files Tool*
This tool can be used make edits to files on disk.
--]]

local Path = require("plenary.path")
local log = require("codecompanion.utils.log")

local fmt = string.format

---@class Action The arguments from the LLM's tool call
---@field action string CREATE / READ / UPDATE / DELETE action to perform
---@field path string path of the file to perform action on
---@field contents string diff in case of UPDATE; raw contents in case of CREATE

---Create a file and it's surrounding folders
---@param action Action The arguments from the LLM's tool call
---@return string
local function create(action)
  local p = Path:new(action.path)
  p.filename = p:expand()
  p:touch({ parents = true })
  p:write(action.contents or "", "w")
  return fmt("The CREATE action for `%s` was successful", action.path)
end

---Read the contents of file
---@param action Action The arguments from the LLM's tool call
---@return string
local function read(action)
  local p = Path:new(action.path)
  p.filename = p:expand()

  local output = fmt(
    [[The file's contents are:

```%s
%s
```]],
    vim.fn.fnamemodify(p.filename, ":e"),
    p:read()
  )
  return output
end

---@class Change
---@field focus table list of lines before changes for larger context
---@field pre table list of unchanged lines just before edits
---@field old table list of lines to be removed
---@field new table list of lines to be added
---@field post table list of unchanged lines just after edits
--- Returns an new (empty) change table instance
---@param focus table list of focus lines, used to create a new change set with similar focus
---@param pre table list of pre lines to extend an existing change set
---@return Change
local function get_new_change(focus, pre)
  return {
    focus = focus or {},
    pre = pre or {},
    old = {},
    new = {},
    post = {},
  }
end

--- Returns list of Change objects parsed from the patch provided by LLMs
---@param patch string patch contents to be parsed
---@return Change[]
local function parse_changes(patch)
  local changes = {}
  local change = get_new_change()
  local lines = vim.split(patch, "\n", { plain = true })
  for i, line in ipairs(lines) do
    if vim.startswith(line, "@@") then
      if #change.old > 0 or #change.new > 0 then
        -- @@ after any edits is a new change block
        table.insert(changes, change)
        change = get_new_change()
      end
      -- focus name can be empty too to signify new blocks
      local focus_name = vim.trim(line:sub(3))
      if focus_name and #focus_name > 0 then
        change.focus[#change.focus + 1] = focus_name
      end
    elseif line == "" and lines[i + 1] and lines[i + 1]:match("^@@") then
      -- empty lines can be part of pre/post context
      -- we treat empty lines as new change block and not as post context
      -- only when the the next line uses @@ identifier
      table.insert(changes, change)
      change = get_new_change()
    elseif line:sub(1, 1) == "-" then
      if #change.post > 0 then
        -- edits after post edit lines are new block of changes with same focus
        table.insert(changes, change)
        change = get_new_change(change.focus, change.post)
      end
      change.old[#change.old + 1] = line:sub(2)
    elseif line:sub(1, 1) == "+" then
      if #change.post > 0 then
        -- edits after post edit lines are new block of changes with same focus
        table.insert(changes, change)
        change = get_new_change(change.focus, change.post)
      end
      change.new[#change.new + 1] = line:sub(2)
    elseif #change.old == 0 and #change.new == 0 then
      change.pre[#change.pre + 1] = line
    elseif #change.old > 0 or #change.new > 0 then
      change.post[#change.post + 1] = line
    end
  end
  table.insert(changes, change)
  return changes
end

---@class MatchOptions
---@field trim_spaces boolean trim spaces while comparing lines
--- returns whether the given lines (needle) match the lines in the file we are editing at the given line number
---@param haystack string[] list of lines in the file we are updating
---@param pos number the line number where we are checking the match
---@param needle string[] list of lines we are trying to match
---@param opts? MatchOptions options for matching strategy
---@return boolean true of the given lines match at the given line number in haystack
local function matches_lines(haystack, pos, needle, opts)
  opts = opts or {}
  if pos < 1 then return false end -- Cannot match before the start of the file
  for i, needle_line in ipairs(needle) do
    local hayline_idx = pos + i - 1
    if hayline_idx > #haystack then return false end -- Cannot match beyond the end of the file
    local hayline = haystack[hayline_idx]
    local is_same = hayline
      and ((hayline == needle_line) or (opts.trim_spaces and vim.trim(hayline) == vim.trim(needle_line)))
    if not is_same then
      return false
    end
  end
  return true
end

--- returns whether the given line number (before_pos) is after the focus lines
---@param lines string[] list of lines in the file we are updating
---@param before_pos number current line number before which the focus lines should appear
---@param focus string[] list of focus lines
---@param opts? MatchOptions options for matching strategy
---@return boolean true of the given line number is after the focus lines
local function has_focus(lines, before_pos, focus, opts)
  opts = opts or {}
  local start = 1
  for _, focus_line in ipairs(focus) do
    local found = false
    -- Ensure k does not go below 1 or exceed #lines
    for k = start, math.min(before_pos - 1, #lines) do
      if k < 1 then goto continue end -- Skip if k is out of bounds
      if focus_line == lines[k] or (opts.trim_spaces and vim.trim(focus_line) == vim.trim(lines[k])) then
        start = k + 1 -- Start next search from the line after the found line
        found = true
        break
      end
      ::continue::
    end
    if not found then
      return false
    end
  end
  return true
end

--- Calculates the probability of a match based on context lines.
---@param haystack string[] list of lines in the file we are updating
---@param pos number the line number in `haystack` which is currently being considered as the starting point of `change.old` lines
---@param change Change the change object, containing `pre`, `old`, `new`, `post` line lists
---@param opts? MatchOptions options for matching strategy
---@return number probability score between 0.0 and 1.0
local function calculate_match_probability(haystack, pos, change, opts)
  opts = opts or {}
  local matching_lines_count = 0
  local total_context_lines = #change.pre + #change.post

  if total_context_lines == 0 then
    return #change.old == 0 and 1.0 or 0.5
  end

  -- Check pre-context lines
  for i, pre_line in ipairs(change.pre) do
    local hay_index = pos - #change.pre + i - 1
    if hay_index >= 1 and hay_index <= #haystack then
      local hay_line = haystack[hay_index]
      if hay_line then
        local is_same = (hay_line == pre_line) or (opts.trim_spaces and vim.trim(hay_line) == vim.trim(pre_line))
        if is_same then
          matching_lines_count = matching_lines_count + 1
        end
      end
    end
  end

  -- Check post-context lines
  for i, post_line in ipairs(change.post) do
    local hay_index = pos + #change.old + i - 1
    if hay_index >= 1 and hay_index <= #haystack then
      local hay_line = haystack[hay_index]
      if hay_line then
        local is_same = (hay_line == post_line) or (opts.trim_spaces and vim.trim(hay_line) == vim.trim(post_line))
        if is_same then
          matching_lines_count = matching_lines_count + 1
        end
      end
    end
  end

  return matching_lines_count / total_context_lines
end

--- returns new list of lines with the applied changes
---@param lines string[] list of lines in the file we are updating
---@param change Change change to be applied on the lines
---@return string[]|nil list of updated lines after change
local function apply_change(lines, change)
  local best_match = { probability = -1, line_index = -1, trim_spaces = false }

  for i = 1, #lines + 1 do -- Iterate up to #lines + 1 to allow appending to file
    local opts_no_trim = { trim_spaces = false }
    if has_focus(lines, i, change.focus, opts_no_trim) then
      local prob_no_trim = calculate_match_probability(lines, i, change, opts_no_trim)
      if prob_no_trim > best_match.probability then
        best_match = { probability = prob_no_trim, line_index = i, trim_spaces = false }
      end
    end

    local opts_trim = { trim_spaces = true }
    if has_focus(lines, i, change.focus, opts_trim) then
      local prob_trim = calculate_match_probability(lines, i, change, opts_trim)
      if prob_trim > best_match.probability then
        best_match = { probability = prob_trim, line_index = i, trim_spaces = true }
      end
    end
  end

  if best_match.line_index == -1 or best_match.probability == 0 then
    if not (best_match.probability == 1.0 and #change.pre == 0 and #change.post == 0 and #change.old == 0) then
      return nil
    end
  end

  local apply_opts = { trim_spaces = best_match.trim_spaces }
  local current_pos = best_match.line_index

  if #change.old > 0 then
    if not matches_lines(lines, current_pos, change.old, apply_opts) then
      return nil
    end
  end

  local new_lines = {}
  for k = 1, current_pos - 1 do
    if k > #lines then break end
    new_lines[#new_lines + 1] = lines[k]
  end

  local fix_spaces
  if apply_opts.trim_spaces and #change.old > 0 and current_pos <= #lines and #lines[current_pos] > 0 then
      local original_line_in_file = lines[current_pos]
      local change_old_first_line = change.old[1]
      if change_old_first_line == " " .. vim.trim(original_line_in_file) then
          fix_spaces = function(ln) return ln:sub(2) end
      elseif vim.trim(change_old_first_line) == vim.trim(original_line_in_file) then
          local actual_prefix_on_file = original_line_in_file:match("^%s*") or ""
          fix_spaces = function(ln) return actual_prefix_on_file .. ln end
      end
  elseif apply_opts.trim_spaces and #change.old == 0 and #change.pre > 0 and current_pos > #change.pre then
      local last_pre_line_in_file_idx = current_pos - 1
      if last_pre_line_in_file_idx >=1 and last_pre_line_in_file_idx <= #lines then
        local actual_prefix_on_file = lines[last_pre_line_in_file_idx]:match("^%s*") or ""
        if #actual_prefix_on_file > 0 then
            fix_spaces = function(ln) return actual_prefix_on_file .. ln end
        end
      end
  end

  for _, ln in ipairs(change.new) do
    if fix_spaces then ln = fix_spaces(ln) end
    new_lines[#new_lines + 1] = ln
  end

  for k = current_pos + #change.old, #lines do
    new_lines[#new_lines + 1] = lines[k]
  end

  return new_lines
end

---Edit the contents of a file
---@param action Action The arguments from the LLM's tool call
---@return string
local function update(action)
  local p = Path:new(action.path)
  p.filename = p:expand()
  local raw = action.contents or ""
  local patch = raw:match("%*%*%* Begin Patch%s+(.-)%s+%*%*%* End Patch")
  if not patch then error("Invalid patch format: missing Begin/End markers") end
  local content = p:read()
  local lines = vim.split(content, "\n", { plain = true })
  local changes = parse_changes(patch)
  for _, change in ipairs(changes) do
    local new_lines = apply_change(lines, change)
    if new_lines == nil then
      error(fmt("Diff block not found or old lines mismatch for patch:\n\n%s", vim.inspect(change)))
    else
      lines = new_lines
    end
  end
  p:write(table.concat(lines, "\n"), "w")
  return fmt("The UPDATE action for `%s` was successful", action.path)
end

---Delete a file
---@param action table The arguments from the LLM's tool call
---@return string
local function delete(action)
  local p = Path:new(action.path)
  p.filename = p:expand()
  p:rm()
  return fmt("The DELETE action for `%s` was successful", action.path)
end

local M = {
  CREATE = create,
  READ = read,
  UPDATE = update,
  DELETE = delete,
  -- For testing purposes:
  apply_change = apply_change,
  parse_changes = parse_changes,
  calculate_match_probability = calculate_match_probability,
  has_focus = has_focus,
  matches_lines = matches_lines,
}

---@class CodeCompanion.Tool.Files: CodeCompanion.Agent.Tool
local tool_definition = {
  name = "files",
  cmds = {
    function(self, args, input)
      args.action = args.action and string.upper(args.action)
      if not M[args.action] then
        return { status = "error", data = fmt("Unknown action: %s", args.action) }
      end
      local ok, outcome = pcall(M[args.action], args)
      if not ok then return { status = "error", data = outcome } end
      return { status = "success", data = outcome }
    end,
  },
  schema = {
    type = "function",
    ["function"] = {
      name = "files",
      description = "CREATE/READ/UPDATE/DELETE files on disk (user approval required)",
      parameters = {
        type = "object",
        properties = {
          action = { type = "string", enum = { "CREATE", "READ", "UPDATE", "DELETE" }, description = "Type of file action to perform." },
          path = { type = "string", description = "Path of the target file." },
          contents = { anyOf = { { type = "string" }, { type = "null" } }, description = "Contents of new file in the case of CREATE action; patch in the specified format for UPDATE action. `null` in the case of READ or DELETE actions." },
        },
        required = { "action", "path", "contents" },
        additionalProperties = false,
      },
      strict = true,
    },
  },
  system_prompt = [[# Files Tool (`files`)
-- (system prompt content remains the same)
]],
  handlers = {
    on_exit = function(agent) log:debug("[Files Tool] on_exit handler executed") end,
  },
  output = {
    prompt = function(self, agent)
      local responses = { CREATE = "Create a file at %s?", READ = "Read %s?", UPDATE = "Edit %s?", DELETE = "Delete %s?" }
      local args = self.args
      local path = vim.fn.fnamemodify(args.path, ":.")
      local action = args.action
      if action and path and responses[string.upper(action)] then return fmt(responses[string.upper(action)], path) end
    end,
    success = function(self, agent, cmd, stdout)
      local chat = agent.chat
      local args = self.args
      local llm_output = vim.iter(stdout):flatten():join("\n")
      local user_output = fmt([[**Files Tool**: The %s action for `%s` was successful]], args.action, args.path)
      chat:add_tool_output(self, llm_output, user_output)
    end,
    error = function(self, agent, cmd, stderr, stdout)
      local chat = agent.chat
      local args = self.args
      local errors = vim.iter(stderr):flatten():join("\n")
      log:debug("[Files Tool] Error output: %s", stderr)
      local error_output = fmt([[**Files Tool**: There was an error running the %s action:

```txt
%s
```]], args.action, errors)
      chat:add_tool_output(self, error_output)
    end,
    rejected = function(self, agent, cmd)
      local chat = agent.chat
      chat:add_tool_output(self, fmt("**Files Tool**: The user declined to run the `%s` action", self.args.action))
    end,
  },
}

return tool_definition
